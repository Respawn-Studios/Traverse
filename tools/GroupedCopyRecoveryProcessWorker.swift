// Concatenate after a frozen copy of GroupedCopyProductionWorker.swift with only
// that worker's @main attribute removed. Never edit the frozen forward helper.
import Darwin
import Foundation
import SQLite3

private final class RecoveryProcessFaultGate: @unchecked Sendable {
    private let lock = NSLock()
    let mechanism: String
    let target: GroupedCopyRecoveryCheckpointStage?
    let member: Int?
    private var reached = false, armed = false, lost = false, stopped = false
    private var events: [[String: String]] = []
    private var sqliteCodes: [Int32] = []
    init(_ mechanism: String, target: GroupedCopyRecoveryCheckpointStage?, member: Int?) {
        self.mechanism = mechanism; self.target = target; self.member = member
    }
    func checkpoint(_ event: GroupedCopyRecoveryCheckpoint, cancellation: OperationCancellation) throws {
        lock.lock()
        guard events.count < 512 else { lock.unlock(); throw GroupedProductionHarnessFailure.bound }
        events.append(["stage": event.stage.rawValue, "member": event.memberOrdinal.map(String.init) ?? "-",
                       "revision": String(event.revision)])
        let hit = !reached && event.stage == target && (member == nil || event.memberOrdinal == member)
        if hit { reached = true; armed = mechanism == "lost_acknowledgement"; stopped = mechanism == "cooperative_stop" }
        lock.unlock()
        guard hit else { return }
        switch mechanism {
        case "cooperative_stop": cancellation.cancel()
        case "injected_error": throw FileOperationFailure.ioFailure
        case "process_crash":
            var value = status()
            value.merge(["pid": getpid(), "recordID": event.recordID.uuidString, "mechanism": mechanism,
                         "checkpoint": event.stage.rawValue, "termination": "_exit(86)",
                         "actionAchieved": false, "acknowledgedActionAchieved": false,
                         "actionAchievedSemantics": "acknowledged_successful_return"]) { _, new in new }
            try GroupedCopyProductionWorker.emit(value); _exit(86)
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
    func observedSQLite(_ code: Int32) { lock.lock(); defer { lock.unlock() }; if sqliteCodes.count < 256 { sqliteCodes.append(code) } }
    func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["targetReached": reached, "acknowledgementLost": lost, "stopIssued": stopped,
                "events": events, "observedSQLiteFailureCodes": sqliteCodes,
                "sqliteFailureCount": sqliteCodes.count, "genuineSQLiteFullCount": sqliteCodes.filter { $0 & 0xff == 13 }.count]
    }
}

/// This oracle reads literal slots directly. It does not call the production
/// recovery classifier or borrow its public/private state labels.
private enum RecoveryProcessOracle {
    static func children(_ url: URL, maximum: Int) throws -> Set<Data> {
        try GroupedProductionFixture.directory(url)
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw GroupedProductionHarnessFailure.io }; defer { close(descriptor) }
        var values = Set<Data>()
        try GroupedProductionFixture.eachName(in: descriptor, maximum: maximum) { _ = values.insert(Data($0.utf8)) }
        return values
    }
    static func record(_ fixture: GroupedProductionFixture, _ id: UUID) throws -> GroupedCopyRecord {
        let journal = try OperationJournal(fixture.journal)
        guard case .groupedCopyV1(let record)? = try journal.inspectCatalogRecord(id), record.members.count <= 33 else {
            throw GroupedProductionHarnessFailure.unsafeFixture
        }
        for member in record.members {
            guard member.manifest.source.parent.path == fixture.source.path,
                  member.manifest.destination.parent.path == fixture.destination.path else { throw GroupedProductionHarnessFailure.unsafeFixture }
            if let declaration = member.progress.declaration {
                guard record.groups.indices.contains(declaration.groupOrdinal),
                      declaration.areaURL.deletingLastPathComponent().path == record.groups[declaration.groupOrdinal].areaURL.path,
                      record.groups[declaration.groupOrdinal].areaURL.deletingLastPathComponent().path == fixture.destination.path,
                      declaration.payloadName == Data("payload".utf8) else { throw GroupedProductionHarnessFailure.unsafeFixture }
            }
        }
        return record
    }
    static func slot(_ url: URL, seal: GroupedCopySeal?) throws -> String {
        var value = stat()
        let (status, failure) = url.withUnsafeFileSystemRepresentation { pointer -> (Int32, Int32) in
            guard let pointer else { return (-1, EINVAL) }; let result = lstat(pointer, &value); return (result, errno)
        }
        if status != 0 { guard failure == ENOENT else { return "unavailable" }; return "absent" }
        guard value.st_uid == geteuid(), value.st_mode & 0o077 == 0,
              value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else { return "foreign" }
        guard let seal else { return "unsealed" }
        do {
            let parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
            let literal = try NativeRenameEntry.observe(parent: parent, name: url.lastPathComponent)
            guard literal.nameBytes == Data(url.lastPathComponent.utf8) else { return "changed" }
            let tree = try verifiedTree(parent: parent.fd, name: url.lastPathComponent, cancellation: OperationCancellation())
            let nodes = try snapshotTree(parent: parent.fd, name: url.lastPathComponent, cancellation: OperationCancellation())
            try parent.validate()
            return nodes.count == 1 && tree.identity == literal.identity && seal.proof.payload.matches(tree)
                && stagingIdentityDigest(nodes) == seal.proof.identityDigest ? "matched" : "changed"
        } catch { return "changed" }
    }
    static func snapshot(_ fixture: GroupedProductionFixture, _ id: UUID) throws -> [String: Any] {
        let record = try record(fixture, id)
        var rows: [[String: Any]] = []
        var expectedPublic = Set(record.groups.map { Data($0.areaURL.lastPathComponent.utf8) })
        for member in record.members {
            let publicSlot = try slot(member.manifest.destination.url, seal: member.progress.seal)
            let privateSlot: String
            var exactArea = true
            if publicSlot != "absent" { expectedPublic.insert(member.manifest.destination.nameBytes) }
            if let declaration = member.progress.declaration {
                privateSlot = try slot(declaration.areaURL.appendingPathComponent("payload"), seal: member.progress.seal)
                let expected: Set<Data> = privateSlot == "absent" ? [] : [Data("payload".utf8)]
                exactArea = (try children(declaration.areaURL, maximum: 4)) == expected
                if let seal = member.progress.seal {
                    let area = try DirectoryAnchor(declaration.areaURL, resolve: false)
                    exactArea = exactArea && area.identity.sameObject(as: seal.areaIdentity)
                }
            } else { privateSlot = "notDeclared" }
            rows.append(["ordinal": member.ordinal, "phase": member.progress.phase, "public": publicSlot,
                         "private": privateSlot, "areaInventoryExact": exactArea])
        }
        let exactPublic = (try children(fixture.destination, maximum: 64)) == expectedPublic
        var groups: [[String: Any]] = []
        for group in record.groups {
            var expected = Set(group.members.compactMap { record.members[$0].progress.declaration.map { Data($0.areaURL.lastPathComponent.utf8) } })
            expected.insert(Data(GroupedCopyGroup.markerName.utf8))
            let area = try DirectoryAnchor(group.areaURL, resolve: false)
            let identity = group.areaIdentity.map { area.identity.sameObject(as: $0) } ?? false
            let marker = try GroupedProductionFixture.read(group.areaURL.appendingPathComponent(GroupedCopyGroup.markerName), maximum: 256)
            groups.append(["ordinal": group.ordinal, "inventoryExact": (try children(group.areaURL, maximum: 20)) == expected,
                           "identityMatched": identity, "markerMatched": marker == group.marker])
        }
        let intent: Any
        if let review = record.head.reviewIntent { intent = ["kind": review.kind.rawValue, "members": review.members] as [String: Any] }
        else { intent = NSNull() }
        return ["revision": record.head.revision, "state": record.head.state.rawValue,
                "reviewIntent": intent, "undoInvalidated": record.head.undoInvalidated, "members": rows,
                "groupPhases": record.groups.map { $0.phase.rawValue }, "groups": groups, "publicInventoryExact": exactPublic,
                "sourceFingerprint": try GroupedProductionFixture.fingerprint(fixture.source),
                "destinationFingerprint": try GroupedProductionFixture.fingerprint(fixture.destination)]
    }
    static func pageBudget(_ fixture: GroupedProductionFixture) throws -> (pages: Int64, free: Int64) {
        try GroupedProductionFixture.directory(fixture.journal)
        let url = fixture.journal.appendingPathComponent("operations-v2.sqlite")
        var before = stat()
        guard lstat(url.path, &before) == 0, before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & S_IFMT == S_IFREG, before.st_mode & 0o077 == 0, before.st_size <= 67_108_864 else {
            throw GroupedProductionHarnessFailure.unsafeFixture
        }
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
        var after = stat()
        guard lstat(url.path, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              pages > 0, pages <= 16_384, free >= 0, free <= pages else { throw GroupedProductionHarnessFailure.unsafeFixture }
        return (pages, free)
    }
    static func rewrite(_ url: URL) throws {
        try GroupedProductionFixture.directory(url.deletingLastPathComponent())
        let descriptor = open(url.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw GroupedProductionHarnessFailure.io }; defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_uid == geteuid(), value.st_nlink == 1,
              value.st_mode & S_IFMT == S_IFREG, value.st_mode & 0o077 == 0 else { throw GroupedProductionHarnessFailure.unsafeFixture }
        let bytes = Data("Changed generated recovery qualification object v1\n".utf8)
        guard ftruncate(descriptor, 0) == 0,
              bytes.withUnsafeBytes({ Darwin.write(descriptor, $0.baseAddress, $0.count) }) == bytes.count,
              fsync(descriptor) == 0 else { throw GroupedProductionHarnessFailure.io }
    }
    static func change(_ fixture: GroupedProductionFixture, id: UUID, kind: String, member ordinal: Int) throws {
        let record = try record(fixture, id)
        guard record.members.indices.contains(ordinal) else { throw GroupedProductionHarnessFailure.unsafeFixture }
        let member = record.members[ordinal]
        switch kind {
        case "source_edit": try rewrite(member.manifest.source.url)
        case "source_remove":
            let parent = try DirectoryAnchor(fixture.source, resolve: false)
            let original = try NativeRenameEntry.observe(parent: parent, name: member.manifest.source.name)
            guard original.identity.sameObject(as: member.manifest.sourceTree.identity), original.nameBytes == member.manifest.source.nameBytes,
                  try NativeRenameEntry.observe(parent: parent, name: member.manifest.source.name).identity == original.identity,
                  unlinkat(parent.fd, member.manifest.source.name, 0) == 0 else { throw GroupedProductionHarnessFailure.unsafeFixture }
            try syncDirectory(parent)
        case "public_corrupt": try rewrite(member.manifest.destination.url)
        case "private_corrupt":
            guard let declaration = member.progress.declaration else { throw GroupedProductionHarnessFailure.unsafeFixture }
            try GroupedProductionFixture.directory(record.groups[declaration.groupOrdinal].areaURL)
            try rewrite(declaration.areaURL.appendingPathComponent("payload"))
        case "marker_corrupt":
            guard let declaration = member.progress.declaration else { throw GroupedProductionHarnessFailure.unsafeFixture }
            try rewrite(record.groups[declaration.groupOrdinal].areaURL.appendingPathComponent(GroupedCopyGroup.markerName))
        case "extra_child":
            guard let declaration = member.progress.declaration else { throw GroupedProductionHarnessFailure.unsafeFixture }
            try GroupedProductionFixture.directory(record.groups[declaration.groupOrdinal].areaURL)
            try GroupedProductionFixture.write(Data("Generated foreign inventory v1\n".utf8), to: declaration.areaURL.appendingPathComponent("extra"))
        default: throw GroupedProductionHarnessFailure.unsafeFixture
        }
    }
}

@main private enum GroupedCopyRecoveryProcessWorker {
    /// Explicit qualification calls, not an engine retry. Every successful
    /// priming call stops immediately after its own durable review intent. The
    /// fixed page cap and unchanged payload namespace are checked each time.
    static func confirmationStoragePressure(_ fixture: GroupedProductionFixture, id: UUID,
                                           action: CopyRecoveryAction, stage: ProductionDiagnosticStage) async throws {
        guard action == .confirmCopies || action == .confirmUndo else { throw GroupedProductionHarnessFailure.unsafeFixture }
        let budget = try RecoveryProcessOracle.pageBudget(fixture)
        let initial = try RecoveryProcessOracle.snapshot(fixture, id)
        var attempts: [[String: Any]] = []
        var primed = 0
        for ordinal in 0..<256 {
            stage.set("recovery_storage_pressure_explicit_attempt")
            let gate = RecoveryProcessFaultGate("cooperative_stop", target: .reviewIntentCommitted, member: nil)
            var hooks = RecoveryHooks()
            hooks.groupedCopy.qualification = try GroupedCopyQualification(root: fixture.root)
            hooks.groupedRecovery.checkpoint = { try gate.checkpoint($0, cancellation: $1) }
            hooks.journalHooks.maximumPageCount = budget.pages
            hooks.journalHooks.observedSQLiteFailureCode = { gate.observedSQLite($0) }
            let engine = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks)
            let before = try RecoveryProcessOracle.snapshot(fixture, id)
            let priorIntent = try RecoveryProcessOracle.record(fixture, id).head.reviewIntent
            let review = try await engine.prepareGroupedRecovery(recordID: id)
            guard review.availableActions.contains(action) else { throw GroupedProductionHarnessFailure.unsafeFixture }
            let result = await engine.performGroupedRecovery(action: action, from: review)
            let after = try RecoveryProcessOracle.snapshot(fixture, id)
            let intent = try RecoveryProcessOracle.record(fixture, id).head.reviewIntent
            let currentBudget = try RecoveryProcessOracle.pageBudget(fixture)
            guard currentBudget.pages == budget.pages,
                  initial["sourceFingerprint"] as? String == after["sourceFingerprint"] as? String,
                  initial["destinationFingerprint"] as? String == after["destinationFingerprint"] as? String else {
                throw GroupedProductionHarnessFailure.unsafeFixture
            }
            let outcomes: [[String: Any]] = result.result.items.map { item in
                let status: String, failure: String
                switch item.status {
                case .succeeded: status = "succeeded"; failure = "none"
                case .cancelled: status = "cancelled"; failure = "none"
                case .notStarted: status = "notStarted"; failure = "none"
                case .skipped: status = "skipped"; failure = "none"
                case .failed(let reason): status = "failed"; failure = reason.rawValue
                }
                return ["ordinal": NSNull(), "role": item.role.rawValue, "status": status, "failure": failure]
            }
            var receipt = gate.status()
            receipt.merge(["ordinal": ordinal, "before": before, "after": after,
                "requestedMaximumPages": budget.pages, "observedPageCount": currentBudget.pages,
                "disposition": result.result.disposition.rawValue, "cancellationRequested": result.result.cancellationRequested,
                "returnedOutcomes": outcomes, "returnedSuccessCount": result.result.items.filter { $0.status == .succeeded }.count,
                "priorStoredIntentID": priorIntent.map { $0.id.uuidString as Any } ?? NSNull(),
                "storedIntentID": intent.map { $0.id.uuidString as Any } ?? NSNull(),
                "storedIntentPreparedRevision": intent.map { $0.preparedRevision as Any } ?? NSNull(),
                "sourceUnchanged": true, "confirmationNamespaceUnchanged": true,
                "freshExplicitReviewToken": true]) { _, new in new }
            attempts.append(receipt)
            let full = (receipt["genuineSQLiteFullCount"] as? Int ?? 0) > 0
            if !full, receipt["targetReached"] as? Bool == true,
               receipt["stopIssued"] as? Bool == true, result.result.cancellationRequested,
               result.result.disposition == .cancelled, result.result.items.count == 1,
               result.result.items[0].role == .job, result.result.items[0].status == .cancelled {
                primed += 1
                if ordinal < 255 { continue }
            }
            // Include all evidence even if the bounded pressure experiment did
            // not produce FULL. The runner must fail that case, never relabel it.
            var value = gate.status()
            value.merge(["pid": getpid(), "recordID": id.uuidString, "mechanism": "sqlite_full", "snapshot": after,
                "disposition": result.result.disposition.rawValue, "cancellationRequested": result.result.cancellationRequested,
                "returnedSuccessCount": result.result.items.filter { $0.status == .succeeded }.count,
                "returnedOutcomeRoles": result.result.items.map { $0.role.rawValue }, "returnedOutcomes": outcomes,
                "sourceUnchanged": true, "confirmationNamespaceUnchanged": true,
                "actionAchieved": result.result.disposition == .succeeded, "acknowledgedActionAchieved": result.result.disposition == .succeeded,
                "actionAchievedSemantics": "acknowledged_successful_return",
                "storagePressure": ["requestedMaximumPages": budget.pages, "initialFreePages": budget.free,
                    "maximumAttempts": 256, "attemptCount": attempts.count, "primingAttemptCount": primed,
                    "attempts": attempts, "failedAttemptBefore": before, "fixtureExplicitAttempts": true,
                    "productionAutomaticRetry": false, "pressureExhaustedWithoutFull": !full && ordinal == 255]]) { _, new in new }
            try GroupedCopyProductionWorker.emit(value); return
        }
        throw GroupedProductionHarnessFailure.bound
    }

    static func main() async {
        let stage = ProductionDiagnosticStage("recovery_validate_arguments")
        do { try await execute(stage: stage) }
        catch { try? GroupedCopyProductionWorker.emit(["pid": getpid(), "failed": true, "stage": stage.value,
                                                       "failureKind": "recovery_qualification_failure"]); exit(1) }
    }
    static func execute(stage: ProductionDiagnosticStage) async throws {
        let args = CommandLine.arguments
        guard args.count == 8, ["review", "action", "undo", "change", "authority"].contains(args[1]), let id = UUID(uuidString: args[3]),
              ["none", "cooperative_stop", "injected_error", "process_crash", "lost_acknowledgement", "sqlite_full"].contains(args[6]) else {
            throw GroupedProductionHarnessFailure.unsafeFixture
        }
        let fixture = try GroupedProductionFixture(args[2])
        let checkpoint = args[5] == "none" ? nil : GroupedCopyRecoveryCheckpointStage(rawValue: args[5])
        let member = args[7] == "-" ? nil : Int(args[7])
        guard (["none", "sqlite_full"].contains(args[6]) && checkpoint == nil) || (!["none", "sqlite_full"].contains(args[6]) && checkpoint != nil),
              args[7] == "-" || (member != nil && (0..<33).contains(member!)) else { throw GroupedProductionHarnessFailure.unsafeFixture }
        if args[6] == "lost_acknowledgement" {
            guard [.reviewIntentWillCommit, .reviewWillRecordOutcomes, .reverseIntentWillCommit,
                   .reverseWillRecordOutcome, .reverseTerminalWillCommit].contains(checkpoint!) else { throw GroupedProductionHarnessFailure.unsafeFixture }
        }
        if args[1] == "change" {
            guard args[6] == "none", let member else { throw GroupedProductionHarnessFailure.unsafeFixture }
            stage.set("recovery_deliberate_fixture_change")
            try RecoveryProcessOracle.change(fixture, id: id, kind: args[4], member: member)
            try GroupedCopyProductionWorker.emit(["pid": getpid(), "deliberateFixtureChange": args[4], "snapshot": try RecoveryProcessOracle.snapshot(fixture, id)])
            return
        }
        if args[1] == "action", args[6] == "sqlite_full" {
            guard let action = CopyRecoveryAction(rawValue: args[4]) else { throw GroupedProductionHarnessFailure.unsafeFixture }
            try await confirmationStoragePressure(fixture, id: id, action: action, stage: stage)
            return
        }
        let gate = RecoveryProcessFaultGate(args[6], target: checkpoint, member: member)
        var hooks = RecoveryHooks()
        hooks.groupedCopy.qualification = try GroupedCopyQualification(root: fixture.root)
        hooks.groupedRecovery.checkpoint = { try gate.checkpoint($0, cancellation: $1) }
        hooks.journalHooks.afterCommitBeforeAcknowledgement = { try gate.afterCommit() }
        hooks.journalHooks.observedSQLiteFailureCode = { gate.observedSQLite($0) }
        var pressure: [String: Any] = [:]
        if args[6] == "sqlite_full" {
            let budget = try RecoveryProcessOracle.pageBudget(fixture)
            hooks.journalHooks.maximumPageCount = budget.pages
            pressure = ["requestedMaximumPages": budget.pages, "initialFreePages": budget.free]
        }
        let engine = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks)
        let before = try RecoveryProcessOracle.snapshot(fixture, id)
        stage.set("recovery_prepare_review")
        let review: GroupedCopyRecoveryReview
        do { review = try await engine.prepareGroupedRecovery(recordID: id) }
        catch {
            let after = try RecoveryProcessOracle.snapshot(fixture, id)
            guard NSDictionary(dictionary: before).isEqual(to: after) else { throw GroupedProductionHarnessFailure.unsafeFixture }
            var value = gate.status(); value.merge(["pid": getpid(), "failed": true, "stage": stage.value,
                "failureKind": "reader_interruption", "snapshot": after, "actionAchieved": false,
                "acknowledgedActionAchieved": false, "noForwardAutoAction": true,
                "sourceUnchanged": true, "namespaceUnchanged": true]) { _, new in new }
            try GroupedCopyProductionWorker.emit(value); exit(1)
        }
        if args[1] == "review" {
            let after = try RecoveryProcessOracle.snapshot(fixture, id)
            guard NSDictionary(dictionary: before).isEqual(to: after) else { throw GroupedProductionHarnessFailure.unsafeFixture }
            var value = gate.status(); value.merge(["pid": getpid(), "recordID": id.uuidString, "snapshot": after,
                "availableActions": review.availableActions.map(\.rawValue), "canUndo": review.canUndo,
                "itemStates": review.items.map { $0.state.rawValue }, "protectionReasons": review.items.map { $0.protectionReason ?? "none" },
                "namespaceUnchanged": true, "sourceUnchanged": true, "noForwardAutoAction": true]) { _, new in new }
            try GroupedCopyProductionWorker.emit(value); return
        }
        stage.set("recovery_explicit_action")
        let result: RecoverableOperationResult
        var rejectedBaseline = before
        if args[1] == "authority" {
            guard args[6] == "none", let action = review.availableActions.first else { throw GroupedProductionHarnessFailure.unsafeFixture }
            switch args[4] {
            case "foreign_session":
                let foreign = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks)
                result = await foreign.performGroupedRecovery(action: action, from: review)
            case "reuse":
                let first = await engine.performGroupedRecovery(action: action, from: review)
                guard first.result.disposition == .succeeded else { throw GroupedProductionHarnessFailure.unsafeFixture }
                rejectedBaseline = try RecoveryProcessOracle.snapshot(fixture, id)
                result = await engine.performGroupedRecovery(action: action, from: review)
            case "revision":
                do {
                    let journal = try OperationJournal(fixture.journal)
                    guard let edit = try journal.openGroupedEdit(id) else { throw GroupedProductionHarnessFailure.unsafeFixture }
                    try edit.markNeedsReview(); try journal.save(edit)
                }
                rejectedBaseline = try RecoveryProcessOracle.snapshot(fixture, id)
                result = await engine.performGroupedRecovery(action: action, from: review)
            case "inventory":
                try RecoveryProcessOracle.change(fixture, id: id, kind: "public_corrupt", member: 0)
                rejectedBaseline = try RecoveryProcessOracle.snapshot(fixture, id)
                result = await engine.performGroupedRecovery(action: action, from: review)
            default: throw GroupedProductionHarnessFailure.unsafeFixture
            }
        } else if args[1] == "undo" { result = await engine.undo(recordID: id) }
        else {
            guard let action = CopyRecoveryAction(rawValue: args[4]), review.availableActions.contains(action) else { throw GroupedProductionHarnessFailure.unsafeFixture }
            result = await engine.performGroupedRecovery(action: action, from: review)
        }
        let after = try RecoveryProcessOracle.snapshot(fixture, id)
        guard before["sourceFingerprint"] as? String == after["sourceFingerprint"] as? String else { throw GroupedProductionHarnessFailure.unsafeFixture }
        let namespaceUnchanged = before["destinationFingerprint"] as? String == after["destinationFingerprint"] as? String
        if args[1] == "action" { guard namespaceUnchanged else { throw GroupedProductionHarnessFailure.unsafeFixture } }
        let rejectionUnchanged = NSDictionary(dictionary: rejectedBaseline).isEqual(to: after)
        if args[1] == "authority" { guard result.result.disposition == .failed, rejectionUnchanged else { throw GroupedProductionHarnessFailure.unsafeFixture } }
        let finalRecord = try RecoveryProcessOracle.record(fixture, id)
        let returned: [[String: Any]] = try result.result.items.map { item in
            let ordinal: Any
            if item.role == .transfer {
                guard args[1] == "undo", let source = item.source, let destination = item.destination,
                      let member = finalRecord.members.first(where: { $0.manifest.destination.url.path == source.path }),
                      let declaration = member.progress.declaration,
                      declaration.areaURL.appendingPathComponent("payload").path == destination.path else {
                    throw GroupedProductionHarnessFailure.unsafeFixture
                }
                ordinal = member.ordinal
            } else { ordinal = NSNull() }
            let status: String, failure: String
            switch item.status {
            case .succeeded: status = "succeeded"; failure = "none"
            case .cancelled: status = "cancelled"; failure = "none"
            case .notStarted: status = "notStarted"; failure = "none"
            case .skipped: status = "skipped"; failure = "none"
            case .failed(let reason): status = "failed"; failure = reason.rawValue
            }
            return ["ordinal": ordinal, "role": item.role.rawValue, "status": status, "failure": failure]
        }
        var value = gate.status()
        value.merge(["pid": getpid(), "recordID": id.uuidString, "mechanism": args[6], "snapshot": after,
            "disposition": result.result.disposition.rawValue, "cancellationRequested": result.result.cancellationRequested,
            "returnedSuccessCount": result.result.items.filter { $0.status == .succeeded }.count,
            "returnedOutcomeRoles": result.result.items.map { $0.role.rawValue },
            "returnedOutcomes": returned,
            "returnedOutcomeStatuses": result.result.items.map { item in
                switch item.status { case .succeeded: "succeeded"; case .cancelled: "cancelled"; case .notStarted: "notStarted"; case .skipped: "skipped"; case .failed: "failed" }
            }, "sourceUnchanged": true, "confirmationNamespaceUnchanged": namespaceUnchanged,
            "rejectionUnchanged": rejectionUnchanged, "actionAchieved": result.result.disposition == .succeeded,
            "acknowledgedActionAchieved": result.result.disposition == .succeeded,
            "actionAchievedSemantics": "acknowledged_successful_return",
            "storagePressure": pressure]) { _, new in new }
        try GroupedCopyProductionWorker.emit(value)
    }
}
