import Darwin
import Foundation

/// Compatibility evidence selected by the application, never execution authority.
/// The development build supplies its locally qualified volume identifiers.
public struct QualifiedCopyPreviewScope: Sendable, Equatable {
    internal let volumes: Set<Data>
    internal let historyVolume: Data
    public init?(volumes: Set<UUID>, historyVolume: UUID) {
        guard volumes.count == 2, volumes.contains(historyVolume),
              !volumes.contains(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))) else { return nil }
        self.volumes = Set(volumes.map(Self.bytes)); self.historyVolume = Self.bytes(historyVolume)
    }
    private static func bytes(_ id: UUID) -> Data { var raw = id.uuid; return withUnsafeBytes(of: &raw) { Data($0) } }
    internal func permits(_ volume: NativeRenameVolume) -> Bool { volumes.contains(volume.uuid) }
}

/// Local preference receipt. Decoding it does not grant a session: rebinding
/// requires the original catalog objects, owner and currently qualified volume.
public struct CopyPreviewActivationReceipt: Codable, Equatable, Sendable {
    internal let version: Int
    internal let owner: UUID
    internal let root: EntrySnapshot
    internal let marker: EntrySnapshot
    internal let database: EntrySnapshot
    internal let volumes: Set<Data>
    internal let historyVolume: Data
}

public struct CopyPreviewDisclosure: Sendable {
    public let previousCatalogVersion: Int?
    public var requiresHistoryUpgrade: Bool { ![4, 7, 9, 10].contains(previousCatalogVersion ?? -1) }
}
public enum CopyPreviewHistoryChange: Sendable, Equatable { case none, prepared, upgraded, uncertain }
public enum CopyPreviewActivationOutcome: Sendable, Equatable {
    case enabled
    case cancelled
    case notIdle
    case qualificationUnavailable
    case notEnabled(history: CopyPreviewHistoryChange, savedChoiceMayRemain: Bool)
}

internal struct ProductionCopySession: Sendable {
    let directory: URL
    let receipt: CopyPreviewActivationReceipt
    let scope: QualifiedCopyPreviewScope
    let volume: NativeRenameVolume

    func checkedHistory() throws -> DirectoryAnchor {
        let anchor = try DirectoryAnchor(directory, resolve: false)
        var st = stat()
        guard fstat(anchor.fd, &st) == 0, st.st_uid == geteuid(), st.st_mode & 0o077 == 0,
              anchor.identity.sameObject(as: receipt.root),
              try EntrySnapshot(parent: anchor.fd, name: ".mac-explorer-journal-v1") == receipt.marker,
              try EntrySnapshot(parent: anchor.fd, name: SQLiteJournalStore.name).sameObject(as: receipt.database),
              receipt.version == 1, receipt.volumes == scope.volumes, receipt.historyVolume == scope.historyVolume,
              try NativeRenameVolume.qualified(in: anchor) == volume, volume.uuid == scope.historyVolume else {
            throw FileOperationFailure.recoveryUncertain
        }
        for name in [".mac-explorer-journal-v1", ".mac-explorer-sqlite-v2", ".mac-explorer-sqlite-ready-v2"] {
            guard try OperationJournal.read(name: name, anchor: anchor) == Data(receipt.owner.uuidString.utf8) else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
        try anchor.validate(); return anchor
    }

    static func bind(_ directory: URL, scope: QualifiedCopyPreviewScope,
                     receipt expected: CopyPreviewActivationReceipt? = nil,
                     cancellation: OperationCancellation) throws -> Self {
        let inspection = try OperationHistoryInspector.inspect(directory, cancellation: cancellation)
        guard [OperationHistoryReadiness.available(catalogVersion: 4), .available(catalogVersion: 7), .available(catalogVersion: 9), .available(catalogVersion: 10)].contains(inspection.readiness), inspection.refusedEntries.isEmpty else {
            throw FileOperationFailure.recoveryUncertain
        }
        let anchor = try DirectoryAnchor(directory, resolve: false)
        guard let volume = try NativeRenameVolume.qualified(in: anchor), volume.uuid == scope.historyVolume,
              let text = String(data: try OperationJournal.read(name: ".mac-explorer-journal-v1", anchor: anchor), encoding: .utf8),
              let owner = UUID(uuidString: text) else { throw FileOperationFailure.unsupported }
        let receipt = CopyPreviewActivationReceipt(version: 1, owner: owner, root: anchor.identity,
            marker: try EntrySnapshot(parent: anchor.fd, name: ".mac-explorer-journal-v1"),
            database: try EntrySnapshot(parent: anchor.fd, name: SQLiteJournalStore.name),
            volumes: scope.volumes, historyVolume: scope.historyVolume)
        if let expected {
            guard expected.version == 1, expected.owner == receipt.owner, expected.root.sameObject(as: receipt.root),
                  expected.marker == receipt.marker, expected.database.sameObject(as: receipt.database),
                  expected.volumes == receipt.volumes, expected.historyVolume == receipt.historyVolume else {
                throw FileOperationFailure.recoveryUncertain
            }
        }
        let session = Self(directory: directory, receipt: receipt, scope: scope, volume: volume)
        _ = try session.checkedHistory(); return session
    }
}

/// Holds the original OS owner lock across preference acknowledgement. It has
/// no writable SQLite connection and is touched serially by activation only.
private final class PreviewHistoryLease: @unchecked Sendable {
    let session: ProductionCopySession
    let anchor: DirectoryAnchor
    private var fd: Int32 = -1
    private let entries: [String: EntrySnapshot]

    init(_ session: ProductionCopySession, cancellation: OperationCancellation) throws {
        self.session = session; anchor = try session.checkedHistory()
        entries = try Self.snapshot(anchor, cancellation: cancellation)
        fd = openat(anchor.fd, ".mac-explorer-journal-v1", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }
        do {
            guard flock(fd, LOCK_EX | LOCK_NB) == 0,
                  try EntrySnapshot(fd: fd) == session.receipt.marker else { throw FileOperationFailure.unavailable }
            try validate(cancellation: cancellation)
        } catch { release(); throw error }
    }
    deinit { release() }
    func release() { if fd >= 0 { close(fd); fd = -1 } }
    func validate(cancellation: OperationCancellation) throws {
        try cancellation.check()
        _ = try session.checkedHistory()
        guard fd >= 0, try EntrySnapshot(fd: fd) == session.receipt.marker,
              try Self.snapshot(anchor, cancellation: cancellation) == entries else { throw FileOperationFailure.sourceChanged }
        let budget = OperationHistoryReadBudget(cancellation: cancellation)
        let store = try SQLiteJournalStore(readOnly: anchor, owner: session.receipt.owner, budget: budget)
        guard [4, 7, 9, 10].contains(store.inspectedCatalogVersion) else { throw FileOperationFailure.recoveryUncertain }
        try store.validateCatalog(cancellation: cancellation)
        try store.validateFiles(); try anchor.validate()
        guard try Self.snapshot(anchor, cancellation: cancellation) == entries else { throw FileOperationFailure.sourceChanged }
    }
    private static func snapshot(_ anchor: DirectoryAnchor, cancellation: OperationCancellation) throws -> [String: EntrySnapshot] {
        let names = try GroupedCopyFilesystemEvidence.children(in: anchor, cancellation: cancellation, limit: 16_384)
        return try Dictionary(uniqueKeysWithValues: names.map { (name: String) in
            try cancellation.check(); return (name, try EntrySnapshot(parent: anchor.fd, name: name))
        })
    }
}

/// The complete pre-consent observation is checked again before a writer opens.
private struct PreviewHistoryObservation: Sendable, Equatable {
    let parent: EntrySnapshot
    let root: EntrySnapshot?
    let entries: [String: EntrySnapshot]
    let readiness: OperationHistoryReadiness

    static func capture(_ directory: URL, scope: QualifiedCopyPreviewScope,
                        cancellation: OperationCancellation) throws -> Self {
        let parent = try DirectoryAnchor(directory.deletingLastPathComponent(), resolve: false)
        guard let volume = try NativeRenameVolume.qualified(in: parent), volume.uuid == scope.historyVolume else {
            throw FileOperationFailure.unsupported
        }
        func snapshot() throws -> (EntrySnapshot?, [String: EntrySnapshot]) {
            let anchor: DirectoryAnchor
            do { anchor = try DirectoryAnchor(directory, resolve: false) }
            catch FileOperationFailure.notFound { try requireAbsent(directory.lastPathComponent, in: parent.fd); return (nil, [:]) }
            let names = try GroupedCopyFilesystemEvidence.children(in: anchor, cancellation: cancellation, limit: 16_384)
            return (anchor.identity, try Dictionary(uniqueKeysWithValues: names.map { ($0, try EntrySnapshot(parent: anchor.fd, name: $0)) }))
        }
        let first = try snapshot()
        let inspection = try OperationHistoryInspector.inspect(directory, cancellation: cancellation)
        let last = try snapshot(); try parent.validate()
        guard first.0 == last.0, first.1 == last.1 else { throw FileOperationFailure.sourceChanged }
        return Self(parent: parent.identity, root: last.0, entries: last.1, readiness: inspection.readiness)
    }
    var version: Int? { if case .available(let version) = readiness { version } else { nil } }
    func matches(_ other: Self) -> Bool {
        parent.sameObject(as: other.parent) && root == other.root && entries == other.entries && readiness == other.readiness
    }
}

private final class PreviewWriterAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var objects: (root: EntrySnapshot, marker: EntrySnapshot)?
    func opened(_ journal: OperationJournal) throws {
        let value = (journal.anchor.identity, try EntrySnapshot(parent: journal.anchor.fd, name: ".mac-explorer-journal-v1"))
        lock.withLock { objects = value }
    }
    func matches(_ current: PreviewHistoryObservation) -> Bool {
        lock.withLock {
            guard let objects, let root = current.root else { return false }
            return objects.root.sameObject(as: root) && objects.marker == current.entries[".mac-explorer-journal-v1"]
        }
    }
}

extension RecoverableFileOperations {
    /// Only this explicit action may prepare/upgrade history for preview. The
    /// reservation blocks this engine from accepting new work throughout consent,
    /// cold validation and acknowledged preference persistence. The app must also
    /// reserve its shared queue, preparation and inspection owners before calling.
    public func activateCopyPreview(
        review: @escaping @Sendable (CopyPreviewDisclosure) async -> Bool,
        persist: @escaping @Sendable (CopyPreviewActivationReceipt?) async throws -> Void
    ) async -> CopyPreviewActivationOutcome {
        guard let scope = qualifiedCopyPreview else { return .qualificationUnavailable }
        guard let token = reserveCopyPreview() else { return .notIdle }
        defer { finishCopyPreviewReservation(token) }
        var initial: PreviewHistoryObservation?
        var lease: PreviewHistoryLease?
        var writerAttempted = false
        var preferenceAttempted = false
        let writer = PreviewWriterAttempt()
        do {
            let observation = try await worker(activation: token) { cancellation in
                try PreviewHistoryObservation.capture(self.directory, scope: scope, cancellation: cancellation)
            }
            initial = observation
            switch observation.readiness {
            case .absent, .available, .legacyImportRequired: break
            default: return .notEnabled(history: .none, savedChoiceMayRemain: false)
            }
            guard await review(CopyPreviewDisclosure(previousCatalogVersion: observation.version)) else { return .cancelled }
            try Task.checkCancellation()
            writerAttempted = true
            let preparedLease = try await worker(activation: token) { cancellation in
                guard observation.matches(try PreviewHistoryObservation.capture(self.directory, scope: scope, cancellation: cancellation)) else {
                    throw FileOperationFailure.sourceChanged
                }
                // The writer is destroyed before the cold, read-only validation.
                let expected = try autoreleasepool {
                    let journal = try OperationJournal(self.directory, hooks: self.hooks.journalHooks, cancellation: cancellation)
                    try writer.opened(journal)
                    try journal.upgradeForGroupedCopy()
                    return try journal.existingGroupedReceipt(scope: scope)
                }
                let session = try ProductionCopySession.bind(self.directory, scope: scope, receipt: expected, cancellation: cancellation)
                return try PreviewHistoryLease(session, cancellation: cancellation)
            }
            lease = preparedLease
            preferenceAttempted = true
            try await persist(preparedLease.session.receipt)
            try await worker(activation: token) { cancellation in
                try preparedLease.validate(cancellation: cancellation)
                try self.installCopyPreview(preparedLease.session, reservation: token)
                preparedLease.release()
            }
            return .enabled
        } catch {
            lease?.release(); lease = nil
            try? installCopyPreview(nil, reservation: token)
            var savedChoiceMayRemain = false
            if preferenceAttempted {
                do { try await persist(nil) } catch { savedChoiceMayRemain = true }
            }
            guard writerAttempted, let initial else {
                return error is CancellationError ? .cancelled : .notEnabled(history: .none, savedChoiceMayRemain: savedChoiceMayRemain)
            }
            let change = (try? await worker(activation: token, ignoringCancellation: true) { cancellation -> CopyPreviewHistoryChange in
                let current = try PreviewHistoryObservation.capture(self.directory, scope: scope, cancellation: cancellation)
                if initial.matches(current) { return .none }
                guard writer.matches(current) else { return .uncertain }
                if current.version == 4 && initial.version != 4 { return .upgraded }
                return current.version != nil ? .prepared : .uncertain
            }) ?? .uncertain
            return .notEnabled(history: change, savedChoiceMayRemain: savedChoiceMayRemain)
        }
    }

    /// Saved-on launch is read-only: missing/old/replaced history cannot be prepared
    /// here. A failure leaves ordinary Copy available and preview authority absent.
    public func rebindCopyPreview(_ receipt: CopyPreviewActivationReceipt) async -> Bool {
        guard let scope = qualifiedCopyPreview, let token = reserveCopyPreview() else { return false }
        defer { finishCopyPreviewReservation(token) }
        do {
            try await worker(activation: token) { cancellation in
                let session = try ProductionCopySession.bind(self.directory, scope: scope, receipt: receipt, cancellation: cancellation)
                // Reopening must validate all old payloads as activation does;
                // passive summaries alone are only a display/readiness hint.
                let lease = try PreviewHistoryLease(session, cancellation: cancellation)
                defer { lease.release() }
                try self.installCopyPreview(session, reservation: token)
            }
            return true
        } catch { try? installCopyPreview(nil, reservation: token); return false }
    }
}
