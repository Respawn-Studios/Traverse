import AppKit
import Combine
import FileOperations
import LocalStorage
import SwiftUI

@MainActor final class GitFileHistoryModel: ObservableObject {
    let access: GitReviewAccess
    let originalPath: GitSnapshotPath
    let initialCommit: GitObjectID?
    let local: GitLocalFileReview?
    @Published private(set) var path: GitSnapshotPath
    @Published private(set) var paths: [GitSnapshotPath]
    @Published private(set) var history: GitFileHistory?
    @Published private(set) var revisions: [GitRevisionOption] = []
    @Published private(set) var startingRevision: GitRevisionOption?
    @Published private(set) var startingCommit: GitObjectID?
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published var selectedCommits = Set<GitObjectID>()
    @Published private(set) var hasDraft = false
    @Published private(set) var filterID: UUID?
    @Published private(set) var query = ""
    @Published private(set) var comparisonBase: GitFileHistory.Entry?
    private let request = GitReviewRequest()
    private var closed = false
    private var newerPages: [GitFileHistory.Page] = []
    private let maximumRememberedPages = 64

    init(access: GitReviewAccess, path: GitSnapshotPath, startingAt commit: GitObjectID?, local: GitLocalFileReview?) {
        self.access = access
        originalPath = path
        initialCommit = commit
        self.local = local
        self.path = path
        paths = [path]
    }

    var selection: GitObjectID? { selectedCommits.count == 1 ? selectedCommits.first : nil }
    var selected: GitFileHistory.Entry? { visibleEntries.first { $0.id == selection } }
    var selectedPair: (earlier: GitFileHistory.Entry, later: GitFileHistory.Entry)? {
        guard selectedCommits.count == 2 else { return nil }
        let entries = visibleEntries.filter { selectedCommits.contains($0.id) }
        guard entries.count == 2 else { return nil }
        return (entries[1], entries[0])
    }
    var visibleEntries: [GitFileHistory.Entry] {
        let entries = history?.entries ?? []
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return entries }
        func matches(_ value: String) -> Bool {
            value.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return entries.filter { entry in
            entry.commit.matchesFilter(term)
                || entry.before.map { matches($0.path.display) } == true
                || entry.after.map { matches($0.path.display) } == true
        }
    }
    var canFilter: Bool { !busy && history?.entries.isEmpty == false }
    var pageNumber: Int { newerPages.count + 1 }
    var canGoNewer: Bool { !busy && !newerPages.isEmpty }
    var canGoOlder: Bool { !busy && history?.older != nil && !atPageLimit }
    var atPageLimit: Bool { newerPages.count >= maximumRememberedPages }
    var canOpen: Bool { !busy && selected?.after?.isTextCandidate == true }
    var canSetBase: Bool { canOpen && selected?.id != comparisonBase?.id }
    var compareTitle: String { selectedCommits.count == 2 ? "Compare Versions" : "Compare Change" }
    var canCompare: Bool {
        guard !busy else { return false }
        if let pair = selectedPair { return canCompare(pair.earlier.after, pair.later.after) }
        return selected.map { canCompare($0.before, $0.after) } ?? false
    }

    private func canCompare(_ left: GitSnapshotMember?, _ right: GitSnapshotMember?) -> Bool {
        (left != nil || right != nil) && (left?.isTextCandidate ?? true) && (right?.isTextCandidate ?? true)
    }

    var canCompareWithBase: Bool {
        guard !busy, let comparisonBase, let selected, selected.id != comparisonBase.id else { return false }
        return canCompare(comparisonBase.after, selected.after)
    }

    func setBase() { if canSetBase { comparisonBase = selected } }
    func clearBase() { if !busy { comparisonBase = nil } }

    func refreshDraftAvailability() { hasDraft = local?.hasDraft() == true }

    func showFilter() {
        guard canFilter else { return }
        filterID = UUID()
    }

    func hideFilter() {
        filterID = nil
        setQuery("")
    }

    func setQuery(_ text: String) {
        let next = String(text.prefix(256))
        guard query != next else { return }
        query = next
        retainSelection(selectedCommits)
    }

    func moveFilteredSelection(by offset: Int) {
        let entries = visibleEntries
        guard !busy, !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : entries.count)
        selectedCommits = [entries[min(entries.count - 1, max(0, index + offset))].id]
    }

    func reload() {
        let path = self.path
        if let prior = startingRevision, !prior.isPinned, prior.id != Data("HEAD".utf8) {
            load("Reloading local Git revisions…") { [access] in try await access.catalog() } accept: { model, catalog in
                model.revisions = GitRevisionOption.choices(catalog)
                if let refreshed = prior.refreshed(in: model.revisions) { model.choose(refreshed, path: path) }
                else { model.message = "That branch or tag is no longer listed. Choose another revision to update the history." }
            }
        } else {
            let pinned = startingRevision.flatMap { $0.isPinned ? $0 : nil }
            let initial = startingRevision == nil ? initialCommit : nil
            let revision = pinned?.revision ?? initial.map(GitRevisionSelection.object) ?? .head
            load("Reading Git file history…") { [access] in
                try await access.openHistory(path: path, from: revision)
            } accept: { model, value in
                let (catalog, history) = value
                var choices = GitRevisionOption.choices(catalog)
                let fixed = pinned ?? initial.map { GitRevisionOption.pinnedCommit($0, in: choices) }
                if let fixed, !choices.contains(where: { $0.id == fixed.id }) { choices.insert(fixed, at: 0) }
                model.revisions = choices
                model.install(history, path: path, revision: fixed ?? (catalog.head == nil ? nil : choices.first))
            }
        }
    }

    func choose(_ revision: GitRevisionOption, path: GitSnapshotPath) {
        load("Reading Git file history…") { [access] in
            try await access.history(path: path, from: revision.revision)
        } accept: { model, history in model.install(history, path: path, revision: revision) }
    }

    func choosePath(_ path: GitSnapshotPath) {
        guard let startingRevision, self.path != path else { return }
        choose(startingRevision, path: path)
    }

    func goOlder() {
        guard canGoOlder, let start = history?.start, let older = history?.older else { return }
        readPage(older) { $0.newerPages.append(start) }
    }

    func goNewer() {
        guard canGoNewer, let previous = newerPages.last else { return }
        readPage(previous) { _ = $0.newerPages.popLast() }
    }

    private func readPage(_ page: GitFileHistory.Page, accept: @escaping (GitFileHistoryModel) -> Void) {
        load("Reading the selected history page…") { [access] in
            let history = try await access.history(path: page.path, from: .object(page.commit))
            guard history.start == page, !history.entries.isEmpty else { throw GitInspectionFailure.changed }
            return history
        } accept: { model, history in
            accept(model)
            model.installPage(history, preserving: [])
        }
    }

    private func install(_ history: GitFileHistory, path: GitSnapshotPath, revision: GitRevisionOption?) {
        let previousSelection = self.path == path ? selectedCommits : []
        self.path = path
        newerPages.removeAll()
        startingCommit = history.startingCommit
        startingRevision = history.startingCommit.flatMap { commit in revision?.resolved(to: commit) } ?? revision
        installPage(history, preserving: previousSelection)
    }

    private func installPage(_ history: GitFileHistory, preserving previousSelection: Set<GitObjectID>) {
        self.history = history
        var known = Set(paths)
        for entry in history.entries where entry.kind == .renamed {
            for name in [entry.before?.path, entry.after?.path].compactMap({ $0 }) where paths.count < 192 {
                if known.insert(name).inserted { paths.append(name) }
            }
        }
        retainSelection(previousSelection)
    }

    private func retainSelection(_ previous: Set<GitObjectID>) {
        let visible = visibleEntries
        let retained = previous.intersection(visible.lazy.map(\.id))
        selectedCommits = retained.isEmpty ? Set(visible.prefix(1).map(\.id)) : retained
    }

    func open(_ accept: @escaping (GitSnapshotMember, GitObjectID, TextDocumentValue) -> Void) {
        guard canOpen, let entry = selected, let member = entry.after else { return }
        load("Opening Git version…") { [access] in try await access.text(member) } accept: { _, text in
            accept(member, entry.commit.object, text)
        }
    }

    func open(at reference: GitRevisionOption, accept: @escaping (GitSnapshotMember, GitObjectID, TextDocumentValue) -> Void) {
        let path = self.path
        load("Opening Git version…") { [access] in
            try await access.versionText(path: path, at: reference.revision)
        } accept: { model, value in
            let (version, text) = value
            switch version.state {
            case .absent: model.report("This path is absent in the selected revision.")
            case .member(let member) where text != nil:
                if let text { accept(member, version.commit, text) }
            default: model.report("This path is a folder, symbolic link or submodule in the selected revision.")
            }
        }
    }

    func resolve(_ reference: GitRevisionOption, accept: @escaping (GitFileVersion) -> Void) {
        let path = self.path
        load("Looking up the file version…") { [access] in
            try await access.version(path: path, at: reference.revision)
        } accept: { _, version in accept(version) }
    }

    func compare(with reference: GitRevisionOption, accept: @escaping (GitFileVersion, GitFileVersion) -> Void) {
        guard let first = startingCommit else { return }
        let path = self.path
        load("Looking up both file versions…") { [access] in
            try await access.versions(path: path, left: .object(first), right: reference.revision)
        } accept: { _, versions in accept(versions.0, versions.1) }
    }

    func stop() {
        guard request.isRunning else { return }
        message = "Stopping Git review…"
        request.stop()
    }

    func close() {
        request.close()
        closed = true
        history = nil
        revisions = []
        newerPages.removeAll()
        startingRevision = nil
        startingCommit = nil
        selectedCommits = []
        filterID = nil
        query = ""
        comparisonBase = nil
    }

    func report(_ message: String) { self.message = message }

    private func load<Value: Sendable>(_ message: String, read: @escaping @MainActor () async throws -> Value,
                                       accept: @escaping @MainActor (GitFileHistoryModel, Value) -> Void) {
        guard !closed, !request.isRunning else { return }
        busy = true
        self.message = message
        request.start(read) { [weak self] result in
            guard let self else { return }
            busy = false
            switch result {
            case .success(let value):
                self.message = ""
                accept(self, value)
            case .failure(let error):
                self.message = GitReviewAccess.message(for: error)
            }
        }
    }
}

enum GitLocalDiff: Int, CaseIterable {
    case commitToDisk, commitToDraft, commitToIndex, diskToDraft, indexToDisk

    var title: String {
        switch self {
        case .commitToDisk: "Selected Commit ↔ On Disk"
        case .commitToDraft: "Selected Commit ↔ Unsaved Buffer"
        case .commitToIndex: "Selected Commit ↔ Git Index"
        case .diskToDraft: "On Disk ↔ Unsaved Buffer"
        case .indexToDisk: "Git Index ↔ On Disk"
        }
    }

    var left: GitLocalFileReview.Source? {
        switch self {
        case .commitToDisk, .commitToDraft, .commitToIndex: nil
        case .diskToDraft: .disk
        case .indexToDisk: .index
        }
    }

    var right: GitLocalFileReview.Source {
        switch self {
        case .commitToDraft, .diskToDraft: .draft
        case .commitToIndex: .index
        case .commitToDisk, .indexToDisk: .disk
        }
    }

    @MainActor func isAvailable(in model: GitFileHistoryModel) -> Bool {
        guard !model.busy, model.local != nil, right != .draft || model.hasDraft else { return false }
        if left != nil { return true }
        return model.selected.map { $0.after?.isTextCandidate ?? true } == true
    }
}

@MainActor final class GitFileHistoryWindow: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let model: GitFileHistoryModel
    private let settings: BrowserSettings
    private var snapshot: NativeTextSnapshotController?
    private var diff: EditorComparisonWindow?
    private var started = false
    var didClose: (() -> Void)?

    init(parent: NSWindow, settings: BrowserSettings, access: GitReviewAccess, path: GitSnapshotPath,
         startingAt commit: GitObjectID? = nil, local: GitLocalFileReview?) {
        self.settings = settings
        model = GitFileHistoryModel(access: access, path: path, startingAt: commit, local: local)
        let viewport = ToolWindowChrome.initialViewport(size: .init(width: 940, height: 610),
            minimum: .init(width: 650, height: 430), scale: settings.interfaceSize.scale, screen: parent.screen)
        let native = ToolWindowChrome.makeWindow(title: "Git File History — Traverse", size: viewport.size, minimumSize: viewport.minimum)
        super.init(window: native)
        native.delegate = self
        native.contentViewController = InterfaceHostingController(rootView: GitFileHistoryContent(model: model,
            open: { [weak self] in self?.openVersion(nil) }, compare: { [weak self] in self?.compareChange(nil) },
            compareBase: { [weak self] in self?.compareWithBase(nil) },
            compareWith: { [weak self] in self?.compareRevisions(with: $0) },
            openAt: { [weak self] in self?.openRevision($0) },
            compareRevisionWithLocal: { [weak self] in self?.compareRevision($0, with: $1) },
            compareLocal: { [weak self] in self?.compareLocal($0) }))
        ToolWindowChrome.install(in: native, settings: settings, initialContentSize: viewport.size, minimumContentSize: viewport.minimum)
        ToolWindowChrome.position(native, relativeTo: parent)
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        window?.makeKeyAndOrderFront(nil)
        if !started { started = true; model.reload() }
    }

    func matches(_ location: GitRepositoryLocation, path: GitSnapshotPath, startingAt commit: GitObjectID? = nil) -> Bool {
        model.access.location.isSameRepository(as: location) && model.originalPath == path && model.initialCommit == commit
            && (commit == nil || model.startingCommit == nil || model.startingCommit == commit)
    }

    @objc func openVersion(_ sender: Any?) {
        model.open { [weak self] member, commit, text in self?.presentSnapshot(member, commit: commit, text: text) }
    }

    @objc func compareChange(_ sender: Any?) {
        guard model.canCompare else { return }
        if let pair = model.selectedPair {
            presentDiff(left: pair.earlier.after, right: pair.later.after,
                leftLabel: "\(pair.earlier.id.short) · \(pair.earlier.after?.path.display ?? "Absent")",
                rightLabel: "\(pair.later.id.short) · \(pair.later.after?.path.display ?? "Absent")")
        } else if let entry = model.selected {
            let commit = entry.commit.object.short
            presentDiff(left: entry.before, right: entry.after,
                leftLabel: "Before \(commit) · \(entry.before?.path.display ?? "Absent")",
                rightLabel: "\(commit) · \(entry.after?.path.display ?? "Absent")")
        }
    }

    func compareRevisions(with revision: GitRevisionOption) {
        model.compare(with: revision) { [weak self] left, right in self?.compareVersions(left, right) }
    }

    @objc func compareWithBase(_ sender: Any?) {
        guard model.canCompareWithBase, let base = model.comparisonBase, let entry = model.selected else { return }
        presentDiff(left: base.after, right: entry.after,
            leftLabel: "Base \(base.id.short) · \(base.after?.path.display ?? "Absent")",
            rightLabel: "\(entry.id.short) · \(entry.after?.path.display ?? "Absent")")
    }

    private func openRevision(_ revision: GitRevisionOption) {
        model.open(at: revision) { [weak self] member, commit, text in
            self?.presentSnapshot(member, commit: commit, text: text)
        }
    }

    private func compareRevision(_ revision: GitRevisionOption, with source: GitLocalFileReview.Source) {
        guard let local = model.local else { return }
        model.resolve(revision) { [weak self] version in
            guard let self, let before = version.editorTextSource else {
                self?.model.report("This path is a folder, symbolic link or submodule in the selected revision.")
                return
            }
            let access = model.access
            presentDiff(leftLabel: before.label, rightLabel: local.label(source),
                detail: "The Git revision stays pinned. Refresh captures the current local version again.") {
                let after = try await local.read(source, through: access)
                try Task.checkCancellation()
                return .init(left: try await access.committedSide(before.member), right: after)
            }
        }
    }

    private func compareVersions(_ left: GitFileVersion, _ right: GitFileVersion) {
        guard let a = left.editorTextSource, let b = right.editorTextSource else {
            model.report("One revision contains a folder, symbolic link or submodule at this path.")
            return
        }
        guard a.member != nil || b.member != nil else {
            model.report("This path is absent in both revisions. Choose a file path from its history.")
            return
        }
        presentDiff(left: a.member, right: b.member, leftLabel: a.label, rightLabel: b.label)
    }

    private func presentSnapshot(_ member: GitSnapshotMember, commit: GitObjectID, text: TextDocumentValue) {
        guard let parent = window, parent.isVisible else { return }
        snapshot?.window.window?.performClose(nil)
        let view = NativeTextSnapshotController.gitVersion(text: text, member: member, commit: commit,
            access: model.access, settings: settings, parent: parent)
        snapshot = view
        view.didClose = { [weak self, weak view] _ in if self?.snapshot === view { self?.snapshot = nil } }
        view.show()
    }

    private func presentDiff(left: GitSnapshotMember?, right: GitSnapshotMember?, leftLabel: String, rightLabel: String) {
        let access = model.access
        presentDiff(leftLabel: leftLabel, rightLabel: rightLabel, detail: "Read-only text from the selected Git commits.") {
            try await access.textComparison(left: left, right: right)
        }
    }

    private func compareLocal(_ action: GitLocalDiff) {
        model.refreshDraftAvailability()
        guard action.isAvailable(in: model), let local = model.local else { return }
        let entry = model.selected
        let revisionTitle = entry?.commit.object.short ?? "Commit"
        let committedLabel = revisionTitle + " · " + (entry?.after?.path.display ?? "Absent")
        let access = model.access
        presentDiff(leftLabel: action.left.map(local.label) ?? committedLabel, rightLabel: local.label(action.right),
            detail: "Captured from the selected sources. Refresh reads current local versions again.") {
            // Capture draft text before an awaited disk or Git read can yield.
            let draft = action.right == .draft ? try await local.read(.draft, through: access) : nil
            let before: EditorComparisonCapture.Side
            if let source = action.left { before = try await local.read(source, through: access) }
            else { before = try await access.committedSide(entry?.after) }
            try Task.checkCancellation()
            let after: EditorComparisonCapture.Side
            if let draft { after = draft }
            else { after = try await local.read(action.right, through: access) }
            return .init(left: before, right: after)
        }
    }

    private func presentDiff(leftLabel: String, rightLabel: String, detail: String,
                             capture: @escaping @MainActor () async throws -> EditorComparisonCapture) {
        guard let parent = window, parent.isVisible else { return }
        if diff?.preparing == true { diff?.present(); return }
        diff?.window?.performClose(nil)
        let pointSize = CGFloat(settings.editorPreferences.basePointSize) * settings.interfaceSize.scale
        let result = EditorComparisonWindow(relativeTo: parent, settings: settings, pointSize: pointSize,
            labels: .init(title: "Git Text Diff", source: model.path.display, left: leftLabel, right: rightLabel,
                detail: detail, refresh: "Refresh"), capture: capture)
        diff = result
        result.didClose = { [weak self, weak result] in if self?.diff === result { self?.diff = nil } }
        result.present()
    }

    @objc private func reload(_ sender: Any?) { model.reload() }
    @objc private func older(_ sender: Any?) { model.goOlder() }
    @objc private func newer(_ sender: Any?) { model.goNewer() }
    @objc private func filterHistory(_ sender: Any?) { model.showFilter() }
    @objc private func setComparisonBase(_ sender: Any?) { model.setBase() }
    @objc private func clearComparisonBase(_ sender: Any?) { model.clearBase() }
    @objc private func compareLocalCommand(_ sender: NSMenuItem) {
        if let action = GitLocalDiff(rawValue: sender.tag) { compareLocal(action) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard window?.isKeyWindow == true, !(window?.firstResponder is NSTextView) else { return false }
        switch item.action {
        case #selector(openVersion(_:)): return model.canOpen
        case #selector(compareChange(_:)):
            item.title = model.compareTitle
            return model.canCompare
        case #selector(reload(_:)): return !model.busy
        case #selector(older(_:)): return model.canGoOlder
        case #selector(newer(_:)): return model.canGoNewer
        case #selector(filterHistory(_:)): return model.canFilter
        case #selector(setComparisonBase(_:)): return model.canSetBase
        case #selector(clearComparisonBase(_:)): return !model.busy && model.comparisonBase != nil
        case #selector(compareWithBase(_:)): return model.canCompareWithBase
        case #selector(compareLocalCommand(_:)): return GitLocalDiff(rawValue: item.tag)?.isAvailable(in: model) == true
        default: return true
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshDraftAvailability()
        _ = ToolWindowMenuOwnership.claim(self) { base in
            var actions = [
                BrowserMenus.item("Open Version", #selector(openVersion(_:)), key: "\r", modifiers: [], target: self),
                BrowserMenus.item(model.compareTitle, #selector(compareChange(_:)), key: "\r", target: self),
                BrowserMenus.item("Set Comparison Base", #selector(setComparisonBase(_:)), target: self),
                BrowserMenus.item("Compare with Base", #selector(compareWithBase(_:)), key: "\r", modifiers: [.command, .option], target: self),
                BrowserMenus.item("Clear Comparison Base", #selector(clearComparisonBase(_:)), target: self),
                BrowserMenus.item("Newer Changes", #selector(newer(_:)), key: "[", target: self),
                BrowserMenus.item("Older Changes", #selector(older(_:)), key: "]", target: self),
                BrowserMenus.item("Filter This History Page", #selector(filterHistory(_:)), key: "f", target: self),
                BrowserMenus.item("Reload History", #selector(reload(_:)), key: "r", target: self)
            ]
            if model.local != nil {
                let parent = NSMenuItem(title: "Compare Local", action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: parent.title)
                for action in GitLocalDiff.allCases {
                    let item = BrowserMenus.item(action.title, #selector(compareLocalCommand(_:)), target: self)
                    item.tag = action.rawValue
                    submenu.addItem(item)
                }
                parent.submenu = submenu
                actions.insert(parent, at: 2)
            }
            return ToolWindowMenuOwnership.reviewMenu(from: base, window: window, actions: actions)
        }
    }

    func windowDidResignKey(_ notification: Notification) { ToolWindowMenuOwnership.release(self) }

    func windowWillClose(_ notification: Notification) {
        model.close()
        snapshot?.window.window?.performClose(nil)
        diff?.window?.performClose(nil)
        ToolWindowMenuOwnership.release(self)
        didClose?()
    }

    #if DEBUG
    var snapshotForVerification: NativeTextSnapshotController? { snapshot }
    var diffForVerification: EditorComparisonWindow? { diff }
    #endif
}

@MainActor extension BrowserWorkspaceController {
    func presentGitFileHistory(access: GitReviewAccess, parent: NSWindow, settings: BrowserSettings, path: GitSnapshotPath,
                               startingAt commit: GitObjectID? = nil, local: GitLocalFileReview?) {
        guard !isClosing else { return }
        if let existing = gitFileHistoryWindow, existing.matches(access.location, path: path, startingAt: commit) {
            existing.present()
            return
        }
        gitFileHistoryWindow?.window?.performClose(nil)
        let history = GitFileHistoryWindow(parent: parent, settings: settings, access: access, path: path, startingAt: commit, local: local)
        gitFileHistoryWindow = history
        history.didClose = { [weak self, weak history] in
            if self?.gitFileHistoryWindow === history { self?.gitFileHistoryWindow = nil }
        }
        history.present()
    }
}

@MainActor extension NativeTextSnapshotController {
    static func gitVersion(text: TextDocumentValue, member: GitSnapshotMember, commit: GitObjectID,
                           access: GitReviewAccess, settings: BrowserSettings, parent: NSWindow) -> NativeTextSnapshotController {
        let name = member.path.name
        let context = EditorLocationContext(label: access.location.root.lastPathComponent + " › " + member.path.display,
            detail: "Git commit " + commit.hex + "\n" + member.path.display, symbol: "arrow.triangle.branch")
        let view = NativeTextSnapshotController(contents: text, filename: name, title: name + " · " + commit.short,
            location: context, status: "Read-only Git revision · " + commit.short, settings: settings)
        view.window.gitLineReview = GitLineReview(editor: view.window, access: access, member: member, commit: commit, settings: settings)
        if let native = view.window.window { ToolWindowChrome.position(native, relativeTo: parent) }
        return view
    }
}

private struct GitFileHistoryContent: View {
    @ObservedObject var model: GitFileHistoryModel
    let open: () -> Void
    let compare: () -> Void
    let compareBase: () -> Void
    let compareWith: (GitRevisionOption) -> Void
    let openAt: (GitRevisionOption) -> Void
    let compareRevisionWithLocal: (GitRevisionOption, GitLocalFileReview.Source) -> Void
    let compareLocal: (GitLocalDiff) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.path.display, systemImage: "doc.text").interfaceFont(.headline)
                    .lineLimit(1).truncationMode(.middle).help(model.path.display)
                Spacer(minLength: 4)
                Button("Filter This History Page", systemImage: "magnifyingglass", action: model.showFilter)
                    .labelStyle(.iconOnly).help("Filter this history page (⌘F)").disabled(!model.canFilter)
                if model.busy { Button("Stop", role: .cancel, action: model.stop).keyboardShortcut(.cancelAction) }
                else { Button("Reload", systemImage: "arrow.clockwise", action: model.reload).help("Reload revisions and return to the start of history") }
            }
            HStack(spacing: 10) {
                GitRevisionPicker(label: "History starting at", selected: model.startingRevision, choices: model.revisions) {
                    model.choose($0, path: model.path)
                }
                revisionActions
                if model.paths.count > 1 {
                    Menu("File path", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                        ForEach(model.paths, id: \.self) { path in
                            Button(path.display) { model.choosePath(path) }.disabled(path == model.path)
                        }
                    }.help("Choose a path recorded in this file’s rename history")
                }
            }.disabled(model.busy)
            Divider()
            if let filterID = model.filterID { filter(filterID) }
            if model.history?.entries.isEmpty == false {
                let visible = model.visibleEntries
                if visible.isEmpty {
                    ContentUnavailableView("No matching revisions on this page", systemImage: "magnifyingglass")
                } else { entries(visible) }
            } else if model.busy {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No file history", systemImage: "clock.arrow.circlepath",
                    description: Text("Choose another revision or a path from this file’s history."))
            }
            if let base = model.comparisonBase { baseBar(base) }
            ViewThatFits(in: .horizontal) {
                HStack { paging; Spacer(minLength: 8); fileActions }
                VStack(alignment: .leading, spacing: 8) {
                    paging
                    fileActions.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }.padding(16)
    }

    private var paging: some View {
        HStack {
            if model.pageNumber > 1 || model.history?.older != nil {
                Button("Newer Changes", systemImage: "chevron.left", action: model.goNewer)
                    .labelStyle(.iconOnly).help("Newer changes (⌘[)").disabled(!model.canGoNewer)
                Button("Older Changes", systemImage: "chevron.right", action: model.goOlder)
                    .labelStyle(.iconOnly).help("Older changes (⌘])").disabled(!model.canGoOlder)
            }
            Text(summary).interfaceFont(.caption).foregroundStyle(.secondary)
                .lineLimit(2).accessibilityIdentifier("git-file-history-status")
        }
    }

    private var fileActions: some View {
        HStack {
            if model.local != nil {
                Menu("Compare Local", systemImage: "square.split.2x1") {
                    ForEach(GitLocalDiff.allCases, id: \.rawValue) { action in
                        Button(action.title) { compareLocal(action) }.disabled(!action.isAvailable(in: model))
                    }
                }.disabled(model.busy)
            }
            Button(model.compareTitle, systemImage: "doc.on.doc", action: compare)
                .disabled(!model.canCompare).help(model.compareTitle + " (⌘↩)")
            Button("Open Version", systemImage: "doc.text", action: open).disabled(!model.canOpen)
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var revisionActions: some View {
        let canCompare = model.startingCommit != nil
        let alternatives: GitRevisionPicker.ActionGroup? = model.local == nil ? nil : .init(title: "Compare with",
            items: GitLocalFileReview.Source.allCases.map { source in
                .init(title: source.rawValue, enabled: source != .draft || model.hasDraft) { compareRevisionWithLocal($0, source) }
            })
        return GitRevisionPicker(label: "Open or Compare Revision", selected: nil, choices: model.revisions,
            submitTitle: canCompare ? "Compare Revisions" : "Open Version",
            alternate: canCompare ? .init(title: "Open Version", perform: openAt) : nil,
            group: alternatives, onSelection: canCompare ? compareWith : openAt)
    }

    private var summary: String {
        if !model.message.isEmpty { return model.message }
        guard let history = model.history else { return "" }
        let count = history.entries.count
        var changes = "\(count) \(count == 1 ? "change" : "changes")"
        if model.pageNumber > 1 || history.older != nil { changes += " · Page \(model.pageNumber)" }
        else { changes += " along the first-parent history" }
        if model.atPageLimit, history.older != nil { return changes + " · Choose an older starting commit to continue." }
        if history.isShallow, history.older == nil { return changes + " · This repository has limited local history." }
        return changes
    }

    private func baseBar(_ base: GitFileHistory.Entry) -> some View {
        HStack(spacing: 8) {
            let name = base.after?.path.display ?? "Absent"
            Label("Base \(base.id.short) · \(name)", systemImage: "pin")
                .interfaceFont(.caption).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary).help(base.id.hex + "\n" + name)
            Spacer(minLength: 8)
            Button("Compare with Base", systemImage: "square.split.2x1", action: compareBase)
                .disabled(!model.canCompareWithBase).help("Compare with Base (⌥⌘↩)")
            Button("Clear Comparison Base", systemImage: "xmark", action: model.clearBase)
                .labelStyle(.iconOnly).disabled(model.busy)
        }
    }

    private func filter(_ id: UUID) -> some View {
        HStack(spacing: 8) {
            NativeQueryField(text: Binding(get: { model.query }, set: model.setQuery),
                identifier: "git-history-filter", placeholder: "Filter this page by commit, message or path",
                style: .focusedSearch) { command in
                    switch command {
                    case .submit: if model.canOpen { open() }
                    case .cancel: model.hideFilter()
                    case .down: model.moveFilteredSelection(by: 1)
                    case .up: model.moveFilteredSelection(by: -1)
                    }
                    return true
                }.id(id).disabled(model.busy)
            Text("\(model.visibleEntries.count) of \(model.history?.entries.count ?? 0)")
                .interfaceFont(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button("Close Filter", systemImage: "xmark", action: model.hideFilter).labelStyle(.iconOnly)
        }
    }

    private func entries(_ rows: [GitFileHistory.Entry]) -> some View {
        Table(rows, selection: $model.selectedCommits) {
            TableColumn("Commit") { entry in
                GitCommitLabel(commit: entry.commit)
            }.width(min: 140, ideal: 275)
            TableColumn("File") { entry in
                let name = entry.after?.path.display ?? entry.before?.path.display ?? ""
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).lineLimit(1).truncationMode(.middle)
                    if entry.kind == .renamed, let before = entry.before {
                        Text("From " + before.path.display).interfaceFont(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }.help(name)
            }.width(min: 120, ideal: 245)
            TableColumn("Change") { entry in
                Text(entry.kind == .typeChanged ? "Type changed" : entry.kind.rawValue.capitalized)
            }.width(min: 78, ideal: 100)
            TableColumn("Date") { entry in
                GitCommitDateLabel(date: entry.commit.date)
            }.width(min: 90, ideal: 128)
        }
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .accessibilityLabel("Committed versions of this file")
        .disabled(model.busy)
    }
}
