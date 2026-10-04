import Foundation
import AudioCore
import MCP
import Vapor

private struct WireMethod: MCP.Method {
    static let name = ""
    typealias Parameters = Value
    typealias Result = Value
}

public func configureAudioMCP(_ routes: any RoutesBuilder, audio: AudioApplication, configuration: MCPConfiguration) {
    let port = audio.catalog.configuration.server.port
    let origins = ["http://127.0.0.1:\(port)", "http://localhost:\(port)"] + configuration.allowedOrigins
    let hosts = origins.compactMap { value -> String? in
        guard let url = URL(string: value), let host = url.host else { return nil }
        return url.port.map { "\(host):\($0)" } ?? host
    }
    let pipeline = StandardValidationPipeline(validators: [
        OriginValidator(allowedHosts: hosts, allowedOrigins: origins),
        AcceptHeaderValidator(mode: .jsonOnly), ContentTypeValidator(), ProtocolVersionValidator(),
    ])
    let maximum = ((audio.catalog.configuration.server.maxUploadBytes + 2) / 3) * 4 + 262144
    let tools = AudioTools(audio: audio)
    routes.on(.POST, "mcp", body: .collect(maxSize: ByteCount(value: maximum))) { request async throws -> Vapor.Response in
        let body = request.body.data.map { Data($0.readableBytesView) }
        // Reject malformed envelopes before the SDK can wait for an unmatched response ID.
        guard let body, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              object["jsonrpc"] as? String == "2.0", object["method"] is String,
              object["id"] == nil || (try? JSONDecoder().decode(MCP.Request<WireMethod>.self, from: body)) != nil else {
            return response(.error(statusCode: 400, .parseError("Expected one valid JSON-RPC request or notification.")))
        }
        // Each HTTP request owns its transport so independent clients may reuse JSON-RPC IDs.
        let server = MCP.Server(name: "omni-mlx", version: "0.1.0", capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools.tools) }
        await server.withMethodHandler(CallTool.self) { parameters in try await tools.call(parameters) }
        let transport = StatelessHTTPServerTransport(validationPipeline: pipeline)
        try await server.start(transport: transport)
        var headers: [String: String] = [:]
        for (name, value) in request.headers { headers[name] = value }
        let result = await transport.handleRequest(MCP.HTTPRequest(method: "POST", headers: headers, body: try sdkRequestBody(body, envelope: object)))
        await server.stop()
        return response(result)
    }
    for method in [HTTPMethod.GET, .DELETE] {
        routes.on(method, "mcp") { _ -> Vapor.Response in
            let result = response(.error(statusCode: 405, .invalidRequest("This stateless endpoint accepts POST only.")))
            result.headers.replaceOrAdd(name: .allow, value: "POST")
            return result
        }
    }
}

private func sdkRequestBody(_ body: Data, envelope: [String: Any]) throws -> Data {
    guard envelope["method"] as? String == "initialize",
          var parameters = envelope["params"] as? [String: Any],
          var capabilities = parameters["capabilities"] as? [String: Any],
          capabilities["experimental"] is [String: Any] else { return body }
    // SDK 0.12.1 models experimental values as strings, but MCP allows nested JSON.
    // This server supports no experimental extensions; ignore them before SDK decoding.
    capabilities.removeValue(forKey: "experimental")
    parameters["capabilities"] = capabilities
    var normalized = envelope
    normalized["params"] = parameters
    return try JSONSerialization.data(withJSONObject: normalized)
}

private func response(_ result: MCP.HTTPResponse) -> Vapor.Response {
    var headers = HTTPHeaders()
    for (name, value) in result.headers { headers.replaceOrAdd(name: name, value: value) }
    headers.replaceOrAdd(name: .cacheControl, value: "no-store")
    return Vapor.Response(status: .init(statusCode: result.statusCode), headers: headers, body: .init(data: result.bodyData ?? Data()))
}
