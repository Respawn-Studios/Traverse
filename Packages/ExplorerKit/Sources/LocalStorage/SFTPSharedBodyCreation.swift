import Darwin
import Foundation

/// A real reserved body, never a caller-created bool, cache URL or journal row.
final class SFTPOriginalBodyAllocation: @unchecked Sendable, CustomDebugStringConvertible {
    let id: UUID, owner: SFTPOriginalStorageOwner, reservedBytes: UInt64
    fileprivate init(id: UUID, owner: SFTPOriginalStorageOwner, reservedBytes: UInt64) {
        self.id = id; self.owner = owner; self.reservedBytes = reservedBytes
    }
    var debugDescription: String { "<reserved Original body>" }
    func checkLive() throws { try owner.checkLive() }
}

/// The common metadata lock stays held from durable reservation through actual
/// mkdir/materialization. Body lock is always acquired inside this lifetime.
final class SFTPSharedBodyCreation {
    let transaction: SFTPSharedBudgetTransaction, allocation: SFTPOriginalBodyAllocation
    private var possibleCreation = false, completed = false
    init(owner: SFTPOriginalStorageOwner, expectedBytes: UInt64) throws {
        try owner.checkLive()
        guard expectedBytes <= 1 << 20 else { throw SFTPSharedBudgetFailure.capacity }
        let transaction = try SFTPSharedBudgetTransaction.open(layout: owner.layout, writing: true)
        do {
            try owner.checkLive()
            guard transaction.document.budgetID == owner.budgetID,
                  let metadata = transaction.document.metadata.first(where: { $0.id == owner.catalogID }),
                  metadata.kind == .original, metadata.phase == .live, metadata.session == owner.session,
                  metadata.context == owner.contextDigest else { throw SFTPSharedBudgetFailure.stale }
            var next = transaction.document; next.bodies.removeAll { $0.phase == .removed }
            guard next.bodies.count < (next.format == 3 ? SFTPSharedBudgetDocument.expandedBodySlots : 8) else {
                throw SFTPSharedBudgetFailure.capacity
            }
            let id = UUID(), reserved = try DownloadDisk.reservation(expectedBytes: expectedBytes, tree: false)
            next.bodies.append(.init(id: id, owner: owner.catalogID, expectedBytes: expectedBytes, reservedBytes: reserved, phase: .allocating))
            let held = next.bodies.filter { $0.owner == owner.catalogID }.map(\.reservedBytes)
            _ = try SFTPSharedBudgetDocument.sum(held + [metadata.quota, 64 << 10, SFTPSharedBudgetDocument.ownerOverheadBytes],
                limit: SFTPSharedBudgetDocument.ownerBytes)
            try transaction.commit(next)
            #if DEBUG
            try SFTPSharedBudgetQualification.shared.reach(.bodyReserved)
            #endif
            self.transaction = transaction; allocation = .init(id: id, owner: owner, reservedBytes: reserved)
        } catch { transaction.close(); throw error }
    }
    func beforeMkdir() throws {
        possibleCreation = true
        #if DEBUG
        try SFTPSharedBudgetQualification.shared.reach(.bodyBeforeMkdir)
        #endif
    }
    func materialized(bodyPool: Int32, lease: Int32) throws {
        guard let budgetID = transaction.document.budgetID else { throw SFTPSharedBudgetFailure.unsafe }
        let current = try DownloadDisk.record(bodyPool, name: "download-" + allocation.id.uuidString, heldLease: lease)
        let marker = try JSONDecoder().decode(DownloadDisk.Marker.self, from: current.marker)
        guard marker.version == 3, marker.originalBudget == budgetID, marker.originalOwner == allocation.owner.catalogID,
              current.summary.active else { throw SFTPSharedBudgetFailure.unsafe }
        var charges: [UUID: UInt64] = [:]
        for record in try DownloadDisk.inventory(bodyPool, originalBudgetID: budgetID) {
            charges[record.summary.id] = max(record.summary.observedBytes, record.reservedBytes)
        }
        var next = transaction.document
        guard let index = next.bodies.firstIndex(where: { $0.id == allocation.id }), next.bodies[index].phase == .allocating else { throw SFTPSharedBudgetFailure.stale }
        next.bodies[index].phase = .allocated
        let owned = next.bodies.filter { $0.owner == allocation.owner.catalogID && $0.phase != .removed }
            .map { max($0.reservedBytes, charges[$0.id] ?? 0) }
        _ = try SFTPSharedBudgetDocument.sum(owned, limit: SFTPSharedBudgetDocument.originalBodyBytes)
        try transaction.commit(next, actualBodies: charges); completed = true
        #if DEBUG
        try SFTPSharedBudgetQualification.shared.reach(.bodyMaterialized)
        #endif
    }
    func closeAfterConstructor() {
        defer { transaction.close() }
        guard !completed, !possibleCreation else { return }
        // Only this exact constructor knows it never submitted mkdir. Absence
        // is rechecked under the same common lock before releasing its bucket.
        do {
            guard let pool = try SMBCatalogFiles.openPool(allocation.owner.layout.bodies, create: false) else { throw SFTPSharedBudgetFailure.recoveryRequired }
            defer { Darwin.close(pool) }
            let lock = try SMBCatalogFiles.lockPool(pool, create: false); defer { Darwin.close(lock) }
            var facts = stat()
            guard fstatat(pool, "download-" + allocation.id.uuidString, &facts, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { return }
            var next = transaction.document
            guard let index = next.bodies.firstIndex(where: { $0.id == allocation.id }), next.bodies[index].phase == .allocating else { return }
            next.bodies[index].phase = .removed
            let charges = try DownloadDisk.inventory(pool, originalBudgetID: allocation.owner.budgetID)
                .reduce(into: [UUID: UInt64]()) { $0[$1.summary.id] = max($1.summary.observedBytes, $1.reservedBytes) }
            try transaction.commit(next, actualBodies: charges)
        } catch { /* A lost abort stays charged; never infer no allocation. */ }
    }
}
