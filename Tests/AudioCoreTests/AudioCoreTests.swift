import Foundation
import Testing
@testable import AudioCore
import AudioTestSupport

@Test func configuredVoicesResolveWithoutFallbackAndRejectWrongOperations() throws {
    let fixture = try CatalogFixture(); defer { fixture.cleanup() }
    #expect(fixture.catalog.voices.map(\.id) == ["alpha", "beta"])
    #expect(try fixture.catalog.resolveVoice("beta", model: "speech").locale == "en-GB")
    #expect(throws: ServiceError.self) { try fixture.catalog.resolveVoice("missing", model: "speech") }
    #expect(throws: ServiceError.self) { try fixture.catalog.resolveModel("transcription", operation: .speech) }
    #expect(throws: ServiceError.self) { try fixture.catalog.resolveVoice("alpha", model: "transcription") }
}
@Test func rejectsEscapingAssetsAndDuplicateTOMLKeys() throws {
    #expect(throws: ServiceError.self) { try CatalogFixture(mutate: { $0.replacingOccurrences(of: "transcript = \"reference.txt\"", with: "transcript = \"../outside.txt\"") }) }
    #expect(throws: ServiceError.self) { try CatalogFixture(mutate: { $0.replacingOccurrences(of: "schema_version = 1", with: "schema_version = 1\nschema_version = 1") }) }
    #expect(throws: ServiceError.self) { try CatalogFixture(mutate: { $0.replacingOccurrences(of: "max_in_flight = 1", with: "max_in_flight = 2") }) }
}
@Test func administrationEndpointMustBeHTTPWithoutEmbeddedCredentials() throws {
    let admin = "\n[admin]\nport = 8081\nkeys_file = \"keys.json\"\n"
    let fixture = try CatalogFixture(mutate: { $0 + admin + "audio_api_url = \"https://audio.example.test/v1\"\n" })
    defer { fixture.cleanup() }
    #expect(fixture.catalog.configuration.admin?.audioAPIURL == "https://audio.example.test/v1")
    for endpoint in ["file:///tmp/audio", "https://client:secret@audio.example.test/v1", "https://audio.example.test/v1?key=secret", "https://audio.example.test/v1#fragment"] {
        #expect(throws: ServiceError.self) { try CatalogFixture(mutate: { $0 + admin + "audio_api_url = \"\(endpoint)\"\n" }) }
    }
}
@Test func mcpOriginsRejectPathsCredentialsAndWildcards() throws {
    for origin in ["https://audio.example.test/v1", "https://client:secret@audio.example.test", "https://*.example.test", "file:///tmp"] {
        #expect(throws: ServiceError.self) { try CatalogFixture(mutate: { $0 + "\n[mcp]\nallowed_origins = [\"\(origin)\"]\n" }) }
    }
}
@Test func invalidRequestsDoNotReachInference() async throws {
    let fixture = try CatalogFixture(); defer { fixture.cleanup() }
    let stub = StubAudio(), app = stubApplication(fixture.catalog, stub: stub)
    for request in [SpeechRequest(model: "speech", input: "Hello", voice: "missing"),
                    SpeechRequest(model: "speech", input: "Hello", voice: "alpha", responseFormat: "mp3"),
                    SpeechRequest(model: "speech", input: String(repeating: "a", count: 129), voice: "alpha")] {
        do { _ = try await app.generate(request); Issue.record("Invalid request reached inference.") }
        catch { #expect(error is ServiceError) }
    }
    #expect(await stub.requests == 0)
    let result = try await app.generate(SpeechRequest(model: "speech", input: "Hello", voice: "beta"))
    #expect(result == Data("RIFF-beta".utf8))
}
@Test func sharedQueueBoundsCapacityAndCancelledWaitersReleaseTheirPlaces() async throws {
    let queue = ResourceQueue(capacity: 1), entered = Latch(), release = Latch()
    let first = Task { try await queue.withPermit(budget: RequestBudget(seconds: 5)) { await entered.open(); await release.wait(); return 1 } }
    await entered.wait()
    let second = Task { try await queue.withPermit(budget: RequestBudget(seconds: 5)) { 2 } }
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while await queue.queuedRequests == 0 && ContinuousClock.now < deadline { await Task.yield() }
    #expect(await queue.queuedRequests == 1)
    do { _ = try await queue.withPermit(budget: RequestBudget(seconds: 1)) { 3 }; Issue.record("Queue capacity was exceeded.") }
    catch let error as ServiceError { #expect(error.code == "queue_full") }
    second.cancel()
    do { _ = try await second.value; Issue.record("Cancelled waiter ran.") }
    catch let error as ServiceError { #expect(error.code == "request_cancelled") }
    await release.open(); #expect(try await first.value == 1)
    #expect(try await queue.withPermit(budget: RequestBudget(seconds: 1)) { 4 } == 4)
}
@Test func queueWaitCountsAgainstDeadline() async throws {
    let queue = ResourceQueue(capacity: 1), entered = Latch(), release = Latch()
    let first = Task { try await queue.withPermit(budget: RequestBudget(seconds: 5)) { await entered.open(); await release.wait(); return true } }
    await entered.wait()
    do { _ = try await queue.withPermit(budget: RequestBudget(seconds: 0.02)) { false }; Issue.record("Expired queued request ran.") }
    catch let error as ServiceError { #expect(error.code == "deadline_exceeded") }
    await release.open(); _ = try await first.value
}

@Test func lateAdapterSuccessIsRejectedAndReleasesThePermit() async throws {
    let queue = ResourceQueue(capacity: 1)
    do {
        _ = try await queue.withPermit(budget: RequestBudget(seconds: 0.01)) {
            try await Task.sleep(for: .milliseconds(30))
            return true
        }
        Issue.record("Late adapter success bypassed the request deadline.")
    } catch let error as ServiceError { #expect(error.code == "deadline_exceeded") }
    #expect(try await queue.withPermit(budget: RequestBudget(seconds: 1)) { true })
}
