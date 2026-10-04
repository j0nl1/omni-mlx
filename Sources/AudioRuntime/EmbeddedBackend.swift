import Foundation
import AudioCore

/// The native engine stays behind the same ports as the remote HTTP adapter.
public protocol EmbeddedAudioEngine: SpeechGenerator, AudioTranscriber, BackendRuntime {}

/// Owns an in-process engine and holds its resource permit until inference finishes.
public actor EmbeddedBackend: SpeechGenerator, AudioTranscriber, BackendRuntime {
    private let engine: any EmbeddedAudioEngine
    private var started = false
    private var stopping = false
    private var faulted = false
    private var active: Task<Void, Never>?

    public init(engine: any EmbeddedAudioEngine) { self.engine = engine }

    public func start() async throws {
        guard !stopping, !faulted else { throw ServiceError.unavailable }
        try await engine.start()
        started = true
    }
    public func ready() async -> Bool {
        guard started, !stopping, !faulted else { return false }
        return await engine.ready()
    }
    public func shutdown() async {
        stopping = true
        // The SDK can continue GPU work after a client cancels. Drain before disposal.
        await active?.value
        await engine.shutdown()
        started = false
    }
    public func generate(_ request: SpeechRequest, budget: RequestBudget) async throws -> Data {
        try await execute(budget: budget) { try await $0.generate(request, budget: budget) }
    }
    public func transcribe(_ request: TranscriptionRequest, budget: RequestBudget) async throws -> TranscriptionResult {
        try await execute(budget: budget) { try await $0.transcribe(request, budget: budget) }
    }
    private func execute<T: Sendable>(budget: RequestBudget,
                                    operation: @escaping @Sendable (any EmbeddedAudioEngine) async throws -> T) async throws -> T {
        try budget.check()
        guard started, !stopping, !faulted, active == nil else { throw ServiceError.unavailable }
        let engine = self.engine
        // Cancellation of the caller must not abandon an unjoined native producer.
        let work = Task.detached { try await operation(engine) }
        active = Task { _ = await work.result }
        defer { active = nil }
        let result: T
        do { result = try await work.value }
        catch let error as ServiceError {
            if error.status >= 500 && error != .deadline { faulted = true }
            throw error
        } catch is CancellationError {
            throw ServiceError.cancelled
        } catch {
            faulted = true
            try? FileHandle.standardError.write(contentsOf: Data("Embedded inference failed: \(String(reflecting: error))\n".utf8))
            throw ServiceError("inference_failed", "Native audio inference failed; inspect the service logs and restart the service.", status: 502)
        }
        try budget.check()
        return result
    }
}
