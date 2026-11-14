import CryptoKit
import ExplorerCore
import Foundation

/// One working-only catalog. Per-profile lifetime leases prevent competing
/// autosave owners; short catalog locks and exact revisions protect each edit.
final class WorkspaceProfileStore: @unchecked Sendable {
    enum Failure: Error { case unavailable, inUse, templateChanged, stale }
    struct Snapshot: Sendable { let memory: WorkspaceProfileMemory; let exists: Bool }
    struct Session: Sendable { let token: UUID; let record: WorkspaceProfileMemory.Record }
    private struct Owner {
        let lease: BrowserSnapshotFile.LifetimeLease
        var record: WorkspaceProfileMemory.Record
    }
    private struct Value { let bytes: Data?; var memory: WorkspaceProfileMemory }
    private let queue = DispatchQueue(label: "Traverse.ProfileWorkspaces", qos: .utility)
    private let directory: URL?
    private var owners: [UUID: Owner] = [:]
    #if DEBUG
    private var checkpointForVerification: (@Sendable (BrowserSnapshotFile.WriteBoundary) throws -> Void)?
    #endif
    init(directory: URL?) { self.directory = directory }
    private var file: BrowserSnapshotFile? {
        guard let directory else { return nil }
        var value = BrowserSnapshotFile(directory: directory, name: "profile-workspaces-v1.json", maximumBytes: 4 << 20)
        value.requiresPrivateDurability = true; value.requiresExistingWriterLock = true
        return value
    }
    static func templateKey(_ profile: WorkspaceLaunchProfile) throws -> String {
        struct Input: Encodable { let snapshot: PaneWorkspaceSnapshot; let includesFilters: Bool }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Input(snapshot: profile.snapshot, includesFilters: profile.includesFilters))
        guard bytes.count <= 4 << 20 else { throw Failure.unavailable }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private func perform<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { do { continuation.resume(returning: try action()) } catch { continuation.resume(throwing: error) } }
        }
    }
    private func decode(_ bytes: Data) throws -> WorkspaceProfileMemory {
        let memory = try JSONDecoder().decode(WorkspaceProfileMemory.self, from: bytes); try memory.validate(); return memory
    }
    private func read() throws -> Value {
        guard let file else { throw Failure.unavailable }
        let bytes = try file.read()
        return Value(bytes: bytes, memory: try bytes.map(decode) ?? .init())
    }
    private func mutationLease(creating: Bool = false) throws -> BrowserSnapshotFile.LifetimeLease {
        guard let file else { throw Failure.unavailable }
        // Only this short cooperative gate is retried, never an uncertain file
        // publication. The bounded wait runs on this store's worker, not AppKit.
        for attempt in 0..<8 {
            do {
                guard let lease = try file.acquireMutationLease(create: creating) else { throw Failure.unavailable }
                return lease
            } catch BrowserSnapshotFile.Failure.writerBusy {
                guard attempt < 7 else { throw BrowserSnapshotFile.Failure.writerBusy }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        throw Failure.inUse
    }
    private func write(_ memory: WorkspaceProfileMemory, replacing before: Data?, creating: Bool = false) throws {
        guard var file, before != nil || creating else { throw Failure.stale }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try memory.validate(); let bytes = try encoder.encode(memory)
        if before == nil && creating { file.requiresExistingWriterLock = false }
        try file.write(bytes, replacing: before.map(BrowserSnapshotFile.ExpectedVersion.bytes) ?? .absent,
            checkpoint: { boundary in
                #if DEBUG
                try self.checkpointForVerification?(boundary)
                #endif
            }, validating: { _ = try self.decode($0) })
    }
    func load() async throws -> Snapshot {
        try await perform { let value = try self.read(); return .init(memory: value.memory, exists: value.bytes != nil) }
    }
    func key(for profile: WorkspaceLaunchProfile) async throws -> String { try await perform { try Self.templateKey(profile) } }
    func enable(_ profile: WorkspaceLaunchProfile, initial: PaneWorkspaceSnapshot) async throws -> WorkspaceProfileMemory.Record {
        try await perform {
            let before = try self.read()
            let mutation = try self.mutationLease(creating: before.bytes == nil)
            defer { withExtendedLifetime(mutation) {} }
            guard let file = self.file, let lease = try file.acquireLifetimeLease(profile.id, create: true,
                creatingInventory: before.bytes == nil) else { throw Failure.unavailable }
            defer { withExtendedLifetime(lease) {} }
            var value = try self.read(); let key = try Self.templateKey(profile)
            let record = try value.memory.enable(profile.id, templateKey: key, includesFilters: profile.includesFilters, snapshot: initial)
            try lease.validate(); try mutation.validate(); try self.write(value.memory, replacing: value.bytes, creating: true)
            try lease.validate(); try mutation.validate()
            return record
        }
    }
    func begin(_ profile: WorkspaceLaunchProfile) async throws -> Session {
        try await perform {
            let key = try Self.templateKey(profile)
            if let current = self.owners.first(where: { $0.value.record.id == profile.id }) {
                try current.value.lease.validate()
                guard current.value.record.templateKey == key else { throw Failure.templateChanged }
                let mutation = try self.mutationLease()
                defer { withExtendedLifetime(mutation) {} }
                let latest = try self.read()
                guard latest.memory.record(for: profile.id) == current.value.record else { throw Failure.stale }
                try mutation.validate()
                return .init(token: current.key, record: current.value.record)
            }
            let before = try self.read()
            guard let candidate = before.memory.record(for: profile.id) else { throw WorkspaceProfileMemory.Failure.missing }
            guard candidate.templateKey == key else { throw Failure.templateChanged }
            let mutation = try self.mutationLease()
            defer { withExtendedLifetime(mutation) {} }
            guard let file = self.file, let lease = try file.acquireLifetimeLease(profile.id) else { throw Failure.unavailable }
            let latest = try self.read()
            guard let record = latest.memory.record(for: profile.id), record == candidate else { throw Failure.stale }
            try lease.validate(); try mutation.validate()
            let token = UUID(); self.owners[token] = Owner(lease: lease, record: record)
            return .init(token: token, record: record)
        }
    }
    func save(_ token: UUID, snapshot: PaneWorkspaceSnapshot) async throws -> WorkspaceProfileMemory.Record {
        try await perform {
            guard var owner = self.owners[token] else { throw Failure.stale }
            try owner.lease.validate()
            let mutation = try self.mutationLease()
            defer { withExtendedLifetime(mutation) {} }
            var value = try self.read()
            let normalized = try snapshot.forLaunchProfile(includeFilters: owner.record.includesFilters)
            guard value.memory.record(for: owner.record.id) == owner.record else { throw Failure.stale }
            if normalized == owner.record.snapshot { return owner.record }
            let record = try value.memory.save(owner.record.id, consent: owner.record.consent,
                expected: owner.record.revision, templateKey: owner.record.templateKey, snapshot: normalized)
            try owner.lease.validate(); try mutation.validate(); try self.write(value.memory, replacing: value.bytes)
            try owner.lease.validate(); try mutation.validate()
            owner.record = record; self.owners[token] = owner; return record
        }
    }
    func disable(_ id: UUID, expectedConsent: UUID?, ownedBy token: UUID? = nil) async throws {
        try await perform {
            guard let file = self.file else { throw Failure.unavailable }
            if token == nil, try self.read().memory.record(for: id) == nil { return }
            let mutation = try self.mutationLease()
            defer { withExtendedLifetime(mutation) {} }
            let lease: BrowserSnapshotFile.LifetimeLease
            if let token {
                guard let owner = self.owners[token], owner.record.id == id else { throw Failure.stale }
                lease = owner.lease
            } else {
                // Missing means already forgotten. Never create a session lock
                // to repair/erase a record whose coordination is unavailable.
                let before = try self.read()
                guard before.memory.record(for: id) != nil else { return }
                guard let opened = try file.acquireLifetimeLease(id) else { throw Failure.unavailable }
                lease = opened
            }
            defer { withExtendedLifetime(lease) {} }
            var value = try self.read()
            guard let record = value.memory.record(for: id) else { return }
            guard record.consent == expectedConsent else { throw Failure.stale }
            if let token, self.owners[token]?.record != record { throw Failure.stale }
            try value.memory.disable(id, consent: record.consent)
            try lease.validate(); try mutation.validate(); try self.write(value.memory, replacing: value.bytes); try lease.validate()
            try file.retireLifetimeLease(lease)
            try mutation.validate()
            if let token { self.owners.removeValue(forKey: token) }
        }
    }
    func end(_ token: UUID) async {
        _ = try? await perform { self.owners.removeValue(forKey: token); return true }
    }
    func drain() async { _ = try? await perform { true } }
    #if DEBUG
    func heldSessionsForVerification() async -> Int { (try? await perform { self.owners.count }) ?? -1 }
    func setCheckpointForVerification(_ checkpoint: (@Sendable (BrowserSnapshotFile.WriteBoundary) throws -> Void)?) async {
        _ = try? await perform { self.checkpointForVerification = checkpoint; return true }
    }
    #endif
}
