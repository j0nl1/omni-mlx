import Foundation
import AudioCore
import AudioMCP
import Vapor

private struct ErrorEnvelope: Content {
    struct Detail: Codable, Sendable { let message: String; let type: String; let code: String; let param: String? }
    let error: Detail
}
private struct ModelList: Content { var object = "list"; let data: [ModelDescriptor] }
private struct VoiceList: Content { var object = "list"; let data: [VoiceDescriptor] }
private struct APIIndex: Content {
    struct Endpoint: Codable, Sendable { let method: String; let path: String }
    var service = "omni-mlx"
    let endpoints: [Endpoint]
}
private struct TranscriptionForm: Decodable {
    let file: File
    let model: String
    let language: String?
    let response_format: String?
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
        init?(stringValue: String) { self.stringValue = stringValue }
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let allowed: Set<String> = ["file", "model", "language", "response_format"]
        if let unknown = c.allKeys.map(\.stringValue).sorted().first(where: { !allowed.contains($0) }) {
            throw ServiceError("unsupported_option", "Unsupported transcription option: \(unknown)")
        }
        file = try c.decode(File.self, forKey: Key(stringValue: "file")!)
        model = try c.decode(String.self, forKey: Key(stringValue: "model")!)
        language = try c.decodeIfPresent(String.self, forKey: Key(stringValue: "language")!)
        response_format = try c.decodeIfPresent(String.self, forKey: Key(stringValue: "response_format")!)
    }
}

struct AudioErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do { return try await next.respond(to: request) }
        catch {
            let detail: ServiceError
            if let error = error as? ServiceError { detail = error }
            else if let error = error as? any AbortError {
                detail = ServiceError("invalid_request", error.status.code >= 500 ? "The request could not be completed." : error.reason, status: Int(error.status.code))
            } else if error is DecodingError { detail = ServiceError("invalid_request", "The request body is invalid or missing a required field.") }
            else if error is CancellationError { detail = .cancelled }
            else { request.logger.error("Audio request failed: \(String(reflecting: type(of: error)))"); detail = ServiceError("internal_error", "The request could not be completed.", status: 500) }
            let response = Response(status: HTTPResponseStatus(statusCode: detail.status))
            try response.content.encode(ErrorEnvelope(error: .init(message: detail.message, type: detail.status >= 500 ? "server_error" : "invalid_request_error", code: detail.code, param: nil)))
            if detail.status == 429 { response.headers.replaceOrAdd(name: .retryAfter, value: "1") }
            return response
        }
    }
}
private struct BearerMiddleware: AsyncMiddleware {
    let key: String?
    let keys: (any APIKeyManager)?
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let actual = request.headers.bearerAuthorization?.token else {
            throw ServiceError("invalid_api_key", "A valid bearer API key is required.", status: 401)
        }
        let fixed = key.map { secureEqual(actual, $0) } ?? false
        let managed = await keys?.authorizes(actual) ?? false
        guard fixed || managed else {
            throw ServiceError("invalid_api_key", "A valid bearer API key is required.", status: 401)
        }
        return try await next.respond(to: request)
    }
    private func secureEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

public func configureAudioHTTP(_ app: Application, audio: AudioApplication, apiKey: String?, apiKeys: (any APIKeyManager)? = nil) {
    app.middleware.use(AudioErrorMiddleware())
    let limits = audio.catalog.configuration.server
    app.routes.defaultMaxBodySize = ByteCount(value: limits.maxUploadBytes + 131072)
    app.get("health", "live") { _ in ["status": "ok"] }
    let routes: any RoutesBuilder
    if apiKey != nil || apiKeys != nil { routes = app.grouped(BearerMiddleware(key: apiKey, keys: apiKeys)) }
    else { routes = app }
    if let mcp = audio.catalog.configuration.mcp {
        configureAudioMCP(routes, audio: audio, configuration: mcp)
    }
    routes.get("health", "ready") { _ async throws -> [String: String] in
        guard await audio.ready() else { throw ServiceError.unavailable }
        return ["status": "ready"]
    }
    routes.get("v1", "models") { _ in ModelList(data: audio.catalog.models) }
    routes.get("v1", "voices") { _ in VoiceList(data: audio.catalog.voices) }
    routes.get("v1", "capabilities") { _ throws -> Response in
        struct Capability: Codable { let id: String; let operation: AudioOperation; let formats: [String]; let options: [String] }
        struct Capabilities: Codable { let service_protocol_version: Int; let models: [Capability] }
        let models = audio.catalog.models.map {
            Capability(id: $0.id, operation: $0.operation, formats: $0.operation == .speech ? ["wav"] : ["json"],
                       options: $0.operation == .speech ? ["model", "input", "voice", "response_format"] : ["file", "model", "language", "response_format"])
        }
        let response = Response(); try response.content.encode(Capabilities(service_protocol_version: 1, models: models), as: .json); return response
    }
    routes.post("v1", "audio", "speech") { request async throws -> Response in
        guard request.headers.contentType?.type == "application", request.headers.contentType?.subType == "json", let body = request.body.data else { throw ServiceError("invalid_request", "Expected a JSON speech request.") }
        let raw = Data(body.readableBytesView)
        guard let fields = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { throw ServiceError("invalid_request", "Expected a valid JSON object.") }
        let allowed: Set<String> = ["model", "input", "voice", "response_format"]
        if let key = fields.keys.sorted().first(where: { !allowed.contains($0) }) { throw ServiceError("unsupported_option", "Unsupported speech option: \(key)") }
        let input = try request.content.decode(SpeechRequest.self)
        let data = try await audio.generate(input)
        return Response(status: .ok, headers: ["Content-Type": "audio/wav"], body: .init(data: data))
    }
    routes.post("v1", "audio", "transcriptions") { request async throws -> Response in
        guard request.headers.contentType?.type == "multipart", request.headers.contentType?.subType == "form-data" else {
            throw ServiceError("invalid_request", "Expected multipart/form-data with an audio file.")
        }
        let form = try request.content.decode(TranscriptionForm.self)
        guard form.response_format == nil || form.response_format == "json" else {
            throw ServiceError("unsupported_option", "Transcription supports model, file, language and response_format=json only.")
        }
        let result = try await audio.transcribe(TranscriptionRequest(model: form.model, audio: Data(form.file.data.readableBytesView), filename: form.file.filename, language: form.language))
        let response = Response(); try response.content.encode(result, as: .json); return response
    }
    let endpoints = app.routes.all.compactMap { route -> APIIndex.Endpoint? in
        guard route.path.first == .constant("v1"), route.path.count > 1 else { return nil }
        return .init(method: route.method.rawValue, path: "/" + route.path.map(\.description).joined(separator: "/"))
    }
    app.get("v1") { _ in APIIndex(endpoints: endpoints) }
}
