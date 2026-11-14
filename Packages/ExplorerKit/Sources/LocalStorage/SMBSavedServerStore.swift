import Foundation

/// One bounded, off-main preferences writer. No network or Keychain access.
/// Construction/inspection never initialize or recover storage. Ordinary app
/// activation is separate from this qualification interface.
@_spi(Qualification) public final class SMBSavedServerStore: @unchecked Sendable {
    private let location: URL
    private let queue = DispatchQueue(label: "MacExplorer.SMB.SavedServers", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = 0
    private var owner: SMBServerFile? // Only accessed on queue, except inert deinit.
    private let probe: SMBServerFile.Probe?
    public init(directory: URL) { location = directory; probe = nil }
    init(directory: URL, probe: @escaping SMBServerFile.Probe) { location = directory; self.probe = probe }
    deinit {
        let held = owner
        queue.async { held?.close() }
    }
    var admittedRequestCount: Int { lock.withLock { pending } }

    public func inspect() async throws -> SMBServerSnapshot? {
        let (value, _) = try await perform(read: true) { [self] () throws -> SMBServerSnapshot? in
            if let owner { try owner.validateCurrent(); return owner.snapshot }
            guard let opened = try SMBServerFile.open(location, writing: false) else { return nil }
            defer { opened.close() }; return opened.snapshot
        }
        return value
    }
    /// Call only for an explicit save/Forget. Interrupted staging requires the
    /// separately explained discard action; opening is never implicit recovery.
    public func openForExplicitWrite(discardUncommittedStage: Bool = false) async throws -> SMBServerMutation {
        let (value, cancelled) = try await perform(read: false) { [self] in
            guard owner == nil else { throw SMBServerStoreFailure.busy }
            guard let opened = try SMBServerFile.open(location, writing: true, discardStage: discardUncommittedStage, probe: probe) else {
                throw SMBServerStoreFailure.unavailable
            }
            owner = opened; return opened.snapshot
        }
        return SMBServerMutation(snapshot: value, serverID: nil, credentialReference: nil, completedAfterCancellation: cancelled)
    }
    public func apply(_ change: SMBServerChange, expectedRevision: UInt64) async throws -> SMBServerMutation {
        let (value, cancelled) = try await perform(read: false) { [self] in
            guard let owner else { throw SMBServerStoreFailure.notOpen }
            try owner.validateCurrent()
            guard owner.snapshot.revision == expectedRevision else { throw SMBServerStoreFailure.staleRevision }
            var next = owner.snapshot
            var serverID: UUID?, reference: SMBCredentialReference?
            switch change {
            case let .updatePresentation(id, label, components):
                guard let index = next.servers.firstIndex(where: { $0.id == id }), !next.servers[index].removalPending else { throw SMBServerStoreFailure.missing }
                let old = next.servers[index].details
                let path = components.isEmpty ? "/" : "/" + components.map(\.displayName).joined(separator: "/")
                let address = try SMBConnectionAddress(server: old.address.serverField, port: old.address.port,
                    share: old.address.share.displayName, startingFolder: path)
                next.servers[index].details = try .init(name: label, address: address, account: old.account,
                    domain: old.domain, security: old.security, transferPreference: old.transferPreference)
                serverID = id
            case let .saveServer(draft, id, credentialID):
                if draft.transferPreference != nil { next.format = 2 }
                try draft.validate()
                if let credentialID {
                    guard let claim = next.credentials.first(where: { $0.reference.id == credentialID }), claim.state == .ready,
                          claim.reference.bindingDigest == (try draft.credentialBinding()).digest else { throw SMBServerStoreFailure.invalidRecord }
                }
                if let id {
                    guard let index = next.servers.firstIndex(where: { $0.id == id }), !next.servers[index].removalPending else { throw SMBServerStoreFailure.missing }
                    next.servers[index].details = draft; next.servers[index].credentialID = credentialID; serverID = id
                } else {
                    guard next.servers.count < 64 else { throw SMBServerStoreFailure.capacity }
                    let id = UUID(); serverID = id
                    next.servers.append(SMBSavedServer(id: id, details: draft, credentialID: credentialID, removalPending: false))
                }
            case let .beginPassword(binding):
                guard next.credentials.count < 128 else { throw SMBServerStoreFailure.capacity }
                let created = SMBCredentialReference(binding: binding); reference = created
                next.credentials.append(SMBOwnedCredential(reference: created, state: .preparing))
            case let .confirmPassword(id):
                guard let index = next.credentials.firstIndex(where: { $0.reference.id == id }), next.credentials[index].state == .preparing else { throw SMBServerStoreFailure.missing }
                next.credentials[index].state = .ready
            case let .beginForgetPassword(id):
                try Self.markPasswordForRemoval(id, snapshot: &next)
            case let .finishForgetPassword(id):
                guard let index = next.credentials.firstIndex(where: { $0.reference.id == id }), next.credentials[index].state == .deleting else { throw SMBServerStoreFailure.missing }
                next.credentials.remove(at: index)
                for server in next.servers.indices where next.servers[server].credentialID == id { next.servers[server].credentialID = nil }
            case let .beginForgetServer(id, removePassword):
                guard let index = next.servers.firstIndex(where: { $0.id == id }) else { throw SMBServerStoreFailure.missing }
                next.servers[index].removalPending = true
                if removePassword, let credential = next.servers[index].credentialID {
                    try Self.markPasswordForRemoval(credential, snapshot: &next)
                }
            case let .beginForgetExpectedServer(expected, removePassword):
                guard let index = next.servers.firstIndex(where: { $0.id == expected.id }) else { throw SMBServerStoreFailure.missing }
                guard next.servers[index] == expected, !next.servers[index].removalPending else { throw SMBServerStoreFailure.staleRevision }
                next.servers[index].removalPending = true
                if removePassword, let credential = next.servers[index].credentialID {
                    try Self.markPasswordForRemoval(credential, snapshot: &next)
                }
            case let .finishForgetServer(id):
                guard let index = next.servers.firstIndex(where: { $0.id == id }), next.servers[index].removalPending else { throw SMBServerStoreFailure.missing }
                if let credential = next.servers[index].credentialID,
                   next.credentials.first(where: { $0.reference.id == credential })?.state == .deleting { throw SMBServerStoreFailure.recoveryRequired }
                next.servers.remove(at: index)
            }
            guard next.revision < UInt64.max else { throw SMBServerStoreFailure.capacity }
            next.revision += 1
            try owner.commit(next)
            return SMBServerMutation(snapshot: next, serverID: serverID, credentialReference: reference, completedAfterCancellation: false)
        }
        return SMBServerMutation(snapshot: value.snapshot, serverID: value.serverID, credentialReference: value.credentialReference, completedAfterCancellation: cancelled)
    }
    private static func markPasswordForRemoval(_ id: UUID, snapshot: inout SMBServerSnapshot) throws {
        guard let index = snapshot.credentials.firstIndex(where: { $0.reference.id == id }) else { throw SMBServerStoreFailure.missing }
        snapshot.credentials[index].state = .deleting
        // A hidden server must retain this association even if cleanup is
        // retried from the separate pending-password control.
        for server in snapshot.servers.indices where snapshot.servers[server].credentialID == id && !snapshot.servers[server].removalPending {
            snapshot.servers[server].credentialID = nil
        }
    }
    /// Cancellation does not skip closing the file owner or jump ahead of work.
    public func close() async {
        await withCheckedContinuation { continuation in
            lock.withLock { queue.async { [self] in owner?.close(); owner = nil; continuation.resume() } }
        }
    }
    private final class Request: @unchecked Sendable {
        private let lock = NSLock(); private var stopped = false
        func cancel() { lock.withLock { stopped = true } }
        var cancelled: Bool { lock.withLock { stopped } }
    }
    private func perform<T: Sendable>(read: Bool, body: @escaping @Sendable () throws -> T) async throws -> (T, Bool) {
        let request = Request()
        return try await withTaskCancellationHandler {
            if Task.isCancelled { request.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard pending < 8 else { lock.unlock(); continuation.resume(throwing: SMBServerStoreFailure.busy); return }
                pending += 1
                queue.async { [self] in
                    let result: Result<T, Error> = request.cancelled ? .failure(SMBServerStoreFailure.cancelled) : Result { try body() }
                    let cancelled = request.cancelled
                    lock.withLock { pending -= 1 }
                    if read && cancelled { continuation.resume(throwing: SMBServerStoreFailure.cancelled) }
                    else { continuation.resume(with: result.map { ($0, cancelled) }) }
                }
                lock.unlock()
            }
        } onCancel: { request.cancel() }
    }
}
