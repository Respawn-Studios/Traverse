import Darwin
import FileOperations
import Foundation
import NameStoreFaultSupport
import SQLite3
import Testing
@testable import FileMemory

/// Each crash terminates only this isolated generated child, never the app.
@Test func b074cMemberProcessWorker() async throws {
    let env = ProcessInfo.processInfo.environment
    guard MoveFixture.enabled, MoveFixture.extended, let path = env["MAC_EXPLORER_B074_ROOT"],
          let scenario = env["MAC_EXPLORER_B074_SCENARIO"], let phase = env["MAC_EXPLORER_B074_PHASE"] else { return }
    let f = try MoveFixture(existingRoot: URL(fileURLWithPath: path))
    let folder = f.source.appendingPathComponent("Project"), source = folder.appendingPathComponent("Document.txt")
    let operationFile = f.root.appendingPathComponent("operation.json")
    let upgrading = scenario.hasPrefix("memberUpgrade"), inverse = scenario.hasPrefix("memberUndo") || scenario == "memberFileUndoCommit"
    @Sendable func receipt(_ values: [String: String]) throws {
        var values = values; values["scenario"] = scenario; values["phase"] = phase; values["pid"] = String(getpid())
        let url = f.root.appendingPathComponent(phase + ".json")
        try JSONSerialization.data(withJSONObject: values, options: .sortedKeys).write(to: url, options: .withoutOverwriting)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NameStoreFailure.unsafe }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw NameStoreFailure.unsafe }
    }
    @Sendable func crash(_ boundary: String) throws -> Never { try receipt(["boundary": boundary]); Darwin._exit(86) }
    func image() throws -> [String: Data] {
        var value: [String: Data] = [:]
        for url in try FileManager().contentsOfDirectory(at: f.catalog, includingPropertiesForKeys: nil) {
            var s = stat(); guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFREG,
                s.st_nlink == 1, s.st_size <= 4_194_304 else { throw NameStoreFailure.unsafe }
            value[url.lastPathComponent] = try Data(contentsOf: url)
            value[url.lastPathComponent + ".stat"] = Data("\(s.st_ino)|\(s.st_size)|\(s.st_mtimespec)|\(s.st_ctimespec)".utf8)
        }
        return value
    }
    func operation() throws -> UUID? {
        guard FileManager().fileExists(atPath: operationFile.path) else { return nil }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: operationFile))["id"].flatMap(UUID.init(uuidString:))
    }
    func prepare(_ store: PersistentNameStore, engine: RecoverableFileOperations) async throws -> (MoveReferenceAdmission, RememberedMoveHandoff) {
        let plan = try await engine.prepareTransfer(sources: [folder], destinationDirectory: f.destination, move: true)
        let admitted = try await engine.observingMoveReferences(plan, candidates: [source])
        let ticket = try #require(admitted.tickets.first)
        try JSONEncoder().encode(["id": ticket.operationID.uuidString]).write(to: operationFile, options: .withoutOverwriting)
        return try await (admitted, store.prepareMoveHandoff(store.firstItemID(), ticket: ticket))
    }
    let engine = RecoverableFileOperations(journalDirectory: f.history)
    if phase == "seed" {
        try FileManager().createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("Generated process member".utf8).write(to: source, options: .withoutOverwriting)
        let first = try await PersistentNameStore.createRemembering(directory: f.catalog,
            first: AuthoredNames(nickname: "Private member description"), source: source, allowDocumentFollowing: true)
        await first.close()
        let store = try await PersistentNameStore.open(directory: f.catalog, action: upgrading ? .upgradeMoveContinuity : .upgradeMoveMembers)
        if inverse {
            let (admitted, handle) = try await prepare(store, engine: engine)
            let result = await engine.perform(admitted.plan), witness = try #require(result.referenceReceipts.first)
            let saved = try await store.retainMoveReceipt(handle, receipt: witness)
            _ = try await store.applyMoveHandoff(saved,
                evidence: engine.inspectMoveReference(saved.ticket, direction: .forward, receipt: saved.receipt))
        }
        await store.close(); try receipt(["seeded": "true"]); return
    }
    if phase == "inspect" {
        let before = try image(), state = await PersistentNameStore.inspect(directory: f.catalog)
        #expect(try image() == before)
        try receipt(["unchanged": "true", "status": String(describing: state.status)]); return
    }
    if phase == "crash" || phase == "fault" {
        let boundaries: [String: NameStoreBoundary] = ["memberUpgradeRows": .memberUpgradeRows, "memberUpgradeCommit": .memberUpgradeCommit,
            "memberReceiptRows": .memberReceiptRows, "memberReceiptCommit": .memberReceiptCommit,
            "memberReferenceRows": .moveReferenceRows, "memberReferenceCommit": .moveReferenceCommit,
            "memberUndoIntentRows": .moveUndoIntentRows, "memberUndoIntentCommit": .moveUndoIntentCommit,
            "memberUndoReferenceRows": .moveReferenceRows, "memberUndoReferenceCommit": .moveReferenceCommit]
        let probe: NameStoreProbe = { if $0 == boundaries[scenario] { try crash($0.rawValue) } }
        if upgrading {
            _ = try await PersistentNameStore.open(directory: f.catalog, action: .upgradeMoveMembers, probe: probe, vfs: nil)
            Issue.record("Upgrade boundary missed"); return
        }
        let fault = phase == "fault"
        if fault { #expect(menames_fault_register(f.root.path) == SQLITE_OK) }
        let store = try await PersistentNameStore.open(directory: f.catalog, action: .edit,
            probe: fault ? nil : probe, vfs: fault ? "menames-generated-faults" : nil)
        try await store.qualificationCachePages(1)
        if inverse {
            let operation = try #require(try operation())
            let row = try #require(await store.moveHandoffs(for: operation).first)
            let undo = try await store.prepareMoveUndo(row,
                evidence: engine.inspectMoveReference(row.ticket, direction: .forward, receipt: row.receipt))
            try #require((await engine.undo(recordID: operation)).result.disposition == .succeeded)
            if scenario == "memberFileUndoCommit" { try crash(scenario) }
            _ = try await store.applyMoveHandoff(undo,
                evidence: engine.inspectMoveReference(undo.ticket, direction: .undo, receipt: undo.receipt))
        } else {
            let (admitted, row) = try await prepare(store, engine: engine)
            let result = await engine.perform(admitted.plan), witness = try #require(result.referenceReceipts.first)
            if scenario == "memberFileCommit" { try crash(scenario) }
            if fault { menames_fault_arm(scenario == "faultMemberReceiptWrite" ? 1 : 2, 1, 2) }
            do {
                let saved = try await store.retainMoveReceipt(row, receipt: witness)
                _ = try await store.applyMoveHandoff(saved,
                    evidence: engine.inspectMoveReference(saved.ticket, direction: .forward, receipt: saved.receipt))
                if fault { Issue.record("Expected receipt I/O error") }
            } catch { guard fault else { throw error } }
        }
        if fault {
            #expect(menames_fault_hits() == 1); await store.close()
            try receipt(["faultHits": String(menames_fault_hits()), "errorReported": "true"]); return
        }
        Issue.record("Member crash boundary missed"); return
    }
    if phase == "recover" || phase == "cold" {
        let before = try image()
        var store = try await PersistentNameStore.open(directory: f.catalog, action: phase == "recover" ? .recover : .readOnly)
        if upgrading, try await !store.supportsMoveMembers() {
            await store.close(); guard phase == "recover" else { throw NameStoreFailure.unsupported }
            store = try await PersistentNameStore.open(directory: f.catalog, action: .upgradeMoveMembers)
        }
        let id = try await store.firstItemID()
        #expect(try storedSnapshot(await store.snapshot(id)).names.nickname == "Private member description")
        if phase == "recover" {
            for row in try await store.pendingMoveHandoffs() {
                if let proof = try? await engine.inspectMoveReference(row.ticket, direction: row.direction, receipt: row.receipt) {
                    _ = try await store.applyMoveHandoff(row, evidence: proof)
                }
            }
        }
        let pending = try await store.pendingMoveHandoffs()
        if pending.isEmpty {
            #expect(try referenceDisplay(await store.resolveReference(id)).availability == .available)
        } else {
            #expect(try referenceDisplay(await store.resolveReference(id)).availability == .needsReconciliation)
            await #expect(throws: RememberedReferenceFailure.stale) { _ = try await store.withVerifiedReference(id) { _ in true } }
        }
        await store.close()
        if phase == "cold" { #expect(try image() == before) }
        try receipt(["namesKept": "true", "pending": String(pending.count), "coldUnchanged": String(phase == "cold")]); return
    }
    Issue.record("Unknown member process phase")
}
