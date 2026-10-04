import Foundation
import Testing
import Vapor
import VaporTesting
import AudioCore
import AudioHTTP
import AudioTestSupport

private let mcpFixture = "\n[mcp]\nallowed_origins = [\"https://audio.example.test\"]\n"
private let mcpHeaders: HTTPHeaders = ["Host": "127.0.0.1:8080", "Accept": "application/json, text/event-stream", "Content-Type": "application/json", "Authorization": "Bearer client-key"]

private func rpc(_ method: String, parameters: [String: Any] = [:], id: Int = 1) throws -> ByteBuffer {
    ByteBuffer(data: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": parameters]))
}
private func json(_ body: ByteBuffer) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(body.readableBytesView)) as? [String: Any])
}

@Test func mcpInitializeAcceptsNestedExperimentalClientCapabilities() async throws {
    let fixture = try CatalogFixture(mutate: { $0 + mcpFixture }); defer { fixture.cleanup() }
    try await withApp(configure: { configureAudioHTTP($0, audio: stubApplication(fixture.catalog), apiKey: "client-key") }) { app in
        let parameters: [String: Any] = [
            "protocolVersion": "2025-11-25",
            "clientInfo": ["name": "mcp-client-omni-mlx", "version": "1.0.0"],
            "capabilities": ["experimental": ["io.modelcontextprotocol/ui": ["mimeTypes": ["text/html;profile=mcp-app"]]]],
        ]
        try await app.testing().test(.POST, "mcp", headers: mcpHeaders, body: rpc("initialize", parameters: parameters, id: 0), afterResponse: { res in
            #expect(res.status == .ok)
            let envelope = try json(res.body)
            #expect(envelope["error"] == nil)
            #expect(envelope["id"] as? Int == 0)
            let result = try #require(envelope["result"] as? [String: Any])
            #expect(result["protocolVersion"] as? String == "2025-11-25")
            let capabilities = try #require(result["capabilities"] as? [String: Any])
            #expect(capabilities["tools"] != nil)
            #expect(capabilities["experimental"] == nil)
        })
        try await app.testing().test(.POST, "mcp", headers: mcpHeaders, body: rpc("tools/list"), afterResponse: { res in
            let result = try #require(try json(res.body)["result"] as? [String: Any])
            #expect((result["tools"] as? [[String: Any]])?.count == 4)
        })
    }
}

@Test func mcpNegotiationDiscoveryAndHTTPValidationUseAudioAuthorization() async throws {
    let fixture = try CatalogFixture(mutate: { $0 + mcpFixture }); defer { fixture.cleanup() }
    let audio = stubApplication(fixture.catalog)
    try await withApp(configure: { configureAudioHTTP($0, audio: audio, apiKey: "client-key") }) { app in
        try await app.testing().test(.POST, "mcp", headers: ["Host": "127.0.0.1:8080"], body: rpc("tools/list"), afterResponse: { res in
            #expect(res.status == .unauthorized)
        })
        try await app.testing().test(.POST, "mcp", headers: mcpHeaders, body: rpc("initialize", parameters: ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "test-client", "version": "1"]]), afterResponse: { res in
            #expect(res.status == .ok)
            let result = try #require(try json(res.body)["result"] as? [String: Any])
            #expect(result["protocolVersion"] as? String == "2025-11-25")
            let capabilities = try #require(result["capabilities"] as? [String: Any])
            #expect(capabilities["tools"] != nil)
        })
        try await app.testing().test(.POST, "mcp", headers: mcpHeaders, body: rpc("tools/list"), afterResponse: { res in
            #expect(res.status == .ok)
            let result = try #require(try json(res.body)["result"] as? [String: Any])
            let tools = try #require(result["tools"] as? [[String: Any]])
            #expect(Set(tools.compactMap { $0["name"] as? String }) == ["list_models", "list_voices", "generate_speech", "transcribe_audio"])
        })
        for (header, value, expected) in [("Origin", "https://evil.example", HTTPResponseStatus.forbidden), ("Host", "evil.example", .misdirectedRequest), ("Mcp-Protocol-Version", "unsupported", .badRequest), ("Accept", "text/plain", .notAcceptable)] {
            var headers = mcpHeaders; headers.replaceOrAdd(name: header, value: value)
            try await app.testing().test(.POST, "mcp", headers: headers, body: rpc("tools/list"), afterResponse: { res in #expect(res.status == expected) })
        }
        try await app.testing().test(.GET, "mcp", headers: mcpHeaders, afterResponse: { res in #expect(res.status == .methodNotAllowed) })
        for invalid in ["{", "{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"tools/list\"}", "{\"jsonrpc\":\"3.0\",\"id\":1,\"method\":\"tools/list\"}"] {
            try await app.testing().test(.POST, "mcp", headers: mcpHeaders, body: ByteBuffer(string: invalid), afterResponse: { res in #expect(res.status == .badRequest) })
        }
        try await app.testing().test(.POST, "mcp", headers: mcpHeaders, body: ByteBuffer(string: "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"), afterResponse: { res in #expect(res.status == .accepted) })
    }
}

@Test func mcpAudioToolsReturnAudioAndTranscriptsAndRejectInvalidInputBeforeInference() async throws {
    let fixture = try CatalogFixture(mutate: { $0 + mcpFixture }); defer { fixture.cleanup() }
    let stub = StubAudio(), audio = stubApplication(fixture.catalog, stub: stub)
    try await withApp(configure: { configureAudioHTTP($0, audio: audio, apiKey: "client-key") }) { app in
        let arguments: [String: Any] = ["model": "speech", "voice": "beta", "input": "Hello"]
        try await app.testing().test(.POST, "mcp", headers: mcpHeaders, body: rpc("tools/call", parameters: ["name": "generate_speech", "arguments": arguments]), afterResponse: { res in
            #expect(res.status == .ok)
            let result = try #require(try json(res.body)["result"] as? [String: Any])
            let content = try #require(result["content"] as? [[String: Any]])
            #expect(content[0]["type"] as? String == "audio")
            #expect(content[0]["mimeType"] as? String == "audio/wav")
            #expect(content[0]["data"] as? String == Data("RIFF-beta".utf8).base64EncodedString())
        })
        try await app.testing().test(.POST, "mcp", headers: mcpHeaders, body: rpc("tools/call", parameters: ["name": "transcribe_audio", "arguments": ["model": "transcription", "filename": "sample.wav", "audio_base64": Data("RIFF".utf8).base64EncodedString(), "language": "en"]]), afterResponse: { res in
            let result = try #require(try json(res.body)["result"] as? [String: Any])
            let output = try #require(result["structuredContent"] as? [String: Any])
            #expect(output["text"] as? String == "Transcribed fixture.")
        })
        for invalid: [String: Any] in [
            ["name": "generate_speech", "arguments": ["model": "speech", "voice": "missing", "input": "Hello"]],
            ["name": "generate_speech", "arguments": ["model": "speech", "voice": "alpha", "input": "Hello", "speed": 2]],
            ["name": "transcribe_audio", "arguments": ["model": "transcription", "filename": "sample.wav", "audio_base64": "invalid"]],
            ["name": "transcribe_audio", "arguments": ["model": "transcription", "filename": "/private/sample.wav", "audio_base64": "UklGRg=="]],
            ["name": "transcribe_audio", "arguments": ["model": "transcription", "filename": "sample.wav", "audio_base64": Data(repeating: 1, count: 1025).base64EncodedString()]],
        ] {
            try await app.testing().test(.POST, "mcp", headers: mcpHeaders, body: rpc("tools/call", parameters: invalid), afterResponse: { res in
                #expect(res.status == .ok)
                let result = try #require(try json(res.body)["result"] as? [String: Any])
                #expect(result["isError"] as? Bool == true)
            })
        }
    }
    #expect(await stub.requests == 2)
}

@Test func mcpIsOptInAndIndependentClientsCanReuseRequestIDs() async throws {
    let disabled = try CatalogFixture(); defer { disabled.cleanup() }
    try await withApp(configure: { configureAudioHTTP($0, audio: stubApplication(disabled.catalog), apiKey: "client-key") }) { app in
        try await app.testing().test(.POST, "mcp", headers: mcpHeaders, body: rpc("tools/list"), afterResponse: { res in #expect(res.status == .notFound) })
    }
    let enabled = try CatalogFixture(mutate: { $0 + mcpFixture }); defer { enabled.cleanup() }
    try await withApp(configure: { configureAudioHTTP($0, audio: stubApplication(enabled.catalog), apiKey: "client-key") }) { app in
        async let models = app.testing().test(.POST, "mcp", headers: mcpHeaders, body: rpc("tools/call", parameters: ["name": "list_models"]), afterResponse: { res in
            let result = try #require(try json(res.body)["result"] as? [String: Any])
            #expect((result["structuredContent"] as? [String: Any])?["models"] != nil)
        })
        async let voices = app.testing().test(.POST, "mcp", headers: mcpHeaders, body: rpc("tools/call", parameters: ["name": "list_voices"]), afterResponse: { res in
            let result = try #require(try json(res.body)["result"] as? [String: Any])
            #expect((result["structuredContent"] as? [String: Any])?["voices"] != nil)
        })
        _ = try await (models, voices)
    }
}
