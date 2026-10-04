import Foundation
import Testing
import AudioCore
import AudioRuntime
import AudioTestSupport

@Test func keysPersistAsDigestsAndRevocationSurvivesRestart() async throws {
    let fixture = try CatalogFixture(); defer { fixture.cleanup() }
    let url = fixture.root.appendingPathComponent("state/keys.json")
    let keys = try FileAPIKeyStore(url: url)
    let created = try await keys.create(name: "  Local engine  ")
    #expect(created.key.name == "Local engine")
    #expect(await keys.authorizes(created.secret))
    #expect(!(await keys.authorizes(created.secret + "x")))
    let disk = try String(contentsOf: url, encoding: .utf8)
    #expect(!disk.contains(created.secret))
    #expect(!disk.contains("\"secret\""))
    #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let reloaded = try FileAPIKeyStore(url: url)
    #expect(await reloaded.authorizes(created.secret))
    try await reloaded.revoke(id: created.key.id)
    #expect(!(await reloaded.authorizes(created.secret)))
    let restarted = try FileAPIKeyStore(url: url)
    #expect(!(await restarted.authorizes(created.secret)))
    #expect(await restarted.list().first?.revokedAt != nil)
    try await restarted.revoke(id: created.key.id)
}

@Test func invalidNamesCorruptStoresAndFailedWritesFailClosed() async throws {
    let fixture = try CatalogFixture(); defer { fixture.cleanup() }
    let url = fixture.root.appendingPathComponent("keys.json")
    let keys = try FileAPIKeyStore(url: url)
    for name in ["  ", String(repeating: "a", count: 81), "name\nsecond"] {
        await #expect(throws: ServiceError.self) { try await keys.create(name: name) }
    }
    #expect(await keys.list().isEmpty)
    await #expect(throws: ServiceError.self) { try await keys.revoke(id: "missing") }
    try Data("{broken".utf8).write(to: url)
    #expect(throws: ServiceError.self) { try FileAPIKeyStore(url: url) }
    let blocker = fixture.root.appendingPathComponent("file")
    try Data().write(to: blocker)
    let failing = try FileAPIKeyStore(url: blocker.appendingPathComponent("keys.json"))
    await #expect(throws: ServiceError.self) { try await failing.create(name: "Cannot persist") }
    #expect(await failing.list().isEmpty)
}
