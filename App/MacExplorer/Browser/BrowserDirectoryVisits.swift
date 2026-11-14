import Combine
import ExplorerCore
import Foundation
import LocalStorage

@MainActor
enum BrowserAddressServices {
    static let completion = DirectoryCompletionService(activityGate: ApplicationFileActivity.gate)
    private static var stores: [URL: BrowserDirectoryVisits] = [:]
    static func visits(at root: URL?) -> BrowserDirectoryVisits {
        guard let root else { return BrowserDirectoryVisits(directory: nil) }
        if let store = stores[root] { return store }
        let store = BrowserDirectoryVisits(directory: root); stores[root] = store; return store
    }
}

@MainActor
final class BrowserDirectoryVisits: ObservableObject {
    @Published private(set) var status = ""
    private(set) var history = DirectoryVisitHistory()
    private let worker: DirectoryVisitWorker
    private var configuration: Configuration?
    private var revision = UUID()
    private var task: Task<Void, Never>?
    private var ready = false
    private var pendingVisits: [URL] = []
    struct Configuration: Sendable, Equatable { let enabled: Bool; let policy: DirectoryVisitPolicy }
    init(directory: URL?) { worker = DirectoryVisitWorker(directory: directory) }
    func configure(enabled: Bool, policy: DirectoryVisitPolicy) {
        let value = Configuration(enabled: enabled, policy: policy)
        guard configuration != value else { return }
        configuration = value; revision = worker.advance(); task?.cancel(); ready = false; pendingVisits = []
        history = DirectoryVisitHistory()
        let revision = revision
        task = Task { [weak self, worker] in
            let result = await worker.configure(value, revision: revision)
            guard let self, self.revision == revision else { return }
            self.accept(result)
        }
    }
    func clear() {
        revision = worker.advance(); task?.cancel(); history = DirectoryVisitHistory(); ready = false; pendingVisits = []
        let revision = revision
        task = Task { [weak self, worker] in
            let result = await worker.clear(revision: revision)
            guard let self, self.revision == revision else { return }
            self.accept(result)
        }
    }
    func record(_ url: URL) {
        guard let config = configuration, config.enabled else { return }
        guard ready else { if pendingVisits.count < 32 { pendingVisits.append(url) }; return }
        history.record(url, policy: config.policy)
        let revision = revision
        worker.record(url, revision: revision) { [weak self] failed in
            Task { @MainActor [weak self] in
                guard let self, self.revision == revision, failed else { return }
                self.status = "Visit history could not be saved. Existing data was preserved."
            }
        }
    }
    var counts: [String: Int] {
        guard let configuration, configuration.enabled else { return [:] }
        var current = history; current.prune(policy: configuration.policy, now: Date())
        if current != history {
            history = current
            let revision = revision
            worker.prune(revision: revision) { [weak self] failed in
                Task { @MainActor [weak self] in
                    guard let self, self.revision == revision, failed else { return }
                    self.status = "Expired visit history could not be saved. Existing data was preserved."
                }
            }
        }
        return history.counts(policy: configuration.policy)
    }
    func flush() async { await task?.value; await worker.flush() }
    private func accept(_ result: Result<DirectoryVisitHistory, Error>) {
        switch result {
        case .success(let value):
            history = value; status = ""; ready = true
            let pending = pendingVisits; pendingVisits = []
            pending.forEach(record)
        case .failure: ready = false; pendingVisits = []; status = "Visit history could not be read or cleared safely. Existing data was preserved."
        }
    }
}

private final class DirectoryVisitWorker: @unchecked Sendable {
    private struct Document: Codable { var version = 1; let history: DirectoryVisitHistory }
    private let queue = DispatchQueue(label: "MacExplorer.DirectoryVisits", qos: .utility)
    private let lock = NSLock()
    private var generation = UUID()
    private let file: BrowserSnapshotFile?
    private var history = DirectoryVisitHistory()
    private var configuration: BrowserDirectoryVisits.Configuration?
    private var blocked = false
    init(directory: URL?) {
        file = directory.map { BrowserSnapshotFile(directory: $0, name: "directory-visits-v1.json", maximumBytes: 2_097_152) }
    }
    func advance() -> UUID { lock.withLock { generation = UUID(); return generation } }
    private func current(_ revision: UUID) -> Bool { lock.withLock { generation == revision } }
    private func decode(_ data: Data) throws -> DirectoryVisitHistory {
        let value = try JSONDecoder().decode(Document.self, from: data)
        guard value.version == 1 else { throw BrowserSnapshotFile.Failure.invalidDocument }
        try value.history.validate(); return value.history
    }
    func configure(_ config: BrowserDirectoryVisits.Configuration, revision: UUID) async -> Result<DirectoryVisitHistory, Error> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: Result {
                    guard current(revision) else { throw CancellationError() }
                    let lease = try ApplicationFileActivity.gate.begin(); defer { withExtendedLifetime(lease) {} }
                    configuration = config
                    if !config.enabled {
                        history = DirectoryVisitHistory()
                        try file?.forget { _ = try self.decode($0) }; blocked = false
                    } else {
                        history = try file?.read().map(decode) ?? DirectoryVisitHistory()
                        history.prune(policy: config.policy, now: Date())
                        guard current(revision) else { throw CancellationError() }
                        blocked = false
                        if let file { try file.write(try JSONEncoder().encode(Document(history: history))) { _ = try self.decode($0) } }
                    }
                    return history
                })
            }
        }
    }
    func clear(revision: UUID) async -> Result<DirectoryVisitHistory, Error> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: Result {
                    guard current(revision) else { throw CancellationError() }
                    let lease = try ApplicationFileActivity.gate.begin(); defer { withExtendedLifetime(lease) {} }
                    history = DirectoryVisitHistory()
                    try file?.forget { _ = try self.decode($0) }; blocked = false
                    return history
                })
            }
        }
    }
    func record(_ url: URL, revision: UUID, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard current(revision), !blocked, let configuration, configuration.enabled else { return }
            do {
                let lease = try ApplicationFileActivity.gate.begin(); defer { withExtendedLifetime(lease) {} }
                history.record(url, policy: configuration.policy)
                guard current(revision) else { return }
                if let file { try file.write(try JSONEncoder().encode(Document(history: history))) { _ = try self.decode($0) } }
                completion(false)
            } catch { blocked = true; completion(true) }
        }
    }
    func prune(revision: UUID, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard current(revision), !blocked, let configuration, configuration.enabled else { return }
            do {
                let lease = try ApplicationFileActivity.gate.begin(); defer { withExtendedLifetime(lease) {} }
                history.prune(policy: configuration.policy, now: Date())
                guard current(revision) else { return }
                if let file { try file.write(try JSONEncoder().encode(Document(history: history))) { _ = try self.decode($0) } }
                completion(false)
            } catch { blocked = true; completion(true) }
        }
    }
    func flush() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
}
