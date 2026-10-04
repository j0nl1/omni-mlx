import Foundation

public enum AudioOperation: String, Codable, Sendable { case speech, transcription }

public struct ServiceError: Error, Codable, Sendable, Equatable, LocalizedError {
    public let code: String
    public let message: String
    public let status: Int
    public init(_ code: String, _ message: String, status: Int = 400) {
        self.code = code; self.message = message; self.status = status
    }
    public var errorDescription: String? { message }
    public static let cancelled = ServiceError("request_cancelled", "The request was cancelled.", status: 499)
    public static let deadline = ServiceError("deadline_exceeded", "The request deadline was exceeded.", status: 504)
    public static let unavailable = ServiceError("backend_unavailable", "The configured audio backend is unavailable.", status: 503)
}

public struct SpeechRequest: Codable, Sendable {
    public let model: String
    public let input: String
    public let voice: String
    public let responseFormat: String
    public init(model: String, input: String, voice: String, responseFormat: String = "wav") {
        self.model = model; self.input = input; self.voice = voice; self.responseFormat = responseFormat
    }
    enum CodingKeys: String, CodingKey { case model, input, voice; case responseFormat = "response_format" }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        input = try c.decode(String.self, forKey: .input)
        voice = try c.decode(String.self, forKey: .voice)
        responseFormat = try c.decodeIfPresent(String.self, forKey: .responseFormat) ?? "wav"
    }
}

public struct TranscriptionRequest: Sendable {
    public let model: String
    public let audio: Data
    public let filename: String
    public let language: String?
    public init(model: String, audio: Data, filename: String, language: String? = nil) {
        self.model = model; self.audio = audio; self.filename = filename; self.language = language
    }
}

public struct TranscriptionResult: Codable, Sendable, Equatable {
    public let text: String
    public init(text: String) { self.text = text }
}

public struct RequestBudget: Sendable {
    public let deadline: ContinuousClock.Instant
    public init(seconds: Double) { deadline = ContinuousClock.now.advanced(by: .seconds(seconds)) }
    public var remainingSeconds: Double {
        let c = ContinuousClock.now.duration(to: deadline).components
        return max(0, Double(c.seconds) + Double(c.attoseconds) / 1e18)
    }
    public func check() throws {
        if Task.isCancelled { throw ServiceError.cancelled }
        if remainingSeconds <= 0 { throw ServiceError.deadline }
    }
}

public protocol SpeechGenerator: Sendable {
    func generate(_ request: SpeechRequest, budget: RequestBudget) async throws -> Data
}
public protocol AudioTranscriber: Sendable {
    func transcribe(_ request: TranscriptionRequest, budget: RequestBudget) async throws -> TranscriptionResult
}
public protocol BackendRuntime: Sendable {
    func start() async throws
    func ready() async -> Bool
    func shutdown() async
}

public struct ModelDescriptor: Codable, Sendable {
    public let id: String
    public let object: String
    public let ownedBy: String
    public let created: Int
    public let operation: AudioOperation
    public init(id: String, operation: AudioOperation) {
        self.id = id; self.operation = operation; object = "model"; ownedBy = "configured"; created = 0
    }
    enum CodingKeys: String, CodingKey { case id, object, operation, created; case ownedBy = "owned_by" }
}
public struct VoiceDescriptor: Codable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String?
    public let locales: [String]
    public let models: [String]
    enum CodingKeys: String, CodingKey { case id, description, locales, models; case displayName = "display_name" }
}
