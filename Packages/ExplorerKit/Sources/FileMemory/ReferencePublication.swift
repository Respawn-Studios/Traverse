import Foundation

public struct RememberedReferenceDisplay: Sendable {
    public let id: RememberedItemID
    public let availability: RememberedReferenceAvailability
    /// Last-known for unresolved rows, freshly observed for Available. This URL
    /// is never a file-operation proof or a retained security-scope lease.
    public let location: URL?
}
public final class StoredRememberedReference: Sendable {
    internal let token = UUID()
    internal let id: RememberedItemID
    internal let owner: ReferencePublication
    internal let names: NamePublicationAuthority
    internal init(id: RememberedItemID, owner: ReferencePublication, names: NamePublicationAuthority) {
        self.id = id; self.owner = owner; self.names = names
    }
    @discardableResult public func publish(_ body: (RememberedReferenceDisplay) -> Void) -> Bool {
        names.withReferencePublication(id) { owner.publish(self, body) } ?? false
    }
}
public final class PreparedReferenceChange: Sendable {
    public let itemID: RememberedItemID
    internal let token = UUID()
    internal let mutationID: UUID
    internal init(_ id: RememberedItemID, mutationID: UUID = UUID()) { itemID = id; self.mutationID = mutationID }
}
public final class PreparedAccessRemoval: Sendable {
    public let itemID: RememberedItemID
    internal let token = UUID()
    internal init(_ id: RememberedItemID) { itemID = id }
}
public enum RememberedAccessRemovalOutcome: Sendable, Equatable {
    case removed, disabledPending, sessionDisabledOnly
}
public struct ReferenceChangePreview: Sendable {
    public let previousLocation: URL?
    public let chosenLocation: URL
}

internal struct ReferenceProposal: Sendable {
    let handle: PreparedReferenceChange
    let evidence: NativeDocumentReference
    let revision: UInt64?
    let authoredRevision: UInt64?
    let newNames: PreparedNameEdit?
    let previous: String?
}
internal final class ReferenceWork: Sendable {
    let id: RememberedItemID
    let token = UUID()
    let generation: UUID
    let cancellation = RememberedNameCancellation()
    init(_ id: RememberedItemID, generation: UUID) { self.id = id; self.generation = generation }
}

/// Native payloads stay here, never in retained public handles. Publication is
/// nested inside NamePublicationAuthority's serialized Forget admission.
internal final class ReferencePublication: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var blocked = Set<RememberedItemID>()
    private var generations: [RememberedItemID: UUID] = [:]
    private var work: [UUID: ReferenceWork] = [:]
    private var proposals: [UUID: ReferenceProposal] = [:]
    private var displays: [UUID: (StoredRememberedReference, RememberedReferenceDisplay)] = [:]
    private var removals: [UUID: PreparedAccessRemoval] = [:]
    private var waiters: [(RememberedItemID?, CheckedContinuation<Void, Never>)] = []

    func begin(_ id: RememberedItemID, allowBlocked: Bool = false) throws -> ReferenceWork {
        try lock.withLock {
            guard !closed, allowBlocked || !blocked.contains(id) else { throw RememberedReferenceFailure.stale }
            guard work.count < 64 else { throw RememberedReferenceFailure.capacity }
            let generation = generations[id] ?? UUID(); generations[id] = generation
            let request = ReferenceWork(id, generation: generation); work[request.token] = request; return request
        }
    }
    func current(_ request: ReferenceWork) -> Bool { lock.withLock { valid(request) } }
    private func valid(_ request: ReferenceWork) -> Bool {
        !closed && work[request.token] === request && generations[request.id] == request.generation && !request.cancellation.isCancelled
    }
    func finish(_ request: ReferenceWork) {
        var ready: [CheckedContinuation<Void, Never>] = []
        lock.withLock {
            work.removeValue(forKey: request.token)
            waiters.removeAll { id, waiter in
                if !work.values.contains(where: { id == nil || $0.id == id }) { ready.append(waiter); return true }; return false
            }
            // No unbounded per-record registry remains after ephemeral work.
            let needed = Set(work.values.map(\.id)).union(proposals.values.map { $0.handle.itemID }).union(displays.values.map { $0.1.id })
            generations = generations.filter { needed.contains($0.key) }
        }
        ready.forEach { $0.resume() }
    }
    func waitForDrain(_ id: RememberedItemID?) async {
        await withCheckedContinuation { waiter in
            let done = lock.withLock {
                if !work.values.contains(where: { id == nil || $0.id == id }) { return true }
                waiters.append((id, waiter)); return false
            }
            if done { waiter.resume() }
        }
    }
    func capture(_ value: RememberedReferenceDisplay, work request: ReferenceWork,
                 names: NamePublicationAuthority) throws -> StoredRememberedReference {
        try lock.withLock {
            guard valid(request), !blocked.contains(value.id) || value.availability == .accessRemoved else { throw RememberedReferenceFailure.stale }
            if displays.count >= 64 { displays.removeAll() }
            let result = StoredRememberedReference(id: value.id, owner: self, names: names)
            displays[result.token] = (result, value); return result
        }
    }
    func publish(_ handle: StoredRememberedReference, _ body: (RememberedReferenceDisplay) -> Void) -> Bool {
        lock.withLock {
            guard !closed, let pair = displays[handle.token], pair.0 === handle else { return false }
            body(pair.1); return true
        }
    }
    func keep(_ proposal: ReferenceProposal, work request: ReferenceWork) throws -> PreparedReferenceChange {
        try lock.withLock {
            guard valid(request), proposals.count < 64,
                  proposals.values.reduce(0, { $0 + $1.evidence.bookmark.count + $1.evidence.path.utf8.count * 2 })
                    + proposal.evidence.bookmark.count + proposal.evidence.path.utf8.count * 2 <= 8 * 1_024 * 1_024 else { throw RememberedReferenceFailure.capacity }
            proposals[proposal.handle.token] = proposal; return proposal.handle
        }
    }
    func proposal(_ handle: PreparedReferenceChange, consume: Bool = false) throws -> ReferenceProposal {
        try lock.withLock {
            guard !closed, let proposal = proposals[handle.token], proposal.handle === handle else { throw RememberedReferenceFailure.stale }
            if consume { proposals.removeValue(forKey: handle.token) }; return proposal
        }
    }
    func invalidate(_ id: RememberedItemID?, disable: Bool = false) {
        lock.withLock { invalidateLocked(id, disable: disable) }
    }
    private func invalidateLocked(_ id: RememberedItemID?, disable: Bool) {
        if let id { generations[id] = UUID(); if disable { blocked.insert(id) } }
        else { for id in generations.keys { generations[id] = UUID() } }
        for request in work.values where id == nil || request.id == id { request.cancellation.cancel() }
        proposals = proposals.filter { id != nil && $0.value.handle.itemID != id }
        displays = displays.filter { id != nil && $0.value.1.id != id }
    }
    func removeAccess(_ id: RememberedItemID) throws -> PreparedAccessRemoval {
        try lock.withLock {
            guard !closed, removals.count < 64, blocked.count < 100_000 else { throw RememberedReferenceFailure.capacity }
            guard !removals.values.contains(where: { $0.itemID == id }) else { throw NameStoreFailure.busy }
            invalidateLocked(id, disable: true)
            let request = PreparedAccessRemoval(id); removals[request.token] = request; return request
        }
    }
    func owns(_ removal: PreparedAccessRemoval) -> Bool { lock.withLock { removals[removal.token] === removal && !closed } }
    func isBlocked(_ id: RememberedItemID) -> Bool { lock.withLock { blocked.contains(id) } }
    func hasRemoval(_ id: RememberedItemID) -> Bool { lock.withLock { removals.values.contains { $0.itemID == id } } }
    func complete(_ removal: PreparedAccessRemoval) { lock.withLock { removals.removeValue(forKey: removal.token); return () } }
    func regrant(_ id: RememberedItemID) { lock.withLock { blocked.remove(id); return () } }
    func close() { lock.withLock { closed = true; invalidateLocked(nil, disable: false); removals.removeAll(); blocked.removeAll() } }
}
