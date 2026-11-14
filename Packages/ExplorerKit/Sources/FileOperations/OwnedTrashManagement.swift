import Darwin
import Foundation

/// Only entries in a confirmed Traverse native-Trash job can enter this view.
/// These are recorded outcomes, not a claim that the system Trash still holds them.
public enum OwnedTrashEntryState: String, Codable, Sendable {
    case retained, deleteIntent, uncertain, deleteConfirmed
}

public struct OwnedTrashEntry: Identifiable, Sendable {
    public let id: Int
    public let originalURL: URL
    public let trashedURL: URL
    public let isDirectory: Bool
    /// Saved root size for a regular file. Directory totals are unknown here.
    public let recordedByteCount: UInt64?
    public let state: OwnedTrashEntryState
    /// Known private location for an attempted Delete; display only in review.
    public let stagedURL: URL?
}

public struct OwnedTrashGroup: Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let entries: [OwnedTrashEntry]
    public let recoveryRecord: OperationRecoveryRecord?
    public let canRestoreWholeGroup: Bool
    public let canDeleteWholeGroup: Bool
    public let reviewRequired: Bool
    public let confirmedDeletionCount: Int
}

public struct OwnedTrashInspection: Sendable {
    public let groups: [OwnedTrashGroup]
    public let nextCursor: UUID?
    public let readiness: OperationHistoryReadiness
    public let refusedEntries: [URL]
}

/// The claim object is shared by value copies, so a prepared decision is one-use.
internal final class OwnedTrashPlanClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var spent = false
    func consume() -> Bool { lock.withLock { if spent { return false }; spent = true; return true } }
}

public struct OwnedTrashDeletionPlan: Sendable {
    public let recordID: UUID
    public let entries: [OwnedTrashEntry]
    public let createdAt: Date
    internal let engine: UUID
    internal let journalOwner: UUID
    internal let revision: Int
    internal let claim: OwnedTrashPlanClaim
}

internal struct JournalOwnedTrashHead: Codable, Equatable, Sendable {
    let undoInvalidated: Bool
    let itemCount: Int
    /// Present only for v10, so a v9 witness cannot disappear at the Delete barrier.
    var sourceVersion: Int? = nil
    var retainedCount: Int
    var intentCount: Int
    var uncertainCount: Int
    var confirmedCount: Int

    static func counted(_ phases: [OwnedTrashEntryState], sourceVersion: Int? = nil) -> Self {
        Self(undoInvalidated: true, itemCount: phases.count, sourceVersion: sourceVersion,
             retainedCount: phases.filter { $0 == .retained }.count,
             intentCount: phases.filter { $0 == .deleteIntent }.count,
             uncertainCount: phases.filter { $0 == .uncertain }.count,
             confirmedCount: phases.filter { $0 == .deleteConfirmed }.count)
    }
}

internal enum OwnedTrashPolicy {
    static func committed(_ record: JournalRecord) throws {
        guard [3, 9, 11, 12].contains(record.version), record.operation == "Move to Trash", record.state == "committed",
              record.persistentVolumes != nil, record.nameRename == nil, record.downloadAdoption == nil,
              record.ownedTrash == nil, record.areas.isEmpty,
              !record.steps.isEmpty, record.steps.count <= OperationJournal.maximumTrashIntents,
              record.steps.count == record.trashIntents.count,
              (record.version != 12 || record.steps.contains(where: { $0.before.identity.isDirectory })) else {
            throw FileOperationFailure.recoveryUncertain
        }
        let locations = Dictionary(grouping: record.locations, by: \.absoluteString)
        var sources = Set<String>(), destinations = Set<String>()
        for (step, intent) in zip(record.steps, record.trashIntents) {
            guard !step.undone, step.after != nil, step.ownedTrashDeletion == nil, step.ownedTrashStageURL == nil,
                  OperationJournal.sameURLRepresentation(step.source, intent.source),
                  step.sourceParent == intent.sourceParent, step.before == intent.before,
                  step.source.path != step.destination.path,
                  locations[step.destination.absoluteString]?.contains(where: {
                      OperationJournal.sameURLRepresentation($0, step.destination)
                  }) == true,
                  sources.insert(step.source.absoluteString).inserted,
                  destinations.insert(step.destination.absoluteString).inserted else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
        try OperationJournal.validateTrashRootAddition(record)
        try requireSeparateReturnedLocations(record.steps)
    }

    static func validate(_ record: JournalRecord) throws {
        guard [8, 10].contains(record.version), record.operation == "Move to Trash", record.areas.isEmpty,
              record.nameRename == nil, record.downloadAdoption == nil, record.persistentVolumes != nil,
              !record.steps.isEmpty, record.steps.count <= OperationJournal.maximumTrashIntents,
              record.steps.count == record.trashIntents.count,
              let head = record.ownedTrash, head.undoInvalidated,
              head.sourceVersion == (record.version == 10 ? 9 : nil),
              head.itemCount == record.steps.count else { throw FileOperationFailure.recoveryUncertain }
        let locations = Dictionary(grouping: record.locations, by: \.absoluteString)
        var sources = Set<String>(), destinations = Set<String>()
        var phases: [OwnedTrashEntryState] = []
        for (step, intent) in zip(record.steps, record.trashIntents) {
            guard !step.undone, step.after != nil, let phase = step.ownedTrashDeletion,
                  OperationJournal.sameURLRepresentation(step.source, intent.source),
                  step.sourceParent == intent.sourceParent, step.before == intent.before,
                  step.source.path != step.destination.path,
                  locations[step.destination.absoluteString]?.contains(where: {
                      OperationJournal.sameURLRepresentation($0, step.destination)
                  }) == true,
                  sources.insert(step.source.absoluteString).inserted,
                  destinations.insert(step.destination.absoluteString).inserted else {
                throw FileOperationFailure.recoveryUncertain
            }
            if phase == .retained {
                guard step.ownedTrashStageURL == nil else { throw FileOperationFailure.recoveryUncertain }
            } else {
                guard let stage = step.ownedTrashStageURL,
                      stage.deletingLastPathComponent().lastPathComponent.hasPrefix(".traverse-owned-trash-delete-"),
                      UUID(uuidString: String(stage.deletingLastPathComponent().lastPathComponent
                          .dropFirst(".traverse-owned-trash-delete-".count))) != nil,
                      stage.lastPathComponent == "payload",
                      OperationJournal.sameURLRepresentation(stage.deletingLastPathComponent().deletingLastPathComponent(),
                          step.destination.deletingLastPathComponent()),
                      locations[stage.absoluteString]?.contains(where: {
                          OperationJournal.sameURLRepresentation($0, stage)
                      }) == true else {
                    throw FileOperationFailure.recoveryUncertain
                }
                try OperationJournal.validateLocation(stage)
            }
            phases.append(phase)
        }
        try OperationJournal.validateTrashRootAddition(record)
        try requireSeparateReturnedLocations(record.steps)
        guard head == JournalOwnedTrashHead.counted(phases, sourceVersion: record.version == 10 ? 9 : nil),
              (record.state == "trashDeleted") == (head.confirmedCount == head.itemCount),
              ["trashDeleteReview", "trashDeleted"].contains(record.state) else {
            throw FileOperationFailure.recoveryUncertain
        }
    }

    private static func requireSeparateReturnedLocations(_ steps: [JournalStep]) throws {
        let paths = Set(steps.map { $0.destination.path })
        guard paths.count == steps.count else { throw FileOperationFailure.recoveryUncertain }
        for step in steps {
            var parent = step.destination.deletingLastPathComponent()
            for _ in 0..<OperationLimits.maximumDepth {
                if paths.contains(parent.path) { throw FileOperationFailure.recoveryUncertain }
                if parent.path == "/" { break }
                parent.deleteLastPathComponent()
            }
        }
    }

    static func entries(_ record: JournalRecord) -> [OwnedTrashEntry] {
        record.steps.enumerated().map { ordinal, step in
            let size = step.after?.identity.type == S_IFREG ? step.after!.identity.size : -1
            return OwnedTrashEntry(id: ordinal, originalURL: step.source, trashedURL: step.destination,
                isDirectory: step.after?.identity.isDirectory ?? false,
                recordedByteCount: size >= 0 ? UInt64(size) : nil,
                state: step.ownedTrashDeletion ?? .retained,
                stagedURL: step.ownedTrashStageURL)
        }
    }

    static func sameEntries(_ lhs: [OwnedTrashEntry], _ rhs: [OwnedTrashEntry]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { a, b in
            a.id == b.id && a.originalURL.absoluteString == b.originalURL.absoluteString &&
            a.trashedURL.absoluteString == b.trashedURL.absoluteString &&
            a.isDirectory == b.isDirectory && a.recordedByteCount == b.recordedByteCount &&
            a.state == b.state && a.stagedURL?.absoluteString == b.stagedURL?.absoluteString
        }
    }

    /// Delete needs the returned root's change time as well as its saved tree
    /// digest. This catches same-content child replacement before private custody.
    static func unchangedRootMetadata(_ saved: EntrySnapshot, _ current: EntrySnapshot) -> Bool {
        saved.inode == current.inode && saved.mode == current.mode && saved.size == current.size &&
        saved.modifiedSeconds == current.modifiedSeconds && saved.modifiedNanos == current.modifiedNanos &&
        saved.changedSeconds == current.changedSeconds && saved.changedNanos == current.changedNanos &&
        saved.birthSeconds == current.birthSeconds && saved.birthNanos == current.birthNanos
    }
}

extension RecoverableFileOperations {
    /// Passive, bounded history projection. No system Trash enumeration or file-body read.
    public func inspectOwnedTrash(after: UUID? = nil, limit: Int = 8) async throws -> OwnedTrashInspection {
        try await worker { cancellation in
            guard (1...8).contains(limit) else { throw FileOperationFailure.invalidRequest }
            let page = try OperationHistoryInspector.inspect(self.directory, after: after, limit: limit,
                                                             cancellation: cancellation)
            let narrowNativeTrash = self.nativeTrashPolicy == .regularFilesOnly
                || self.nativeTrashPolicy == .regularFilesAndDirectories
            guard case .available(let catalog) = page.readiness,
                  [10, 11].contains(catalog) || narrowNativeTrash && [3, 4, 7, 9].contains(catalog) else {
                return OwnedTrashInspection(groups: [], nextCursor: page.nextCursor,
                    readiness: page.readiness, refusedEntries: page.refusedEntries)
            }
            var groups: [OwnedTrashGroup] = []
            for summary in page.records where summary.operation == "Move to Trash" {
                try cancellation.check()
                let selected = try OperationHistoryInspector.record(self.directory, id: summary.id,
                                                                     cancellation: cancellation)
                let record: JournalRecord
                switch selected {
                case .treeV3(let ordinary), .treeTrashRootAddV9(let ordinary),
                     .treeNativeTrashV11(let ordinary), .treeNativeTrashV12(let ordinary):
                    guard ordinary.state == "committed" else { continue }
                    try OwnedTrashPolicy.committed(ordinary); record = ordinary
                case .ownedTrashV8(let deletion), .ownedTrashRootAddDeleteV10(let deletion):
                    try OwnedTrashPolicy.validate(deletion); record = deletion
                default: continue
                }
                let canRestoreVersion: Bool
                switch self.nativeTrashPolicy {
                case .held: canRestoreVersion = false
                case .regularFilesOnly: canRestoreVersion = record.version == 11
                case .regularFilesAndDirectories: canRestoreVersion = [11, 12].contains(record.version)
                case .existingVerifiedPaths: canRestoreVersion = [3, 9, 11, 12].contains(record.version)
                }
                let confirmed = record.ownedTrash?.confirmedCount ?? 0
                groups.append(OwnedTrashGroup(id: record.id, createdAt: record.createdAt,
                    entries: OwnedTrashPolicy.entries(record), recoveryRecord: summary,
                    canRestoreWholeGroup: canRestoreVersion && summary.canUndo,
                    canDeleteWholeGroup: self.nativeTrashPolicy == .existingVerifiedPaths
                        && [3, 9].contains(record.version),
                    reviewRequired: [8, 10].contains(record.version) && record.state != "trashDeleted",
                    confirmedDeletionCount: confirmed))
            }
            return OwnedTrashInspection(groups: groups, nextCursor: page.nextCursor,
                readiness: page.readiness, refusedEntries: page.refusedEntries)
        }
    }

    /// Seals one selected, intact group against its exact journal revision. This
    /// reads saved metadata only; deletion reopens and verifies every returned item.
    public func prepareOwnedTrashDeletion(recordID: UUID) async throws -> OwnedTrashDeletionPlan {
        try await worker { cancellation in
            guard self.nativeTrashPolicy == .existingVerifiedPaths else { throw FileOperationFailure.unsupported }
            let readiness = try OperationHistoryInspector.inspect(self.directory, limit: 1,
                                                                   cancellation: cancellation).readiness
            guard case .available(let catalog) = readiness, [10, 11].contains(catalog) else {
                throw FileOperationFailure.unavailable
            }
            let selected = try OperationHistoryInspector.record(self.directory, id: recordID,
                                                                 cancellation: cancellation)
            let record: JournalRecord
            switch selected {
            case .treeV3(let ordinary), .treeTrashRootAddV9(let ordinary): record = ordinary
            default: throw FileOperationFailure.unsupported
            }
            try OwnedTrashPolicy.committed(record)
            return OwnedTrashDeletionPlan(recordID: record.id, entries: OwnedTrashPolicy.entries(record),
                createdAt: record.createdAt, engine: self.continuationSession, journalOwner: record.owner,
                revision: record.revision, claim: OwnedTrashPlanClaim())
        }
    }

    /// Deletes only the complete selected, confirmed Traverse group. A failed
    /// or interrupted v8 job is review-only; it is never replayed automatically.
    public func permanentlyDeleteOwnedTrash(_ plan: OwnedTrashDeletionPlan,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> RecoverableOperationResult {
        let reporter = OperationProgressReporter(jobID: plan.recordID, callback: progress)
        do {
            let result = try await worker(progress: reporter) { cancellation in
                guard self.nativeTrashPolicy == .existingVerifiedPaths else { throw FileOperationFailure.unsupported }
                guard plan.engine == self.continuationSession, plan.claim.consume() else {
                    throw FileOperationFailure.invalidRequest
                }
                reporter.begin(.verifying, count: plan.entries.count, items: plan.entries.count)
                let journal = try OperationJournal(self.directory, hooks: self.hooks.journalHooks,
                                                   cancellation: cancellation)
                try journal.validateWritableCatalog()
                let selected = try journal.inspectCatalogRecord(plan.recordID)
                let candidate: Bool
                switch selected {
                case .treeV3?, .treeTrashRootAddV9?: candidate = true
                default: candidate = false
                }
                guard case .available(let catalog) = journal.inspectionReadiness,
                      [10, 11].contains(catalog), candidate,
                      let record = try journal.openEdit(plan.recordID),
                      record.revision == plan.revision,
                      record.snapshot.owner == plan.journalOwner,
                      record.snapshot.createdAt == plan.createdAt else { throw FileOperationFailure.sourceChanged }
                try OwnedTrashPolicy.committed(record.snapshot)
                guard OwnedTrashPolicy.sameEntries(OwnedTrashPolicy.entries(record.snapshot), plan.entries) else {
                    throw FileOperationFailure.sourceChanged
                }
                let projection = record.snapshot
                let reservation = min(OperationJournal.maximumRecordBytes,
                    (try JSONEncoder().encode(projection)).count + projection.steps.count * 2_048 + 65_536)
                try journal.reserveCapacity(steps: projection.steps.count, areas: 0,
                    locations: projection.locations.count + projection.steps.count,
                    trashIntents: projection.trashIntents.count, estimatedBytes: reservation)
                let protection = try HistoryProtection(self.directory, cancellation: cancellation,
                                                       protecting: self.protectedLocations)
                // Refuse predictable missing, changed, inaccessible, protected, or
                // unsupported inputs before the durable whole-job Undo barrier.
                let preflightBudget = TraversalBudget()
                for step in record.steps {
                    try cancellation.check()
                    let parent = try DirectoryAnchor(step.destination.deletingLastPathComponent(), resolve: false)
                    guard try record.matchesPersisted(step.destinationParent, parent.identity, in: parent),
                          let after = step.after else { throw FileOperationFailure.sourceChanged }
                    try protection.requireEntry(parent: parent, name: step.destination.lastPathComponent)
                    #if DEBUG
                    let synthetic = record.snapshot.version == 9 ? self.hooks.nativeTrashSyntheticRootMetadata : nil
                    #else
                    let synthetic: NativeTrashSyntheticRootMetadata? = nil
                    #endif
                    let current = try verifiedTree(parent: parent.fd, name: step.destination.lastPathComponent,
                                                   cancellation: cancellation, budget: preflightBudget,
                                                   nativeTrashSyntheticRootMetadata: synthetic)
                    guard try record.matchesPersisted(after, current, in: parent),
                          OwnedTrashPolicy.unchangedRootMetadata(after.identity, current.identity) else {
                        throw FileOperationFailure.sourceChanged
                    }
                }
                try cancellation.check()
                try record.promoteOwnedTrashDeletion()
                try journal.save(record) // Undo is gone before the first irreversible syscall.
                var outcomes: [FileOperationOutcome] = []
                let recheckBudget = TraversalBudget()
                let stagedBudget = TraversalBudget()
                let manifestBudget = TraversalBudget()
                for index in record.steps.indices {
                    let step = record.steps[index]
                    if cancellation.isCancelled {
                        outcomes += record.steps.dropFirst(index).map {
                            FileOperationOutcome(source: $0.destination, destination: nil,
                                                 status: .notStarted, recoveryURLs: [])
                        }
                        break
                    }
                    let stage = step.destination.deletingLastPathComponent()
                        .appendingPathComponent(".traverse-owned-trash-delete-" + UUID().uuidString, isDirectory: true)
                        .appendingPathComponent("payload", isDirectory: step.before.identity.isDirectory)
                    do {
                        try record.setOwnedTrashDeletion(.deleteIntent, at: index, stage: stage)
                        try journal.save(record)
                        reporter.begin(.retaining, source: step.destination, index: index + 1,
                                       count: record.steps.count, items: record.steps.count)
                        try self.deleteOneOwnedTrashEntry(step, stagedAt: stage, record: record,
                            journal: journal, index: index, reporter: reporter,
                            protection: protection, cancellation: cancellation.draining(),
                            recheckBudget: recheckBudget, stagedBudget: stagedBudget,
                            manifestBudget: manifestBudget)
                        try self.hooks.afterOwnedTrashDeleteBeforeConfirm?()
                        try record.setOwnedTrashDeletion(.deleteConfirmed, at: index)
                        try journal.save(record)
                        outcomes.append(FileOperationOutcome(source: step.destination, destination: nil,
                                                             status: .succeeded, recoveryURLs: []))
                        reporter.advance(items: 1)
                    } catch {
                        if record.steps[index].ownedTrashDeletion == .deleteIntent {
                            do {
                                try record.setOwnedTrashDeletion(.uncertain, at: index)
                                try journal.save(record)
                            } catch { /* The durable intent still requires cold review. */ }
                        }
                        outcomes.append(FileOperationOutcome(source: step.destination, destination: nil,
                            status: operationStatus(error), recoveryURLs: [step.destination, stage]))
                        outcomes += record.steps.dropFirst(index + 1).map {
                            FileOperationOutcome(source: $0.destination, destination: nil,
                                                 status: .notStarted, recoveryURLs: [])
                        }
                        break
                    }
                }
                return RecoverableOperationResult(result: FileOperationResult(items: outcomes,
                    cancellationRequested: cancellation.isCancelled), recordID: plan.recordID)
            }
            reporter.finish(success: result.result.disposition == .succeeded)
            return result
        } catch {
            reporter.observeCaughtFailure(.nativeTrashDeletePreflight, error: error,
                recordID: plan.recordID)
            reporter.finish(success: false)
            return RecoverableOperationResult(result: FileOperationResult(items: [
                FileOperationOutcome(source: nil, destination: nil, status: operationStatus(error),
                                     recoveryURLs: [], role: .job)
            ], cancellationRequested: error is CancellationError), recordID: plan.recordID)
        }
    }
}

private extension RecoverableFileOperations {
    /// A returned item is isolated into a new private sibling directory first.
    /// A source swapped at the final rename is preserved there for review, never
    /// passed to the irreversible walker as the recorded item.
    func deleteOneOwnedTrashEntry(_ step: JournalStep, stagedAt stageURL: URL,
        record: JournalEditSession, journal: OperationJournal, index: Int,
        reporter: OperationProgressReporter, protection: HistoryProtection,
        cancellation: OperationCancellation, recheckBudget: TraversalBudget,
        stagedBudget: TraversalBudget, manifestBudget: TraversalBudget) throws {
        var checkpoint = OperationDiagnosticCheckpoint.nativeTrashDeletePreflight
        var familyFinding: NativeTrashFamilyFinding?
        do {
            try cancellation.check()
            #if DEBUG
            let synthetic = record.snapshot.version == 10 ? hooks.nativeTrashSyntheticRootMetadata : nil
            #else
            let synthetic: NativeTrashSyntheticRootMetadata? = nil
            #endif
            guard let expected = step.after else { throw FileOperationFailure.recoveryUncertain }
            let parent = try DirectoryAnchor(step.destination.deletingLastPathComponent(), resolve: false)
            guard try record.matchesPersisted(step.destinationParent, parent.identity, in: parent) else {
                throw FileOperationFailure.sourceChanged
            }
            let sourceName = step.destination.lastPathComponent
            try protection.requireEntry(parent: parent, name: sourceName)
            let stageDirectory = stageURL.deletingLastPathComponent()
            let stageName = stageDirectory.lastPathComponent
            try validateName(stageName)
            try protection.requireEntry(parent: parent, name: stageName)
            try requireAbsent(stageName, in: parent.fd)

            let beforeSecurity = NativeRenameSecurityProjection()
            let directoryStage = record.snapshot.version == 10 && step.nativeTrashRootAddition != nil
            if directoryStage { familyFinding = .unavailable }
            let beforeFamilies = directoryStage ? NativeTrashFamilyCollector() : nil
            let current = try verifiedTree(parent: parent.fd, name: sourceName, cancellation: cancellation,
                                           budget: recheckBudget, nativeRename: beforeSecurity,
                                           nativeTrashFamilyCollector: beforeFamilies,
                                           nativeTrashSyntheticRootMetadata: synthetic)
            guard try record.matchesPersisted(expected, current, in: parent),
                  OwnedTrashPolicy.unchangedRootMetadata(expected.identity, current.identity) else {
                throw FileOperationFailure.sourceChanged
            }
            let pinned = try pinEntry(parent: parent.fd, name: sourceName, matching: current.identity)
            defer { close(pinned) }
            guard mkdirat(parent.fd, stageName, 0o700) == 0 else { throw posixFailure() }
            let stage = try DirectoryAnchor(stageDirectory, resolve: false)
            let initialReadable = try openReadableDirectory(stage.fd)
            defer { close(initialReadable) }
            var attributes = stat()
            guard fstat(stage.fd, &attributes) == 0, attributes.st_uid == geteuid(),
                  attributes.st_mode & S_IFMT == S_IFDIR, attributes.st_mode & 0o077 == 0,
                  stage.identity.device == parent.identity.device,
                  try childNames(in: initialReadable, cancellation: cancellation, limit: 1).isEmpty else {
                throw FileOperationFailure.recoveryUncertain
            }
            try syncDirectory(parent)
            try stage.validate(); try parent.validate()
            let sourceAgain = try EntrySnapshot(parent: parent.fd, name: sourceName)
            guard sourceAgain.sameObject(as: current.identity) else { throw FileOperationFailure.sourceChanged }
            try requireAbsent("payload", in: stage.fd)
            checkpoint = .nativeTrashDeleteStageRename
            try exclusiveRename(from: parent.fd, name: sourceName, to: stage.fd, name: "payload")
            // No path-based deletion may begin until the exact pinned object is
            // reidentified on the private side of the exclusive rename.
            let moved = try EntrySnapshot(parent: stage.fd, name: "payload")
            guard moved.sameObject(as: current.identity),
                  moved.sameObject(as: try EntrySnapshot(fd: pinned)) else {
                throw FileOperationFailure.recoveryUncertain
            }
            try requireAbsent(sourceName, in: parent.fd)
            try syncDirectory(parent); try syncDirectory(stage)
            #if DEBUG
            try hooks.nativeTrashDeleteAfterStageRename?(stageURL)
            #endif
            let afterSecurity = NativeRenameSecurityProjection()
            let afterFamilies = directoryStage ? NativeTrashFamilyCollector() : nil
            #if DEBUG
            let stageSynthetic = directoryStage
                ? hooks.nativeTrashDeleteStagedSyntheticRootMetadata ?? synthetic : synthetic
            #else
            let stageSynthetic = synthetic
            #endif
            checkpoint = .nativeTrashDeleteStagePostWalk
            let staged = try verifiedTree(parent: stage.fd, name: "payload", cancellation: cancellation,
                                          budget: stagedBudget, nativeRename: afterSecurity,
                                          nativeTrashFamilyCollector: afterFamilies,
                                          nativeTrashSyntheticRootMetadata: stageSynthetic)
            try parent.validate(); try stage.validate()
            checkpoint = .nativeTrashDeleteStageTransition
            let exact = try record.matchesPersisted(expected, staged, in: stage)
            let priorFamilies = beforeFamilies?.snapshot(), laterFamilies = afterFamilies?.snapshot()
            if directoryStage, !exact {
                if let prior = priorFamilies, let later = laterFamilies {
                    familyFinding = prior.finding(comparedWith: later, before: current, returned: staged)
                } else { familyFinding = .unavailable }
            }
            let boundedDirectoryStage: Bool
            if directoryStage, let prior = priorFamilies, let later = laterFamilies {
                boundedDirectoryStage = prior.permitsOwnedTrashStagingRootSecurityRewrite(
                    comparedWith: later, before: current, staged: staged)
            } else { boundedDirectoryStage = false }
            guard exact || boundedDirectoryStage
                || record.snapshot.version != 10 && beforeSecurity.permitsNativeTransition(to: afterSecurity,
                    before: current, after: staged, origin: NativeProcessSecurityOrigin.current) else {
                throw FileOperationFailure.recoveryUncertain
            }
            if directoryStage {
                // A successful stage is still reversible. Record its actual
                // full image before the final manifest and first irreversible
                // unlink; cold v10 remains review-only.
                checkpoint = .nativeTrashDeleteStageJournal
                try record.setStepOutcome(staged, at: index)
                try journal.save(record)
                checkpoint = .nativeTrashDeleteStagePostWalk
            }
            let manifest = try snapshotTree(parent: stage.fd, name: "payload", cancellation: cancellation)
            guard manifest[""]?.snapshot.sameObject(as: staged.identity) == true else {
                throw FileOperationFailure.sourceChanged
            }
            let postManifest = try verifiedTree(parent: stage.fd, name: "payload", cancellation: cancellation,
                                                budget: manifestBudget, nativeTrashSyntheticRootMetadata: stageSynthetic)
            guard staged.matches(postManifest) else { throw FileOperationFailure.sourceChanged }
            checkpoint = .nativeTrashDeleteUnlink
            try removeExactStagedTree(stage: stage, manifest: manifest, cancellation: cancellation,
                                      afterUnlink: hooks.afterOwnedTrashUnlink)
            try stage.validate(); try parent.validate()
            let readable = try openReadableDirectory(stage.fd)
            defer { close(readable) }
            guard try childNames(in: readable, cancellation: cancellation, limit: 1).isEmpty else {
                throw FileOperationFailure.recoveryUncertain
            }
            guard unlinkat(parent.fd, stageName, AT_REMOVEDIR) == 0 else { throw posixFailure() }
            try syncDirectory(parent)
        } catch {
            reporter.observeCaughtFailure(checkpoint, error: error, recordID: record.id,
                nativeTrashFinding: familyFinding)
            throw error
        }
    }
}

/// Opens a directory for enumeration without changing its pinned search handle.
private func openReadableDirectory(_ fd: Int32) throws -> Int32 {
    let readable = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard readable >= 0 else { throw posixFailure() }
    return readable
}

/// Only called for an isolated, journal-intended owned-Trash payload. The
/// manifest bounds and names every unlink; newly inserted names are not walked.
private func removeExactStagedTree(stage: DirectoryAnchor, manifest: [String: TreeNode],
    cancellation: OperationCancellation, afterUnlink: (@Sendable (Int) throws -> Void)?) throws {
    guard !manifest.isEmpty, manifest.count <= OperationLimits.maximumNodes else {
        throw FileOperationFailure.recoveryUncertain
    }
    let ordered = manifest.keys.sorted { lhs, rhs in
        let a = lhs.isEmpty ? 0 : lhs.split(separator: "/").count
        let b = rhs.isEmpty ? 0 : rhs.split(separator: "/").count
        return a == b ? lhs > rhs : a > b
    }
    var unlinked = 0
    for relative in ordered {
        try cancellation.check()
        let path = ["payload"] + (relative.isEmpty ? [] : relative.split(separator: "/").map(String.init))
        guard let name = path.last, let expected = manifest[relative]?.snapshot else {
            throw FileOperationFailure.recoveryUncertain
        }
        var opened: [Int32] = []
        let first = dup(stage.fd)
        guard first >= 0 else { throw posixFailure() }
        opened.append(first)
        defer { for fd in opened.reversed() { close(fd) } }
        var parentFD = first
        for (offset, component) in path.dropLast().enumerated() {
            try validateName(component)
            let next = openat(parentFD, component, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw posixFailure() }
            opened.append(next); parentFD = next
            let parentRelative = offset == 0 ? "" : path[1...offset].joined(separator: "/")
            guard let parentExpected = manifest[parentRelative]?.snapshot,
                  try EntrySnapshot(fd: parentFD).sameObject(as: parentExpected) else {
                throw FileOperationFailure.sourceChanged
            }
        }
        try validateName(name)
        let observed = try EntrySnapshot(parent: parentFD, name: name)
        guard observed.sameObject(as: expected),
              expected.isDirectory || (observed.mode == expected.mode && observed.size == expected.size &&
                  observed.modifiedSeconds == expected.modifiedSeconds &&
                  observed.modifiedNanos == expected.modifiedNanos) else {
            throw FileOperationFailure.sourceChanged
        }
        if expected.isDirectory {
            let child = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw posixFailure() }
            defer { close(child) }
            guard try EntrySnapshot(fd: child).sameObject(as: expected),
                  try childNames(in: child, cancellation: cancellation, limit: 1).isEmpty else {
                throw FileOperationFailure.sourceChanged
            }
        }
        guard unlinkat(parentFD, name, expected.isDirectory ? AT_REMOVEDIR : 0) == 0 else {
            throw posixFailure()
        }
        unlinked += 1
        try afterUnlink?(unlinked)
        guard fsync(parentFD) == 0 else { throw posixFailure() }
    }
}
