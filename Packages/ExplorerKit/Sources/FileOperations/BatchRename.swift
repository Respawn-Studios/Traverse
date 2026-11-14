import Darwin
import Foundation

public struct BatchRenameItem: Sendable, Identifiable {
    public let id: UUID
    public let source: URL
    public let destination: URL
    public let originalName: String
    public let newName: String
    public var isUnchanged: Bool { originalName.utf8.elementsEqual(newName.utf8) }
    internal let observation: EntrySnapshot
}

/// One explicit preparation, bound to the observing engine and consumed once.
/// A preview URL/name cannot construct this capability.
public final class BatchRenamePlan: @unchecked Sendable {
    public let items: [BatchRenameItem]
    public let parent: URL
    internal let parentIdentity: EntrySnapshot
    internal let engine: UUID
    private let lock = NSLock()
    private var consumed = false
    internal init(items: [BatchRenameItem], parent: URL, parentIdentity: EntrySnapshot, engine: UUID) {
        self.items = items; self.parent = parent; self.parentIdentity = parentIdentity; self.engine = engine
    }
    internal func consume(by engine: UUID) -> Bool {
        lock.withLock { guard self.engine == engine, !consumed else { return false }; consumed = true; return true }
    }
}

public struct BatchRenameUnitResult: Sendable {
    public let item: BatchRenameItem
    public let outcome: RecoverableOperationResult
}

public struct BatchRenameResult: Sendable {
    public let units: [BatchRenameUnitResult]
    public let cancellationRequested: Bool
    internal let engine: UUID
    internal let undoAdmission: BatchRenameUndoAdmission
    public var result: FileOperationResult { .init(items: units.flatMap { $0.outcome.result.items }, cancellationRequested: cancellationRequested) }
    public var completedRecordIDs: [UUID] {
        units.compactMap { $0.outcome.result.disposition == .succeeded ? $0.outcome.recordID : nil }
    }
}
internal final class BatchRenameUndoAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false
    func consume() -> Bool { lock.withLock { guard !consumed else { return false }; consumed = true; return true } }
}
public struct BatchRenameUndoResult: Sendable {
    public let attempted: [RecoverableOperationResult]
    public let remainingRecordIDs: [UUID]
    public let cancellationRequested: Bool
    public var result: FileOperationResult { .init(items: attempted.flatMap { $0.result.items }, cancellationRequested: cancellationRequested) }
}

extension RecoverableFileOperations {
    /// Entirely observational. No journal/state directory is created here.
    public func prepareBatchRename(sources: [URL], rule: BatchRenameRule,
                                   observing selection: FileOperationSelection) async throws -> BatchRenamePlan {
        try await worker { cancellation in
            if case .generatedFixture = self.copyExecutionAuthorization { throw FileOperationFailure.unsupported }
            guard (2...512).contains(sources.count), selection.urls.count == sources.count,
                  selection.identities.count == sources.count,
                  Set(sources.map { Data($0.path.utf8) }).count == sources.count,
                  let first = sources.first else { throw FileOperationFailure.invalidRequest }
            let parent = try DirectoryAnchor(first.deletingLastPathComponent())
            guard sources.allSatisfy({ Data($0.deletingLastPathComponent().path.utf8) == Data(parent.url.path.utf8) }),
                  try NativeRenameVolume.qualified(in: parent) != nil else { throw FileOperationFailure.unsupported }
            let protection = try HistoryProtection(self.directory, cancellation: cancellation, protecting: self.protectedLocations)
            var entries: [NativeRenameEntry] = []
            for source in sources {
                try cancellation.check()
                let entry = try NativeRenameEntry.observe(parent: parent, name: source.lastPathComponent)
                guard [S_IFREG, S_IFDIR].contains(entry.identity.type), entry.identity.device == parent.identity.device,
                      let observed = selection.urls.firstIndex(where: { Data($0.path.utf8) == Data(source.path.utf8) }),
                      selection.identities[observed] == entry.identity else { throw FileOperationFailure.sourceChanged }
                try protection.requireEntry(parent: parent, name: entry.name, snapshot: entry.identity)
                entries.append(entry)
            }
            let names = try rule.names(for: entries.map { .init(name: $0.name, isDirectory: $0.identity.isDirectory) })
            let items = zip(entries, names).map { entry, name in
                BatchRenameItem(id: UUID(), source: parent.url.appendingPathComponent(entry.name), destination: parent.url.appendingPathComponent(name),
                                originalName: entry.name, newName: name, observation: entry.identity)
            }
            let plan = BatchRenamePlan(items: items, parent: parent.url, parentIdentity: parent.identity, engine: self.continuationSession)
            try self.validateBatchRename(plan, cancellation: cancellation)
            return plan
        }
    }

    public func performBatchRename(_ plan: BatchRenamePlan,
                                   progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> BatchRenameResult {
        let reporter = OperationProgressReporter(callback: progress)
        let result: BatchRenameResult
        do {
            result = try await worker(progress: reporter) { cancellation in
                if case .generatedFixture = self.copyExecutionAuthorization { throw FileOperationFailure.unsupported }
                guard plan.consume(by: self.continuationSession) else { throw FileOperationFailure.invalidRequest }
                try self.validateCopyExecutionSession(locations: plan.items.flatMap { [$0.source, $0.destination] }, directories: [plan.parent])
                try self.validateBatchRename(plan, cancellation: cancellation)
                var units: [BatchRenameUnitResult] = []
                var stopped = false
                for (index, item) in plan.items.enumerated() {
                    if stopped || cancellation.isCancelled {
                        units.append(self.batchUnit(item, status: .notStarted, cancelled: cancellation.isCancelled)); continue
                    }
                    if item.isUnchanged {
                        units.append(self.batchUnit(item, status: .skipped, cancelled: false)); continue
                    }
                    reporter.begin(.publishing, source: item.source, destination: item.destination, index: index + 1, count: plan.items.count)
                    let observation = FileOperationSelection(urls: [item.source, plan.parent], identities: [item.observation, plan.parentIdentity])
                    let outcome = self.sameParentRename(source: item.source, name: item.newName, observing: observation, cancellation: cancellation)
                        ?? self.batchUnit(item, status: .failed(.unsupported), cancelled: cancellation.isCancelled).outcome
                    units.append(.init(item: item, outcome: outcome))
                    stopped = outcome.result.disposition != .succeeded
                }
                return .init(units: units, cancellationRequested: cancellation.isCancelled, engine: self.continuationSession, undoAdmission: .init())
            }
        } catch {
            let cancelled = error is CancellationError
            let failure = error as? FileOperationFailure ?? .invalidRequest
            result = .init(units: plan.items.enumerated().map { index, item in
                self.batchUnit(item, status: index == 0 ? (cancelled ? .cancelled : .failed(failure)) : .notStarted, cancelled: cancelled)
            }, cancellationRequested: cancelled, engine: continuationSession, undoAdmission: .init())
        }
        reporter.finish(success: result.result.disposition == .succeeded)
        return result
    }

    /// A session convenience over the same independently guarded Undo records.
    /// The caller keeps the application's exclusive lane across this await.
    public func undoBatchRename(_ batch: BatchRenameResult,
                                progress: (@Sendable (OperationProgress) -> Void)? = nil) async throws -> BatchRenameUndoResult {
        guard batch.engine == continuationSession, batch.undoAdmission.consume() else { throw FileOperationFailure.invalidRequest }
        let ids = batch.completedRecordIDs.reversed().map { $0 }
        var outcomes: [RecoverableOperationResult] = []
        for (index, id) in ids.enumerated() {
            if Task.isCancelled { return .init(attempted: outcomes, remainingRecordIDs: Array(ids[index...]), cancellationRequested: true) }
            let outcome = await undo(recordID: id, progress: progress); outcomes.append(outcome)
            if outcome.result.disposition != .succeeded {
                return .init(attempted: outcomes, remainingRecordIDs: Array(ids[(index + 1)...]), cancellationRequested: Task.isCancelled)
            }
        }
        return .init(attempted: outcomes, remainingRecordIDs: [], cancellationRequested: Task.isCancelled)
    }

    private func batchUnit(_ item: BatchRenameItem, status: FileOperationStatus, cancelled: Bool) -> BatchRenameUnitResult {
        .init(item: item, outcome: .init(result: .init(items: [.init(source: item.source, destination: item.destination, status: status, recoveryURLs: [])],
            cancellationRequested: cancelled), recordID: nil))
    }
    private func validateBatchRename(_ plan: BatchRenamePlan, cancellation: OperationCancellation) throws {
        let parent = try DirectoryAnchor(plan.parent, resolve: false)
        guard parent.identity.sameObject(as: plan.parentIdentity), try NativeRenameVolume.qualified(in: parent) != nil else { throw FileOperationFailure.destinationChanged }
        let protection = try HistoryProtection(directory, cancellation: cancellation, protecting: protectedLocations)
        for item in plan.items {
            try cancellation.check()
            let entry = try NativeRenameEntry.observe(parent: parent, name: item.originalName)
            guard entry.identity == item.observation, entry.nameBytes == Data(item.originalName.utf8) else { throw FileOperationFailure.sourceChanged }
            try protection.requireEntry(parent: parent, name: item.originalName, snapshot: item.observation)
            try protection.requireEntry(parent: parent, name: item.newName)
            if let target = try NativeRenameEntry.optional(parent: parent, name: item.newName) {
                guard target.sameEntry(as: entry), target.nameBytes == entry.nameBytes else { throw FileOperationFailure.conflict }
            }
        }
        try parent.validate(); try cancellation.check()
    }
}
