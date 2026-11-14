import Foundation
import ExplorerCore
import LocalStorage
import StorageAnalysis

enum AnalysisFolderPickerStyle: String, CaseIterable, Codable, Identifiable {
    case system = "System", explorer = "Explorer", columns = "Columns"
    var id: Self { self }
}

protocol AnalysisPickerReading: Sendable {
    func entries(in url: URL, showHidden: Bool, retaining: (any Sendable)?,
                 didDrain: @escaping @Sendable () -> Void) -> AsyncThrowingStream<ListingEvent, Error>
}

struct NativeAnalysisPickerReader: AnalysisPickerReading {
    let reader = LocalFileSystem(maximumConcurrentReads: 1, activityGate: ApplicationFileActivity.gate)
    func entries(in url: URL, showHidden: Bool, retaining lifetime: (any Sendable)?,
                 didDrain: @escaping @Sendable () -> Void) -> AsyncThrowingStream<ListingEvent, Error> {
        reader.entries(in: url, showHidden: showHidden, retaining: lifetime, didDrain: didDrain)
    }
}

/// One shallow-navigation owner shared by both layouts. Only one read is
/// admitted, with one replaceable pending request. A cancelled request retains
/// its slot until both the backend and its off-main processing actually finish.
@MainActor
final class AnalysisFolderPickerModel {
    struct Level: Identifiable {
        let id: UUID
        let location: BrowserLocation
        var entries: [FileEntry] = []
        var message = "Loading folders…"
        var loading = true
        var readable = false
    }
    struct Request { let generation: UUID; let level: UUID; let root: URL }
    let volumes: [VolumeInfo]
    let access: FolderAccessController
    let showsHidden: Bool
    private let reader: any AnalysisPickerReading
    private var tab: BrowserTab
    private(set) var levels: [Level] = []
    private(set) var selectedURL: URL?
    private(set) var generation = UUID()
    private var pending: Request?
    private var activeRead: UUID?
    private var readerDrained = false
    private var collectorDrained = false
    private var collector: Task<Void, Never>?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    #if DEBUG
    var sortingHookForVerification: (@Sendable () throws -> Void)?
    #endif
    var onChange: (() -> Void)?
    var location: BrowserLocation { tab.location }
    var canGoBack: Bool { tab.canGoBack }
    var canGoForward: Bool { tab.canGoForward }
    var isDrained: Bool { activeRead == nil }
    var confirmationURL: URL? {
        guard let current = levels.last, current.readable, !current.loading else { return nil }
        return selectedURL ?? current.location.directoryURL
    }

    init(initialDirectory: URL?, volumes: [VolumeInfo], access: FolderAccessController,
         showsHidden: Bool = false, reader: any AnalysisPickerReading = NativeAnalysisPickerReader()) {
        tab = BrowserTab(location: initialDirectory.map(BrowserLocation.directory) ?? .computer)
        self.volumes = volumes; self.access = access; self.showsHidden = showsHidden; self.reader = reader
    }

    func start() { replace(location, appendAfter: nil) }

    func navigate(_ target: BrowserLocation, appendAfter column: Int? = nil) {
        guard !closed else { return }
        tab.navigate(to: target); replace(target, appendAfter: column)
    }
    func goBack() { guard canGoBack else { return }; tab.goBack(); replace(location, appendAfter: nil) }
    func goForward() { guard canGoForward else { return }; tab.goForward(); replace(location, appendAfter: nil) }
    func goUp() { guard let parent = location.parent else { return }; navigate(parent) }

    func select(_ url: URL?) { selectedURL = url; onChange?() }

    @discardableResult func navigate(text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 8192, !value.utf8.contains(0), !value.contains("\n"), !value.contains("\r") else { return false }
        if value.caseInsensitiveCompare("This Mac") == .orderedSame { navigate(.computer); return true }
        let url: URL?
        if let path = try? DirectoryPathInput.resolve(value, home: BrowsingHome.url) { url = path }
        else if let found = levels.last?.entries.first(where: { $0.name == value }) { url = found.url }
        else { url = nil }
        guard let url else { return false }
        navigate(.directory(url))
        return true
    }

    private func replace(_ target: BrowserLocation, appendAfter column: Int?) {
        generation = UUID(); pending = nil; collector?.cancel(); selectedURL = nil
        if let column, levels.indices.contains(column) { levels = Array(levels.prefix(column + 1)) }
        else { levels = [] }
        // Keep bounded navigation state; the full path and Up/Back remain.
        if levels.count >= 8 { levels.removeFirst(levels.count - 7) }
        var level = Level(id: UUID(), location: target)
        if case .computer = target {
            level.entries = volumes.map { FileEntry(url: $0.url, name: $0.name, kind: .directory) }
            level.loading = false; level.readable = true
            level.message = volumes.isEmpty ? "No mounted locations are available in this session." : "Select a drive, or open it to browse folders."
        } else if let root = target.directoryURL, StorageAnalysisPolicy.excludes(root) {
            level.loading = false; level.message = "This folder is excluded by the current analysis privacy policy."
        }
        levels.append(level)
        if level.loading, let root = target.directoryURL {
            pending = Request(generation: generation, level: level.id, root: root)
        }
        onChange?(); pump()
    }

    private func pump() {
        guard !closed, activeRead == nil, let request = pending else { return }
        pending = nil
        let owner = UUID(); activeRead = owner; readerDrained = false; collectorDrained = false
        collector = Task { [weak self] in
            guard let self else { return }
            var launched = false
            defer { self.didFinishCollection(owner, readerLaunched: launched) }
            let lease = await self.access.acquireAccess(to: request.root)
            guard !Task.isCancelled, self.generation == request.generation, !self.closed else { return }
            let reader = self.reader, hidden = self.showsHidden
            let lifetime = FileAccessLifetimes(leases: lease.map { [$0] } ?? [])
            launched = true
            var collected: [FileEntry] = [], limited = false, issues = false
            do {
                for try await event in reader.entries(in: request.root, showHidden: hidden, retaining: lifetime,
                    didDrain: { [weak self] in Task { @MainActor in self?.didDrain(owner) } }) {
                    try Task.checkCancellation()
                    switch event {
                    case .batch(let entries):
                        for entry in entries where entry.kind == .directory {
                            if collected.count < 10_000 { collected.append(entry) } else { limited = true }
                        }
                    case .finished(let problems): issues = !problems.isEmpty
                    }
                }
                let input = collected
                try Task.checkCancellation()
                #if DEBUG
                let sortingHook = self.sortingHookForVerification
                #endif
                let sorting = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    #if DEBUG
                    try sortingHook?()
                    #endif
                    let result = orderedEntries(input, sort: DirectorySort())
                    try Task.checkCancellation()
                    return result
                }
                let sorted = try await withTaskCancellationHandler {
                    try await sorting.value
                } onCancel: {
                    sorting.cancel()
                }
                guard !Task.isCancelled, self.generation == request.generation, !self.closed,
                      let index = self.levels.firstIndex(where: { $0.id == request.level }) else { return }
                self.levels[index].entries = sorted; self.levels[index].loading = false
                self.levels[index].readable = !issues
                self.levels[index].message = issues ? "Some folder metadata was unavailable. Use System Picker or grant access to retry."
                    : limited ? "Showing the first 10,000 folders. Enter an exact path to reach other folders."
                    : sorted.isEmpty ? "This folder has no visible subfolders. You can choose this folder." : ""
                self.onChange?()
            } catch {
                guard !Task.isCancelled, self.generation == request.generation, !self.closed,
                      let index = self.levels.firstIndex(where: { $0.id == request.level }) else { return }
                self.levels[index].loading = false; self.levels[index].readable = false
                self.levels[index].message = FolderAccessDiagnostic.describe(error).message
                self.onChange?()
            }
        }
    }

    private func didDrain(_ owner: UUID) {
        guard activeRead == owner else { return }
        readerDrained = true
        finishIfDrained(owner)
    }

    private func didFinishCollection(_ owner: UUID, readerLaunched: Bool) {
        guard activeRead == owner else { return }
        if !readerLaunched { readerDrained = true }
        collectorDrained = true
        finishIfDrained(owner)
    }

    private func finishIfDrained(_ owner: UUID) {
        guard activeRead == owner, readerDrained, collectorDrained else { return }
        activeRead = nil; collector = nil
        let waiters = drainWaiters; drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
        pump()
    }

    func cancelAndDrain() async {
        closed = true; generation = UUID(); pending = nil; collector?.cancel(); onChange = nil
        if activeRead != nil { await withCheckedContinuation { drainWaiters.append($0) } }
    }
}
