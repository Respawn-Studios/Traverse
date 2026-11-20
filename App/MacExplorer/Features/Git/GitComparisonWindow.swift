import AppKit
import FileOperations
import LocalStorage
import SwiftUI

private extension GitTreeComparison.Basis {
    var title: String {
        switch self {
        case .selectedRevisions: "Selected Revisions"
        case .commonAncestor: "Since Common Ancestor"
        }
    }
}

@MainActor final class GitComparisonWindow: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    fileprivate static let compareEditorTitle = "Compare Revision with Open Editor"
    fileprivate static let openWorkingTitle = "Open Working File in Editor"

    let model: GitComparisonModel
    var didClose: (() -> Void)?
    var onDiff: ((EditorComparisonWindow.Labels, EditorComparisonWindow.FileList?, @escaping EditorComparisonWindow.TextRead) -> Void)?
    var onFileHistory: ((GitComparisonModel.FileHistorySource) -> Void)?
    var onOpenWorkingFile: ((LocalTextOpenSelection, NSWindow) -> Void)?

    init(parent: NSWindow, settings: BrowserSettings, access: GitReviewAccess, mode: GitComparisonModel.Mode,
         pairedWith peer: GitReviewAccess? = nil) {
        model = GitComparisonModel(access: access, mode: mode, pairedWith: peer, showHidden: { settings.showsHiddenFiles })
        let viewport = ToolWindowChrome.initialViewport(size: .init(width: 1080, height: 670),
            minimum: .init(width: 630, height: 400), scale: settings.interfaceSize.scale, screen: parent.screen)
        let native = ToolWindowChrome.makeWindow(title: mode.title + " — Traverse", size: viewport.size,
            minimumSize: viewport.minimum)
        super.init(window: native)
        native.delegate = self
        native.contentViewController = InterfaceHostingController(rootView: GitComparisonContent(model: model, settings: settings,
            openDiff: { [weak self] in self?.openDiff(nil) }, compareEditor: { [weak self] in self?.compareWorkingEditor(nil) },
            findDiffs: { [weak self] in self?.findAcrossDiffs(nil) },
            openWorkingFile: { [weak self] in self?.openWorkingFile(nil) },
            unstageFile: { [weak self] in self?.unstageFile(nil) },
            stageWorkingPath: { [weak self] removal in self?.stageWorkingPath(removal: removal) },
            openHistory: { [weak self] in self?.onFileHistory?($0) }))
        ToolWindowChrome.install(in: native, settings: settings,
            initialContentSize: viewport.size, minimumContentSize: viewport.minimum)
        ToolWindowChrome.position(native, relativeTo: parent)
    }

    required init?(coder: NSCoder) { nil }

    func present() { window?.makeKeyAndOrderFront(nil) }

    @objc func openDiff(_ sender: Any?) {
        openDiff(startingSearch: false)
    }

    @objc func findAcrossDiffs(_ sender: Any?) {
        guard window?.isKeyWindow == true, model.canFindAcrossDiffs else { return }
        openDiff(startingSearch: true)
    }

    private func openDiff(startingSearch: Bool) {
        let access = model.access
        if model.mode == .working {
            openWorkingDiff(startingSearch: startingSearch)
            return
        }
        let listsChanges = model.presentation == .changes || model.presentation == .commits
        let visible = listsChanges ? model.visibleChanges.filter(\.canCompareText) : []
        let selected = (listsChanges && model.selected?.canCompareText == true ? model.selected : nil)
            ?? (startingSearch ? visible.first : nil)
        guard let pair = selected.map({ ($0.left, $0.right) }) ?? model.textPair else { return }
        let conflicts = model.presentation == .conflicts
        let labels = conflicts ? model.conflictPair.labels : model.comparisonLabels()
        let detail: String
        if conflicts { detail = "Read-only versions from Git’s unmerged index stages." }
        else if model.mode == .index { detail = "Text from the captured Git index and base revision." }
        else if model.presentation == .commits { detail = "The selected commit’s change relative to the displayed parent." }
        else { detail = "Read-only text from the selected Git commits." }
        let repositoryName = model.location.root.lastPathComponent
        let indexBase = !conflicts && model.staged?.comparesHead == true ? model.staged?.base : nil
        let review = model
        func entry(_ left: GitSnapshotMember?, _ right: GitSnapshotMember?) -> EditorComparisonWindow.Source {
            var source = EditorComparisonWindow.Source(labels: .init(title: "Git Text Diff", source: right?.path.display ?? left?.path.display ?? repositoryName,
                left: labels.left + " · " + (left?.path.display ?? "Absent"),
                right: labels.right + " · " + (right?.path.display ?? "Absent"), detail: detail, refresh: "Refresh"),
                read: { try await access.textComparison(left: left, right: right) })
            if let indexBase, let left, let right, left.path == right.path, left.kind == right.kind, right.isTextCandidate {
                source.editIndexChange = Self.indexEdit(for: right.path, in: review) { .unstageReviewedChange(head: indexBase, $0) }
            }
            return source
        }
        var files: EditorComparisonWindow.FileList?
        if let selected {
            // The visible list contains pinned blob IDs and paths only. Each
            // explicit step reads just its selected pair through GitReviewAccess.
            if let index = visible.firstIndex(where: { $0.id == selected.id }) {
                files = .init(count: visible.count, initialIndex: index, excludedCount: model.visibleChanges.count - visible.count,
                    startsWithSearch: startingSearch, indexAction: indexBase == nil ? nil : .unstage, entryAt: { index in
                    entry(visible[index].left, visible[index].right)
                })
            }
        }
        let initial = entry(pair.0, pair.1)
        onDiff?(initial.labels, files, initial.read)
    }

    private func openWorkingDiff(startingSearch: Bool) {
        guard let folder = model.workingFolder, !model.busy, !model.filteringChanges else { return }
        let access = model.access
        let selections = model.visibleWorkingTextSelections()
        guard let index = selections.firstIndex(where: { $0.path == model.selectedMember })
            ?? (startingSearch && !selections.isEmpty ? 0 : nil) else { return }
        let revisionLabel = folder.revision?.short ?? "Git Index"
        let detail = folder.comparesIndex ? "Git index text and the selected version on disk." : "Committed text and the selected version on disk."
        let review = model
        func entry(_ index: Int) -> EditorComparisonWindow.Source {
            let selection = selections[index]
            let left = revisionLabel + " · " + (selection.referenceMember?.path.display ?? "Absent")
            let right = "Working Folder · " + (selection.existsOnDisk ? selection.path.display : "Absent")
            var entry = EditorComparisonWindow.Source(labels: .init(title: "Git Text Diff", source: selection.path.display,
                left: left, right: right, detail: detail, refresh: "Refresh"),
                read: { try await access.workingComparison(selection) })
            if selection.referenceMember != nil, let staged = folder.stagingSelection(for: selection.path), !staged.isRemoval {
                entry.editIndexChange = Self.indexEdit(for: selection.path, in: review) { .stageReviewedChange(staged, $0) }
            }
            return entry
        }
        let initial = entry(index)
        let excluded = model.visibleWorkingRows.lazy.filter { !$0.isFolder }.count - selections.count
        let files = EditorComparisonWindow.FileList(count: selections.count, initialIndex: index,
            excludedCount: excluded, startsWithSearch: startingSearch, indexAction: folder.comparesIndex ? .stage : nil,
            entryAt: entry)
        onDiff?(initial.labels, files, initial.read)
    }

    private static func indexEdit(for path: GitSnapshotPath, in review: GitComparisonModel,
                                  action: @escaping (GitIndexTextChange) -> GitIndexEditAction)
        -> EditorComparisonWindow.EditIndexChange {
        let access = review.access
        return { [weak review] window, plan, change, isCurrent in
            let selected = try GitIndexTextChange(before: plan.before, after: plan.current,
                beforeLines: change.beforeLines, afterLines: change.currentLines)
            let action = action(selected)
            let outcome = try await GitIndexEditFlow.run(action, path: path, using: access, in: window, isCurrent: isCurrent)
            guard case .changed = outcome else { return false }
            review?.load(successNotice: outcome.notice(for: action), selecting: path)
            return true
        }
    }

    @objc func compareWorkingEditor(_ sender: Any?) {
        guard window?.isKeyWindow == true, let selection = model.workingTextSelection,
              let folder = model.workingFolder, let url = selection.workingFileURL,
              let capture = ApplicationLocalTextEditors.shared.capturedEditorSource(for: url) else { return }
        let access = model.access
        let left = (folder.revision?.short ?? "Git Index") + " · " + (selection.referenceMember?.path.display ?? "Absent")
        let detail = folder.comparesIndex ? "Compare the captured Git index with this editor’s unsaved text."
            : "Compare the pinned revision with the open editor, including unsaved changes."
        onDiff?(.init(title: "Git Text Diff", source: selection.path.display, left: left,
            right: "Editor Buffer · " + url.lastPathComponent,
            detail: detail, refresh: "Refresh Editor"), nil) {
            guard let current = capture() else {
                throw EditorComparisonLoadFailure.unavailable("The original editor moved, closed or is busy. Open a new comparison to use another editor.")
            }
            return .init(left: try await access.workingReference(selection), right: current)
        }
    }

    @objc private func openWorkingFile(_ sender: Any?) {
        guard let window, window.isKeyWindow, window.attachedSheet == nil,
              let path = model.selectedMember, let selection = model.workingOpenSelection(for: path) else { return }
        onOpenWorkingFile?(selection, window)
    }

    @objc func unstageFile(_ sender: Any?) {
        guard let window, !(window.firstResponder is NSTextView) else { return }
        model.unstage(in: window)
    }

    @objc private func stageWorkingPath(_ sender: NSMenuItem) { stageWorkingPath(removal: sender.tag == 1) }

    private func stageWorkingPath(removal: Bool) {
        guard let window, !(window.firstResponder is NSTextView) else { return }
        model.stageWorkingPath(removal: removal, in: window)
    }

    @objc func enterFolder(_ sender: Any?) { if let path = model.selectedFolder { model.enter(path) } }
    @objc private func upFolder(_ sender: Any?) { model.goUp() }

    @objc private func refresh(_ sender: Any?) { model.load() }
    @objc private func checkWorkingContents(_ sender: Any?) { model.checkWorkingContents() }
    @objc private func toggleWorkingIndex(_ sender: Any?) {
        model.setWorkingBaseline(model.workingBaseline == .index ? .revision : .index)
    }
    @objc private func toggleMatchingFiles(_ sender: Any?) { model.setHidesMatchingFiles(!model.hidesMatchingFiles) }
    private var filterTitle: String {
        if model.showsCommitList { return "Filter Commits…" }
        return model.mode == .working ? "Filter Folder Paths…" : "Filter Changed Files…"
    }
    @objc private func filterReview(_ sender: Any?) {
        if model.showsCommitList { model.showCommitFilter() }
        else { model.showChangeFilter() }
    }
    @objc private func inspectCommit(_ sender: Any?) { model.inspectSelectedCommit() }
    @objc private func backToCommits(_ sender: Any?) { model.returnToCommitRange() }
    @objc private func newerCommits(_ sender: Any?) { model.changeHistoryPage(older: false) }
    @objc private func olderCommits(_ sender: Any?) { model.changeHistoryPage(older: true) }

    @objc private func openFileHistory(_ item: NSMenuItem) {
        guard window?.isKeyWindow == true, let side = GitComparisonModel.Side(rawValue: item.tag),
              let source = model.selectedFileHistory(on: side) else { return }
        onFileHistory?(source)
    }

    @objc private func chooseBasis(_ item: NSMenuItem) {
        let options = GitTreeComparison.Basis.allCases
        if options.indices.contains(item.tag) { model.setBasis(options[item.tag]) }
    }

    @objc private func choosePresentation(_ item: NSMenuItem) {
        if model.presentations.indices.contains(item.tag) { model.setPresentation(model.presentations[item.tag]) }
    }

    @objc private func chooseChangeKind(_ item: NSMenuItem) {
        guard window?.isKeyWindow == true, GitComparisonModel.changeKinds.indices.contains(item.tag) else { return }
        model.setChangeKind(GitComparisonModel.changeKinds[item.tag])
    }

    @objc private func chooseConflictPair(_ item: NSMenuItem) {
        let pairs = GitComparisonModel.ConflictPair.allCases
        if pairs.indices.contains(item.tag) { model.setConflictPair(pairs[item.tag]) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(openWorkingFile(_:)) {
            return window?.isKeyWindow == true && window?.attachedSheet == nil && !(window?.firstResponder is NSTextView)
                && onOpenWorkingFile != nil && model.selectedMember.flatMap(model.workingOpenSelection(for:)) != nil
        }
        if item.action == #selector(compareWorkingEditor(_:)) {
            return window?.isKeyWindow == true && !(window?.firstResponder is NSTextView)
                && model.selectedMember.map(model.hasWorkingEditor(for:)) == true
        }
        if item.action == #selector(openDiff(_:)) {
            return window?.isKeyWindow == true && !(window?.firstResponder is NSTextView)
                && model.canOpenTextDiff
        }
        if item.action == #selector(findAcrossDiffs(_:)) {
            return window?.isKeyWindow == true && model.canFindAcrossDiffs
        }
        if item.action == #selector(unstageFile(_:)) {
            return model.canUnstageSelection && window?.isKeyWindow == true
                && window?.attachedSheet == nil && !(window?.firstResponder is NSTextView)
        }
        if item.action == #selector(stageWorkingPath(_:)) {
            return model.canStageWorkingPath(removal: item.tag == 1) && window?.isKeyWindow == true
                && window?.attachedSheet == nil && !(window?.firstResponder is NSTextView)
        }
        if item.action == #selector(enterFolder(_:)) { return window?.isKeyWindow == true && !model.busy && model.selectedFolder != nil }
        if item.action == #selector(upFolder(_:)) { return window?.isKeyWindow == true && model.canGoUp }
        if item.action == #selector(checkWorkingContents(_:)) { return window?.isKeyWindow == true && model.canCheckWorkingContents }
        if item.action == #selector(toggleWorkingIndex(_:)) {
            item.state = model.workingBaseline == .index ? .on : .off
            return window?.isKeyWindow == true && !model.busy && model.mode == .working
        }
        if item.action == #selector(toggleMatchingFiles(_:)) {
            item.state = model.hidesMatchingFiles ? .on : .off
            return window?.isKeyWindow == true && !model.busy && model.workingContents != nil
        }
        if item.action == #selector(openFileHistory(_:)) {
            guard let side = GitComparisonModel.Side(rawValue: item.tag) else { return false }
            return window?.isKeyWindow == true && model.selectedFileHistory(on: side) != nil
        }
        if item.action == #selector(filterReview(_:)) {
            item.title = filterTitle
            return window?.isKeyWindow == true && (model.canFilterChanges || model.canFilterCommits)
        }
        if item.action == #selector(chooseChangeKind(_:)) {
            item.state = GitComparisonModel.changeKinds.firstIndex(of: model.changeKind) == item.tag ? .on : .off
            return window?.isKeyWindow == true && model.canFilterChangeKinds
        }
        if item.action == #selector(inspectCommit(_:)) { return window?.isKeyWindow == true && model.canInspectCommit }
        if item.action == #selector(newerCommits(_:)) { return window?.isKeyWindow == true && model.canReadNewerCommits }
        if item.action == #selector(olderCommits(_:)) { return window?.isKeyWindow == true && model.canReadOlderCommits }
        if item.action == #selector(backToCommits(_:)) {
            return window?.isKeyWindow == true && !model.busy && model.presentation == .commits && model.commitChanges != nil
        }
        if item.action == #selector(chooseBasis(_:)) {
            item.state = GitTreeComparison.Basis.allCases.firstIndex(of: model.basis) == item.tag ? .on : .off
            return window?.isKeyWindow == true && !model.busy && model.presentation != .commits && model.left != nil && model.right != nil
        }
        if item.action == #selector(choosePresentation(_:)) {
            item.state = model.presentations.firstIndex(of: model.presentation) == item.tag ? .on : .off
            return window?.isKeyWindow == true && !model.busy && model.summary != nil
        }
        if item.action == #selector(chooseConflictPair(_:)) {
            item.state = GitComparisonModel.ConflictPair.allCases.firstIndex(of: model.conflictPair) == item.tag ? .on : .off
            return window?.isKeyWindow == true && !model.busy && model.presentation == .conflicts && model.staged?.conflicts.isEmpty == false
        }
        return item.action != #selector(refresh(_:)) || (window?.isKeyWindow == true && !model.busy)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        _ = ToolWindowMenuOwnership.claim(self) { base in
            let basisCommands = GitTreeComparison.Basis.allCases.enumerated().map { index, basis in
                let item = BrowserMenus.item(basis.title, #selector(chooseBasis(_:)), target: self)
                item.tag = index
                return item
            }
            var actions = [BrowserMenus.item("Open Text Diff", #selector(openDiff(_:)), key: "\r", modifiers: [], target: self)]
            let historySides: [GitComparisonModel.Side] = model.mode.supportsCommitInspection ? [.left, .right] : [.left]
            actions += historySides.map { side in
                let title = model.mode.supportsCommitInspection ? side.historyTitle : "Committed File History…"
                let item = BrowserMenus.item(title, #selector(openFileHistory(_:)), target: self)
                item.tag = side.rawValue
                return item
            }
            if model.mode == .working || model.mode == .revisions {
                actions += [BrowserMenus.item("Open Folder", #selector(enterFolder(_:)), key: "\r", modifiers: [], target: self),
                            BrowserMenus.item("Up a Folder", #selector(upFolder(_:)), key: String(UnicodeScalar(NSUpArrowFunctionKey)!), target: self)]
            }
            actions.append(BrowserMenus.item(model.mode.reloadTitle, #selector(refresh(_:)), key: "r", target: self))
            if model.mode == .index {
                actions.append(BrowserMenus.item("Unstage File…", #selector(unstageFile(_:)), target: self))
            }
            if model.mode == .working {
                let stage = BrowserMenus.item("Stage Saved File…", #selector(stageWorkingPath(_:)), target: self)
                let removal = BrowserMenus.item("Stage File Removal…", #selector(stageWorkingPath(_:)), target: self)
                removal.tag = 1
                actions += [stage, removal]
                actions.append(BrowserMenus.item(Self.openWorkingTitle, #selector(openWorkingFile(_:)), target: self))
                actions.append(BrowserMenus.item(Self.compareEditorTitle, #selector(compareWorkingEditor(_:)),
                    key: "\r", modifiers: [.option], target: self))
                actions.append(BrowserMenus.item("Check Contents", #selector(checkWorkingContents(_:)), target: self))
            }
            if model.mode.supportsCommitInspection {
                actions.append(BrowserMenus.item("Review Selected Commit", #selector(inspectCommit(_:)), key: "\r", modifiers: [], target: self))
                actions.append(BrowserMenus.item("Back to Commits", #selector(backToCommits(_:)), key: "[", target: self))
            }
            if model.mode == .revisions { actions += basisCommands }
            if model.mode == .folderHistory {
                actions.append(BrowserMenus.item("Newer Commits", #selector(newerCommits(_:)), target: self))
                actions.append(BrowserMenus.item("Older Commits", #selector(olderCommits(_:)), target: self))
            }
            var views = model.presentations.enumerated().map { index, mode in
                let item = BrowserMenus.item("Show " + mode.rawValue, #selector(choosePresentation(_:)), target: self)
                item.tag = index
                return item
            }
            if model.mode == .working {
                views.append(BrowserMenus.item("Compare with Git Index", #selector(toggleWorkingIndex(_:)), target: self))
                views.append(BrowserMenus.item("Hide Matching Files", #selector(toggleMatchingFiles(_:)), target: self))
            }
            views.insert(BrowserMenus.item(filterTitle, #selector(filterReview(_:)), key: "f", target: self), at: 0)
            views.insert(BrowserMenus.item("Find Across Diffs…", #selector(findAcrossDiffs(_:)), key: "F", target: self), at: 1)
            if model.mode == .index {
                views.append(.separator())
                views += GitComparisonModel.ConflictPair.allCases.enumerated().map { index, pair in
                    let item = BrowserMenus.item("Compare " + pair.rawValue, #selector(chooseConflictPair(_:)), target: self)
                    item.tag = index
                    return item
                }
            }
            let menu = ToolWindowMenuOwnership.reviewMenu(from: base, window: window, actions: actions, viewActions: views)
            if model.mode != .working, let viewMenu = menu.item(withTitle: "View")?.submenu {
                BrowserMenus.addSection("Change Type", to: viewMenu) { filter in
                    for (index, kind) in GitComparisonModel.changeKinds.enumerated() {
                        let item = BrowserMenus.item(GitComparisonModel.changeKindLabel(kind),
                            #selector(chooseChangeKind(_:)), target: self)
                        item.tag = index
                        filter.addItem(item)
                    }
                }
            }
            return menu
        }
    }

    func windowDidResignKey(_ notification: Notification) { ToolWindowMenuOwnership.release(self) }

    func windowWillClose(_ notification: Notification) {
        model.close()
        ToolWindowMenuOwnership.release(self)
        didClose?()
    }
}

private struct GitComparisonContent: View {
    @ObservedObject var model: GitComparisonModel
    @ObservedObject var settings: BrowserSettings
    let openDiff: () -> Void
    let compareEditor: () -> Void
    let findDiffs: () -> Void
    let openWorkingFile: () -> Void
    let unstageFile: () -> Void
    let stageWorkingPath: (Bool) -> Void
    let openHistory: (GitComparisonModel.FileHistorySource) -> Void
    @State private var stacksFolders = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.folderLabel, systemImage: "folder").interfaceFont(.headline)
                    .lineLimit(1).truncationMode(.middle).help(model.location.root.path)
                Spacer(minLength: 6)
                if model.busy { Button("Stop", role: .cancel, action: model.stop).keyboardShortcut(.cancelAction) }
                else { Button(model.mode.reloadTitle, systemImage: "arrow.clockwise") { model.load() } }
            }
            HStack(spacing: 10) {
                if model.mode == .working, model.workingBaseline == .index {
                    Label("Git Index", systemImage: "tray.full").interfaceFont(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    GitRevisionPicker(label: model.mode.primaryRevisionLabel, selected: model.left,
                                      choices: model.choices) { model.choose($0, for: .left) }
                }
                if model.mode == .working || model.mode == .index {
                    Label(model.mode == .working ? "Working Folder" : "Git Index",
                          systemImage: model.mode == .working ? "folder" : "tray.full").interfaceFont(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if model.mode == .revisions {
                    Button("Swap revisions", systemImage: "arrow.left.arrow.right", action: model.swap)
                        .labelStyle(.iconOnly).help("Swap the left and right revisions")
                        .disabled(model.left == nil || model.right == nil)
                    GitRevisionPicker(label: "Right revision", selected: model.right, choices: model.choices) { model.choose($0, for: .right) }
                }
            }.disabled(model.busy)
            if model.mode == .working {
                ViewThatFits(in: .horizontal) {
                    HStack { workingBaselinePicker; Spacer(minLength: 12); scopeToggle }
                    VStack(alignment: .leading, spacing: 6) { workingBaselinePicker; scopeToggle }
                }.disabled(model.busy)
            } else if model.mode != .revisions || model.presentation == .commits { scopeToggle.disabled(model.busy) }
            else { comparisonOptions }
            if !model.presentations.isEmpty {
                Picker("Git review view", selection: Binding(get: { model.presentation }, set: model.setPresentation)) {
                    ForEach(model.presentations, id: \.self) { value in Text(value.rawValue).tag(value) }
                }.pickerStyle(.segmented).labelsHidden().disabled(model.busy || model.summary == nil)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if model.presentation == .commits, model.mode == .folderHistory || model.summary != nil {
                    commitRangeView()
                } else if let folder = model.workingFolder {
                    workingFolder(folder)
                } else if let summary = model.summary {
                    if model.presentation == .folders {
                        folderViews()
                    } else if model.presentation == .conflicts {
                        conflicts(model.staged?.conflicts ?? [])
                    } else if summary.changes.isEmpty {
                        ContentUnavailableView(model.mode == .index ? "No staged differences in this scope" : "No changes in this folder",
                            systemImage: "checkmark.circle")
                    } else {
                        changeList(summary)
                    }
                    if model.presentation == .changes, !model.notice.isEmpty {
                        Text(model.notice).interfaceFont(.caption).foregroundStyle(.secondary)
                    }
                    footer(summary)
                } else if model.busy {
                    ProgressView(model.notice).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Git comparison", systemImage: "arrow.triangle.branch", description: Text(model.notice))
                }
            }.toolPageCrossfade(model.presentation.rawValue + (model.commitChanges?.entry.id.hex ?? ""), motion: settings.motion)
        }.padding(16)
    }

    @ViewBuilder private func commitRangeView() -> some View {
        if let details = model.commitChanges {
            commitDetails(details)
        } else if let page = model.folderHistory {
            folderCommitList(page)
        } else if let range = model.commitRange {
            exclusiveCommitList(range)
        } else if model.busy {
            ProgressView(model.notice).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Commit history unavailable", systemImage: "arrow.triangle.branch")
            } description: {
                Text(model.notice)
            } actions: {
                Button("Read Commits") {
                    if model.mode == .folderHistory { model.load() }
                    else { model.readCommitRange() }
                }
            }
        }
    }

    @ViewBuilder private func commitDetails(_ details: GitCommitChanges) -> some View {
        HStack(spacing: 8) {
            Button("Back to Commits", systemImage: "chevron.left", action: model.returnToCommitRange).disabled(model.busy)
            Text(details.entry.commit.subject.isEmpty ? "Untitled commit" : details.entry.commit.subject)
                .interfaceFont(.headline).lineLimit(1).truncationMode(.tail)
                .help(details.entry.commit.subject)
            Spacer(minLength: 4)
            if details.entry.parents.count > 1, let parent = details.parent {
                Picker("Parent", selection: Binding(get: { parent }, set: model.selectCommitParent)) {
                    ForEach(Array(details.entry.parents.enumerated()), id: \.element) { index, item in
                        Text("\(index + 1) · \(item.short)").tag(item)
                    }
                }.fixedSize().disabled(model.busy)
            }
        }
        if details.summary.changes.isEmpty {
            ContentUnavailableView("No files changed in this scope", systemImage: "checkmark.circle")
        } else { changeList(details.summary) }
        if !model.notice.isEmpty { Text(model.notice).interfaceFont(.caption).foregroundStyle(.secondary) }
        footer(details.summary)
    }

    @ViewBuilder private func folderCommitList(_ page: GitFolderHistory) -> some View {
        if page.commits.isEmpty {
            ContentUnavailableView("No commits in this scope", systemImage: "clock",
                description: Text("Try another revision or show the whole repository."))
        } else { commitList() }
        folderHistoryControls(page)
    }

    @ViewBuilder private func exclusiveCommitList(_ range: GitCommitRange) -> some View {
        if model.commitRows.isEmpty {
            ContentUnavailableView("No exclusive commits", systemImage: "checkmark.circle",
                description: Text(range.isShallow ? "The available shallow history has no commits unique to either side." : "Both revisions share the same local commit history."))
        } else { commitList() }
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(range.left.commits.count)\(range.left.hasMore ? "+" : "") left only · \(range.right.commits.count)\(range.right.hasMore ? "+" : "") right only")
                if range.isShallow { Text("Shallow repository · Local history only") }
                if model.rangeSelection?.canReviewChanges == false { Text("The selected commit’s parent history is unavailable.") }
                if !model.notice.isEmpty { Text(model.notice) }
            }.interfaceFont(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("Review Commit", systemImage: "doc.text.magnifyingglass", action: model.inspectSelectedCommit)
                .disabled(!model.canInspectCommit)
        }
    }

    private func folderHistoryControls(_ page: GitFolderHistory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Page \(model.folderHistoryPage) · First-parent history")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Newer", systemImage: "chevron.left") { model.changeHistoryPage(older: false) }
                    .disabled(!model.canReadNewerCommits)
                Button("Older", systemImage: "chevron.right") { model.changeHistoryPage(older: true) }
                    .disabled(!model.canReadOlderCommits)
                Button("Review Commit", systemImage: "doc.text.magnifyingglass", action: model.inspectSelectedCommit)
                    .disabled(!model.canInspectCommit)
            }
            if page.isShallow || model.atFolderHistoryPageLimit || model.rangeSelection?.canReviewChanges == false || !model.notice.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    if page.isShallow { Text("Shallow repository · Local history only") }
                    if model.atFolderHistoryPageLimit { Text("Browse further by choosing an older commit.") }
                    if model.rangeSelection?.canReviewChanges == false { Text("The selected commit’s parent history is unavailable.") }
                    if !model.notice.isEmpty { Text(model.notice) }
                }.interfaceFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func commitList() -> some View {
        let rows = model.visibleCommitRows
        if let id = model.commitFilterID {
            ReviewFilterField(query: Binding(get: { model.commitQuery }, set: model.setCommitQuery),
                identifier: "git-commit-filter", placeholder: "Filter loaded commits by message or ID",
                visibleCount: rows.count, totalCount: model.commitRows.count,
                isFiltering: false, dismiss: model.hideCommitFilter) { command in
                    switch command {
                    case .submit: model.inspectSelectedCommit()
                    case .cancel: model.hideCommitFilter()
                    case .down: model.moveFilteredSelection(by: 1)
                    case .up: model.moveFilteredSelection(by: -1)
                    }
                    return true
                }.id(id).disabled(model.busy)
        }
        if rows.isEmpty { ContentUnavailableView("No matching commits", systemImage: "magnifyingglass") }
        else { commitTable(rows) }
    }

    private func commitTable(_ rows: [GitComparisonModel.CommitRow]) -> some View {
        Table(rows, selection: $model.selectedRangeCommit) {
            TableColumn("Commit") { row in GitCommitLabel(commit: row.commit.commit) }.width(min: 180, ideal: 400)
            TableColumn("Side") { row in
                if let side = row.side { Text(side == .left ? "Left" : "Right").foregroundStyle(.secondary) }
            }
                .width(min: 68, ideal: 86, max: 105)
                .defaultVisibility(model.mode == .folderHistory ? .hidden : .visible)
            TableColumn("Date") { row in GitCommitDateLabel(date: row.commit.commit.date) }.width(min: 90, ideal: 125, max: 155)
        }
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .accessibilityLabel(model.mode == .folderHistory ? "Commits in the selected folder history" : "Commits exclusive to each selected revision")
        .contextMenu(forSelectionType: GitObjectID.self) { ids in
            if let id = ids.first, rows.first(where: { $0.id == id })?.commit.canReviewChanges == true {
                Button("Review Commit") { model.selectedRangeCommit = id; model.inspectSelectedCommit() }
            }
        } primaryAction: { ids in
            guard let id = ids.first else { return }
            model.selectedRangeCommit = id
            model.inspectSelectedCommit()
        }
    }

    private var comparisonOptions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { basisPicker; scopeToggle }
            VStack(alignment: .leading, spacing: 8) { basisPicker; scopeToggle }
        }.disabled(model.busy || model.left == nil || model.right == nil)
    }

    private var basisPicker: some View {
        Picker("Compare", selection: Binding(get: { model.basis }, set: model.setBasis)) {
            ForEach(GitTreeComparison.Basis.allCases, id: \.self) { basis in Text(basis.title).tag(basis) }
        }.fixedSize(horizontal: true, vertical: false)
            .help("Choose both selected revisions or the changes from their common ancestor to the right revision")
    }

    @ViewBuilder private var scopeToggle: some View {
        if !model.location.relativeFolder.isEmpty {
            let title = model.mode == .folderHistory ? "Show whole repository history"
                : model.presentation == .commits ? "Show changed files from entire repository" : "Compare entire repository"
            Toggle(title,
                isOn: Binding(get: { model.wholeRepository }, set: model.useWholeRepository))
        }
    }

    private var workingBaselinePicker: some View {
        Picker("Compare with", selection: Binding(get: { model.workingBaseline }, set: model.setWorkingBaseline)) {
            ForEach(GitComparisonModel.WorkingBaseline.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    @ViewBuilder private func workingFolder(_ folder: GitWorkingFolder) -> some View {
        let reference = folder.comparesIndex ? "Git Index" : "Revision"
        let referenceInSentence = folder.comparesIndex ? "Git index" : "revision"
        let rows = model.visibleWorkingRows
        HStack(spacing: 8) {
            Button("Up a Folder", systemImage: "arrow.up", action: model.goUp).labelStyle(.iconOnly).disabled(!model.canGoUp)
            Text(folder.path?.display ?? model.location.root.lastPathComponent).interfaceFont(.callout.weight(.semibold))
                .lineLimit(1).truncationMode(.middle).help(folder.path?.display ?? model.location.root.path)
            Spacer(minLength: 6)
            if model.busy { ProgressView().controlSize(.small) }
            else if let path = model.selectedFolder { Button("Open Folder", systemImage: "folder") { model.enter(path) } }
            Button("Find Across Diffs", systemImage: "magnifyingglass", action: findDiffs)
                .labelStyle(.iconOnly).help("Find Across Diffs (⇧⌘F)").disabled(!model.canFindAcrossDiffs)
            Button("Check Contents", systemImage: "checkmark.magnifyingglass", action: model.checkWorkingContents)
                .disabled(!model.canCheckWorkingContents)
                .help("Check this folder’s file pairs against Git, up to 64 pairs, 1 MiB per file and 4 MiB total")
        }
        pathFilter(visible: rows.count, total: folder.rows.count) {
            if let selected = model.selectedFolder { model.enter(selected) }
            else if model.canOpenTextDiff { openDiff() }
        }
        if folder.rows.isEmpty {
            ContentUnavailableView("No visible files in this folder", systemImage: "folder")
        } else if rows.isEmpty && !model.filteringChanges {
            ContentUnavailableView(model.changeQuery.isEmpty ? "Matching files hidden" : "No matching paths",
                systemImage: "line.3.horizontal.decrease.circle")
        } else {
            GeometryReader { geometry in
                let scale = settings.interfaceSize.scale
                let kind = 65 * scale, comparison = 106 * scale
                let name = preferredPathWidth(in: geometry.size.width, after: 2 * kind + comparison)
                Table(rows, selection: $model.selectedMember) {
                    TableColumn("Name") { row in
                        Label(row.path.name, systemImage: row.isFolder ? "folder" : "doc")
                            .lineLimit(1).truncationMode(.middle).help(row.path.display)
                    }.width(min: 115, ideal: name)
                    TableColumn(reference) { row in
                        kindLabel(row.referenceKind.map { label(for: $0) })
                    }.width(kind)
                    TableColumn("On Disk") { row in
                        kindLabel(row.working.map { label(for: $0) })
                    }.width(kind)
                    TableColumn("Comparison") { row in
                        let text = model.workingContents?.results[row.path].map { label(for: $0, reference: referenceInSentence) }
                            ?? label(for: row.difference, reference: referenceInSentence)
                        Text(text).lineLimit(1).help(text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.width(comparison)
                }.scrollContentBackground(.hidden).alternatingRowBackgrounds(.disabled)
                    .accessibilityLabel(folder.comparesIndex ? "Working folder and Git index" : "Working folder and committed files")
                    .contextMenu(forSelectionType: GitSnapshotPath.self) { paths in
                        if paths.count == 1, let path = paths.first, let entry = rows.first(where: { $0.path == path }) {
                            if entry.isFolder { Button("Open Folder") { model.enter(path) } }
                            else if folder.textSelection(for: path) != nil {
                                Button("Open Text Diff") { model.selectedMember = path; openDiff() }
                                if model.hasWorkingEditor(for: path) {
                                    Button(GitComparisonWindow.compareEditorTitle) { model.selectedMember = path; compareEditor() }
                                }
                            }
                            if model.workingOpenSelection(for: path) != nil {
                                Button(GitComparisonWindow.openWorkingTitle) { model.selectedMember = path; openWorkingFile() }
                            }
                            if let staging = model.stagingSelection(for: path) {
                                Button(staging.isRemoval ? "Stage File Removal…" : "Stage Saved File…") {
                                    model.selectedMember = path
                                    stageWorkingPath(staging.isRemoval)
                                }
                            }
                            if let source = model.folderFileHistory(at: path, on: .left) {
                                Button("Committed File History…") {
                                    if model.folderFileHistory(at: path, on: .left) == source { openHistory(source) }
                                }
                            }
                        }
                    } primaryAction: { paths in
                        guard let path = paths.first else { return }
                        model.selectedMember = path
                        if let selected = model.selectedFolder { model.enter(selected) }
                        else { openDiff() }
                    }.disabled(model.busy || model.filteringChanges)
            }
        }
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if folder.committedState != .available || folder.workingState != .available {
                    Text(folderState(folder.committedState, side: reference) + " · " + folderState(folder.workingState, side: "Disk"))
                }
                if !model.notice.isEmpty { Text(model.notice) }
                else { Text("\(folder.onlyInRevision) only in \(referenceInSentence) · \(folder.onlyOnDisk) only on disk") }
                if let result = model.workingContents {
                    Text("\(result.matching) match · \(result.differing) changed · \(result.unreadable) unavailable · \(result.unchecked) unchecked")
                    Toggle("Hide Matching Files", isOn: Binding(get: { model.hidesMatchingFiles }, set: model.setHidesMatchingFiles))
                        .disabled(model.busy)
                        .help("Keep folders and files that still need checking")
                }
            }.interfaceFont(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("Open Working File", systemImage: "pencil", action: openWorkingFile)
                .accessibilityLabel(GitComparisonWindow.openWorkingTitle)
                .help("Open the selected on-disk file in the Traverse editor")
                .disabled(model.selectedMember.flatMap(model.workingOpenSelection(for:)) == nil)
            Button("Open Text Diff", systemImage: "doc.on.doc", action: openDiff).disabled(!model.canOpenTextDiff)
        }
    }

    private func folderState(_ state: GitWorkingFolder.DirectoryState, side: String) -> String {
        switch state {
        case .available: side + " folder available"
        case .absent: side + " folder absent"
        case .differentType: side + " has a different item at this path"
        case .unavailable: side + " folder unavailable"
        }
    }

    private func label(for kind: GitWorkingFolder.WorkingKind) -> String {
        switch kind {
        case .file: "File"
        case .directory: "Folder"
        case .symbolicLink: "Link"
        case .other: "Special file"
        case .unavailable: "Unavailable"
        }
    }

    private func label(for kind: GitSnapshotMember.Kind) -> String {
        switch kind {
        case .directory: "Folder"
        case .file: "File"
        case .executable: "Executable"
        case .symbolicLink: "Link"
        case .submodule: "Submodule"
        }
    }

    private func label(for difference: GitWorkingFolder.Difference, reference: String) -> String {
        switch difference {
        case .onlyInRevision: "Only in \(reference)"
        case .onlyOnDisk: "Only on disk"
        case .differentTypes: "Different types"
        case .bothFolders: "Folder on both"
        case .contentsUnchecked: "Unchecked"
        case .indexConflict: "Unmerged index"
        case .unavailable: "Unavailable"
        }
    }

    private func label(for result: GitWorkingFolder.ContentReview.Result, reference: String) -> String {
        switch result {
        case .matchesRevision: "Matches \(reference)"
        case .differs: "Changed"
        case .aboveLimit: "Over size limit"
        case .unavailable: "Unavailable"
        }
    }

    @ViewBuilder private func folderViews() -> some View {
        if let folders = model.folders {
            let labels = model.comparisonLabels(stacked: stacksFolders)
            HStack(spacing: 8) {
                Button("Up a Folder", systemImage: "arrow.up", action: model.goUp)
                    .labelStyle(.iconOnly).disabled(!model.canGoUp)
                Text(folders.path?.display ?? model.location.root.lastPathComponent).interfaceFont(.callout.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle).help(folders.path?.display ?? model.location.root.path)
                Spacer(minLength: 0)
                if model.busy { ProgressView().controlSize(.small) }
                if let path = model.selectedFolder {
                    Button("Open Folder", systemImage: "folder") { model.enter(path) }.disabled(model.busy)
                }
            }
            AdaptiveToolColumns(settings: settings, minimumWidth: 640, sizing: .viewport,
                onArrangementChanged: { stacksFolders = $0 }) {
                folderPanel(folders.left, side: .left, title: labels.left,
                            differences: folders.leftDifferences)
            } trailing: {
                folderPanel(folders.right, side: .right, title: labels.right,
                            differences: folders.rightDifferences)
            }
            if !model.notice.isEmpty {
                Text(model.notice).interfaceFont(.caption).foregroundStyle(.secondary)
            }
        } else if model.busy {
            ProgressView(model.notice).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Folder versions unavailable", systemImage: "folder.badge.questionmark")
            } description: { Text(model.notice) } actions: { Button("Try Again", action: model.refreshFolder) }
        }
    }

    private func folderPanel(_ directory: GitRevisionFolders.Directory, side: GitComparisonModel.Side, title: String,
                             differences: [GitSnapshotPath: GitRevisionFolders.Difference]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).interfaceFont(.callout.weight(.semibold)).foregroundStyle(.secondary)
            switch directory {
            case .absent:
                ContentUnavailableView("Folder absent", systemImage: "folder.badge.questionmark")
            case .differentType:
                ContentUnavailableView("A different item has this name", systemImage: "doc")
            case .children(let entries) where entries.isEmpty:
                ContentUnavailableView("Empty folder", systemImage: "folder")
            case .children(let entries):
                Table(entries, selection: tableSelection(entries)) {
                    TableColumn("Name") { entry in
                        Label(entry.path.name, systemImage: icon(for: entry.kind))
                            .lineLimit(1).truncationMode(.middle).help(entry.path.display)
                    }.width(min: 145, ideal: 300)
                    TableColumn("Difference") { entry in differenceLabel(differences[entry.path]) }
                        .width(min: 90, ideal: 105)
                }
                .scrollContentBackground(.hidden).alternatingRowBackgrounds(.disabled)
                .accessibilityLabel(title + " folder contents")
                .contextMenu(forSelectionType: GitSnapshotPath.self) { paths in
                    if paths.count == 1, let path = paths.first, let member = entries.first(where: { $0.path == path }) {
                        if member.kind == .directory {
                            Button("Open Folder") { model.enter(path) }
                        } else if model.folderTextPair(at: path) != nil {
                            Button("Compare Text Versions") { model.selectedMember = path; openDiff() }
                        }
                        if let source = model.folderFileHistory(at: path, on: side) {
                            Button("File History Here…") {
                                if model.folderFileHistory(at: path, on: side) == source { openHistory(source) }
                            }
                        }
                    }
                } primaryAction: { paths in
                    guard let path = paths.first else { return }
                    model.selectedMember = path
                    if let folder = model.selectedFolder { model.enter(folder) }
                    else { openDiff() }
                }
                .disabled(model.busy)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func tableSelection(_ entries: [GitSnapshotMember]) -> Binding<GitSnapshotPath?> {
        Binding {
            model.selectedMember.flatMap { path in entries.contains { $0.path == path } ? path : nil }
        } set: { path in
            if let path, entries.contains(where: { $0.path == path }) {
                model.selectedMember = path
            } else if path == nil, let selected = model.selectedMember, entries.contains(where: { $0.path == selected }) {
                model.selectedMember = nil
            }
        }
    }

    private func icon(for kind: GitSnapshotMember.Kind) -> String {
        switch kind {
        case .directory: "folder"
        case .file: "doc.text"
        case .executable: "terminal"
        case .symbolicLink: "link"
        case .submodule: "shippingbox"
        }
    }

    @ViewBuilder private func differenceLabel(_ difference: GitRevisionFolders.Difference?) -> some View {
        switch difference {
        case .onlyHere: Text("Only here")
        case .modified: Text("Changed")
        case .typeChanged: Text("Type changed")
        case nil: EmptyView()
        }
    }

    @ViewBuilder private func pathFilter(visible: Int, total: Int, open: @escaping () -> Void) -> some View {
        if let filterID = model.changeFilterID {
            ReviewFilterField(query: Binding(get: { model.changeQuery }, set: model.setChangeQuery),
                identifier: "git-change-filter", visibleCount: visible, totalCount: total,
                isFiltering: model.filteringChanges, dismiss: model.hideChangeFilter) { command in
                    switch command {
                    case .submit: if !model.filteringChanges { open() }
                    case .cancel: model.hideChangeFilter()
                    case .down: model.moveFilteredSelection(by: 1)
                    case .up: model.moveFilteredSelection(by: -1)
                    }
                    return true
                }
                .id(filterID)
        }
    }

    @ViewBuilder private func changeList(_ summary: GitChangeSummary) -> some View {
        HStack(spacing: 8) {
            Picker("Change Type", selection: Binding(get: { model.changeKind }, set: model.setChangeKind)) {
                ForEach(GitComparisonModel.changeKinds, id: \.self) { kind in
                    Text(GitComparisonModel.changeKindLabel(kind)).tag(kind)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("git-change-kind")
            .disabled(!model.canFilterChangeKinds)
            if model.changeKind != nil && model.changeFilterID == nil && !model.filteringChanges {
                Text("\(model.visibleChanges.count) of \(summary.changes.count) files")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
            }
        }
        pathFilter(visible: model.visibleChanges.count, total: summary.changes.count) {
            if model.canOpenTextDiff { openDiff() }
        }
        if !model.filteringChanges && model.filteredChanges?.isEmpty == true {
            ContentUnavailableView("No matching files", systemImage: "line.3.horizontal.decrease.circle")
        } else {
            changes(model.visibleChanges).disabled(model.filteringChanges)
        }
    }

    private func changes(_ rows: [GitTreeComparison.Change]) -> some View {
        let labels = model.comparisonLabels()
        let scale = settings.interfaceSize.scale
        let path = 98 * scale
        return Table(rows, selection: $model.selectedChange) {
            TableColumn(labels.left) { row in memberLabel(row.left) }.width(min: path, ideal: path + 7)
            TableColumn(labels.right) { row in memberLabel(row.right) }.width(min: path, ideal: path + 7)
            TableColumn("Change") { row in
                let label = GitComparisonModel.changeKindLabel(row.kind)
                Text(label).lineLimit(1).help(label)
            }.width(85 * scale)
            TableColumn("Lines") { row in
                if let lines = row.lines {
                    Text("+\(lines.added)  −\(lines.removed)").monospacedDigit().lineLimit(1)
                } else { Text("Unavailable").foregroundStyle(.secondary).lineLimit(1) }
            }.width(75 * scale)
        }
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .accessibilityLabel(model.mode == .index ? "Files changed in the Git index" : "Files changed between the selected Git revisions")
        .contextMenu(forSelectionType: Int.self) { ids in
            if ids.count == 1, let id = ids.first {
                if rows.first(where: { $0.id == id })?.canCompareText == true {
                    Button("Open Text Diff") { model.selectedChange = id; openDiff() }
                }
                ForEach(GitComparisonModel.Side.allCases, id: \.rawValue) { side in
                    if let source = model.changedFileHistory(id: id, on: side) {
                        Button(model.mode.supportsCommitInspection ? side.historyTitle : "Committed File History…") {
                            if model.changedFileHistory(id: id, on: side) == source { openHistory(source) }
                        }
                    }
                }
            }
        } primaryAction: { ids in
            guard let id = ids.first else { return }
            model.selectedChange = id
            if model.canOpenTextDiff { openDiff() }
        }
    }

    private func preferredPathWidth(in width: CGFloat, after fixed: CGFloat, paths: CGFloat = 1) -> CGFloat {
        let available = InterfaceMetrics.insetTableColumnBudget(in: width, scale: settings.interfaceSize.scale)
        return max(115, floor((available - fixed) / paths))
    }

    private func memberLabel(_ member: GitSnapshotMember?) -> some View {
        pathLabel(member?.path.display ?? "—")
    }

    private func pathLabel(_ path: String) -> some View {
        let prefix = model.location.relativeFolder + "/"
        let visible = !model.wholeRepository && path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        return Text(visible).lineLimit(1).truncationMode(.middle).help(path)
    }

    @ViewBuilder private func conflicts(_ entries: [GitIndexConflict]) -> some View {
        if entries.isEmpty {
            ContentUnavailableView("No unmerged files in this scope", systemImage: "checkmark.circle")
        } else {
            Picker("Compare", selection: Binding(get: { model.conflictPair }, set: model.setConflictPair)) {
                ForEach(GitComparisonModel.ConflictPair.allCases, id: \.self) { pair in Text(pair.rawValue).tag(pair) }
            }.help("These are Git’s stage names. In a rebase, Ours is the branch you are rebasing onto.")
            let stage = 77 * settings.interfaceSize.scale
            Table(entries, selection: $model.selectedConflict) {
                TableColumn("File") { pathLabel($0.path.display) }.width(min: 120, ideal: 266)
                TableColumn("Base") { conflictStage($0.base) }.width(stage)
                TableColumn("Ours") { conflictStage($0.ours) }.width(stage)
                TableColumn("Theirs") { conflictStage($0.theirs) }.width(stage)
            }.scrollContentBackground(.hidden).alternatingRowBackgrounds(.disabled)
                .accessibilityLabel("Unmerged files in the Git index")
                .contextMenu(forSelectionType: GitSnapshotPath.self) { paths in
                    if let path = paths.first, let entry = entries.first(where: { $0.path == path }),
                       model.conflictTextPair(in: entry) != nil {
                        Button("Open Text Diff") { model.selectedConflict = path; openDiff() }
                    }
                } primaryAction: { paths in
                    guard let path = paths.first else { return }
                    model.selectedConflict = path
                    openDiff()
                }
        }
    }

    private func conflictStage(_ member: GitSnapshotMember?) -> some View {
        kindLabel(member.map { label(for: $0.kind) })
            .help(member?.object.hex ?? "No version of this file in this stage")
    }

    private func kindLabel(_ title: String?) -> some View {
        Text(title ?? "Absent").lineLimit(1)
            .foregroundStyle(title == nil ? Color.secondary : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footer(_ summary: GitChangeSummary) -> some View {
        let files = summary.changes.count
        let folders = summary.affectedSubfolders
        let missing = summary.rowsWithoutLineCounts
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if model.presentation == .folders {
                    Text("Changes in \(model.folderLabel)").fontWeight(.medium).lineLimit(1)
                }
                Text("\(files) \(files == 1 ? "file" : "files") changed · \(folders) \(folders == 1 ? "subfolder" : "subfolders") · +\(summary.lines.added) added · −\(summary.lines.removed) removed")
                    .help("Totals for \(model.folderLabel)")
                if missing > 0 {
                    Text("\(missing) \(missing == 1 ? "file" : "files") without line counts")
                }
                if let conflicts = model.staged?.conflicts, !conflicts.isEmpty {
                    Text("\(conflicts.count) unmerged \(conflicts.count == 1 ? "file" : "files")")
                }
            }.interfaceFont(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if model.mode == .index && model.presentation == .changes {
                Button("Unstage…", systemImage: "tray.and.arrow.up", action: unstageFile)
                    .disabled(!model.canUnstageSelection)
                    .accessibilityIdentifier("git-unstage-file")
            }
            if model.canFindAcrossDiffs {
                Button("Find Across Diffs", systemImage: "magnifyingglass", action: findDiffs)
                    .labelStyle(.iconOnly).help("Find Across Diffs (⇧⌘F)")
            }
            Button("Open Text Diff", systemImage: "doc.on.doc", action: openDiff)
                .disabled(!model.canOpenTextDiff)
        }
    }
}

@MainActor extension BrowserWorkspaceController {
    func presentGitComparison(access: GitReviewAccess, parent: NSWindow, settings: BrowserSettings,
                              mode: GitComparisonModel.Mode = .revisions, pairedWith peer: GitReviewAccess? = nil) {
        guard !isClosing else { return }
        if let existing = gitComparisonWindow, existing.model.location == access.location, existing.model.mode == mode,
           existing.model.pairedAccess?.location == peer?.location {
            if parent.isVisible { existing.present() }
            return
        }
        gitComparisonWindow?.window?.close()
        let review = GitComparisonWindow(parent: parent, settings: settings, access: access, mode: mode, pairedWith: peer)
        gitComparisonWindow = review
        review.didClose = { [weak self, weak review] in
            if self?.gitComparisonWindow === review { self?.gitComparisonWindow = nil }
        }
        review.onDiff = { [weak self, weak review] labels, files, read in
            guard let self, let window = review?.window else { return }
            presentTextComparison(relativeTo: window, settings: settings, labels: labels, files: files, capture: read)
        }
        review.onFileHistory = { [weak self, weak review] source in
            guard let self, let window = review?.window, window.isVisible else { return }
            presentGitFileHistory(access: access, parent: window, settings: settings, path: source.path,
                                  startingAt: source.commit, local: nil)
        }
        if mode == .working {
            review.onOpenWorkingFile = { [weak self, weak review] selection, window in
                guard let self, let review, gitComparisonWindow === review, !isClosing else { return }
                let browser = activeBrowser
                guard browser.folderAccess === access.access, !browser.isBrowserSuspended,
                      browser.recoverableFileOperations != nil, !ApplicationFileActivity.gate.isClosed else {
                    review.model.reportWorkingOpen("The editor is unavailable while the workspace is busy. Try again when it’s ready.")
                    return
                }
                ApplicationLocalTextEditors.shared.open(selection, from: browser, in: window, repository: access.location,
                    report: review.model.reportWorkingOpen)
            }
        }
        if parent.isVisible { review.present() }
        review.model.load()
    }
}
