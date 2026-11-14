import Darwin
import ExplorerCore
import Foundation

public struct TARCompressedPreparationProgress: Sendable {
    public enum Phase: Sendable {
        case checkingSource, preparingStorage, checkingOrphans, checkingSpace, checkingRoot
        case decoding, validating, cataloging
    }
    public let phase: Phase
    public let decodedBytes: UInt64
    public let decodedLimit: UInt64
    internal init(_ phase: Phase, _ bytes: UInt64) {
        self.phase = phase; decodedBytes = bytes; decodedLimit = TARCompressedDecoder.maximumBytes
    }
}

/// All numbers describe this process's private compressed-TAR work. A false
/// `isComplete` means a write or retirement is still in flight, or a cleanup
/// could not be proved. It is not an estimate of the whole app cache.
public struct TARCompressedPreparationUsage: Sendable {
    public let entryCount: Int
    public let reservedBytes: UInt64
    public let knownLogicalBytes: UInt64
    public let knownAllocatedBytes: UInt64
    public let isComplete: Bool
    public let hasRetainedCleanup: Bool
}

/// One process-local owner. Its lock protects only admission and ownership;
/// all filesystem work runs outside it on bounded worker queues.
public final class TARCompressedPreparationPool: @unchecked Sendable {
    internal struct Prepared: Sendable {
        let catalog: TARCatalogStorage
        let binding: TARSourceBinding
    }
    private final class Ticket: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }
    /// Clearing the closure before DispatchGroup.leave makes a completed job
    /// mean its captured activity/access leases have actually been released.
    private final class JobBox: @unchecked Sendable {
        private var body: (@Sendable () -> Void)?
        init(_ body: @escaping @Sendable () -> Void) { self.body = body }
        func run() { body?(); body = nil }
    }
    private struct Request {
        let ticket: Ticket
        let continuation: CheckedContinuation<Prepared, Error>
        let progress: @Sendable (TARCompressedPreparationProgress) -> Void
        let lifetime: (any Sendable)?
    }
    /// Every mutable field is read or written under the pool lock, except the
    /// decoder's own lock-protected cancellation token.
    private final class Entry: @unchecked Sendable {
        let proof: TARCompressedOriginalProof
        let excludedRoots: [URL]
        var cancellation = TARCompressedDecoder.Cancellation()
        var waiters = Set<UUID>()
        var prepared: TARCompressedSpoolStorage.Prepared?
        var workActivity: FileActivityGate.Lease?
        var retirementActivity: FileActivityGate.Lease?
        var workLifetime: (any Sendable)?
        var activeLeases = 0
        var pendingCloses = [Int32]()
        var observedLogical: UInt64 = 0
        var observedAllocated: UInt64 = 0
        var working = true
        var retiring = false
        var retirementScheduled = false
        var uncertain = false
        init(_ proof: TARCompressedOriginalProof, roots: [URL],
             activity: FileActivityGate.Lease, lifetime: (any Sendable)?, waiter: UUID) {
            self.proof = proof; excludedRoots = roots; workActivity = activity
            workLifetime = lifetime; waiters.insert(waiter)
        }
    }

    private let cacheDirectory: URL
    private let activity: FileActivityGate
    private let beforeDecode: (@Sendable () throws -> Void)?
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "Traverse.CompressedTAR.Preparation", qos: .utility)
    private let jobs = DispatchGroup()
    private var requests = [UUID: Request]()
    private var entries = [Entry]()
    private var paused = false
    private var closed = false
    private var storageUncertain = false
    private var hasStorage = false
    private var rootRetirementActivity: FileActivityGate.Lease?
    // Accessed only on the serial worker. Initial recovery runs once.
    private var storage: TARCompressedSpoolStorage?

    public init(cacheDirectory: URL, activity: FileActivityGate) {
        self.cacheDirectory = cacheDirectory; self.activity = activity; beforeDecode = nil
    }
    internal init(cacheDirectory: URL, activity: FileActivityGate,
                  beforeDecode: @escaping @Sendable () throws -> Void) {
        self.cacheDirectory = cacheDirectory; self.activity = activity; self.beforeDecode = beforeDecode
    }

    public var usage: TARCompressedPreparationUsage {
        lock.withLock {
            let logical = entries.reduce(UInt64(0)) { $0 + ($1.prepared?.decodedBytes ?? $1.observedLogical) }
            let allocated = entries.reduce(UInt64(0)) { $0 + ($1.prepared?.allocatedBytes ?? $1.observedAllocated) }
            let retained = storageUncertain || entries.contains { $0.uncertain || !$0.pendingCloses.isEmpty }
            return .init(entryCount: entries.count,
                reservedBytes: UInt64(entries.count) * TARCompressedDecoder.maximumBytes,
                knownLogicalBytes: logical, knownAllocatedBytes: allocated,
                isComplete: !retained && requests.isEmpty && entries.allSatisfy { !$0.working && !$0.retirementScheduled },
                hasRetainedCleanup: retained)
        }
    }

    internal func prepare(_ original: URL, excluding roots: [URL], publicQuarantineSource: Bool = false,
                          retaining lifetime: (any Sendable)?,
                          progress: @escaping @Sendable (TARCompressedPreparationProgress) -> Void) async throws -> Prepared {
        let ticket = Ticket()
        let prepared = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Prepared, Error>) in
                let accepted = lock.withLock { () -> Bool in
                    guard !paused, !closed, !ticket.isCancelled, requests.count < 8 else { return false }
                    requests[ticket.id] = .init(ticket: ticket, continuation: continuation,
                                                progress: progress, lifetime: lifetime)
                    return true
                }
                guard accepted else {
                    continuation.resume(throwing: ticket.isCancelled ? TARArchiveFailure.stopped : TARArchiveFailure.busy)
                    return
                }
                enqueueProbe { [self] in
                    let result: Result<TARCompressedOriginalProof, Error> = Result {
                        let admitted = try activity.begin(); defer { withExtendedLifetime(admitted) {} }
                        defer { withExtendedLifetime(lifetime) {} }
                        guard !ticket.isCancelled else { throw TARArchiveFailure.stopped }
                        let suffix = original.lastPathComponent.lowercased()
                        guard suffix.hasSuffix(".tar.gz") || suffix.hasSuffix(".tgz") else { throw TARArchiveFailure.unsupported }
                        progress(.init(.checkingSource, 0))
                        let source = try PinnedLocalFileSource(original, excluding: roots)
                        guard source.observed.size >= 0,
                              UInt64(source.observed.size) <= TARCompressedDecoder.maximumBytes else { throw TARArchiveFailure.limited }
                        let security = try TARCompressedOriginalProof.Security.observe(source,
                            publicQuarantine: publicQuarantineSource)
                        try source.validate()
                        guard !ticket.isCancelled else { throw TARArchiveFailure.stopped }
                        return .init(source: source.url, stamp: source.observed, security: security)
                    }
                    self.probed(ticket.id, result: result, roots: roots)
                }
            }
        } onCancel: {
            ticket.cancel(); cancel(ticket.id)
        }
        if Task.isCancelled { throw TARArchiveFailure.stopped }
        return prepared
    }

    /// Admit every possible retirement before the global FileActivityGate is
    /// closed. Failure leaves the pool's admission state unchanged.
    public func prepareForQuiescence() throws {
        var completions = [(CheckedContinuation<Prepared, Error>, Error)]()
        var toRetire = [Entry]()
        try lock.withLock {
            if paused { return }
            guard !closed else { throw TARArchiveFailure.closed }
            var admitted = [ObjectIdentifier: FileActivityGate.Lease]()
            for entry in entries where entry.retirementActivity == nil {
                do { admitted[ObjectIdentifier(entry)] = try activity.begin() }
                catch { throw TARArchiveFailure.busy }
            }
            let rootAdmission: FileActivityGate.Lease?
            if rootRetirementActivity == nil && (hasStorage || !entries.isEmpty) {
                do { rootAdmission = try activity.begin() }
                catch { throw TARArchiveFailure.busy }
            } else { rootAdmission = nil }
            paused = true
            if let rootAdmission { rootRetirementActivity = rootAdmission }
            for entry in entries {
                if let lease = admitted[ObjectIdentifier(entry)] { entry.retirementActivity = lease }
                entry.retiring = true
                entry.cancellation.stop()
                if !entry.working && entry.activeLeases == 0 { toRetire.append(entry) }
            }
            for request in requests.values {
                request.ticket.cancel()
                completions.append((request.continuation, TARArchiveFailure.stopped))
            }
            requests.removeAll()
            for entry in entries { entry.waiters.removeAll() }
        }
        completions.forEach { $0.0.resume(throwing: $0.1) }
        toRetire.forEach { scheduleRetirement($0) }
        retryPendingCloses()
    }

    public func resumeAfterQuiescence() {
        lock.withLock {
            if !closed { paused = false }
            rootRetirementActivity = nil
        }
        retryPendingCloses()
        let retiring = lock.withLock { entries.filter { $0.retiring && !$0.working && $0.activeLeases == 0 } }
        retiring.forEach { scheduleRetirement($0) }
    }

    public func drain() async -> Bool {
        let ready = lock.withLock { () -> [Entry] in
            paused = true
            for entry in entries { entry.retiring = true; entry.cancellation.stop() }
            return entries.filter { !$0.working && $0.activeLeases == 0 }
        }
        ready.forEach { scheduleRetirement($0) }
        retryPendingCloses()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            jobs.notify(queue: .global(qos: .utility)) { continuation.resume() }
        }
        lock.withLock {
            if entries.isEmpty && !hasStorage { rootRetirementActivity = nil }
        }
        let mayCloseRoot = lock.withLock { requests.isEmpty && entries.isEmpty && hasStorage && !storageUncertain }
        if mayCloseRoot {
            let admitted = lock.withLock { rootRetirementActivity ?? (try? activity.begin()) }
            guard let admitted else { return false }
            enqueueWorker { [self] in
                let okay = storage?.closeRoot() ?? true
                storage = nil
                lock.withLock {
                    hasStorage = false
                    if !okay { storageUncertain = true }
                    rootRetirementActivity = nil
                }
                withExtendedLifetime(admitted) {}
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                jobs.notify(queue: .global(qos: .utility)) { continuation.resume() }
            }
        }
        return lock.withLock { requests.isEmpty && entries.isEmpty && !storageUncertain }
    }

    public func closeAndDrain() async -> Bool {
        do { try prepareForQuiescence() } catch { return false }
        lock.withLock { closed = true }
        return await drain()
    }

    private func enqueueProbe(_ body: @escaping @Sendable () -> Void) {
        jobs.enter()
        let box = JobBox(body)
        DispatchQueue.global(qos: .utility).async { [self, box] in box.run(); jobs.leave() }
    }
    private func enqueueWorker(_ body: @escaping @Sendable () -> Void) {
        jobs.enter()
        let box = JobBox(body)
        worker.async { [self, box] in box.run(); jobs.leave() }
    }

    private func cancel(_ id: UUID) {
        var continuation: CheckedContinuation<Prepared, Error>?
        lock.withLock {
            guard let request = requests.removeValue(forKey: id) else { return }
            continuation = request.continuation
            for entry in entries where entry.waiters.remove(id) != nil {
                if entry.waiters.isEmpty && entry.working { entry.cancellation.stop() }
            }
        }
        continuation?.resume(throwing: TARArchiveFailure.stopped)
    }

    private func probed(_ id: UUID, result: Result<TARCompressedOriginalProof, Error>, roots: [URL]) {
        guard case .success(let proof) = result else {
            if case .failure(let error) = result { finish(id, error: Self.failure(error)) }
            return
        }
        var schedule: Entry?
        var failure: Error?
        lock.withLock {
            guard let request = requests[id] else { return }
            guard !paused, !closed, !request.ticket.isCancelled else { failure = TARArchiveFailure.stopped; return }
            if let entry = entries.first(where: { $0.proof == proof }) {
                guard !entry.retiring && !entry.uncertain else { failure = TARArchiveFailure.busy; return }
                entry.waiters.insert(id)
                if !entry.working {
                    do { entry.workActivity = try activity.begin() }
                    catch { entry.waiters.remove(id); failure = TARArchiveFailure.busy; return }
                    entry.cancellation = TARCompressedDecoder.Cancellation()
                    entry.working = true
                    entry.workLifetime = request.lifetime
                    schedule = entry
                }
            } else {
                guard entries.count < 4 else { failure = TARArchiveFailure.limited; return }
                do {
                    let admitted = try activity.begin()
                    let entry = Entry(proof, roots: roots, activity: admitted,
                                      lifetime: request.lifetime, waiter: id)
                    entries.append(entry); schedule = entry
                } catch { failure = TARArchiveFailure.busy }
            }
        }
        if let failure { finish(id, error: failure) }
        if let schedule { enqueueWorker { [self] in run(schedule) } }
    }

    private func report(_ entry: Entry, phase: TARCompressedPreparationProgress.Phase,
                        bytes: UInt64 = 0, allocated: UInt64 = 0) {
        let callbacks = lock.withLock { () -> [@Sendable (TARCompressedPreparationProgress) -> Void] in
            entry.observedLogical = bytes
            entry.observedAllocated = allocated
            return entry.waiters.compactMap { requests[$0]?.progress }
        }
        let value = TARCompressedPreparationProgress(phase, bytes)
        callbacks.forEach { $0(value) }
    }

    private func run(_ entry: Entry) {
        var result: Result<TARCompressedSpoolStorage.Prepared, Error>
        do {
            guard entry.cancellation.poll() == 0 else { throw entry.cancellation.failure }
            if let prepared = lock.withLock({ entry.prepared }) {
                try Self.validateOriginal(entry.proof, excluding: entry.excludedRoots)
                let lease = TARCompressedSpoolLease(descriptor: prepared.descriptor, original: entry.proof,
                    decodedBytes: prepared.decodedBytes, digest: prepared.digest, stamp: prepared.stamp,
                    retire: { _ in })
                try lease.verifyDigest { guard entry.cancellation.poll() == 0 else { throw entry.cancellation.failure } }
                try Self.validateOriginal(entry.proof, excluding: entry.excludedRoots)
                result = .success(prepared)
            } else {
                try beforeDecode?()
                guard entry.cancellation.poll() == 0 else { throw entry.cancellation.failure }
                report(entry, phase: .preparingStorage)
                let store: TARCompressedSpoolStorage
                if let storage { store = storage }
                else {
                    store = try TARCompressedSpoolStorage(directory: cacheDirectory)
                    storage = store
                    lock.withLock { hasStorage = true }
                    report(entry, phase: .checkingOrphans)
                    try store.requireNoOrphans()
                }
                report(entry, phase: .checkingSpace)
                try store.requireFreeCapacity()
                let prepared = try store.prepare(entry.proof, excluding: entry.excludedRoots,
                    cancellation: entry.cancellation, progress: { [self] phase, bytes, allocated in
                        report(entry, phase: phase, bytes: bytes, allocated: allocated)
                    })
                result = .success(prepared)
            }
        } catch { result = .failure(Self.failure(error)) }
        if storage?.uncertainCleanup == true { lock.withLock { storageUncertain = true; entry.uncertain = true } }
        finishJob(entry, result: result)
    }

    private func finishJob(_ entry: Entry, result: Result<TARCompressedSpoolStorage.Prepared, Error>) {
        let admitted = lock.withLock { entry.workActivity }
        if case .success(let prepared) = result, lock.withLock({ entry.prepared == nil }) {
            lock.withLock { entry.prepared = prepared; entry.observedLogical = prepared.decodedBytes }
        }
        let ids = lock.withLock { Array(entry.waiters) }
        var copies = [UUID: Int32]()
        if case .success(let prepared) = result {
            for id in ids { copies[id] = dup(prepared.descriptor) }
        }
        var completions = [(CheckedContinuation<Prepared, Error>, Result<Prepared, Error>)]()
        var retire = false
        lock.withLock {
            for id in ids {
                guard let request = requests.removeValue(forKey: id) else { continue }
                let output: Result<Prepared, Error>
                if paused || entry.retiring || request.ticket.isCancelled {
                    output = .failure(TARArchiveFailure.stopped)
                } else {
                    switch result {
                    case .failure(let error): output = .failure(error)
                    case .success(let prepared):
                        if let fd = copies.removeValue(forKey: id), fd >= 0 {
                            entry.activeLeases += 1
                            let lease = TARCompressedSpoolLease(descriptor: fd, original: entry.proof,
                                decodedBytes: prepared.decodedBytes, digest: prepared.digest, stamp: prepared.stamp,
                                retire: { [self, entry] descriptor in retireDescriptor(descriptor, entry: entry) })
                            output = .success(.init(catalog: prepared.catalog,
                                binding: .init(source: entry.proof.source, stamp: entry.proof.stamp,
                                               witness: prepared.catalog.witness, compressed: lease)))
                        } else { output = .failure(TARArchiveFailure.unavailable) }
                    }
                }
                completions.append((request.continuation, output))
            }
            entry.waiters.removeAll()
            entry.working = false
            entry.workActivity = nil
            entry.workLifetime = nil
            if case .failure = result { entry.retiring = true }
            if entry.activeLeases == 0 && entry.waiters.isEmpty { entry.retiring = true }
            retire = entry.retiring && !entry.uncertain && entry.activeLeases == 0
        }
        for descriptor in copies.values where descriptor >= 0 { close(descriptor) }
        completions.forEach { $0.0.resume(with: $0.1) }
        if retire { scheduleRetirement(entry) }
        withExtendedLifetime(admitted) {}
    }

    private func finish(_ id: UUID, error: Error) {
        let continuation = lock.withLock { requests.removeValue(forKey: id)?.continuation }
        continuation?.resume(throwing: error)
    }

    private func retireDescriptor(_ descriptor: Int32, entry: Entry) {
        let admitted = lock.withLock { () -> FileActivityGate.Lease? in
            if let lease = entry.retirementActivity { return lease }
            return try? activity.begin()
        }
        guard let admitted else {
            lock.withLock { entry.pendingCloses.append(descriptor) }
            return
        }
        enqueueWorker { [self] in
            let okay = close(descriptor) == 0
            let retire = lock.withLock { () -> Bool in
                entry.activeLeases -= 1
                if !okay { entry.uncertain = true }
                if entry.activeLeases == 0 && !entry.working { entry.retiring = true }
                return entry.retiring && entry.activeLeases == 0 && !entry.uncertain
            }
            withExtendedLifetime(admitted) {}
            if retire { scheduleRetirement(entry) }
        }
    }

    private func retryPendingCloses() {
        let pending = lock.withLock { () -> [(Entry, Int32)] in
            entries.flatMap { entry in
                let descriptors = entry.pendingCloses
                entry.pendingCloses.removeAll()
                return descriptors.map { (entry, $0) }
            }
        }
        pending.forEach { retireDescriptor($0.1, entry: $0.0) }
    }

    private func scheduleRetirement(_ entry: Entry) {
        let admitted = lock.withLock { () -> FileActivityGate.Lease? in
            guard entry.retiring, !entry.retirementScheduled, !entry.working,
                  entry.activeLeases == 0, !entry.uncertain else { return nil }
            if entry.retirementActivity == nil {
                guard let lease = try? activity.begin() else { return nil }
                entry.retirementActivity = lease
            }
            entry.retirementScheduled = true
            return entry.retirementActivity
        }
        guard let admitted else { return }
        enqueueWorker { [self] in
            let descriptor = lock.withLock { entry.prepared?.descriptor }
            let okay = descriptor.map { close($0) == 0 } ?? true
            lock.withLock {
                if okay {
                    entries.removeAll { $0 === entry }
                    entry.prepared = nil
                } else { entry.uncertain = true; entry.retirementScheduled = false }
                entry.retirementActivity = nil
            }
            withExtendedLifetime(admitted) {}
        }
    }

    private static func validateOriginal(_ proof: TARCompressedOriginalProof, excluding roots: [URL]) throws {
        let source = try PinnedLocalFileSource(proof.source, excluding: roots)
        guard source.observed == proof.stamp,
              try proof.security.reobserve(source) == proof.security else {
            throw TARArchiveFailure.changed
        }
        try source.validate()
    }

    private static func failure(_ error: Error) -> Error {
        if let failure = error as? TARArchiveFailure { return failure }
        if let failure = error as? ZIPArchiveFailure {
            switch failure {
            case .changed: return TARArchiveFailure.changed
            case .stopped: return TARArchiveFailure.stopped
            case .limited: return TARArchiveFailure.limited
            case .malformed: return TARArchiveFailure.malformed
            case .unsupported: return TARArchiveFailure.unsupported
            default: return TARArchiveFailure.unavailable
            }
        }
        return TARArchiveFailure.unavailable
    }
}
