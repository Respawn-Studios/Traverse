import Darwin
import ExplorerCore
import Foundation
import Testing
@testable import FileMemory

@Test(arguments: [
    "UPDATE records SET revision=-1", "UPDATE records SET revision='one'",
    "UPDATE names SET original=CAST(x'FF' AS TEXT)", "UPDATE names SET original='hidden' || char(0) || 'suffix'",
    "UPDATE names SET ordinal=17", "UPDATE names SET field=99",
    "UPDATE records SET sort_key=x'31'", "DELETE FROM name_keys",
    "INSERT INTO revocations VALUES('not-an-id',0)", "UPDATE store_header SET all_pending=2"
])
func privateNamesRejectMalformedStoredRowsWithoutWriting(_ corruption: String) async throws {
    let fixture = try NameStoreFixture()
    let store = try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "Guarded"))
    await store.close(); try fixture.databaseSQL(corruption)
    let original = try fixture.image()
    #expect(await PersistentNameStore.inspect(directory: fixture.catalog).status == .unsafe)
    #expect(try fixture.image() == original)
    await #expect(throws: (any Error).self) { try await PersistentNameStore.open(directory: fixture.catalog) }
    #expect(try fixture.image() == original)
}

@Test(arguments: ["schema", "sidecar", "hardlink", "permission", "missing", "acl"])
func privateNamesRefuseUnsafeOrUnknownNamespacesWithoutRepair(_ scenario: String) async throws {
    let fixture = try NameStoreFixture()
    let store = try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "Private"))
    await store.close()
    switch scenario {
    case "schema": try fixture.databaseSQL("PRAGMA user_version=99")
    case "sidecar": try Data([1]).write(to: fixture.catalog.appendingPathComponent("names.sqlite-wal"), options: .withoutOverwriting)
    case "hardlink": #expect(link(fixture.catalog.appendingPathComponent("names.sqlite").path, fixture.child("retained-link").path) == 0)
    case "permission": #expect(chmod(fixture.catalog.appendingPathComponent("names.sqlite").path, 0o644) == 0)
    case "missing": try FileManager().moveItem(at: fixture.catalog.appendingPathComponent("names.sqlite"), to: fixture.child("preserved.sqlite"))
    case "acl":
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow read", fixture.catalog.path]
        try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
    default: Issue.record("Unexpected fixture case")
    }
    let before = try fixture.image()
    let observation = await PersistentNameStore.inspect(directory: fixture.catalog)
    #expect(observation.status != .ready)
    #expect(try fixture.image() == before)
    await #expect(throws: (any Error).self) { try await PersistentNameStore.open(directory: fixture.catalog, action: .edit) }
    #expect(try fixture.image() == before)
}

@Test func privateNamesRefuseSymlinkAndInSessionReplacementOrInPlaceChange() async throws {
    let fixture = try NameStoreFixture()
    let store = try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "Pinned"))
    let id = try await store.firstItemID()
    try FileManager().moveItem(at: fixture.catalog, to: fixture.child("original"))
    try FileManager().createSymbolicLink(at: fixture.catalog, withDestinationURL: fixture.child("original"))
    await #expect(throws: (any Error).self) { try await store.snapshot(id) }
    #expect(await PersistentNameStore.inspect(directory: fixture.catalog).status != .ready)
    await store.close()
    let second = try NameStoreFixture()
    let live = try await PersistentNameStore.create(directory: second.catalog, first: AuthoredNames(nickname: "Current"))
    try second.databaseSQL("UPDATE records SET revision=revision+1")
    await #expect(throws: NameStoreFailure.changed) { try await live.query(RememberedNameQuery(text: "Current")) }
    await live.close()
}

@Test func privateNamesFirstSaveDoesNotAdoptAnExistingEmptyLeafAndRespectsActivityAdmission() async throws {
    let fixture = try NameStoreFixture()
    try FileManager().createDirectory(at: fixture.catalog, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    await #expect(throws: (any Error).self) { try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "No adoption")) }
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.catalog.path).isEmpty)
    let activity = FileActivityGate(), token = try #require(activity.closeAdmission())
    let other = fixture.child("other")
    await #expect(throws: (any Error).self) { try await PersistentNameStore.create(directory: other, first: AuthoredNames(nickname: "Blocked"), activity: activity) }
    #expect(!FileManager().fileExists(atPath: other.path))
    #expect(activity.ownsDrainedAdmission(token))
}

@Test func privateNamesUnknownFormatCannotAuthorizeRecoveryEvenWithAPossiblyHotJournal() async throws {
    let fixture = try NameStoreFixture()
    let store = try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "Unchanged"))
    await store.close(); try fixture.databaseSQL("PRAGMA user_version=99")
    // This is a refusal fixture, not a genuine SQLite-hot-recovery claim.
    var journal = Data([0xd9,0xd5,0x05,0xf9,0x20,0xa1,0x63,0xd7]); journal.append(Data(count: 504))
    let path = fixture.catalog.appendingPathComponent("names.sqlite-journal")
    try journal.write(to: path, options: .withoutOverwriting); #expect(chmod(path.path, 0o600) == 0)
    let before = try fixture.image()
    #expect(await PersistentNameStore.inspect(directory: fixture.catalog).status == .unsupported)
    await #expect(throws: NameStoreFailure.unsupported) { try await PersistentNameStore.open(directory: fixture.catalog, action: .recover) }
    #expect(try fixture.image() == before)
}
