import Darwin
import FileOperations
import Foundation
import NameStoreFaultSupport
import SQLite3
import Testing
@testable import FileMemory

extension PersistentNameStore {
    fileprivate func b074HasFormat() throws -> Bool { try database.hasMoveFormat }
}

/// Each invocation owns one generated case and one requested phase. Crashes
/// exit only this child; normal transfers never install these probes or VFS.
@Test func b074MoveProcessWorker() async throws {
    let env = ProcessInfo.processInfo.environment
    guard MoveFixture.enabled, let path = env["MAC_EXPLORER_B074_ROOT"],
          let scenario = env["MAC_EXPLORER_B074_SCENARIO"], let phase = env["MAC_EXPLORER_B074_PHASE"] else { return }
    let f = try MoveFixture(existingRoot: URL(fileURLWithPath: path))
    let source = f.source.appendingPathComponent("Document.txt")
    let operationFile = f.root.appendingPathComponent("operation.json")
    let undoScenario = scenario.hasPrefix("undoReference") || scenario.hasPrefix("moveUndo") || scenario == "fileUndoCommit"
    @Sendable func receipt(_ fields: [String: String]) throws {
        var fields = fields
        fields["phase"] = phase; fields["scenario"] = scenario; fields["pid"] = String(getpid())
        let url = f.root.appendingPathComponent(phase + ".json")
        try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys).write(to: url, options: .withoutOverwriting)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NameStoreFailure.unavailable }; defer { close(fd) }
        #expect(fsync(fd) == 0)
    }
    @Sendable func crash(_ boundary: String) throws -> Never {
        try receipt(["boundary": boundary, "terminationCode": "86"])
        Darwin._exit(86)
    }
    func operationID() throws -> UUID? {
        guard FileManager().fileExists(atPath: operationFile.path) else { return nil }
        let value = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: operationFile))
        return value["id"].flatMap(UUID.init(uuidString:))
    }
    func saveOperation(_ ticket: MoveReferenceTicket) throws {
        try JSONEncoder().encode(["id": ticket.operationID.uuidString]).write(to: operationFile, options: .withoutOverwriting)
    }
    func image() throws -> [String: Data] {
        var rows: [String: Data] = [:]
        for url in try FileManager().contentsOfDirectory(at: f.catalog, includingPropertiesForKeys: nil) {
            var info = stat(); guard lstat(url.path, &info) == 0, info.st_size <= 4 * 1_024 * 1_024 else { throw NameStoreFailure.quota }
            rows[url.lastPathComponent] = try Data(contentsOf: url)
            rows[url.lastPathComponent + ".stat"] = Data("\(info.st_ino)|\(info.st_mode)|\(info.st_size)|\(info.st_mtimespec)|\(info.st_ctimespec)".utf8)
        }
        return rows
    }
    let engine = RecoverableFileOperations(journalDirectory: f.history)
    if phase == "seed" {
        _ = try f.file()
        let first = try await PersistentNameStore.createRemembering(directory: f.catalog,
            first: AuthoredNames(nickname: "Kept private names", labels: ["generated"]), source: source, allowDocumentFollowing: true)
        await first.close()
        if !scenario.hasPrefix("moveUpgrade") {
            let store = try await PersistentNameStore.open(directory: f.catalog, action: .upgradeMoveContinuity)
            if undoScenario {
                let id = try await store.firstItemID()
                let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
                let ticket = try #require(engine.moveReferenceTickets(for: plan).first)
                try saveOperation(ticket)
                let handoff = try await store.prepareMoveHandoff(id, ticket: ticket)
                try #require((await engine.perform(plan)).result.disposition == .succeeded)
                _ = try await store.applyMoveHandoff(handoff, evidence: engine.inspectMoveReference(ticket, direction: .forward))
            }
            await store.close()
        }
        try receipt(["seeded": "true"]); return
    }
    if phase == "inspect" {
        let before = try image()
        let inspection = await PersistentNameStore.inspect(directory: f.catalog)
        #expect(try image() == before)
        try receipt(["status": String(describing: inspection.status), "unchanged": "true"]); return
    }
    if phase == "crash" || phase == "fault" {
        let stages: [String: NameStoreBoundary] = ["moveUpgradeRows": .moveUpgradeRows, "moveUpgradeCommit": .moveUpgradeCommit,
            "moveIntentRows": .moveIntentRows, "moveIntentCommit": .moveIntentCommit,
            "moveReferenceRows": .moveReferenceRows, "moveReferenceCommit": .moveReferenceCommit,
            "moveUndoIntentRows": .moveUndoIntentRows, "moveUndoIntentCommit": .moveUndoIntentCommit,
            "undoReferenceRows": .moveReferenceRows, "undoReferenceCommit": .moveReferenceCommit]
        let probe: NameStoreProbe = { stage in
            if stage == stages[scenario] { try crash(stage.rawValue) }
        }
        if scenario.hasPrefix("moveUpgrade") {
            _ = try await PersistentNameStore.open(directory: f.catalog, action: .upgradeMoveContinuity, probe: probe, vfs: nil)
            Issue.record("Upgrade crash point not reached"); return
        }
        let faults = phase == "fault"
        if faults { #expect(menames_fault_register(f.root.path) == SQLITE_OK) }
        let store = try await PersistentNameStore.open(directory: f.catalog, action: .edit,
            probe: faults ? nil : probe, vfs: faults ? "menames-generated-faults" : nil)
        try await store.qualificationCachePages(1)
        let id = try await store.firstItemID()
        var didFail = false
        if undoScenario {
            let operation = try #require(try operationID())
            let handoff = try #require(await store.moveHandoffs(for: operation).first)
            let forward = try await engine.inspectMoveReference(handoff.ticket, direction: .forward)
            let inverse = try await store.prepareMoveUndo(handoff, evidence: forward)
            try #require((await engine.undo(recordID: operation)).result.disposition == .succeeded)
            if scenario == "fileUndoCommit" { try crash(scenario) }
            _ = try await store.applyMoveHandoff(inverse, evidence: engine.inspectMoveReference(handoff.ticket, direction: .undo))
        } else {
            let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
            let ticket = try #require(engine.moveReferenceTickets(for: plan).first)
            try saveOperation(ticket)
            if scenario.hasPrefix("faultIntent") { menames_fault_arm(scenario == "faultIntentWrite" ? 1 : 2, 1, 2) }
            do {
                let handoff = try await store.prepareMoveHandoff(id, ticket: ticket)
                try #require((await engine.perform(plan)).result.disposition == .succeeded)
                if scenario == "fileMoveCommit" { try crash(scenario) }
                let proof = try await engine.inspectMoveReference(ticket, direction: .forward)
                if scenario == "faultReferenceSync" { menames_fault_arm(2, 1, 2) }
                _ = try await store.applyMoveHandoff(handoff, evidence: proof)
            } catch {
                guard faults else { throw error }
                didFail = true
            }
        }
        if faults {
            #expect(didFail); #expect(menames_fault_hits() == 1)
            await store.close()
            try receipt(["errorReported": String(didFail), "faultHits": String(menames_fault_hits())]); return
        }
        Issue.record("Move crash point not reached"); return
    }
    if phase == "recover" || phase == "cold" {
        let before = try image()
        var store = try await PersistentNameStore.open(directory: f.catalog, action: phase == "recover" ? .recover : .readOnly)
        if scenario.hasPrefix("moveUpgrade"), !(try await store.b074HasFormat()) {
            await store.close()
            guard phase == "recover" else { throw NameStoreFailure.continuityUpdateRequired }
            store = try await PersistentNameStore.open(directory: f.catalog, action: .upgradeMoveContinuity)
        }
        let id = try await store.firstItemID()
        #expect(try storedSnapshot(await store.snapshot(id)).names.nickname == "Kept private names")
        var applied = "none"
        if phase == "recover" {
            let pending = try await store.pendingMoveHandoffs()
            for handle in pending {
                // This explicit test phase reconciles references only. No file
                // Move/Undo/recovery is performed by the reconciliation path.
                let evidence = try? await engine.inspectMoveReference(handle.ticket, direction: handle.direction)
                if let evidence { applied = String(describing: try await store.applyMoveHandoff(handle, evidence: evidence)) }
            }
        }
        let unresolved = try await store.pendingMoveHandoffs().count
        if unresolved > 0 {
            #expect(try referenceDisplay(await store.resolveReference(id)).availability == .needsReconciliation)
            await #expect(throws: RememberedReferenceFailure.stale) { _ = try await store.withVerifiedReference(id) { _ in true } }
        } else if !scenario.hasPrefix("moveUpgrade") {
            #expect(try referenceDisplay(await store.resolveReference(id)).availability == .available)
        }
        // Lost acknowledgement may already have committed: replay only the
        // exact completed association, proving its idempotent no-op.
        if phase == "recover", let operation = try operationID(),
           let handle = try await store.moveHandoffs(for: operation).first,
           let evidence = try? await engine.inspectMoveReference(handle.ticket, direction: handle.direction), unresolved == 0 {
            #expect(try await store.applyMoveHandoff(handle, evidence: evidence) == .alreadyApplied)
        }
        await store.close()
        if phase == "cold" { #expect(try image() == before) }
        try receipt(["namesKept": "true", "reconciled": applied, "pending": String(unresolved),
            "coldUnchanged": String(phase == "cold")]); return
    }
    Issue.record("Unknown Move process phase")
}
