import Foundation

/// Session-only consent context for explicitly continuing untouched work. This is
/// not crash recovery and never grants permission to replace a new occupant.
public struct TransferContinuation: Sendable {
    public let id: UUID
    public let previousJobID: UUID
    public let previousRecordID: UUID?
    public let remainingSources: [URL]
    public let destinationDirectory: URL
    public let isMove: Bool
    public let metadataPolicy: TransferMetadataPolicy
    internal let session: UUID
    internal let units: [ContinuationUnit]
    internal let records: [ContinuationRecord]
    internal let containers: [TransferEntry]
    internal let roots: [UUID: ContinuationRoot]
    internal let use: ContinuationUse
    internal var groupedRecords: [GroupedCopyContinuationRecord] = []
}

internal struct ContinuationRoot: Sendable {
    let id: UUID
    let source: URL
}

internal struct ContinuationUnit: Sendable {
    let entry: TransferEntry
    let source: ContinuationGuard
    let destination: ContinuationGuard?
}

internal struct ContinuationGuard: Sendable {
    let tree: VerifiedTree
    let identities: [String: EntrySnapshot]
    static func observe(_ url: URL, cancellation: OperationCancellation, budget: TraversalBudget) throws -> Self {
        let parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
        return try observe(parent: parent.fd, name: url.lastPathComponent, cancellation: cancellation, budget: budget)
    }
    static func observe(parent: Int32, name: String, cancellation: OperationCancellation,
                        budget: TraversalBudget = TraversalBudget(), nativeRename: NativeRenameSecurityProjection? = nil) throws -> Self {
        let comparison = CopyComparison()
        let tree = try verifiedTree(parent: parent, name: name, cancellation: cancellation, budget: budget, copyComparison: comparison, nativeRename: nativeRename)
        return Self(tree: tree, identities: comparison.nodes.mapValues(\.identity))
    }
    func matches(_ other: Self) -> Bool {
        tree.matches(other.tree) && identities == other.identities
    }
    /// A rename changes the root's ctime, but must not adopt a substituted descendant.
    func matchesRelocated(_ other: Self) -> Bool {
        tree.matches(other.tree) && matchesRelocatedIdentities(other)
    }
    /// A separately qualified tree transition must still reject substituted
    /// descendants; only the root's rename-induced ctime is allowed to change.
    func matchesRelocatedIdentities(_ other: Self) -> Bool {
        identities.count == other.identities.count && identities.allSatisfy { path, identity in
            guard let actual = other.identities[path] else { return false }
            return path.isEmpty ? identity.sameObject(as: actual) : identity == actual
        }
    }
    /// Merge expansion may narrow a previously skipped folder. Bind the child
    /// observation to the original exact snapshots, including every ctime. Full
    /// ancestor guards are validated on both sides of these admission scans.
    func projecting(_ relative: String, onto observation: Self, failure: FileOperationFailure) throws -> Self {
        if relative.isEmpty {
            guard matches(observation) else { throw failure }
            return self
        }
        let projected = Dictionary(uniqueKeysWithValues: identities.compactMap { path, identity in
            path == relative || path.hasPrefix(relative + "/")
                ? (path == relative ? "" : String(path.dropFirst(relative.count + 1)), identity) : nil
        })
        guard !projected.isEmpty, projected == observation.identities else { throw failure }
        return Self(tree: observation.tree, identities: projected)
    }
}

internal struct ContinuationRecord: Sendable {
    let id: UUID
    let revision: Int
}

/// Copies of the token and plans prepared from it share one consumption gate.
internal final class ContinuationUse: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func validate() throws {
        try lock.withLock { if claimed { throw FileOperationFailure.invalidRequest } }
    }
    func claim() throws {
        try lock.withLock {
            guard !claimed else { throw FileOperationFailure.invalidRequest }
            claimed = true
        }
    }
}

extension RecoverableFileOperations {
    public func prepareContinuation(_ token: TransferContinuation,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async throws -> TransferPlan {
        let reporter = OperationProgressReporter(callback: progress)
        do {
            let plan = try await worker(progress: reporter) { cancellation in
                let journal = try token.records.isEmpty && token.groupedRecords.isEmpty ? nil : OperationJournal(self.directory, hooks: self.hooks.journalHooks, cancellation: cancellation)
                try self.validateContinuation(token, journal: journal, cancellation: cancellation)
                var conflicts: [TransferConflict] = []
                func visit(_ entry: TransferEntry) throws {
                    if let destination = entry.destinationIdentity {
                        var conflict = TransferConflict(id: entry.id, source: entry.source,
                            destination: entry.destination, canMerge: entry.children != nil)
                        conflict.kind = try TransferConflictKind.observe(source: entry.source, destination: entry.destination,
                            sourceIdentity: entry.sourceIdentity, destinationIdentity: destination)
                        conflicts.append(conflict)
                    }
                    try entry.children?.forEach(visit)
                }
                try token.units.forEach { try visit($0.entry) }
                return TransferPlan(jobID: reporter.jobID, progressReporter: reporter,
                    conflicts: conflicts, sources: token.remainingSources,
                    destinationDirectory: token.destinationDirectory, isMove: token.isMove,
                    metadataPolicy: token.metadataPolicy, executionDecision: .standard(.continuation),
                    entries: token.units.map(\.entry), continuation: token,
                    moveReservation: token.isMove ? MoveRecordReservation(owner: self.continuationSession) : nil)
            }
            reporter.flush(); return plan
        } catch { reporter.finish(success: false); throw error }
    }

    internal func validateContinuation(_ token: TransferContinuation, journal: OperationJournal?,
                                      cancellation: OperationCancellation) throws {
        guard token.session == continuationSession else { throw FileOperationFailure.invalidRequest }
        guard token.records.count <= OperationJournal.maximumInputs else { throw FileOperationFailure.unsupported }
        try token.use.validate()
        for dependency in token.records {
            try cancellation.check()
            guard let record = try journal?.inspectRecord(dependency.id), record.state == "committed",
                  record.revision == dependency.revision else { throw FileOperationFailure.recoveryUncertain }
        }
        try validateGroupedContinuationDependencies(token, journal: journal, cancellation: cancellation)
        let budget = TraversalBudget()
        for unit in token.units {
            try cancellation.check()
            let entry = unit.entry
            let sourceParent = try DirectoryAnchor(entry.source.deletingLastPathComponent(), resolve: false)
            let destinationParent = try DirectoryAnchor(entry.destination.deletingLastPathComponent(), resolve: false)
            guard sourceParent.identity.sameObject(as: entry.sourceParent) else { throw FileOperationFailure.sourceChanged }
            guard destinationParent.identity.sameObject(as: entry.destinationParent) else { throw FileOperationFailure.destinationChanged }
            guard unit.source.matches(try ContinuationGuard.observe(entry.source, cancellation: cancellation, budget: budget)) else {
                throw FileOperationFailure.sourceChanged
            }
            if let destination = unit.destination {
                guard destination.matches(try ContinuationGuard.observe(entry.destination, cancellation: cancellation, budget: budget)) else {
                    throw FileOperationFailure.destinationChanged
                }
            } else {
                do { try requireAbsent(entry.destination.lastPathComponent, in: destinationParent.fd) }
                catch FileOperationFailure.conflict { throw FileOperationFailure.destinationChanged }
            }
        }
    }
}
