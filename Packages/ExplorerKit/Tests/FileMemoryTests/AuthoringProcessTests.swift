import Darwin
import Foundation
import NameStoreFaultSupport
import SQLite3
import Testing
@testable import FileMemory

/// Fresh generated-only children; no termination or VFS fault code in the app.
@Test func b073AuthoringProcessWorker() async throws {
    let env = ProcessInfo.processInfo.environment
    guard NameStoreFixture.authoringPacket, let path = env["MAC_EXPLORER_B073_ROOT"],
          let phase = env["MAC_EXPLORER_B073_PHASE"], let scenario = env["MAC_EXPLORER_B073_SCENARIO"] else { return }
    let fixture = try NameStoreFixture(existingRoot: URL(fileURLWithPath: path)), source = fixture.child("Generated.txt")
    @Sendable func tracked() throws -> Bool { var info = stat(); guard lstat(source.path, &info) == 0 else { throw NameStoreFailure.unavailable }; return info.st_flags & UInt32(UF_TRACKED) != 0 }
    @Sendable func receipt(_ values: [String: String]) throws {
        var value = values; value["phase"] = phase; value["scenario"] = scenario
        let url = fixture.child(phase + ".json")
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .withoutOverwriting)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw NameStoreFailure.unavailable }
        defer { Darwin.close(fd) }; guard fsync(fd) == 0 else { throw NameStoreFailure.unavailable }
    }
    if phase == "seed" { try Data("Generated B07.3 crash source".utf8).write(to: source, options: .withoutOverwriting); try receipt(["tracked": String(try tracked())]); return }
    if phase == "crash" {
        let boundary: NameStoreBoundary = scenario == "beforeFlag" ? .sourceCapture : scenario == "afterFlag" ? .sourcePrepared : .firstCommit
        _ = try await PersistentNameStore.createRemembering(directory: fixture.catalog, first: AuthoredNames(nickname: "Generated description"),
            source: source, allowDocumentFollowing: true, probe: { observed in
                if observed == boundary { try receipt(["terminationCode": "86", "tracked": String(try tracked())]); _exit(86) }
            }, vfs: nil)
        Issue.record("Requested crash boundary was not reached"); return
    }
    if phase == "fault" {
        #expect(menames_fault_register(fixture.root.path) == SQLITE_OK)
        var failed = false
        do {
            _ = try await PersistentNameStore.createRemembering(directory: fixture.catalog, first: AuthoredNames(nickname: "Generated description"),
                source: source, allowDocumentFollowing: true, probe: { if $0 == .sourcePrepared { menames_fault_arm(2, 1, 2) } }, vfs: "menames-generated-faults")
        } catch { failed = true }
        #expect(failed && menames_fault_hits() == 1)
        #expect(try tracked())
        try receipt(["failed": String(failed), "hits": String(menames_fault_hits()), "tracked": String(try tracked())]); return
    }
    if phase == "inspect" {
        let exists = FileManager().fileExists(atPath: fixture.catalog.path), before = exists ? try fixture.image() : [:]
        let result = await PersistentNameStore.inspect(directory: fixture.catalog)
        if exists { #expect(try fixture.image() == before) } else { #expect(result.status == .absent && !FileManager().fileExists(atPath: fixture.catalog.path)) }
        #expect(try tracked() == (scenario != "beforeFlag"))
        try receipt(["status": String(describing: result.status), "unchanged": "true", "tracked": String(try tracked())]); return
    }
    if phase == "recover" || phase == "cold" {
        if scenario == "committedNames" {
            let store = try await PersistentNameStore.open(directory: fixture.catalog, action: phase == "recover" ? .recover : .readOnly)
            let page = try await store.query(RememberedNameQuery(text: "Generated description"))
            #expect(try storedMatches(page).count == 1)
            await store.close()
        } else if !FileManager().fileExists(atPath: fixture.catalog.path) {
            #expect(await PersistentNameStore.inspect(directory: fixture.catalog).status == .absent)
        } else {
            // A failed first transaction is preserved; never recreate/adopt it.
            await #expect(throws: (any Error).self) { try await PersistentNameStore.open(directory: fixture.catalog, action: .recover) }
        }
        try receipt(["preserved": "true", "tracked": String(try tracked())]); return
    }
    Issue.record("Unknown authoring worker phase")
}
