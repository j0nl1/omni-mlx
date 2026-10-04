import Foundation
import TOMLDecoder

public struct ServiceConfiguration: Decodable, Sendable {
    public let schemaVersion: Int
    public let server: ServerConfiguration
    public let admin: AdminConfiguration?
    public let mcp: MCPConfiguration?
    public let assets: AssetsConfiguration
    public let backends: [String: BackendConfiguration]
    public let resourceGroups: [String: ResourceConfiguration]
    public let models: [String: ModelConfiguration]
    public let voices: [String: VoiceConfiguration]
    enum CodingKeys: String, CodingKey {
        case server, admin, mcp, assets, backends, models, voices
        case schemaVersion = "schema_version", resourceGroups = "resource_groups"
    }
}

public struct MCPConfiguration: Decodable, Sendable {
    public let allowedOrigins: [String]
    enum CodingKeys: String, CodingKey { case allowedOrigins = "allowed_origins" }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowedOrigins = try container.decodeIfPresent([String].self, forKey: .allowedOrigins) ?? []
    }
}

public struct AdminConfiguration: Decodable, Sendable {
    public let port: Int
    public let keysFile: String
    public let audioAPIURL: String?
    enum CodingKeys: String, CodingKey { case port; case keysFile = "keys_file", audioAPIURL = "audio_api_url" }
}

public struct ServerConfiguration: Decodable, Sendable {
    public let host: String
    public let port: Int
    public let apiKeyEnv: String?
    public let maxUploadBytes: Int
    public let maxOutputBytes: Int
    public let maxTextCharacters: Int
    public let maxAudioSeconds: Double
    enum CodingKeys: String, CodingKey {
        case host, port
        case apiKeyEnv = "api_key_env", maxUploadBytes = "max_upload_bytes"
        case maxOutputBytes = "max_output_bytes", maxTextCharacters = "max_text_characters"
        case maxAudioSeconds = "max_audio_seconds"
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8080
        apiKeyEnv = try c.decodeIfPresent(String.self, forKey: .apiKeyEnv)
        maxUploadBytes = try c.decodeIfPresent(Int.self, forKey: .maxUploadBytes) ?? 25 * 1024 * 1024
        maxOutputBytes = try c.decodeIfPresent(Int.self, forKey: .maxOutputBytes) ?? 32 * 1024 * 1024
        maxTextCharacters = try c.decodeIfPresent(Int.self, forKey: .maxTextCharacters) ?? 8192
        maxAudioSeconds = try c.decodeIfPresent(Double.self, forKey: .maxAudioSeconds) ?? 600
    }
}
public struct AssetsConfiguration: Decodable, Sendable { public let root: String }
public struct BackendConfiguration: Decodable, Sendable {
    public enum Mode: String, Decodable, Sendable { case embedded, attached }
    public let mode: Mode
    public let resourceGroup: String
    public let baseURL: String?
    public let apiKeyEnv: String?
    enum CodingKeys: String, CodingKey {
        case mode
        case resourceGroup = "resource_group", baseURL = "base_url", apiKeyEnv = "api_key_env"
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(Mode.self, forKey: .mode)
        resourceGroup = try c.decode(String.self, forKey: .resourceGroup)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        apiKeyEnv = try c.decodeIfPresent(String.self, forKey: .apiKeyEnv)
    }
}
public struct ResourceConfiguration: Decodable, Sendable {
    public let maxInFlight: Int
    public let queueCapacity: Int
    public let requestTimeoutSeconds: Double
    enum CodingKeys: String, CodingKey {
        case maxInFlight = "max_in_flight", queueCapacity = "queue_capacity", requestTimeoutSeconds = "request_timeout_seconds"
    }
}
public struct ModelConfiguration: Decodable, Sendable {
    public let operation: AudioOperation
    public let backend: String
    public let source: String?
    public let profile: String?
    public let generation: GenerationConfiguration?
}
public struct GenerationConfiguration: Decodable, Sendable {
    public let maxTokens: Int?
    public let temperature: Float?
    public let topP: Float?
    public let topK: Int?
    public let repetitionPenalty: Float?
    public let maxSpeechSeconds: Double?
    enum CodingKeys: String, CodingKey {
        case temperature
        case maxTokens = "max_tokens", topP = "top_p", topK = "top_k"
        case repetitionPenalty = "repetition_penalty", maxSpeechSeconds = "max_speech_seconds"
    }
}
public struct VoiceConfiguration: Decodable, Sendable {
    public let displayName: String
    public let description: String?
    public let bindings: [String: VoiceBinding]
    enum CodingKeys: String, CodingKey { case description, bindings; case displayName = "display_name" }
}
public struct VoiceBinding: Decodable, Sendable {
    public enum Kind: String, Decodable, Sendable { case reference, preset }
    public let kind: Kind
    public let locale: String
    public let language: String?
    public let audio: String?
    public let transcript: String?
    public let preset: String?
}

public struct AudioCatalog: Sendable {
    public let configuration: ServiceConfiguration
    public let configurationURL: URL
    public let assetsURL: URL
    public let modelSources: [String: URL]
    public let referenceAudio: [String: URL]
    public let referenceText: [String: String]

    public static func load(_ url: URL) throws -> AudioCatalog {
        let url = url.standardizedFileURL
        let config: ServiceConfiguration
        do { config = try TOMLDecoder().decode(ServiceConfiguration.self, from: Data(contentsOf: url)) }
        catch { throw ServiceError("invalid_configuration", "Cannot decode configuration: \(error.localizedDescription)") }
        func invalid(_ key: String, _ reason: String) throws -> Never {
            throw ServiceError("invalid_configuration", "\(key): \(reason)")
        }
        guard config.schemaVersion == 1 else { try invalid("schema_version", "expected 1") }
        guard !config.backends.isEmpty, !config.models.isEmpty else { try invalid("models", "at least one model and backend are required") }
        guard !config.server.host.isEmpty, (1...65535).contains(config.server.port) else { try invalid("server", "invalid host or port") }
        guard (1...100 * 1024 * 1024).contains(config.server.maxUploadBytes),
              (1...100 * 1024 * 1024).contains(config.server.maxOutputBytes),
              (1...100_000).contains(config.server.maxTextCharacters),
              config.server.maxAudioSeconds.isFinite, (0.001...86400).contains(config.server.maxAudioSeconds) else {
            try invalid("server", "limits must be positive and bounded")
        }
        if let admin = config.admin {
            guard (1...65535).contains(admin.port), admin.port != config.server.port,
                  !admin.keysFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                try invalid("admin", "requires a separate valid port and a key store path")
            }
            if let value = admin.audioAPIURL {
                guard value.count <= 2048, let endpoint = URL(string: value),
                      ["http", "https"].contains(endpoint.scheme), let host = endpoint.host, !host.isEmpty,
                      endpoint.user == nil, endpoint.password == nil,
                      endpoint.query == nil, endpoint.fragment == nil else {
                    try invalid("admin.audio_api_url", "expected an HTTP(S) endpoint without credentials, query or fragment")
                }
            }
        }
        if let mcp = config.mcp {
            guard mcp.allowedOrigins.count <= 32 else { try invalid("mcp.allowed_origins", "at most 32 origins are supported") }
            for value in mcp.allowedOrigins {
                guard value.count <= 2048, let origin = URL(string: value),
                      ["http", "https"].contains(origin.scheme), let host = origin.host, !host.isEmpty,
                      !host.contains("*"), origin.user == nil, origin.password == nil,
                      origin.path.isEmpty, origin.query == nil, origin.fragment == nil else {
                    try invalid("mcp.allowed_origins", "expected exact HTTP(S) origins without paths, credentials or wildcards")
                }
            }
        }
        let parent = url.deletingLastPathComponent()
        func path(_ value: String) -> URL { URL(fileURLWithPath: value, relativeTo: parent).standardizedFileURL.resolvingSymlinksInPath() }
        let assets = path(config.assets.root)
        var sources: [String: URL] = [:]
        var referenceAudio: [String: URL] = [:], referenceText: [String: String] = [:]
        for (id, group) in config.resourceGroups {
            guard group.maxInFlight == 1 else { try invalid("resource_groups.\(id).max_in_flight", "initial native execution requires 1") }
            guard (0...10_000).contains(group.queueCapacity), group.requestTimeoutSeconds.isFinite,
                  group.requestTimeoutSeconds > 0 else { try invalid("resource_groups.\(id)", "invalid queue capacity or timeout") }
        }
        for (id, backend) in config.backends {
            guard config.resourceGroups[backend.resourceGroup] != nil else { try invalid("backends.\(id).resource_group", "unknown resource group") }
            switch backend.mode {
            case .embedded:
                break
            case .attached:
                guard let value = backend.baseURL, let u = URL(string: value),
                      ["http", "https"].contains(u.scheme), u.host != nil, u.user == nil, u.password == nil,
                      u.query == nil, u.fragment == nil else { try invalid("backends.\(id).base_url", "expected an HTTP(S) service origin without credentials") }
            }
        }
        for (id, model) in config.models {
            guard validID(id), let backend = config.backends[model.backend] else { try invalid("models.\(id)", "invalid alias or unknown backend") }
            if backend.mode == .embedded {
                guard let source = model.source, let profile = model.profile else { try invalid("models.\(id)", "local source and profile are required") }
                guard !profile.isEmpty else { try invalid("models.\(id).profile", "profile must not be empty") }
                let sourceURL = path(source)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else { try invalid("models.\(id).source", "missing model directory") }
                sources[id] = sourceURL
            }
            if let g = model.generation {
                guard (1...16_384).contains(g.maxTokens ?? 4096), (g.temperature ?? 0.9).isFinite,
                      (0...2).contains(g.temperature ?? 0.9), (g.topP ?? 1).isFinite,
                      (0...1).contains(g.topP ?? 1), (g.topP ?? 1) > 0,
                      (0...1000).contains(g.topK ?? 50), (g.repetitionPenalty ?? 1.05).isFinite,
                      (g.repetitionPenalty ?? 1.05) > 0, (g.maxSpeechSeconds ?? 300).isFinite,
                      (0.001...3600).contains(g.maxSpeechSeconds ?? 300) else { try invalid("models.\(id).generation", "invalid generation limits") }
            }
        }
        for (id, voice) in config.voices {
            guard validID(id), !voice.displayName.isEmpty, !voice.bindings.isEmpty else { try invalid("voices.\(id)", "invalid voice or empty bindings") }
            for (alias, binding) in voice.bindings {
                guard let model = config.models[alias], model.operation == .speech,
                      !binding.locale.isEmpty else { try invalid("voices.\(id).bindings.\(alias)", "requires a speech model and locale") }
                if config.backends[model.backend]?.mode == .attached { continue }
                let key = "\(id)/\(alias)"
                switch binding.kind {
                case .reference:
                    guard let audio = binding.audio, let transcript = binding.transcript else {
                        try invalid("voices.\(id).bindings.\(alias)", "reference conditioning requires audio and transcript")
                    }
                    func asset(_ value: String) throws -> URL {
                        let result = assets.appendingPathComponent(value).standardizedFileURL.resolvingSymlinksInPath()
                        guard !value.hasPrefix("/"), result.path.hasPrefix(assets.path + "/"),
                              FileManager.default.isReadableFile(atPath: result.path) else {
                            try invalid("voices.\(id).bindings.\(alias)", "missing asset or path outside assets.root")
                        }
                        return result
                    }
                    referenceAudio[key] = try asset(audio)
                    let text = try String(contentsOf: asset(transcript), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { try invalid("voices.\(id).bindings.\(alias).transcript", "empty transcript") }
                    referenceText[key] = text
                case .preset:
                    guard let preset = binding.preset, !preset.isEmpty else {
                        try invalid("voices.\(id).bindings.\(alias)", "preset binding requires a preset name")
                    }
                }
            }
        }
        return AudioCatalog(configuration: config, configurationURL: url, assetsURL: assets,
                            modelSources: sources, referenceAudio: referenceAudio, referenceText: referenceText)
    }

    public func resolveModel(_ alias: String, operation: AudioOperation) throws -> ModelConfiguration {
        guard let model = configuration.models[alias] else { throw ServiceError("unknown_model", "Unknown model alias: \(alias)") }
        guard model.operation == operation else { throw ServiceError("unsupported_operation", "Model \(alias) does not support \(operation.rawValue).") }
        return model
    }
    public func resolveVoice(_ id: String, model: String) throws -> VoiceBinding {
        guard let voice = configuration.voices[id] else { throw ServiceError("unknown_voice", "Unknown voice ID: \(id)") }
        guard let binding = voice.bindings[model] else { throw ServiceError("incompatible_voice", "Voice \(id) is not bound to model \(model).") }
        return binding
    }
    public var models: [ModelDescriptor] {
        configuration.models.sorted(by: { $0.key < $1.key }).map { ModelDescriptor(id: $0.key, operation: $0.value.operation) }
    }
    public var voices: [VoiceDescriptor] {
        configuration.voices.sorted(by: { $0.key < $1.key }).map {
            VoiceDescriptor(id: $0.key, displayName: $0.value.displayName, description: $0.value.description,
                            locales: Array(Set($0.value.bindings.values.map(\.locale))).sorted(), models: $0.value.bindings.keys.sorted())
        }
    }
    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0) }
    }
}
