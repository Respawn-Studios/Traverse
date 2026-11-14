// Concatenate after the frozen production worker with only that
// worker's @main removed. Never install a fixture relocation Trash action.
import Darwin
import Foundation
import SQLite3

private struct NativeTrashCheckpointReceipt: Codable, Sendable {
    let stage: String
    let group: Int?
    let revision: Int
}

private final class NativeTrashProcessGate: @unchecked Sendable {
    let mechanism: String
    let stage: GroupedCopyRetentionCheckpointStage?
    let group: Int?
    private let lock = NSLock()
    private var reached = false
    private var armed = false
    private var lost = false
    private var sqliteCodes: [Int32] = []
    private var events: [NativeTrashCheckpointReceipt] = []
    init(mechanism: String, stage: GroupedCopyRetentionCheckpointStage?, group: Int?) {
        self.mechanism = mechanism; self.stage = stage; self.group = group
    }
    func checkpoint(_ point: GroupedCopyRetentionCheckpoint, cancellation: OperationCancellation) throws {
        lock.lock()
        guard events.count < 128 else { lock.unlock(); throw GroupedProductionHarnessFailure.bound }
        events.append(.init(stage: point.stage.rawValue, group: point.groupOrdinal, revision: point.revision))
        let hit = !reached && point.stage == stage && (group == nil || point.groupOrdinal == group)
        if hit { reached = true; armed = mechanism == "lost_acknowledgement" }
        lock.unlock()
        guard hit else { return }
        switch mechanism {
        case "cooperative_stop": cancellation.cancel()
        case "injected_error": throw FileOperationFailure.ioFailure
        case "process_crash":
            try GroupedCopyProductionWorker.emit(["pid": getpid(), "targetReached": true,
                "mechanism": mechanism, "stage": point.stage.rawValue, "revision": point.revision,
                "group": point.groupOrdinal.map { $0 as Any } ?? NSNull(),
                "recordID": point.recordID.uuidString, "termination": "_exit(86)",
                "nativeTrashDefaultRoute": true])
            _exit(86)
        case "lost_acknowledgement": break
        default: throw GroupedProductionHarnessFailure.unsafeFixture
        }
    }
    func afterCommit() throws {
        lock.lock(); let fire = armed
        if fire { armed = false; lost = true }
        lock.unlock()
        if fire { throw FileOperationFailure.ioFailure }
    }
    func observedSQLite(_ code: Int32) {
        lock.lock(); defer { lock.unlock() }
        if sqliteCodes.count < 256 { sqliteCodes.append(code) }
    }
    var snapshot: (reached: Bool, lost: Bool, events: [NativeTrashCheckpointReceipt], sqliteCodes: [Int32]) {
        lock.lock(); defer { lock.unlock() }; return (reached, lost, events, sqliteCodes)
    }
}

/// Only a deliberately created collision object is kept here. Its native URL
/// stays in a private0600 owned receipt; reports contain hashes/flags, not paths.
private struct NativeTrashCollisionReceipt: Codable {
    let target: URL
    let before: VerifiedTree
    let marker: Data
}

private final class NativeTrashColdTrap: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    func refuse() throws -> URL {
        lock.lock(); entered = true; lock.unlock()
        throw GroupedProductionHarnessFailure.unsafeFixture
    }
    var wasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
}

@main private enum GroupedCopyNativeTrashProcessWorker {
    static func main() async {
        let stage = ProductionDiagnosticStage("native_trash_validate_arguments")
        do { try await execute(stage) }
        catch {
            let failure: String
            if let typed = error as? FileOperationFailure { failure = typed.rawValue }
            else { failure = "harness_or_platform_failure" }
            try? GroupedCopyProductionWorker.emit(["pid": getpid(), "failed": true,
                "stage": stage.value, "failureCode": failure, "nativeTrashDefaultRoute": true])
            exit(1)
        }
    }

    static func execute(_ stage: ProductionDiagnosticStage) async throws {
        let args = CommandLine.arguments
        guard args.count == 8, ["observe", "observe-ordinary", "cleanup", "undo", "ordinary", "collision", "compact"].contains(args[1]),
              let policy = TransferMetadataPolicy(rawValue: args[7]),
              ["none", "cooperative_stop", "injected_error", "process_crash", "lost_acknowledgement", "sqlite_full"].contains(args[6]) else {
            throw GroupedProductionHarnessFailure.unsafeFixture
        }
        let fixture = try GroupedProductionFixture(args[2])
        let id = UUID(uuidString: args[3])
        guard args[1] == "ordinary" ? args[3] == "-" : id != nil else { throw GroupedProductionHarnessFailure.unsafeFixture }
        let point = args[4] == "none" ? nil : GroupedCopyRetentionCheckpointStage(rawValue: args[4])
        let group = args[5] == "-" ? nil : Int(args[5])
        guard args[5] == "-" || (group != nil && (0..<3).contains(group!)),
              (["none", "sqlite_full"].contains(args[6]) && point == nil) || (!["none", "sqlite_full"].contains(args[6]) && point != nil),
              args[1] == "cleanup" || args[6] == "none" else { throw GroupedProductionHarnessFailure.unsafeFixture }
        if args[6] == "lost_acknowledgement" {
            guard [.invalidationWillCommit, .trashIntentWillCommit, .trashOutcomeWillCommit,
                .cleanupTerminalWillCommit].contains(point!) else { throw GroupedProductionHarnessFailure.unsafeFixture }
        }
        if args[1] == "collision" {
            stage.set("native_trash_owned_collision")
            try seedCollision(fixture, id: id!); return
        }
        if args[1] == "observe" {
            stage.set("native_trash_read_only_observation")
            try await observe(fixture, id: id!); return
        }
        if args[1] == "observe-ordinary" {
            stage.set("native_trash_ordinary_read_only_observation")
            try await observeOrdinary(fixture, id: id!); return
        }
        if args[1] == "compact" {
            guard point == nil, group == nil else { throw GroupedProductionHarnessFailure.unsafeFixture }
            stage.set("native_trash_explicit_catalog_compaction")
            try await compact(fixture, id: id!); return
        }
        let sourceBefore = try GroupedProductionFixture.fingerprint(fixture.source)
        guard sourceBefore == (try fixture.seedManifest())["sourceFingerprint"] else { throw GroupedProductionHarnessFailure.unsafeFixture }
        var hooks = RecoveryHooks()
        hooks.groupedCopy.qualification = try GroupedCopyQualification(root: fixture.root)
        let gate = NativeTrashProcessGate(mechanism: args[6], stage: point, group: group)
        hooks.groupedRetention.checkpoint = { try gate.checkpoint($0, cancellation: $1) }
        hooks.journalHooks.afterCommitBeforeAcknowledgement = { try gate.afterCommit() }
        hooks.journalHooks.observedSQLiteFailureCode = { gate.observedSQLite($0) }
        var pressure: [String: Any] = [:]
        if args[6] == "sqlite_full" {
            let budget = try pageBudget(fixture)
            hooks.journalHooks.maximumPageCount = budget.pages
            pressure = ["requestedMaximumPages": budget.pages, "initialFreePages": budget.free]
        }
        // Deliberately nil: production FileManager.trashItem is the tested route.
        guard hooks.retentionTrash == nil else { throw GroupedProductionHarnessFailure.unsafeFixture }
        if args[1] == "ordinary" { hooks.groupedCopy.qualification = nil }
        let engine = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks)
        let result: RecoverableOperationResult
        if args[1] == "ordinary" {
            stage.set("native_trash_ordinary_copy_control_seed")
            let manifest = try fixture.seedManifest()
            guard let text = manifest["count"], let count = Int(text) else { throw GroupedProductionHarnessFailure.unsafeFixture }
            let inputs = (0..<count).map { fixture.source.appendingPathComponent(GroupedProductionFixture.inputName($0)) }
            result = await engine.perform(.copy(sources: inputs, destinationDirectory: fixture.destination), metadataPolicy: policy)
        } else if args[1] == "undo" {
            stage.set("native_trash_completed_undo_seed")
            result = await engine.undo(recordID: id!)
        } else {
            stage.set("native_trash_explicit_cleanup")
            result = await engine.cleanupRecovery(recordID: id!, progress: nil, journalHooks: hooks.journalHooks)
        }
        let captured = gate.snapshot
        guard sourceBefore == (try GroupedProductionFixture.fingerprint(fixture.source)),
              ["none", "sqlite_full"].contains(args[6]) || captured.reached,
              args[6] != "lost_acknowledgement" || captured.lost else { throw GroupedProductionHarnessFailure.unsafeFixture }
        let events = try JSONSerialization.jsonObject(with: GroupedProductionFixture.encode(captured.events))
        try GroupedCopyProductionWorker.emit(["pid": getpid(), "recordID": result.recordID.map { $0.uuidString as Any } ?? NSNull(),
            "disposition": result.result.disposition.rawValue, "cancellationRequested": result.result.cancellationRequested,
            "failureCodes": result.result.items.compactMap { item -> String? in
                if case .failed(let error) = item.status { return error.rawValue }; return nil },
            "reportedSucceededAreas": result.result.items.filter { $0.role == .transfer && $0.status == .succeeded }.count,
            "knownNativeRecoveryLocations": result.result.items.reduce(0) { $0 + $1.recoveryURLs.count },
            "returnedOutcomeRoles": result.result.items.map { $0.role.rawValue },
            "returnedOutcomeStatuses": result.result.items.map { item in
                switch item.status { case .succeeded: "succeeded"; case .cancelled: "cancelled"
                case .failed: "failed"; case .skipped: "skipped"; case .notStarted: "notStarted" }
            },
            "mechanism": args[6], "targetReached": captured.reached, "acknowledgementLost": captured.lost,
            "checkpoints": events, "sourceUnchanged": true, "nativeTrashDefaultRoute": true,
            "storagePressure": pressure, "observedSQLiteFailureCodes": captured.sqliteCodes,
            "sqliteFailureCount": captured.sqliteCodes.count,
            "genuineSQLiteFullCount": captured.sqliteCodes.filter { $0 & 0xff == 13 }.count])
    }

    /// Read-only bounded pressure observation of the exact generated database.
    /// No padding table or fabricated error changes the catalog or its history.
    static func pageBudget(_ fixture: GroupedProductionFixture) throws -> (pages: Int64, free: Int64) {
        try GroupedProductionFixture.directory(fixture.journal)
        let url = fixture.journal.appendingPathComponent("operations-v2.sqlite")
        let pinned = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard pinned >= 0 else { throw GroupedProductionHarnessFailure.io }; defer { close(pinned) }
        var before = stat()
        guard fstat(pinned, &before) == 0, before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & S_IFMT == S_IFREG, before.st_mode & 0o077 == 0,
              before.st_size > 0, before.st_size <= 67_108_864 else { throw GroupedProductionHarnessFailure.unsafeFixture }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { if let database { sqlite3_close(database) }; throw GroupedProductionHarnessFailure.io }
        defer { sqlite3_close(database) }
        func integer(_ sql: String) throws -> Int64 {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw GroupedProductionHarnessFailure.io }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw GroupedProductionHarnessFailure.io }
            let result = sqlite3_column_int64(statement, 0)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw GroupedProductionHarnessFailure.io }; return result
        }
        let pages = try integer("PRAGMA page_count"), free = try integer("PRAGMA freelist_count")
        var after = stat(), linked = stat()
        guard fstat(pinned, &after) == 0, lstat(url.path, &linked) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              after.st_dev == linked.st_dev, after.st_ino == linked.st_ino,
              before.st_size == after.st_size, before.st_mode == after.st_mode, after.st_nlink == 1,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              pages > 0, pages <= 16_384, free >= 0, free <= pages else { throw GroupedProductionHarnessFailure.unsafeFixture }
        return (pages, free)
    }

    static func groupedRecord(_ fixture: GroupedProductionFixture, id: UUID) throws -> GroupedCopyRecord {
        let journal = try OperationJournal(fixture.journal)
        guard case .groupedCopyV1(let record)? = try journal.inspectCatalogRecord(id) else { throw FileOperationFailure.recoveryUncertain }
        return record
    }

    static func compactMutationTrap() -> Never { _exit(87) }

    static func confirmedNativeFingerprint(_ record: GroupedCopyRecord) throws -> String {
        var rows: [String] = []
        for group in record.groups {
            guard case .confirmed(let intent, let target, let after) = group.cleanup else {
                throw FileOperationFailure.recoveryUncertain
            }
            let tree = try ownedGroupFingerprint(record, group: group, root: target, nativeTransition: true)
            guard intent.before.matchesNativeTrashTransition(tree), after.matches(tree) else {
                throw FileOperationFailure.recoveryUncertain
            }
            rows.append("\(group.ordinal):\(tree.identity.device):\(tree.identity.inode):\(tree.digest)")
        }
        return GroupedProductionFixture.digest(Data(rows.joined(separator: "\n").utf8))
    }

    static func compact(_ fixture: GroupedProductionFixture, id: UUID) async throws {
        let before = try groupedRecord(fixture, id: id)
        guard before.head.state == .cleaned, before.head.undoInvalidated, before.members.count == 33,
              before.members.allSatisfy({ $0.progress.phase == "published" }) ||
                before.members.allSatisfy({ $0.progress.phase == "undone" }) else {
            throw GroupedProductionHarnessFailure.unsafeFixture
        }
        let recordBytes = try GroupedProductionFixture.encode(before)
        let source = try GroupedProductionFixture.fingerprint(fixture.source)
        guard source == (try fixture.seedManifest())["sourceFingerprint"] else { throw FileOperationFailure.sourceChanged }
        let destination = try GroupedProductionFixture.metadataFingerprint(fixture.destination)
        let published = try publicFingerprint(before)
        let native = try confirmedNativeFingerprint(before)
        let prior = try OperationJournal(fixture.journal).maintenance()
        var hooks = RecoveryHooks()
        hooks.beforeStagingProof = { _ in compactMutationTrap() }
        hooks.beforeSync = { _ in compactMutationTrap() }
        hooks.beforeExclusiveRename = { _, _ in compactMutationTrap() }
        hooks.beforeCommit = { compactMutationTrap() }
        hooks.beforeRename = { compactMutationTrap() }
        hooks.copyFaults.beforeNativeCopy = { _, _ in compactMutationTrap() }
        hooks.retentionTrash = { _ in compactMutationTrap() }
        hooks.groupedCopy.checkpoint = { _, _ in compactMutationTrap() }
        hooks.groupedRecovery.checkpoint = { _, _ in compactMutationTrap() }
        hooks.groupedRetention.checkpoint = { _, _ in compactMutationTrap() }
        let engine = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks)
        let result = try await engine.compactJournal()
        let after = try groupedRecord(fixture, id: id)
        guard recordBytes == (try GroupedProductionFixture.encode(after)),
              source == (try GroupedProductionFixture.fingerprint(fixture.source)),
              destination == (try GroupedProductionFixture.metadataFingerprint(fixture.destination)),
              published == (try publicFingerprint(after)), native == (try confirmedNativeFingerprint(after)),
              result.eventCount == 1, prior.eventCount > result.eventCount,
              result.databaseBytes > 0, result.freePages >= 0 else { throw FileOperationFailure.recoveryUncertain }
        try GroupedCopyProductionWorker.emit(["pid": getpid(), "recordID": id.uuidString,
            "compacted": true, "publicCompactJournalInvoked": true,
            "databaseBytes": result.databaseBytes, "eventCount": result.eventCount, "freePages": result.freePages,
            "beforeDatabaseBytes": prior.databaseBytes, "beforeEventCount": prior.eventCount, "beforeFreePages": prior.freePages,
            "catalogRecordDigest": GroupedProductionFixture.digest(recordBytes), "revision": after.head.revision,
            "sourceFingerprint": source, "sourceUnchanged": true, "destinationFingerprint": destination,
            "publicFingerprint": published, "knownNativeFingerprint": native,
            "exactRecordPreserved": true, "ownedNamespaceUnchanged": true,
            "payloadFilesystemMutationTrapsInstalled": true, "mutationTrapExitCode": 87,
            "nativeTrashInvoked": false, "noArbitraryTrashSearch": true])
    }

    /// Bind the root, marker, exact children and each sealed descendant before
    /// reading any payload. Never walk an arbitrary Trash directory or source.
    static func ownedGroupFingerprint(_ record: GroupedCopyRecord, group: GroupedCopyGroup,
                                      root: URL, nativeTransition: Bool) throws -> VerifiedTree {
        for attempt in 0..<3 {
            do { return try ownedGroupFingerprintOnce(record, group: group, root: root, nativeTransition: nativeTransition) }
            catch FileOperationFailure.sourceChanged {
                guard nativeTransition && attempt < 2 else { throw FileOperationFailure.sourceChanged }
                Thread.sleep(forTimeInterval: 0.01 * Double(attempt + 1))
            }
        }
        throw FileOperationFailure.sourceChanged
    }

    static func ownedGroupFingerprintOnce(_ record: GroupedCopyRecord, group: GroupedCopyGroup,
                                          root: URL, nativeTransition: Bool) throws -> VerifiedTree {
        guard let expected = group.areaIdentity else { throw FileOperationFailure.recoveryUncertain }
        let area = try DirectoryAnchor(root, resolve: false)
        let markerIdentity = try EntrySnapshot(parent: area.fd, name: GroupedCopyGroup.markerName)
        guard area.identity.sameObject(as: expected),
              markerIdentity.type == S_IFREG, markerIdentity.size == group.marker.count,
              try OperationJournal.read(name: GroupedCopyGroup.markerName, anchor: area) == group.marker else {
            throw FileOperationFailure.recoveryUncertain
        }
        let rootNames = try GroupedCopyFilesystemEvidence.children(in: area, cancellation: OperationCancellation(), limit: 17)
        var expectedNames = [Data(GroupedCopyGroup.markerName.utf8)]
        for ordinal in group.members {
            let member = record.members[ordinal]
            guard let declaration = member.progress.declaration else { throw FileOperationFailure.recoveryUncertain }
            if case .neverStaged = member.progress {
                try requireAbsent(declaration.areaURL.lastPathComponent, in: area.fd); continue
            }
            guard let seal = member.progress.seal else { throw FileOperationFailure.recoveryUncertain }
            expectedNames.append(Data(declaration.areaURL.lastPathComponent.utf8))
            let privateArea = try DirectoryAnchor(root.appendingPathComponent(declaration.areaURL.lastPathComponent), resolve: false)
            guard privateArea.identity.sameObject(as: seal.areaIdentity) else { throw FileOperationFailure.recoveryUncertain }
            let names = try GroupedCopyFilesystemEvidence.children(in: privateArea, cancellation: OperationCancellation(), limit: 1)
            if member.progress.phase == "published" {
                guard names.isEmpty else { throw FileOperationFailure.recoveryUncertain }
            } else {
                guard ["sealed", "undone"].contains(member.progress.phase), names == ["payload"],
                      try EntrySnapshot(parent: privateArea.fd, name: "payload").sameObject(as: seal.proof.payload.identity) else {
                    throw FileOperationFailure.recoveryUncertain
                }
                let tree = try verifiedTree(parent: privateArea.fd, name: "payload", cancellation: OperationCancellation())
                let nodes = try snapshotTree(parent: privateArea.fd, name: "payload", cancellation: OperationCancellation())
                guard (nativeTransition ? seal.proof.payload.matchesNativeTrashTransition(tree) : seal.proof.payload.matches(tree)),
                      stagingIdentityDigest(nodes) == seal.proof.identityDigest else { throw FileOperationFailure.recoveryUncertain }
            }
            try privateArea.validate()
        }
        guard rootNames.count == expectedNames.count, Set(rootNames.map { Data($0.utf8) }) == Set(expectedNames) else {
            throw FileOperationFailure.recoveryUncertain
        }
        try area.validate()
        return try verifiedTree(root, cancellation: OperationCancellation())
    }

    static func publicFingerprint(_ record: GroupedCopyRecord) throws -> String {
        var rows: [String] = []
        for member in record.members {
            let parent = try GroupedCopyFilesystemEvidence.checkedParent(member.manifest.destination)
            if member.progress.phase == "published" {
                guard let seal = member.progress.seal,
                      let entry = try NativeRenameEntry.optional(parent: parent, name: member.manifest.destination.name),
                      entry.nameBytes == member.manifest.destination.nameBytes,
                      entry.identity.sameObject(as: seal.proof.payload.identity) else { throw FileOperationFailure.recoveryUncertain }
                let tree = try verifiedTree(parent: parent.fd, name: member.manifest.destination.name, cancellation: OperationCancellation())
                guard seal.proof.payload.matches(tree) else { throw FileOperationFailure.recoveryUncertain }
                rows.append("\(member.ordinal):\(tree.identity.device):\(tree.identity.inode):\(tree.digest)")
            } else {
                try requireAbsent(member.manifest.destination.name, in: parent.fd)
                rows.append("\(member.ordinal):absent")
            }
        }
        return GroupedProductionFixture.digest(Data(rows.joined(separator: "\n").utf8))
    }

    static func observe(_ fixture: GroupedProductionFixture, id: UUID) async throws {
        let sourceBefore = try GroupedProductionFixture.fingerprint(fixture.source)
        guard sourceBefore == (try fixture.seedManifest())["sourceFingerprint"] else { throw GroupedProductionHarnessFailure.unsafeFixture }
        let destinationBefore = try GroupedProductionFixture.metadataFingerprint(fixture.destination)
        let record = try groupedRecord(fixture, id: id)
        let publishedBefore = try publicFingerprint(record)
        var rows: [[String: Any]] = []
        var nativeFingerprints: [String] = []
        for group in record.groups {
            var row: [String: Any] = ["ordinal": group.ordinal, "members": group.members,
                "cleanupPhase": group.cleanup.phase, "neverCreated": group.creationClosure == .neverCreated]
            let parent = try GroupedCopyFilesystemEvidence.checkedParent(record.members[0].manifest.destination)
            let original = try NativeRenameEntry.optional(parent: parent, name: group.areaURL.lastPathComponent)
            row["originalAbsent"] = original == nil
            switch group.cleanup {
            case .none:
                if group.creationClosure == .neverCreated {
                    guard original == nil else { throw FileOperationFailure.recoveryUncertain }
                    row["ownedInventoryVerified"] = true
                } else {
                    let tree = try ownedGroupFingerprint(record, group: group, root: group.areaURL, nativeTransition: false)
                    row["ownedInventoryVerified"] = true; row["ownedDigest"] = tree.digest
                }
            case .intent:
                // No returned URL is durable. An absent original is uncertainty;
                // never search Trash or infer successful cleanup from absence.
                row["unknownNativeOutcomeProtected"] = true
                if original != nil { _ = try ownedGroupFingerprint(record, group: group, root: group.areaURL, nativeTransition: false) }
            case .returned(let intent, let target), .confirmed(let intent, let target, _):
                guard original == nil else { throw FileOperationFailure.recoveryUncertain }
                let tree = try ownedGroupFingerprint(record, group: group, root: target, nativeTransition: true)
                guard intent.before.matchesNativeTrashTransition(tree) else { throw FileOperationFailure.recoveryUncertain }
                if case .confirmed(_, _, let after) = group.cleanup {
                    guard after.matches(tree) else { throw FileOperationFailure.recoveryUncertain }
                }
                row["knownNativeTargetVerified"] = true; row["ownedDigest"] = tree.digest
                row["unknownNativeOutcomeProtected"] = group.cleanup.phase == "returned"
                row["targetOutsideFixture"] = !target.path.hasPrefix(fixture.root.path + "/")
                guard !target.path.hasPrefix(fixture.root.path + "/") else { throw GroupedProductionHarnessFailure.unsafeFixture }
                nativeFingerprints.append("\(group.ordinal):\(tree.identity.device):\(tree.identity.inode):\(tree.digest)")
            }
            rows.append(row)
        }
        let collision = try inspectCollision(fixture)
        var collisionSeparated: Any = NSNull()
        let collisionReceiptURL = fixture.root.appendingPathComponent("native-collision.json")
        if FileManager().fileExists(atPath: collisionReceiptURL.path), let first = record.groups.first {
            let receipt = try JSONDecoder().decode(NativeTrashCollisionReceipt.self,
                from: GroupedProductionFixture.read(collisionReceiptURL, maximum: 16_384))
            let target: URL?
            switch first.cleanup { case .returned(_, let url), .confirmed(_, let url, _): target = url; default: target = nil }
            if let target {
                guard receipt.target != target, receipt.target.lastPathComponent == first.areaURL.lastPathComponent else {
                    throw FileOperationFailure.recoveryUncertain
                }
                collisionSeparated = true
            }
        }
        let trap = NativeTrashColdTrap()
        var hooks = RecoveryHooks()
        hooks.retentionTrash = { _ in try trap.refuse() }
        let engine = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks)
        let summary = try await engine.retentionRecord(recordID: id)
        let review = try await engine.prepareGroupedRecovery(recordID: id)
        let after = try groupedRecord(fixture, id: id)
        guard !trap.wasEntered, after.head.revision == record.head.revision, after.head.state == record.head.state,
              sourceBefore == (try GroupedProductionFixture.fingerprint(fixture.source)),
              destinationBefore == (try GroupedProductionFixture.metadataFingerprint(fixture.destination)),
              publishedBefore == (try publicFingerprint(after)) else { throw FileOperationFailure.recoveryUncertain }
        // Recheck known returned targets after the production cold summary too.
        var repeatedNative: [String] = []
        for group in after.groups {
            let target: URL?
            switch group.cleanup { case .returned(_, let url), .confirmed(_, let url, _): target = url; default: target = nil }
            if let target {
                let tree = try ownedGroupFingerprint(after, group: group, root: target, nativeTransition: true)
                repeatedNative.append("\(group.ordinal):\(tree.identity.device):\(tree.identity.inode):\(tree.digest)")
            }
        }
        guard nativeFingerprints == repeatedNative else { throw FileOperationFailure.recoveryUncertain }
        try GroupedCopyProductionWorker.emit(["pid": getpid(), "recordID": id.uuidString,
            "state": record.head.state.rawValue, "revision": record.head.revision,
            "catalogRecordDigest": GroupedProductionFixture.digest(try GroupedProductionFixture.encode(record)),
            "sourceFingerprint": sourceBefore,
            "undoInvalidated": record.head.undoInvalidated, "memberPhases": record.members.map { $0.progress.phase },
            "groups": rows, "canCleanup": summary.canCleanup, "sourceUnchanged": true,
            "canUndo": review.canUndo, "groupedReviewActions": review.availableActions.map(\.rawValue),
            "destinationFingerprint": destinationBefore, "publicFingerprint": publishedBefore,
            "knownNativeFingerprint": GroupedProductionFixture.digest(Data(nativeFingerprints.joined(separator: "\n").utf8)),
            "coldObservationOnly": true, "nativeTrashInvoked": false,
            "collisionObjectPreserved": collision, "nativeCollisionTargetsDistinct": collisionSeparated,
            "noArbitraryTrashSearch": true])
    }

    static func seedCollision(_ fixture: GroupedProductionFixture, id: UUID) throws {
        let record = try groupedRecord(fixture, id: id)
        guard let group = record.groups.first, group.areaIdentity != nil else { throw GroupedProductionHarnessFailure.unsafeFixture }
        let parent = fixture.root.appendingPathComponent("collision-source", isDirectory: true)
        try GroupedProductionFixture.createDirectory(parent)
        let original = parent.appendingPathComponent(group.areaURL.lastPathComponent, isDirectory: true)
        try GroupedProductionFixture.createDirectory(original)
        let marker = Data(("MacExplorer native Trash collision fixture v1\n" + fixture.root.lastPathComponent).utf8)
        try GroupedProductionFixture.write(marker, to: original.appendingPathComponent(".owned-native-collision"))
        let before = try verifiedTree(original, cancellation: OperationCancellation())
        var returned: NSURL?
        try FileManager().trashItem(at: original, resultingItemURL: &returned)
        guard let target = returned as URL?, !target.path.hasPrefix(fixture.root.path + "/") else { throw FileOperationFailure.recoveryUncertain }
        let receipt = NativeTrashCollisionReceipt(target: target, before: before, marker: marker)
        try GroupedProductionFixture.write(GroupedProductionFixture.encode(receipt), to: fixture.root.appendingPathComponent("native-collision.json"))
        guard try inspectCollision(fixture) else { throw FileOperationFailure.recoveryUncertain }
        try GroupedCopyProductionWorker.emit(["pid": getpid(), "nativeCollisionSeeded": true,
            "nativeTrashDefaultRoute": true, "knownTargetRetained": true])
    }

    static func observeOrdinary(_ fixture: GroupedProductionFixture, id: UUID) async throws {
        let sourceBefore = try GroupedProductionFixture.fingerprint(fixture.source)
        guard sourceBefore == (try fixture.seedManifest())["sourceFingerprint"] else { throw GroupedProductionHarnessFailure.unsafeFixture }
        let destinationBefore = try GroupedProductionFixture.metadataFingerprint(fixture.destination)
        let record: JournalRecord
        do {
            let journal = try OperationJournal(fixture.journal)
            guard case .treeV1(let legacy)? = try journal.inspectCatalogRecord(id), legacy.nameRename == nil else {
                throw FileOperationFailure.recoveryUncertain
            }
            record = legacy
        }
        var publicRows: [String] = [], areaRows: [[String: Any]] = [], returned: [String] = []
        for step in record.steps where step.destination.deletingLastPathComponent().path == fixture.destination.path && !step.before.identity.isDirectory {
            guard let expected = step.after else { throw FileOperationFailure.recoveryUncertain }
            let parent = try DirectoryAnchor(fixture.destination, resolve: false)
            guard try EntrySnapshot(parent: parent.fd, name: step.destination.lastPathComponent).sameObject(as: expected.identity) else { throw FileOperationFailure.recoveryUncertain }
            let tree = try verifiedTree(step.destination, cancellation: OperationCancellation())
            guard expected.matches(tree) else { throw FileOperationFailure.recoveryUncertain }
            publicRows.append("\(tree.identity.inode):\(tree.digest)")
        }
        for (ordinal, area) in record.areas.enumerated() {
            let cleanup = record.steps.last { $0.source.path == area.url.path && $0.before.identity.sameObject(as: area.identity) }
            let target = cleanup?.destination ?? area.url
            let anchor = try DirectoryAnchor(target, resolve: false)
            let marker = Data("MacExplorer recovery v1\n\(record.id.uuidString)\nRetained until explicit cleanup.\n".utf8)
            let markerIdentity = try EntrySnapshot(parent: anchor.fd, name: ".mac-explorer-recovery-v1")
            guard anchor.identity.sameObject(as: area.identity),
                  markerIdentity.type == S_IFREG, markerIdentity.size == marker.count,
                  try GroupedCopyFilesystemEvidence.children(in: anchor, cancellation: OperationCancellation(), limit: 1) == [".mac-explorer-recovery-v1"],
                  try OperationJournal.read(name: ".mac-explorer-recovery-v1", anchor: anchor) == marker else { throw FileOperationFailure.recoveryUncertain }
            let tree = try verifiedTree(target, cancellation: OperationCancellation())
            if let cleanup {
                guard let after = cleanup.after, after.matches(tree), cleanup.before.matchesNativeTrashTransition(tree),
                      !target.path.hasPrefix(fixture.root.path + "/") else { throw FileOperationFailure.recoveryUncertain }
                let originalParent = try DirectoryAnchor(area.url.deletingLastPathComponent(), resolve: false)
                try requireAbsent(area.url.lastPathComponent, in: originalParent.fd)
                returned.append("\(tree.identity.inode):\(tree.digest)")
            }
            areaRows.append(["ordinal": ordinal, "cleanupPhase": cleanup == nil ? "none" : "confirmed",
                "knownNativeTargetVerified": cleanup != nil, "ownedInventoryVerified": true])
        }
        let trap = NativeTrashColdTrap()
        var hooks = RecoveryHooks(); hooks.retentionTrash = { _ in try trap.refuse() }
        let engine = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks)
        let summary = try await engine.retentionRecord(recordID: id)
        do {
            let journal = try OperationJournal(fixture.journal)
            guard case .treeV1(let after)? = try journal.inspectCatalogRecord(id),
                  after.revision == record.revision, after.state == record.state else { throw FileOperationFailure.recoveryUncertain }
        }
        guard !trap.wasEntered, sourceBefore == (try GroupedProductionFixture.fingerprint(fixture.source)),
              destinationBefore == (try GroupedProductionFixture.metadataFingerprint(fixture.destination)) else { throw FileOperationFailure.recoveryUncertain }
        try GroupedCopyProductionWorker.emit(["pid": getpid(), "recordID": id.uuidString,
            "state": record.state, "revision": record.revision, "undoInvalidated": record.state == "cleaned",
            "groups": areaRows, "canCleanup": summary.canCleanup, "sourceUnchanged": true,
            "destinationFingerprint": destinationBefore,
            "publicFingerprint": GroupedProductionFixture.digest(Data(publicRows.joined(separator: "\n").utf8)),
            "knownNativeFingerprint": GroupedProductionFixture.digest(Data(returned.joined(separator: "\n").utf8)),
            "coldObservationOnly": true, "nativeTrashInvoked": false, "ordinaryTreeControl": true,
            "noArbitraryTrashSearch": true])
    }

    static func inspectCollision(_ fixture: GroupedProductionFixture) throws -> Bool {
        let receiptURL = fixture.root.appendingPathComponent("native-collision.json")
        var info = stat()
        guard lstat(receiptURL.path, &info) == 0 else {
            guard errno == ENOENT else { throw posixFailure() }; return true
        }
        let receipt = try JSONDecoder().decode(NativeTrashCollisionReceipt.self,
            from: GroupedProductionFixture.read(receiptURL, maximum: 16_384))
        let area = try DirectoryAnchor(receipt.target, resolve: false)
        let markerIdentity = try EntrySnapshot(parent: area.fd, name: ".owned-native-collision")
        guard area.identity.sameObject(as: receipt.before.identity),
              markerIdentity.type == S_IFREG, markerIdentity.size == receipt.marker.count,
              try GroupedCopyFilesystemEvidence.children(in: area, cancellation: OperationCancellation(), limit: 1) == [".owned-native-collision"],
              try OperationJournal.read(name: ".owned-native-collision", anchor: area) == receipt.marker else { throw FileOperationFailure.recoveryUncertain }
        // Native access metadata may still be settling immediately after Trash.
        // Retry only an unstable read of the same recorded object, matching the
        // bounded production post-Trash observation contract; never adopt data.
        var stable: VerifiedTree?
        for attempt in 0..<3 {
            do {
                let candidate = try verifiedTree(receipt.target, cancellation: OperationCancellation())
                guard receipt.before.matchesNativeTrashTransition(candidate) else { throw FileOperationFailure.recoveryUncertain }
                stable = candidate; break
            } catch FileOperationFailure.sourceChanged {
                guard attempt < 2 else { throw FileOperationFailure.sourceChanged }
                Thread.sleep(forTimeInterval: 0.01 * Double(attempt + 1))
            }
        }
        guard stable != nil else { throw FileOperationFailure.recoveryUncertain }
        return true
    }
}
