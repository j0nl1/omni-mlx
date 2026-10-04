import Foundation
import AudioCore

public typealias EmbeddedEngineFactory = @Sendable (AudioCatalog, String) async throws -> any EmbeddedAudioEngine

public func makeAudioApplication(catalog: AudioCatalog,
                                 environment: [String: String] = ProcessInfo.processInfo.environment,
                                 embeddedEngineFactory: EmbeddedEngineFactory? = nil) async throws -> AudioApplication {
    let queues = catalog.configuration.resourceGroups.mapValues { ResourceQueue(capacity: $0.queueCapacity) }
    var speech: [String: any SpeechGenerator] = [:], transcription: [String: any AudioTranscriber] = [:], runtimes: [String: any BackendRuntime] = [:]
    for (id, backend) in catalog.configuration.backends {
        switch backend.mode {
        case .embedded:
            guard let embeddedEngineFactory else {
                throw ServiceError("unsupported_backend", "Embedded inference is unavailable in this build; use an attached backend.", status: 503)
            }
            let adapter = EmbeddedBackend(engine: try await embeddedEngineFactory(catalog, id))
            speech[id] = adapter; transcription[id] = adapter; runtimes[id] = adapter
        case .attached:
            let key: String?
            if let name = backend.apiKeyEnv {
                guard let value = environment[name], !value.isEmpty else { throw ServiceError("invalid_configuration", "backends.\(id).api_key_env: required environment variable is missing") }
                key = value
            } else { key = nil }
            let adapter = AttachedBackend(origin: URL(string: backend.baseURL!)!, apiKey: key, catalog: catalog, backendID: id, queue: queues[backend.resourceGroup]!)
            speech[id] = adapter; transcription[id] = adapter; runtimes[id] = adapter
        }
    }
    return AudioApplication(catalog: catalog, speech: speech, transcription: transcription, runtimes: runtimes, queues: queues)
}
