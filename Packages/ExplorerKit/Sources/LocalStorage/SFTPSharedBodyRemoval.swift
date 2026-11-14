import CryptoKit
import Darwin
import Foundation

extension SFTPSharedBudgetTransaction {
    /// Generic unused capture removal requires an actual allocation. A read
    /// cleanup supplies its private job proof; an admitted copy supplies the
    /// actual locked catalog proof. No caller can assert "unreferenced=true".
    func removeOriginalBody(_ id: UUID, heldLease: Int32? = nil, allocation: SFTPOriginalBodyAllocation? = nil,
        readProof: SFTPOriginalUnadmittedReadProof? = nil,
        catalogProof: SFTPOriginalCatalogRetirementProof? = nil) throws {
        guard let budgetID = document.budgetID,
              let charge = document.bodies.first(where: { $0.id == id }), charge.phase != .removed else { throw SFTPSharedBudgetFailure.stale }
        if let allocation {
            guard allocation.id == id, allocation.owner.budgetID == budgetID, allocation.owner.layout == layout,
                  charge.owner == allocation.owner.catalogID else { throw SFTPSharedBudgetFailure.stale }
        }
        if allocation == nil && readProof == nil && catalogProof == nil { throw SFTPSharedBudgetFailure.unsafe }
        let editors: RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>?
        var ownsEditors = false
        if let catalogProof {
            try catalogProof.validate(layout: layout, body: id)
            guard let metadata = document.metadata.first(where: { $0.id == charge.owner }), metadata.kind == .original,
                  metadata.session == catalogProof.session,
                  let record = catalogProof.file.snapshot.records.first(where: { $0.id == catalogProof.editorID }),
                  try Self.contextDigest(record.context) == metadata.context else { throw SFTPSharedBudgetFailure.stale }
            editors = catalogProof.file
        } else {
            editors = try RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>.open(layout.editors, writing: readProof != nil)
            ownsEditors = true
        }
        defer { if ownsEditors { editors?.close() } }
        if let editors { try editors.validateCurrent() }
        let excluded: UUID?
        if let readProof {
            guard let editors, let record = editors.snapshot.records.first(where: { $0.id == readProof.editorID }) else { throw SFTPSharedBudgetFailure.referenced }
            try readProof.validate(record: record, body: id)
            guard let owner = document.metadata.first(where: { $0.id == charge.owner }), owner.kind == .original,
                  owner.session == readProof.session, try Self.contextDigest(record.context) == owner.context else { throw SFTPSharedBudgetFailure.stale }
            excluded = readProof.editorID
        } else { excluded = catalogProof?.editorID }
        guard editors?.snapshot.records.contains(where: { record in
            record.id != excluded && (record.bodyID == id || record.body?.id == id || record.recovery.contains(where: { $0.id == id }))
        }) != true else { throw SFTPSharedBudgetFailure.referenced }
        if excluded == nil, editors?.snapshot.records.contains(where: { $0.bodyID == id || $0.body?.id == id || $0.recovery.contains(where: { $0.id == id }) }) == true {
            throw SFTPSharedBudgetFailure.referenced
        }
        if let retained = catalogProof?.retained {
            // This authority validated the held journal writer and ALL selected
            // references, not an assertion that a retained copy is unreferenced.
            try retained.removeBody(id); return
        }
        // A real writer/uncertain commit refuses this read. Every journal
        // reference remains mandatory, including notStarted captured text.
        do {
            let journal = try RemoteSettingsFile<SFTPOriginalJournalDocument>.open(layout.journal, writing: false)
            defer { journal?.close() }
            if let journal {
                try journal.validateCurrent()
                guard !journal.snapshot.records.contains(where: { $0.baseline.id == id || $0.edited.id == id }) else { throw SFTPSharedBudgetFailure.referenced }
            }
        } catch RemoteSettingsFailure.incompatibleVersion {
            // Only this EXACT canonical alternate identity is accepted. Busy,
            // corrupt, stale or pending files never become an empty history.
            let journal = try RemoteSettingsFile<SFTPInPlaceJournalDocument>.open(layout.journal, writing: false)
            defer { journal?.close() }
            guard let journal else { throw SFTPSharedBudgetFailure.recoveryRequired }; try journal.validateCurrent()
            guard !journal.snapshot.records.contains(where: { $0.baseline.id == id || $0.edited.id == id }) else { throw SFTPSharedBudgetFailure.referenced }
        }
        guard let pool = try SMBCatalogFiles.openPool(layout.bodies, create: false) else { throw SFTPSharedBudgetFailure.recoveryRequired }
        defer { Darwin.close(pool) }
        let bodyLock = try SMBCatalogFiles.lockPool(pool, create: false); defer { Darwin.close(bodyLock) }
        guard try Self.readFence(pool, name: Self.bodyFence, prefix: "MEXSHAREDBODY1") == budgetID else { throw SFTPSharedBudgetFailure.unsafe }
        let record = try DownloadDisk.record(pool, name: "download-" + id.uuidString, heldLease: heldLease)
        guard heldLease != nil || !record.summary.active else { throw SFTPSharedBudgetFailure.busy }
        let marker = try JSONDecoder().decode(DownloadDisk.Marker.self, from: record.marker)
        guard marker.version == 3, marker.originalBudget == budgetID, marker.originalOwner == charge.owner else { throw SFTPSharedBudgetFailure.stale }
        if let reference = catalogProof?.reference { try Self.checkDigest(pool: pool, record: record, reference: reference, bodyDirectory: layout.bodies) }
        var charges = try DownloadDisk.inventory(pool, originalBudgetID: budgetID)
            .reduce(into: [UUID: UInt64]()) { $0[$1.summary.id] = max($1.summary.observedBytes, $1.reservedBytes) }
        var next = document
        guard let index = next.bodies.firstIndex(where: { $0.id == id }) else { throw SFTPSharedBudgetFailure.stale }
        next.bodies[index].phase = .removalPending; try commit(next, actualBodies: charges)
        if let readProof, let editors {
            var document = editors.snapshot
            guard let index = document.records.firstIndex(where: { $0.id == readProof.editorID }), document.revision < UInt64.max else { throw SFTPSharedBudgetFailure.stale }
            document.records[index].bodyID = id; document.records[index].path = readProof.path
            document.records[index].phase = .unadmittedRemovalPending; document.revision += 1
            try editors.commit(document)
        }
        #if DEBUG
        try SFTPSharedBudgetQualification.shared.reach(.bodyRemovalIntent)
        #endif
        try DownloadDisk.remove(pool, record: record, heldLease: heldLease)
        #if DEBUG
        try SFTPSharedBudgetQualification.shared.reach(.bodyDeleted)
        #endif
        if let catalogProof { try catalogProof.completeAfterActualDeletion() }
        if let readProof, let editors {
            try editors.validateCurrent(); var document = editors.snapshot
            guard let index = document.records.firstIndex(where: { $0.id == readProof.editorID }),
                  document.records[index].phase == .unadmittedRemovalPending, document.revision < UInt64.max else { throw SFTPSharedBudgetFailure.stale }
            document.records[index].body = nil; document.records[index].bodyID = nil
            document.records[index].phase = .closedUnused; document.revision += 1; try editors.commit(document)
        }
        // Release follows exact deletion/fsync AND the actual catalog commit.
        // A failure above keeps removalPending and its complete charged bucket.
        next = document
        guard let final = next.bodies.firstIndex(where: { $0.id == id }), next.bodies[final].phase == .removalPending else { throw SFTPSharedBudgetFailure.stale }
        next.bodies[final].phase = .removed; charges.removeValue(forKey: id)
        try commit(next, actualBodies: charges)
        #if DEBUG
        try SFTPSharedBudgetQualification.shared.reach(.bodyReleased)
        #endif
    }
    static func contextDigest(_ context: SFTPOriginalContext) throws -> Data {
        try context.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Data(SHA256.hash(data: try encoder.encode(context)))
    }
    static func checkDigest(pool: Int32, record: DownloadDisk.Record, reference: SFTPOriginalSpoolReference,
        bodyDirectory: URL) throws {
        // A pin constructor may validate and hash payload before pinOpen.
        // Count the canonical validation entry even if a later check fails.
        #if DEBUG && !SFTP_PARENT_STANDALONE
        SFTPGeneratedBackendObservation.shared.payloadValidationRead(directory: bodyDirectory)
        #endif
        guard reference.id == record.summary.id, reference.logicalBytes == record.summary.expectedBytes else { throw SFTPSharedBudgetFailure.stale }
        let folder = openat(pool, record.name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard folder >= 0 else { throw SFTPSharedBudgetFailure.unsafe }; defer { Darwin.close(folder) }
        let file = openat(folder, "payload", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw SFTPSharedBudgetFailure.unsafe }; defer { Darwin.close(file) }
        let before = try DownloadDisk.stamp(file)
        guard before.identity == record.files["payload"], before.size == reference.logicalBytes else { throw SFTPSharedBudgetFailure.stale }
        var hash = SHA256(), offset: UInt64 = 0
        while offset < reference.logicalBytes {
            var bytes = Data(count: Int(min(32768, reference.logicalBytes - offset))); let count = bytes.count
            let found = bytes.withUnsafeMutableBytes { pread(file, $0.baseAddress, count, off_t(offset)) }
            if found < 0 && errno == EINTR { continue }
            guard found == count else { throw SFTPSharedBudgetFailure.unsafe }; hash.update(data: bytes); offset += UInt64(found)
        }
        guard Data(hash.finalize()) == reference.digest, try DownloadDisk.stamp(file) == before else { throw SFTPSharedBudgetFailure.stale }
    }
}

extension SFTPOriginalBodyAllocation {
    func removeAfterActualUsersDrain(heldLease: Int32, readProof: SFTPOriginalUnadmittedReadProof? = nil) throws {
        let transaction = try SFTPSharedBudgetTransaction.open(layout: owner.layout, writing: true)
        defer { transaction.close() }
        try transaction.removeOriginalBody(id, heldLease: heldLease, allocation: self, readProof: readProof)
    }
}
