import Foundation
import AudioCore
import MCP

struct AudioTools: Sendable {
    let audio: AudioApplication

    var tools: [Tool] {
        let catalog = audio.catalog
        let textLimit = catalog.configuration.server.maxTextCharacters
        let base64Limit = ((catalog.configuration.server.maxUploadBytes + 2) / 3) * 4
        let model = { (operation: AudioOperation) in
            Value.object(["type": .string("string"), "enum": .array(catalog.models.filter { $0.operation == operation }.map { .string($0.id) })])
        }
        return [
            Tool(name: "list_models", description: "List configured audio model IDs and their operations.", inputSchema: schema([:]), annotations: .init(readOnlyHint: true, openWorldHint: false)),
            Tool(name: "list_voices", description: "List curated voices, languages and compatible model IDs.", inputSchema: schema([:]), annotations: .init(readOnlyHint: true, openWorldHint: false)),
            Tool(name: "generate_speech", description: "Generate speech using a configured voice. Returns an inline WAV audio content block.", inputSchema: schema([
                "model": model(.speech),
                "voice": .object(["type": .string("string"), "enum": .array(catalog.voices.map { .string($0.id) })]),
                "input": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(textLimit)]),
            ], required: ["model", "voice", "input"]), annotations: .init(readOnlyHint: true, openWorldHint: false)),
            Tool(name: "transcribe_audio", description: "Transcribe supplied audio bytes. Pass plain base64 and a filename with its audio extension; server paths and remote URLs are not accepted.", inputSchema: schema([
                "model": model(.transcription),
                "audio_base64": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(base64Limit)]),
                "filename": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(255)]),
                "language": .object(["type": .string("string"), "pattern": .string("^[a-z]{2}$")]),
            ], required: ["model", "audio_base64", "filename"]), annotations: .init(readOnlyHint: true, openWorldHint: false)),
        ]
    }

    func call(_ parameters: CallTool.Parameters) async throws -> CallTool.Result {
        guard let tool = tools.first(where: { $0.name == parameters.name }) else {
            throw MCPError.invalidParams("Unknown audio tool.")
        }
        let arguments = parameters.arguments ?? [:]
        do {
            let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            guard Set(arguments.keys).isSubset(of: Set(properties.keys)) else {
                throw ServiceError("unsupported_option", "The tool received unsupported arguments.")
            }
            switch parameters.name {
            case "list_models":
                return try jsonResult(["models": try Value(audio.catalog.models)])
            case "list_voices":
                return try jsonResult(["voices": try Value(audio.catalog.voices)])
            case "generate_speech":
                let output = try await audio.generate(SpeechRequest(model: string("model", arguments), input: string("input", arguments), voice: string("voice", arguments)))
                return .init(content: [.audio(data: output.base64EncodedString(), mimeType: "audio/wav", annotations: nil, _meta: nil)], isError: false)
            case "transcribe_audio":
                let encoded = try string("audio_base64", arguments)
                let maximum = audio.catalog.configuration.server.maxUploadBytes
                guard encoded.utf8.count <= ((maximum + 2) / 3) * 4 else {
                    throw ServiceError("input_too_large", "Audio upload exceeds the configured limit.", status: 413)
                }
                guard let bytes = Data(base64Encoded: encoded), !bytes.isEmpty else {
                    throw ServiceError("invalid_input", "Supply plain base64-encoded audio bytes.")
                }
                let filename = try string("filename", arguments)
                guard filename.count <= 255, !filename.contains("/"), !filename.contains("\\"),
                      !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw ServiceError("invalid_input", "Supply an audio filename without a path.")
                }
                let language = try arguments["language"].map { value -> String in
                    guard let result = value.stringValue else { throw ServiceError("invalid_input", "language must be a string.") }
                    return result
                }
                let result = try await audio.transcribe(TranscriptionRequest(model: string("model", arguments), audio: bytes, filename: filename, language: language))
                return .init(content: [.text(text: result.text, annotations: nil, _meta: nil)], structuredContent: Optional.some(try Value(result)), isError: false)
            default:
                throw MCPError.invalidParams("Unknown audio tool.")
            }
        } catch let error as ServiceError {
            return .init(content: [.text(text: error.message, annotations: nil, _meta: nil)], structuredContent: .object(["code": .string(error.code)]), isError: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .init(content: [.text(text: "The audio operation could not be completed.", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private func string(_ name: String, _ arguments: [String: Value]) throws -> String {
        guard let result = arguments[name]?.stringValue, !result.isEmpty else {
            throw ServiceError("invalid_input", "\(name) must be a non-empty string.")
        }
        return result
    }

    private func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(Value.string)), "additionalProperties": .bool(false)])
    }

    private func jsonResult(_ object: [String: Value]) throws -> CallTool.Result {
        let value = Value.object(object)
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: Optional.some(value), isError: false)
    }
}
