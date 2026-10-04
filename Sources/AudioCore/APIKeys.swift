import Foundation

public struct APIKeyDescriptor: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let prefix: String
    public let createdAt: Int
    public var revokedAt: Int?
    public init(id: String, name: String, prefix: String, createdAt: Int, revokedAt: Int? = nil) {
        self.id = id; self.name = name; self.prefix = prefix; self.createdAt = createdAt; self.revokedAt = revokedAt
    }
    enum CodingKeys: String, CodingKey {
        case id, name, prefix
        case createdAt = "created_at", revokedAt = "revoked_at"
    }
}

public struct CreatedAPIKey: Codable, Sendable {
    public let key: APIKeyDescriptor
    public let secret: String
    public init(key: APIKeyDescriptor, secret: String) { self.key = key; self.secret = secret }
}

public protocol APIKeyManager: Sendable {
    func list() async -> [APIKeyDescriptor]
    func create(name: String) async throws -> CreatedAPIKey
    func revoke(id: String) async throws
    func authorizes(_ token: String) async -> Bool
}
