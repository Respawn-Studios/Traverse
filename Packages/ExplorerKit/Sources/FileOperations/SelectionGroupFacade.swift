import Darwin
import Foundation

public enum SelectionGroupDisposition: String, Sendable { case confirmObservedLocation, keepCurrentLocations, confirmCleanup }
public enum SelectionGroupResultState: String, Sendable { case notStarted, grouped, undone, partial, membersRestored, uncertain, cleaned }
public enum SelectionGroupProblem: String, Sendable { case denied, disconnectedOrUnavailable, unsupported, changed, conflict, unreadable, uncertain }
public enum SelectionGroupPendingEdgeKind: String, Sendable, Equatable { case publication, memberMove, memberReturn, folderRetirement }
public enum SelectionGroupObservedSide: String, Sendable, Equatable { case source, destination }
/// A passive projection of one unresolved native edge, never mutation authority.
public struct SelectionGroupPendingObservation: Sendable, Equatable {
    public let kind: SelectionGroupPendingEdgeKind
    public let memberIndex: Int?
    public let from: URL
    public let to: URL
    public let side: SelectionGroupObservedSide?
    public let problem: SelectionGroupProblem?
    public var observedURL: URL? {
        switch side { case .source: from; case .destination: to; case nil: nil }
    }
    internal init(edge: SelectionGroupEdge, manifest: SelectionGroupManifest, location: SelectionGroupObservedLocation?) {
        // Match selectionPair's direction without opening anchors or rereading
        // the filesystem. The record and location were already inspected.
        switch edge {
        case .publish:
            kind = .publication; memberIndex = nil
            from = manifest.area.appendingPathComponent("candidate"); to = manifest.folder
        case .move(let ordinal):
            kind = .memberMove; memberIndex = ordinal
            from = manifest.source(ordinal); to = manifest.destination(ordinal)
        case .restore(let ordinal):
            kind = .memberReturn; memberIndex = ordinal
            from = manifest.destination(ordinal); to = manifest.source(ordinal)
        case .retire:
            kind = .folderRetirement; memberIndex = nil
            from = manifest.folder; to = manifest.area.appendingPathComponent("retained")
        }
        switch location {
        case .original: side = .source; problem = nil
        case .destination: side = .destination; problem = nil
        case .denied: side = nil; problem = .denied
        case .disconnectedOrUnavailable: side = nil; problem = .disconnectedOrUnavailable
        case .unsupported: side = nil; problem = .unsupported
        case .changed: side = nil; problem = .changed
        case .conflict: side = nil; problem = .conflict
        case .unreadable: side = nil; problem = .unreadable
        case .unavailable, nil: side = nil; problem = .uncertain
        }
    }
}
public struct SelectionGroupPlan: Sendable {
    public let memberCount: Int
    public let destination: URL
    public let requiredAccessRoots: [URL]
    internal let core: CoreSelectionGroupPlan
}
public struct SelectionGroupItem: Sendable {
    public let source: URL
    public let destination: URL
    public let state: String
}
public struct SelectionGroupReview: Sendable {
    public let recordID: UUID
    public let revision: Int
    public let state: String
    public let items: [SelectionGroupItem]
    public let requiredAccessRoots: [URL]
    public let problem: SelectionGroupProblem?
    /// Its problem/side concerns this edge; `problem` above can describe a
    /// different member in the overall namespace frontier.
    public let pending: SelectionGroupPendingObservation?
    /// Present only when this inspection's empty-custody check admitted cleanup confirmation.
    public let verifiedCleanupTarget: URL?
    public let actions: [SelectionGroupDisposition]
    public let canUndo: Bool
    internal let core: CoreSelectionGroupReview
}
public struct SelectionGroupResult: Sendable {
    public let recordID: UUID?
    public let state: SelectionGroupResultState
    public let status: FileOperationStatus
    public let knownLocations: [URL]
    /// False means even presence/absence could not be re-read after a failed acknowledgement.
    public let authoritative: Bool
    public let cancellationRequested: Bool
}
internal struct SelectionGroupHistoryIdentity: Sendable {
    let root: EntrySnapshot
    let marker: EntrySnapshot
    let database: EntrySnapshot
    let owner: Data
    init(_ directory: URL) throws {
        let anchor = try DirectoryAnchor(directory, resolve: false)
        root = anchor.identity; marker = try EntrySnapshot(parent: anchor.fd, name: ".mac-explorer-journal-v1")
        database = try EntrySnapshot(parent: anchor.fd, name: SQLiteJournalStore.name)
        owner = try OperationJournal.read(name: ".mac-explorer-journal-v1", anchor: anchor)
        try anchor.validate()
    }
    func validateOpened(anchor: DirectoryAnchor, markerFD: Int32, owner currentOwner: UUID,
                        database currentDatabase: EntrySnapshot) throws {
        try anchor.validate()
        var attributes = stat()
        guard fstat(anchor.fd, &attributes) == 0, attributes.st_uid == geteuid(), attributes.st_mode & 0o077 == 0,
              root.sameObject(as: anchor.identity), markerFD >= 0,
              try EntrySnapshot(fd: markerFD) == marker,
              try EntrySnapshot(parent: anchor.fd, name: ".mac-explorer-journal-v1") == marker,
              owner == Data(currentOwner.uuidString.utf8),
              try OperationJournal.read(name: ".mac-explorer-journal-v1", anchor: anchor) == owner,
              database.sameObject(as: currentDatabase),
              try EntrySnapshot(parent: anchor.fd, name: SQLiteJournalStore.name).sameObject(as: database) else {
            throw FileOperationFailure.sourceChanged
        }
    }
    func validate(_ directory: URL) throws {
        let current = try Self(directory)
        guard root.sameObject(as: current.root), marker == current.marker, database.sameObject(as: current.database), owner == current.owner else { throw FileOperationFailure.sourceChanged }
    }
}

extension RecoverableFileOperations {
    public func prepareSelectionGroup(selection: FileOperationSelection, name: String) async throws -> SelectionGroupPlan {
        let core = try await prepareSelectionGroup(sources: selection.urls, name: name)
        guard core.members.count == selection.identities.count,
              zip(core.members, selection.identities).allSatisfy({ $0.0.identity == $0.1 }) else { throw FileOperationFailure.sourceChanged }
        return SelectionGroupPlan(memberCount: core.members.count,
            destination: core.parent.appendingPathComponent(String(decoding: core.folderName, as: UTF8.self)),
            requiredAccessRoots: [core.parent], core: core)
    }
    public func performSelectionGroup(_ plan: SelectionGroupPlan,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> SelectionGroupResult {
        let reporter = OperationProgressReporter(jobID: plan.core.jobID, callback: progress)
        reporter.begin(.planning, items: plan.memberCount)
        let status: FileOperationStatus
        do { status = try await performSelectionGroup(plan.core, progress: reporter).failure ?? .succeeded }
        catch { status = operationStatus(error) }
        let result = await selectionPublicResult(id: plan.core.jobID, status: status, history: plan.core.history, locations: [plan.core.parent, plan.destination, plan.core.parent.appendingPathComponent(".mac-explorer-selection-" + plan.core.jobID.uuidString)])
        reporter.finish(success: result.state == .grouped && status == .succeeded); return result
    }
    public func inspectSelectionGroup(recordID: UUID,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async throws -> SelectionGroupReview {
        let core = try await reviewSelectionGroup(recordID)
        let state = try core.record.project(), observed = core.problem ?? core.pendingLocation
        let problem: SelectionGroupProblem?
        switch observed {
        case .denied: problem = .denied
        case .disconnectedOrUnavailable: problem = .disconnectedOrUnavailable
        case .unsupported: problem = .unsupported
        case .changed: problem = .changed
        case .conflict: problem = .conflict
        case .unreadable: problem = .unreadable
        case .unavailable: problem = .uncertain
        default: problem = nil
        }
        var actions: [SelectionGroupDisposition] = []
        if state.pending != nil, let location = core.pendingLocation, [.original, .destination].contains(location) { actions.append(.confirmObservedLocation) }
        if state.pending == nil, [.active, .completed, .undoing, .membersRestored, .stoppedSettled].contains(state.state),
           core.record.maximumEvents - core.record.events.count >= 4 { actions.append(.keepCurrentLocations) }
        var verifiedCleanupTarget: URL?
        if state.state == .cleanupPending, let target = state.cleanupTarget {
            let record = core.record
            if (try? await worker { cancellation in try self.selectionEmptyCustody(record, at: target, cancellation: cancellation) }) != nil {
                actions.append(.confirmCleanup); verifiedCleanupTarget = target
            }
        }
        return SelectionGroupReview(recordID: recordID, revision: core.record.revision, state: state.state.rawValue,
            items: core.record.manifest.members.indices.map { SelectionGroupItem(source: core.record.manifest.source($0), destination: core.record.manifest.destination($0), state: state.memberPhases[$0].rawValue) },
            requiredAccessRoots: [core.record.manifest.parent] + (state.cleanupTarget.map { [$0.deletingLastPathComponent()] } ?? []),
            problem: problem,
            pending: state.pending.map { SelectionGroupPendingObservation(edge: $0, manifest: core.record.manifest, location: core.pendingLocation) },
            verifiedCleanupTarget: verifiedCleanupTarget, actions: actions,
            canUndo: problem == nil && state.pending == nil &&
                ((state.canCloseUnpublished && core.record.maximumEvents - core.record.events.count >= 4) ||
                 (state.container == .publicFolder && [.active, .completed, .undoing, .membersRestored, .stoppedSettled].contains(state.state))), core: core)
    }
    public func undoSelectionGroup(_ review: SelectionGroupReview,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> SelectionGroupResult {
        guard review.canUndo else { return await selectionPublicResult(id: review.recordID, status: .failed(.recoveryUncertain), history: review.core.history, locations: review.core.locations) }
        let reporter = OperationProgressReporter(jobID: review.recordID, callback: progress)
        reporter.begin(.verifying)
        let status: FileOperationStatus
        do { status = try await undoSelectionGroup(review.core, progress: reporter).failure ?? .succeeded }
        catch { status = operationStatus(error) }
        let result = await selectionPublicResult(id: review.recordID, status: status, history: review.core.history, locations: review.core.locations)
        reporter.finish(success: result.state == .undone && status == .succeeded); return result
    }
    public func confirmSelectionGroup(_ review: SelectionGroupReview, disposition: SelectionGroupDisposition,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> SelectionGroupResult {
        guard review.actions.contains(disposition), review.core.engine == continuationSession else {
            return await selectionPublicResult(id: review.recordID, status: .failed(.invalidRequest), history: review.core.history, locations: review.core.locations)
        }
        let status: FileOperationStatus
        do {
            if disposition == .confirmObservedLocation { _ = try await confirmSelectionGroupDisposition(review.core) }
            else {
                try review.core.use.claim()
                _ = try await worker { cancellation in
                    guard let history = review.core.history else { throw FileOperationFailure.invalidRequest }
                    try history.validate(self.directory)
                    try self.hooks.selectionGroup.checkpoint?("beforeHistoryWriter", review.recordID, nil)
                    let journal = try OperationJournal(self.directory, hooks: self.hooks.journalHooks, cancellation: cancellation, existingSelectionHistory: history)
                    try self.hooks.selectionGroup.checkpoint?("afterHistoryWriter", review.recordID, nil)
                    let record = try journal.selectionGroup(review.recordID)
                    guard record == review.core.record else { throw FileOperationFailure.sourceChanged }
                    if disposition == .keepCurrentLocations {
                        guard record.maximumEvents - record.events.count >= 4 else { throw FileOperationFailure.unsupported }
                        return try journal.appendSelectionGroup(record, SelectionGroupEvent(kind: .closeReview))
                    }
                    let state = try record.project()
                    guard state.state == .cleanupPending, let target = state.cleanupTarget else { throw FileOperationFailure.recoveryUncertain }
                    let parent = try self.selectionParent(record)
                    try requireAbsent(record.manifest.areaName, in: parent.fd)
                    _ = try self.selectionEmptyCustody(record, at: target, cancellation: cancellation)
                    let destination = try DirectoryAnchor(target.deletingLastPathComponent(), resolve: false)
                    try syncDirectory(parent); try syncDirectory(destination)
                    _ = try self.selectionEmptyCustody(record, at: target, cancellation: cancellation)
                    try requireAbsent(record.manifest.areaName, in: parent.fd)
                    return try journal.appendSelectionGroup(record, SelectionGroupEvent(kind: .cleanupConfirmed, confirmed: true))
                }
            }
            status = .succeeded
        } catch { status = operationStatus(error) }
        return await selectionPublicResult(id: review.recordID, status: status, history: review.core.history, locations: review.core.locations)
    }
    private func selectionPublicResult(id: UUID, status: FileOperationStatus, history: SelectionGroupHistoryIdentity?, locations: [URL]) async -> SelectionGroupResult {
        // Outcome collection drains after Stop. A failed first commit still has
        // its attempt ID; read authoritative storage before naming it a record.
        let stop = Task.isCancelled
        do {
            return try await worker(ignoringCancellation: true) { cancellation in
                guard let history else { throw FileOperationFailure.recoveryUncertain }
                try self.hooks.selectionGroup.checkpoint?("beforeResultRead", id, nil)
                guard let found = try OperationHistoryInspector.recordIfPresent(self.directory, id: id, cancellation: cancellation, selectionHistory: history),
                      case .selectionGroupV2(let record) = found else {
                    return SelectionGroupResult(recordID: nil, state: .notStarted, status: status, knownLocations: [], authoritative: true, cancellationRequested: stop)
                }
                let value = try record.project()
                let state: SelectionGroupResultState = value.pending != nil || value.state == .cleanupPending || value.container == .undeclaredObject ? .uncertain :
                    value.state == .cleaned ? .cleaned : value.state == .membersRestored ? .membersRestored :
                    value.state == .completed ? .grouped : value.state == .undone ? .undone : .partial
                return SelectionGroupResult(recordID: id, state: state, status: status,
                    knownLocations: [record.manifest.parent, record.manifest.folder, record.manifest.area] + (value.cleanupTarget.map { [$0] } ?? []), authoritative: true, cancellationRequested: stop)
            }
        } catch { return SelectionGroupResult(recordID: id, state: .uncertain,
            status: status == .succeeded ? .failed(.recoveryUncertain) : status,
            knownLocations: locations, authoritative: false, cancellationRequested: stop) }
    }
}
