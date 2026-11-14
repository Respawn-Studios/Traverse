import Darwin
import Foundation

/// Retains real record SH -> pool EX -> ledger/editor/journal owners. The
/// selected metadata lease and ALL body leases outlive the complete operation.
fileprivate final class SFTPRetainedRetirementSession {
    let transaction: SFTPSharedBudgetTransaction
    let editors: RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>
    let journal: RemoteSettingsFile<SFTPInPlaceJournalDocument>?
    private(set) var bodyPool: Int32
    private var leases: [UUID: Int32] = [:], metadataLease: Int32?
    private var metadataLeaseOwner: UUID?
    init(layout: SFTPSharedBudgetLayout, writing: Bool) throws {
        let transaction = try SFTPSharedBudgetTransaction.open(layout: layout, writing: writing, retirementAccess: writing ? .explicitResume : .passive)
        var editor: RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>?
        var journal: RemoteSettingsFile<SFTPInPlaceJournalDocument>?, pool: Int32 = -1, keep = false
        defer { if !keep { editor?.close(); journal?.close(); if pool >= 0 { Darwin.close(pool) }; transaction.close() } }
        #if DEBUG
        let editorProbe: RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>.Probe?
        let journalProbe: RemoteSettingsFile<SFTPInPlaceJournalDocument>.Probe?
        if writing {
            editorProbe = { stage in try SFTPRetainedRemovalQualification.shared.metadata("editor", stage.rawValue) }
            journalProbe = { stage in try SFTPRetainedRemovalQualification.shared.metadata("journal", stage.rawValue) }
        } else { editorProbe = nil; journalProbe = nil }
        #else
        let editorProbe: RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>.Probe? = nil
        let journalProbe: RemoteSettingsFile<SFTPInPlaceJournalDocument>.Probe? = nil
        #endif
        let known = Set((transaction.document.retirements ?? []).flatMap { $0.bodies.map { $0.reference.id } })
        guard !transaction.document.metadata.contains(where: { [.allocating, .removalPending].contains($0.phase) }),
              !transaction.document.bodies.contains(where: { $0.phase == .allocating || ($0.phase == .removalPending && !known.contains($0.id)) }) else { throw SFTPSharedBudgetFailure.recoveryRequired }
        let stageAuthority = SFTPRetainedMetadataStageAccess.inspectReferences(transaction.document)
        if writing {
            guard let read = try RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>.open(layout.editors, writing: false, retainedRetirement: stageAuthority) else { throw SFTPSharedBudgetFailure.stale }
            read.close()
        }
        editor = try RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>.open(layout.editors, writing: writing, probe: editorProbe, retainedRetirement: writing ? SFTPRetainedMetadataStageAccess.resumeReferences(transaction.document) : stageAuthority)
        guard let editor else { throw SFTPSharedBudgetFailure.stale }
        if let read = try RemoteSettingsFile<SFTPInPlaceJournalDocument>.open(layout.journal, writing: false, retainedRetirement: stageAuthority) {
            if writing { read.close(); journal = try RemoteSettingsFile<SFTPInPlaceJournalDocument>.open(layout.journal, writing: true, probe: journalProbe, retainedRetirement: SFTPRetainedMetadataStageAccess.resumeReferences(transaction.document)) }
            else { journal = read }
        }
        guard let opened = try SMBCatalogFiles.openPool(layout.bodies, create: false) else { throw SFTPSharedBudgetFailure.stale }; pool = opened
        self.transaction = transaction; self.editors = editor; self.journal = journal; bodyPool = pool
        do { try validateGraph() }
        catch {
            // A throwing initializer does not reliably run deinit. The local
            // defer owns every descriptor until graph validation succeeds.
            // Clear this copy too if a runtime does deinitialize failed self.
            bodyPool = -1
            throw error
        }
        keep = true
    }
    deinit {
        leases.values.forEach { Darwin.close($0) }; if let metadataLease { Darwin.close(metadataLease) }
        if bodyPool >= 0 { Darwin.close(bodyPool) }
        journal?.close(); editors.close(); transaction.close()
    }
    func validateGraph() throws {
        try editors.validateCurrent(); try journal?.validateCurrent()
        let intents = transaction.document.retirements ?? []
        for intent in intents {
            try intent.validateGraph(editors: editors.snapshot, journal: journal?.snapshot)
            try intent.validateMetadataOwner(pool: transaction.pool, document: transaction.document, heldLease: metadataLeaseOwner == intent.owner ? metadataLease : nil)
        }
        let pending = Set(intents.map { $0.editor.id })
        for save in journal?.snapshot.records ?? [] {
            let matches = editors.snapshot.records.filter { $0.journals.contains(save.id) }
            guard matches.count == 1, let editor = matches.first,
                  editor.session == save.session, editor.context == save.context, editor.path == save.path,
                  editor.recovery.contains(save.baseline), editor.recovery.contains(save.edited) else { throw SFTPSharedBudgetFailure.referenced }
        }
        for editor in editors.snapshot.records where editor.phase != .closedUnused && !pending.contains(editor.id) {
            let saves = (journal?.snapshot.records ?? []).filter { editor.journals.contains($0.id) }
            guard Set(saves.map(\.id)) == Set(editor.journals) else { throw SFTPSharedBudgetFailure.referenced }
        }
    }
    func metadata(_ editor: SFTPOriginalEditorRecord, acquire: Bool) throws -> (SharedMetadataCharge, SMBCatalogFiles.Record?) {
        let owners = transaction.document.metadata.filter {
            $0.kind == .original && $0.session == editor.session && $0.context == (try? SFTPSharedBudgetTransaction.contextDigest(editor.context))
        }
        guard owners.count == 1, let owner = owners.first, [.live, .orphan, .removed].contains(owner.phase) else { throw SFTPSharedBudgetFailure.stale }
        let name = "session-" + owner.id.uuidString
        if owner.phase == .removed {
            var facts = stat(); errno = 0
            guard fstatat(transaction.pool, name, &facts, AT_SYMLINK_NOFOLLOW) < 0, errno == ENOENT else { throw SFTPSharedBudgetFailure.stale }
            return (owner, nil)
        }
        let record = try SMBCatalogFiles.record(transaction.pool, name: name)
        guard !record.summary.active, record.files["catalog.sqlite-journal"] == nil else { throw SFTPSharedBudgetFailure.busy }
        if acquire {
            let directory = openat(transaction.pool, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard directory >= 0 else { throw SFTPSharedBudgetFailure.stale }; defer { Darwin.close(directory) }
            let lease = openat(directory, "owner.lock", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard lease >= 0 else { throw SFTPSharedBudgetFailure.stale }
            var keep = false; defer { if !keep { Darwin.close(lease) } }
            guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { throw SFTPSharedBudgetFailure.busy }
            let actual = try SMBCatalogFiles.record(transaction.pool, name: name, heldLease: lease)
            guard actual.directory == record.directory, actual.files == record.files, actual.marker == record.marker else { throw SFTPSharedBudgetFailure.stale }
            metadataLease = lease; metadataLeaseOwner = owner.id; keep = true
        }
        return (owner, record)
    }
    func freshIntent(_ editor: SFTPOriginalEditorRecord, acquire: Bool) throws -> SFTPRetainedRetirementIntent {
        guard let budget = transaction.document.budgetID, let initial = editor.body,
              [.admitted, .readyToAccept, .saveReferenced, .retainedReleasePending, .recoveryOnly, .releasePending].contains(editor.phase) else { throw SFTPSharedBudgetFailure.busy }
        let (owner, metadata) = try metadata(editor, acquire: acquire)
        let saves = (journal?.snapshot.records ?? []).filter { editor.journals.contains($0.id) }
        guard Set(saves.map(\.id)) == Set(editor.journals), saves.isEmpty ? editor.recovery.isEmpty : editor.recovery.contains(initial) else { throw SFTPSharedBudgetFailure.referenced }
        let refs = editor.recovery + [initial]
        var unique: [UUID: SFTPOriginalSpoolReference] = [:]
        for ref in refs { if let old = unique[ref.id], old != ref { throw SFTPSharedBudgetFailure.stale }; unique[ref.id] = ref }
        guard !unique.isEmpty, unique.count <= 8,
              saves.isEmpty || Set(unique.keys) == Set(saves.flatMap { [$0.baseline.id, $0.edited.id] }) else { throw SFTPSharedBudgetFailure.referenced }
        var bodies: [SFTPRetainedBodyIntent] = []
        let lock = try SMBCatalogFiles.lockPool(bodyPool, create: false); defer { Darwin.close(lock) }
        for ref in unique.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard transaction.document.bodies.contains(where: { $0.id == ref.id && $0.owner == owner.id && $0.phase == .allocated && $0.expectedBytes == ref.logicalBytes }) else { throw SFTPSharedBudgetFailure.stale }
            let record = try DownloadDisk.record(bodyPool, name: "download-" + ref.id.uuidString)
            guard !record.summary.active else { throw SFTPSharedBudgetFailure.busy }
            let body = SFTPRetainedBodyIntent(ref, record: record); try body.validate(budget: budget, owner: owner.id)
            if acquire { try acquireBody(body, hash: true) }
            bodies.append(body)
        }
        // SMBCatalogFiles identities use device+inode. Its private marker is
        // checked by record(); retain that exact anchored identity graph.
        let result = SFTPRetainedRetirementIntent(editor: editor, owner: owner.id, budget: budget,
            metadataDirectory: metadata.map { SFTPRetainedDiskIdentity.metadata($0.directory) },
            metadataFiles: metadata.map { $0.files.mapValues(SFTPRetainedDiskIdentity.metadata) },
            saves: try saves.map { .init(id: $0.id, digest: try SFTPRetainedRetirementIntent.digest($0)) }, bodies: bodies)
        try result.validateGraph(editors: editors.snapshot, journal: journal?.snapshot)
        return result
    }
    func acquireBody(_ body: SFTPRetainedBodyIntent, hash: Bool) throws {
        guard let folder = try SFTPRetainedBodyRemoval.inspect(pool: bodyPool, body: body, hash: hash) else { return }
        defer { Darwin.close(folder) }
        let present = Set(try DownloadDisk.names(folder, maximum: 3))
        guard present.contains("owner.lock") else { return }
        let lease = openat(folder, "owner.lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard lease >= 0 else { throw SFTPSharedBudgetFailure.stale }
        var keep = false; defer { if !keep { Darwin.close(lease) } }
        guard body.files["owner.lock"]?.matches(try DownloadDisk.identity(lease)) == true else {
            throw SFTPSharedBudgetFailure.busy
        }
        #if DEBUG
        try SFTPRetainedRemovalQualification.shared.reach(.beforeBodyExclusive)
        #endif
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { throw SFTPSharedBudgetFailure.busy }
        // Hash and identity validation AFTER acquiring the real lease.
        if let checked = try SFTPRetainedBodyRemoval.inspect(pool: bodyPool, body: body, hash: hash) { Darwin.close(checked) }
        leases[body.reference.id] = lease; keep = true
    }
    func acquirePending(_ intent: SFTPRetainedRetirementIntent) throws {
        let (owner, metadata) = try metadata(intent.editor, acquire: true)
        guard owner.id == intent.owner,
              metadata.map({ SFTPRetainedDiskIdentity.metadata($0.directory) }) == intent.metadataDirectory,
              metadata.map({ $0.files.mapValues(SFTPRetainedDiskIdentity.metadata) }) == intent.metadataFiles else { throw SFTPSharedBudgetFailure.stale }
        let lock = try SMBCatalogFiles.lockPool(bodyPool, create: false); defer { Darwin.close(lock) }
        for body in intent.bodies { try acquireBody(body, hash: true) }
    }
    func lease(_ id: UUID) -> Int32? { leases[id] }
    func setStage(_ editor: UUID, _ stage: SFTPRetainedRetirementStage) throws {
        var next = transaction.document
        guard let index = next.retirements?.firstIndex(where: { $0.editor.id == editor }) else { throw SFTPSharedBudgetFailure.stale }
        next.retirements?[index].stage = stage; try transaction.commit(next)
    }
}

/// Nonforgeable authority holds the actual checked writers and real leases.
/// It never grants arbitrary body deletion or ignores unrelated references.
final class SFTPRetainedRetirementAuthority {
    private let owner: SFTPRetainedRetirementSession
    let intent: SFTPRetainedRetirementIntent
    private init(owner: SFTPRetainedRetirementSession, intent: SFTPRetainedRetirementIntent) { self.owner = owner; self.intent = intent }
    fileprivate static func mint(owner: SFTPRetainedRetirementSession, intent: SFTPRetainedRetirementIntent) -> Self { .init(owner: owner, intent: intent) }
    var layout: SFTPSharedBudgetLayout { owner.transaction.layout }
    var editorFile: RemoteSettingsFile<SFTPOriginalEditorCatalogDocument> { owner.editors }
    func validate(layout: SFTPSharedBudgetLayout, body: UUID) throws {
        try owner.transaction.file.validateCurrent(); try owner.validateGraph()
        guard owner.transaction.layout == layout,
              owner.transaction.document.retirements?.contains(intent) == true,
              intent.stage == .deleting, intent.bodies.contains(where: { $0.reference.id == body }) else { throw SFTPSharedBudgetFailure.referenced }
    }
    func removeBody(_ id: UUID) throws {
        try validate(layout: owner.transaction.layout, body: id)
        guard let body = intent.bodies.first(where: { $0.reference.id == id }) else { throw SFTPSharedBudgetFailure.stale }
        let lock = try SMBCatalogFiles.lockPool(owner.bodyPool, create: false); defer { Darwin.close(lock) }
        try SFTPRetainedBodyRemoval.remove(pool: owner.bodyPool, body: body, heldLease: owner.lease(id))
        // No reference or charge is released here. Whole-document retirement
        // follows only after EVERY selected body has been durably deleted.
    }
}

extension SFTPRetainedDiskIdentity {
    static func metadata(_ value: SMBCatalogFiles.Identity) -> Self {
        .init(device: Int64(value.device), inode: UInt64(value.inode), birth: 0, nanos: 0)
    }
}

final class SFTPRetainedRetirementOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var active: (UUID, Task<[SFTPRetainedDocumentChoice], Error>)?, draining = 0
    private func perform(_ action: @escaping @Sendable () throws -> [SFTPRetainedDocumentChoice]) async throws -> [SFTPRetainedDocumentChoice] {
        let (id, task) = try lock.withLock { () throws -> (UUID, Task<[SFTPRetainedDocumentChoice], Error>) in
            guard active == nil, draining == 0 else { throw SFTPSharedBudgetFailure.busy }
            let id = UUID(), task = Task.detached(priority: .utility) { try Task.checkCancellation(); return try action() }
            active = (id, task); return (id, task)
        }
        defer { lock.withLock { if active?.0 == id { active = nil } } }
        return try await withTaskCancellationHandler { let value = try await task.value; try Task.checkCancellation(); return value } onCancel: { task.cancel() }
    }
    func choices(_ prepare: @escaping @Sendable () throws -> SFTPSharedBudgetLayout?) async throws -> [SFTPRetainedDocumentChoice] {
        try await perform {
            guard let layout = try prepare() else { return [] }
            let owner = try SFTPRetainedRetirementSession(layout: layout, writing: false)
            let stamp = try owner.transaction.file.recoveryReadIdentity(), document = owner.transaction.document
            var result: [SFTPRetainedDocumentChoice] = []
            let pending = document.retirements ?? []
            let editorIdentity = try owner.editors.recoveryReadIdentity(), journalIdentity = try owner.journal?.recoveryReadIdentity()
            for intent in pending {
                result.append(.mint(layout: layout, editor: intent.editor, stamp: stamp, revision: document.revision, intent: intent, captured: intent,
                    editorIdentity: editorIdentity, journalIdentity: journalIdentity))
            }
            for editor in owner.editors.snapshot.records where editor.phase != .closedUnused && !pending.contains(where: { $0.editor.id == editor.id }) {
                do {
                    let captured = try owner.freshIntent(editor, acquire: false)
                    result.append(.mint(layout: layout, editor: editor, stamp: stamp, revision: document.revision, intent: nil, captured: captured,
                        editorIdentity: editorIdentity, journalIdentity: journalIdentity))
                } catch SFTPSharedBudgetFailure.busy { continue }
            }
            guard result.count <= 64 else { throw SFTPSharedBudgetFailure.capacity }; return result
        }
    }
    func remove(_ choice: SFTPRetainedDocumentChoice, prepare: @escaping @Sendable () throws -> SFTPSharedBudgetLayout?) async throws {
        _ = try await perform {
            guard let layout = try prepare(), layout == choice.layout else { throw SFTPSharedBudgetFailure.stale }
            let owner = try SFTPRetainedRetirementSession(layout: layout, writing: true)
            guard owner.transaction.document.revision == choice.revision,
                  try owner.transaction.file.recoveryReadIdentity() == choice.stamp,
                  try owner.editors.recoveryReadIdentity() == choice.editorIdentity,
                  try owner.journal?.recoveryReadIdentity() == choice.journalIdentity else { throw SFTPSharedBudgetFailure.stale }
            var intent: SFTPRetainedRetirementIntent
            if let pending = choice.intent {
                guard owner.transaction.document.retirements?.contains(pending) == true else { throw SFTPSharedBudgetFailure.stale }
                intent = pending; try owner.acquirePending(intent)
                // A metadata open NEVER removes a stage. Explicit Resume may
                // retire only this selected intent's exact staged prefix,
                // after all actual graph/body owners have been acquired.
                try owner.transaction.file.retireRetainedStageForExplicitResume(selectedEditor: intent.editor.id)
                try owner.journal?.retireRetainedStageForExplicitResume(selectedEditor: intent.editor.id)
                try owner.editors.retireRetainedStageForExplicitResume(selectedEditor: intent.editor.id)
            } else {
                guard owner.editors.snapshot.records.contains(choice.editor) else { throw SFTPSharedBudgetFailure.stale }
                intent = try owner.freshIntent(choice.editor, acquire: true)
                guard intent == choice.captured else { throw SFTPSharedBudgetFailure.stale }
                var next = owner.transaction.document; next.format = max(next.format, 2)
                next.retirements = (next.retirements ?? []) + [intent]
                for index in next.bodies.indices where intent.bodies.contains(where: { $0.reference.id == next.bodies[index].id }) { next.bodies[index].phase = .removalPending }
                try Task.checkCancellation(); try owner.transaction.commit(next)
                #if DEBUG
                try SFTPRetainedRemovalQualification.shared.reach(.intentCommitted)
                #endif
            }
            if intent.stage == .deleting {
                let proof = SFTPRetainedRetirementAuthority.mint(owner: owner, intent: intent)
                for body in intent.bodies {
                    try Task.checkCancellation()
                    let catalog = SFTPOriginalCatalogRetirementProof.retained(proof, reference: body.reference)
                    try owner.transaction.removeOriginalBody(body.reference.id, catalogProof: catalog)
                }
                try owner.setStage(intent.editor.id, .retiringHistory); intent.stage = .retiringHistory
            }
            if intent.stage == .retiringHistory {
                try Task.checkCancellation()
                #if DEBUG
                try SFTPRetainedRemovalQualification.shared.reach(.beforeHistory)
                #endif
                if let journal = owner.journal, journal.snapshot.records.contains(where: { intent.editor.journals.contains($0.id) }) {
                    var next = journal.snapshot; guard next.revision < UInt64.max else { throw SFTPSharedBudgetFailure.capacity }
                    next.records.removeAll { intent.editor.journals.contains($0.id) }; next.revision += 1; try journal.commit(next)
                }
                #if DEBUG
                try SFTPRetainedRemovalQualification.shared.reach(.historyCommitted)
                #endif
                try owner.setStage(intent.editor.id, .retiringEditor); intent.stage = .retiringEditor
            }
            if intent.stage == .retiringEditor {
                try Task.checkCancellation()
                #if DEBUG
                try SFTPRetainedRemovalQualification.shared.reach(.beforeEditor)
                #endif
                var next = owner.editors.snapshot
                guard let index = next.records.firstIndex(where: { $0.id == intent.editor.id }) else { throw SFTPSharedBudgetFailure.stale }
                if next.records[index].phase != .closedUnused {
                    guard next.revision < UInt64.max else { throw SFTPSharedBudgetFailure.capacity }
                    next.records[index].body = nil; next.records[index].bodyID = nil; next.records[index].recovery = []; next.records[index].journals = []
                    next.records[index].phase = .closedUnused; next.revision += 1; try owner.editors.commit(next)
                }
                #if DEBUG
                try SFTPRetainedRemovalQualification.shared.reach(.editorCommitted)
                #endif
                try owner.setStage(intent.editor.id, .releasingCharges); intent.stage = .releasingCharges
            }
            try Task.checkCancellation(); try owner.validateGraph()
            #if DEBUG
            try SFTPRetainedRemovalQualification.shared.reach(.beforeCharges)
            #endif
            var next = owner.transaction.document
            for index in next.bodies.indices where intent.bodies.contains(where: { $0.reference.id == next.bodies[index].id }) { next.bodies[index].phase = .removed }
            next.retirements?.removeAll { $0.editor.id == intent.editor.id }; try owner.transaction.commit(next)
            #if DEBUG
            try SFTPRetainedRemovalQualification.shared.reach(.chargesCommitted)
            #endif
            return []
        }
    }
    #if DEBUG
    var drainingForQualification: Bool { lock.withLock { draining > 0 } }
    #endif
    func stopAndDrain() async {
        let held = lock.withLock { draining += 1; return active }; held?.1.cancel()
        if let held { _ = try? await held.1.value }
        lock.withLock { if active?.0 == held?.0 { active = nil }; draining -= 1 }
    }
}
