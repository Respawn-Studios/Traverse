import Darwin
import Foundation

/// Read-only recognition of a receive interrupted before its editor could
/// attach a body. It grants no cleanup, retirement, or mutation authority.
struct SFTPIncompleteReceiveDiscovery {
    let editorIDs: Set<UUID>

    static func inspect(transaction: SFTPSharedBudgetTransaction,
                        editors: SFTPOriginalEditorCatalogDocument,
                        journal: SFTPInPlaceJournalDocument?) throws -> Self {
        let document = transaction.document
        guard !document.metadata.contains(where: { [.allocating, .removalPending].contains($0.phase) }),
              !document.bodies.contains(where: { $0.phase == .removalPending }) else {
            throw SFTPSharedBudgetFailure.recoveryRequired
        }
        let allocating = document.bodies.filter { $0.phase == .allocating }
        let receiving = editors.records.filter { $0.phase == .receiving }
        guard !allocating.isEmpty || receiving.isEmpty else { throw SFTPSharedBudgetFailure.recoveryRequired }
        guard !receiving.isEmpty || allocating.isEmpty else { throw SFTPSharedBudgetFailure.recoveryRequired }
        if allocating.isEmpty { return .init(editorIDs: []) }

        guard let budgetID = document.budgetID,
              let pool = try SMBCatalogFiles.openPool(transaction.layout.bodies, create: false) else {
            throw SFTPSharedBudgetFailure.recoveryRequired
        }
        defer { Darwin.close(pool) }
        let lock = try SMBCatalogFiles.lockPool(pool, create: false)
        defer { Darwin.close(lock) }
        guard try SFTPSharedBudgetTransaction.readFence(pool, name: SFTPSharedBudgetTransaction.bodyFence,
            prefix: "MEXSHAREDBODY1") == budgetID else { throw SFTPSharedBudgetFailure.recoveryRequired }
        let physical = try DownloadDisk.inventory(pool, originalBudgetID: budgetID)
        var recognized = Set<UUID>()
        for charge in allocating {
            guard let ownerID = charge.owner,
                  let owner = document.metadata.first(where: { $0.id == ownerID }),
                  owner.kind == .original, owner.phase == .removed,
                  let session = owner.session, let context = owner.context else {
                throw SFTPSharedBudgetFailure.recoveryRequired
            }
            // A v3 body marker has no Open-versus-Save bit. Isolation is safe
            // only when this former owner has no other live body or document
            // that could have produced the uncommitted allocation.
            guard document.bodies.filter({ $0.owner == ownerID && $0.phase != .removed }).map(\.id) == [charge.id],
                  !(document.retirements ?? []).contains(where: { $0.owner == ownerID }) else {
                throw SFTPSharedBudgetFailure.recoveryRequired
            }
            var absent = stat(); errno = 0
            guard fstatat(transaction.pool, "session-" + ownerID.uuidString, &absent, AT_SYMLINK_NOFOLLOW) < 0,
                  errno == ENOENT else { throw SFTPSharedBudgetFailure.recoveryRequired }
            let matches = try receiving.filter {
                let digest = try SFTPSharedBudgetTransaction.contextDigest($0.context)
                return $0.session == session && $0.expectedBytes == charge.expectedBytes && digest == context
            }
            let ownerEditors = try editors.records.filter {
                let digest = try SFTPSharedBudgetTransaction.contextDigest($0.context)
                return $0.session == session && digest == context
            }
            let ownerSaves = try (journal?.records ?? []).filter {
                let digest = try SFTPSharedBudgetTransaction.contextDigest($0.context)
                return $0.session == session && digest == context
            }
            guard matches.count == 1, let editor = matches.first, !recognized.contains(editor.id),
                  ownerEditors.map(\.id) == [editor.id], ownerSaves.isEmpty,
                  !(document.retirements ?? []).contains(where: {
                      $0.editor.id == editor.id || $0.bodies.contains(where: { $0.reference.id == charge.id })
                  }),
                  !editors.records.contains(where: {
                      $0.bodyID == charge.id || $0.body?.id == charge.id || $0.recovery.contains(where: { $0.id == charge.id })
                  }),
                  !(journal?.records ?? []).contains(where: { $0.baseline.id == charge.id || $0.edited.id == charge.id }),
                  let record = physical.first(where: { $0.summary.id == charge.id }),
                  !record.summary.active, !record.summary.isFolder,
                  record.summary.expectedBytes == charge.expectedBytes,
                  record.reservedBytes == charge.reservedBytes else {
                throw SFTPSharedBudgetFailure.recoveryRequired
            }
            let marker = try JSONDecoder().decode(DownloadDisk.Marker.self, from: record.marker)
            guard marker.version == 3, marker.originalBudget == budgetID, marker.originalOwner == ownerID else {
                throw SFTPSharedBudgetFailure.recoveryRequired
            }
            recognized.insert(editor.id)
        }
        guard recognized == Set(receiving.map(\.id)) else { throw SFTPSharedBudgetFailure.recoveryRequired }
        return .init(editorIDs: recognized)
    }
}
