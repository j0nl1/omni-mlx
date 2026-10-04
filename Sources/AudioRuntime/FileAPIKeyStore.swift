import Foundation
import Crypto
import AudioCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One server process owns a store. Secrets are returned once; only SHA-256 digests persist.
public actor FileAPIKeyStore: APIKeyManager {
    private struct Record: Codable { var key: APIKeyDescriptor; let digest: String }
    private struct Document: Codable { let version: Int; let keys: [Record] }
    private let url: URL
    private var records: [Record]

    public init(url: URL) throws {
        self.url = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
                guard document.version == 1, document.keys.count <= 1000,
                      Set(document.keys.map { $0.key.id }).count == document.keys.count,
                      document.keys.allSatisfy({ $0.digest.count == 64 && $0.digest.allSatisfy { $0.isHexDigit } }) else {
                    throw ServiceError("invalid_key_store", "The API key store has an unsupported or invalid format.")
                }
                records = document.keys
            } catch {
                throw ServiceError("invalid_key_store", "Cannot load the API key store; refusing to start.", status: 500)
            }
        } else { records = [] }
    }

    public func list() -> [APIKeyDescriptor] {
        records.map(\.key).sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }

    public func create(name: String) throws -> CreatedAPIKey {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ServiceError("invalid_key_name", "Use a key name between 1 and 80 characters.")
        }
        guard records.count < 1000 else { throw ServiceError("key_limit_reached", "The store has reached its 1,000-key limit.", status: 409) }
        let id = UUID().uuidString.lowercased()
        let prefix = "omlx_" + id.prefix(8)
        var random = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }
        let secret = prefix + "_" + Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let key = APIKeyDescriptor(id: id, name: name, prefix: prefix, createdAt: Int(Date().timeIntervalSince1970))
        let next = records + [Record(key: key, digest: Self.digest(secret))]
        try persist(next)
        records = next
        return CreatedAPIKey(key: key, secret: secret)
    }

    public func revoke(id: String) throws {
        guard let index = records.firstIndex(where: { $0.key.id == id }) else {
            throw ServiceError("unknown_api_key", "This API key does not exist.", status: 404)
        }
        guard records[index].key.revokedAt == nil else { return }
        var next = records
        next[index].key.revokedAt = Int(Date().timeIntervalSince1970)
        try persist(next)
        records = next
    }

    public func authorizes(_ token: String) -> Bool {
        guard token.utf8.count <= 256 else { return false }
        let digest = Array(Self.digest(token).utf8)
        return records.contains { record in
            guard record.key.revokedAt == nil else { return false }
            let stored = Array(record.digest.utf8)
            guard stored.count == digest.count else { return false }
            var difference: UInt8 = 0
            for i in digest.indices { difference |= digest[i] ^ stored[i] }
            return difference == 0
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func persist(_ next: [Record]) throws {
        do {
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let temporary = parent.appendingPathComponent(".keys-" + UUID().uuidString + ".tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(atPath: temporary.path, contents: try encoder.encode(Document(version: 1, keys: next)), attributes: [.posixPermissions: 0o600]),
                  rename(temporary.path, url.path) == 0 else {
                throw ServiceError("key_store_unavailable", "Cannot replace the API key store.", status: 500)
            }
        } catch {
            throw ServiceError("key_store_unavailable", "Cannot save API keys. Check the key store's directory and permissions.", status: 500)
        }
    }
}
