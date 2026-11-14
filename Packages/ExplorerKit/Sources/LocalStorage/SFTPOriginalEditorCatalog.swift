import CoreFoundation
import CryptoKit
import Darwin
import Foundation

enum SFTPOriginalEditorPhase: String, Codable, Sendable {
    case receiving, bodyAttached, readyToAccept, admitted, releasePending
    case recoveryOnly, saveReferenced, retainedReleasePending, cleanupPending, unadmittedRemovalPending, closedUnused
}

/// Private metadata, never a restored worker capability or a serialized draft.
struct SFTPOriginalEditorRecord: Codable, Equatable, Sendable, CustomDebugStringConvertible {
    let id: UUID, session: UUID, request: UUID, context: SFTPOriginalContext, expectedBytes: UInt64
    var phase = SFTPOriginalEditorPhase.receiving
    var path: String?, bodyID: UUID?, body: SFTPOriginalSpoolReference?
    var recovery: [SFTPOriginalSpoolReference] = []
    var journals: [UUID] = []
    var debugDescription: String { "<SFTP initial editor reference>" }
    func validate() throws {
        try context.validate()
        guard [id, session, request].allSatisfy(SFTPWire.validToken), expectedBytes <= 1 << 20,
              recovery.count <= 8, journals.count <= 64, Set(journals).count == journals.count,
              journals.allSatisfy(SFTPWire.validToken) else { throw RemoteSettingsFailure.invalidRecord }
        if let path {
            guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.utf8.contains(0), path.utf8.count <= 8192,
                  path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  path.split(separator: "/").count <= 127 else { throw RemoteSettingsFailure.invalidRecord }
        }
        if let bodyID { guard SFTPWire.validToken(bodyID) else { throw RemoteSettingsFailure.invalidRecord } }
        if let body { try body.validate(); guard body.id == bodyID else { throw RemoteSettingsFailure.invalidRecord } }
        var refs: [UUID: SFTPOriginalSpoolReference] = [:]
        for ref in recovery + (body.map { [$0] } ?? []) {
            try ref.validate()
            if let existing = refs[ref.id] { guard existing == ref else { throw RemoteSettingsFailure.invalidRecord } }
            refs[ref.id] = ref
        }
        // Whole-document retirement captures at most eight distinct bodies.
        // A current body may duplicate a recovery reference but cannot add a ninth.
        guard refs.count <= 8 else { throw RemoteSettingsFailure.invalidRecord }
        switch phase {
        case .receiving: guard path == nil, bodyID == nil, body == nil, journals.isEmpty, recovery.isEmpty else { throw RemoteSettingsFailure.invalidRecord }
        case .bodyAttached: guard path != nil, bodyID != nil, body == nil, journals.isEmpty, recovery.isEmpty else { throw RemoteSettingsFailure.invalidRecord }
        case .unadmittedRemovalPending: guard path != nil, bodyID != nil, journals.isEmpty, recovery.isEmpty else { throw RemoteSettingsFailure.invalidRecord }
        case .readyToAccept, .releasePending, .cleanupPending:
            guard path != nil, body != nil, journals.isEmpty, recovery.isEmpty else { throw RemoteSettingsFailure.invalidRecord }
        case .admitted: guard path != nil, body != nil else { throw RemoteSettingsFailure.invalidRecord }
        case .saveReferenced, .retainedReleasePending: guard path != nil, body != nil, !journals.isEmpty, !recovery.isEmpty else { throw RemoteSettingsFailure.invalidRecord }
        case .recoveryOnly: guard path != nil, bodyID != nil else { throw RemoteSettingsFailure.invalidRecord }
        case .closedUnused: guard body == nil, bodyID == nil, journals.isEmpty, recovery.isEmpty else { throw RemoteSettingsFailure.invalidRecord }
        }
    }
}

struct SFTPOriginalEditorCatalogDocument: RemoteSettingsDocument, Codable, Sendable, CustomDebugStringConvertible {
    var format = 1, protocolIdentity = "sftp-original-editor-catalog"
    var revision: UInt64 = 0
    var records: [SFTPOriginalEditorRecord] = []
    var debugDescription: String { "<SFTP initial editor catalog>" }
    init() {}
    func encoded() throws -> Data {
        guard format == 1, protocolIdentity == "sftp-original-editor-catalog", records.count <= 64,
              Set(records.map(\.id)).count == records.count else { throw RemoteSettingsFailure.invalidRecord }
        try records.forEach { try $0.validate() }
        var refs: [UUID: SFTPOriginalSpoolReference] = [:]
        for record in records {
            for ref in record.recovery + (record.body.map { [$0] } ?? []) {
                if let old = refs[ref.id] { guard old == ref else { throw RemoteSettingsFailure.invalidRecord } }
                refs[ref.id] = ref
            }
        }
        guard refs.count <= SFTPSharedBudgetDocument.expandedBodySlots,
              refs.values.reduce(UInt64(0), { $0 + $1.logicalBytes + (64 << 10) }) <= 32 << 20 else { throw RemoteSettingsFailure.capacity }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(self); bytes.append(10)
        guard bytes.count <= RemoteSettingsFile<Self>.maximumBytes else { throw RemoteSettingsFailure.capacity }; return bytes
    }
    static func decode(_ bytes: Data) throws -> Self {
        do {
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            guard let version = object?["format"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID() else { throw RemoteSettingsFailure.invalidRecord }
            guard version.intValue == 1, object?["protocolIdentity"] as? String == "sftp-original-editor-catalog" else { throw RemoteSettingsFailure.incompatibleVersion }
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            guard try value.encoded() == bytes else { throw RemoteSettingsFailure.invalidRecord }; return value
        } catch let issue as RemoteSettingsFailure { throw issue }
        catch { throw RemoteSettingsFailure.invalidRecord }
    }
}

/// One fixed body pool and its durable reference graph. No URL is exported.
/// Passive inspection is metadata-only and never creates/repairs a store.
final class SFTPOriginalEditorCatalog: @unchecked Sendable {
    typealias File = RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>
    private let directory: URL, bodyDirectory: URL
    private let executor = UploadLocalExecutor(label: "Traverse.SFTP.Original.EditorCatalog")
    private let probe: File.Probe?
    private var owner: File?
    #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
    private let gateBHookLock = NSLock()
    private var gateBScopedCommit: (@Sendable (UUID, SFTPOriginalSpoolReference) throws -> Void)?
    func installGateBScopedCommit(_ hook: @escaping @Sendable (UUID, SFTPOriginalSpoolReference) throws -> Void) throws {
        try gateBHookLock.withLock {
            guard gateBScopedCommit == nil else { throw RemoteSettingsFailure.busy }
            gateBScopedCommit = hook
        }
    }
    #endif
    let sharedLayout: SFTPSharedBudgetLayout?
    init(bodyDirectory: URL, probe: File.Probe? = nil, sharedLayout: SFTPSharedBudgetLayout? = nil) throws {
        _ = try RemoteDownloadStore(directory: bodyDirectory)
        self.directory = bodyDirectory.appendingPathExtension("original-editors")
        self.bodyDirectory = bodyDirectory; self.probe = probe; self.sharedLayout = sharedLayout
        guard sharedLayout == nil || sharedLayout?.bodies == bodyDirectory else { throw SFTPSharedBudgetFailure.unsafe }
    }
    deinit { let file = owner; executor.enqueueDrain { file?.close() } }
    func validatesPool(_ pool: URL) -> Bool { pool == bodyDirectory }
    func validatesBudget(_ owner: SFTPOriginalStorageOwner) -> Bool { sharedLayout == owner.layout && bodyDirectory == owner.layout.bodies }
    func inspect() async throws -> SFTPOriginalEditorCatalogDocument {
        let (value, late) = try await executor.perform { [self] in
            if let owner { try owner.validateCurrent(); return owner.snapshot }
            guard let file = try File.open(directory, writing: false) else { return SFTPOriginalEditorCatalogDocument() }
            defer { file.close() }; return file.snapshot
        }
        guard !late else { throw RemoteSettingsFailure.cancelled }; return value
    }
    func begin(id: UUID, session: UUID, request: UUID, context: SFTPVerifiedSessionContext, expectedBytes: UInt64) async throws {
        let record = SFTPOriginalEditorRecord(id: id, session: session, request: request,
            context: try SFTPOriginalContext(context), expectedBytes: expectedBytes)
        try await change { document in
            // Only metadata whose exact unused copy was actually removed is pruned.
            document.records.removeAll { $0.phase == .closedUnused }
            guard document.records.count < 64, !document.records.contains(where: { $0.id == id }) else { throw RemoteSettingsFailure.capacity }
            document.records.append(record)
        }
    }
    func attach(_ id: UUID, bodyID: UUID, path: String) async throws {
        try await update(id) { record in
            guard record.phase == .receiving else { throw RemoteSettingsFailure.invalidRecord }
            record.bodyID = bodyID; record.path = path; record.phase = .bodyAttached
        }
    }
    private enum PinTransition: Sendable, Equatable { case ready, continued }
    /// The catalog writer and body-pool EX owner remain held from each durable
    /// body transition through its real owner SH acquisition.
    func readyAndPin(_ id: UUID, reference: SFTPOriginalSpoolReference,
                     storageOwner: SFTPOriginalStorageOwner) async throws -> SFTPOriginalLifetimePin {
        try await transitionAndPin(id, reference: reference, storageOwner: storageOwner, transition: .ready)
    }
    func continuedAndPin(_ id: UUID, reference: SFTPOriginalSpoolReference,
                         storageOwner: SFTPOriginalStorageOwner) async throws -> SFTPOriginalLifetimePin {
        try await transitionAndPin(id, reference: reference, storageOwner: storageOwner, transition: .continued)
    }
    private func transitionAndPin(_ id: UUID, reference: SFTPOriginalSpoolReference,
        storageOwner: SFTPOriginalStorageOwner, transition: PinTransition) async throws -> SFTPOriginalLifetimePin {
        let (pin, late) = try await executor.perform { [self] in
            guard let sharedLayout, sharedLayout == storageOwner.layout,
                  bodyDirectory == sharedLayout.bodies, owner == nil else { throw SFTPSharedBudgetFailure.unsafe }
            try storageOwner.checkLive(); try reference.validate()
            let budget = try SFTPSharedBudgetTransaction.open(layout: sharedLayout, writing: false)
            defer { budget.close() }
            guard budget.document.budgetID == storageOwner.budgetID,
                  let metadata = budget.document.metadata.first(where: { $0.id == storageOwner.catalogID }),
                  metadata.kind == .original, metadata.phase == .live,
                  metadata.session == storageOwner.session, metadata.context == storageOwner.contextDigest,
                  let charge = budget.document.bodies.first(where: { $0.id == reference.id }),
                  charge.owner == storageOwner.catalogID, charge.phase == .allocated,
                  charge.expectedBytes == reference.logicalBytes,
                  !(budget.document.retirements ?? []).contains(where: { $0.editor.id == id })
            else { throw SFTPSharedBudgetFailure.stale }
            guard let editor = try File.open(directory, writing: true, probe: probe) else { throw RemoteSettingsFailure.notOpen }
            defer { editor.close() }
            try editor.validateCurrent()
            var next = editor.snapshot
            guard let index = next.records.firstIndex(where: { $0.id == id }),
                  next.records[index].session == storageOwner.session,
                  try SFTPSharedBudgetTransaction.contextDigest(next.records[index].context) == storageOwner.contextDigest,
                  next.revision < UInt64.max else { throw RemoteSettingsFailure.invalidRecord }
            switch transition {
            case .ready:
                guard next.records[index].phase == .bodyAttached,
                      next.records[index].bodyID == reference.id,
                      next.records[index].expectedBytes == reference.logicalBytes
                else { throw RemoteSettingsFailure.invalidRecord }
            case .continued:
                guard next.records[index].phase == .saveReferenced,
                      next.records[index].recovery.contains(reference),
                      !next.records[index].journals.isEmpty
                else { throw RemoteSettingsFailure.invalidRecord }
            }
            let authority = SFTPOriginalLifetimePinAuthority(layout: sharedLayout,
                budgetID: storageOwner.budgetID, ownerID: storageOwner.catalogID,
                editorID: id, session: storageOwner.session, reference: reference)
            guard let pool = try SMBCatalogFiles.openPool(sharedLayout.bodies, create: false) else { throw SFTPSharedBudgetFailure.recoveryRequired }
            defer { Darwin.close(pool) }
            let bodyOwner = try SFTPOriginalBodyPoolExclusive(pool: pool)
            try bodyOwner.validate(pool: pool)
            guard try SFTPSharedBudgetTransaction.readFence(pool,
                name: SFTPSharedBudgetTransaction.bodyFence, prefix: "MEXSHAREDBODY1") == storageOwner.budgetID
            else { throw SFTPSharedBudgetFailure.stale }
            next.records[index].bodyID = reference.id; next.records[index].body = reference
            next.records[index].phase = transition == .ready ? .readyToAccept : .admitted
            next.revision += 1; _ = try next.encoded(); try editor.commit(next)
            return try SFTPOriginalLifetimePin.open(authority, pool: pool, bodyOwner: bodyOwner)
        }
        // A completed writer action is never rolled back by caller cancellation.
        // The durable reference remains charged and reviewable if late.
        guard !late else { _ = await pin.closeAndDrain(); throw RemoteSettingsFailure.cancelled }
        return pin
    }
    func admitted(_ id: UUID) async throws {
        try await update(id) { record in
            guard record.phase == .readyToAccept else { throw RemoteSettingsFailure.invalidRecord }; record.phase = .admitted
        }
    }
    func retainForRecovery(_ id: UUID) async {
        try? await update(id) { record in
            guard record.phase != .closedUnused else { return }; record.phase = .recoveryOnly
        }
    }
    func removedFailedRead(_ id: UUID, bodyID: UUID) async throws {
        try await update(id) { record in
            if record.phase == .closedUnused, record.body == nil, record.bodyID == nil { return }
            guard [.bodyAttached, .readyToAccept].contains(record.phase), record.bodyID == bodyID,
                  record.journals.isEmpty, record.recovery.isEmpty else { throw RemoteSettingsFailure.busy }
            record.body = nil; record.bodyID = nil; record.phase = .closedUnused
        }
    }
    /// Startup3's sealed no-header rejection. Unlike best-effort shutdown
    /// cleanup this MUST acknowledge the exact durable change or retain review.
    func rejectedBeforeBody(_ id: UUID, session: UUID, request: UUID,
        context: SFTPVerifiedSessionContext, expectedBytes: UInt64) async throws {
        let expected = try SFTPOriginalContext(context)
        try await update(id) { record in
            guard record.session == session, record.request == request, record.context == expected,
                  record.expectedBytes == expectedBytes, record.phase == .receiving,
                  record.path == nil, record.bodyID == nil, record.body == nil,
                  record.journals.isEmpty, record.recovery.isEmpty else { throw RemoteSettingsFailure.busy }
            record.phase = .closedUnused
        }
    }
    func abandonedBeforeBody(_ id: UUID) async {
        try? await update(id) { record in
            guard record.phase == .receiving, record.bodyID == nil, record.body == nil,
                  record.journals.isEmpty, record.recovery.isEmpty else { throw RemoteSettingsFailure.busy }
            record.phase = .closedUnused
        }
    }
    func linkSave(_ id: UUID, record save: SFTPOriginalRecord) async throws {
        try await update(id) { record in
            guard record.phase == .admitted, record.body == save.baseline, record.context == save.context,
                  record.session == save.session else { throw RemoteSettingsFailure.invalidRecord }
            for ref in [save.baseline, save.edited] where !record.recovery.contains(ref) { record.recovery.append(ref) }
            guard !record.journals.contains(save.id) else { throw RemoteSettingsFailure.invalidRecord }
            record.journals.append(save.id); record.phase = .saveReferenced
        }
    }
    func linkInPlaceSave(_ id: UUID, record save: SFTPInPlaceRecord) async throws {
        try save.validate()
        try await update(id) { record in
            guard record.phase == .admitted, record.body == save.baseline, record.context == save.context, record.session == save.session else { throw RemoteSettingsFailure.invalidRecord }
            for ref in [save.baseline, save.edited] where !record.recovery.contains(ref) { record.recovery.append(ref) }
            guard !record.journals.contains(save.id) else { throw RemoteSettingsFailure.invalidRecord }
            record.journals.append(save.id); record.phase = .saveReferenced
        }
    }
    func releasePending(_ id: UUID, reference: SFTPOriginalSpoolReference) async throws {
        try await update(id) { record in
            guard [.admitted, .releasePending].contains(record.phase), record.body == reference, record.journals.isEmpty, record.recovery.isEmpty else { throw RemoteSettingsFailure.busy }
            record.phase = .releasePending
        }
    }
    func retainedReleasePending(_ id: UUID, reference: SFTPOriginalSpoolReference) async throws {
        try await update(id) { record in
            guard [.admitted, .retainedReleasePending].contains(record.phase), record.body == reference,
                  !record.journals.isEmpty, record.recovery.contains(reference) else { throw RemoteSettingsFailure.busy }
            record.phase = .retainedReleasePending
        }
    }
    /// Token invalidation and local-user drain do not retire any Save/history
    /// reference. A durable failure remains reviewable and cannot claim close.
    func closeRetainedAfterDrain(_ id: UUID, reference: SFTPOriginalSpoolReference) async throws {
        try await update(id) { record in
            guard [.retainedReleasePending, .recoveryOnly].contains(record.phase), record.body == reference,
                  !record.journals.isEmpty, record.recovery.contains(reference) else { throw RemoteSettingsFailure.busy }
            record.phase = .recoveryOnly
        }
    }
    /// Caller owns the strict token-release/session-drain receipt and has joined
    /// baseline users. The catalog atomically excludes every other reference.
    func removeUnusedAfterDrain(_ id: UUID, reference: SFTPOriginalSpoolReference) async throws {
        let (_, late) = try await executor.perform { [self] in
            guard let sharedLayout, owner == nil else { throw SFTPSharedBudgetFailure.unsafe }
            let transaction = try SFTPSharedBudgetTransaction.open(layout: sharedLayout, writing: true)
            defer { transaction.close() }
            guard let file = try File.open(directory, writing: true, probe: probe) else { throw RemoteSettingsFailure.notOpen }
            defer { file.close() }
            try file.validateCurrent(); var document = file.snapshot
            do {
                guard let i = document.records.firstIndex(where: { $0.id == id }) else { throw RemoteSettingsFailure.missing }
                let record = document.records[i]
                guard [.releasePending, .cleanupPending].contains(record.phase), record.body == reference,
                      record.journals.isEmpty, record.recovery.isEmpty,
                      !document.records.contains(where: { $0.id != id && ($0.body?.id == reference.id || $0.recovery.contains(where: { $0.id == reference.id })) }) else { throw RemoteSettingsFailure.busy }
                document.records[i].phase = .cleanupPending
            }
            guard document.revision < UInt64.max else { throw RemoteSettingsFailure.capacity }
            document.revision += 1
            #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
            let scoped = gateBHookLock.withLock { gateBScopedCommit }
            try scoped?(id, reference)
            #endif
            try file.commit(document)
            let proof = SFTPOriginalCatalogRetirementProof(file: file, layout: sharedLayout, editorID: id, reference: reference)
            try transaction.removeOriginalBody(reference.id, catalogProof: proof)
        }
        if late { throw RemoteSettingsFailure.cancelled }
    }
    func close() async {
        await executor.drain { [self] in owner?.close(); owner = nil }
    }
    private func update(_ id: UUID, _ body: @escaping @Sendable (inout SFTPOriginalEditorRecord) throws -> Void) async throws {
        try await change { document in
            guard let i = document.records.firstIndex(where: { $0.id == id }) else { throw RemoteSettingsFailure.missing }
            try body(&document.records[i])
        }
    }
    private func change(_ body: @escaping @Sendable (inout SFTPOriginalEditorCatalogDocument) throws -> Void) async throws {
        let (_, late) = try await executor.perform { [self] in try mutate(body) }
        if late { throw RemoteSettingsFailure.cancelled }
    }
    private func mutate(_ body: (inout SFTPOriginalEditorCatalogDocument) throws -> Void) throws {
        guard let sharedLayout else { throw SFTPSharedBudgetFailure.unsafe }
        let budget = try SFTPSharedBudgetTransaction.open(layout: sharedLayout, writing: false)
        defer { budget.close() }
        if owner == nil { owner = try File.open(directory, writing: true, probe: probe) }
        // Every mutation reloads a fresh current revision under the actual
        // cross-process writer lock; no cached stale snapshot can overwrite it.
        defer { owner?.close(); owner = nil }
        guard let owner else { throw RemoteSettingsFailure.notOpen }; try owner.validateCurrent()
        guard owner.snapshot.revision < UInt64.max else { throw RemoteSettingsFailure.capacity }
        let previous = owner.snapshot
        var next = previous; try body(&next)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for record in next.records where previous.records.first(where: { $0.id == record.id }) != record {
            if record.phase == .closedUnused { continue }
            let context = Data(SHA256.hash(data: try encoder.encode(record.context)))
            guard let storageOwner = budget.document.metadata.first(where: {
                $0.kind == .original && $0.session == record.session && $0.context == context
            }), record.phase != .receiving || storageOwner.phase == .live else { throw SFTPSharedBudgetFailure.stale }
            let ids = record.recovery.map(\.id) + (record.bodyID.map { [$0] } ?? [])
            guard ids.allSatisfy({ id in budget.document.bodies.contains(where: {
                $0.id == id && $0.owner == storageOwner.id && $0.phase != .removed
            }) }) else { throw SFTPSharedBudgetFailure.stale }
        }
        let pending = Set((budget.document.retirements ?? []).map { $0.editor.id })
        guard pending.allSatisfy({ id in next.records.first(where: { $0.id == id }) == previous.records.first(where: { $0.id == id }) }) else { throw SFTPSharedBudgetFailure.busy }
        next.revision += 1; _ = try next.encoded(); try owner.commit(next)
        try SFTPSharedBudgetTransaction.validateMetadataFootprint(sharedLayout)
    }
}

/// Only readyAndPin may mint this under the actual ledger, editor writer and
/// body-pool EX owners. Its fields are rechecked against the filesystem while
/// those same locks still exclude removal and new competing constructors.
struct SFTPOriginalLifetimePinAuthority: Sendable {
    let layout: SFTPSharedBudgetLayout, budgetID: UUID, ownerID: UUID
    let editorID: UUID, session: UUID, reference: SFTPOriginalSpoolReference
    fileprivate init(layout: SFTPSharedBudgetLayout, budgetID: UUID, ownerID: UUID,
                     editorID: UUID, session: UUID, reference: SFTPOriginalSpoolReference) {
        self.layout = layout; self.budgetID = budgetID; self.ownerID = ownerID
        self.editorID = editorID; self.session = session; self.reference = reference
    }
    func validate(_ record: DownloadDisk.Record) throws {
        let marker = try JSONDecoder().decode(DownloadDisk.Marker.self, from: record.marker)
        guard record.name == "download-" + reference.id.uuidString,
              record.summary.id == reference.id, !record.summary.isFolder,
              record.summary.expectedBytes == reference.logicalBytes,
              marker.version == 3, marker.originalBudget == budgetID,
              marker.originalOwner == ownerID, record.files["payload"] != nil
        else { throw SFTPSharedBudgetFailure.stale }
    }
}

/// Only this catalog's checked, held writer can mint a retirement proof. It
/// remains held through deletion, catalog commit and ledger charge release.
final class SFTPOriginalCatalogRetirementProof {
    let file: RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>
    private(set) var retained: SFTPRetainedRetirementAuthority?
    let layout: SFTPSharedBudgetLayout, editorID: UUID, reference: SFTPOriginalSpoolReference
    fileprivate init(file: RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>, layout: SFTPSharedBudgetLayout,
                     editorID: UUID, reference: SFTPOriginalSpoolReference) {
        self.file = file; self.layout = layout; self.editorID = editorID; self.reference = reference
    }
    static func retained(_ authority: SFTPRetainedRetirementAuthority, reference: SFTPOriginalSpoolReference) -> SFTPOriginalCatalogRetirementProof {
        let proof = SFTPOriginalCatalogRetirementProof(file: authority.editorFile,
            layout: authority.layout, editorID: authority.intent.editor.id, reference: reference)
        proof.retained = authority; return proof
    }
    var session: UUID? { file.snapshot.records.first(where: { $0.id == editorID })?.session }
    func validate(layout: SFTPSharedBudgetLayout, body: UUID) throws {
        if let retained { try retained.validate(layout: layout, body: body); return }
        try file.validateCurrent()
        guard self.layout == layout, reference.id == body,
              let record = file.snapshot.records.first(where: { $0.id == editorID }), record.phase == .cleanupPending,
              record.body == reference, record.journals.isEmpty, record.recovery.isEmpty else { throw SFTPSharedBudgetFailure.referenced }
    }
    func completeAfterActualDeletion() throws {
        try validate(layout: layout, body: reference.id)
        var document = file.snapshot
        guard let index = document.records.firstIndex(where: { $0.id == editorID }), document.revision < UInt64.max else { throw SFTPSharedBudgetFailure.stale }
        document.records[index].body = nil; document.records[index].bodyID = nil; document.records[index].phase = .closedUnused
        document.revision += 1; try file.commit(document)
    }
}
