import Foundation
import Testing
import Vapor
import VaporTesting
import AudioCore
import AudioHTTP
import AudioRuntime
import AudioTestSupport

@Test func managedKeysProtectAudioAndAdminRoutesStayOffPublicListener() async throws {
    let fixture = try CatalogFixture(); defer { fixture.cleanup() }
    let keys = try FileAPIKeyStore(url: fixture.root.appendingPathComponent("keys.json"))
    let created = try await keys.create(name: "Engine")
    let stub = StubAudio(), audio = stubApplication(fixture.catalog, stub: stub)
    try await withApp(configure: { app in configureAudioHTTP(app, audio: audio, apiKey: nil, apiKeys: keys) }) { app in
        for path in ["v1/models", "v1/voices"] {
            try await app.testing().test(.GET, path, afterResponse: { res in #expect(res.status == .unauthorized) })
            try await app.testing().test(.GET, path, headers: ["Authorization": "Bearer \(created.secret)"], afterResponse: { res in #expect(res.status == .ok) })
        }
        try await app.testing().test(.POST, "v1/audio/speech", headers: ["Content-Type": "application/json", "Authorization": "Bearer \(created.secret)"], body: ByteBuffer(string: "{\"model\":\"speech\",\"input\":\"Hello\",\"voice\":\"alpha\"}"), afterResponse: { res in #expect(res.status == .ok) })
        try await keys.revoke(id: created.key.id)
        try await app.testing().test(.GET, "v1/models", headers: ["Authorization": "Bearer \(created.secret)"], afterResponse: { res in #expect(res.status == .unauthorized) })
        for path in ["api/keys", "", "admin"] {
            try await app.testing().test(.GET, path, afterResponse: { res in #expect(res.status == .notFound) })
        }
    }
    #expect(await stub.requests == 1)
}

@Test func localAdminHasNoLoginAndRejectsForeignHostsAndOrigins() async throws {
    let fixture = try CatalogFixture(); defer { fixture.cleanup() }
    let keys = try FileAPIKeyStore(url: fixture.root.appendingPathComponent("keys.json"))
    let created = try await keys.create(name: "Existing key")
    let local: HTTPHeaders = ["Host": "127.0.0.1:8081"]
    try await withApp(configure: { app in configureLocalAdminHTTP(app, keys: keys, audioPort: 8080, fixedKeyEnabled: false) }) { app in
        try await app.testing().test(.GET, "api/keys", headers: local, afterResponse: { res in
            #expect(res.status == .ok)
            #expect(res.body.string.contains("Existing key"))
            #expect(!res.body.string.contains(created.secret))
            #expect(res.headers.first(name: .cacheControl) == "no-store")
            let catalog = try JSONSerialization.jsonObject(with: Data(res.body.string.utf8)) as? [String: Any]
            #expect(catalog?["audio_api_url"] as? String == "http://127.0.0.1:8080/v1")
        })
        for headers: HTTPHeaders in [
            ["Host": "evil.example:8081"],
            ["Host": "127.0.0.1:8081", "Origin": "https://evil.example"],
        ] {
            try await app.testing().test(.GET, "api/keys", headers: headers, afterResponse: { res in #expect(res.status == .forbidden) })
        }
        try await app.testing().test(.POST, "api/keys", headers: ["Host": "127.0.0.1:8081", "Content-Type": "application/json"], body: ByteBuffer(string: "{\"name\":\"Blocked\"}"), afterResponse: { res in #expect(res.status == .forbidden) })
        let mutation: HTTPHeaders = ["Host": "127.0.0.1:8081", "Origin": "http://127.0.0.1:8081", "X-Omni-MLX-Local": "1", "Content-Type": "application/json"]
        try await app.testing().test(.POST, "api/keys", headers: mutation, body: ByteBuffer(string: "{\"name\":\"New client\"}"), afterResponse: { res in
            #expect(res.status == .created)
            let result = try res.content.decode(CreatedAPIKey.self)
            #expect(result.key.name == "New client")
            #expect(result.secret.hasPrefix("omlx_"))
        })
        try await app.testing().test(.DELETE, "api/keys/\(created.key.id)", headers: mutation, afterResponse: { res in #expect(res.status == .noContent) })
        try await app.testing().test(.GET, "v1/models", headers: local, afterResponse: { res in #expect(res.status == .notFound) })
        try await app.testing().test(.GET, "", headers: local, afterResponse: { res in #expect(res.status == .ok); #expect(res.headers.contentType?.type == "text") })
    }
    #expect(!(await keys.authorizes(created.secret)))
}

@Test func localAdminAdvertisesConfiguredAudioEndpointWithoutRelaxingHostChecks() async throws {
    let fixture = try CatalogFixture(); defer { fixture.cleanup() }
    let keys = try FileAPIKeyStore(url: fixture.root.appendingPathComponent("keys.json"))
    try await withApp(configure: { app in
        configureLocalAdminHTTP(app, keys: keys, audioPort: 8080, fixedKeyEnabled: false, audioAPIURL: "https://audio.example.test/v1")
    }) { app in
        try await app.testing().test(.GET, "api/keys", headers: ["Host": "127.0.0.1:8081"], afterResponse: { res in
            #expect(res.status == .ok)
            let catalog = try JSONSerialization.jsonObject(with: Data(res.body.string.utf8)) as? [String: Any]
            #expect(catalog?["audio_api_url"] as? String == "https://audio.example.test/v1")
        })
        try await app.testing().test(.GET, "api/keys", headers: ["Host": "audio.example.test"], afterResponse: { res in
            #expect(res.status == .forbidden)
        })
    }
}
