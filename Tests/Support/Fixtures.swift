import Foundation
import AudioCore

public struct CatalogFixture: Sendable {
    public let root: URL
    public let url: URL
    public let text: String
    public let catalog: AudioCatalog
    public init(mutate: (String) -> String = { $0 }) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["speech-model", "transcription-model"] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
            try Data().write(to: directory.appendingPathComponent("model.safetensors"))
        }
        let assets = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data("RIFF".utf8).write(to: assets.appendingPathComponent("reference.wav"))
        try Data("An English reference transcript.".utf8).write(to: assets.appendingPathComponent("reference.txt"))
        try Data("Outside asset directory.".utf8).write(to: root.appendingPathComponent("outside.txt"))
        url = root.appendingPathComponent("service.toml")
        text = mutate("""
        schema_version = 1
        [server]
        host = "127.0.0.1"
        port = 8080
        max_text_characters = 128
        max_upload_bytes = 1024
        max_output_bytes = 1024
        [assets]
        root = "assets"
        [backends.local]
        mode = "embedded"
        resource_group = "gpu"
        [resource_groups.gpu]
        max_in_flight = 1
        queue_capacity = 1
        request_timeout_seconds = 2
        [models.speech]
        operation = "speech"
        backend = "local"
        source = "speech-model"
        profile = "qwen3_base"
        [models.transcription]
        operation = "transcription"
        backend = "local"
        source = "transcription-model"
        profile = "whisper"
        [voices.alpha]
        display_name = "Alpha"
        [voices.alpha.bindings.speech]
        kind = "reference"
        locale = "en-US"
        audio = "reference.wav"
        transcript = "reference.txt"
        [voices.beta]
        display_name = "Beta"
        [voices.beta.bindings.speech]
        kind = "reference"
        locale = "en-GB"
        audio = "reference.wav"
        transcript = "reference.txt"
        """)
        try Data(text.utf8).write(to: url)
        do { catalog = try AudioCatalog.load(url) }
        catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    public func cleanup() { try? FileManager.default.removeItem(at: root) }
}

public actor StubAudio: SpeechGenerator, AudioTranscriber, BackendRuntime {
    public private(set) var requests = 0
    public init() {}
    public func start() {}
    public func ready() -> Bool { true }
    public func shutdown() {}
    public func generate(_ request: SpeechRequest, budget: RequestBudget) -> Data {
        requests += 1; return Data("RIFF-\(request.voice)".utf8)
    }
    public func transcribe(_ request: TranscriptionRequest, budget: RequestBudget) -> TranscriptionResult {
        requests += 1; return TranscriptionResult(text: "Transcribed fixture.")
    }
}
public func stubApplication(_ catalog: AudioCatalog, stub: StubAudio = StubAudio()) -> AudioApplication {
    AudioApplication(catalog: catalog, speech: ["local": stub], transcription: ["local": stub], runtimes: ["local": stub], queues: ["gpu": ResourceQueue(capacity: 1)])
}

public actor Latch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}
    public func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    public func open() { opened = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}
