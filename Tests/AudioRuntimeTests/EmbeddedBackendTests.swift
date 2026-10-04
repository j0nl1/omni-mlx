import Foundation
import Testing
import AudioCore
import AudioRuntime
import AudioTestSupport

private actor ProbeEngine: EmbeddedAudioEngine {
    let entered = Latch()
    let release = Latch()
    var calls = 0
    var stopped = false
    var running = false
    func start() { running = true }
    func ready() -> Bool { running }
    func shutdown() { stopped = true; running = false }
    func generate(_ request: SpeechRequest, budget: RequestBudget) async throws -> Data {
        calls += 1
        if request.input == "blocked" { await entered.open(); await release.wait() }
        if request.input == "slow" { try await Task.sleep(for: .milliseconds(30)) }
        if request.input == "invalid" { throw ServiceError("invalid_audio", "Invalid fixture input.") }
        if request.input == "fault" { throw ServiceError("native_fault", "Native fixture fault.", status: 502) }
        return Data("RIFF-\(request.voice)".utf8)
    }
    func transcribe(_ request: TranscriptionRequest, budget: RequestBudget) -> TranscriptionResult {
        calls += 1
        return TranscriptionResult(text: "Transcribed fixture.")
    }
}

@Test func callerCancellationDrainsBeforeTheNextQueuedRequest() async throws {
    let engine = ProbeEngine(), adapter = EmbeddedBackend(engine: engine), queue = ResourceQueue(capacity: 1)
    try await adapter.start()
    let first = Task {
        let budget = RequestBudget(seconds: 2)
        return try await queue.withPermit(budget: budget) {
            try await adapter.generate(SpeechRequest(model: "speech", input: "blocked", voice: "alpha"), budget: budget)
        }
    }
    await engine.entered.wait()
    first.cancel()
    let second = Task {
        let budget = RequestBudget(seconds: 2)
        return try await queue.withPermit(budget: budget) {
            try await adapter.generate(SpeechRequest(model: "speech", input: "Hello", voice: "beta"), budget: budget)
        }
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(await engine.calls == 1)
    #expect(!(await engine.stopped))
    await engine.release.open()
    do { _ = try await first.value; Issue.record("Cancelled native request returned success.") }
    catch let error as ServiceError { #expect(error == .cancelled) }
    #expect(try await second.value == Data("RIFF-beta".utf8))
    #expect(await engine.calls == 2)
    await adapter.shutdown()
}

@Test func lateNativeCompletionRejectsSuccessWithoutPoisoningTheEngine() async throws {
    let engine = ProbeEngine(), adapter = EmbeddedBackend(engine: engine)
    try await adapter.start()
    let start = ContinuousClock.now
    do {
        _ = try await adapter.generate(SpeechRequest(model: "speech", input: "slow", voice: "alpha"), budget: RequestBudget(seconds: 0.01))
        Issue.record("Late native result returned success.")
    } catch let error as ServiceError { #expect(error == .deadline) }
    #expect(start.duration(to: .now) >= .milliseconds(30))
    #expect(await adapter.ready())
    #expect(try await adapter.generate(SpeechRequest(model: "speech", input: "Hello", voice: "beta"), budget: RequestBudget(seconds: 1)) == Data("RIFF-beta".utf8))
    await adapter.shutdown()
}

@Test func shutdownWaitsForNativeWorkBeforeDisposingTheEngine() async throws {
    let engine = ProbeEngine(), adapter = EmbeddedBackend(engine: engine)
    try await adapter.start()
    let request = Task { try await adapter.generate(SpeechRequest(model: "speech", input: "blocked", voice: "alpha"), budget: RequestBudget(seconds: 2)) }
    await engine.entered.wait()
    let shutdown = Task { await adapter.shutdown() }
    try await Task.sleep(for: .milliseconds(20))
    #expect(!(await adapter.ready()))
    #expect(!(await engine.stopped))
    await engine.release.open()
    _ = try await request.value; await shutdown.value
    #expect(await engine.stopped)
    #expect(!(await adapter.ready()))
}

@Test func inputRejectionsKeepTheNativeEngineUsable() async throws {
    let engine = ProbeEngine(), adapter = EmbeddedBackend(engine: engine)
    try await adapter.start()
    for _ in 0..<5 {
        do { _ = try await adapter.generate(SpeechRequest(model: "speech", input: "invalid", voice: "alpha"), budget: RequestBudget(seconds: 1)); Issue.record("Invalid native input succeeded.") }
        catch let error as ServiceError { #expect(error.code == "invalid_audio") }
    }
    #expect(await adapter.ready())
    #expect(try await adapter.generate(SpeechRequest(model: "speech", input: "Hello", voice: "alpha"), budget: RequestBudget(seconds: 1)) == Data("RIFF-alpha".utf8))
    await adapter.shutdown()
}

@Test func nativeFaultRejectsReuseUntilServiceRestart() async throws {
    let engine = ProbeEngine(), adapter = EmbeddedBackend(engine: engine)
    try await adapter.start()
    do { _ = try await adapter.generate(SpeechRequest(model: "speech", input: "fault", voice: "alpha"), budget: RequestBudget(seconds: 1)); Issue.record("Native fault returned success.") }
    catch let error as ServiceError { #expect(error.code == "native_fault") }
    #expect(!(await adapter.ready()))
    do { _ = try await adapter.generate(SpeechRequest(model: "speech", input: "Hello", voice: "alpha"), budget: RequestBudget(seconds: 1)); Issue.record("Faulted native engine was reused.") }
    catch let error as ServiceError { #expect(error == .unavailable) }
    #expect(await engine.calls == 1)
    await adapter.shutdown()
}

@Test func compositionInjectsTheEngineAndSupportsBothOperations() async throws {
    let fixture = try CatalogFixture(); defer { fixture.cleanup() }
    do { _ = try await makeAudioApplication(catalog: fixture.catalog); Issue.record("Embedded backend started without an engine factory.") }
    catch let error as ServiceError { #expect(error.code == "unsupported_backend") }
    let engine = ProbeEngine()
    let app = try await makeAudioApplication(catalog: fixture.catalog, embeddedEngineFactory: { _, id in
        #expect(id == "local")
        return engine
    })
    try await app.start()
    #expect(await app.ready())
    #expect(try await app.generate(SpeechRequest(model: "speech", input: "Hello", voice: "beta")) == Data("RIFF-beta".utf8))
    #expect(try await app.transcribe(TranscriptionRequest(model: "transcription", audio: Data("audio".utf8), filename: "sample.wav")).text == "Transcribed fixture.")
    await app.shutdown()
    #expect(!(await app.ready()))
}
