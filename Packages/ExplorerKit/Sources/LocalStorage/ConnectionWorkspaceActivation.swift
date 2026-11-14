import Darwin
import Foundation

extension ConnectionWorkspaceDisk {
    static func activate(_ paths: ConnectionWorkspacePaths, file: File) throws -> ConnectionWorkspaceRecord {
        try checkThread(); try file.validateCurrent()
        guard file.snapshot.revision == 0 else { throw ConnectionWorkspaceFailure.reviewRequired }
        try requireAbsent(paths.earlierSiblings + paths.graph)
        guard let pool = try SMBCatalogFiles.openPool(paths.earlier, create: true) else { throw ConnectionWorkspaceFailure.unsafe }
        defer { Darwin.close(pool) }
        let oldLock = try SMBCatalogFiles.lockPool(pool, create: true); defer { Darwin.close(oldLock) }
        // Record EX -> actual old allocator EX -> fresh exact revalidation.
        try SMBCatalogFiles.validatePool(pool, at: paths.earlier)
        try requireAbsent(paths.earlierSiblings + paths.graph)
        let earlierRecords: [SMBCatalogFiles.Record]
        do { earlierRecords = try SMBCatalogFiles.legacyInventory(pool) }
        catch { throw ConnectionWorkspaceFailure.reviewRequired }
        guard earlierRecords.isEmpty else { throw ConnectionWorkspaceFailure.reviewRequired }
        var value = ConnectionWorkspaceRecord(); value.revision = 1; value.activationID = UUID(); value.budgetID = UUID()
        value.earlier = try identity(pool, directory: true); value.earlierLock = try identity(oldLock, directory: false)
        value.locationDigest = paths.locationDigest
        try file.commit(value)
        #if DEBUG
        try ConnectionWorkspaceQualification.shared.reach(.preparingRecorded)
        #endif
        try Task.checkCancellation()
        guard let activation = value.activationID, let budget = value.budgetID else { throw ConnectionWorkspaceFailure.unsafe }
        try establishLegacyFence(pool: pool, lock: oldLock, activation: activation)
        let earlierParent = Darwin.open(paths.earlier.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard earlierParent >= 0 else { throw ConnectionWorkspaceFailure.unsafe }
        do { try sync(earlierParent); Darwin.close(earlierParent) }
        catch { Darwin.close(earlierParent); throw error }
        // Fencing is irreversible here. Every failure retains preparing and all
        // created objects. There is no automatic continuation or rollback.
        try Task.checkCancellation(); try establishGraph(paths, budgetID: budget)
        // The preparing v1 record retains its original strict device witness.
        // Only the fully established active graph publishes fd-bound, reboot-
        // stable APFS volume UUIDs. An older reader rejects v3 canonically.
        value.earlier = try identity(pool, directory: true, stable: true)
        value.earlierLock = try identity(oldLock, directory: false, stable: true)
        value.graph = try graphIdentity(paths, stable: true)
        value.format = 3; value.protocolIdentity = "traverse-persistent-connections-v3"
        value.phase = .active; value.revision = 2
        // The actual earlier pool is still held, and all graph roots are now
        // synced before the location commit can expose a new allocator.
        try validateLegacyFence(paths, record: value)
        try file.commit(value)
        #if DEBUG
        try ConnectionWorkspaceQualification.shared.reach(.activeRecorded)
        #endif
        return value
    }
    private static func establishGraph(_ paths: ConnectionWorkspacePaths, budgetID: UUID) throws {
        try requireAbsent(paths.graph)
        let storage = try SMBTemporaryStorage(unadmittedWorkspaceDirectory: paths.metadata)
        let layout = SFTPSharedBudgetLayout(storage: storage)
        guard let pool = try SMBCatalogFiles.openPool(layout.metadata, create: true) else { throw ConnectionWorkspaceFailure.unsafe }
        defer { Darwin.close(pool) }
        let lock = try SMBCatalogFiles.lockPool(pool, create: true); defer { Darwin.close(lock) }
        guard (try SMBCatalogFiles.legacyInventory(pool)).isEmpty else { throw ConnectionWorkspaceFailure.reviewRequired }
        try SFTPSharedBudgetTransaction.writeFence(pool, name: SFTPSharedBudgetTransaction.metadataFence, prefix: "MEXSHAREDMETA1", id: budgetID)
        #if DEBUG
        try ConnectionWorkspaceQualification.shared.reach(.metadataFenceWritten)
        #endif
        guard let ledger = try RemoteSettingsFile<SFTPSharedBudgetDocument>.open(layout.ledger, writing: true) else { throw ConnectionWorkspaceFailure.unsafe }
        defer { ledger.close() }
        guard ledger.snapshot.revision == 0 else { throw ConnectionWorkspaceFailure.reviewRequired }
        var document = SFTPSharedBudgetDocument(); document.revision = 1; document.budgetID = budgetID
        try ledger.commit(document)
        #if DEBUG
        try ConnectionWorkspaceQualification.shared.reach(.ledgerWritten)
        #endif
        guard let bodies = try SMBCatalogFiles.openPool(layout.bodies, create: true) else { throw ConnectionWorkspaceFailure.unsafe }
        defer { Darwin.close(bodies) }
        let bodyLock = try SMBCatalogFiles.lockPool(bodies, create: true); defer { Darwin.close(bodyLock) }
        try SFTPSharedBudgetTransaction.writeFence(bodies, name: SFTPSharedBudgetTransaction.bodyFence, prefix: "MEXSHAREDBODY1", id: budgetID)
        #if DEBUG
        try ConnectionWorkspaceQualification.shared.reach(.bodyFenceWritten)
        #endif
        guard let editors = try RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>.open(layout.editors, writing: true),
              let journal = try RemoteSettingsFile<SFTPInPlaceJournalDocument>.open(layout.journal, writing: true) else { throw ConnectionWorkspaceFailure.unsafe }
        defer { editors.close(); journal.close() }
        guard editors.snapshot.revision == 0, journal.snapshot.revision == 0 else { throw ConnectionWorkspaceFailure.reviewRequired }
        try editors.commit(SFTPOriginalEditorCatalogDocument()); try journal.commit(SFTPInPlaceJournalDocument())
        document.poolPhase = .active; document.revision += 1; try ledger.commit(document)
        let parent = Darwin.open(paths.metadata.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard parent >= 0 else { throw ConnectionWorkspaceFailure.unsafe }; defer { Darwin.close(parent) }; try sync(parent)
        try SFTPSharedBudgetTransaction.validateMetadataFootprint(layout, workspaceRecordBytes: try recordFootprint(paths))
        #if DEBUG
        try ConnectionWorkspaceQualification.shared.reach(.graphEstablished)
        #endif
    }
}
