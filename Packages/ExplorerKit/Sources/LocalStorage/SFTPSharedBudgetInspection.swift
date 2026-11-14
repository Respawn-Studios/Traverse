import Darwin
import Foundation

/// Closed metadata-only view. Reservation totals deliberately do not claim
/// that a partial/corrupt physical namespace passed current admission checks.
@_spi(Qualification) public struct SFTPOriginalBudgetSummary: Sendable {
    public let revision: UInt64, reservedBytes: UInt64
    public let owners: Int, oldUnassignedOwners: Int, pendingOwners: Int
    public let heldBodies: Int, pendingBodies: Int
    public let inactiveLiveOwners: Int
    public let requiresReview: Bool
}
enum SFTPSharedBudgetInspection {
    /// A fresh read-only file owner under the same actual common lock. This
    /// never constructs the transaction that validates all physical records:
    /// crashed partial mkdir/deletion must remain inspectable as pending data.
    private static func inspect<T>(_ layout: SFTPSharedBudgetLayout,
        read: (Int32, SFTPSharedBudgetDocument) throws -> T) throws -> T? {
        guard !Thread.isMainThread else { throw SFTPSharedBudgetFailure.busy }
        let workspace = try layout.storage.beginWorkspaceTransaction(); defer { workspace?.close() }
        guard let pool = try SMBCatalogFiles.openPool(layout.metadata, create: false) else { return nil }
        defer { Darwin.close(pool) }
        let lock = try SMBCatalogFiles.lockPool(pool, create: false); defer { Darwin.close(lock) }
        try workspace?.validateCurrent()
        try SMBCatalogFiles.validatePool(pool, at: layout.metadata)
        guard try SFTPSharedBudgetTransaction.hasFence(pool) else { return nil }
        let budgetID = try SFTPSharedBudgetTransaction.readFence(pool,
            name: SFTPSharedBudgetTransaction.metadataFence, prefix: "MEXSHAREDMETA1")
        guard let file = try RemoteSettingsFile<SFTPSharedBudgetDocument>.open(layout.ledger, writing: false) else { throw SFTPSharedBudgetFailure.recoveryRequired }
        defer { file.close() }; try file.validateCurrent(); try file.snapshot.validate()
        guard file.snapshot.budgetID == budgetID else { throw SFTPSharedBudgetFailure.recoveryRequired }
        // Observe liveness and the SAME ledger revision under pool.lock. No
        // cleanup, phase repair, replay, revision write or authority is minted.
        let value = try read(pool, file.snapshot); try file.validateCurrent(); return value
    }
    static func document(_ layout: SFTPSharedBudgetLayout) throws -> SFTPSharedBudgetDocument? {
        try inspect(layout) { _, value in value }
    }
    static func summary(_ layout: SFTPSharedBudgetLayout) throws -> SFTPOriginalBudgetSummary? {
        try inspect(layout) { pool, value in
            let held = value.bodies.filter { $0.phase != .removed }
            let pendingOwners = value.metadata.filter { [.allocating, .removalPending, .orphan].contains($0.phase) }.count
            let pendingBodies = held.filter { $0.phase != .allocated }.count
            var inactive = 0
            for owner in value.metadata where owner.phase == .live {
                // record() anchors exact private session/marker/lease identities
                // and uses nonblocking flock. Missing/unsafe/unavailable fails
                // closed, never a falsely clean result or an inferred owner.
                let record = try SMBCatalogFiles.record(pool, name: "session-" + owner.id.uuidString)
                guard record.summary.id == owner.id else { throw SFTPSharedBudgetFailure.stale }
                if !record.summary.active { inactive += 1 }
            }
            return .init(revision: value.revision,
                reservedBytes: try value.globalCharge(actualBodies: [:], limit: layout.storage.poolByteLimit),
                owners: value.metadata.filter { $0.phase != .removed }.count,
                oldUnassignedOwners: value.metadata.filter { $0.kind == .legacy && $0.phase != .removed }.count,
                pendingOwners: pendingOwners, heldBodies: held.count, pendingBodies: pendingBodies, inactiveLiveOwners: inactive,
                requiresReview: value.poolPhase != .active || pendingOwners != 0 || pendingBodies != 0 || inactive != 0)
        }
    }
}
