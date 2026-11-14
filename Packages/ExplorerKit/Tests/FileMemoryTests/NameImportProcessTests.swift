import Darwin
import Foundation
import NameStoreFaultSupport
import SQLite3
import Testing
@testable import FileMemory

@Test func b075ImportProcessWorker() async throws {
    let env = ProcessInfo.processInfo.environment
    guard MoveFixture.enabled, MoveFixture.extended, let path = env["MAC_EXPLORER_B074_ROOT"],
          let scenario = env["MAC_EXPLORER_B074_SCENARIO"], let phase = env["MAC_EXPLORER_B074_PHASE"] else { return }
    let f = try MoveFixture(existingRoot: URL(fileURLWithPath: path)), initial = scenario.hasPrefix("initial")
    let boundary = String(scenario.dropFirst(initial ? 7 : 8))
    let file = f.source.appendingPathComponent("saved-names.json")
    @Sendable func receipt(_ values: [String: String]) throws {
        var values = values; values["scenario"] = scenario; values["phase"] = phase
        let url = f.root.appendingPathComponent(phase + ".json")
        try JSONSerialization.data(withJSONObject: values, options: .sortedKeys).write(to: url, options: .withoutOverwriting)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw NameStoreFailure.unsafe }
        defer { close(fd) }; guard fsync(fd) == 0 else { throw NameStoreFailure.unsafe }
    }
    if phase == "seed" {
        _ = try writeImport(f, rows: (0..<3).map { row(UUID(), "Imported \($0)") })
        if !initial {
            let store = try await PersistentNameStore.create(directory: f.catalog, first: AuthoredNames(nickname: "Keep existing"))
            await store.close()
        }
        try receipt(["seeded": "true"]); return
    }
    if phase == "crash" {
        let target: NameImportTarget
        if initial { target = .newCatalog(directory: f.catalog) }
        else { target = .existing(try await PersistentNameStore.open(directory: f.catalog, action: .edit)) }
        let session = NameImportSession(target: target), preview = try await session.preview(selectedFile: file)
        _ = await session.apply(preview, probe: {
            if $0.rawValue == boundary { try receipt(["boundary": boundary]); Darwin._exit(86) }
        })
        Issue.record("Import crash boundary missed"); return
    }
    if phase == "fault" {
        try #require(!initial)
        try #require(menames_fault_register(f.root.path) == SQLITE_OK)
        let store = try await PersistentNameStore.open(directory: f.catalog, action: .edit, probe: nil, vfs: "menames-generated-faults")
        let session = NameImportSession(target: .existing(store)), preview = try await session.preview(selectedFile: file)
        let operation: Int32 = boundary == "faultWrite" ? 1 : 2
        let role: Int32 = boundary == "faultDatabaseSync" ? 1 : 2
        menames_fault_arm(operation, 1, role)
        let result = await session.apply(preview)
        #expect(menames_fault_hits() == 1 && menames_fault_seen() >= 1)
        if case .imported = result { Issue.record("Import reported success after actual VFS failure") }
        if case .committedButHidden = result { Issue.record("Import reported committed after actual VFS failure") }
        await session.close(); await store.close()
        try receipt(["faultHits": String(menames_fault_hits()), "outcome": String(describing: result)]); return
    }
    if phase == "inspect" {
        let state = await PersistentNameStore.inspect(directory: f.catalog)
        #expect([.ready, .recoveryRequired, .initializationIncomplete].contains(state.status))
        try receipt(["status": String(describing: state.status)]); return
    }
    if phase == "recover" || phase == "cold" {
        let committed = boundary == "committed" || boundary == "acknowledged"
        if initial, !committed {
            // Before a first commit the owned namespace can remain incomplete.
            // Preserve it; never invent a Ready marker or adopt a partial batch.
            let state = await PersistentNameStore.inspect(directory: f.catalog)
            #expect(state.status == .initializationIncomplete || state.status == .recoveryRequired)
            if phase == "recover" {
                var opened = false
                do {
                    let store = try await PersistentNameStore.open(directory: f.catalog, action: .recover)
                    opened = true; await store.close()
                } catch { }
                #expect(!opened)
            }
            try receipt(["incompleteFirstTransactionPreserved": "true", "noAutomaticReplay": "true"]); return
        }
        let store = try await PersistentNameStore.open(directory: f.catalog, action: phase == "recover" ? .recover : .readOnly)
        let count = try await store.management().savedItems
        if boundary.hasPrefix("fault") { #expect(count == 1 || count == 4) }
        else { #expect(count == (committed ? (initial ? 3 : 4) : 1)) }
        #expect(try await store.management().storedReferences == 0)
        let values = try storedMatches(await store.library())
        #expect(values.filter { $0.item.names.nickname?.hasPrefix("Imported ") == true }.count == count - (initial ? 0 : 1))
        #expect(initial || values.contains { $0.item.names.nickname == "Keep existing" })
        if boundary.hasPrefix("fault"), phase == "cold" {
            let recovered = try JSONSerialization.jsonObject(with: Data(contentsOf: f.root.appendingPathComponent("recover.json"))) as? [String: String]
            #expect(recovered?["atomicBatchCount"] == String(count))
        }
        await store.close()
        try receipt(["atomicBatchCount": String(count), "noNativeAccess": "true", "noAutomaticReplay": "true"]); return
    }
}
