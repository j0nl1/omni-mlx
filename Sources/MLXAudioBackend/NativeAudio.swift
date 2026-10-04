import Foundation
import AVFoundation
import AudioCore
import AudioRuntime
@preconcurrency import MLX
@preconcurrency import MLXAudioCore
@preconcurrency import MLXAudioTTS
@preconcurrency import MLXAudioSTT
import MLXLMCommon

@MainActor
final class NativeAudio: EmbeddedAudioEngine {
    private var running = false
    private let catalog: AudioCatalog
    private let backendID: String
    private var qwen: (alias: String, model: Qwen3TTSModel)?
    private var whisper: (alias: String, model: WhisperModel)?
    private var references: [String: MLXArray] = [:]

    init(catalog: AudioCatalog, backendID: String) throws {
        self.catalog = catalog; self.backendID = backendID
        guard catalog.configuration.backends[backendID]?.mode == .embedded else { throw ServiceError("invalid_configuration", "Native inference requires an embedded backend.") }
        for (alias, model) in catalog.configuration.models where model.backend == backendID {
            guard let source = catalog.modelSources[alias] else { throw ServiceError("invalid_configuration", "Missing local model source.") }
            let profiles = model.operation == .speech ? ["qwen3_base", "qwen3_custom_voice"] : ["whisper"]
            guard let profile = model.profile, profiles.contains(profile) else { throw ServiceError("unsupported_profile", "Unsupported profile in the native MLX audio adapter.") }
            let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            guard FileManager.default.fileExists(atPath: source.appendingPathComponent("config.json").path), files.contains(where: { $0.pathExtension == "safetensors" }) else {
                throw ServiceError("invalid_checkpoint_layout", "The native model requires config.json and safetensors weights.")
            }
            for voice in catalog.configuration.voices.values {
                if let binding = voice.bindings[alias] {
                    let expectedProfile = binding.kind == .reference ? "qwen3_base" : "qwen3_custom_voice"
                    guard profile == expectedProfile else { throw ServiceError("incompatible_voice", "The voice binding requires a matching native Qwen profile.") }
                }
            }
            if model.profile == "whisper" {
                guard FileManager.default.fileExists(atPath: source.appendingPathComponent("tokenizer.json").path) else {
                    throw ServiceError("missing_tokenizer", "Provision the Whisper tokenizer locally before starting the service.")
                }
            } else {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("config.json"))) as? [String: Any]
                let expected = model.profile == "qwen3_base" ? "base" : "custom_voice"
                guard object?["tts_model_type"] as? String == expected,
                      FileManager.default.fileExists(atPath: source.appendingPathComponent("speech_tokenizer/config.json").path) else {
                    throw ServiceError("incompatible_checkpoint", "The configured Qwen profile requires its matching checkpoint and speech tokenizer.")
                }
                guard FileManager.default.fileExists(atPath: source.appendingPathComponent("tokenizer.json").path) ||
                      (FileManager.default.fileExists(atPath: source.appendingPathComponent("vocab.json").path) &&
                       FileManager.default.fileExists(atPath: source.appendingPathComponent("merges.txt").path)) else {
                    throw ServiceError("missing_tokenizer", "Provision the Qwen tokenizer locally before starting the service.")
                }
                do { _ = try FileManager.default.contentsOfDirectory(at: source.appendingPathComponent("speech_tokenizer"), includingPropertiesForKeys: nil) }
                catch { throw ServiceError("invalid_checkpoint_layout", "Qwen speech_tokenizer must be a readable directory; materialize directory symlinks before startup.") }
            }
        }
        Memory.cacheLimit = 256 * 1024 * 1024
    }

    func start() { running = true }
    func ready() -> Bool { running }
    func shutdown() {
        running = false
        qwen = nil; whisper = nil; references.removeAll(); Memory.clearCache()
    }
    func generate(_ request: SpeechRequest, budget: RequestBudget) async throws -> Data {
        try budget.check()
        guard running else { throw ServiceError.unavailable }
        let model = try catalog.resolveModel(request.model, operation: .speech)
        guard model.backend == backendID else { throw ServiceError("wrong_backend", "The model belongs to another backend.") }
        let binding = try catalog.resolveVoice(request.voice, model: request.model)
        return try await speech(input: request.input, voice: request.voice, alias: request.model, binding: binding, model: model, budget: budget)
    }
    func transcribe(_ request: TranscriptionRequest, budget: RequestBudget) async throws -> TranscriptionResult {
        try budget.check()
        guard running else { throw ServiceError.unavailable }
        let model = try catalog.resolveModel(request.model, operation: .transcription)
        guard model.backend == backendID else { throw ServiceError("wrong_backend", "The model belongs to another backend.") }
        guard !request.audio.isEmpty, request.audio.count <= catalog.configuration.server.maxUploadBytes else {
            throw ServiceError("invalid_input", "Invalid or oversized audio upload.")
        }
        return TranscriptionResult(text: try await transcribe(request.audio, filename: request.filename, alias: request.model, language: request.language, model: model))
    }

    private func speech(input: String, voice: String, alias: String, binding: VoiceBinding, model: AudioCore.ModelConfiguration, budget: RequestBudget) async throws -> Data {
        guard !input.isEmpty, input.count <= catalog.configuration.server.maxTextCharacters else { throw ServiceError("invalid_input", "Invalid or oversized speech input.") }
        if qwen?.alias != alias {
            log("Loading configured Qwen checkpoint.")
            qwen = nil; whisper = nil; references.removeAll(); Memory.clearCache()
            qwen = (alias, try await Qwen3TTSModel.fromModelDirectory(catalog.modelSources[alias]!))
            log("Qwen checkpoint loaded.")
        }
        let engine = qwen!.model, key = "\(voice)/\(alias)"
        let refAudio: MLXArray?, refText: String?, preset: String?
        switch binding.kind {
        case .reference:
            guard let url = catalog.referenceAudio[key], let transcript = catalog.referenceText[key] else { throw ServiceError("invalid_configuration", "Missing reference voice assets.") }
            if references[key] == nil { references[key] = MLXArray(try monoAudio(url, sampleRate: engine.sampleRate, maxSeconds: 30)) }
            refAudio = references[key]; refText = transcript; preset = nil
        case .preset:
            refAudio = nil; refText = nil; preset = binding.preset
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog.modelSources[alias]!.appendingPathComponent("config.json"))) as? [String: Any]
            let talker = config?["talker_config"] as? [String: Any]
            let speakers = talker?["spk_id"] as? [String: Any]
            guard let preset, speakers?[preset.lowercased()] != nil else { throw ServiceError("unsupported_voice", "The configured preset is unavailable in this checkpoint.") }
        }
        let language = try qwenLanguage(binding.language ?? binding.locale.components(separatedBy: "-")[0])
        let settings = model.generation
        let parameters = GenerateParameters(maxTokens: settings?.maxTokens ?? 4096, temperature: settings?.temperature ?? 0.9,
                                            topP: settings?.topP ?? 1, topK: settings?.topK ?? 50, repetitionPenalty: settings?.repetitionPenalty ?? 1.05)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog.modelSources[alias]!.appendingPathComponent("config.json"))) as? [String: Any]
        guard let talker = object?["talker_config"] as? [String: Any], let eos = talker["codec_eos_token_id"] as? Int else {
            throw ServiceError("incompatible_checkpoint", "The Qwen checkpoint must expose its audio stop token.")
        }
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("result.wav")
        let writer = try PCMWriter(url: url, sampleRate: engine.sampleRate, maxBytes: catalog.configuration.server.maxOutputBytes,
                                   maxSeconds: settings?.maxSpeechSeconds ?? 300)
        try budget.check()
        var stopped = false
        var deferredFailure: (any Error)?
        log("Starting reference-conditioned speech generation.")
        for try await event in engine.generateStream(text: input, voice: preset, refAudio: refAudio, refText: refText,
                                                     language: language, generationParameters: parameters, streamingInterval: 1.0) {
            // Drain the SDK producer even after a deadline or a WAV limit failure.
            // Returning early would permit another request to overlap its GPU work.
            if deferredFailure != nil { continue }
            do {
                try budget.check()
                switch event {
                case .audio(let chunk): try writer.append(chunk.asArray(Float.self))
                case .token(let token): if token == eos { stopped = true }
                default: break
                }
            } catch { deferredFailure = error }
        }
        if let deferredFailure { throw deferredFailure }
        try budget.check()
        guard stopped else { throw ServiceError("generation_limit", "Speech reached its token limit before the stop token; incomplete audio was discarded.", status: 422) }
        try writer.finish(); Memory.clearCache()
        log("Speech generation completed; peak Metal allocation: \(Memory.peakMemory) bytes.")
        return try Data(contentsOf: url)
    }

    private func transcribe(_ bytes: Data, filename: String?, alias: String, language: String?, model: AudioCore.ModelConfiguration) async throws -> String {
        if whisper?.alias != alias {
            log("Loading configured Whisper checkpoint.")
            qwen = nil; whisper = nil; references.removeAll(); Memory.clearCache()
            whisper = (alias, try await WhisperModel.fromDirectory(catalog.modelSources[alias]!))
            log("Whisper checkpoint loaded.")
        }
        if let language {
            let configURL = catalog.modelSources[alias]!.appendingPathComponent("generation_config.json")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
            guard let languages = object?["lang_to_id"] as? [String: Any], languages["<|\(language)|>"] != nil else {
                throw ServiceError("unsupported_language", "The requested language is unavailable in this Whisper checkpoint.")
            }
        }
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ext = URL(fileURLWithPath: filename ?? "upload.wav").pathExtension.lowercased()
        let allowed = ["wav", "mp3", "m4a", "flac", "aiff", "aif", "caf"]
        guard allowed.contains(ext) else { throw ServiceError("unsupported_format", "Unsupported audio file extension.") }
        let url = directory.appendingPathComponent("upload.\(ext)")
        try bytes.write(to: url, options: .atomic)
        let audio: [Float]
        do { audio = try monoAudio(url, sampleRate: 16000, maxSeconds: catalog.configuration.server.maxAudioSeconds) }
        catch let error as ServiceError { throw error }
        catch { throw ServiceError("invalid_audio", "Cannot decode the supplied audio file.") }
        let settings = model.generation
        let parameters = STTGenerateParameters(maxTokens: settings?.maxTokens ?? 432, temperature: settings?.temperature ?? 0,
                                               topP: settings?.topP ?? 1, topK: settings?.topK ?? 0, language: language,
                                               chunkDuration: 30, minChunkDuration: 0.1, repetitionPenalty: settings?.repetitionPenalty ?? 1)
        let result = whisper!.model.generate(audio: MLXArray(audio), generationParameters: parameters)
        log("Transcription completed; peak Metal allocation: \(Memory.peakMemory) bytes.")
        Memory.clearCache(); return result.text
    }

    private func monoAudio(_ url: URL, sampleRate: Int, maxSeconds: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url), format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate
        guard duration.isFinite, duration > 0, duration <= maxSeconds, file.length <= Int64(UInt32.max) else {
            throw ServiceError("audio_duration_limit", "Audio duration exceeds its configured limit or is empty.", status: 413)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ServiceError("invalid_audio", "Cannot allocate the decoded audio buffer.")
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw ServiceError("invalid_audio", "Expected decodable PCM audio.") }
        var mono = [Float](repeating: 0, count: Int(buffer.frameLength))
        for channel in 0..<Int(format.channelCount) {
            for frame in mono.indices { mono[frame] += channels[channel][frame] / Float(format.channelCount) }
        }
        guard mono.allSatisfy(\.isFinite) else { throw ServiceError("invalid_audio", "Audio contains non-finite samples.") }
        return try resampleAudio(mono, from: Int(format.sampleRate), to: sampleRate)
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swift-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func log(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
    }
    private func qwenLanguage(_ value: String) throws -> String {
        let aliases = ["es": "spanish", "en": "english", "fr": "french", "de": "german", "it": "italian", "pt": "portuguese", "zh": "chinese", "ja": "japanese", "ko": "korean", "ru": "russian"]
        let lower = value.lowercased(), resolved = aliases[lower] ?? lower
        guard Set(aliases.values).contains(resolved) else { throw ServiceError("unsupported_language", "Unsupported Qwen speech language in the voice binding.") }
        return resolved
    }
}
