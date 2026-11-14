import Darwin
import Foundation

/// Owns the actual common pool lock and one fresh revision-checked ledger
/// transaction. No persistent ledger writer, async callback or UI executor.
final class SFTPSharedBudgetTransaction {
    typealias File = RemoteSettingsFile<SFTPSharedBudgetDocument>
    static let metadataFence = "shared-original-budget-v1.fence"
    static let bodyFence = "shared-original-body-v1.fence"
    let layout: SFTPSharedBudgetLayout, pool: Int32, guardFD: Int32
    let file: File
    private var workspaceLease: ConnectionWorkspaceRecordLease?
    private var ownsPool: Bool
    private var closed = false
    var document: SFTPSharedBudgetDocument { file.snapshot }
    private init(layout: SFTPSharedBudgetLayout, pool: Int32, guardFD: Int32, file: File, ownsPool: Bool) {
        self.layout = layout; self.pool = pool; self.guardFD = guardFD; self.file = file; self.ownsPool = ownsPool
    }
    deinit { close() }
    func close() {
        guard !closed else { return }; closed = true; file.close()
        if ownsPool { Darwin.close(guardFD); Darwin.close(pool) }
        workspaceLease?.close(); workspaceLease = nil
    }
    static func open(layout: SFTPSharedBudgetLayout, writing: Bool, retirementAccess: SFTPRetainedMetadataAccess? = nil) throws -> SFTPSharedBudgetTransaction {
        guard !Thread.isMainThread else { throw SFTPSharedBudgetFailure.busy }
        let workspace = try layout.storage.beginWorkspaceTransaction()
        var workspaceTransferred = false
        defer { if !workspaceTransferred { workspace?.close() } }
        guard let pool = try SMBCatalogFiles.openPool(layout.metadata, create: false) else { throw SFTPSharedBudgetFailure.recoveryRequired }
        var guardFD: Int32 = -1, keep = false
        defer { if !keep { if guardFD >= 0 { Darwin.close(guardFD) }; Darwin.close(pool) } }
        guardFD = try SMBCatalogFiles.lockPool(pool, create: false)
        try workspace?.validateCurrent()
        let value = try existing(layout: layout, pool: pool, guardFD: guardFD, writing: writing, ownsPool: true, retirementAccess: retirementAccess)
        value.workspaceLease = workspace; workspaceTransferred = true
        keep = true; return value
    }
    /// An explicit Connect may retire only drained temporary Original catalog
    /// directories. The body pool, editor catalog and Save journal remain
    /// untouched. Once the exact old graph is clean and inactive, the same
    /// writer transaction fences older binaries with format 3.
    static func prepareForConnect(layout: SFTPSharedBudgetLayout) throws {
        try layout.storage.requireDurableOriginalAdmission()
        let transaction = try open(layout: layout, writing: true)
        defer { transaction.close() }
        let before = transaction.document
        guard before.poolPhase == .active, (before.retirements ?? []).isEmpty,
              before.metadata.allSatisfy({ $0.phase == .live || $0.phase == .removed }),
              before.bodies.allSatisfy({ $0.phase != .removalPending }) else {
            throw SFTPSharedBudgetFailure.recoveryRequired
        }
        var coldEditors: RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>?
        var coldJournal: RemoteSettingsFile<SFTPInPlaceJournalDocument>?
        defer { coldJournal?.close(); coldEditors?.close() }
        if before.bodies.contains(where: { $0.phase == .allocating }) {
            // Keep exact editor/journal read owners through the ledger upgrade.
            // Recognition leaves interrupted bytes and their charge untouched.
            coldEditors = try RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>.open(layout.editors, writing: false)
            coldJournal = try RemoteSettingsFile<SFTPInPlaceJournalDocument>.open(layout.journal, writing: false)
            guard let coldEditors, let coldJournal else { throw SFTPSharedBudgetFailure.recoveryRequired }
            _ = try SFTPIncompleteReceiveDiscovery.inspect(transaction: transaction,
                editors: coldEditors.snapshot, journal: coldJournal.snapshot)
        }
        let records = try records(transaction.pool)
        let expected = Set(before.metadata.filter { $0.phase == .live }.map(\.id))
        guard Set(records.map(\.summary.id)) == expected, records.count == expected.count else {
            throw SFTPSharedBudgetFailure.recoveryRequired
        }
        let oldFormat = before.format != 3
        if oldFormat {
            guard records.allSatisfy({ !$0.summary.active && $0.files["catalog.sqlite-journal"] == nil }) else {
                throw SFTPSharedBudgetFailure.busy
            }
        }
        let activeBodyOwners: Set<UUID> = try {
            guard let bodyPool = try SMBCatalogFiles.openPool(layout.bodies, create: false) else {
                throw SFTPSharedBudgetFailure.recoveryRequired
            }
            defer { Darwin.close(bodyPool) }
            let bodyLock = try SMBCatalogFiles.lockPool(bodyPool, create: false)
            defer { Darwin.close(bodyLock) }
            guard let budgetID = before.budgetID,
                  try readFence(bodyPool, name: bodyFence, prefix: "MEXSHAREDBODY1") == budgetID else {
                throw SFTPSharedBudgetFailure.recoveryRequired
            }
            let bodies = try SFTPRetainedBodyRemoval.inventory(pool: bodyPool, document: before)
            if oldFormat && bodies.contains(where: { $0.summary.active }) { throw SFTPSharedBudgetFailure.busy }
            return Set(bodies.filter { $0.summary.active }.compactMap { body in
                before.bodies.first(where: { $0.id == body.summary.id })?.owner
            })
        }()
        for record in records where before.metadata.contains(where: { $0.id == record.summary.id && $0.kind == .original }) {
            let id = record.summary.id
            guard !record.summary.active, record.files["catalog.sqlite-journal"] == nil,
                  !activeBodyOwners.contains(id) else {
                if oldFormat { throw SFTPSharedBudgetFailure.busy }
                continue
            }
            try Task.checkCancellation()
            try transaction.metadataRemovalIntent(id)
            try SMBCatalogFiles.remove(pool: transaction.pool, record: record)
            try transaction.metadataRemoved(id)
        }
        if oldFormat {
            try Task.checkCancellation()
            try coldEditors?.validateCurrent(); try coldJournal?.validateCurrent()
            var expanded = transaction.document
            expanded.format = 3
            expanded.retirements = []
            try transaction.commit(expanded)
        }
        try coldEditors?.validateCurrent(); try coldJournal?.validateCurrent()
    }
    static func existing(layout: SFTPSharedBudgetLayout, pool: Int32, guardFD: Int32,
                         writing: Bool, ownsPool: Bool = false, retirementAccess: SFTPRetainedMetadataAccess? = nil) throws -> SFTPSharedBudgetTransaction {
        try SMBCatalogFiles.validatePool(pool, at: layout.metadata)
        let budgetID = try readFence(pool, name: metadataFence, prefix: "MEXSHAREDMETA1")
        // A fence with missing/partial/corrupt ledger is a refusal, never an
        // empty writable document or automatic migration continuation.
        guard let ledgerFD = try SMBCatalogFiles.openPool(layout.ledger, create: false) else { throw SFTPSharedBudgetFailure.recoveryRequired }
        Darwin.close(ledgerFD)
        #if DEBUG
        let retirementProbe: File.Probe?
        if retirementAccess == .explicitResume {
            retirementProbe = { stage in try SFTPRetainedRemovalQualification.shared.metadata("ledger", stage.rawValue) }
        } else { retirementProbe = nil }
        #else
        let retirementProbe: File.Probe? = nil
        #endif
        guard let file = try File.open(layout.ledger, writing: writing, probe: retirementProbe,
            retainedRetirement: retirementAccess.map { $0 == .explicitResume ? .resumeCommittedLedger : .inspectCommittedLedger }) else { throw SFTPSharedBudgetFailure.recoveryRequired }
        do {
            try file.validateCurrent(); try file.snapshot.validate()
            guard file.snapshot.budgetID == budgetID, file.snapshot.poolPhase == .active else { throw SFTPSharedBudgetFailure.recoveryRequired }
            let transaction = SFTPSharedBudgetTransaction(layout: layout, pool: pool, guardFD: guardFD, file: file, ownsPool: false)
            try transaction.validateInventory()
            // open() retains descriptor cleanup responsibility until every
            // validation passes; an error must never close its fds twice.
            transaction.ownsPool = ownsPool; return transaction
        } catch { file.close(); throw error }
    }
    static func hasFence(_ pool: Int32) throws -> Bool {
        var facts = stat()
        if fstatat(pool, metadataFence, &facts, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw SFTPSharedBudgetFailure.unsafe }; return false
    }
    static func records(_ pool: Int32) throws -> [SMBCatalogFiles.Record] {
        try DownloadDisk.names(pool, maximum: 66).filter { $0 != "pool.lock" && $0 != metadataFence }
            .map { try SMBCatalogFiles.record(pool, name: $0) }
    }
    /// All post-fence ordinary and Original metadata admission uses this path.
    /// Before a fence exists, ordinary modes retain their frozen legacy path;
    /// Original creation performs the whole fence+ledger migration under lock.
    static func reserveMetadata(layout: SFTPSharedBudgetLayout, pool: Int32, guardFD: Int32,
        id: UUID, purpose: SFTPSharedMetadataPurpose) throws -> SFTPSharedMetadataCreation? {
        guard !Thread.isMainThread else { throw SFTPSharedBudgetFailure.busy }
        if case .originalPending = purpose { try layout.storage.requireDurableOriginalAdmission() }
        let transaction: SFTPSharedBudgetTransaction
        if try hasFence(pool) {
            transaction = try existing(layout: layout, pool: pool, guardFD: guardFD, writing: true)
            do { try transaction.addMetadata(id: id, purpose: purpose) }
            catch { transaction.close(); throw error }
        } else {
            guard case .originalPending = purpose else { return nil }
            transaction = try migrate(layout: layout, pool: pool, guardFD: guardFD, id: id, purpose: purpose)
        }
        guard let record = transaction.document.metadata.first(where: { $0.id == id }) else {
            transaction.close(); throw SFTPSharedBudgetFailure.unsafe
        }
        return .init(transaction: transaction, id: id, writerQuota: record.quota)
    }
    private static func migrate(layout: SFTPSharedBudgetLayout, pool: Int32, guardFD: Int32,
                                id: UUID, purpose: SFTPSharedMetadataPurpose) throws -> SFTPSharedBudgetTransaction {
        try SMBCatalogFiles.validatePool(pool, at: layout.metadata)
        try validateMetadataFootprint(layout)
        var filesystem = statfs()
        guard fstatfs(pool, &filesystem) == 0 else { throw SFTPSharedBudgetFailure.unsafe }
        let type = withUnsafePointer(to: &filesystem.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
        guard type == "apfs" else { throw SFTPSharedBudgetFailure.unsafe }
        let legacy = try SMBCatalogFiles.legacyInventory(pool)
        if let existing = try SMBCatalogFiles.openPool(layout.ledger, create: false) {
            Darwin.close(existing); throw SFTPSharedBudgetFailure.recoveryRequired
        }
        var value = SFTPSharedBudgetDocument(); value.budgetID = UUID(); value.revision = 1
        value.metadata = legacy.map { .init(id: $0.summary.id, kind: .legacy, session: nil,
            quota: SFTPSharedBudgetDocument.ownerBytes, context: nil, phase: .orphan) }
        // Pre-existing old Original bodies cannot be adopted as new authority.
        var orphanCharges: [UUID: UInt64] = [:]
        if let bodyPool = try SMBCatalogFiles.openPool(layout.bodies, create: false) {
            defer { Darwin.close(bodyPool) }
            let bodyLock = try SMBCatalogFiles.lockPool(bodyPool, create: false); defer { Darwin.close(bodyLock) }
            for record in try DownloadDisk.inventory(bodyPool) {
                guard !record.summary.isFolder, record.summary.expectedBytes <= 1 << 20,
                      value.bodies.count < 8 else { throw SFTPSharedBudgetFailure.capacity }
                value.bodies.append(.init(id: record.summary.id, owner: nil, expectedBytes: record.summary.expectedBytes,
                    reservedBytes: record.reservedBytes, phase: .allocated))
                orphanCharges[record.summary.id] = max(record.summary.observedBytes, record.reservedBytes)
            }
        }
        value.metadata.append(try metadataRecord(id: id, purpose: purpose, storage: layout.storage))
        _ = try SFTPSharedBudgetDocument.sum(Array(orphanCharges.values), limit: SFTPSharedBudgetDocument.originalBodyBytes)
        _ = try value.globalCharge(actualBodies: orphanCharges, limit: layout.storage.poolByteLimit)
        try value.validate()
        guard let budgetID = value.budgetID else { throw SFTPSharedBudgetFailure.unsafe }
        // The marker deliberately precedes ledger construction. Every failure
        // after this point stays fenced/review-required; no rollback unlink.
        try writeFence(pool, name: metadataFence, prefix: "MEXSHAREDMETA1", id: budgetID)
        #if DEBUG
        try SFTPSharedBudgetQualification.shared.reach(.fenceWritten)
        #endif
        guard let file = try File.open(layout.ledger, writing: true) else { throw SFTPSharedBudgetFailure.recoveryRequired }
        do {
            guard file.snapshot.revision == 0 else { throw SFTPSharedBudgetFailure.recoveryRequired }
            try file.commit(value)
            #if DEBUG
            try SFTPSharedBudgetQualification.shared.reach(.ledgerWritten)
            #endif
            guard let bodyPool = try SMBCatalogFiles.openPool(layout.bodies, create: true) else { throw SFTPSharedBudgetFailure.unsafe }
            defer { Darwin.close(bodyPool) }
            let bodyLock = try SMBCatalogFiles.lockPool(bodyPool, create: true); defer { Darwin.close(bodyLock) }
            try writeFence(bodyPool, name: bodyFence, prefix: "MEXSHAREDBODY1", id: budgetID)
            #if DEBUG
            try SFTPSharedBudgetQualification.shared.reach(.bodyFenceWritten)
            #endif
            let parent = Darwin.open(layout.bodies.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard parent >= 0 else { throw SFTPSharedBudgetFailure.unsafe }; defer { Darwin.close(parent) }
            guard fsync(parent) == 0 else { throw SFTPSharedBudgetFailure.recoveryRequired }
            let transaction = SFTPSharedBudgetTransaction(layout: layout, pool: pool, guardFD: guardFD, file: file, ownsPool: false)
            var established = transaction.document; established.poolPhase = .active
            try transaction.commit(established, actualBodies: orphanCharges)
            #if DEBUG
            try SFTPSharedBudgetQualification.shared.reach(.metadataReserved)
            #endif
            return transaction
        } catch { file.close(); throw error }
    }
    private static func metadataRecord(id: UUID, purpose: SFTPSharedMetadataPurpose, storage: SMBTemporaryStorage) throws -> SharedMetadataCharge {
        guard SFTPWire.validToken(id) else { throw SFTPSharedBudgetFailure.unsafe }
        switch purpose {
        case .ordinary:
            return .init(id: id, kind: .ordinary, session: nil, quota: storage.sessionByteLimit, context: nil, phase: .allocating)
        case .originalPending(let session):
            guard SFTPWire.validToken(session) else { throw SFTPSharedBudgetFailure.unsafe }
            return .init(id: id, kind: .original, session: session,
                quota: min(storage.sessionByteLimit, SFTPSharedBudgetDocument.originalMetadataBytes), context: nil, phase: .allocating)
        }
    }
    private func addMetadata(id: UUID, purpose: SFTPSharedMetadataPurpose) throws {
        var next = document
        next.bodies.removeAll { $0.phase == .removed }
        let retainedOwners = Set(next.bodies.filter { $0.phase != .removed }.compactMap(\.owner))
        next.metadata.removeAll { $0.phase == .removed && !retainedOwners.contains($0.id) }
        guard next.metadata.count < 64, !next.metadata.contains(where: { $0.id == id }) else { throw SFTPSharedBudgetFailure.capacity }
        next.metadata.append(try Self.metadataRecord(id: id, purpose: purpose, storage: layout.storage))
        try commit(next)
        #if DEBUG
        try SFTPSharedBudgetQualification.shared.reach(.metadataReserved)
        #endif
    }
    func commit(_ value: SFTPSharedBudgetDocument, actualBodies: [UUID: UInt64]? = nil) throws {
        try workspaceLease?.validateCurrent()
        try file.validateCurrent()
        guard value.revision == document.revision, value.budgetID == document.budgetID,
              value.revision < UInt64.max else { throw SFTPSharedBudgetFailure.stale }
        var next = value; next.revision += 1
        _ = try next.globalCharge(actualBodies: actualBodies ?? actualBodyCharges(), limit: layout.storage.poolByteLimit)
        try next.validate(); try file.commit(next)
    }
    func metadataMaterialized(_ id: UUID) throws {
        let record = try SMBCatalogFiles.record(pool, name: "session-" + id.uuidString)
        guard record.summary.active else { throw SFTPSharedBudgetFailure.ownerEnded }
        var next = document
        guard let index = next.metadata.firstIndex(where: { $0.id == id }), next.metadata[index].phase == .allocating else { throw SFTPSharedBudgetFailure.stale }
        next.metadata[index].phase = .live; try commit(next)
        #if DEBUG
        try SFTPSharedBudgetQualification.shared.reach(.metadataMaterialized)
        #endif
    }
    func abortMetadataBeforeMkdir(_ id: UUID) throws {
        var facts = stat()
        guard fstatat(pool, "session-" + id.uuidString, &facts, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw SFTPSharedBudgetFailure.recoveryRequired }
        var next = document
        guard let index = next.metadata.firstIndex(where: { $0.id == id }), next.metadata[index].phase == .allocating else { throw SFTPSharedBudgetFailure.stale }
        next.metadata[index].phase = .removed; try commit(next)
    }
    func bindOriginal(catalogID: UUID, session: UUID, context: Data, heldLease: Int32) throws {
        let actual = try SMBCatalogFiles.record(pool, name: "session-" + catalogID.uuidString, heldLease: heldLease)
        guard actual.summary.active, context.count == 32 else { throw SFTPSharedBudgetFailure.ownerEnded }
        var next = document
        guard let index = next.metadata.firstIndex(where: { $0.id == catalogID }), next.metadata[index].kind == .original,
              next.metadata[index].phase == .live, next.metadata[index].session == session,
              next.metadata[index].context == nil || next.metadata[index].context == context else { throw SFTPSharedBudgetFailure.stale }
        next.metadata[index].context = context; try commit(next)
    }
    func metadataRemovalIntent(_ id: UUID) throws {
        guard !(document.retirements ?? []).contains(where: { $0.owner == id }) else { throw SFTPSharedBudgetFailure.busy }
        var next = document
        guard let index = next.metadata.firstIndex(where: { $0.id == id }), next.metadata[index].phase != .removed else { throw SFTPSharedBudgetFailure.stale }
        if next.metadata[index].kind == .original {
            guard let bodies = try SMBCatalogFiles.openPool(layout.bodies, create: false), let budgetID = document.budgetID else { throw SFTPSharedBudgetFailure.recoveryRequired }
            defer { Darwin.close(bodies) }
            let bodyLock = try SMBCatalogFiles.lockPool(bodies, create: false); defer { Darwin.close(bodyLock) }
            let held = Set(document.bodies.filter { $0.owner == id && $0.phase != .removed }.map(\.id))
            guard !(try DownloadDisk.inventory(bodies, originalBudgetID: budgetID)).contains(where: {
                held.contains($0.summary.id) && $0.summary.active
            }) else { throw SFTPSharedBudgetFailure.busy }
        }
        next.metadata[index].phase = .removalPending; try commit(next)
        #if DEBUG
        try SFTPSharedBudgetQualification.shared.reach(.metadataRemovalIntent)
        #endif
    }
    func metadataRemoved(_ id: UUID) throws {
        var facts = stat()
        guard fstatat(pool, "session-" + id.uuidString, &facts, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw SFTPSharedBudgetFailure.recoveryRequired }
        var next = document
        guard let index = next.metadata.firstIndex(where: { $0.id == id }), next.metadata[index].phase == .removalPending else { throw SFTPSharedBudgetFailure.stale }
        next.metadata[index].phase = .removed; try commit(next)
        #if DEBUG
        try SFTPSharedBudgetQualification.shared.reach(.metadataRemoved)
        #endif
    }
    func actualBodyCharges() throws -> [UUID: UInt64] {
        guard let budgetID = document.budgetID, let bodies = try SMBCatalogFiles.openPool(layout.bodies, create: false) else { throw SFTPSharedBudgetFailure.recoveryRequired }
        defer { Darwin.close(bodies) }
        let lock = try SMBCatalogFiles.lockPool(bodies, create: false); defer { Darwin.close(lock) }
        guard try Self.readFence(bodies, name: Self.bodyFence, prefix: "MEXSHAREDBODY1") == budgetID else { throw SFTPSharedBudgetFailure.recoveryRequired }
        var charges: [UUID: UInt64] = [:]
        for record in try SFTPRetainedBodyRemoval.inventory(pool: bodies, document: document) {
            guard let entry = document.bodies.first(where: { $0.id == record.summary.id }), entry.phase != .removed,
                  entry.expectedBytes == record.summary.expectedBytes, entry.reservedBytes == record.reservedBytes,
                  !record.summary.isFolder else { throw SFTPSharedBudgetFailure.unsafe }
            let marker = try JSONDecoder().decode(DownloadDisk.Marker.self, from: record.marker)
            if let owner = entry.owner {
                guard marker.version == 3, marker.originalBudget == budgetID, marker.originalOwner == owner else { throw SFTPSharedBudgetFailure.stale }
            } else {
                guard marker.version == 1, marker.originalBudget == nil, marker.originalOwner == nil else { throw SFTPSharedBudgetFailure.stale }
            }
            charges[entry.id] = max(record.summary.observedBytes, record.reservedBytes)
        }
        for body in document.bodies where body.phase == .allocated && body.owner != nil {
            guard charges[body.id] != nil else { throw SFTPSharedBudgetFailure.recoveryRequired }
        }
        return charges
    }
    func validateInventory() throws {
        try file.validateCurrent(); try document.validate()
        let records = try Self.records(pool)
        for record in records {
            guard let entry = document.metadata.first(where: { $0.id == record.summary.id }), entry.phase != .removed,
                  record.summary.observedBytes <= SFTPSharedBudgetDocument.ownerBytes else { throw SFTPSharedBudgetFailure.unsafe }
        }
        let bodies = try actualBodyCharges()
        _ = try SFTPSharedBudgetDocument.sum(document.bodies.filter { $0.phase != .removed }
            .map { max($0.reservedBytes, bodies[$0.id] ?? 0) }, limit: SFTPSharedBudgetDocument.originalBodyBytes)
        for owner in document.metadata where owner.kind == .original {
            let charges = document.bodies.filter { $0.owner == owner.id && $0.phase != .removed }.map { max($0.reservedBytes, bodies[$0.id] ?? 0) }
            _ = try SFTPSharedBudgetDocument.sum(charges, limit: SFTPSharedBudgetDocument.originalBodyBytes)
            let observed = records.first(where: { $0.summary.id == owner.id })?.summary.observedBytes ?? 0
            guard observed <= owner.quota + (64 << 10) else { throw SFTPSharedBudgetFailure.capacity }
            let metadata = max(owner.quota + (64 << 10), observed)
            _ = try SFTPSharedBudgetDocument.sum(charges + [metadata, SFTPSharedBudgetDocument.ownerOverheadBytes], limit: SFTPSharedBudgetDocument.ownerBytes)
        }
        _ = try document.globalCharge(actualBodies: bodies, limit: layout.storage.poolByteLimit)
        try Self.validateMetadataFootprint(layout)
    }
    static func validateMetadataFootprint(_ layout: SFTPSharedBudgetLayout, workspaceRecordBytes: UInt64? = nil) throws {
        let recordBytes: UInt64
        if let workspaceRecordBytes { recordBytes = workspaceRecordBytes }
        else if let witness = layout.storage.workspaceWitness { recordBytes = try ConnectionWorkspaceDisk.recordFootprint(witness.paths) }
        else { recordBytes = 0 }
        guard recordBytes <= SFTPSharedBudgetDocument.globalOverheadBytes - (64 << 10) else { throw SFTPSharedBudgetFailure.capacity }
        // The location record shares the existing global2MiB overhead reserve.
        // This does not add another allowance or another budget root.
        var charged: UInt64 = (64 << 10) + recordBytes
        for path in [layout.ledger, layout.editors, layout.journal] {
            guard let directory = try SMBCatalogFiles.openPool(path, create: false) else { continue }
            defer { Darwin.close(directory) }
            for name in try DownloadDisk.names(directory, maximum: 3) {
                guard ["owner.lock", "servers.json", "pending.json"].contains(name) else { throw SFTPSharedBudgetFailure.unsafe }
                var facts = stat()
                guard fstatat(directory, name, &facts, AT_SYMLINK_NOFOLLOW) == 0, DownloadDisk.privateFile(facts),
                      facts.st_size <= (name == "owner.lock" ? 0 : 256 << 10), UInt64(facts.st_blocks) <= (512 << 10) / 512 else { throw SFTPSharedBudgetFailure.unsafe }
                let amount = max(UInt64(facts.st_size), UInt64(facts.st_blocks) * 512)
                guard amount <= SFTPSharedBudgetDocument.globalOverheadBytes,
                      charged <= SFTPSharedBudgetDocument.globalOverheadBytes - amount else { throw SFTPSharedBudgetFailure.capacity }
                charged += amount
            }
        }
    }
    static func writeFence(_ directory: Int32, name: String, prefix: String, id: UUID) throws {
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SFTPSharedBudgetFailure.recoveryRequired }; defer { Darwin.close(descriptor) }
        try DownloadDisk.writeAll(descriptor, Data((prefix + " " + id.uuidString + "\n").utf8))
        guard fsync(descriptor) == 0, fsync(directory) == 0 else { throw SFTPSharedBudgetFailure.recoveryRequired }
    }
    static func readFence(_ directory: Int32, name: String, prefix: String) throws -> UUID {
        let descriptor = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw SFTPSharedBudgetFailure.recoveryRequired }; defer { Darwin.close(descriptor) }
        var facts = stat(), named = stat()
        guard fstat(descriptor, &facts) == 0, DownloadDisk.privateFile(facts), facts.st_size <= 128,
              UInt64(facts.st_blocks) <= 16, fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              DownloadDisk.Identity(facts) == DownloadDisk.Identity(named) else { throw SFTPSharedBudgetFailure.unsafe }
        var data = Data(count: Int(facts.st_size)); let count = data.count
        guard data.withUnsafeMutableBytes({ pread(descriptor, $0.baseAddress, count, 0) }) == count,
              let text = String(data: data, encoding: .utf8), text.hasPrefix(prefix + " "), text.hasSuffix("\n"),
              let id = UUID(uuidString: String(text.dropFirst(prefix.count + 1).dropLast())), SFTPWire.validToken(id),
              text == prefix + " " + id.uuidString + "\n" else { throw SFTPSharedBudgetFailure.recoveryRequired }
        return id
    }
}

final class SFTPSharedMetadataCreation {
    let transaction: SFTPSharedBudgetTransaction, id: UUID, writerQuota: UInt64
    private var possibleCreation = false, completed = false
    fileprivate init(transaction: SFTPSharedBudgetTransaction, id: UUID, writerQuota: UInt64) {
        self.transaction = transaction; self.id = id; self.writerQuota = writerQuota
    }
    func beforeMkdir() throws {
        possibleCreation = true
        #if DEBUG
        try SFTPSharedBudgetQualification.shared.reach(.metadataBeforeMkdir)
        #endif
    }
    func materialized() throws { try transaction.metadataMaterialized(id); completed = true }
    func closeAfterConstructor() {
        if !completed && !possibleCreation { try? transaction.abortMetadataBeforeMkdir(id) }
        transaction.close()
    }
}
