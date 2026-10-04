import Foundation
import Testing
import Vapor
import VaporTesting
import AudioHTTP
import AudioCore
import AudioTestSupport

@Test func authenticatedAudioRoutesExposeConfiguredVoicesAndNoChat() async throws {
    let fixture = try CatalogFixture(); defer { fixture.cleanup() }
    let audio = stubApplication(fixture.catalog)
    try await withApp(configure: { app in configureAudioHTTP(app, audio: audio, apiKey: "test-key") }) { app in
        try await app.testing().test(.GET, "v1/voices", afterResponse: { res in #expect(res.status == .unauthorized) })
        try await app.testing().test(.GET, "v1/voices", headers: ["Authorization": "Bearer test-key"], afterResponse: { res in
            #expect(res.status == .ok); #expect(res.body.string.contains("beta")); #expect(!res.body.string.contains(fixture.root.path))
        })
        try await app.testing().test(.POST, "v1/chat/completions", afterResponse: { res in #expect(res.status == .notFound) })
        try await app.testing().test(.POST, "v1/embeddings", afterResponse: { res in #expect(res.status == .notFound) })
        try await app.testing().test(.POST, "v1/audio/speech", headers: ["Authorization": "Bearer test-key", "Content-Type": "application/json"], body: ByteBuffer(string: "{\"model\":\"speech\",\"input\":\"Hello\",\"voice\":\"beta\"}"), afterResponse: { res in
            #expect(res.status == .ok); #expect(res.headers.contentType?.subType == "wav"); #expect(res.body.string == "RIFF-beta")
        })
    }
}
@Test func speechRejectsMalformedJSONAndUnsupportedOptions() async throws {
    let fixture = try CatalogFixture(); defer { fixture.cleanup() }
    let stub = StubAudio(), audio = stubApplication(fixture.catalog, stub: stub)
    try await withApp(configure: { app in configureAudioHTTP(app, audio: audio, apiKey: nil) }) { app in
        for body in ["{broken", "{\"model\":\"speech\",\"input\":\"Hello\",\"voice\":\"alpha\",\"speed\":1}"] {
            try await app.testing().test(.POST, "v1/audio/speech", headers: ["Content-Type": "application/json"], body: ByteBuffer(string: body), afterResponse: { res in
                #expect(res.status == .badRequest); #expect(res.body.string.contains("error"))
            })
        }
    }
    #expect(await stub.requests == 0)
}
@Test func multipartTranscriptionWorksAndRejectsUnimplementedOptions() async throws {
    let fixture = try CatalogFixture(); defer { fixture.cleanup() }
    let audio = stubApplication(fixture.catalog)
    func multipart(extra: String) -> String {
        "--boundary\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ntranscription\r\n--boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"sample.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF\r\n\(extra)--boundary--\r\n"
    }
    try await withApp(configure: { app in configureAudioHTTP(app, audio: audio, apiKey: nil) }) { app in
        try await app.testing().test(.POST, "v1/audio/transcriptions", headers: ["Content-Type": "multipart/form-data; boundary=boundary"], body: ByteBuffer(string: multipart(extra: "")), afterResponse: { res in
            #expect(res.status == .ok); #expect(res.body.string.contains("Transcribed fixture."))
        })
        let extra = "--boundary\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nHint\r\n"
        try await app.testing().test(.POST, "v1/audio/transcriptions", headers: ["Content-Type": "multipart/form-data; boundary=boundary"], body: ByteBuffer(string: multipart(extra: extra)), afterResponse: { res in
            #expect(res.status == .badRequest); #expect(res.body.string.contains("unsupported_option"))
        })
    }
}
