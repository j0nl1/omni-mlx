import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AudioCore

/// Connects to another instance of this service; it never owns that instance's process.
public actor AttachedBackend: SpeechGenerator, AudioTranscriber, BackendRuntime {
    private let origin: URL
    private let apiKey: String?
    private let catalog: AudioCatalog
    private let backendID: String
    private let queue: ResourceQueue
    private let session: URLSession
    private var healthy = false
    private var uncertain = false
    public init(origin: URL, apiKey: String?, catalog: AudioCatalog, backendID: String, queue: ResourceQueue) {
        self.origin = origin; self.apiKey = apiKey; self.catalog = catalog; self.backendID = backendID; self.queue = queue
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: configuration)
    }
    public func start() async throws {
        guard !uncertain else { throw ServiceError.unavailable }
        struct Capabilities: Decodable { let service_protocol_version: Int }
        struct Models: Decodable { let data: [ModelDescriptor] }
        struct Voices: Decodable { let data: [VoiceDescriptor] }
        let capabilities = try JSONDecoder().decode(Capabilities.self, from: await fetch("v1/capabilities"))
        guard capabilities.service_protocol_version == 1 else { throw ServiceError.unavailable }
        let models = try JSONDecoder().decode(Models.self, from: await fetch("v1/models"))
        let voices = try JSONDecoder().decode(Voices.self, from: await fetch("v1/voices"))
        for (alias, model) in catalog.configuration.models where model.backend == backendID {
            guard models.data.contains(where: { $0.id == alias && $0.operation == model.operation }) else {
                throw ServiceError("backend_catalog_mismatch", "The attached service does not expose configured model \(alias).", status: 503)
            }
            for (id, voice) in catalog.configuration.voices where voice.bindings[alias] != nil {
                guard voices.data.contains(where: { $0.id == id && $0.models.contains(alias) }) else {
                    throw ServiceError("backend_catalog_mismatch", "The attached service does not expose configured voice \(id).", status: 503)
                }
            }
        }
        _ = try await fetch("health/ready")
        healthy = true
    }
    public func ready() async -> Bool {
        guard healthy, !uncertain else { return false }
        do { _ = try await fetch("health/ready"); return true }
        catch { return false }
    }
    public func shutdown() { session.invalidateAndCancel(); healthy = false }
    public func generate(_ request: SpeechRequest, budget: RequestBudget) async throws -> Data {
        try await submit("v1/audio/speech", body: JSONEncoder().encode(request), contentType: "application/json", budget: budget)
    }
    public func transcribe(_ request: TranscriptionRequest, budget: RequestBudget) async throws -> TranscriptionResult {
        let boundary = "audio-\(UUID().uuidString)", ext = URL(fileURLWithPath: request.filename).pathExtension.lowercased()
        let filename = ["wav", "mp3", "m4a", "flac", "aiff", "aif", "caf"].contains(ext) ? "upload.\(ext)" : "upload.bin"
        var body = Data()
        func field(_ name: String, _ value: String) { body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)) }
        field("model", request.model)
        if let language = request.language { field("language", language) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(request.audio); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let data = try await submit("v1/audio/transcriptions", body: body, contentType: "multipart/form-data; boundary=\(boundary)", budget: budget)
        return try JSONDecoder().decode(TranscriptionResult.self, from: data)
    }
    private func fetch(_ path: String) async throws -> Data {
        var request = URLRequest(url: origin.appendingPathComponent(path)); request.timeoutInterval = 5
        authorize(&request)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_048_576 else { throw ServiceError.unavailable }
        return data
    }
    private func submit(_ path: String, body: Data, contentType: String, budget: RequestBudget) async throws -> Data {
        try budget.check()
        guard healthy, !uncertain else { throw ServiceError.unavailable }
        var request = URLRequest(url: origin.appendingPathComponent(path))
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = budget.remainingSeconds
        request.setValue(contentType, forHTTPHeaderField: "Content-Type"); authorize(&request)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            // A failed connection does not establish that remote computation stopped.
            uncertain = true; healthy = false; await queue.quarantine()
            if Task.isCancelled { throw ServiceError.cancelled }
            throw ServiceError("remote_execution_uncertain", "Remote execution may still be running; restart this gateway after checking the attached service.", status: 503)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw ServiceError.unavailable }
        guard status == 200 else {
            struct Envelope: Decodable { struct Detail: Decodable { let message: String; let code: String }; let error: Detail }
            if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
                throw ServiceError(envelope.error.code, envelope.error.message, status: status)
            }
            throw ServiceError("backend_error", "The attached audio service rejected the request.", status: 502)
        }
        guard data.count <= catalog.configuration.server.maxOutputBytes else { throw ServiceError("output_too_large", "Attached output exceeds the configured limit.", status: 413) }
        return data
    }
    private func authorize(_ request: inout URLRequest) {
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
    }
}
