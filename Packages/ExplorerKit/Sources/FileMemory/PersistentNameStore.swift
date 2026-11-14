import Darwin
import ExplorerCore
import Foundation
import LocalStorage

/// The single background owner of one catalog. No ordinary app composition is
/// wired in B07.1. All public construction is explicit; passive inspection cannot
/// create, recover, upgrade or rebuild storage.
public actor PersistentNameStore {
    internal let catalog: OwnedNameCatalog
    internal let database: NameIndexDatabase
    internal let core: NameSessionCore
    internal let activity: FileActivityGate?
    internal nonisolated let publication: NamePublicationAuthority
    internal let writable: Bool
    internal nonisolated let references = ReferencePublication()
    internal let referenceReader: NativeDocumentReferenceReader
    private var compatible: Bool
    internal var suspended = false
    private var closing = false
    private var closeComplete = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishing = false

    internal init(catalog: OwnedNameCatalog, database: NameIndexDatabase, activity: FileActivityGate?, compatible: Bool,
                  publication: NamePublicationAuthority = .init()) throws {
        self.catalog = catalog; self.database = database; self.activity = activity
        self.publication = publication
        writable = catalog.writable; self.compatible = compatible
        referenceReader = NativeDocumentReferenceReader(activity: activity)
        core = try NameSessionCore(database: database)
    }
    deinit { publication.close(); references.close() }

    public static func create(directory: URL, first: AuthoredNames,
                              activity: FileActivityGate? = nil) async throws -> PersistentNameStore {
        try await create(directory: directory, first: first, activity: activity, probe: nil, vfs: nil)
    }
    internal static func create(directory: URL, first: AuthoredNames, activity: FileActivityGate? = nil,
                                probe: NameStoreProbe?, vfs: String?, reference: NativeDocumentReference? = nil) async throws -> PersistentNameStore {
        try Task.checkCancellation()
        // Existing empty leaves are not adopted as fresh stores.
        try await PrivateStateDirectory(directory: directory, activity: activity, requireNew: true).prepare()
        return try await Task.detached(priority: .utility) {
            let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
            let catalog = try OwnedNameCatalog.create(directory)
            do {
                try probe?(.initialized)
                let database = try NameIndexDatabase(catalog: catalog, action: .edit, creating: true, vfs: vfs)
                do {
                    database.probe = probe
                    try database.initialize(catalog, first: first, reference: reference)
                    try catalog.synchronize(); try probe?(.firstCommit)
                    try database.validateRows(verifyIndex: true)
                    try catalog.publishReady(); try catalog.sealReadState(); try probe?(.ready)
                    return try PersistentNameStore(catalog: catalog, database: database, activity: activity, compatible: true)
                } catch { database.close(); throw error }
            } catch { catalog.release(); throw error }
        }.value
    }

    public static func inspect(directory: URL, activity: FileActivityGate? = nil) async -> NameStoreInspection {
        await Task.detached(priority: .utility) {
            do {
                let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
                var info = stat()
                if lstat(directory.path, &info) != 0 {
                    return NameStoreInspection(errno == ENOENT ? .absent : .unavailable)
                }
                let catalog = try OwnedNameCatalog.open(directory, writable: false)
                defer { catalog.release() }
                guard try catalog.isReady() else { return NameStoreInspection(.initializationIncomplete) }
                try catalog.validateHeader(creating: false)
                guard try !catalog.needsRecovery() else { return NameStoreInspection(.recoveryRequired) }
                try catalog.sealReadState()
                let db = try NameIndexDatabase(catalog: catalog, action: .readOnly)
                defer { db.close() }
                let header = try db.validateFormat(catalog)
                try db.validateRows(verifyIndex: header.compatible)
                try catalog.validate()
                let count = try db.statistics().records, pending = try db.pendingForgetCount()
                let referenceState: NameStoreStatus = try !db.hasReferenceFormat ? .referenceUpdateRequired
                    : db.pendingAccessRemovals() > 0 ? .accessRemovalPending : header.compatible ? .ready : .indexUpdateRequired
                return NameStoreInspection(pending > 0 ? .forgetPending : referenceState,
                    records: header.allPending ? 0 : count, pending: pending)
            } catch { return NameStoreInspection(status(for: error)) }
        }.value
    }

    public static func open(directory: URL, action: NameStoreOpenAction = .readOnly,
                            activity: FileActivityGate? = nil) async throws -> PersistentNameStore {
        try await open(directory: directory, action: action, activity: activity, probe: nil, vfs: nil)
    }
    internal static func open(directory: URL, action: NameStoreOpenAction, activity: FileActivityGate? = nil,
                              probe: NameStoreProbe?, vfs: String?) async throws -> PersistentNameStore {
        try await Task.detached(priority: .utility) {
            let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
            let catalog = try OwnedNameCatalog.open(directory, writable: action != .readOnly)
            do {
                let ready = try catalog.isReady()
                guard ready || action == .recover else { throw NameStoreFailure.initializationIncomplete }
                if action != .recover { try catalog.sealReadState() }
                let database = try NameIndexDatabase(catalog: catalog, action: action, vfs: vfs)
                do {
                    database.probe = probe
                    let header = try database.validateFormat(catalog)
                    try database.validateRows(verifyIndex: header.compatible)
                    if !ready {
                        guard try database.matchesFirstCommit(catalog) else { throw NameStoreFailure.initializationIncomplete }
                        try catalog.publishReady()
                    }
                    if action == .updateIndex {
                        guard try database.pendingForgetCount() == 0 else { throw NameStoreFailure.forgetPending }
                        try catalog.beginWrite(); try database.updateIndex()
                        try database.validateRows(verifyIndex: true); try catalog.synchronize(); try catalog.endWrite()
                    } else if action == .recover { try catalog.synchronize() }
                    if action == .upgradeReferences || action == .upgradeMoveContinuity || action == .upgradeMoveMembers {
                        guard header.compatible else { throw NameStoreFailure.indexUpdateRequired }
                        try catalog.beginWrite(); try database.upgradeReferences()
                        if action == .upgradeMoveContinuity || action == .upgradeMoveMembers { try database.upgradeMoveContinuity() }
                        if action == .upgradeMoveMembers { try database.upgradeMoveMembers() }
                        _ = try database.validateFormat(catalog); try database.validateRows(verifyIndex: true)
                        try catalog.synchronize(); try catalog.endWrite()
                    }
                    try catalog.sealReadState()
                    return try PersistentNameStore(catalog: catalog, database: database, activity: activity,
                        compatible: action == .updateIndex || header.compatible)
                } catch { database.close(); throw error }
            } catch { catalog.release(); throw error }
        }.value
    }

    /// The first saved ID is opaque and unrelated to a source filesystem object.
    public func firstItemID() throws -> RememberedItemID { try requireOpen(); return catalog.firstID }
    public func prepareNew(_ names: AuthoredNames) throws -> PreparedNameEdit {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireWrite(); return try core.prepareNew(names)
    }
    public func prepareEdit(_ snapshot: StoredNameSnapshot, names: AuthoredNames) throws -> PreparedNameEdit {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireWrite()
        guard publication.isCurrent(snapshot), try database.revision(snapshot.id) == snapshot.revision else { throw NameIndexFailure.staleEdit }
        return try core.prepareEdit(snapshot.id, names: names)
    }
    public func cancel(_ edit: PreparedNameEdit) { core.cancel(edit) }
    @discardableResult public func apply(_ edit: PreparedNameEdit) throws -> RememberedItemID {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireWrite()
        guard publication.allows(edit.itemID) else { throw NameIndexFailure.staleEdit }
        var committed = false
        do {
            try publication.advance()
            try catalog.beginWrite()
            let id = try core.apply(edit)
            committed = true
            try catalog.synchronize(); try catalog.endWrite()
            try database.probe?(.saveCommit)
            return id
        } catch {
            // Safe rollback can be re-used. Commit/synchronization/namespace
            // uncertainty suspends this owner rather than replaying an edit.
            if committed || database.commitUncertain { suspended = true }
            do { try catalog.endWrite() } catch { suspended = true }
            if suspended { throw NameStoreFailure.uncertainCommit }
            throw error
        }
    }

    public enum SaveResolution: Sendable, Equatable { case saved, notCurrent }
    public func resolve(_ edit: PreparedNameEdit) throws -> SaveResolution {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireOpen(); try catalog.validate()
        guard publication.allows(edit.itemID), try !database.hasAllFence() else { return .notCurrent }
        return try database.hasMutation(edit.itemID, nonce: edit.mutationID) ? .saved : .notCurrent
    }
    public func snapshot(_ id: RememberedItemID) throws -> StoredNameSnapshot {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireOpen()
        guard publication.allows(id), try !database.hasAllFence() else { throw NameIndexFailure.missingRecord }
        let epoch = try publication.snapshotEpoch(id)
        try catalog.validate(); let result = try core.snapshot(id); try catalog.validate()
        return try publication.capture(result, epoch: epoch)
    }
    public func query(_ query: RememberedNameQuery, budget: RememberedNameQueryBudget = .init(),
                      cancellation: RememberedNameCancellation = .init()) throws -> StoredNamePage {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireReadableIndex()
        let (token, epoch) = try publication.beginQuery(cancellation)
        defer { publication.endQuery(token) }
        try catalog.validate()
        let page = try core.query(query, budget: budget, cancellation: cancellation)
        try catalog.validate()
        return try publication.capture(page, epoch: epoch)
    }
    public func nextPage(_ cursor: RememberedNameCursor,
                         cancellation: RememberedNameCancellation = .init()) throws -> StoredNamePage {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireReadableIndex()
        let (token, epoch) = try publication.beginQuery(cancellation)
        defer { publication.endQuery(token) }
        try catalog.validate(); let page = try core.nextPage(cursor, cancellation: cancellation)
        try catalog.validate(); return try publication.capture(page, epoch: epoch)
    }
    public nonisolated func beginUse(_ page: StoredNamePage) throws -> RememberedNameUse { try publication.beginUse(page) }
    public nonisolated func prepareForget(_ id: RememberedItemID? = nil) throws -> PreparedNameForget {
        let request = try publication.withdraw(id); references.invalidate(id); return request
    }
    /// Native callers use this when an export could already be committing.
    /// Cancellation cannot withdraw a pending privacy request or release work.
    public nonisolated func prepareForgetAfterExports(_ id: RememberedItemID? = nil) async throws -> PreparedNameForget {
        references.invalidate(id)
        return try await publication.withdrawAfterCommit(id)
    }

    public func finishForget(_ request: PreparedNameForget,
                             cancellation: RememberedNameCancellation = .init()) async throws -> RememberedForgetOutcome {
        try requireOpen()
        guard writable else { throw NameStoreFailure.readOnly }
        guard publication.owns(request) else { throw NameStoreFailure.invalidRequest }
        guard !finishing else { throw NameStoreFailure.busy }
        finishing = true; defer { finishing = false }
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try core.invalidate(request.item)
        do {
            try catalog.beginWrite(); try database.revoke(request.item)
            try catalog.synchronize(); try catalog.endWrite()
        } catch {
            suspended = true
            return .sessionHiddenOnly
        }
        return await finishPurge(request, cancellation: cancellation)
    }

    /// Explicit continuation after reopening a known-format pending revocation.
    /// Index compatibility is deliberately not required to forget saved text.
    public func finishPendingForget(cancellation: RememberedNameCancellation = .init()) async throws -> RememberedForgetOutcome {
        try requireOpen()
        guard writable else { throw NameStoreFailure.readOnly }
        guard !finishing else { throw NameStoreFailure.busy }
        let request = try await publication.withdrawAfterCommit(nil)
        try requireOpen()
        guard !finishing else { throw NameStoreFailure.busy }
        references.invalidate(nil)
        finishing = true; defer { finishing = false }
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try core.invalidate()
        return await finishPurge(request, cancellation: cancellation)
    }

    private func finishPurge(_ request: PreparedNameForget, cancellation: RememberedNameCancellation) async -> RememberedForgetOutcome {
        do {
            try catalog.beginWrite(); try database.purgePending(cancellation: cancellation)
            try catalog.synchronize(); try catalog.endWrite(); try core.invalidate()
            await publication.waitForDrain(request.item)
            guard !closing else { return .hiddenPending }
            try catalog.validate()
            guard try database.pendingForgetCount() == 0 else { return .hiddenPending }
            try database.probe?(.acknowledged)
            publication.complete(request)
            return .forgotten
        } catch {
            if database.commitUncertain { suspended = true }
            do { try catalog.endWrite() } catch { suspended = true }
            return .hiddenPending
        }
    }

    public func close() async {
        if closing {
            if !closeComplete { await withCheckedContinuation { closeWaiters.append($0) } }
            return
        }
        closing = true; publication.close(); references.close()
        await publication.waitForDrain(nil)
        core.close(); catalog.release()
        closeComplete = true
        let waiters = closeWaiters; closeWaiters = []
        for waiter in waiters { waiter.resume() }
    }
    internal func requireOpen() throws {
        guard !closing else { throw NameStoreFailure.closed }
        guard !suspended else { throw NameStoreFailure.recoveryRequired }
    }
    internal func requireWrite() throws {
        try requireOpen()
        guard writable else { throw NameStoreFailure.readOnly }
        guard compatible else { throw NameStoreFailure.indexUpdateRequired }
        guard try database.hasReferenceFormat else { throw NameStoreFailure.referenceUpdateRequired }
        guard !publication.hasPending, try database.pendingForgetCount() == 0 else { throw NameStoreFailure.forgetPending }
        try catalog.validate()
    }
    private func requireReadableIndex() throws {
        try requireOpen()
        guard compatible else { throw NameStoreFailure.indexUpdateRequired }
        guard try !database.hasAllFence() else { throw NameStoreFailure.forgetPending }
    }
    private static func status(for error: Error) -> NameStoreStatus {
        switch error {
        case NameStoreFailure.busy: .busy
        case NameStoreFailure.initializationIncomplete: .initializationIncomplete
        case NameStoreFailure.recoveryRequired: .recoveryRequired
        case NameStoreFailure.unsupported: .unsupported
        case NameStoreFailure.indexUpdateRequired: .indexUpdateRequired
        case NameStoreFailure.referenceUpdateRequired: .referenceUpdateRequired
        case NameStoreFailure.unavailable: .unavailable
        default: .unsafe
        }
    }
    internal func qualificationStatistics() throws -> NameIndexDatabase.Statistics { try database.statistics() }
    internal nonisolated var qualificationPayloadCount: Int { publication.qualificationPayloadCount }

    /// Generated setup only. This is not ordinary per-Save throughput: each
    /// bounded seed transaction still pays the configured strong synchronization.
    internal func qualificationSeed(_ count: Int) throws {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireWrite()
        guard count >= 0, count + (try database.statistics().records) <= NameStoreFormat.maximumRecords else { throw NameIndexFailure.resourceLimit }
        try publication.advance(); try catalog.beginWrite()
        for start in stride(from: 0, to: count, by: 256) {
            try autoreleasepool {
                try database.transaction {
                    for i in start..<min(start + 256, count) {
                        let names = try AuthoredNames(nickname: "Project \(String(format: "%06d", i))",
                            alternateNames: ["Release \(String(format: "%06d", i))"], labels: [i % 2 == 0 ? "work" : "personal"])
                        try database.save(id: RememberedItemID(UUID()), names: names, expected: nil, withinTransaction: true)
                    }
                }
            }
        }
        try catalog.synchronize(); try catalog.endWrite(); try core.invalidate()
    }
    internal func qualificationCachePages(_ pages: Int) throws {
        guard pages == 1 else { throw NameStoreFailure.invalidRequest }
        try database.exec("PRAGMA cache_size=1")
        database.qualificationFlushBeforeBoundary = true
    }
    internal func qualificationPageLimit() throws {
        let count = try database.scalar("PRAGMA page_count")
        try database.exec("PRAGMA max_page_count=\(count)")
    }
}
