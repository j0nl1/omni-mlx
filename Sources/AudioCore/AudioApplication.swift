import Foundation

public struct AudioApplication: Sendable {
    public let catalog: AudioCatalog
    private let speech: [String: any SpeechGenerator]
    private let transcription: [String: any AudioTranscriber]
    private let runtimes: [String: any BackendRuntime]
    private let queues: [String: ResourceQueue]

    public init(catalog: AudioCatalog, speech: [String: any SpeechGenerator], transcription: [String: any AudioTranscriber],
                runtimes: [String: any BackendRuntime], queues: [String: ResourceQueue]) {
        self.catalog = catalog; self.speech = speech; self.transcription = transcription; self.runtimes = runtimes; self.queues = queues
    }
    public func generate(_ request: SpeechRequest) async throws -> Data {
        let model = try catalog.resolveModel(request.model, operation: .speech)
        _ = try catalog.resolveVoice(request.voice, model: request.model)
        guard !request.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError("invalid_input", "Speech input must not be empty.") }
        guard request.input.count <= catalog.configuration.server.maxTextCharacters else { throw ServiceError("input_too_large", "Speech text exceeds the configured limit.", status: 413) }
        guard request.responseFormat == "wav" else { throw ServiceError("unsupported_option", "Only response_format=wav is supported.") }
        guard let backend = catalog.configuration.backends[model.backend], let adapter = speech[model.backend],
              let queue = queues[backend.resourceGroup] else { throw ServiceError.unavailable }
        let budget = RequestBudget(seconds: catalog.configuration.resourceGroups[backend.resourceGroup]!.requestTimeoutSeconds)
        let output = try await queue.withPermit(budget: budget) { try await adapter.generate(request, budget: budget) }
        guard output.count <= catalog.configuration.server.maxOutputBytes else { throw ServiceError("output_too_large", "Generated audio exceeds the configured limit.", status: 413) }
        return output
    }
    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let model = try catalog.resolveModel(request.model, operation: .transcription)
        guard !request.audio.isEmpty else { throw ServiceError("invalid_input", "Audio input must not be empty.") }
        guard request.audio.count <= catalog.configuration.server.maxUploadBytes else { throw ServiceError("input_too_large", "Audio upload exceeds the configured limit.", status: 413) }
        if let language = request.language {
            guard language.count == 2, language.utf8.allSatisfy({ (97...122).contains($0) }) else {
                throw ServiceError("unsupported_language", "Use a lowercase two-letter language code.")
            }
        }
        guard let backend = catalog.configuration.backends[model.backend], let adapter = transcription[model.backend],
              let queue = queues[backend.resourceGroup] else { throw ServiceError.unavailable }
        let budget = RequestBudget(seconds: catalog.configuration.resourceGroups[backend.resourceGroup]!.requestTimeoutSeconds)
        return try await queue.withPermit(budget: budget) { try await adapter.transcribe(request, budget: budget) }
    }
    public func ready() async -> Bool {
        for runtime in runtimes.values { if !(await runtime.ready()) { return false } }
        for queue in queues.values { if !(await queue.ready()) { return false } }
        return true
    }
    public func start() async throws {
        do { for runtime in runtimes.values { try await runtime.start() } }
        catch { await shutdown(); throw error }
    }
    public func shutdown() async { for runtime in runtimes.values { await runtime.shutdown() } }
}
