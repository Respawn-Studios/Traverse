import CryptoKit
import Darwin
import Foundation

internal struct JournalStep: Codable, Equatable, Sendable {
    let source: URL
    let destination: URL
    let sourceParent: EntrySnapshot
    let destinationParent: EntrySnapshot
    let before: VerifiedTree
    var after: VerifiedTree?
    var undone: Bool = false
    /// V13 ZIP / v18 TAR / v19 TAR.gz: retained-original after-image passed the additional
    /// source-mark/public-security checks and was saved before replacement.
    var archiveOriginalRetainedQualified: Bool? = nil
    /// Forward v9/v12 directory admission witness. Retained through Undo and v10 Delete.
    var nativeTrashRootAddition: NativeTrashRootMetadataProofV4? = nil
    /// V11/v12 regular-file contract: whether macOS changed the root quarantine mark.
    /// This is a boolean observation, never the raw mark or its digest.
    var nativeTrashMarkChanged: Bool? = nil
    /// V12 directory's complete committed descendant identity walk. No path is stored.
    var nativeTrashDirectoryDescendantIdentity: Data? = nil
    /// V15 only: public-mark requirement observed on the fresh ZIP member.
    /// False permits an unmarked source/member without asserting mark absence.
    var publicZIPExtractionMarkRequired: Bool? = nil
    /// V17 only: public-mark requirement on the fresh TAR member.
    var publicTARExtractionMarkRequired: Bool? = nil
    /// Present only after a confirmed ordinary Trash job becomes owned-Trash v8.
    var ownedTrashDeletion: OwnedTrashEntryState? = nil
    /// An exact private staging candidate, recorded before a destructive rename.
    var ownedTrashStageURL: URL? = nil
}

internal struct JournalArea: Codable, Equatable, Sendable {
    let url: URL
    let identity: EntrySnapshot
    // Missing in older v1 JSON/SQLite rows; never infer this proof from leftovers.
    var stagingProof: JournalStagingProof? = nil
}
internal struct JournalTrashIntent: Codable, Equatable, Sendable {
    let source: URL
    let sourceParent: EntrySnapshot
    let before: VerifiedTree
}

internal struct JournalRecord: Codable, Sendable {
    var version: Int
    let owner: UUID
    let id: UUID
    let operation: String
    var createdAt: Date = Date()
    var revision: Int = 0
    var state: String = "preparing"
    /// Constant operation stage only; never an error body, path, or file content.
    var failureStage: String?
    var locations: [URL] = []
    var steps: [JournalStep] = []
    var areas: [JournalArea] = []
    var trashIntents: [JournalTrashIntent] = []
    /// Versions 2 and 4. A bounded same-parent namespace operation, never a tree step.
    var nameRename: JournalNameRename?
    /// Version 7 only: one sealed binary Download spool adoption.
    var downloadAdoption: JournalDownloadAdoption?
    /// Versions 3 and 4 bind mount-epoch devices to persistent APFS UUIDs.
    /// Nil is required for legacy versions 1 and 2; never infer a binding on cold open.
    var persistentVolumes: PersistentVolumeBindings?
    /// A v8-only whole-job Undo barrier and bounded per-step count receipt.
    var ownedTrash: JournalOwnedTrashHead? = nil
    /// V16 only: closed producer purpose and the ZIP source-mark fact.
    var producedTreeV16: PublicProducedTreePurposeV16? = nil
}

/// Normalized SQLite metadata; preserved v1 snapshots remain migration evidence.
/// One OS writer lock covers inspection, import, mutation recording and maintenance.
internal struct JournalStorageHooks: Sendable {
    var selectionAfterWriterLock: (@Sendable () throws -> Void)? = nil
    var beforeSaveCommit: (@Sendable () throws -> Void)?
    var afterSaveCommit: (@Sendable () throws -> Void)? = nil
    var afterCommitBeforeAcknowledgement: (@Sendable () throws -> Void)? = nil
    /// Generated-fixture fault qualification only; may lower, never raise the store bound.
    var maximumPageCount: Int64? = nil
    var metrics: JournalMetrics? = nil
    var beforeCatalogUpgradeCommit: (@Sendable () throws -> Void)? = nil
    var afterCatalogUpgradeCommit: (@Sendable () throws -> Void)? = nil
    var beforeTextCheckpointCommit: (@Sendable () throws -> Void)? = nil
    var afterTextCheckpointCommit: (@Sendable () throws -> Void)? = nil
    /// Fixture-only simulated rollback failure; nil preserves the normal rollback.
    var beforeSaveRollback: (@Sendable () throws -> Void)? = nil
    /// Generated-fixture diagnostics only: a numeric SQLite result, never SQL,
    /// paths or error bodies. This observer cannot change error handling.
    var observedSQLiteFailureCode: (@Sendable (Int32) -> Void)? = nil
}

internal final class OperationJournal {
    let anchor: DirectoryAnchor
    let owner: UUID
    private var lockFD: Int32 = -1
    private var store: SQLiteJournalStore?
    private var storageRefusal: URL?
    private var storageFailure: Error?
    private var didImport = false
    private let selectionHistory: SelectionGroupHistoryIdentity?
    private var refused: [URL] = []
    private var refusedIDs = Set<UUID>()
    private let cancellation: OperationCancellation
    private let hooks: JournalStorageHooks
    private var refusedDirectory = false
    static let maximumBytes = 4_194_304 // Legacy revision decoder only.
    static let maximumRecordBytes = 67_108_864
    static let maximumInputs = 1024
    static let maximumSteps = 8192
    static let maximumAreas = 4096
    static let maximumLocations = 16384
    static let maximumTrashIntents = 1024

    init(_ url: URL, hooks: JournalStorageHooks = JournalStorageHooks(), cancellation: OperationCancellation = OperationCancellation(),
         existingGroupedSession: ProductionCopySession? = nil,
         existingSelectionHistory: SelectionGroupHistoryIdentity? = nil) throws {
        guard existingGroupedSession == nil || existingSelectionHistory == nil else { throw FileOperationFailure.invalidRequest }
        selectionHistory = existingSelectionHistory
        self.cancellation = cancellation
        self.hooks = hooks
        try cancellation.check()
        let parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
        try validateName(url.lastPathComponent)
        let created: Bool
        if let existingSelectionHistory {
            try existingSelectionHistory.validate(url); created = false
        } else if let existingGroupedSession {
            guard existingGroupedSession.directory == url else { throw FileOperationFailure.invalidRequest }
            _ = try existingGroupedSession.checkedHistory(); created = false
        } else {
            created = mkdirat(parent.fd, url.lastPathComponent, 0o700) == 0
            if !created, errno != EEXIST { throw posixFailure() }
        }
        anchor = try DirectoryAnchor(url, resolve: false)
        var attributes = stat()
        guard fstat(anchor.fd, &attributes) == 0, attributes.st_uid == geteuid(),
              attributes.st_mode & 0o077 == 0 else { throw FileOperationFailure.accessDenied }
        let marker = ".mac-explorer-journal-v1"
        if created {
            let id = UUID()
            try Self.writeExclusive(Data(id.uuidString.utf8), name: marker, anchor: anchor)
            try syncDirectory(parent)
            owner = id
        } else {
            let data = try Self.read(name: marker, anchor: anchor)
            guard let value = String(data: data, encoding: .utf8), let id = UUID(uuidString: value) else {
                throw FileOperationFailure.recoveryUncertain
            }
            owner = id
        }
        lockFD = openat(anchor.fd, marker, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard lockFD >= 0 else { throw posixFailure() }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { close(lockFD); lockFD = -1; throw FileOperationFailure.unavailable }
        do {
            if let existingSelectionHistory {
                try hooks.selectionAfterWriterLock?()
                try existingSelectionHistory.validateOpened(anchor: anchor, markerFD: lockFD,
                    owner: owner, database: EntrySnapshot(parent: anchor.fd, name: SQLiteJournalStore.name))
            }
            if let existingGroupedSession {
                _ = try existingGroupedSession.checkedHistory()
                guard owner == existingGroupedSession.receipt.owner,
                      try EntrySnapshot(fd: lockFD) == existingGroupedSession.receipt.marker else { throw FileOperationFailure.sourceChanged }
                // Activation imported old archives explicitly. Ordinary grouped
                // execution uses its existing catalog and never imports/upgrades.
                didImport = true
            }
            store = try SQLiteJournalStore(anchor: anchor, owner: owner, hooks: hooks, cancellation: cancellation,
                expectedIdentity: existingSelectionHistory?.database ?? existingGroupedSession?.receipt.database,
                requiresGroupedCatalog: existingGroupedSession != nil, requiresSelectionCatalog: existingSelectionHistory != nil)
            if let existingSelectionHistory {
                try existingSelectionHistory.validateOpened(anchor: anchor, markerFD: lockFD, owner: owner, database: store!.fileIdentity)
            }
        }
        catch {
            // Corrupt/unsafe storage is visible to inspection and blocks writes. Never
            // fall back to an older legacy state after a SQLite record might have advanced.
            storageRefusal = anchor.url.appendingPathComponent(SQLiteJournalStore.name)
            storageFailure = error
        }
    }

    deinit { store = nil; if lockFD >= 0 { close(lockFD) } }

    var inspectionReadiness: OperationHistoryReadiness {
        guard storageRefusal == nil, let store else { return .unavailable }
        return .available(catalogVersion: store.inspectedCatalogVersion)
    }

    func existingGroupedReceipt(scope: QualifiedCopyPreviewScope) throws -> CopyPreviewActivationReceipt {
        try validateWritableCatalog()
        guard let store, [4, 7, 9, 10].contains(store.inspectedCatalogVersion) else { throw FileOperationFailure.recoveryUncertain }
        return CopyPreviewActivationReceipt(version: 1, owner: owner, root: anchor.identity,
            marker: try EntrySnapshot(parent: anchor.fd, name: ".mac-explorer-journal-v1"),
            database: store.fileIdentity, volumes: scope.volumes, historyVolume: scope.historyVolume)
    }

    static func validateCapacity(steps: Int, areas: Int, locations: Int, trashIntents: Int) throws {
        guard (0...maximumSteps).contains(steps), (0...maximumAreas).contains(areas),
              (0...maximumLocations).contains(locations), (0...maximumTrashIntents).contains(trashIntents) else {
            throw FileOperationFailure.unsupported
        }
    }

    func reserveCapacity(steps: Int, areas: Int, locations: Int, trashIntents: Int, estimatedBytes: Int) throws {
        try Self.validateCapacity(steps: steps, areas: areas, locations: locations, trashIntents: trashIntents)
        try importLegacy()
        if let storageFailure { throw storageFailure }
        guard let store, storageRefusal == nil else { throw FileOperationFailure.recoveryUncertain }
        try store.reserve(estimatedBytes: estimatedBytes)
    }

    func beginEdit(operation: String, nameRename: JournalNameRename? = nil, reservedID: UUID? = nil) throws -> JournalEditSession {
        try validateWritableCatalog()
        guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.beginEdit(operation: operation, nameRename: nameRename, reservedID: reservedID)
    }

    func beginReceivedPublicDownloadEdit() throws -> JournalEditSession {
        try validateWritableCatalog()
        guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.beginReceivedPublicDownloadEdit()
    }

    func beginPublicZIPExtractionEdit() throws -> JournalEditSession {
        try validateWritableCatalog()
        guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.beginPublicZIPExtractionEdit()
    }

    func beginPublicTARExtractionEdit() throws -> JournalEditSession {
        try validateWritableCatalog()
        guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.beginPublicTARExtractionEdit()
    }

    func beginProducedTreeV16Edit(purpose: PublicProducedTreePurposeV16) throws -> JournalEditSession {
        try validateWritableCatalog()
        guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.beginProducedTreeV16Edit(purpose: purpose)
    }

    func beginAdditiveRootTrashEdit() throws -> JournalEditSession {
        try validateWritableCatalog()
        guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.beginAdditiveRootTrashEdit()
    }

    /// Regular-file native Trash has a distinct inverse metadata contract.
    /// Older records never acquire that authority during cold recovery.
    func beginNativeTrashEdit() throws -> JournalEditSession {
        try validateWritableCatalog()
        guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.beginNativeTrashEdit()
    }

    /// A fresh folder/mixed job uses its own witness and cold inverse rules.
    func beginNativeDirectoryTrashEdit() throws -> JournalEditSession {
        try validateWritableCatalog()
        guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.beginNativeDirectoryTrashEdit()
    }

    func beginArchiveUpdateEdit(protocolKind: OperationCatalogProtocol) throws -> JournalEditSession {
        try validateWritableCatalog()
        guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.beginArchiveUpdateEdit(protocolKind: protocolKind)
    }

    func beginDownloadAdoptionEdit() throws -> JournalEditSession {
        try validateWritableCatalog()
        guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.beginDownloadAdoptionEdit()
    }

    /// Called from an idle serialized operation, before grouped execution is enabled.
    /// The OS writer lock stays held while the upgraded SQLite connection is replaced.
    func upgradeForGroupedCopy() throws {
        try validateWritableCatalog()
        guard refused.isEmpty, store != nil else { throw FileOperationFailure.recoveryUncertain }
        do {
            let expectedIdentity = store!.fileIdentity
            try store!.upgradeForGroupedCopy(cancellation: cancellation)
            store = nil
            let reopened = try SQLiteJournalStore(anchor: anchor, owner: owner, hooks: hooks, cancellation: cancellation,
                expectedIdentity: expectedIdentity)
            try reopened.validateCatalog(cancellation: cancellation)
            store = reopened
        } catch {
            store = nil; storageFailure = error
            storageRefusal = anchor.url.appendingPathComponent(SQLiteJournalStore.name)
            throw error
        }
    }

    func beginGroupedEdit(members: [GroupedCopyManifestMember], groupSize: Int = 16,
                          metadataPolicy: TransferMetadataPolicy = .strict) throws -> GroupedCopyEditSession {
        try validateWritableCatalog()
        guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.beginGroupedEdit(members: members, groupSize: groupSize, metadataPolicy: metadataPolicy)
    }

    func openGroupedEdit(_ id: UUID) throws -> GroupedCopyEditSession? {
        try validateWritableCatalog()
        guard !refusedIDs.contains(id), let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.openGroupedEdit(id)
    }

    func save(_ session: GroupedCopyEditSession) throws {
        var expectedIdentity: EntrySnapshot?
        do {
            try validateWritableCatalog()
            guard !refusedIDs.contains(session.id), store != nil else { throw FileOperationFailure.recoveryUncertain }
            expectedIdentity = store!.fileIdentity
            try store!.save(session)
        } catch {
            let original = error
            session.invalidate()
            if let expectedIdentity, storageFailure == nil, storageRefusal == nil {
                // Destroy the old connection, including any transaction whose rollback
                // failed. Fresh authority comes only from the same pinned catalog file.
                store = nil
                do {
                    let reopened = try SQLiteJournalStore(anchor: anchor, owner: owner, hooks: hooks,
                        cancellation: cancellation.draining(), expectedIdentity: expectedIdentity)
                    _ = try reopened.catalogRecord(session.id)
                    store = reopened
                } catch {
                    storageFailure = error
                    storageRefusal = anchor.url.appendingPathComponent(SQLiteJournalStore.name)
                }
            }
            throw original
        }
    }

    func inspectCatalogRecord(_ id: UUID) throws -> OperationCatalogRecord? {
        try validateWritableCatalog()
        guard !refusedIDs.contains(id), let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.catalogRecord(id)
    }

    func openEdit(_ id: UUID) throws -> JournalEditSession? {
        try validateWritableCatalog()
        guard !refusedIDs.contains(id), let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.openEdit(id)
    }

    func save(_ session: JournalEditSession) throws {
        try importLegacy()
        if let storageFailure { throw storageFailure }
        guard !refusedIDs.contains(session.id), let store, storageRefusal == nil else { throw FileOperationFailure.recoveryUncertain }
        try store.save(session)
    }

    /// Conservative full-record entry for legacy/fixture snapshots. This never accepts
    /// caller-supplied change hints and invalidates any active incremental session.
    func saveSnapshot(_ record: inout JournalRecord) throws {
        try importLegacy()
        if let storageFailure { throw storageFailure }
        guard record.owner == owner, let store, storageRefusal == nil, !refusedIDs.contains(record.id) else {
            throw FileOperationFailure.recoveryUncertain
        }
        try store.saveSnapshot(record)
        record.revision += 1
    }

    func inspect() throws -> (records: [JournalRecord], refused: [URL]) {
        try anchor.validate()
        try importLegacy()
        if let storageRefusal { return ([], refused + [storageRefusal]) }
        guard let store else { throw FileOperationFailure.recoveryUncertain }
        do { return (try store.records(excluding: refusedIDs), refused) }
        catch {
            storageRefusal = anchor.url.appendingPathComponent(SQLiteJournalStore.name)
            return ([], refused + [storageRefusal!])
        }
    }

    func validateWritableCatalog() throws {
        if selectionHistory != nil { try validateSelectionOwnership() }
        try importLegacy()
        if let storageFailure { throw storageFailure }
        guard let store, storageRefusal == nil else { throw FileOperationFailure.recoveryUncertain }
        try store.validateFiles()
        if [7, 9, 10].contains(store.inspectedCatalogVersion) { try store.validateWriteCatalog(cancellation: cancellation.draining()) }
    }

    func inspectRecord(_ id: UUID) throws -> JournalRecord? {
        try validateWritableCatalog()
        guard !refusedIDs.contains(id), let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.recordIfPresent(id)
    }

    func inspectSummaries(after: UUID? = nil, limit: Int = 64,
        allowNativeOriginalUpdateUndoHint: Bool = false,
        allowNativeTARUpdateUndoHint: Bool = false,
        allowNativeTARGzipUpdateUndoHint: Bool = false,
        allowNativeTARBzip2UpdateUndoHint: Bool = false,
        allowPublicDownloadUndoHint: Bool = false,
        allowPublicZIPExtractionUndoHint: Bool = false,
        allowPublicTARExtractionUndoHint: Bool = false,
        allowReceivedFolderUndoHint: Bool = false,
        allowZIPTreeUndoHint: Bool = false,
        allowTARTreeUndoHint: Bool = false) throws -> (records: [OperationRecoveryRecord], refused: [URL], next: UUID?) {
        try importLegacy()
        if let storageRefusal { return ([], refused + [storageRefusal], nil) }
        guard let store else { throw FileOperationFailure.recoveryUncertain }
        do {
            let page = try store.summaries(after: after, limit: limit, excluding: refusedIDs,
                allowNativeOriginalUpdateUndoHint: allowNativeOriginalUpdateUndoHint,
                allowNativeTARUpdateUndoHint: allowNativeTARUpdateUndoHint,
                allowNativeTARGzipUpdateUndoHint: allowNativeTARGzipUpdateUndoHint,
                allowNativeTARBzip2UpdateUndoHint: allowNativeTARBzip2UpdateUndoHint,
                allowPublicDownloadUndoHint: allowPublicDownloadUndoHint,
                allowPublicZIPExtractionUndoHint: allowPublicZIPExtractionUndoHint,
                allowPublicTARExtractionUndoHint: allowPublicTARExtractionUndoHint,
                allowReceivedFolderUndoHint: allowReceivedFolderUndoHint,
                allowZIPTreeUndoHint: allowZIPTreeUndoHint,
                allowTARTreeUndoHint: allowTARTreeUndoHint)
            return (page.records, refused, page.next)
        } catch {
            return ([], refused + [anchor.url.appendingPathComponent(SQLiteJournalStore.name)], nil)
        }
    }

    func unfinishedCount() throws -> Int {
        try validateWritableCatalog()
        guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.unfinishedCount(cancellation: cancellation)
    }

    func maintenance(compact: Bool = false) throws -> SQLiteJournalStore.MaintenanceSummary {
        try importLegacy()
        if let storageFailure { throw storageFailure }
        guard let store, storageRefusal == nil else { throw FileOperationFailure.recoveryUncertain }
        // A refused legacy chain must never be hidden by maintenance.
        guard !compact || refused.isEmpty else { throw FileOperationFailure.recoveryUncertain }
        return try store.maintenance(compact: compact, cancellation: cancellation)
    }

    func compact() throws -> SQLiteJournalStore.MaintenanceSummary { try maintenance(compact: true) }

    static func validate(_ record: JournalRecord, metrics: JournalMetrics? = nil) throws {
        try validateHeader(record)
        for step in record.steps { metrics?.add(.validatedRows, 1); try validateStep(step) }
        for area in record.areas { metrics?.add(.validatedRows, 1); try validateArea(area, stepCount: record.steps.count) }
        for location in record.locations { metrics?.add(.validatedRows, 1); try validateLocation(location) }
        for intent in record.trashIntents { metrics?.add(.validatedRows, 1); try validateTrashIntent(intent) }
        if [5, 6, 13, 18, 19, 20].contains(record.version) { try validateArchiveUpdate(record) }
        if record.version == 7 { try validateDownloadAdoption(record) }
        if record.version == 14 { try validateReceivedPublicDownload(record) }
        if record.version == 15 { try validatePublicZIPExtraction(record) }
        if record.version == 16 { try validateProducedTreeV16(record) }
        if record.version == 17 { try validatePublicTARExtraction(record) }
        try validateTrashRootAddition(record)
        if [9, 11, 12].contains(record.version) && record.state == "committed" { try OwnedTrashPolicy.committed(record) }
        if [8, 10].contains(record.version) { try OwnedTrashPolicy.validate(record) }
    }

    static func validateHeader(_ record: JournalRecord) throws {
        try record.persistentVolumes?.validateRepresentation()
        try validateCapacity(steps: record.steps.count, areas: record.areas.count,
                             locations: record.locations.count, trashIntents: record.trashIntents.count)
        guard record.revision >= 0, record.operation.utf8.count <= 64,
              (record.failureStage?.utf8.count ?? 0) <= 64,
              ["preparing", "mutating", "committed", "needsReview", "undoing", "undone", "cleanupReview", "cleaned", "trashDeleteReview", "trashDeleted"].contains(record.state)
        else { throw FileOperationFailure.recoveryUncertain }
        guard ([8, 10].contains(record.version)) == (record.ownedTrash != nil) else { throw FileOperationFailure.recoveryUncertain }
        guard (record.version == 16) == (record.producedTreeV16 != nil) else { throw FileOperationFailure.recoveryUncertain }
        if record.version == 8 || record.version == 10 {
            guard record.ownedTrash?.sourceVersion == (record.version == 10 ? 9 : nil) else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
        if [1, 3, 9, 11, 12].contains(record.version) {
            guard record.nameRename == nil, record.downloadAdoption == nil,
                  (record.version == 1) == (record.persistentVolumes == nil),
                  (![9, 11, 12].contains(record.version) || record.operation == "Move to Trash"),
                  (record.version != 11 || record.areas.isEmpty && record.steps.count <= maximumTrashIntents
                      && record.steps.allSatisfy({ $0.before.identity.type == S_IFREG })),
                  (record.version != 12 || record.areas.isEmpty && record.steps.count <= maximumTrashIntents
                      && record.steps.allSatisfy({ [S_IFREG, S_IFDIR].contains($0.before.identity.type) })) else {
                throw FileOperationFailure.recoveryUncertain
            }
        } else if (record.version == 2 || record.version == 4), let rename = record.nameRename {
            guard record.downloadAdoption == nil, (record.version == 2) == (record.persistentVolumes == nil) else {
                throw FileOperationFailure.recoveryUncertain
            }
            guard record.operation == "Rename", record.steps.isEmpty, record.areas.isEmpty, record.trashIntents.isEmpty else {
                throw FileOperationFailure.recoveryUncertain
            }
            try rename.validate(state: record.state)
            if record.version == 4 {
                guard record.persistentVolumes?.binding(for: rename.volume.device)?.uuid == rename.volume.uuid else {
                    throw FileOperationFailure.recoveryUncertain
                }
            }
        } else if [5, 6, 13, 18, 19, 20].contains(record.version) {
            guard record.operation == ArchiveUpdateProfile.title(version: record.version), record.nameRename == nil, record.downloadAdoption == nil,
                  record.persistentVolumes != nil, record.areas.count <= 1,
                  record.steps.count <= ([13, 18, 19, 20].contains(record.version) ? 2 : 3),
                  record.trashIntents.count <= ([13, 18, 19, 20].contains(record.version) ? 0 : 1),
                  (![13, 18, 19, 20].contains(record.version) || !["cleanupReview", "cleaned"].contains(record.state)) else {
                throw FileOperationFailure.recoveryUncertain
            }
        } else if record.version == 14 {
            guard record.operation == "Download", record.nameRename == nil,
                  record.downloadAdoption == nil, record.persistentVolumes != nil,
                  record.areas.count <= 1, record.steps.count <= 1,
                  record.trashIntents.isEmpty,
                  record.steps.allSatisfy({ step in
                      step.before.osManagedSecurityV1 == true
                          && (step.after == nil || step.after?.osManagedSecurityV1 == true)
                          && step.before.identity.type == S_IFREG
                          && step.nativeTrashRootAddition == nil
                          && step.publicZIPExtractionMarkRequired == nil
                  }) else {
                throw FileOperationFailure.recoveryUncertain
            }
        } else if record.version == 15 {
            guard record.operation == "Extract ZIP", record.nameRename == nil,
                  record.downloadAdoption == nil, record.persistentVolumes != nil,
                  record.areas.count <= 1, record.steps.count <= 1,
                  record.trashIntents.isEmpty,
                  record.steps.allSatisfy({ step in
                      step.before.osManagedSecurityV1 == true
                          && (step.after == nil || step.after?.osManagedSecurityV1 == true)
                          && step.before.identity.type == S_IFREG
                          && step.publicZIPExtractionMarkRequired != nil
                          && step.nativeTrashRootAddition == nil
                  }) else { throw FileOperationFailure.recoveryUncertain }
        } else if record.version == 16 {
            guard let purpose = record.producedTreeV16,
                  record.operation == purpose.historyTitle, record.nameRename == nil,
                  record.downloadAdoption == nil, record.persistentVolumes != nil,
                  record.areas.count <= 1, record.steps.count <= 1,
                  record.trashIntents.isEmpty,
                  record.steps.allSatisfy({ step in
                      step.before.osManagedSecurityV1 == true && step.before.identity.isDirectory
                          && step.before.publicTreeQuarantineV16?.requiresEveryNode == purpose.requiresMarkOnEveryNode
                          && step.after.map({ $0.osManagedSecurityV1 == true
                              && $0.publicTreeQuarantineV16 == step.before.publicTreeQuarantineV16 }) ?? true
                          && step.nativeTrashRootAddition == nil
                          && step.publicZIPExtractionMarkRequired == nil
                  }) else { throw FileOperationFailure.recoveryUncertain }
        } else if record.version == 17 {
            guard record.operation == "Extract TAR", record.nameRename == nil,
                  record.downloadAdoption == nil, record.persistentVolumes != nil,
                  record.areas.count <= 1, record.steps.count <= 1,
                  record.trashIntents.isEmpty,
                  record.steps.allSatisfy({ step in
                      step.before.osManagedSecurityV1 == true
                          && (step.after == nil || step.after?.osManagedSecurityV1 == true)
                          && step.before.identity.type == S_IFREG
                          && step.publicTARExtractionMarkRequired != nil
                          && step.nativeTrashRootAddition == nil
                  }) else { throw FileOperationFailure.recoveryUncertain }
        } else if record.version == 7 {
            guard record.operation == "Download", record.nameRename == nil,
                  record.persistentVolumes != nil, record.areas.count <= 1,
                  record.steps.count <= 1, record.trashIntents.isEmpty,
                  (record.downloadAdoption != nil || ["preparing", "needsReview"].contains(record.state) && record.steps.isEmpty) else {
                throw FileOperationFailure.recoveryUncertain
            }
        } else if record.version == 8 || record.version == 10 {
            guard record.operation == "Move to Trash", record.nameRename == nil,
                  record.downloadAdoption == nil, record.areas.isEmpty,
                  record.persistentVolumes != nil,
                  ["trashDeleteReview", "trashDeleted"].contains(record.state),
                  record.ownedTrash?.undoInvalidated == true else {
                throw FileOperationFailure.recoveryUncertain
            }
        } else { throw FileOperationFailure.recoveryUncertain }
        if ![8, 10].contains(record.version) {
            guard !["trashDeleteReview", "trashDeleted"].contains(record.state),
                  record.steps.allSatisfy({ $0.ownedTrashDeletion == nil && $0.ownedTrashStageURL == nil }) else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
        guard record.steps.allSatisfy({ step in
            let requiresMarkWitness = record.version == 11
                || record.version == 12 && step.before.identity.type == S_IFREG
            let requiresDirectoryIdentity = record.version == 12 && step.before.identity.isDirectory
            return requiresMarkWitness == (step.nativeTrashMarkChanged != nil)
                && requiresDirectoryIdentity == (step.nativeTrashDirectoryDescendantIdentity != nil)
                && (step.nativeTrashDirectoryDescendantIdentity?.count ?? 32) == 32
                && (record.version == 15) == (step.publicZIPExtractionMarkRequired != nil)
                && (record.version == 17) == (step.publicTARExtractionMarkRequired != nil)
                && (record.version == 16) == (step.before.publicTreeQuarantineV16 != nil)
                && (record.version == 16
                    ? step.after == nil || step.after?.publicTreeQuarantineV16 != nil
                    : step.after?.publicTreeQuarantineV16 == nil)
        }) else {
            throw FileOperationFailure.recoveryUncertain
        }
        guard record.steps.enumerated().allSatisfy({ index, step in
            step.archiveOriginalRetainedQualified == nil ||
                ([13, 18, 19, 20].contains(record.version) && index == 0 && step.archiveOriginalRetainedQualified == true
                    && step.after != nil)
        }) else { throw FileOperationFailure.recoveryUncertain }
    }

    /// A record version is required because older readers ignore unknown JSON
    /// step keys. The witness remains bound to the original forward after-image
    /// even after Undo or review-only v10 staging records a later image there.
    static func validateTrashRootAddition(_ record: JournalRecord) throws {
        guard [9, 10, 12].contains(record.version) else {
            guard record.steps.allSatisfy({ $0.nativeTrashRootAddition == nil }) else {
                throw FileOperationFailure.recoveryUncertain
            }
            return
        }
        guard record.operation == "Move to Trash" else { throw FileOperationFailure.recoveryUncertain }
        for step in record.steps {
            if let proof = step.nativeTrashRootAddition {
                // A v10 deleteIntent may retain the separately verified actual
                // private-stage image before unlink. It is review evidence only:
                // no v10 history can authorize Undo or resume Delete on cold open.
                let stagedDeleteImage = record.version == 10 && step.ownedTrashStageURL != nil
                    && (step.ownedTrashDeletion == .deleteIntent
                        || step.ownedTrashDeletion == .uncertain
                        || step.ownedTrashDeletion == .deleteConfirmed)
                guard step.before.identity.isDirectory,
                      (record.version == 12
                        ? proof.validatesNativeDirectoryV12(before: step.before, after: proof.after)
                        : proof.validatesAdditiveRoot(before: step.before, after: proof.after)),
                      let after = step.after,
                      after.identity.sameObject(as: proof.after.identity),
                      (record.version != 12 || step.nativeTrashDirectoryDescendantIdentity == proof.afterDescendantIdentity),
                      step.undone || after == proof.after || stagedDeleteImage else {
                    throw FileOperationFailure.recoveryUncertain
                }
            } else if let after = step.after, !step.undone,
                      step.before.identity.isDirectory,
                      !step.before.matchesNativeTrashTransition(after) {
                throw FileOperationFailure.recoveryUncertain
            }
        }
    }

    static func validateDownloadAdoption(_ record: JournalRecord) throws {
        guard record.version == 7, record.operation == "Download", record.nameRename == nil,
              record.trashIntents.isEmpty, record.areas.count <= 1, record.steps.count <= 1 else {
            throw FileOperationFailure.recoveryUncertain
        }
        guard let adoption = record.downloadAdoption else {
            guard ["preparing", "needsReview"].contains(record.state), record.steps.isEmpty else { throw FileOperationFailure.recoveryUncertain }
            return
        }
        try adoption.validate()
        guard record.areas.count == 1, let area = record.areas.first,
              sameURLRepresentation(area.url, adoption.area), area.identity.sameObject(as: adoption.areaIdentity),
              record.locations.contains(where: { sameURLRepresentation($0, adoption.source) }),
              record.locations.contains(where: { sameURLRepresentation($0, adoption.destination) }) else {
            throw FileOperationFailure.recoveryUncertain
        }
        if let step = record.steps.first {
            guard adoption.adoptedStage != nil,
                  sameURLRepresentation(step.source, area.url.appendingPathComponent("payload")),
                  sameURLRepresentation(step.destination, adoption.destination),
                  step.sourceParent.sameObject(as: area.identity),
                  step.destinationParent.sameObject(as: adoption.destinationParent),
                  step.before.identity.sameObject(as: adoption.sourceIdentity),
                  step.before.matches(adoption.adoptedStage!) else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
        if record.state == "committed" || record.state == "undone" {
            guard record.steps.count == 1, record.steps[0].after != nil,
                  record.steps[0].undone == (record.state == "undone") else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
    }

    /// A v14 projection may guard only one newly received regular file from
    /// the owned private payload to the observed sibling destination.
    static func validateReceivedPublicDownload(_ record: JournalRecord) throws {
        guard record.version == 14, record.operation == "Download",
              record.areas.count <= 1, record.steps.count <= 1,
              record.trashIntents.isEmpty, record.nameRename == nil,
              record.downloadAdoption == nil else { throw FileOperationFailure.recoveryUncertain }
        if let step = record.steps.first {
            guard let area = record.areas.first,
                  sameURLRepresentation(step.source, area.url.appendingPathComponent("payload")),
                  sameURLRepresentation(step.destination.deletingLastPathComponent(),
                      area.url.deletingLastPathComponent()),
                  step.sourceParent.sameObject(as: area.identity),
                  step.before.identity.type == S_IFREG,
                  step.before.osManagedSecurityV1 == true,
                  step.after.map({ $0.osManagedSecurityV1 == true
                      && step.before.matches($0) }) ?? true else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
        if ["committed", "undone"].contains(record.state) {
            guard record.areas.count == 1, record.steps.count == 1,
                  record.steps[0].after != nil,
                  record.steps[0].undone == (record.state == "undone") else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
    }

    /// V15 binds only a selected ZIP regular file and its per-member public
    /// mark requirement. It is never a received Download or a directory tree.
    static func validatePublicZIPExtraction(_ record: JournalRecord) throws {
        guard record.version == 15, record.operation == "Extract ZIP",
              record.areas.count <= 1, record.steps.count <= 1,
              record.trashIntents.isEmpty, record.nameRename == nil,
              record.downloadAdoption == nil else { throw FileOperationFailure.recoveryUncertain }
        if let step = record.steps.first {
            guard let area = record.areas.first,
                  sameURLRepresentation(step.source, area.url.appendingPathComponent("payload")),
                  sameURLRepresentation(step.destination.deletingLastPathComponent(),
                      area.url.deletingLastPathComponent()),
                  step.sourceParent.sameObject(as: area.identity),
                  step.before.identity.type == S_IFREG,
                  step.publicZIPExtractionMarkRequired != nil,
                  step.before.osManagedSecurityV1 == true,
                  step.after.map({ $0.osManagedSecurityV1 == true
                      && step.before.matches($0) }) ?? true else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
        if ["committed", "undone"].contains(record.state) {
            guard record.areas.count == 1, record.steps.count == 1,
                  record.steps[0].after != nil,
                  record.steps[0].undone == (record.state == "undone") else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
    }

    /// V17 retains v15's one-file staging topology while binding a distinct
    /// TAR source/producer contract and mark witness. V15 stays ZIP-only.
    static func validatePublicTARExtraction(_ record: JournalRecord) throws {
        guard record.version == 17, record.operation == "Extract TAR",
              record.areas.count <= 1, record.steps.count <= 1,
              record.trashIntents.isEmpty, record.nameRename == nil,
              record.downloadAdoption == nil else { throw FileOperationFailure.recoveryUncertain }
        if let step = record.steps.first {
            guard let area = record.areas.first,
                  sameURLRepresentation(step.source, area.url.appendingPathComponent("payload")),
                  sameURLRepresentation(step.destination.deletingLastPathComponent(),
                      area.url.deletingLastPathComponent()),
                  step.sourceParent.sameObject(as: area.identity),
                  step.before.identity.type == S_IFREG,
                  step.publicTARExtractionMarkRequired != nil,
                  step.before.osManagedSecurityV1 == true,
                  step.after.map({ $0.osManagedSecurityV1 == true
                      && step.before.matches($0) }) ?? true else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
        if ["committed", "undone"].contains(record.state) {
            guard record.areas.count == 1, record.steps.count == 1,
                  record.steps[0].after != nil,
                  record.steps[0].undone == (record.state == "undone") else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
    }

    /// A v16 record uses one whole-tree namespace step. The typed purpose
    /// prevents a received folder from becoming ZIP recovery (or vice versa)
    /// through a display-title or older-record reinterpretation.
    static func validateProducedTreeV16(_ record: JournalRecord) throws {
        guard record.version == 16, let purpose = record.producedTreeV16,
              record.operation == purpose.historyTitle,
              record.areas.count <= 1, record.steps.count <= 1,
              record.trashIntents.isEmpty, record.nameRename == nil,
              record.downloadAdoption == nil else { throw FileOperationFailure.recoveryUncertain }
        if let step = record.steps.first {
            guard let area = record.areas.first,
                  sameURLRepresentation(step.source, area.url.appendingPathComponent("payload", isDirectory: true)),
                  sameURLRepresentation(step.destination.deletingLastPathComponent(),
                      area.url.deletingLastPathComponent()),
                  step.sourceParent.sameObject(as: area.identity),
                  step.before.identity.isDirectory, step.before.osManagedSecurityV1 == true,
                  let mark = step.before.publicTreeQuarantineV16,
                  mark.requiresEveryNode == purpose.requiresMarkOnEveryNode,
                  step.after.map({ $0.osManagedSecurityV1 == true && step.before.matches($0) }) ?? true else {
                throw FileOperationFailure.recoveryUncertain
            }
            try mark.validateRepresentation()
            if let later = step.after?.publicTreeQuarantineV16 { try later.validateRepresentation() }
        }
        if ["committed", "undone"].contains(record.state) {
            guard record.areas.count == 1, record.steps.count == 1,
                  record.steps[0].after != nil,
                  record.steps[0].undone == (record.state == "undone") else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
    }

    /// Archive versions close the two rename topology. A display title alone must
    /// never turn an arbitrary tree job into an archive replacement or cleanup.
    static func validateArchiveUpdate(_ record: JournalRecord) throws {
        guard [5, 6, 13, 18, 19, 20].contains(record.version), record.operation == ArchiveUpdateProfile.title(version: record.version),
              record.areas.count <= 1,
              record.steps.count <= ([13, 18, 19, 20].contains(record.version) ? 2 : 3),
              record.trashIntents.count <= ([13, 18, 19, 20].contains(record.version) ? 0 : 1),
              (![13, 18, 19, 20].contains(record.version) || !["cleanupReview", "cleaned"].contains(record.state)) else {
            throw FileOperationFailure.recoveryUncertain
        }
        let steps = record.steps
        let area = record.areas.first
        if let area {
            let prefix = ".mac-explorer-recovery-"
            guard area.identity.type == S_IFDIR,
                  area.url.lastPathComponent.hasPrefix(prefix),
                  UUID(uuidString: String(area.url.lastPathComponent.dropFirst(prefix.count))) != nil else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
        let hasCleanupStep = record.trashIntents.count == 1 && area != nil
            && steps.last.map { sameURLRepresentation($0.source, area!.url) } == true
        let forward = Array(steps.prefix(steps.count - (hasCleanupStep ? 1 : 0)))
        guard forward.count <= 2, steps.count <= forward.count + 1 else {
            throw FileOperationFailure.recoveryUncertain
        }
        if !forward.isEmpty {
            guard let area,
                  ArchiveUpdateProfile.acceptsSource(forward[0].source, version: record.version),
                  sameURLRepresentation(forward[0].destination, area.url.appendingPathComponent("displaced")),
                  sameURLRepresentation(forward[0].source.deletingLastPathComponent(), area.url.deletingLastPathComponent()),
                  forward[0].before.identity.type == S_IFREG,
                  forward[0].destinationParent.sameObject(as: area.identity) else {
                throw FileOperationFailure.recoveryUncertain
            }
            if forward.count == 2 {
                guard sameURLRepresentation(forward[1].source, area.url.appendingPathComponent("payload")),
                      sameURLRepresentation(forward[1].destination, forward[0].source),
                      forward[1].before.identity.type == S_IFREG,
                      forward[1].sourceParent.sameObject(as: area.identity),
                      forward[1].destinationParent.sameObject(as: forward[0].sourceParent) else {
                    throw FileOperationFailure.recoveryUncertain
                }
            }
            if hasCleanupStep {
                guard ["cleanupReview", "cleaned"].contains(record.state),
                      steps.last?.before.identity.type == S_IFDIR,
                      steps.last?.before.identity.sameObject(as: area.identity) == true,
                      steps.last?.sourceParent.sameObject(as: forward[0].sourceParent) == true else {
                    throw FileOperationFailure.recoveryUncertain
                }
            }
        }
        if let intent = record.trashIntents.first {
            guard let area,
                  ["cleanupReview", "cleaned"].contains(record.state),
                  sameURLRepresentation(intent.source, area.url), !forward.isEmpty,
                  intent.before.identity.sameObject(as: area.identity),
                  intent.sourceParent.sameObject(as: forward[0].sourceParent) else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
        if ["cleanupReview", "cleaned"].contains(record.state) {
            let committed = forward.count == 2 && forward.allSatisfy({ $0.after != nil && !$0.undone })
            let undone = (1...2).contains(forward.count) && forward.first?.after != nil
                && forward.allSatisfy({ $0.undone })
            guard committed || undone else { throw FileOperationFailure.recoveryUncertain }
        }
        if record.state == "preparing" && !forward.isEmpty {
            throw FileOperationFailure.recoveryUncertain
        }
        if record.state == "committed" {
            guard forward.count == 2, record.areas.count == 1, record.trashIntents.isEmpty,
                  forward.allSatisfy({ $0.after != nil && !$0.undone }) else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
        if record.state == "undone" {
            guard (1...2).contains(forward.count), record.areas.count == 1, record.trashIntents.isEmpty,
                  forward.allSatisfy({ $0.undone }), forward.first?.after != nil else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
        if record.state == "cleaned" {
            guard hasCleanupStep, record.trashIntents.count == 1,
                  steps.last?.after != nil else { throw FileOperationFailure.recoveryUncertain }
        }
    }

    /// A native archive first rename is recoverable only after its complete after-image
    /// was saved and before any replacement intent exists. File observations
    /// and conflicts are checked again by the explicit restore action.
    static func hasRecordedNativeZIPOriginalOnly(_ record: JournalRecord) -> Bool {
        record.version == 13 && hasRecordedNativeArchiveOriginalOnly(record)
    }

    static func hasRecordedNativeArchiveOriginalOnly(_ record: JournalRecord) -> Bool {
        guard [13, 18, 19, 20].contains(record.version), record.operation == ArchiveUpdateProfile.title(version: record.version),
              ["mutating", "needsReview"].contains(record.state),
              record.steps.count == 1, record.areas.count == 1,
              record.trashIntents.isEmpty else { return false }
        let step = record.steps[0], area = record.areas[0]
        guard let after = step.after, !step.undone,
              step.archiveOriginalRetainedQualified == true,
              step.before.identity.type == S_IFREG,
              step.before.identity.sameObject(as: after.identity),
              step.before.identity.size == after.identity.size,
              sameURLRepresentation(step.destination, area.url.appendingPathComponent("displaced")),
              sameURLRepresentation(step.source.deletingLastPathComponent(), area.url.deletingLastPathComponent()) else {
            return false
        }
        return true
    }

    static func validateStep(_ step: JournalStep) throws {
        guard safe(step.source), safe(step.destination) else { throw FileOperationFailure.recoveryUncertain }
    }

    static func validateArea(_ area: JournalArea, stepCount: Int) throws {
        try validateLocation(area.url)
        if let proof = area.stagingProof { try proof.validate(area: area, stepCount: stepCount) }
    }

    static func validateLocation(_ url: URL) throws {
        guard safe(url) else { throw FileOperationFailure.recoveryUncertain }
    }

    static func validateTrashIntent(_ intent: JournalTrashIntent) throws {
        try validateLocation(intent.source)
    }

    /// Foundation URL equality may canonicalize distinct representations. A row can
    /// reuse validation only when its URL spelling and base representation also match.
    static func sameURLRepresentation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs == rhs && lhs.absoluteString == rhs.absoluteString &&
        lhs.relativeString == rhs.relativeString && lhs.baseURL?.absoluteString == rhs.baseURL?.absoluteString
    }

    private struct LegacyGroup {
        var count = 0
        var minimum = Int.max
        var maximum = -1
        var prefix: String
        var invalid = false
        var latestName: String = ""
    }

    private func importLegacy() throws {
        if didImport { return }
        if store?.inspectedCatalogVersion == 10 { didImport = true; return }
        refused = []; refusedIDs = []; refusedDirectory = false
        let known = Set([".mac-explorer-journal-v1", ".mac-explorer-sqlite-v2", ".mac-explorer-sqlite-ready-v2",
                         SQLiteJournalStore.name, SQLiteJournalStore.name + "-journal"])
        var groups: [UUID: LegacyGroup] = [:]
        // Stream directory entries. Memory is bounded by jobs, not historical revisions;
        // the former 8,192-revision directory limit no longer blocks recovery.
        try eachName { name in
            if known.contains(name) { return }
            let prefix = String(name.prefix(36))
            let digits = String(name.dropFirst(37).dropLast(5))
            guard name.utf8.count == 48, name.hasSuffix(".json"), let id = UUID(uuidString: prefix),
                  name[name.index(name.startIndex, offsetBy: 36)] == "-", digits.count == 6,
                  digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let revision = Int(digits) else {
                appendRefusal(anchor.url.appendingPathComponent(name)); return
            }
            guard groups[id] != nil || groups.count < 10_000 else { throw FileOperationFailure.unsupported }
            var group = groups[id] ?? LegacyGroup(prefix: prefix)
            group.invalid = group.invalid || group.prefix != prefix
            group.count += 1; group.minimum = min(group.minimum, revision)
            if revision > group.maximum { group.maximum = revision; group.latestName = name }
            groups[id] = group
        }
        guard let store, storageRefusal == nil else { didImport = true; return }
        let imported = try store.legacyImports()
        for (id, group) in groups.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            do {
                guard !group.invalid, group.minimum == 0, group.count == group.maximum + 1 else {
                    throw FileOperationFailure.recoveryUncertain
                }
                var digest = SHA256()
                var latest: JournalRecord?
                for revision in 0...group.maximum {
                    try cancellation.check()
                    let name = "\(group.prefix)-\(String(format: "%06d", revision)).json"
                    let data = try Self.read(name: name, anchor: anchor)
                    let record = try JSONDecoder().decode(JournalRecord.self, from: data)
                    guard record.version == 1 else { throw FileOperationFailure.recoveryUncertain }
                    try Self.validate(record)
                    guard record.steps.count <= 512, record.areas.count <= 512, record.locations.count <= 1024,
                          record.trashIntents.count <= 256 else { throw FileOperationFailure.recoveryUncertain }
                    guard record.owner == owner, record.id == id, record.revision == revision else { throw FileOperationFailure.recoveryUncertain }
                    digest.update(data: Data(name.utf8)); digest.update(data: Data(SHA256.hash(data: data)))
                    latest = record
                }
                let fingerprint = digest.finalize().map { String(format: "%02x", $0) }.joined()
                if let old = imported[id.uuidString] {
                    guard old.revision == group.maximum, old.digest == fingerprint, old.name == group.latestName else {
                        throw FileOperationFailure.recoveryUncertain
                    }
                } else {
                    // A selection attempt uses an already admitted catalog;
                    // unexpected new archives are refused, never imported here.
                    guard selectionHistory == nil, let latest else { throw FileOperationFailure.recoveryUncertain }
                    try store.saveSnapshot(latest, imported: true, migration: (fingerprint, group.latestName))
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                refusedIDs.insert(id); appendRefusal(anchor.url.appendingPathComponent(group.latestName))
            }
        }
        // Missing preserved evidence is not permission to reuse imported state.
        for (id, evidence) in imported where UUID(uuidString: id).map({ groups[$0] == nil }) ?? true {
            if let id = UUID(uuidString: id) { refusedIDs.insert(id) }
            appendRefusal(anchor.url.appendingPathComponent(evidence.name))
        }
        didImport = true
    }

    /// Beyond 128 individual diagnostics, refuse the containing directory as a whole.
    /// This reports incomplete diagnostic coverage without retaining unbounded paths.
    private func appendRefusal(_ url: URL) {
        guard !refusedDirectory else { return }
        if refused.count < 128 { refused.append(url) }
        else { refused = [anchor.url]; refusedDirectory = true }
    }

    func durabilityConfiguration() throws -> (synchronous: Int64, fullFSync: Int64) {
        try validateWritableCatalog()
        guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.durabilityConfiguration()
    }

    private func eachName(_ body: (String) throws -> Void) throws {
        let fd = openat(anchor.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }
        guard let directory = fdopendir(fd) else { close(fd); throw posixFailure() }
        defer { closedir(directory) }
        while true {
            try cancellation.check()
            errno = 0
            guard let entry = readdir(directory) else { guard errno == 0 else { throw posixFailure() }; break }
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw FileOperationFailure.unsupported }
            if name != "." && name != ".." { try body(name) }
        }
    }

    private static func safe(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && url.path != "/" &&
            (url.host == nil || url.host == "" || url.host == "localhost") &&
            !url.pathComponents.contains("..") && !url.pathComponents.contains(".")
    }

    internal static func read(name: String, anchor: DirectoryAnchor) throws -> Data {
        let fd = openat(anchor.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1,
              value.st_uid == geteuid(), value.st_mode & 0o077 == 0,
              value.st_size >= 0, value.st_size <= maximumBytes else { throw FileOperationFailure.recoveryUncertain }
        let before = try EntrySnapshot(fd: fd)
        var data = Data(count: Int(value.st_size))
        let received = data.withUnsafeMutableBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let amount = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if amount < 0 && errno == EINTR { continue }
                if amount <= 0 { return -1 }
                offset += amount
            }
            return offset
        }
        guard received == data.count, try EntrySnapshot(fd: fd) == before,
              try EntrySnapshot(parent: anchor.fd, name: name) == before else { throw FileOperationFailure.recoveryUncertain }
        return data
    }

    internal static func writeExclusive(_ data: Data, name: String, anchor: DirectoryAnchor) throws {
        let temporary = ".pending-" + UUID().uuidString
        let fd = openat(anchor.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixFailure() }
        defer { close(fd) }
        let identity = try EntrySnapshot(fd: fd)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let amount = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw posixFailure() }
                offset += amount
            }
        }
        guard fsync(fd) == 0 else { throw posixFailure() }
        try anchor.validate()
        guard try EntrySnapshot(parent: anchor.fd, name: temporary).sameObject(as: identity) else { throw FileOperationFailure.recoveryUncertain }
        try exclusiveRename(from: anchor.fd, name: temporary, to: anchor.fd, name: name)
        try syncDirectory(anchor)
    }
}

extension OperationJournal {
    func upgradeForSelectionGroup(backup: URL) throws {
        try validateWritableCatalog()
        guard refused.isEmpty, let current = store else { throw FileOperationFailure.recoveryUncertain }
        do {
            let identity = current.fileIdentity
            try current.upgradeForSelectionGroup(backup: backup, cancellation: cancellation)
            store = nil
            let fresh = try SQLiteJournalStore(anchor: anchor, owner: owner, hooks: hooks, cancellation: cancellation, expectedIdentity: identity)
            try fresh.validateCatalog(cancellation: cancellation); store = fresh
        } catch {
            store = nil; storageFailure = error; storageRefusal = anchor.url.appendingPathComponent(SQLiteJournalStore.name); throw error
        }
    }
    func selectionGroup(_ id: UUID) throws -> SelectionGroupRecord {
        try validateSelectionOwnership()
        try validateWritableCatalog()
        guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.loadSelectionGroup(id.uuidString)
    }
    func beginSelectionGroup(_ manifest: SelectionGroupManifest) throws -> SelectionGroupRecord {
        try selectionWrite { try $0.beginSelectionGroup(manifest) }
    }
    func appendSelectionGroup(_ record: SelectionGroupRecord, _ event: SelectionGroupEvent) throws -> SelectionGroupRecord {
        try selectionWrite { try $0.appendSelectionGroup(record, event) }
    }
    private func selectionWrite(_ action: (SQLiteJournalStore) throws -> SelectionGroupRecord) throws -> SelectionGroupRecord {
        try validateSelectionOwnership()
        // Intent callers check Stop before entering. Once a native edge begins,
        // its authoritative write drains even if the planning token is cancelled.
        try importLegacy()
        if let storageFailure { throw storageFailure }
        guard storageRefusal == nil, let current = store else { throw FileOperationFailure.recoveryUncertain }
        try current.validateWriteCatalog(cancellation: cancellation.draining())
        do { return try action(current) }
        catch {
            // No in-memory record survives any failed or unknown acknowledgement.
            // A subsequent action must reopen and inspect authoritative storage.
            store = nil; storageFailure = error; storageRefusal = anchor.url.appendingPathComponent(SQLiteJournalStore.name); throw error
        }
    }
}

extension OperationJournal {
    /// Recheck the actual owner-lock descriptor, never just the remembered owner
    /// bytes. This is a boundary check, not a lock over unrelated filesystem writers.
    func validateSelectionOwnership() throws {
        if let storageFailure { throw storageFailure }
        guard storageRefusal == nil, let store else { throw FileOperationFailure.recoveryUncertain }
        try anchor.validate(); try store.validateFiles()
        if let selectionHistory {
            try selectionHistory.validateOpened(anchor: anchor, markerFD: lockFD, owner: owner, database: store.fileIdentity)
        } else {
            // Typed retention is entered through the ordinary journal dispatcher.
            guard lockFD >= 0,
                  try EntrySnapshot(fd: lockFD) == EntrySnapshot(parent: anchor.fd, name: ".mac-explorer-journal-v1"),
                  try Self.read(name: ".mac-explorer-journal-v1", anchor: anchor) == Data(owner.uuidString.utf8) else {
                throw FileOperationFailure.sourceChanged
            }
        }
    }
    func reserveSelectionCapacity(_ record: SelectionGroupRecord) throws {
        try validateSelectionOwnership()
        try validateWritableCatalog()
        guard let store else { throw FileOperationFailure.recoveryUncertain }
        try store.reserveSelectionCapacity(record)
    }
}

// Appended to the copied OperationJournal.swift to share its private state.
extension OperationJournal {
    func upgradeForTextV2(backup: URL) throws {
        try validateWritableCatalog(); guard refused.isEmpty, let current = store else { throw FileOperationFailure.recoveryUncertain }
        do {
            let identity = current.fileIdentity
            try current.upgradeForTextV2(backup: backup, cancellation: cancellation)
            store = nil
            let fresh = try SQLiteJournalStore(anchor: anchor, owner: owner, hooks: hooks, cancellation: cancellation, expectedIdentity: identity)
            try fresh.validateCatalog(cancellation: cancellation); store = fresh
        } catch { store = nil; storageFailure = error; storageRefusal = anchor.url.appendingPathComponent(SQLiteJournalStore.name); throw error }
    }
    func textHeadV2(slot: RevisionDigest, allowing job: UUID? = nil) throws -> TextRevisionHeadV2? {
        try validateWritableCatalog(); guard let store else { throw FileOperationFailure.recoveryUncertain }; return try store.textHeadV2(slot: slot, allowing: job)
    }
    func textRecordV2(_ id: UUID) throws -> TextRevisionRecordV2 {
        try validateWritableCatalog(); guard let store else { throw FileOperationFailure.recoveryUncertain }; return try store.textRecordV2(id)
    }
    func textSavePlanningV3(slot: RevisionDigest) throws -> TextPlanning10 {
        try validateWritableCatalog(); guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.textSavePlanningV3(slot: slot)
    }
    func textSelectedSlotV4(target: URL, parent: EntrySnapshot, witness: RevisionWitness) throws -> TextSlotSelectionV4 {
        try validateWritableCatalog(); guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.textSelectedSlotV4(target: target, parent: parent, witness: witness)
    }
    func reserveTextV2(slot:RevisionDigest,newJob: Bool = true,edges:Int = 1) throws {
        try validateWritableCatalog(); guard let store else { throw FileOperationFailure.recoveryUncertain }; try store.reserveTextV2(slot:slot,newJob:newJob,edges:edges)
    }
    func beginTextV2(_ manifest: TextRevisionManifestV2) throws -> TextRevisionRecordV2 { try textWriteV2 { try $0.beginTextV2(manifest) } }
    func appendTextV2(_ old: TextRevisionRecordV2, event: TextRevisionEventV2, transition: TextRevisionTransitionV2? = nil) throws -> TextRevisionRecordV2 {
        try textWriteV2 { try $0.appendTextV2(old, event: event, transition: transition) }
    }
    func textExportsV2(_ id: UUID) throws -> [TextRecoveryExportV2] {
        try validateWritableCatalog(); guard let store else { throw FileOperationFailure.recoveryUncertain }; return try store.textExportsV2(id)
    }
    func writeTextExportV2(_ value: TextRecoveryExportV2, replacing old: TextRecoveryExportV2?) throws { try textWriteV2 { try $0.writeTextExportV2(value, replacing: old) } }
    private func textWriteV2<T>(_ action: (SQLiteJournalStore) throws -> T) throws -> T {
        try validateSelectionOwnership()
        try validateWritableCatalog(); guard let current = store else { throw FileOperationFailure.recoveryUncertain }
        do { return try action(current) }
        catch {
            store = nil; storageFailure = error; storageRefusal = anchor.url.appendingPathComponent(SQLiteJournalStore.name)
            // Discard failed memory, then reopen the exact catalog under the
            // existing OS writer lease. The original action still throws: a
            // fresh, acknowledged abort is required for pre-intent settlement.
            do {
                try anchor.validate()
                guard lockFD >= 0,
                      try EntrySnapshot(fd: lockFD) == EntrySnapshot(parent: anchor.fd, name: ".mac-explorer-journal-v1"),
                      try Self.read(name: ".mac-explorer-journal-v1", anchor: anchor) == Data(owner.uuidString.utf8) else {
                    throw FileOperationFailure.sourceChanged
                }
                let fresh = try SQLiteJournalStore(anchor: anchor, owner: owner, hooks: hooks,
                    cancellation: cancellation.draining(), expectedIdentity: current.fileIdentity)
                try fresh.validateWriteCatalog(cancellation: cancellation.draining())
                try fresh.validateFiles(); try anchor.validate()
                store = fresh; storageFailure = nil; storageRefusal = nil
            } catch { /* Unproved reconciliation keeps the original refusal. */ }
            throw error
        }
    }
}

// Appended to the existing OperationJournal.swift; its OS lease is retained.
extension OperationJournal {
    func textStamp10(slot:RevisionDigest) throws -> TextEpochStamp10? {
        try validateWritableCatalog();guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.textStamp10(slot:slot)
    }
    func textUndoDisposition10(_ id:UUID) throws -> LocalTextUndoDisposition {
        try validateWritableCatalog();guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.textUndoDisposition10(id)
    }
    func textNextExportOrdinal10(_ id:UUID) throws -> Int {
        try validateWritableCatalog();guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.textNextExportOrdinal10(id)
    }
    func textExport10(_ id:UUID,ordinal:Int) throws -> TextRecoveryExportV2? {
        try validateWritableCatalog();guard let store else {throw FileOperationFailure.recoveryUncertain}
        return try store.textExportsV2(id,after:ordinal-1,limit:1).first
    }
    func abortTextExportBeforeNative10(_ value:TextRecoveryExportV2) throws {
        try textWriteV2 {try $0.abortTextExportBeforeNative10(value)}
    }
    func performCheckpoint10(_ plan:LocalTextCheckpointPlan,mutationEntry:() -> Void,validateSource:() throws -> Void) throws -> TextCheckpoint10 {
        try textWriteV2 {try $0.performCheckpoint10(plan,mutationEntry:mutationEntry,validateSource:validateSource)}
    }
    func checkpoint10(_ id:UUID) throws -> TextCheckpoint10? {
        try validateWritableCatalog();guard let store else { throw FileOperationFailure.recoveryUncertain }
        return try store.checkpoint10(id)
    }
    func confirmCheckpoint10(_ value:TextCheckpoint10) throws -> TextCheckpoint10 {
        try validateWritableCatalog();guard let store else {throw FileOperationFailure.recoveryUncertain}
        return try store.confirmCheckpoint10(value)
    }
    func upgradeForEpoch10(backup:URL) throws {
        try validateWritableCatalog();guard refused.isEmpty,let current = store else { throw FileOperationFailure.recoveryUncertain }
        let identity = current.fileIdentity
        do {
            try current.upgradeForEpoch10(backup:backup,cancellation:cancellation)
            store = nil
            let fresh = try SQLiteJournalStore(anchor:anchor,owner:owner,hooks:hooks,cancellation:cancellation,expectedIdentity:identity)
            try fresh.validateCatalog(cancellation:cancellation);store = fresh
        } catch { store = nil;storageFailure = error;storageRefusal = anchor.url.appendingPathComponent(SQLiteJournalStore.name);throw error }
    }
}
