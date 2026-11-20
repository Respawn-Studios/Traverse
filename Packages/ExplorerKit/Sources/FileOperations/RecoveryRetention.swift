import Darwin
import Foundation

public struct RecoveryRetentionArea: Sendable {
    public let url: URL
    /// Logical file sizes, including hard-link paths; not guaranteed reclaimable disk space.
    public let logicalBytes: Int64?
    public let verified: Bool
    public let protectionReason: String?
}

public struct RecoveryRetentionRecord: Identifiable, Sendable {
    public let id: UUID
    public let operation: String
    public let createdAt: Date
    public let state: String
    public let areas: [RecoveryRetentionArea]
    public let logicalBytes: Int64?
    public let canCleanup: Bool
    public let protectionReason: String?
}

public struct RecoveryRetentionInspection: Sendable {
    public let records: [RecoveryRetentionRecord]
    public let refusedEntries: [URL]
    public let nextRecordID: UUID?
    public let automaticExpiryEnabled = false
}

public struct RecoveryJournalMaintenance: Sendable {
    public let databaseBytes: Int64
    public let eventCount: Int64
    public let freePages: Int64
}

extension RecoverableFileOperations {
    /// Verify only the selected job; opening the summary list need not hash every backup.
    public func retentionRecord(recordID: UUID) async throws -> RecoveryRetentionRecord {
        try await worker { cancellation in
            let record = try OperationHistoryInspector.record(self.directory, id: recordID, cancellation: cancellation)
            return try self.retentionRecord(record, cancellation: cancellation)
        }
    }

    public func retentionInspection(after: UUID? = nil, limit: Int = 64) async throws -> RecoveryRetentionInspection {
        try await worker { cancellation in
            let inspection = try OperationHistoryInspector.inspect(self.directory, after: after, limit: limit, cancellation: cancellation)
            guard inspection.readiness == .absent || { if case .available = inspection.readiness { return true }; return false }() else {
                throw FileOperationFailure.unavailable
            }
            let records = try inspection.records.map { summary in
                try cancellation.check()
                let record = try OperationHistoryInspector.record(self.directory, id: summary.id, cancellation: cancellation)
                return try self.retentionRecord(record, cancellation: cancellation)
            }
            return RecoveryRetentionInspection(records: records, refusedEntries: inspection.refusedEntries, nextRecordID: inspection.nextCursor)
        }
    }

    /// Metadata maintenance preserves current recovery records and legacy evidence.
    public func compactJournal() async throws -> RecoveryJournalMaintenance {
        try await worker { cancellation in
            try cancellation.check()
            let journal = try OperationJournal(self.directory, cancellation: cancellation)
            let summary = try journal.maintenance(compact: true)
            return RecoveryJournalMaintenance(databaseBytes: summary.databaseBytes,
                                              eventCount: summary.eventCount, freePages: summary.freePages)
        }
    }

    /// Call only after explicit selection and confirmation. Moves owned recovery areas
    /// to system Trash; never permanently deletes, automatically expires or resumes them.
    public func cleanupRecovery(recordID: UUID,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> RecoverableOperationResult {
        await cleanupRecovery(recordID: recordID, progress: progress, journalHooks: hooks.journalHooks)
    }

    internal func cleanupRecovery(recordID: UUID, progress: (@Sendable (OperationProgress) -> Void)?,
                                  journalHooks: JournalStorageHooks) async -> RecoverableOperationResult {
        let reporter = OperationProgressReporter(jobID: recordID, callback: progress)
        do {
            let result = try await worker(progress: reporter) { cancellation in
                guard self.nativeTrashPolicy == .existingVerifiedPaths else { throw FileOperationFailure.unsupported }
                return try self.cleanupRetainedRecord(recordID, cancellation: cancellation, journalHooks: journalHooks)
            }
            reporter.finish(success: result.result.disposition == .succeeded)
            return result
        } catch {
            reporter.finish(success: false)
            return RecoverableOperationResult(result: FileOperationResult(items: [
                FileOperationOutcome(source: nil, destination: nil, status: operationStatus(error), recoveryURLs: [])
            ], cancellationRequested: error is CancellationError), recordID: recordID)
        }
    }

    private func retentionRecord(_ record: OperationCatalogRecord, cancellation: OperationCancellation) throws -> RecoveryRetentionRecord {
        switch record {
        case .treeV1(let ordinary), .nameRenameV2(let ordinary),
             .treeV3(let ordinary), .nameRenameV4(let ordinary),
             .archiveUpdateV5(let ordinary), .archiveStrictCloneV6(let ordinary),
             .archiveNativeUpdateV13(let ordinary), .tarNativeUpdateV18(let ordinary), .tarGzipNativeUpdateV19(let ordinary), .tarBzip2NativeUpdateV20(let ordinary),
             .receivedPublicDownloadV14(let ordinary),
             .publicZIPExtractionFileV15(let ordinary),
             .publicProducedTreeV16(let ordinary),
             .publicTARExtractionFileV17(let ordinary),
             .downloadAdoptionV7(let ordinary), .treeTrashRootAddV9(let ordinary),
             .treeNativeTrashV11(let ordinary), .treeNativeTrashV12(let ordinary):
            return try retentionRecord(ordinary, cancellation: cancellation)
        case .groupedCopyV1(let grouped):
            return try groupedRetentionRecord(grouped, cancellation: cancellation)
        case .selectionGroupV2(let grouped):
            return try selectionRetentionRecord(grouped, cancellation: cancellation)
        case .textRevisionV3(let record):
            return try textRetentionRecord(record, cancellation: cancellation)
        case .ownedTrashV8(let record), .ownedTrashRootAddDeleteV10(let record):
            return RecoveryRetentionRecord(id: record.id, operation: record.operation, createdAt: record.createdAt,
                state: record.state, areas: [], logicalBytes: nil, canCleanup: false,
                protectionReason: "This Trash group has a separate permanent-deletion review.")
        }
    }

    private func retentionRecord(_ record: JournalRecord, cancellation: OperationCancellation) throws -> RecoveryRetentionRecord {
        let reason = cleanupEligibilityReason(record)
        if let reason {
            // Protected states are inspection-only. Do not rehash their bodies just to
            // redisplay a refusal, and never treat recorded locations as cleanup inputs.
            let projected = try? retainedAreas(record, cancellation: cancellation)
            try cancellation.check()
            let areas = (projected?.map(\.url) ?? record.areas.map(\.url)).map {
                RecoveryRetentionArea(url: $0, logicalBytes: nil, verified: false, protectionReason: reason)
            }
            return RecoveryRetentionRecord(id: record.id, operation: record.operation, createdAt: record.createdAt,
                state: record.state, areas: areas, logicalBytes: nil, canCleanup: false, protectionReason: reason)
        }
        var areas: [RecoveryRetentionArea] = []
        var outerBytes: Int64 = 0
        var protected = reason
        do {
            let projected = try retainedAreas(record, cancellation: cancellation)
            let outer = outermost(projected.map(\.url))
            let budget = TraversalBudget()
            for area in projected {
                try cancellation.check()
                do {
                    let validated = try validateRetainedArea(area, record: record, cancellation: cancellation)
                    var bytes: Int64?
                    if outer.contains(area.url) {
                        let start = budget.bytes
                        try inventoryBytes(area.url, budget: budget, cancellation: cancellation)
                        bytes = budget.bytes - start
                        let (sum, overflow) = outerBytes.addingReportingOverflow(bytes!)
                        guard !overflow else { throw FileOperationFailure.unsupported }
                        outerBytes = sum
                    }
                    _ = validated
                    areas.append(RecoveryRetentionArea(url: area.url, logicalBytes: bytes, verified: reason == nil,
                                                       protectionReason: reason))
                } catch {
                    if error is CancellationError { throw error }
                    protected = "A retained area is changed, unavailable or cannot be verified safely."
                    areas.append(RecoveryRetentionArea(url: area.url, logicalBytes: nil, verified: false,
                                                       protectionReason: protected))
                }
            }
        } catch {
            if error is CancellationError { throw error }
            protected = "Recovery-area locations cannot be resolved safely."
            areas = record.areas.map { RecoveryRetentionArea(url: $0.url, logicalBytes: nil, verified: false,
                                                             protectionReason: protected) }
        }
        if areas.isEmpty { protected = protected ?? "This job has no retained recovery area." }
        return RecoveryRetentionRecord(id: record.id, operation: record.operation, createdAt: record.createdAt,
            state: record.state, areas: areas, logicalBytes: protected == nil ? outerBytes : nil,
            canCleanup: protected == nil, protectionReason: protected)
    }

    private func cleanupRetainedRecord(_ id: UUID, cancellation: OperationCancellation,
                                       journalHooks: JournalStorageHooks) throws -> RecoverableOperationResult {
        let journal = try OperationJournal(directory, hooks: journalHooks, cancellation: cancellation)
        try journal.validateWritableCatalog()
        if case .textRevisionV3? = try journal.inspectCatalogRecord(id) { throw FileOperationFailure.unsupported }
        if case .selectionGroupV2(let grouped)? = try journal.inspectCatalogRecord(id) {
            return cleanupSelectionGroupRecord(grouped, journal: journal, cancellation: cancellation)
        }
        if case .groupedCopyV1? = try journal.inspectCatalogRecord(id) {
            guard let grouped = try journal.openGroupedEdit(id) else { throw FileOperationFailure.recoveryUncertain }
            return cleanupGroupedRecord(grouped, journal: journal, cancellation: cancellation)
        }
        if let selected = try journal.inspectCatalogRecord(id),
           selected.legacy.map({ [8, 10].contains($0.version) }) == true {
            throw FileOperationFailure.unsupported
        }
        guard let record = try journal.openEdit(id), cleanupEligibilityReason(record.snapshot) == nil else {
            throw FileOperationFailure.recoveryUncertain
        }
        let areas = try retainedAreas(record.snapshot, cancellation: cancellation)
        guard !areas.isEmpty else { throw FileOperationFailure.invalidRequest }
        // Verify every nested area as well as its container before the first mutation.
        for area in areas { _ = try validateRetainedArea(area, record: record.snapshot, cancellation: cancellation) }
        let roots = outermost(areas.map(\.url))
        try OperationJournal.validateCapacity(steps: record.steps.count + roots.count, areas: record.areas.count,
            locations: record.locations.count + roots.count * 2, trashIntents: record.trashIntents.count + roots.count)
        try cancellation.check()
        // Invalidate Undo durably before writing any native Trash intent.
        record.setState("cleanupReview")
        record.setFailureStage("cleanup-prepared")
        try journal.save(record)
        var outcomes: [FileOperationOutcome] = []
        do {
            for (index, url) in roots.enumerated() {
                try cancellation.check()
                cancellation.progress?.begin(.retaining, source: url, index: index + 1, count: roots.count,
                                              items: roots.count)
                guard let area = areas.first(where: { $0.url == url }) else { throw FileOperationFailure.recoveryUncertain }
                // Fresh recursive guards are required at each mutation boundary.
                let before = try validateRetainedArea(area, record: record.snapshot, cancellation: cancellation)
                let parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
                guard before.identity.device == parent.identity.device else { throw FileOperationFailure.unsupported }
                record.setFailureStage("cleanup-trash-intent")
                try record.bindPersistentVolume(in: parent)
                try record.appendTrashIntent(JournalTrashIntent(source: url, sourceParent: parent.identity, before: before))
                try journal.save(record)
                hooks.afterIntent?()
                // Journal synchronization can take time. Recheck the full retained tree
                // after the durable intent, immediately before admission to native Trash.
                guard before.matches(try validateRetainedArea(area, record: record.snapshot, cancellation: cancellation)) else {
                    throw FileOperationFailure.sourceChanged
                }
                try parent.validate()
                try cancellation.check()
                // Once the native call starts, drain its returned location, validation and
                // durable recording even when Stop arrives. Check Stop before the next area.
                let draining = cancellation.draining()
                record.setFailureStage("cleanup-native-trash")
                let native = legacy.execute(.trash(sources: [url]),
                    observing: FileOperationSelection(urls: [url], identities: [before.identity]), cancellation: draining)
                guard let item = native.items.first else { throw FileOperationFailure.recoveryUncertain }
                let known = [item.destination].compactMap { $0 } + item.recoveryURLs
                try record.appendNewLocations(known)
                record.setFailureStage("cleanup-record-native-result")
                try journal.save(record)
                if case .failed(let failure) = item.status { throw failure }
                if item.status == .cancelled { throw CancellationError() }
                guard item.status == .succeeded, let target = item.destination else { throw FileOperationFailure.recoveryUncertain }
                let targetParent = try DirectoryAnchor(target.deletingLastPathComponent(), resolve: false)
                try record.bindPersistentVolume(in: targetParent)
                let after = try verifyNativeTrashResult(target, before: before, cancellation: draining)
                try parent.validate(); try targetParent.validate()
                try requireAbsent(url.lastPathComponent, in: parent.fd)
                try record.appendStep(JournalStep(source: url, destination: target, sourceParent: parent.identity,
                    destinationParent: targetParent.identity, before: before, after: after))
                record.setFailureStage("cleanup-sync")
                try syncDirectory(parent); try syncDirectory(targetParent)
                try journal.save(record)
                outcomes.append(FileOperationOutcome(source: url, destination: target, status: .succeeded, recoveryURLs: []))
                cancellation.progress?.advance(items: 1)
            }
            record.setState("cleaned"); record.setFailureStage(nil)
            try journal.save(record)
        } catch {
            record.setState("cleanupReview")
            try? journal.save(record)
            outcomes.append(FileOperationOutcome(source: nil, destination: nil, status: operationStatus(error),
                                                  recoveryURLs: record.locations))
        }
        return RecoverableOperationResult(result: FileOperationResult(items: outcomes,
            cancellationRequested: cancellation.isCancelled), recordID: id)
    }
}

private struct RetainedArea {
    let url: URL
    let identity: EntrySnapshot
    let stagingProof: JournalStagingProof?
    let requiresMaterialization: Bool
}

/// Every inverse needs durable materialization evidence; flags alone do not locate objects.
private func cleanupEligibilityReason(_ record: JournalRecord) -> String? {
    if record.version == 7 { return "This adopted Download retains a separate spool handoff and has no qualified recovery cleanup." }
    if [18, 19, 20].contains(record.version) { return "This TAR update keeps its earlier archive for Undo. Cleanup is not available yet." }
    if record.version == 13 { return "This native ZIP update retains its original until cleanup is separately qualified." }
    if record.version == 14 { return "This public-mark Download candidate retains its private recovery area until cleanup is separately qualified." }
    if record.version == 15 { return "This ZIP extraction candidate retains its private recovery area until cleanup is separately qualified." }
    if record.version == 16 { return "This produced tree retains its private recovery area until cleanup is separately qualified." }
    if record.version == 17 { return "This TAR extraction retains its private recovery area until cleanup is separately qualified." }
    if record.nameRename != nil { return "This name-only Rename retains no backup data. Undo keeps current contents while identity remains verifiable." }
    if [5, 6].contains(record.version) && !["committed", "undone"].contains(record.state) {
        return "This ZIP update is unresolved. Its retained original may be the only surviving copy."
    }
    guard ["committed", "undone", "needsReview", "preparing", "mutating"].contains(record.state) else {
        return "This job has an unfinished recovery or cleanup boundary."
    }
    if record.state == "undone" {
        guard !record.steps.isEmpty, record.steps.allSatisfy({ $0.undone }) else {
            return "The journal does not prove completed Undo."
        }
    } else if !record.steps.allSatisfy({ !$0.undone && $0.after != nil }) {
        return "The journal contains an uncertain operation boundary."
    }
    guard record.trashIntents.allSatisfy({ intent in
        record.steps.contains { $0.source == intent.source && $0.after != nil }
    }) else { return "The journal contains an uncertain native Trash boundary." }
    return nil
}

/// Replay the actual forward materializations, then completed inverse renames.
/// A never-executed intent (undone, without after) has no forward mutation.
private func relocated(_ original: URL, through steps: ArraySlice<JournalStep>,
                       reversing inverseSteps: ArraySlice<JournalStep>? = nil,
                       cancellation: OperationCancellation? = nil) throws -> URL {
    var url = original
    func move(_ source: URL, _ destination: URL) {
        if url.path == source.path || url.path.hasPrefix(source.path + "/") {
            url = URL(fileURLWithPath: destination.path + String(url.path.dropFirst(source.path.count)))
        }
    }
    for (index, step) in steps.enumerated() {
        if index % 64 == 0 { try cancellation?.check() }
        guard step.after != nil else {
            if step.undone { continue }
            throw FileOperationFailure.recoveryUncertain
        }
        move(step.source, step.destination)
    }
    for (index, step) in (inverseSteps ?? steps).reversed().enumerated() {
        if index % 64 == 0 { try cancellation?.check() }
        if step.undone && step.after != nil { move(step.destination, step.source) }
    }
    return url
}

func recoveryAreaID(for name: String) -> UUID? {
    let prefix = ".mac-explorer-recovery-"
    guard name.hasPrefix(prefix) else { return nil }
    return UUID(uuidString: String(name.dropFirst(prefix.count)))
}

private func retainedAreas(_ record: JournalRecord, cancellation: OperationCancellation) throws -> [RetainedArea] {
    var paths = Set<String>()
    return try record.areas.map { area in
        try cancellation.check()
        let url = try relocated(area.url, through: record.steps[...], cancellation: cancellation)
        guard paths.insert(url.path).inserted, recoveryAreaID(for: url.lastPathComponent) != nil else {
            throw FileOperationFailure.recoveryUncertain
        }
        return RetainedArea(url: url, identity: area.identity, stagingProof: area.stagingProof,
            requiresMaterialization: !["committed", "undone"].contains(record.state))
    }
}

private func outermost(_ urls: [URL]) -> [URL] {
    urls.filter { url in !urls.contains { other in other != url && url.path.hasPrefix(other.path + "/") } }
        .sorted { $0.path < $1.path }
}

private func validateRetainedArea(_ area: RetainedArea, record: JournalRecord,
                                  cancellation: OperationCancellation) throws -> VerifiedTree {
    try cancellation.check()
    let anchor = try DirectoryAnchor(area.url, resolve: false)
    var attributes = stat()
    guard try record.matchesPersisted(area.identity, anchor.identity, in: anchor),
          fstat(anchor.fd, &attributes) == 0,
          attributes.st_uid == geteuid(), attributes.st_mode & 0o077 == 0 else { throw FileOperationFailure.sourceChanged }
    let markerName = ".mac-explorer-recovery-v1"
    let marker = try OperationJournal.read(name: markerName, anchor: anchor)
    guard marker == Data("MacExplorer recovery v1\n\(record.id.uuidString)\nRetained until explicit cleanup.\n".utf8) else {
        throw FileOperationFailure.recoveryUncertain
    }
    let rootBefore = try verifiedTree(area.url, cancellation: cancellation)
    var expected: [String: VerifiedTree] = [:]
    func expect(_ current: URL, _ tree: VerifiedTree) throws {
        if current.deletingLastPathComponent().path == area.url.path {
            guard current.lastPathComponent != markerName else { throw FileOperationFailure.recoveryUncertain }
            if let prior = expected[current.lastPathComponent], !record.matchesRecorded(prior, tree) {
                throw FileOperationFailure.recoveryUncertain
            }
            expected[current.lastPathComponent] = tree
        }
    }
    for index in record.steps.indices {
        let step = record.steps[index]
        guard step.after != nil || step.undone else { throw FileOperationFailure.recoveryUncertain }
        let materialized = step.after == nil ? step.source : step.destination
        let current = try relocated(materialized, through: record.steps.suffix(from: index + 1),
            reversing: record.steps[...], cancellation: cancellation)
        try expect(current, step.after ?? step.before)
    }
    var stagedCurrent: URL?
    if let proof = area.stagingProof {
        // The proof was recorded at this step frontier, before publication. Its
        // original area URL is recovered by matching the durable area identity.
        guard let original = record.areas.first(where: { $0.identity.sameObject(as: area.identity) }) else {
            throw FileOperationFailure.recoveryUncertain
        }
        let current = try relocated(original.url.appendingPathComponent("payload"),
            through: record.steps.suffix(from: proof.stepCount), reversing: record.steps[...], cancellation: cancellation)
        // A completed rename (including Undo) can qualify a new root security
        // mark. Prefer its full durable image at this exact retained location;
        // the original staging proof still binds every object's identity below.
        let latest = current.deletingLastPathComponent().path == area.url.path
            ? expected[current.lastPathComponent] : nil
        if latest.map({ record.matchesRecorded($0.identity, proof.payload.identity) }) != true {
            try expect(current, proof.payload)
        }
        if current.deletingLastPathComponent().path == area.url.path { stagedCurrent = current }
    }
    if area.requiresMaterialization && expected.isEmpty && area.stagingProof == nil {
        throw FileOperationFailure.recoveryUncertain
    }
    let fd = openat(anchor.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw posixFailure() }
    defer { close(fd) }
    let children = try childNames(in: fd, cancellation: cancellation, limit: OperationLimits.maximumNodes)
    guard Set(children) == Set(expected.keys).union([markerName]) else { throw FileOperationFailure.sourceChanged }
    for (name, after) in expected {
        let current = try verifiedTree(parent: anchor.fd, name: name, cancellation: cancellation)
        guard try record.matchesPersisted(after, current, in: anchor) else {
            throw FileOperationFailure.sourceChanged
        }
    }
    if let current = stagedCurrent, let proof = area.stagingProof {
        let nodes = try snapshotTree(parent: anchor.fd, name: current.lastPathComponent, cancellation: cancellation)
        let volume: PersistentVolumeBinding?
        if proof.version == 2 {
            let observed = try PersistentVolumeBinding.qualified(in: anchor)
            guard let observed, observed.uuid == proof.volumeUUID,
                  nodes.values.allSatisfy({ $0.snapshot.device == observed.device }) else {
                throw FileOperationFailure.sourceChanged
            }
            volume = observed
        } else { volume = nil }
        guard nodes.count == proof.nodeCount,
              stagingIdentityDigest(nodes, persistentVolume: volume) == proof.identityDigest else {
            throw FileOperationFailure.sourceChanged
        }
    }
    try anchor.validate()
    let rootAfter = try verifiedTree(area.url, cancellation: cancellation)
    guard rootBefore.matches(rootAfter) else { throw FileOperationFailure.sourceChanged }
    return rootAfter
}

/// Metadata-only logical size observation; no following symlinks or other volumes.
private func inventoryBytes(_ url: URL, budget: TraversalBudget, cancellation: OperationCancellation) throws {
    let parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
    let device = try EntrySnapshot(parent: parent.fd, name: url.lastPathComponent).device
    func visit(_ parentFD: Int32, name: String, depth: Int) throws {
        try cancellation.check()
        let before = try EntrySnapshot(parent: parentFD, name: name)
        guard before.device == device, [S_IFREG, S_IFDIR, S_IFLNK].contains(before.type) else { throw FileOperationFailure.unsupported }
        try budget.consume(before, depth: depth)
        if before.isDirectory {
            let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw posixFailure() }
            defer { close(fd) }
            for child in try childNames(in: fd, cancellation: cancellation, limit: budget.remaining) {
                try visit(fd, name: child, depth: depth + 1)
            }
            guard try EntrySnapshot(fd: fd) == before else { throw FileOperationFailure.sourceChanged }
        }
        guard try EntrySnapshot(parent: parentFD, name: name) == before else { throw FileOperationFailure.sourceChanged }
    }
    try visit(parent.fd, name: url.lastPathComponent, depth: 0)
}
