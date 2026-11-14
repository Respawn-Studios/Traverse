import Darwin
import Foundation
import NameStoreFaultSupport
import SQLite3
import Testing
@testable import FileMemory

/// Fresh-process native reference/SQLite boundaries. Only the explicitly
/// declared generated case is admitted; no default process exits or VFS changes.
@Test func b07ReferenceProcessWorker() async throws {
    let env = ProcessInfo.processInfo.environment
    guard NameStoreFixture.nativePacket, let path = env["MAC_EXPLORER_B07_REFERENCE_ROOT"],
          let phase = env["MAC_EXPLORER_B07_REFERENCE_PHASE"], let scenario = env["MAC_EXPLORER_B07_REFERENCE_SCENARIO"] else { return }
    let fixture = try NameStoreFixture(existingRoot: URL(fileURLWithPath: path))
    let reader = NativeDocumentReferenceReader(activity: nil)
    let a = fixture.child("a.txt"), b = fixture.child("b.txt")
    @Sendable func receipt(_ fields: [String: String]) throws {
        var fields = fields; fields["phase"] = phase; fields["scenario"] = scenario; fields["pid"] = String(getpid())
        let url = fixture.child(phase + ".json")
        try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys).write(to: url, options: .withoutOverwriting)
        #expect(chmod(url.path, 0o600) == 0)
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw NameStoreFailure.unavailable }; defer { Darwin.close(fd) }
        #expect(fsync(fd) == 0)
    }
    let boundaries: [String: NameStoreBoundary] = ["referenceRows": .referenceRows, "referenceCommit": .referenceCommit,
        "accessFenceRows": .accessFenceRows, "accessFenceCommit": .accessFenceCommit,
        "accessPurgeRows": .accessPurgeRows, "accessPurgeCommit": .accessPurgeCommit,
        "upgradeRows": .referenceUpgradeRows, "upgradeCommit": .referenceUpgradeCommit]
    if phase == "seed" {
        for url in [a,b] {
            try Data("Generated native process source".utf8).write(to: url, options: .withoutOverwriting)
            try await reader.qualificationEnableTracking(url, cancellation: .init())
        }
        let observation = try await reader.capture(a, cancellation: .init())
        let store = try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "Kept names"),
            probe: nil, vfs: nil, reference: observation.reference)
        await store.close()
        if scenario.hasPrefix("upgrade") {
            try fixture.databaseSQL("DROP INDEX active_document_reference; DROP TABLE item_references; UPDATE store_header SET format=1; PRAGMA user_version=1")
        }
        try receipt(["seeded": "true"]); return
    }
    if phase == "inspect" || phase == "inspectAgain" {
        let before = try fixture.image()
        let inspection = await PersistentNameStore.inspect(directory: fixture.catalog)
        #expect(try fixture.image() == before)
        try receipt(["status": String(describing: inspection.status), "unchanged": "true"]); return
    }
    if phase == "crash" {
        let probe: NameStoreProbe = { stage in
            if stage == boundaries[scenario] {
                let journal = fixture.catalog.appendingPathComponent("names.sqlite-journal")
                let prefix = (try? Data(contentsOf: journal).prefix(8)) ?? Data().prefix(8)
                let hot = Array(prefix) == [0xd9,0xd5,0x05,0xf9,0x20,0xa1,0x63,0xd7]
                try receipt(["exit": "86", "boundary": stage.rawValue, "hot": String(hot)])
                Darwin._exit(86)
            }
        }
        if scenario.hasPrefix("upgrade") {
            _ = try await PersistentNameStore.open(directory: fixture.catalog, action: .upgradeReferences, probe: probe, vfs: nil)
        } else {
            let store = try await PersistentNameStore.open(directory: fixture.catalog, action: .edit, probe: probe, vfs: nil)
            try await store.qualificationCachePages(1)
            let id = try await store.firstItemID()
            if scenario.hasPrefix("reference") { _ = try await store.apply(store.prepareRelink(id, source: b)) }
            else { _ = try await store.finishRemoveAccess(store.prepareRemoveAccess(id)) }
        }
        Issue.record("Native reference crash boundary not reached"); return
    }
    if phase == "fault" {
        #expect(menames_fault_register(fixture.root.path) == SQLITE_OK)
        let store = try await PersistentNameStore.open(directory: fixture.catalog, action: .edit, probe: {
            if scenario == "faultAccessPurge", $0 == .accessFenceCommit { menames_fault_arm(2, 1, 2) }
        }, vfs: "menames-generated-faults")
        try await store.qualificationCachePages(1)
        let id = try await store.firstItemID()
        var outcome = "incorrectSuccess"
        if scenario == "faultAccessPurge" || scenario == "faultAccessFence" {
            if scenario == "faultAccessFence" { menames_fault_arm(2, 1, 2) }
            let result = try await store.finishRemoveAccess(store.prepareRemoveAccess(id))
            #expect(result == (scenario == "faultAccessPurge" ? .disabledPending : .sessionDisabledOnly))
            outcome = String(describing: result)
        } else {
            let request = try await store.prepareRelink(id, source: b)
            let operation: Int32 = scenario == "faultReferenceWrite" ? 1 : 2
            menames_fault_arm(operation, 1, 2)
            do { _ = try await store.apply(request) } catch { outcome = "error" }
            #expect(outcome == "error")
        }
        #expect(menames_fault_hits() == 1)
        await store.close()
        try receipt(["outcome": outcome, "hits": String(menames_fault_hits()), "calls": String(menames_fault_seen())]); return
    }
    if phase == "recover" || phase == "cold" {
        let before = try fixture.image()
        let store = try await PersistentNameStore.open(directory: fixture.catalog, action: phase == "recover" ? .recover : .readOnly)
        let id = try await store.firstItemID()
        #expect(try storedSnapshot(await store.snapshot(id)).names.nickname == "Kept names")
        if phase == "recover", scenario.hasPrefix("access") || scenario == "faultAccessPurge" {
            try await store.finishPendingAccessRemoval()
        }
        if phase == "recover", scenario.hasPrefix("upgrade"), !(try await store.qualificationReferenceFormat()) {
            await store.close()
            let upgraded = try await PersistentNameStore.open(directory: fixture.catalog, action: .upgradeReferences)
            await upgraded.close()
            try receipt(["recovered": "true", "upgradeFinished": "true"]); return
        }
        let display = try referenceDisplay(await store.resolveReference(id))
        if scenario.hasPrefix("upgrade") { #expect(display.availability == .needsRelink) }
        else if ["accessFenceCommit", "accessPurgeRows", "accessPurgeCommit", "faultAccessPurge"].contains(scenario) {
            #expect(display.availability == .accessRemoved)
        } else {
            #expect(display.availability == .available)
            if scenario == "referenceCommit" { #expect(display.location?.path == b.path) }
            else if !scenario.hasPrefix("fault") { #expect(display.location?.path == a.path) }
        }
        await store.close()
        if phase == "cold" { #expect(try fixture.image() == before) }
        try receipt(["recovered": "true", "availability": display.availability.rawValue, "coldUnchanged": String(phase == "cold")]); return
    }
    Issue.record("Unknown native reference process phase")
}
