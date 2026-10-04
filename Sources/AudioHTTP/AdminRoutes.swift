import Foundation
import AudioCore
import Vapor

/// Applied only to the dedicated loopback listener, never to the public audio routes.
private struct LocalBrowserMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let authority = request.headers.first(name: .host),
              let url = URL(string: "http://" + authority),
              ["127.0.0.1", "localhost"].contains(url.host), url.user == nil, url.password == nil,
              url.path.isEmpty, url.query == nil, url.fragment == nil else {
            throw ServiceError("local_request_required", "Open the panel through its localhost address.", status: 403)
        }
        if let origin = request.headers.first(name: .origin), origin != "http://" + authority {
            throw ServiceError("local_request_required", "Only requests from this local panel are accepted.", status: 403)
        }
        if request.method != .GET && request.method != .HEAD {
            guard request.headers.first(name: "X-Omni-MLX-Local") == "1" else {
                throw ServiceError("local_request_required", "Local management requests require the panel's request header.", status: 403)
            }
        }
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        response.headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
        response.headers.replaceOrAdd(name: "Content-Security-Policy", value: "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; font-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        return response
    }
}

public func configureLocalAdminHTTP(_ app: Application, keys: any APIKeyManager, audioPort: Int, fixedKeyEnabled: Bool, audioAPIURL: String? = nil) {
    app.http.server.configuration.hostname = "127.0.0.1"
    app.routes.defaultMaxBodySize = "4kb"
    app.middleware.use(AudioErrorMiddleware())
    app.middleware.use(LocalBrowserMiddleware())
    struct KeyList: Content { let data: [APIKeyDescriptor]; let audio_api_url: String; let fixed_key_enabled: Bool }
    struct CreateKey: Content { let name: String }
    app.get("api", "keys") { _ async -> KeyList in
        KeyList(data: await keys.list(), audio_api_url: audioAPIURL ?? "http://127.0.0.1:\(audioPort)/v1", fixed_key_enabled: fixedKeyEnabled)
    }
    app.post("api", "keys") { request async throws -> Response in
        guard request.headers.contentType == .json else { throw ServiceError("invalid_request", "Expected a JSON key name.") }
        let created = try await keys.create(name: request.content.decode(CreateKey.self).name)
        let response = Response(status: .created)
        try response.content.encode(created, as: .json)
        return response
    }
    app.delete("api", "keys", ":id") { request async throws -> HTTPStatus in
        guard let id = request.parameters.get("id") else { throw ServiceError("unknown_api_key", "Missing key ID.", status: 404) }
        try await keys.revoke(id: id)
        return .noContent
    }
    app.get { _ throws -> Response in try adminAsset("index.html") }
    app.get("assets", ":file") { request throws -> Response in
        guard let name = request.parameters.get("file"), !name.contains("/"), !name.contains("\\"), !name.contains(".."),
              ["js", "css", "woff2", "woff"].contains(URL(fileURLWithPath: name).pathExtension) else { throw Abort(.notFound) }
        return try adminAsset("assets/" + name)
    }
}

private func adminAsset(_ path: String) throws -> Response {
    let root = Bundle.module.resourceURL!.appendingPathComponent("AdminUI")
    let url = root.appendingPathComponent(path)
    guard FileManager.default.isReadableFile(atPath: url.path) else { throw Abort(.notFound, reason: "UI assets are missing. Build web/ before compiling the server.") }
    let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8", "woff2": "font/woff2", "woff": "font/woff"]
    return Response(headers: ["Content-Type": types[url.pathExtension] ?? "application/octet-stream"], body: .init(data: try Data(contentsOf: url)))
}
