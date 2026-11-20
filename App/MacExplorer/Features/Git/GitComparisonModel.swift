import AppKit
import Combine
import FileOperations
import Foundation
import LocalStorage

@MainActor final class GitComparisonModel: ObservableObject {
    enum Side: Int, CaseIterable {
        case left, right

        var historyTitle: String { self == .left ? "Left File History…" : "Right File History…" }
    }
    struct FileHistorySource: Equatable {
        let path: GitSnapshotPath
        let commit: GitObjectID

        init?(_ member: GitSnapshotMember?, commit: GitObjectID?) {
            guard let member, member.isTextCandidate, let commit else { return nil }
            path = member.path
            self.commit = commit
        }
    }
    struct CommitRow: Identifiable {
        let commit: GitRangeCommit
        let side: Side?
        var id: GitObjectID { commit.id }
    }
    enum Mode: Equatable {
        case revisions, index, working, folderHistory

        var supportsCommitInspection: Bool { self == .revisions || self == .folderHistory }

        var primaryRevisionLabel: String {
            switch self {
            case .revisions: "Left revision"
            case .index: "Base revision"
            case .working: "Committed revision"
            case .folderHistory: "History starting at"
            }
        }

        var title: String {
            switch self {
            case .revisions: "Compare Git Revisions"
            case .index: "Review Staged Changes"
            case .working: "Compare Working Folder"
            case .folderHistory: "Git Folder History"
            }
        }

        var reloadTitle: String {
            switch self {
            case .revisions: "Reload Revisions"
            case .index: "Reload Staged Changes"
            case .working: "Reload Working Folder"
            case .folderHistory: "Reload Folder History"
            }
        }
    }
    enum Presentation: String { case changes = "Changes", folders = "Folders", commits = "Commits", conflicts = "Conflicts" }
    typealias ChangeKind = GitTreeComparison.Change.Kind
    static let changeKinds: [ChangeKind?] = [nil] + ChangeKind.allCases.map(Optional.some)
    static func changeKindLabel(_ kind: ChangeKind?) -> String {
        guard let kind else { return "All Changes" }
        return kind == .typeChanged ? "Type Changed" : kind.rawValue.capitalized
    }
    enum WorkingBaseline: String, CaseIterable { case revision = "Revision", index = "Git Index" }
    enum ConflictPair: String, CaseIterable {
        case branches = "Ours and Theirs"
        case baseToOurs = "Base and Ours"
        case baseToTheirs = "Base and Theirs"

        var labels: (left: String, right: String) {
            switch self {
            case .branches: ("Ours", "Theirs")
            case .baseToOurs: ("Base", "Ours")
            case .baseToTheirs: ("Base", "Theirs")
            }
        }

        func members(in conflict: GitIndexConflict) -> (GitSnapshotMember?, GitSnapshotMember?) {
            switch self {
            case .branches: (conflict.ours, conflict.theirs)
            case .baseToOurs: (conflict.base, conflict.ours)
            case .baseToTheirs: (conflict.base, conflict.theirs)
            }
        }
    }

    private enum Review {
        case revisions(GitTreeComparison)
        case index(GitStagedComparison)
    }

    let access: GitReviewAccess
    let mode: Mode
    let pairedAccess: GitReviewAccess?
    @Published private(set) var choices: [GitRevisionOption] = []
    @Published private(set) var left: GitRevisionOption?
    @Published private(set) var right: GitRevisionOption?
    @Published private(set) var basis = GitTreeComparison.Basis.selectedRevisions
    @Published private var review: Review? {
        didSet { refreshChangeFilter() }
    }
    @Published private(set) var wholeRepository = false
    @Published private(set) var busy = false
    @Published private(set) var notice = ""
    @Published var selectedChange: Int?
    @Published private(set) var changeFilterID: UUID?
    @Published private(set) var changeQuery = ""
    @Published private(set) var changeKind: ChangeKind?
    @Published private(set) var filteredChanges: [GitTreeComparison.Change]?
    @Published private(set) var filteringChanges = false
    @Published private(set) var presentation = Presentation.changes
    @Published private(set) var folders: GitRevisionFolders?
    @Published private(set) var commitRange: GitCommitRange?
    @Published private(set) var folderHistory: GitFolderHistory?
    @Published private(set) var commitChanges: GitCommitChanges? {
        didSet { refreshChangeFilter() }
    }
    @Published var selectedRangeCommit: GitObjectID?
    @Published private(set) var commitFilterID: UUID?
    @Published private(set) var commitQuery = ""
    @Published private(set) var workingBaseline = WorkingBaseline.revision
    @Published private(set) var workingFolder: GitWorkingFolder?
    @Published private(set) var workingContents: GitWorkingFolder.ContentReview?
    @Published private(set) var hidesMatchingFiles = false
    @Published private var filteredWorkingRows: [GitWorkingFolder.Row]?
    @Published var selectedMember: GitSnapshotPath?
    @Published var selectedConflict: GitSnapshotPath?
    @Published private(set) var conflictPair = ConflictPair.branches
    private let request = GitReviewRequest()
    private let changeFilter = ReviewRowFilter<GitTreeComparison.Change>()
    private let workingFilter = ReviewRowFilter<GitWorkingFolder.Row>()
    private var newerHistoryStarts: [GitObjectID] = []
    private let maximumRememberedHistoryPages = 64
    private let showHidden: () -> Bool
    private var closed = false

    init(access: GitReviewAccess, mode: Mode, pairedWith pairedAccess: GitReviewAccess? = nil, showHidden: @escaping () -> Bool) {
        self.access = access
        self.mode = mode
        self.pairedAccess = pairedAccess
        self.showHidden = showHidden
        if mode == .folderHistory { presentation = .commits }
    }

    var report: GitTreeComparison? {
        if case .revisions(let value) = review { return value }
        return nil
    }

    var staged: GitStagedComparison? {
        if case .index(let value) = review { return value }
        return nil
    }

    var summary: GitChangeSummary? { report?.summary ?? staged?.summary }
    private var displayedSummary: GitChangeSummary? { presentation == .commits ? commitChanges?.summary : summary }
    var canFilterChanges: Bool {
        if mode == .working { return !busy && !closed && workingFolder?.rows.isEmpty == false }
        return !busy && (presentation == .changes || presentation == .commits) && displayedSummary?.changes.isEmpty == false
    }
    var canFilterChangeKinds: Bool { mode != .working && canFilterChanges }
    var visibleChanges: [GitTreeComparison.Change] { filteredChanges ?? displayedSummary?.changes ?? [] }
    var canFindAcrossDiffs: Bool {
        guard !busy, !closed, !filteringChanges else { return false }
        if mode == .working { return !visibleWorkingTextSelections(limit: 1).isEmpty }
        return (presentation == .changes || presentation == .commits)
            && visibleChanges.contains(where: \.canCompareText)
    }
    var visibleWorkingRows: [GitWorkingFolder.Row] { filteredWorkingRows ?? workingFolder?.rows ?? [] }
    func visibleWorkingTextSelections(limit: Int = .max) -> [GitWorkingFolder.TextSelection] {
        workingFolder?.textSelections(visiblePaths: filteredWorkingRows.map { Set($0.lazy.map(\.path)) }, limit: limit) ?? []
    }
    var presentations: [Presentation] {
        switch mode {
        case .index: [.changes, .conflicts]
        case .revisions: [.changes, .folders, .commits]
        case .working, .folderHistory: []
        }
    }
    func comparisonLabels(stacked: Bool = false) -> (left: String, right: String) {
        if presentation == .commits, let commitChanges {
            let left = commitChanges.parent.map { "Parent · " + $0.short } ?? "Empty tree"
            return (left, "Commit · " + commitChanges.entry.id.short)
        }
        if let report {
            let first = report.basis == .commonAncestor ? "Common ancestor" : (stacked ? "Top" : "Left")
            let second = stacked ? "Bottom" : "Right"
            return (first + " · " + report.left.short, second + " · " + report.right.short)
        }
        return (staged?.base.map { "Base · " + $0.short } ?? "Empty tree", "Git Index")
    }

    var location: GitRepositoryLocation { access.location }
    var folderLabel: String { wholeRepository || location.relativeFolder.isEmpty ? location.root.lastPathComponent : location.relativeFolder }
    var selected: GitTreeComparison.Change? {
        guard !filteringChanges, let selectedChange, let rows = displayedSummary?.changes, rows.indices.contains(selectedChange) else { return nil }
        guard (changeQuery.isEmpty && changeKind == nil)
            || filteredChanges?.contains(where: { $0.id == selectedChange }) == true else { return nil }
        return rows[selectedChange]
    }

    private var selectedIndexPath: GitSnapshotPath? {
        guard mode == .index, presentation == .changes, !closed, let row = selected,
              [.added, .modified, .removed].contains(row.kind), row.left?.isTextCandidate != false,
              row.right?.isTextCandidate != false else { return nil }
        return (row.right ?? row.left)?.path
    }

    var canUnstageSelection: Bool { !busy && !ApplicationFileActivity.gate.isClosed && selectedIndexPath != nil }

    func unstage(in parent: NSWindow) {
        guard canUnstageSelection, let path = selectedIndexPath else { return }
        let expected = selected?.right
        editIndex(.unstage, path: path, in: parent, acceptsPlan: { $0.before == expected }) { $0.selectedIndexPath == path }
    }

    func stagingSelection(for path: GitSnapshotPath) -> GitWorkingFolder.StagingSelection? {
        guard mode == .working, !closed, workingRow(at: path) != nil else { return nil }
        return workingFolder?.stagingSelection(for: path)
    }

    func canStageWorkingPath(removal: Bool) -> Bool {
        !busy && !ApplicationFileActivity.gate.isClosed && selectedMember.flatMap(stagingSelection(for:))?.isRemoval == removal
    }

    func stageWorkingPath(removal: Bool, in parent: NSWindow) {
        guard canStageWorkingPath(removal: removal), let path = selectedMember, let selection = stagingSelection(for: path) else { return }
        let url = workingFolder?.textSelection(for: path)?.workingFileURL
        editIndex(.stageReviewedPath(selection), path: path, in: parent, hasUnsavedEdits: {
            guard let url else { return false }
            return ApplicationLocalTextEditors.shared.reviewSource(for: url).hasDraft()
        }) {
            $0.selectedMember == path && $0.stagingSelection(for: path) == selection
        }
    }

    private func editIndex(_ action: GitIndexEditAction, path: GitSnapshotPath, in parent: NSWindow,
                           hasUnsavedEdits: @escaping () -> Bool = { false },
                           acceptsPlan: @escaping (GitIndexEditPlan) -> Bool = { _ in true },
                           selectionIsCurrent: @escaping (GitComparisonModel) -> Bool) {
        guard !request.isRunning, parent.isKeyWindow, parent.attachedSheet == nil else { return }
        busy = true
        notice = "Checking the Git index…"
        request.start(preservesOutcome: true, { [weak self, weak parent, access] in
            guard let self, let parent else { throw CancellationError() }
            return try await GitIndexEditFlow.run(action, path: path, using: access, in: parent,
                hasUnsavedEdits: hasUnsavedEdits, acceptsPlan: acceptsPlan) {
                selectionIsCurrent(self) && parent.isKeyWindow && !ApplicationFileActivity.gate.isClosed
            }
        }, accept: { [weak self] result in
            guard let self, !closed else { return }
            busy = false
            switch result {
            case .success(.changed): load(successNotice: GitIndexEditFlow.Outcome.changed.notice(for: action), selecting: path)
            case .success(.alreadyCurrent): notice = GitIndexEditFlow.Outcome.alreadyCurrent.notice(for: action) ?? ""
            case .success(.cancelled), .failure(is CancellationError): notice = ""
            case .failure(let error): notice = GitIndexEditFlow.message(for: error)
            }
        })
    }

    func showChangeFilter() {
        guard canFilterChanges else { return }
        changeFilterID = UUID()
    }

    func hideChangeFilter() {
        changeFilterID = nil
        setChangeQuery("")
    }

    func setChangeQuery(_ query: String) {
        let value = String(query.prefix(256))
        guard value != changeQuery else { return }
        changeQuery = value
        refreshChangeFilter(retainingRows: true)
    }

    func setChangeKind(_ kind: ChangeKind?) {
        guard canFilterChangeKinds, changeKind != kind else { return }
        changeKind = kind
        refreshChangeFilter(retainingRows: true)
    }

    func moveFilteredSelection(by offset: Int) {
        guard !busy, !filteringChanges else { return }
        func moved<Row: Identifiable>(_ selection: Row.ID?, within rows: [Row]) -> Row.ID? {
            guard !rows.isEmpty else { return nil }
            let index = rows.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : rows.count)
            return rows[min(rows.count - 1, max(0, index + offset))].id
        }
        if showsCommitList { selectedRangeCommit = moved(selectedRangeCommit, within: visibleCommitRows) }
        else if mode == .working { selectedMember = moved(selectedMember, within: visibleWorkingRows) }
        else { selectedChange = moved(selectedChange, within: visibleChanges) }
    }

    private func refreshChangeFilter(retainingRows: Bool = false) {
        let term = changeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .working { refreshWorkingFilter(term: term, retainingRows: retainingRows); return }
        changeFilter.cancel()
        filteringChanges = false
        let kind = changeKind
        guard !closed, !changeQuery.isEmpty || kind != nil, let changes = displayedSummary?.changes else {
            filteredChanges = nil
            return
        }
        if !retainingRows { filteredChanges = nil }
        filteringChanges = true
        changeFilter.replace(changes, matches: { row in
            (kind == nil || row.kind == kind)
                && (term.isEmpty || row.left?.path.display.localizedStandardContains(term) == true
                    || row.right?.path.display.localizedStandardContains(term) == true)
        }) { [weak self] matches in self?.installChangeFilter(matches) }
    }

    private func installChangeFilter(_ matches: [GitTreeComparison.Change]) {
        guard !closed else { return }
        filteredChanges = matches
        filteringChanges = false
        if !matches.contains(where: { $0.id == selectedChange }) { selectedChange = matches.first?.id }
    }

    func setHidesMatchingFiles(_ value: Bool) {
        guard mode == .working, !busy, !closed, workingContents != nil, hidesMatchingFiles != value else { return }
        hidesMatchingFiles = value
        refreshChangeFilter(retainingRows: true)
    }

    private func refreshWorkingFilter(term: String, retainingRows: Bool) {
        workingFilter.cancel()
        filteringChanges = false
        let results = hidesMatchingFiles ? workingContents?.results : nil
        guard !closed, let rows = workingFolder?.rows, !term.isEmpty || results != nil else {
            filteredWorkingRows = nil
            return
        }
        if !retainingRows { filteredWorkingRows = nil }
        filteringChanges = true
        workingFilter.replace(rows, matches: { row in
            results?[row.path] != .matchesRevision && (term.isEmpty || row.path.display.localizedStandardContains(term))
        }) { [weak self] matches in
            guard let self, !closed else { return }
            filteredWorkingRows = matches
            filteringChanges = false
            if !matches.contains(where: { $0.path == selectedMember }) { selectedMember = matches.first?.path }
        }
    }

    private func workingRow(at path: GitSnapshotPath) -> GitWorkingFolder.Row? {
        guard !filteringChanges else { return nil }
        return visibleWorkingRows.first { $0.path == path }
    }

    private var baseFolder: GitSnapshotPath? { wholeRepository ? nil : GitSnapshotPath(location.relativeFolder) }
    private var shownFolder: GitSnapshotPath? { mode == .working ? workingFolder?.path : folders?.path }
    var canGoUp: Bool { !busy && (mode == .working || presentation == .folders) && shownFolder != baseFolder && shownFolder != nil }
    var selectedFolder: GitSnapshotPath? {
        guard !busy, let selectedMember else { return nil }
        if mode == .working {
            return workingRow(at: selectedMember)?.isFolder == true ? selectedMember : nil
        }
        guard presentation == .folders else { return nil }
        let (left, right) = members(at: selectedMember)
        return left?.kind == .directory || right?.kind == .directory ? selectedMember : nil
    }

    private func members(at path: GitSnapshotPath) -> (GitSnapshotMember?, GitSnapshotMember?) {
        return (folders?.left.entries.first { $0.path == path }, folders?.right.entries.first { $0.path == path })
    }

    func selectedFileHistory(on side: Side) -> FileHistorySource? {
        switch (mode, presentation) {
        case (.working, _), (_, .folders):
            return selectedMember.flatMap { folderFileHistory(at: $0, on: side) }
        case (_, .changes), (_, .commits):
            return selected.flatMap { changedFileHistory(id: $0.id, on: side) }
        case (_, .conflicts):
            return nil
        }
    }

    func changedFileHistory(id: Int, on side: Side) -> FileHistorySource? {
        guard !busy, !closed, !filteringChanges, presentation == .changes || presentation == .commits,
              let row = visibleChanges.first(where: { $0.id == id }) else { return nil }
        let commit: GitObjectID?
        if presentation == .commits {
            commit = side == .left ? commitChanges?.parent : commitChanges?.entry.id
        } else if let report {
            commit = side == .left ? report.left : report.right
        } else {
            commit = side == .left ? staged?.base : nil
        }
        return FileHistorySource(side == .left ? row.left : row.right, commit: commit)
    }

    func folderFileHistory(at path: GitSnapshotPath, on side: Side) -> FileHistorySource? {
        guard !busy, !closed else { return nil }
        if mode == .working {
            guard side == .left, let folder = workingFolder else { return nil }
            return FileHistorySource(workingRow(at: path)?.referenceMember, commit: folder.revision)
        }
        guard presentation == .folders, let report else { return nil }
        let (left, right) = members(at: path)
        return FileHistorySource(side == .left ? left : right, commit: side == .left ? report.left : report.right)
    }

    func folderTextPair(at path: GitSnapshotPath) -> (GitSnapshotMember?, GitSnapshotMember?)? {
        guard presentation == .folders, !busy else { return nil }
        let (left, right) = members(at: path)
        guard left != nil || right != nil, left?.isTextCandidate != false, right?.isTextCandidate != false else { return nil }
        return (left, right)
    }

    var textPair: (GitSnapshotMember?, GitSnapshotMember?)? {
        guard !busy, mode != .working else { return nil }
        switch presentation {
        case .changes, .commits:
            guard let selected, selected.canCompareText else { return nil }
            return (selected.left, selected.right)
        case .folders:
            return selectedMember.flatMap(folderTextPair)
        case .conflicts:
            guard let selectedConflict,
                  let entry = staged?.conflicts.first(where: { $0.path == selectedConflict }) else { return nil }
            return conflictTextPair(in: entry)
        }
    }

    var workingTextSelection: GitWorkingFolder.TextSelection? {
        guard !busy, mode == .working, let selectedMember, workingRow(at: selectedMember) != nil else { return nil }
        return workingFolder?.textSelection(for: selectedMember)
    }

    func hasWorkingEditor(for path: GitSnapshotPath) -> Bool {
        guard mode == .working, !busy, !closed, workingRow(at: path) != nil,
              let url = workingFolder?.textSelection(for: path)?.workingFileURL else { return false }
        return ApplicationLocalTextEditors.shared.capturedEditorSource(for: url) != nil
    }

    func workingOpenSelection(for path: GitSnapshotPath) -> LocalTextOpenSelection? {
        guard mode == .working, !busy, !closed, workingRow(at: path) != nil else { return nil }
        return workingFolder?.openSelection(for: path)
    }

    func reportWorkingOpen(_ message: String) { notice = message }

    var canOpenTextDiff: Bool { textPair != nil || workingTextSelection != nil }
    var canCheckWorkingContents: Bool { !busy && !closed && (workingFolder?.contentCandidates ?? 0) > 0 }

    func checkWorkingContents() {
        guard canCheckWorkingContents, let folder = workingFolder else { return }
        observe("Checking file contents…", replacingComparison: false) { [access] in
            try await access.checkWorkingContents(folder)
        } then: { model, contents in
            model.workingContents = contents
            if model.hidesMatchingFiles { model.refreshChangeFilter(retainingRows: true) }
        }
    }

    func conflictTextPair(in entry: GitIndexConflict) -> (GitSnapshotMember?, GitSnapshotMember?)? {
        let (left, right) = conflictPair.members(in: entry)
        guard !busy, left != nil || right != nil, left?.isTextCandidate != false, right?.isTextCandidate != false else { return nil }
        return (left, right)
    }

    func load(successNotice: String? = nil, selecting path: GitSnapshotPath? = nil) {
        guard !closed, !request.isRunning else { return }
        if mode == .working, workingBaseline == .index {
            readWorkingFolder(workingFolder?.path ?? baseFolder, selection: path ?? selectedMember, successNotice: successNotice)
            return
        }
        let selection = path ?? (selected?.right ?? selected?.left)?.path
        let peer = left == nil && right == nil ? pairedAccess : nil
        observe("Reading local Git revisions…", replacingComparison: false) { [access] in try await access.catalog(pairedWith: peer) } then: { model, catalog in
            let oldLeft = model.left
            let oldRight = model.right
            model.choices = GitRevisionOption.choices(catalog)
            let current = catalog.head == nil ? nil : model.choices.first
            if model.mode != .revisions {
                model.left = oldLeft == nil ? current : oldLeft?.refreshed(in: model.choices)
                if oldLeft != nil, model.left == nil {
                    model.clearComparison()
                    model.notice = "The selected base revision is no longer available. Choose another revision."
                    return
                }
                model.compare(selecting: selection, successNotice: successNotice)
                return
            }
            if let pair = catalog.pairedCheckouts {
                model.left = .checkedOut(pair.left)
                model.right = .checkedOut(pair.right)
                model.compare()
                return
            }
            model.left = oldLeft == nil ? catalog.recentCommits.dropFirst().first.map(GitRevisionOption.commit) : oldLeft?.refreshed(in: model.choices)
            model.right = oldRight == nil ? current : oldRight?.refreshed(in: model.choices)
            if model.left != nil && model.right != nil { model.compare() }
            else {
                model.clearComparison()
                model.notice = model.choices.isEmpty ? "This repository has no committed revisions." : "Choose two revisions to compare."
            }
        }
    }

    func choose(_ revision: GitRevisionOption, for side: Side) {
        guard !busy, !closed, mode == .revisions || side == .left else { return }
        switch side {
        case .left: left = revision
        case .right: right = revision
        }
        compare()
    }

    func setBasis(_ basis: GitTreeComparison.Basis) {
        guard mode == .revisions, !busy, !closed, self.basis != basis else { return }
        self.basis = basis
        compare()
    }

    func setWorkingBaseline(_ target: WorkingBaseline) {
        guard mode == .working, !busy, !closed, workingBaseline != target else { return }
        workingBaseline = target
        compare()
    }

    func useWholeRepository(_ value: Bool) {
        guard !busy, !closed, wholeRepository != value else { return }
        wholeRepository = value
        compare(resetFolder: true)
    }

    func setPresentation(_ presentation: Presentation) {
        guard presentations.contains(presentation), !busy, !closed, self.presentation != presentation else { return }
        hideChangeFilter()
        selectedChange = nil
        self.presentation = presentation
        if presentation == .folders, folders == nil { readFolder(baseFolder) }
        if presentation == .commits, commitRange == nil { readCommitRange() }
    }

    var showsCommitList: Bool { presentation == .commits && commitChanges == nil }

    var commitRows: [CommitRow] {
        if let folderHistory { return folderHistory.commits.map { .init(commit: $0, side: nil) } }
        guard let commitRange else { return [] }
        return commitRange.left.commits.map { .init(commit: $0, side: .left) }
            + commitRange.right.commits.map { .init(commit: $0, side: .right) }
    }

    var visibleCommitRows: [CommitRow] {
        let rows = commitRows
        let term = commitQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? rows : rows.filter { $0.commit.commit.matchesFilter(term) }
    }

    var canFilterCommits: Bool { showsCommitList && !busy && !closed && !commitRows.isEmpty }

    func showCommitFilter() {
        guard canFilterCommits else { return }
        commitFilterID = UUID()
    }

    func hideCommitFilter() {
        commitFilterID = nil
        setCommitQuery("")
    }

    func setCommitQuery(_ query: String) {
        let value = String(query.prefix(256))
        guard value != commitQuery else { return }
        commitQuery = value
        updateCommitSelection()
    }

    private func updateCommitSelection() {
        let rows = visibleCommitRows
        if !rows.contains(where: { $0.id == selectedRangeCommit }) { selectedRangeCommit = rows.first?.id }
    }

    var rangeSelection: GitRangeCommit? {
        visibleCommitRows.first { $0.id == selectedRangeCommit }?.commit
    }

    var canInspectCommit: Bool {
        presentation == .commits && !busy && commitChanges == nil && rangeSelection?.canReviewChanges == true
    }

    func readCommitRange() {
        guard !closed, !request.isRunning, presentation == .commits, let report else { return }
        observe("Reading commits on each side…", replacingComparison: false) { [access] in
            try await access.commitRange(left: report.selectedLeft, right: report.right)
        } then: { model, range in
            model.commitRange = range
            model.selectedRangeCommit = range.right.commits.first?.id ?? range.left.commits.first?.id
            model.updateCommitSelection()
        }
    }

    var folderHistoryPage: Int { newerHistoryStarts.count + 1 }
    var atFolderHistoryPageLimit: Bool { newerHistoryStarts.count >= maximumRememberedHistoryPages }
    var canReadNewerCommits: Bool { !busy && commitChanges == nil && !newerHistoryStarts.isEmpty }
    var canReadOlderCommits: Bool { !busy && commitChanges == nil && folderHistory?.older != nil && !atFolderHistoryPageLimit }

    func changeHistoryPage(older: Bool) {
        guard older ? canReadOlderCommits : canReadNewerCommits,
              let current = folderHistory, let start = older ? current.older : newerHistoryStarts.last else { return }
        observe("Reading the selected folder history page…", replacingComparison: false) { [access, wholeRepository] in
            let page = try await access.folderHistory(from: .object(start), wholeRepository: wholeRepository)
            guard page.start == start, !page.commits.isEmpty, !older || page.commits.first?.id == start else {
                throw GitInspectionFailure.changed
            }
            return page
        } then: { model, page in
            if older { model.newerHistoryStarts.append(current.start) }
            else { model.newerHistoryStarts.removeLast() }
            model.folderHistory = page
            model.selectedRangeCommit = page.commits.first?.id
            model.updateCommitSelection()
        }
    }

    func inspectSelectedCommit() {
        guard canInspectCommit, let entry = rangeSelection else { return }
        inspect(entry, parent: entry.parents.first)
    }

    func selectCommitParent(_ parent: GitObjectID) {
        guard !busy, let details = commitChanges, details.parent != parent, details.entry.parents.contains(parent) else { return }
        inspect(details.entry, parent: parent)
    }

    private func inspect(_ entry: GitRangeCommit, parent: GitObjectID?) {
        guard !closed, !request.isRunning, presentation == .commits else { return }
        hideChangeFilter()
        selectedChange = nil
        observe("Reading files in this commit…", replacingComparison: false) { [access, wholeRepository] in
            try await access.commitChanges(entry, parent: parent, wholeRepository: wholeRepository)
        } then: { model, result in
            model.commitChanges = result
            model.selectedChange = result.summary.changes.first?.id
        }
    }

    func returnToCommitRange() {
        guard !busy, presentation == .commits else { return }
        hideChangeFilter()
        selectedChange = nil
        commitChanges = nil
        notice = ""
    }

    func setConflictPair(_ pair: ConflictPair) {
        guard presentation == .conflicts, !busy, !closed else { return }
        conflictPair = pair
    }

    func enter(_ path: GitSnapshotPath) {
        guard !busy else { return }
        if mode == .working {
            guard workingRow(at: path)?.isFolder == true else { return }
            readWorkingFolder(path)
            return
        }
        guard presentation == .folders else { return }
        let (left, right) = members(at: path)
        guard left?.kind == .directory || right?.kind == .directory else { return }
        readFolder(path)
    }

    func goUp() {
        guard canGoUp else { return }
        if mode == .working { readWorkingFolder(shownFolder?.parent) }
        else { readFolder(shownFolder?.parent) }
    }

    func refreshFolder() { readFolder(folders?.path ?? baseFolder) }

    private func readFolder(_ path: GitSnapshotPath?) {
        guard !closed, !request.isRunning, let report else { return }
        observe("Reading both folder versions…", replacingComparison: false) { [access] in
            try await access.folders(left: report.left, right: report.right, at: path)
        } then: { model, folders in
            model.folders = folders
            model.selectedMember = nil
        }
    }

    private func readWorkingFolder(_ path: GitSnapshotPath?, selection: GitSnapshotPath? = nil, successNotice: String? = nil) {
        guard !closed, !request.isRunning else { return }
        let chosen = workingBaseline == .revision ? left : nil
        let baseline: GitWorkingFolder.Baseline
        if workingBaseline == .index { baseline = .index }
        else if let chosen { baseline = .revision(chosen.revision) }
        else {
            clearComparison()
            notice = "Choose a committed revision to compare with the working folder."
            return
        }
        let message = workingBaseline == .index ? "Reading the working folder and Git index…" : "Reading the working and committed folders…"
        observe(message, replacingComparison: false) { [access, hidden = showHidden()] in
            try await access.workingFolder(at: path, baseline: baseline, showHidden: hidden)
        } then: { model, folder in
            if let chosen, let revision = folder.revision { model.left = chosen.resolved(to: revision) }
            model.workingFolder = folder
            model.workingContents = nil
            model.selectedMember = selection.flatMap { selected in folder.rows.contains { $0.path == selected } ? selected : nil }
            model.notice = successNotice ?? ""
            model.refreshChangeFilter()
        }
    }

    func swap() {
        guard !busy, let before = left, let after = right else { return }
        left = after
        right = before
        compare()
    }

    private func compare(resetFolder: Bool = false, selecting path: GitSnapshotPath? = nil, successNotice: String? = nil) {
        guard !closed, !request.isRunning else { return }
        if mode == .folderHistory {
            guard let chosen = left else {
                clearComparison()
                notice = "This repository has no committed revisions."
                return
            }
            observe("Reading folder history…") { [access, wholeRepository] in
                try await access.folderHistory(from: chosen.revision, wholeRepository: wholeRepository)
            } then: { model, page in
                model.left = chosen.resolved(to: page.start)
                model.folderHistory = page
                model.selectedRangeCommit = page.commits.first?.id
                model.updateCommitSelection()
            }
            return
        }
        if mode == .working {
            let path = resetFolder || workingFolder == nil ? baseFolder : workingFolder?.path
            // A chosen revision or scope invalidates the old table, even if
            // the new request is stopped or cannot be read.
            clearComparison()
            readWorkingFolder(path)
            return
        }
        if mode == .index {
            let chosen = left
            observe("Reading staged changes…") { [access, wholeRepository] in
                try await access.compareIndex(against: chosen?.revision, wholeRepository: wholeRepository)
            } then: { model, value in
                if let base = value.base { model.left = chosen?.resolved(to: base) }
                model.review = .index(value)
                if let path {
                    model.selectedChange = value.summary.changes.first { ($0.right ?? $0.left)?.path == path }?.id
                }
                if value.summary.changes.isEmpty, !value.conflicts.isEmpty { model.presentation = .conflicts }
                model.notice = successNotice ?? ""
                model.refreshChangeFilter()
            }
            return
        }
        guard let left, let right else { notice = "Choose two revisions to compare."; return }
        let nextPath = (resetFolder ? nil : folders?.path) ?? baseFolder
        observe("Comparing committed folders…") { [access, basis, wholeRepository] in
            try await access.compare(left: left.revision, right: right.revision, basis: basis, wholeRepository: wholeRepository)
        } then: { model, report in
            model.left = left.resolved(to: report.selectedLeft)
            model.right = right.resolved(to: report.right)
            model.review = .revisions(report)
            if model.presentation == .folders { model.readFolder(nextPath) }
            if model.presentation == .commits { model.readCommitRange() }
        }
    }

    func stop() {
        guard request.isRunning else { return }
        notice = "Stopping Git review…"
        request.stop()
    }

    func close() {
        closed = true
        request.close()
        clearComparison()
        choices = []
    }

    private func clearComparison() {
        changeFilter.cancel()
        filteredChanges = nil
        filteringChanges = false
        review = nil; selectedChange = nil
        folders = nil; selectedMember = nil
        commitRange = nil; commitChanges = nil; selectedRangeCommit = nil
        folderHistory = nil; newerHistoryStarts.removeAll()
        selectedConflict = nil
        workingFolder = nil
        workingContents = nil
        if mode == .working { refreshChangeFilter() }
    }

    private func observe<Value: Sendable>(_ message: String, replacingComparison: Bool = true,
                                          read: @escaping @MainActor () async throws -> Value,
                                          then install: @escaping @MainActor (GitComparisonModel, Value) -> Void) {
        busy = true
        notice = message
        if replacingComparison { clearComparison() }
        request.start(read) { [weak self] result in
            guard let self, !closed else { return }
            busy = false
            switch result {
            case .success(let value):
                notice = ""
                install(self, value)
            case .failure(let error):
                notice = GitReviewAccess.message(for: error)
            }
        }
    }
}
