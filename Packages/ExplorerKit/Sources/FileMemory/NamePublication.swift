import Foundation

/// An opaque privacy request. Preparing it withdraws publication immediately;
/// only finishing it on its original store can establish durable Forget.
public final class PreparedNameForget: Sendable {
    internal let owner: UUID
    internal let token = UUID()
    internal let item: RememberedItemID?
    internal init(owner: UUID, item: RememberedItemID?) { self.owner = owner; self.item = item }
}

/// Values can be published only inside one short serialized admission decision.
/// A consumer may retain already-delivered values; Forget cannot retract those.
public final class StoredNamePage: Sendable {
    public let coverage: RememberedNameCoverage
    public let visitedPostings: Int
    public let next: RememberedNameCursor?
    internal let token = UUID()
    internal let epoch: UInt64
    internal let authority: NamePublicationAuthority
    internal init(_ page: RememberedNamePage, epoch: UInt64, authority: NamePublicationAuthority) {
        self.epoch = epoch; self.authority = authority
        coverage = page.coverage; visitedPostings = page.visitedPostings; next = page.next
    }
    /// The callback must be short and non-reentrant, with no blocking I/O. Real
    /// AppKit/export owners still need their own B07.3/B07.5 integration gates.
    @discardableResult public func publish(_ body: ([RememberedNameMatch]) -> Void) -> Bool {
        authority.publish(self, body)
    }
}

public final class StoredNameSnapshot: Sendable {
    public let id: RememberedItemID
    public let revision: UInt64
    internal let token = UUID()
    internal let epoch: UInt64
    internal let authority: NamePublicationAuthority
    internal init(_ value: RememberedNamesSnapshot, epoch: UInt64, authority: NamePublicationAuthority) {
        id = value.id; revision = value.revision; self.epoch = epoch; self.authority = authority
    }
    @discardableResult public func publish(_ body: (RememberedNamesSnapshot) -> Void) -> Bool {
        authority.publish(self, body)
    }
}

/// A worker keeps this lease until its actual completion, even if the awaiting
/// task was cancelled. It confers no filesystem or source-reference authority.
public final class RememberedNameUse: Sendable {
    private let authority: NamePublicationAuthority
    private let token: UUID
    internal init(authority: NamePublicationAuthority, token: UUID) { self.authority = authority; self.token = token }
    deinit { authority.finished(token) }
}

/// Tiny lock-protected visibility bookkeeping; no SQLite or filesystem operation
/// runs under this lock. The actor owns all authored captures and query caches.
internal final class NamePublicationAuthority: @unchecked Sendable {
    let owner = UUID()
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var closed = false
    private var requests: [UUID: PreparedNameForget] = [:]
    private var hidden = Set<RememberedItemID>()
    private var allHidden = false
    private var uses: [UUID: Set<RememberedItemID>] = [:]
    private var discoveryUses = Set<UUID>()
    private var waiters: [(RememberedItemID?, CheckedContinuation<Void, Never>)] = []
    private var queries: [UUID: RememberedNameCancellation] = [:]
    // Opaque handles carry no hidden text. Withdrawal/edit/close releases these
    // bounded owned payloads even if a caller retains every old handle.
    private var pages: [UUID: RememberedNamePage] = [:]
    private var pageOrder: [UUID] = []
    private var snapshots: [UUID: RememberedNamesSnapshot] = [:]
    private var snapshotOrder: [UUID] = []
    private var exportPayload: (UUID, Data)?
    private var importPayload: (token: UUID, owner: UUID, value: NameImportPayload)?
    private var retiredImports: [(NameImportPayload, UUID)] = []
    private var releasingImports = false
    private var retiredImportOwners: [UUID: UUID] = [:]
    private var importRetirementWaiters: [(UUID, CheckedContinuation<Void, Never>)] = []
    private var importReader: UUID?
    private let releaseQueue = DispatchQueue(label: "MacExplorer.PrivateNames.retired-imports", qos: .utility)
    private var committingPublication: UUID?
    private var exportWaiters: [CheckedContinuation<Void, Never>] = []

    private func clearPayloads() {
        pages.removeAll(); pageOrder.removeAll(); snapshots.removeAll(); snapshotOrder.removeAll(); exportPayload = nil; retireImportLocked()
    }
    private func retireImportLocked() {
        if let payload = importPayload {
            let use = UUID(); uses[use] = []; discoveryUses.insert(use)
            retiredImportOwners[use] = payload.owner
            retiredImports.append((payload.value, use)); importPayload = nil
        }
        if !retiredImports.isEmpty, !releasingImports {
            releasingImports = true
            releaseQueue.async { [self] in
                while true {
                    let tokens = releaseImportBatch()
                    if tokens.isEmpty { return }
                    tokens.forEach { finished($0) }
                }
            }
        }
    }
    /// Payload destruction and autorelease drain happen before the caller
    /// releases use tokens. Neither the main thread nor visibility lock frees
    /// the potentially large decoded import model.
    private func releaseImportBatch() -> [UUID] {
        autoreleasepool {
            let values: [(NameImportPayload, UUID)] = lock.withLock {
                if retiredImports.isEmpty { releasingImports = false; return [] }
                let result = retiredImports; retiredImports = []; return result
            }
            return values.map { $0.1 }
        }
    }
    func capture(_ page: RememberedNamePage, epoch expected: UInt64) throws -> StoredNamePage {
        try lock.withLock {
            guard !closed, requests.isEmpty, expected == epoch, !page.cancelled else { throw NameIndexFailure.stalePage }
            let handle = StoredNamePage(page, epoch: epoch, authority: self)
            while pages.count >= 4, let oldest = pageOrder.first { pages.removeValue(forKey: oldest); pageOrder.removeFirst() }
            pages[handle.token] = page; pageOrder.append(handle.token); return handle
        }
    }
    func capture(_ value: RememberedNamesSnapshot, epoch expected: UInt64) throws -> StoredNameSnapshot {
        try lock.withLock {
            guard !closed, requests.isEmpty, expected == epoch, !allHidden, !hidden.contains(value.id) else { throw NameIndexFailure.stalePage }
            let handle = StoredNameSnapshot(value, epoch: epoch, authority: self)
            while snapshots.count >= 64, let oldest = snapshotOrder.first { snapshots.removeValue(forKey: oldest); snapshotOrder.removeFirst() }
            snapshots[handle.token] = value; snapshotOrder.append(handle.token); return handle
        }
    }

    func withdraw(_ item: RememberedItemID?) throws -> PreparedNameForget {
        try lock.withLock {
            guard committingPublication == nil else { throw NameStoreFailure.busy }
            return try withdrawLocked(item)
        }
    }
    private func withdrawLocked(_ item: RememberedItemID?) throws -> PreparedNameForget {
            guard !closed else { throw NameStoreFailure.closed }
            guard requests.count < 64, epoch < UInt64.max else { throw NameIndexFailure.pendingLimit }
            let request = PreparedNameForget(owner: owner, item: item)
            requests[request.token] = request
            if let item { hidden.insert(item) } else { allHidden = true }
            epoch += 1
            clearPayloads()
            for token in queries.values { token.cancel() }
            return request
    }
    /// Hiding is immediate. Admission returns only after the actual export
    /// publication interval ends, without blocking the caller's executor.
    func withdrawAfterCommit(_ item: RememberedItemID?) async throws -> PreparedNameForget {
        let request = try lock.withLock { try withdrawLocked(item) }
        await withCheckedContinuation { continuation in
            let done = lock.withLock {
                guard committingPublication != nil else { return true }
                exportWaiters.append(continuation); return false
            }
            if done { continuation.resume() }
        }
        guard owns(request) else { throw NameStoreFailure.closed }
        return request
    }
    func exportEpoch() throws -> UInt64 {
        try lock.withLock {
            guard !closed, requests.isEmpty, !allHidden else { throw NameStoreFailure.forgetPending }
            return epoch
        }
    }
    func checkExportEpoch(_ expected: UInt64) throws {
        try lock.withLock {
            guard !closed, requests.isEmpty, epoch == expected else { throw NameExportFailure.stalePreview }
        }
    }
    func captureExport(_ data: Data, count: Int, locations: Bool, epoch expected: UInt64) throws -> PreparedNameExport {
        try lock.withLock {
            guard !closed, requests.isEmpty, epoch == expected, committingPublication == nil else { throw NameExportFailure.stalePreview }
            let handle = PreparedNameExport(authority: self, epoch: epoch, count: count, bytes: data.count, locations: locations)
            exportPayload = (handle.token, data); return handle
        }
    }
    func cancelExport(_ handle: PreparedNameExport) {
        lock.withLock { if handle.authority === self, exportPayload?.0 == handle.token { exportPayload = nil } }
    }
    /// No I/O here. The returned use pins actual encoding/write completion.
    /// Forget admission cannot succeed while this interval is held.
    func beginExport(_ handle: PreparedNameExport) throws -> (Data, RememberedNameUse) {
        try lock.withLock {
            guard !closed, requests.isEmpty, !allHidden, handle.authority === self,
                  epoch == handle.epoch, exportPayload?.0 == handle.token,
                  let data = exportPayload?.1 else { throw NameExportFailure.stalePreview }
            guard committingPublication == nil, uses.count < 64 else { throw NameStoreFailure.busy }
            let token = UUID(); uses[token] = []; discoveryUses.insert(token)
            committingPublication = handle.token; exportPayload = nil
            return (data, RememberedNameUse(authority: self, token: token))
        }
    }
    func endExport(_ handle: PreparedNameExport) {
        endCommit(handle.token)
    }
    func endCommit(_ token: UUID) {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard committingPublication == token else { return [] }
            committingPublication = nil; let result = exportWaiters; exportWaiters.removeAll(); return result
        }
        waiters.forEach { $0.resume() }
    }
    func captureImport(_ value: NameImportPayload, owner: UUID, epoch expected: UInt64) throws -> PreparedNameImport {
        try lock.withLock {
            guard !closed, requests.isEmpty, epoch == expected, committingPublication == nil else { throw NameImportFailure.stalePreview }
            guard retiredImports.count < 2 else { throw NameStoreFailure.busy }
            let handle = PreparedNameImport(authority: self, owner: owner, epoch: epoch, value: value)
            retireImportLocked()
            importPayload = (handle.token, owner, value); return handle
        }
    }
    func beginImportRead(_ owner: UUID) throws -> (use: RememberedNameUse, epoch: UInt64) {
        try lock.withLock {
            guard !closed, requests.isEmpty, !allHidden else { throw NameImportFailure.stalePreview }
            guard importReader == nil, uses.count < 64, retiredImports.count < 2 else { throw NameStoreFailure.busy }
            importReader = owner
            let token = UUID(); uses[token] = []; discoveryUses.insert(token)
            return (RememberedNameUse(authority: self, token: token), epoch)
        }
    }
    func endImportRead(_ owner: UUID) { lock.withLock { if importReader == owner { importReader = nil } } }
    func cancelImport(owner: UUID) { lock.withLock { if importPayload?.owner == owner { retireImportLocked() } } }
    func cancelImport(_ handle: PreparedNameImport) {
        lock.withLock { if handle.authority === self, importPayload?.token == handle.token { retireImportLocked() } }
    }
    func waitForImportRetirement(_ owner: UUID) async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock {
                if !retiredImportOwners.values.contains(owner) { return true }
                importRetirementWaiters.append((owner, continuation)); return false
            }
            if done { continuation.resume() }
        }
    }
    func beginImport(_ handle: PreparedNameImport) throws -> (value: NameImportPayload, use: RememberedNameUse, epoch: UInt64) {
        try lock.withLock {
            guard !closed, requests.isEmpty, !allHidden, epoch < UInt64.max, committingPublication == nil,
                  handle.authority === self, handle.epoch == epoch, importPayload?.token == handle.token,
                  let payload = importPayload?.value, uses.count < 64 else { throw NameImportFailure.stalePreview }
            let token = UUID(); uses[token] = []; discoveryUses.insert(token)
            importPayload = nil // Ownership moves to this actual work/use.
            epoch += 1; clearPayloads()
            return (payload, RememberedNameUse(authority: self, token: token), epoch)
        }
    }
    func beginImportCommit(_ token: UUID, epoch expected: UInt64) throws {
        try lock.withLock {
            guard !closed, requests.isEmpty, epoch == expected else { throw NameImportFailure.stalePreview }
            guard committingPublication == nil else { throw NameStoreFailure.busy }
            committingPublication = token
        }
    }
    func owns(_ request: PreparedNameForget) -> Bool {
        lock.withLock { !closed && request.owner == owner && requests[request.token] === request }
    }
    var hasPending: Bool { lock.withLock { !requests.isEmpty } }
    func allows(_ item: RememberedItemID) -> Bool { lock.withLock { !closed && !allHidden && !hidden.contains(item) } }
    func advance() throws {
        try lock.withLock {
            guard !closed else { throw NameStoreFailure.closed }
            guard epoch < UInt64.max else { throw NameIndexFailure.resourceLimit }
            epoch += 1
            clearPayloads()
        }
    }
    func beginQuery(_ cancellation: RememberedNameCancellation) throws -> (UUID, UInt64) {
        try lock.withLock {
            guard !closed else { throw NameStoreFailure.closed }
            guard requests.isEmpty else { throw NameStoreFailure.forgetPending }
            guard queries.count < 4 else { throw NameStoreFailure.busy }
            let token = UUID(); queries[token] = cancellation
            return (token, epoch)
        }
    }
    func snapshotEpoch(_ item: RememberedItemID) throws -> UInt64 {
        try lock.withLock {
            guard !closed, !allHidden, !hidden.contains(item) else { throw NameIndexFailure.missingRecord }
            return epoch
        }
    }
    func isCurrent(_ snapshot: StoredNameSnapshot) -> Bool { lock.withLock { valid(snapshot) } }
    private func valid(_ snapshot: StoredNameSnapshot) -> Bool {
        !closed && snapshot.authority === self && snapshot.epoch == epoch && requests.isEmpty
            && !allHidden && !hidden.contains(snapshot.id) && snapshots[snapshot.token] != nil
    }
    func publish(_ snapshot: StoredNameSnapshot, _ body: (RememberedNamesSnapshot) -> Void) -> Bool {
        lock.withLock {
            guard valid(snapshot), let value = snapshots[snapshot.token] else { return false }
            body(value); return true
        }
    }
    func endQuery(_ token: UUID) { _ = lock.withLock { queries.removeValue(forKey: token) } }
    func publish(_ page: StoredNamePage, _ body: ([RememberedNameMatch]) -> Void) -> Bool {
        lock.withLock {
            guard valid(page), let value = pages[page.token] else { return false }
            body(value.matches); return true
        }
    }
    func beginUse(_ page: StoredNamePage) throws -> RememberedNameUse {
        try lock.withLock {
            guard valid(page), uses.count < 64, let value = pages[page.token] else { throw NameIndexFailure.stalePage }
            let token = UUID(); uses[token] = Set(value.matches.map(\.item.id))
            return RememberedNameUse(authority: self, token: token)
        }
    }
    private func valid(_ page: StoredNamePage) -> Bool {
        guard !closed, page.authority === self, page.epoch == epoch, requests.isEmpty,
              let value = pages[page.token], !value.cancelled else { return false }
        return value.matches.allSatisfy { !hidden.contains($0.item.id) && !allHidden }
    }
    func beginReferenceUse(_ id: RememberedItemID) throws -> RememberedNameUse {
        try lock.withLock {
            guard !closed, requests.isEmpty, !allHidden, !hidden.contains(id), uses.count < 64 else { throw NameIndexFailure.stalePage }
            let token = UUID(); uses[token] = [id]; return RememberedNameUse(authority: self, token: token)
        }
    }
    func beginDiscoveryUse() throws -> RememberedNameUse {
        try lock.withLock {
            guard !closed, requests.isEmpty, !allHidden, uses.count < 64 else { throw NameStoreFailure.busy }
            let token = UUID(); uses[token] = []; discoveryUses.insert(token)
            return RememberedNameUse(authority: self, token: token)
        }
    }
    func beginUse(_ snapshot: StoredNameSnapshot) throws -> RememberedNameUse {
        try lock.withLock {
            guard valid(snapshot), uses.count < 64 else { throw NameIndexFailure.stalePage }
            let token = UUID(); uses[token] = [snapshot.id]; return RememberedNameUse(authority: self, token: token)
        }
    }
    func withReferencePublication<T>(_ id: RememberedItemID, _ body: () -> T) -> T? {
        lock.withLock {
            guard !closed, requests.isEmpty, !allHidden, !hidden.contains(id) else { return nil }
            return body()
        }
    }
    func waitForDrain(_ item: RememberedItemID?) async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock {
                if drained(item) { return true }
                waiters.append((item, continuation)); return false
            }
            if done { continuation.resume() }
        }
    }
    private func drained(_ item: RememberedItemID?) -> Bool {
        guard discoveryUses.isEmpty else { return false }
        guard let item else { return uses.isEmpty }
        return !uses.values.contains { $0.contains(item) }
    }
    func finished(_ token: UUID) {
        var resumed: [CheckedContinuation<Void, Never>] = []
        lock.withLock {
            uses.removeValue(forKey: token)
            discoveryUses.remove(token)
            retiredImportOwners.removeValue(forKey: token)
            waiters.removeAll { item, waiter in
                if drained(item) { resumed.append(waiter); return true }; return false
            }
            importRetirementWaiters.removeAll { owner, waiter in
                if !retiredImportOwners.values.contains(owner) { resumed.append(waiter); return true }; return false
            }
        }
        for waiter in resumed { waiter.resume() }
    }
    func complete(_ request: PreparedNameForget) {
        lock.withLock {
            requests.removeValue(forKey: request.token)
            if requests.isEmpty {
                // Purged identities remain hidden by missing DB rows. Releasing
                // these session pins permits an explicit new Remember with a new ID.
                hidden.removeAll(); allHidden = false
            }
        }
    }
    func close() {
        lock.withLock {
            closed = true
            for token in queries.values { token.cancel() }
            requests.removeAll(); hidden.removeAll(); allHidden = true
            clearPayloads()
        }
    }
    internal var qualificationPayloadCount: Int { lock.withLock { pages.count + snapshots.count + (exportPayload == nil ? 0 : 1) + (importPayload == nil ? 0 : 1) } }
}
