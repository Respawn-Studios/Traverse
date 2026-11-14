import ExplorerCore
import Foundation
import SQLite3

extension NameIndexDatabase {
    func libraryRows(count: Int, before: Int?) throws -> [(Int, RememberedItemID)] {
        let statement = try prepare("SELECT record,id FROM records WHERE hidden=0 AND record<? ORDER BY record DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, Int64(before ?? Int.max)))
        try check(sqlite3_bind_int(statement, 2, Int32(count)))
        var result: [(Int, RememberedItemID)] = []
        while try step(statement) {
            guard let id = UUID(uuidString: try text(statement, column: 1)) else { throw NameStoreFailure.unsafe }
            result.append((try integer(statement, column: 0), RememberedItemID(id)))
        }
        return result
    }
}

extension PersistentNameStore {
    /// Explicit maintenance UI can distinguish the two pending fences after
    /// opening recovery. Inspection itself never writes or upgrades storage.
    public func pendingMaintenance() throws -> (forget: Bool, access: Bool) {
        try requireOpen(); try catalog.validate()
        return (try database.pendingForgetCount() > 0,
                try database.hasReferenceFormat && database.pendingAccessRemovals() > 0)
    }
    public func maintenanceStatus() throws -> NameStoreStatus {
        try requireOpen(); try catalog.validate()
        if try database.pendingForgetCount() > 0 { return .forgetPending }
        if try !database.hasReferenceFormat { return .referenceUpdateRequired }
        if try database.pendingAccessRemovals() > 0 { return .accessRemovalPending }
        return try database.validateFormat(catalog).compatible ? .ready : .indexUpdateRequired
    }
    public func library(pageSize: Int = 64, cancellation: RememberedNameCancellation = .init()) throws -> StoredNamePage {
        let activityLease = try activity?.begin(); defer { withExtendedLifetime(activityLease) {} }
        try requireOpen(); try catalog.validate()
        let (token, epoch) = try publication.beginQuery(cancellation)
        defer { publication.endQuery(token) }
        let page = try core.library(count: pageSize, cancellation: cancellation)
        try catalog.validate(); return try publication.capture(page, epoch: epoch)
    }
    public nonisolated func beginUse(_ snapshot: StoredNameSnapshot) throws -> RememberedNameUse { try publication.beginUse(snapshot) }

    /// Lookup from an explicit current selection; never enables document flags,
    /// restores access or adopts a last-known path. Unknown-item work drains for
    /// any Forget because its affected record is not yet known.
    public func lookup(source: URL, retaining access: (any Sendable)? = nil) async throws -> StoredNameSnapshot? {
        let lease = try activity?.begin(), use = try publication.beginDiscoveryUse()
        defer { withExtendedLifetime(lease) {}; withExtendedLifetime(use) {}; withExtendedLifetime(access) {} }
        try requireOpen(); try catalog.validate()
        guard try !database.hasAllFence() else { throw NameIndexFailure.missingRecord }
        let cancellation = RememberedNameCancellation()
        let (token, epoch) = try publication.beginQuery(cancellation)
        defer { publication.endQuery(token) }
        let observed = try await referenceReader.capture(source, cancellation: cancellation)
        try requireOpen(); try catalog.validate()
        guard !cancellation.isCancelled else { throw RememberedReferenceFailure.stale }
        guard try !database.hasAllFence() else { throw NameIndexFailure.missingRecord }
        guard let id = try database.referenceCollision(observed.reference, excluding: nil) else { return nil }
        return try publication.capture(core.snapshot(id), epoch: epoch)
    }

    /// Exact-location admission check for file-operation guards. This reads
    /// native metadata and the active reference index, never creates a bookmark,
    /// enables following, resolves a stored reference, or reads file contents.
    /// A stale path hint with a different current object is uncertain.
    public func hasCurrentBoundReference(at source: URL, retaining access: (any Sendable)? = nil) async throws -> Bool {
        let lease = try activity?.begin(), use = try publication.beginDiscoveryUse()
        defer { withExtendedLifetime(lease) {}; withExtendedLifetime(use) {}; withExtendedLifetime(access) {} }
        try requireOpen(); try catalog.validate()
        guard try database.hasReferenceFormat else { throw NameStoreFailure.referenceUpdateRequired }
        guard try !database.hasAllFence(), try database.pendingForgetCount() == 0 else { throw NameStoreFailure.forgetPending }
        guard try database.pendingAccessRemovals() == 0 else { throw NameStoreFailure.recoveryRequired }
        let cancellation = RememberedNameCancellation()
        let (token, _) = try publication.beginQuery(cancellation)
        defer { publication.endQuery(token) }
        let identity = try await referenceReader.currentIdentity(source, cancellation: cancellation)
        try requireOpen(); try catalog.validate()
        guard !cancellation.isCancelled else { throw RememberedReferenceFailure.stale }
        guard try !database.hasAllFence(), try database.pendingForgetCount() == 0 else { throw NameStoreFailure.forgetPending }
        guard try database.pendingAccessRemovals() == 0 else { throw NameStoreFailure.recoveryRequired }
        if let identity, try database.activeReference(volume: identity.volume, document: identity.document) { return true }
        guard try !database.activeReferenceHint(source.path) else { throw RememberedReferenceFailure.changed }
        return false
    }

    /// Holds the original native read scope and affected-item use through the
    /// caller's actual work. The URL is still not source-mutation authority.
    /// Consumers revalidate their own selection/action before native handoff.
    public func withVerifiedReference<T: Sendable>(_ id: RememberedItemID,
        perform: @Sendable (URL) async throws -> T) async throws -> T {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireOpen(); try catalog.validate()
        guard publication.allows(id), try !database.hasAllFence(), try !database.hasPendingMoveHandoff(id),
              let row = try database.reference(id), row.access == 0,
              let evidence = row.evidence else { throw RememberedReferenceFailure.stale }
        let use = try publication.beginReferenceUse(id), work = try references.begin(id)
        defer { references.finish(work); withExtendedLifetime(use) {} }
        let access = try await referenceReader.access(evidence, cancellation: work.cancellation)
        do {
            try requireOpen(); try catalog.validate()
            guard references.current(work), publication.allows(id),
                  try !database.hasAllFence(), try !database.hasPendingMoveHandoff(id),
                  try database.reference(id)?.revision == row.revision else { throw RememberedReferenceFailure.stale }
            let result = try await perform(access.observation.url)
            await referenceReader.release(access)
            return result
        } catch {
            await referenceReader.release(access)
            throw error
        }
    }
}
