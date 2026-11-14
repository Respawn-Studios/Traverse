import CryptoKit
import Darwin
import Foundation
import FileOperations

@_spi(Qualification) public enum SFTPInPlaceRecoveryVersion: Sendable, Equatable { case before, edited }
@_spi(Qualification) public enum SFTPInPlaceRecoveryOutcome: Sendable, Equatable { case retainedRead, notStarted, needsReview, verified }

/// Bounded presentation only, derived from the discovery-validated witness.
/// These strings are never remote/local lookup, mutation or admission authority.
@_spi(Qualification) public struct SFTPInPlaceRecoveryPresentation: Sendable, CustomDebugStringConvertible {
    public let fileName: String, server: String, account: String
    public var debugDescription: String { "<retained SFTP presentation>" }
    fileprivate init(_ witness: SFTPInPlaceRecoveryWitness) { self.init(editor: witness.editor) }
    init(editor: SFTPOriginalEditorRecord) {
        func display(_ value: String, limit: Int, unavailable: String) -> String {
            let clean = String(value.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
                    && !(0x202A...0x202E).contains($0.value)
                    && !(0x2066...0x2069).contains($0.value)
            })
            guard !clean.isEmpty else { return unavailable }
            return String(clean.prefix(limit)) + (clean.count > limit ? "…" : "")
        }
        fileName = display(editor.path?.split(separator: "/").last.map(String.init) ?? "",
            limit: 160, unavailable: "File name unavailable")
        let host = editor.context.host
        let hostLabel = host.host.contains(":") ? "[\(host.host)]" : host.host
        server = display(hostLabel + ":\(host.port)", limit: 300, unavailable: "Server unavailable")
        account = display(editor.context.account, limit: 256, unavailable: "Account unavailable")
    }
}

/// A local read capability only. No public initializer, path, lookup UUID,
/// remote token, replay, overwrite or deletion authority is exposed.
@_spi(Qualification) public final class SFTPInPlaceRecoveryChoice: Sendable, CustomDebugStringConvertible {
    public let presentation: SFTPInPlaceRecoveryPresentation
    public let availableVersions: [SFTPInPlaceRecoveryVersion]
    public let outcome: SFTPInPlaceRecoveryOutcome, capturedEditorGeneration: UUID?
    fileprivate let witness: SFTPInPlaceRecoveryWitness
    private let reader: SFTPInPlaceRecoveryReadOwner
    public var debugDescription: String { "<opaque retained SFTP recovery choice>" }
    fileprivate init(witness: SFTPInPlaceRecoveryWitness, reader: SFTPInPlaceRecoveryReadOwner) {
        self.witness = witness; self.reader = reader
        presentation = .init(witness)
        availableVersions = witness.record == nil ? [.before] : [.before, .edited]
        capturedEditorGeneration = witness.record?.editorGeneration
        switch witness.record?.outcome {
        case .verified: outcome = .verified
        case .notStarted: outcome = .notStarted
        case nil: outcome = .retainedRead
        default: outcome = .needsReview
        }
    }
    public func readVersion(_ version: SFTPInPlaceRecoveryVersion) async throws -> TextDocumentValue {
        guard availableVersions.contains(version) else { throw SFTPTextFailure.unsupported }
        return try await reader.read(witness, version: version)
    }
    /// The App retains this exact SH owner through export, preparation and
    /// the actual read-only viewer close. No metadata-only browse opens it.
    public func readPinnedVersion(_ version: SFTPInPlaceRecoveryVersion) async throws -> SFTPInPlaceViewedVersion {
        guard availableVersions.contains(version) else { throw SFTPTextFailure.unsupported }
        return try await reader.readPinned(witness, version: version)
    }
}
/// A single read-only discovery result. An incomplete receive is counted only
/// after its exact closed allocation graph is validated; it is never a choice.
@_spi(Qualification) public struct SFTPInPlaceRecoveryListing: Sendable {
    public let choices: [SFTPInPlaceRecoveryChoice]
    public let incompleteReceiveCount: Int
    init(choices: [SFTPInPlaceRecoveryChoice], incompleteReceiveCount: Int) {
        self.choices = choices; self.incompleteReceiveCount = incompleteReceiveCount
    }
}
@_spi(Qualification) public final class SFTPInPlaceViewedVersion: Sendable {
    public let contents: TextDocumentValue
    private let pin: SFTPOriginalLifetimePin
    fileprivate init(contents: TextDocumentValue, pin: SFTPOriginalLifetimePin) {
        self.contents = contents; self.pin = pin
    }
    public func closeAndDrain() async -> Bool { await pin.closeAndDrain() }
    #if DEBUG && !SFTP_PARENT_STANDALONE
    /// Inspect the actual viewed body's minted SH owner, then make one
    /// independent nonmutating EX attempt on its checked owner.lock. `held`
    /// is true while this viewer is open and false after its real drain.
    @_spi(Qualification) public func assertGeneratedReadPin(
        generatedCase: ConnectionWorkspaceGeneratedCase, held: Bool) async throws {
        let owner = pin
        try await Task.detached {
            try generatedCase.validate()
            guard owner.layout.bodies == generatedCase.layout.persistentConnectionWorkspaceDirectory.appendingPathExtension("original-bodies"),
                  owner.layout.storage.workspaceWitness?.access == .coldRecovery,
                  owner.layout.storage.workspaceWitness?.paths == ConnectionWorkspacePaths(generatedCase.layout) else {
                throw SFTPTextFailure.changed
            }
            guard try owner.generatedQualificationIsOpen() == held else { throw SFTPTextFailure.changed }
            let pool = try ConnectionWorkspaceDisk.openDirectory(owner.layout.bodies)
            defer { Darwin.close(pool) }
            let name = "download-" + owner.reference.id.uuidString
            let record = try DownloadDisk.record(pool, name: name)
            guard record.summary.id == owner.reference.id, record.summary.active == held,
                  let expected = record.files["owner.lock"] else { throw SFTPTextFailure.changed }
            let folder = openat(pool, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard folder >= 0 else { throw SFTPTextFailure.changed }
            defer { Darwin.close(folder) }
            guard try DownloadDisk.identity(folder) == record.folder else { throw SFTPTextFailure.changed }
            let contender = openat(folder, "owner.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard contender >= 0 else { throw SFTPTextFailure.changed }
            defer { Darwin.close(contender) }
            var facts = stat()
            guard fstat(contender, &facts) == 0, DownloadDisk.privateFile(facts), facts.st_size == 0,
                  try DownloadDisk.identity(contender) == expected,
                  fstatat(folder, "owner.lock", &facts, AT_SYMLINK_NOFOLLOW) == 0,
                  DownloadDisk.privateFile(facts), DownloadDisk.Identity(facts) == expected else {
                throw SFTPTextFailure.changed
            }
            let acquired = flock(contender, LOCK_EX | LOCK_NB) == 0
            let blocked = !acquired && errno == EWOULDBLOCK
            if acquired { _ = flock(contender, LOCK_UN) }
            guard (held ? blocked : acquired),
                  try DownloadDisk.identity(contender) == expected else { throw SFTPTextFailure.changed }
            try generatedCase.validate()
        }.value
    }
    #endif
}
/// Captured from the real document's initial admitted baseline and retained
/// independently of its later consumed/nil baseline. Never public lookup input.
struct SFTPInPlaceRecoveryOrigin: Sendable {
    fileprivate let editor: UUID, session: UUID, owner: UUID, budget: UUID, context: Data
    private init(_ baseline: SFTPInPlaceBaseline) {
        editor = baseline.editorID; session = baseline.session; owner = baseline.storageOwner.catalogID
        budget = baseline.storageOwner.budgetID; context = baseline.storageOwner.contextDigest
    }
    static func capture(_ baseline: SFTPInPlaceBaseline) -> Self { .init(baseline) }
}
fileprivate struct SFTPInPlaceRecoveryStamp: Sendable, Equatable {
    let ledger: RemoteSettingsReadIdentity, editors: RemoteSettingsReadIdentity, journal: RemoteSettingsReadIdentity?
    let budgetRevision: UInt64, editorRevision: UInt64, journalRevision: UInt64?
}
fileprivate struct SFTPInPlaceRecoveryWitness: Sendable {
    let layout: SFTPSharedBudgetLayout, stamp: SFTPInPlaceRecoveryStamp, budget: UUID, owner: UUID
    let editor: SFTPOriginalEditorRecord, record: SFTPInPlaceRecord?, connection: SFTPInPlaceRecoveryConnectionIdentity, before: SFTPInPlaceRecoveryBodyAuthority
    let edited: SFTPInPlaceRecoveryBodyAuthority?
}
fileprivate struct SFTPInPlaceRecoveryConnectionIdentity: Sendable, Equatable {
    let values: [UInt64]
    init(_ record: SMBCatalogFiles.Record?) throws {
        guard let record else { values = []; return }
        guard let lease = record.files["owner.lock"], let marker = record.files["session.meta"] else { throw SFTPTextFailure.changed }
        // Directory/lease/marker anchor the actual connection owner. The live
        // SQLite contents may change through ordinary navigation independently.
        values = [record.directory, lease, marker].flatMap { [UInt64(truncatingIfNeeded: $0.device), UInt64($0.inode)] }
    }
}
/// Constructor is private to validated metadata discovery. The actual body
/// opener checks these exact marker/owner/filesystem identities while acquiring
/// its real lease. A body UUID or caller bool cannot stand in for this proof.
struct SFTPInPlaceRecoveryBodyAuthority: @unchecked Sendable {
    let budget: UUID, owner: UUID, reference: SFTPOriginalSpoolReference, record: DownloadDisk.Record
    fileprivate init(budget: UUID, owner: UUID, reference: SFTPOriginalSpoolReference, record: DownloadDisk.Record) {
        self.budget = budget; self.owner = owner; self.reference = reference; self.record = record
    }
    func validate(record actual: DownloadDisk.Record, reference: SFTPOriginalSpoolReference) throws {
        let marker = try JSONDecoder().decode(DownloadDisk.Marker.self, from: actual.marker)
        guard self.reference == reference, actual.folder == record.folder, actual.marker == record.marker, actual.files == record.files,
              actual.summary.id == reference.id, actual.summary.expectedBytes == reference.logicalBytes,
              !actual.summary.isFolder, marker.version == 3, marker.originalBudget == budget, marker.originalOwner == owner else { throw SFTPTextFailure.changed }
    }
}
/// Real read owners and the outermost actual metadata pool lock. Discovery is
/// read-only: no transaction admission/migration/repair/cleanup is invoked.
final class SFTPInPlaceRecoveryMetadata: @unchecked Sendable {
    private let layout: SFTPSharedBudgetLayout, pool: Int32, poolLock: Int32
    private let budgetOwner: SFTPSharedBudgetTransaction
    private let ledger: RemoteSettingsFile<SFTPSharedBudgetDocument>, editors: RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>
    private let journal: RemoteSettingsFile<SFTPInPlaceJournalDocument>?
    private let workspaceLease: ConnectionWorkspaceRecordLease?
    private let incompleteReceives: SFTPIncompleteReceiveDiscovery
    private var commonReleased = false, closed = false
    private init?(layout: SFTPSharedBudgetLayout) throws {
        guard !Thread.isMainThread else { throw SFTPTextFailure.busy }
        let workspace = try layout.storage.beginWorkspaceTransaction(); var workspaceTransferred = false
        defer { if !workspaceTransferred { workspace?.close() } }
        guard let pool = try SMBCatalogFiles.openPool(layout.metadata, create: false) else {
            for sibling in [layout.ledger, layout.bodies, layout.editors, layout.journal] {
                var facts = stat(); errno = 0
                guard lstat(sibling.path, &facts) < 0, errno == ENOENT else { throw RemoteSettingsFailure.recoveryRequired }
            }
            return nil
        }
        var descriptors = [pool], keep = false
        var heldBudget: SFTPSharedBudgetTransaction?
        var heldEditors: RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>?, heldJournal: RemoteSettingsFile<SFTPInPlaceJournalDocument>?
        defer { if !keep { heldJournal?.close(); heldEditors?.close(); heldBudget?.close(); descriptors.forEach { Darwin.close($0) } } }
        let lock = try SMBCatalogFiles.lockPool(pool, create: false); descriptors.append(lock)
        try workspace?.validateCurrent()
        try SMBCatalogFiles.validatePool(pool, at: layout.metadata)
        // Reuse Source7's ACTUAL read-only transaction inventory/cap checks;
        // ownsPool is false because this exact owner retains the outer fds.
        let transaction = try SFTPSharedBudgetTransaction.existing(layout: layout, pool: pool, guardFD: lock, writing: false)
        heldBudget = transaction
        let ledger = transaction.file
        guard !ledger.snapshot.metadata.contains(where: { [.allocating, .removalPending].contains($0.phase) }),
              !ledger.snapshot.bodies.contains(where: { $0.phase == .removalPending }) else {
            throw RemoteSettingsFailure.recoveryRequired
        }
        heldEditors = try RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>.open(layout.editors, writing: false)
        guard let editors = heldEditors else {
            // Missing editor state is clean only if no body/journal history
            // exists. Never treat an unfamiliar existing namespace as empty.
            heldJournal = try RemoteSettingsFile<SFTPInPlaceJournalDocument>.open(layout.journal, writing: false)
            guard ledger.snapshot.bodies.isEmpty, heldJournal == nil else { throw RemoteSettingsFailure.recoveryRequired }
            return nil
        }
        try editors.validateCurrent(); _ = try editors.snapshot.encoded()
        heldJournal = try RemoteSettingsFile<SFTPInPlaceJournalDocument>.open(layout.journal, writing: false)
        if let journal = heldJournal { try journal.validateCurrent(); _ = try journal.snapshot.encoded() }
        let incomplete = try SFTPIncompleteReceiveDiscovery.inspect(transaction: transaction,
            editors: editors.snapshot, journal: heldJournal?.snapshot)
        self.layout = layout; self.pool = pool; poolLock = lock; self.budgetOwner = transaction; self.ledger = ledger; self.editors = editors; journal = heldJournal
        incompleteReceives = incomplete
        workspaceLease = workspace; workspaceTransferred = true; keep = true
    }
    private func stamp() throws -> SFTPInPlaceRecoveryStamp {
        try workspaceLease?.validateCurrent()
        return .init(ledger: try ledger.recoveryReadIdentity(), editors: try editors.recoveryReadIdentity(), journal: try journal?.recoveryReadIdentity(),
            budgetRevision: ledger.snapshot.revision, editorRevision: editors.snapshot.revision, journalRevision: journal?.snapshot.revision)
    }
    private func releaseCommon() { if !commonReleased { commonReleased = true; Darwin.close(poolLock) } }
    private func close() {
        guard !closed else { return }; closed = true
        journal?.close(); editors.close(); budgetOwner.close(); releaseCommon(); Darwin.close(pool); workspaceLease?.close()
    }
    private func metadataOwner(_ editor: SFTPOriginalEditorRecord) throws -> (charge: SharedMetadataCharge, identity: SFTPInPlaceRecoveryConnectionIdentity) {
        let context = try SFTPSharedBudgetTransaction.contextDigest(editor.context)
        let owners = ledger.snapshot.metadata.filter { $0.kind == .original && $0.session == editor.session && $0.context == context }
        guard owners.count == 1, let owner = owners.first, [.live, .orphan, .removed].contains(owner.phase) else { throw SFTPTextFailure.changed }
        let record: SMBCatalogFiles.Record?
        if owner.phase == .removed {
            var value = stat(); errno = 0
            guard fstatat(pool, "session-" + owner.id.uuidString, &value, AT_SYMLINK_NOFOLLOW) < 0, errno == ENOENT else { throw SFTPTextFailure.changed }
            record = nil
        } else {
            record = try SMBCatalogFiles.record(pool, name: "session-" + owner.id.uuidString)
        }
        return (owner, try .init(record))
    }
    private func body(_ reference: SFTPOriginalSpoolReference, owner: UUID) throws -> SFTPInPlaceRecoveryBodyAuthority {
        guard let budget = ledger.snapshot.budgetID,
              ledger.snapshot.bodies.contains(where: { $0.id == reference.id && $0.owner == owner && $0.phase == .allocated && $0.expectedBytes == reference.logicalBytes }) else { throw SFTPTextFailure.changed }
        guard let pool = try SMBCatalogFiles.openPool(layout.bodies, create: false) else { throw SFTPTextFailure.changed }; defer { Darwin.close(pool) }
        let lock = try SMBCatalogFiles.lockPool(pool, create: false); defer { Darwin.close(lock) }
        guard try SFTPSharedBudgetTransaction.readFence(pool, name: SFTPSharedBudgetTransaction.bodyFence, prefix: "MEXSHAREDBODY1") == budget else { throw SFTPTextFailure.changed }
        let first = try DownloadDisk.record(pool, name: "download-" + reference.id.uuidString)
        let record: DownloadDisk.Record
        if first.summary.active {
            // A live editor/viewer SH is compatible with another checked
            // recovery view. An actual EX writer refuses this SH acquisition.
            let folder = openat(pool, first.name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard folder >= 0, let expected = first.files["owner.lock"] else { throw SFTPTextFailure.changed }
            defer { Darwin.close(folder) }
            let held = try DownloadDisk.SharedOriginalLease.acquire(folder: folder, expected: expected)
            defer { _ = held.closeAfterDrain() }
            record = try DownloadDisk.record(pool, name: first.name, heldReadLease: held)
            guard record.folder == first.folder, record.marker == first.marker,
                  record.files == first.files else { throw SFTPTextFailure.changed }
        } else { record = first }
        let proof = SFTPInPlaceRecoveryBodyAuthority(budget: budget, owner: owner, reference: reference, record: record)
        try proof.validate(record: record, reference: reference); return proof
    }
    private func choices(origin: SFTPInPlaceRecoveryOrigin?, reader: SFTPInPlaceRecoveryReadOwner) throws -> SFTPInPlaceRecoveryListing {
        try Task.checkCancellation(); let stamp = try stamp(), saves = journal?.snapshot.records ?? []
        // Every referenced save must match exactly one existing document. No
        // skipping unknown/dangling rows or adopting another session's bytes.
        for save in saves {
            let matches = editors.snapshot.records.filter { $0.journals.contains(save.id) }
            guard matches.count == 1, let editor = matches.first, editor.session == save.session, editor.context == save.context,
                  editor.path == save.path, editor.recovery.contains(save.baseline), editor.recovery.contains(save.edited) else { throw SFTPTextFailure.changed }
        }
        var result: [SFTPInPlaceRecoveryChoice] = []
        for editor in editors.snapshot.records where editor.phase != .closedUnused {
            try Task.checkCancellation()
            guard Set(editor.journals) == Set(saves.filter { $0.session == editor.session && editor.journals.contains($0.id) }.map(\.id)) else { throw RemoteSettingsFailure.recoveryRequired }
            if incompleteReceives.editorIDs.contains(editor.id) { continue }
            if let origin, editor.id != origin.editor { continue }
            guard let initial = editor.body else { throw RemoteSettingsFailure.recoveryRequired }
            let validated = try metadataOwner(editor), owner = validated.charge
            if let origin {
                guard editor.session == origin.session, owner.id == origin.owner, ledger.snapshot.budgetID == origin.budget,
                      try SFTPSharedBudgetTransaction.contextDigest(editor.context) == origin.context else { throw SFTPTextFailure.changed }
            }
            guard [.admitted, .readyToAccept, .saveReferenced, .retainedReleasePending, .recoveryOnly, .releasePending].contains(editor.phase) else { throw SFTPTextFailure.busy }
            let changes = saves.filter { editor.journals.contains($0.id) }
            if !changes.isEmpty {
                guard editor.recovery.contains(initial), editor.recovery.allSatisfy({ ref in changes.contains(where: { $0.baseline == ref || $0.edited == ref }) }) else { throw RemoteSettingsFailure.recoveryRequired }
            }
            if changes.isEmpty {
                guard editor.recovery.isEmpty else { throw RemoteSettingsFailure.recoveryRequired }
                let proof = try body(initial, owner: owner.id)
                result.append(.init(witness: .init(layout: layout, stamp: stamp, budget: proof.budget, owner: owner.id,
                    editor: editor, record: nil, connection: validated.identity, before: proof, edited: nil), reader: reader))
            } else {
                for save in changes {
                    let before = try body(save.baseline, owner: owner.id), edited = try body(save.edited, owner: owner.id)
                    result.append(.init(witness: .init(layout: layout, stamp: stamp, budget: before.budget, owner: owner.id,
                        editor: editor, record: save, connection: validated.identity, before: before, edited: edited), reader: reader))
                }
            }
        }
        guard result.count <= 64 else { throw SFTPTextFailure.full }
        return .init(choices: result, incompleteReceiveCount: incompleteReceives.editorIDs.count)
    }
    static func discover(layout: SFTPSharedBudgetLayout, origin: SFTPInPlaceRecoveryOrigin?, reader: SFTPInPlaceRecoveryReadOwner) throws -> SFTPInPlaceRecoveryListing {
        try Task.checkCancellation(); guard let owner = try Self(layout: layout) else { return .init(choices: [], incompleteReceiveCount: 0) }
        defer { owner.close() }; return try owner.choices(origin: origin, reader: reader)
    }
    fileprivate static func read(_ witness: SFTPInPlaceRecoveryWitness, version: SFTPInPlaceRecoveryVersion) async throws -> SFTPInPlaceViewedVersion {
        try Task.checkCancellation(); guard let owner = try Self(layout: witness.layout) else { throw SFTPTextFailure.changed }; defer { owner.close() }
        guard try owner.stamp() == witness.stamp,
              owner.editors.snapshot.records.contains(witness.editor), owner.ledger.snapshot.budgetID == witness.budget,
              try owner.metadataOwner(witness.editor).charge.id == witness.owner,
              try owner.metadataOwner(witness.editor).identity == witness.connection else { throw SFTPTextFailure.changed }
        if let record = witness.record { guard owner.journal?.snapshot.records.contains(record) == true else { throw SFTPTextFailure.changed } }
        let authority: SFTPInPlaceRecoveryBodyAuthority
        switch version { case .before: authority = witness.before; case .edited: guard let edited = witness.edited else { throw SFTPTextFailure.unsupported }; authority = edited }
        let current = try owner.body(authority.reference, owner: witness.owner); try authority.validate(record: current.record, reference: authority.reference)
        // Mint SH under the validated metadata/editor readers and one actual
        // body-pool EX owner. No deletion can fit between proof and pin.
        let pin: SFTPOriginalLifetimePin = try {
            guard let pool = try SMBCatalogFiles.openPool(witness.layout.bodies, create: false) else { throw SFTPTextFailure.changed }
            defer { Darwin.close(pool) }
            let bodyOwner = try SFTPOriginalBodyPoolExclusive(pool: pool)
            return try SFTPOriginalLifetimePin.openForRecovery(authority, layout: witness.layout,
                pool: pool, bodyOwner: bodyOwner)
        }()
        do {
        let body = try await SFTPOriginalRecoveryRead.openForInPlaceRecovery(directory: witness.layout.bodies, reference: authority.reference, authority: authority)
        // Body lease and the actual read-only reference owners now protect this
        // exact copy; release the outer common lock before bounded body I/O.
        owner.releaseCommon()
        do {
            #if DEBUG
            try SFTPInPlaceRecoveryQualification.shared.reach(.bodyPinned)
            #endif
            try Task.checkCancellation(); let contents = try await body.read(); try Task.checkCancellation()
            #if DEBUG
            try SFTPInPlaceRecoveryQualification.shared.reach(.bodyRead)
            #endif
            guard try owner.stamp() == witness.stamp else { throw SFTPTextFailure.changed }
            await body.closeAndDrain(); return .init(contents: contents, pin: pin)
        } catch { await body.closeAndDrain(); throw error }
        } catch { _ = await pin.closeAndDrain(); throw error }
    }
}
/// One retained explicit discovery/read per concrete owner. Ordinary Stop
/// joins the actual local task and permits later explicit reads. A document's
/// native-buffer handoff permanently seals its own reader and joins work that
/// was active when the seal became visible.
final class SFTPInPlaceRecoveryReadOwner: @unchecked Sendable {
    private enum Value: Sendable {
        case listing(SFTPInPlaceRecoveryListing), viewed(SFTPInPlaceViewedVersion), contents(TextDocumentValue)
    }
    private let lock = NSLock()
    private var active: (UUID, Task<Value, Error>)?
    private var sealedTask: (UUID, Task<Value, Error>)?
    private var drainers = 0
    private var sealed = false
    private var drainUncertain = false
    private func markDrainUncertain() { lock.withLock { drainUncertain = true } }
    func discover(layout: SFTPSharedBudgetLayout, origin: SFTPInPlaceRecoveryOrigin?) async throws -> [SFTPInPlaceRecoveryChoice] {
        let value = try await perform { [self] in .listing(try SFTPInPlaceRecoveryMetadata.discover(layout: layout, origin: origin, reader: self)) }
        guard case .listing(let listing) = value else { throw SFTPTextFailure.changed }; return listing.choices
    }
    /// Workspace cold review registers the ACTUAL task before it validates
    /// the location record. Stop therefore joins metadata setup as well.
    func discoverPrepared(_ prepare: @escaping @Sendable () throws -> SFTPSharedBudgetLayout?) async throws -> SFTPInPlaceRecoveryListing {
        let value = try await perform { [self] in
            guard let layout = try prepare() else { return .listing(.init(choices: [], incompleteReceiveCount: 0)) }
            try Task.checkCancellation()
            return .listing(try SFTPInPlaceRecoveryMetadata.discover(layout: layout, origin: nil, reader: self))
        }
        guard case .listing(let listing) = value else { throw SFTPTextFailure.changed }; return listing
    }
    fileprivate func read(_ witness: SFTPInPlaceRecoveryWitness, version: SFTPInPlaceRecoveryVersion) async throws -> TextDocumentValue {
        let value = try await perform { [self] in
            let viewed = try await SFTPInPlaceRecoveryMetadata.read(witness, version: version)
            guard await viewed.closeAndDrain() else {
                markDrainUncertain()
                throw SFTPTextFailure.changed
            }
            return .contents(viewed.contents)
        }
        guard case .contents(let contents) = value else { throw SFTPTextFailure.changed }
        return contents
    }
    fileprivate func readPinned(_ witness: SFTPInPlaceRecoveryWitness,
                                version: SFTPInPlaceRecoveryVersion) async throws -> SFTPInPlaceViewedVersion {
        let value = try await perform { .viewed(try await SFTPInPlaceRecoveryMetadata.read(witness, version: version)) }
        guard case .viewed(let viewed) = value else { throw SFTPTextFailure.changed }; return viewed
    }
    private func perform(_ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let (id, task) = try lock.withLock { () throws -> (UUID, Task<Value, Error>) in
            guard !sealed else { throw SFTPTextFailure.closed }
            guard !drainUncertain else { throw SFTPTextFailure.changed }
            guard active == nil, drainers == 0 else { throw SFTPTextFailure.busy }; let id = UUID()
            let task = Task.detached(priority: .utility) { try Task.checkCancellation(); return try await work() }
            active = (id, task); return (id, task)
        }
        defer { lock.withLock { if active?.0 == id { active = nil } } }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            let (wasSealed, wasDraining) = lock.withLock { () -> (Bool, Bool) in
                if active?.0 == id { active = nil }
                return (sealed, drainers > 0)
            }
            if Task.isCancelled || wasSealed || wasDraining {
                if case .viewed(let viewed) = result {
                    if !(await viewed.closeAndDrain()) { markDrainUncertain() }
                }
                if wasSealed { throw SFTPTextFailure.closed }
                throw CancellationError()
            }
            return result
        } onCancel: { task.cancel() }
    }
    /// Synchronous admission cut. The captured task remains reachable even if
    /// its waiter finishes before the following async drain begins.
    func seal() {
        let held = lock.withLock { () -> (UUID, Task<Value, Error>)? in
            sealed = true
            if sealedTask == nil { sealedTask = active }
            return sealedTask
        }
        held?.1.cancel()
    }
    private func drain(_ held: (UUID, Task<Value, Error>)?) async -> Bool {
        held?.1.cancel()
        guard let held else { return true }
        do {
            let result = try await held.1.value
            if case .viewed(let viewed) = result {
                let drained = await viewed.closeAndDrain()
                if !drained { markDrainUncertain() }
                return drained
            }
        } catch { /* The task has ended; its own error path owns any pin drain. */ }
        return true
    }
    func sealAndDrain() async -> Bool {
        seal()
        let held = lock.withLock { drainers += 1; return sealedTask }
        let drained = await drain(held)
        lock.withLock {
            if active?.0 == held?.0 { active = nil }
            if drained, sealedTask?.0 == held?.0 { sealedTask = nil }
            drainers -= 1
        }
        let uncertain = lock.withLock { drainUncertain }
        return drained && !uncertain
    }
    func stopAndDrain() async {
        let held = lock.withLock { drainers += 1; return active }
        _ = await drain(held)
        lock.withLock { if active?.0 == held?.0 { active = nil }; drainers -= 1 }
    }
}

#if DEBUG
enum SFTPInPlaceRecoveryStage: Sendable { case bodyPinned, bodyRead }
final class SFTPInPlaceRecoveryQualification: @unchecked Sendable {
    static let shared = SFTPInPlaceRecoveryQualification()
    private let lock = NSLock(); private var probe: (@Sendable (SFTPInPlaceRecoveryStage) throws -> Void)?
    func set(_ probe: (@Sendable (SFTPInPlaceRecoveryStage) throws -> Void)?) { lock.withLock { self.probe = probe } }
    func reach(_ stage: SFTPInPlaceRecoveryStage) throws { let held = lock.withLock { probe }; try held?(stage) }
}
#endif
