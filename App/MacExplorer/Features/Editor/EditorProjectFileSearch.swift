import AppKit
import ExplorerCore
import FileOperations
import LocalStorage
import Search

/// A suffix changes where the selected file will open. The search continues
/// to use the existing filename and bounded project scope.
struct EditorProjectFileQuery: Equatable {
    let filename: String
    let address: EditorLineAddress?

    init(_ source: String) {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.prefix(2_049).count <= 2_048 else { filename = text; address = nil; return }
        var parts = [""]
        var escaped = false
        for character in text {
            if escaped {
                if character != ":" && character != "\\" { parts[parts.count - 1].append("\\") }
                parts[parts.count - 1].append(character)
                escaped = false
            } else if character == "\\" { escaped = true }
            else if character == ":" { parts.append("") }
            else { parts[parts.count - 1].append(character) }
        }
        if escaped { parts[parts.count - 1].append("\\") }
        if parts.count > 1, let number = EditorLineNumber.parse(parts[parts.count - 1], maximum: Int.max) {
            if parts.count > 2, let line = EditorLineNumber.parse(parts[parts.count - 2], maximum: Int.max),
               parts.dropLast(2).contains(where: { !$0.isEmpty }) {
                filename = parts.dropLast(2).joined(separator: ":")
                address = .init(line: line, column: number)
                return
            }
            let prefix = parts.dropLast().joined(separator: ":")
            if !prefix.isEmpty {
                filename = prefix
                address = .init(line: number)
                return
            }
        }
        filename = parts.joined(separator: ":")
        address = nil
    }
}

/// One picker for scoped filename lookup and explicit text search. The
/// ordinary editor session admits the selected file after revalidation.
@MainActor final class EditorProjectFileSearch: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let maximumFileResults = 160
    private static let generatedFolderNames: Set<String> = ["node_modules", ".build", "DerivedData", ".venv", "__pycache__"]

    enum Purpose {
        case openFile, findText, findFolderText, findDeclarations

        var isTextSearch: Bool { self != .openFile }
        var title: String {
            switch self {
            case .openFile: "Open Project File"
            case .findText: "Find in Project"
            case .findFolderText: "Find in Folder"
            case .findDeclarations: "Find Project Declarations"
            }
        }
    }

    private struct Row {
        let entry: FileEntry
        var match: EditorProjectTextSearch.Match?
    }
    private struct Discovery {
        let metadata: SearchRequest
        var query: EditorProjectTextSearch.Query? = nil
    }
    private struct TextProgress {
        let folder: LocalProjectTextScope
        let preparation: FolderAccessPreparation
        let candidates: [FileEntry]
        let query: EditorProjectTextSearch.Query
        var offset = 0
        var searched = 0
        var skipped = 0
        var matchesLimited = false
        let locationsSkipped: Int
        let traversalLimited: Bool
    }
    private enum Request {
        case discover(Discovery)
        case more(TextProgress)
    }
    private let settings: BrowserSettings
    private let access: FolderAccessController
    private let fileSystem: LocalFileSystem
    private let search = LocalMetadataSearch(activityGate: ApplicationFileActivity.gate)
    private let reader = SearchResultOpenReader()
    private let input = NativeQueryInput()
    private let folderInput = NativeQueryInput()
    private weak var parent: NSWindow?
    private weak var previousResponder: NSResponder?
    private var projectScope: SearchScope?
    private var scope: SearchScope?
    private var isCurrent: (() -> Bool)?
    private var onOpen: ((LocalTextOpenSelection, EditorFileJump.Destination?) -> Void)?
    #if DEBUG
    var didCheckOpenForVerification: ((LocalTextOpenSelection) -> Void)?
    #endif
    private var preparation: FolderAccessPreparation?
    private var results: [Row] = []
    private var purpose = Purpose.openFile
    private var query = EditorProjectFileQuery("")
    private var partial = false
    private var foundFileCount = 0
    private var textFolder: LocalProjectTextScope?
    private var textProgress: TextProgress?
    private var requested: Request?
    private var worker: Task<Void, Never>?
    private var session: SearchSession?
    private var opening: Task<Void, Never>?
    private var draining = false
    private var binding = UUID()
    private(set) var panel: NSPanel?
    let field = NSSearchField()
    let table = NSTableView()
    private let status = label("", size: 11, color: .secondaryLabelColor)
    private lazy var findButton = NSButton(title: "Search", target: self, action: #selector(searchText(_:)))
    private let matchCase = NSButton(checkboxWithTitle: "Match Case", target: nil, action: nil)
    private let wholeWords = NSButton(checkboxWithTitle: "Whole Words", target: nil, action: nil)
    private let fileType = NSPopUpButton()
    private let folder = NSTextField()
    #if DEBUG
    var statusForVerification: String { status.stringValue }
    var searchButtonForVerification: NSButton { findButton }
    var fileTypeForVerification: NSPopUpButton { fileType }
    var folderForVerification: NSTextField { folder }
    #endif

    init(access: FolderAccessController, fileSystem: LocalFileSystem, settings: BrowserSettings) {
        self.access = access; self.fileSystem = fileSystem; self.settings = settings
        super.init()
        field.delegate = input
        input.onChange = { [weak self] in self?.changeQuery($0) }
        input.onCommand = { [weak self] in self?.handle($0) ?? false }
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(openSelected(_:))
        for control in [matchCase, wholeWords] { control.target = self; control.action = #selector(textOptionsChanged(_:)) }
        fileType.target = self; fileType.action = #selector(textOptionsChanged(_:))
        fileType.setAccessibilityLabel("File Type Filter")
        fileType.toolTip = "Search one supported file type"
        folder.placeholderString = "This folder and subfolders"
        folder.setAccessibilityLabel("Relative Search Folder")
        folder.toolTip = "Enter a relative folder, such as Sources/Models. Leave blank to search all subfolders."
        folder.delegate = folderInput
        folderInput.onChange = { [weak self] _ in
            guard let self else { return }
            changeQuery(field.stringValue)
        }
        folderInput.onCommand = { [weak self] command in
            guard let self else { return false }
            switch command {
            case .submit: panel?.makeFirstResponder(field); searchText(nil); return true
            case .cancel: panel?.performClose(nil); return true
            case .up, .down: return false
            }
        }
    }

    func present(in parent: NSWindow, root: URL, purpose: Purpose, query: String?, isCurrent: @escaping () -> Bool,
                 open: @escaping (LocalTextOpenSelection, EditorFileJump.Destination?) -> Void) {
        let exclusions = settings.editorPreferences.includesGeneratedProjectFolders ? [] : Self.generatedFolderNames
        guard parent.isKeyWindow, parent.isVisible, parent.attachedSheet == nil, NSApp.modalWindow == nil,
              panel == nil, !draining, !AutomaticMetadataPolicy.excludes(root),
              let scope = try? SearchScope(root: root, showHidden: settings.showsHiddenFiles, excludesGitMetadata: true,
                                           excludesSensitiveText: purpose.isTextSearch, excludedDescendantNames: exclusions) else { return }
        self.parent = parent; previousResponder = parent.firstResponder; self.scope = scope
        projectScope = scope
        self.isCurrent = isCurrent; self.purpose = purpose; onOpen = open
        let textSearch = purpose.isTextSearch
        let declarations = purpose == .findDeclarations
        let controls = textSearch ? makeTextControls(declarationsOnly: declarations) : nil
        let panel = CommandDiscoveryPresentation.makePanel(query: field, table: table, status: status,
            title: purpose.title,
            scope: (textSearch ? "Search files on disk in " : "Search filenames in ") + root.lastPathComponent,
            searchLabel: declarations ? "Find a declaration in this project" : textSearch ? "Find text in this folder" : "Find a file in this project",
            placeholder: declarations ? "Function or type name, or initials" : textSearch ? "Text to find" : "Filename, initials or name:line:column",
            resultsLabel: declarations ? "Matching declarations" : textSearch ? "Matching lines" : "Files in this project",
            accessory: controls, settings: settings)
        self.panel = panel
        panel.delegate = self
        field.stringValue = query ?? ""
        changeQuery(field.stringValue)
        CommandDiscoveryPresentation.position(panel, relativeTo: parent)
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(field)
        if query != nil { field.selectText(nil) }
    }

    private func makeTextControls(declarationsOnly: Bool) -> NSView {
        prepareFileTypes(declarationsOnly: declarationsOnly)
        folder.stringValue = ""
        let label = label("Folder", size: 11, color: .secondaryLabelColor, weight: .medium)
        label.setContentHuggingPriority(.required, for: .horizontal)
        let folderRow = NSStackView(views: [label, folder])
        folderRow.alignment = .centerY; folderRow.spacing = 10
        let content: [NSView] = (declarationsOnly ? [] : [matchCase, wholeWords]) + [NSView(), fileType, findButton]
        let options = NSStackView(views: content)
        options.spacing = 12; options.alignment = .centerY
        let controls = NSStackView(views: [folderRow, options])
        controls.orientation = .vertical; controls.alignment = .leading; controls.spacing = 8
        folderRow.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        options.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        return controls
    }

    private func prepareFileTypes(declarationsOnly: Bool) {
        fileType.removeAllItems()
        fileType.addItem(withTitle: "All File Types")
        for language in EditorProjectTextSearch.languages(declarationsOnly: declarationsOnly) {
            fileType.addItem(withTitle: language.title)
            fileType.lastItem?.representedObject = language.rawValue
        }
        fileType.selectItem(at: 0)
    }

    private func changeQuery(_ text: String) {
        let next = EditorProjectFileQuery(purpose == .openFile ? text : "")
        if !next.filename.isEmpty, next.filename.utf8.elementsEqual(query.filename.utf8) {
            opening?.cancel()
            query = next
            if preparation != nil { updateResultsStatus() }
            return
        }
        query = next
        resetResults()
        guard panel != nil else { return }
        if purpose.isTextSearch {
            status.stringValue = purpose == .findDeclarations
                ? "Press Return to find named declarations in supported code files."
                : "Press Return to search supported files in this folder."
            return
        }
        let name = next.filename
        guard !name.isEmpty else { status.stringValue = "Type to find a file in this project."; return }
        guard let request = try? SearchRequest(filename: name, filenameMatch: .navigation, kind: .file,
                                               symbolTolerant: settings.symbolTolerantNames) else {
            status.stringValue = "Enter part of a filename without its folder path."
            return
        }
        requested = .discover(.init(metadata: request))
        status.stringValue = "Finding files…"
        startNext()
    }

    private func resetResults() {
        binding = UUID()
        requested = nil; session?.cancel(); worker?.cancel(); opening?.cancel()
        preparation = nil
        scope = projectScope
        textFolder = nil; textProgress = nil
        foundFileCount = 0
        status.toolTip = nil
        updateSearchButton()
        results.removeAll(); table.reloadData()
    }

    @objc private func textOptionsChanged(_ sender: NSControl) {
        changeQuery(field.stringValue)
        if let panel, panel.isKeyWindow, field.currentEditor() == nil { panel.makeFirstResponder(field) }
    }

    @objc private func searchText(_ sender: NSButton?) {
        guard panel?.isKeyWindow == true, purpose.isTextSearch, opening == nil,
              (field.currentEditor() as? NSTextView)?.hasMarkedText() != true,
              (folder.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if worker != nil {
            requested = nil; session?.cancel(); worker?.cancel()
            status.stringValue = "Stopping search…"
            return
        }
        if let textProgress {
            requested = .more(textProgress)
            startNext()
            return
        }
        let declarations = purpose == .findDeclarations
        let text = declarations ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : field.stringValue
        guard !text.isEmpty, text.utf8.count <= EditorFindPlan.maximumQueryBytes else {
            status.stringValue = !text.isEmpty ? "Try a shorter search." : declarations ? "Enter a declaration name." : "Enter text to find."
            return
        }
        let query: EditorProjectTextSearch.Query = declarations ? .declarations(.init(text)) : .text(text,
            .init(matchesCase: matchCase.state == .on, matchMode: wholeWords.state == .on ? .wholeWord : .contains))
        let language = (fileType.selectedItem?.representedObject as? String).flatMap(TextSyntaxLanguage.init(rawValue:))
        guard let metadata = try? EditorProjectTextSearch.metadataRequest(for: query, language: language) else { return }
        guard let scope = try? projectScope?.confined(toRelativeFolder: folder.stringValue) else {
            status.stringValue = "Enter a relative folder within the search scope. Leave it blank to search every subfolder."
            return
        }
        resetResults()
        self.scope = scope
        requested = .discover(.init(metadata: metadata, query: query))
        status.stringValue = "Finding candidate files…"
        startNext()
    }

    private func updateSearchButton() {
        findButton.title = worker != nil ? "Stop" : textProgress == nil ? "Search" : "Search More"
    }

    private func startNext() {
        guard let request = requested, let scope, panel != nil, worker == nil else { return }
        requested = nil
        let epoch = binding
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                session = nil; worker = nil
                if purpose.isTextSearch {
                    updateSearchButton()
                    if status.stringValue == "Stopping search…" {
                        status.stringValue = results.isEmpty ? "Search stopped." : "Search stopped. Earlier matches are still available."
                    }
                }
                startNext()
            }
            do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
            guard epoch == binding, !Task.isCancelled, hasCurrentProject else { return }
            let prepared: FolderAccessPreparation
            switch request {
            case .discover: prepared = access.prepareAccess(to: [scope.root])
            case .more(let progress): prepared = progress.preparation
            }
            let lifetime = await access.retainAccess(for: [scope.root])
            guard epoch == binding, !Task.isCancelled, hasCurrentProject else { return }
            guard access.isCurrent(prepared), !TraverseAccessPolicy.requiresFolderSelection || lifetime.covers(scope.root) else {
                status.stringValue = "This project folder needs access before it can be searched."
                return
            }
            switch request {
            case .more(let progress): await findText(progress, lifetime: lifetime, epoch: epoch)
            case .discover(let discovery): await discover(discovery, scope: scope, preparation: prepared, lifetime: lifetime, epoch: epoch)
            }
        }
        if purpose.isTextSearch { updateSearchButton() }
    }

    private func discover(_ request: Discovery, scope: SearchScope, preparation: FolderAccessPreparation,
                          lifetime: FileAccessLifetimes, epoch: UUID) async {
        let textFolder: LocalProjectTextScope?
        do {
            if request.query != nil {
                textFolder = try await fileSystem.prepareProjectText(in: scope.root, within: projectScope?.root, retaining: lifetime)
            } else { textFolder = nil }
        } catch {
            if !Task.isCancelled && epoch == binding { status.stringValue = "The selected search folder could not be checked. Try another folder." }
            return
        }
        guard !Task.isCancelled, epoch == binding, hasCurrentProject else { return }
        let policy = SearchPolicy(maximumResults: 512, maximumVisitedEntries: 6_000, maximumDepth: 28,
                batchSize: 64, maximumIssues: 8, maximumDuration: 3)
        let running = search.start(request: request.metadata, scope: scope, policy: policy, retaining: lifetime)
        session = running
        var entries: [FileEntry] = []
        for await event in running.events {
            guard !Task.isCancelled, epoch == binding, running.generation.accepts(event), self.scope == scope else { return }
            switch event.payload {
            case .batch(let matches): entries += matches.map(\.entry)
            case .finished(let coverage):
                guard isCurrent?() == true, access.isCurrent(preparation) else {
                    status.stringValue = "The project changed. Open the picker again."
                    return
                }
                if coverage.completion == .failed {
                    status.stringValue = "The project folder could not be searched."
                    return
                }
                if let query = request.query, let textFolder {
                    let candidates = entries.sorted {
                        $0.url.path.utf8.lexicographicallyPrecedes($1.url.path.utf8)
                    }
                    let skipped = Self.unavailableLocations.reduce(0) { $0 + coverage.boundaryCounts[$1, default: 0] }
                    await findText(.init(folder: textFolder, preparation: preparation, candidates: candidates,
                        query: query, locationsSkipped: skipped, traversalLimited: coverage.completion != .completed
                            || coverage.boundaryCounts[.depthLimit, default: 0] > 0), lifetime: lifetime, epoch: epoch)
                } else {
                    await install(entries, coverage: coverage, request: request.metadata, preparation: preparation, epoch: epoch)
                }
            case .progress: break
            }
        }
    }

    private var hasCurrentProject: Bool {
        guard isCurrent?() == true else {
            status.stringValue = "The project changed. Open the picker again."
            return false
        }
        return true
    }

    private func install(_ entries: [FileEntry], coverage: SearchCoverage, request: SearchRequest,
                         preparation: FolderAccessPreparation, epoch: UUID) async {
        let ranking = Task.detached(priority: .userInitiated) {
            var scored: [(FileEntry, FilenameMatching.NavigationQuery.Rank)] = []
            for entry in entries {
                if Task.isCancelled { return [FileEntry]() }
                if let rank = request.filenameNavigationRank(for: entry.name) { scored.append((entry, rank)) }
            }
            return scored.sorted { left, right in
                if left.1 != right.1 { return left.1.rawValue < right.1.rawValue }
                let order = left.0.name.localizedStandardCompare(right.0.name)
                if order != .orderedSame { return order == .orderedAscending }
                return left.0.url.path.utf8.lexicographicallyPrecedes(right.0.url.path.utf8)
            }.map(\.0)
        }
        let ordered = await withTaskCancellationHandler { await ranking.value } onCancel: { ranking.cancel() }
        guard !Task.isCancelled, epoch == binding else { return }
        guard hasCurrentProject, access.isCurrent(preparation) else {
            status.stringValue = "The project or its folder access changed. Open the picker again."
            return
        }
        foundFileCount = ordered.count
        results = ordered.prefix(maximumFileResults).map { .init(entry: $0) }
        self.preparation = preparation
        reloadResults()
        partial = Self.isPartial(coverage)
        updateResultsStatus()
    }

    private static let unavailableLocations: [SearchBoundary] = [.denied, .unavailable, .metadataUnavailable, .changedDuringSearch]
    private static func isPartial(_ coverage: SearchCoverage) -> Bool {
        coverage.completion != .completed || (unavailableLocations + [.depthLimit]).contains { coverage.boundaryCounts[$0, default: 0] > 0 }
    }

    private func reloadResults() {
        table.reloadData()
        if !results.isEmpty { select(0) }
    }

    private func findText(_ progress: TextProgress, lifetime: FileAccessLifetimes, epoch: UUID) async {
        status.stringValue = progress.query.progressLabel
        do {
            let candidates = progress.candidates[progress.offset...]
            let batch = try await fileSystem.readProjectText(candidates, within: progress.folder, retaining: lifetime)
            try Task.checkCancellation()
            let remainingMatches = EditorProjectTextSearch.maximumMatches - results.count
            let compute = Task.detached(priority: .userInitiated) {
                try EditorProjectTextSearch.find(batch, query: progress.query, remainingMatches: remainingMatches)
            }
            let report = try await withTaskCancellationHandler {
                try await compute.value
            } onCancel: { compute.cancel() }
            guard !Task.isCancelled, epoch == binding, hasCurrentProject else { return }
            guard access.isCurrent(progress.preparation) else { status.stringValue = "Folder access changed. Open the picker again."; return }
            var next = progress
            next.offset += batch.consumed
            next.searched += report.searched
            next.skipped += report.skipped
            next.matchesLimited = progress.matchesLimited || report.matchesLimited
            let firstNew = results.count
            results += report.matches.map { .init(entry: $0.entry, match: $0) }
            if firstNew < results.count {
                table.insertRows(at: IndexSet(integersIn: firstNew..<results.count), withAnimation: [])
                if table.selectedRow < 0 { select(0) }
            }
            preparation = progress.preparation
            textFolder = progress.folder
            let filesLeft = next.candidates.count - next.offset
            let canContinue = filesLeft > 0 && results.count < EditorProjectTextSearch.maximumMatches
            textProgress = canContinue ? next : nil
            let matches = results.count == 1 ? "1 match" : "\(results.count.formatted()) matches"
            let files = next.searched == 1 ? "1 file" : "\(next.searched.formatted()) files"
            var details = [matches, files + " searched"]
            if canContinue { details.append("\(filesLeft.formatted()) left") }
            if next.skipped > 0 { details.append(next.skipped == 1 ? "1 file skipped" : "\(next.skipped.formatted()) files skipped") }
            if next.locationsSkipped > 0 { details.append("Some locations unavailable") }
            if next.traversalLimited { details.append("Folder search limit reached") }
            if next.matchesLimited || filesLeft > 0 && !canContinue { details.append("Match limit reached") }
            if batch.consumed == 0 && canContinue { details.append("Try Search More again") }
            else if !results.isEmpty { details.append("Return to open") }
            status.stringValue = details.joined(separator: " · ")
            status.toolTip = status.stringValue
        } catch is CancellationError { return }
        catch TextComparisonReadFailure.changed {
            if !Task.isCancelled && epoch == binding {
                resetResults()
                status.stringValue = "The project folder changed. Search again."
            }
        }
        catch {
            if !Task.isCancelled && epoch == binding { status.stringValue = "The project text could not be read. Try again." }
        }
    }

    private func updateResultsStatus() {
        if partial {
            status.stringValue = results.isEmpty ? "No matches in the folders checked. Some locations could not be searched."
                : "\(results.count.formatted()) matches found. Some locations could not be searched."
            return
        }
        guard !results.isEmpty else { status.stringValue = "No matching filenames."; return }
        let matches = foundFileCount > results.count ? "Showing \(results.count.formatted()) of \(foundFileCount.formatted())"
            : "\(results.count.formatted()) found"
        if let address = query.address {
            status.stringValue = "\(matches) · Return to open at line \(address.line), column \(address.column)"
        } else {
            status.stringValue = "\(matches) · Return to open"
        }
    }

    private func handle(_ command: NativeQueryInput.Command) -> Bool {
        switch command {
        case .cancel: panel?.performClose(nil)
        case .submit:
            if purpose.isTextSearch && (preparation == nil || (results.isEmpty && textProgress != nil)) {
                if worker == nil { searchText(nil) }
            }
            else { openSelected(nil) }
        case .down: select(min(results.count - 1, table.selectedRow + 1))
        case .up: select(max(0, table.selectedRow - 1))
        }
        return true
    }

    private func select(_ row: Int) {
        guard results.indices.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func openSelected(_ sender: Any?) {
        guard let panel, panel.isKeyWindow, let parent, let scope, let preparation, opening == nil,
              parent.isVisible, results.indices.contains(table.selectedRow) else { return }
        let row = results[table.selectedRow], epoch = binding, textFolder = textFolder
        let entry = row.entry
        let destination = row.match?.destination
            ?? query.address.map(EditorFileJump.Destination.line)
        status.stringValue = "Checking the selected file…"
        opening = Task { [weak self, weak panel] in
            guard let self else { return }
            defer { opening = nil }
            let lifetime = await access.retainAccess(for: [scope.root])
            guard !Task.isCancelled, epoch == binding else { return }
            guard isCurrent?() == true, access.isCurrent(preparation), scope.permits(entry.url),
                  !TraverseAccessPolicy.requiresFolderSelection || lifetime.covers(entry.url) else {
                status.stringValue = "The project or its folder access changed. Open the picker again."
                return
            }
            if let textFolder {
                do { try await fileSystem.validateProjectTextScope(textFolder, retaining: lifetime) }
                catch {
                    if !Task.isCancelled && epoch == binding {
                        resetResults()
                        status.stringValue = "The project folder could not be verified. Search again."
                    }
                    return
                }
            }
            let checked = await reader.observe(entry)
            withExtendedLifetime(lifetime) {}
            guard !Task.isCancelled, epoch == binding, panel?.isKeyWindow == true else { return }
            guard checked.validation == .ready else {
                status.stringValue = checked.validation.userMessage
                return
            }
            guard isCurrent?() == true, access.isCurrent(preparation), let selection = checked.textSelection else {
                status.stringValue = "The project changed. Open the picker again."
                return
            }
            #if DEBUG
            didCheckOpenForVerification?(selection)
            #endif
            let open = onOpen
            opening = nil
            dismiss(restoringFocus: true)
            open?(selection, destination)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row), let scope else { return nil }
        let hit = results[row], item = hit.entry
        let folder = item.url.deletingLastPathComponent().pathComponents.dropFirst(scope.root.pathComponents.count)
        let displayedFolder = folder.isEmpty ? scope.root.lastPathComponent : folder.joined(separator: "/")
        if let match = hit.match {
            let context = displayedFolder + "/" + item.name + ":" + String(match.line)
            return CommandDiscoveryPresentation.row(title: match.preview, category: context, shortcut: "", enabled: true,
                emphasis: match.highlight)
        }
        return CommandDiscoveryPresentation.row(title: item.name, category: displayedFolder, shortcut: "", enabled: true)
    }

    func dismiss(restoringFocus: Bool, nativeCloseInProgress: Bool = false) {
        guard let panel else { return }
        let wasKey = panel.isKeyWindow
        self.panel = nil; scope = nil; projectScope = nil; isCurrent = nil; onOpen = nil
        field.stringValue = ""
        folder.stringValue = ""
        changeQuery("")
        CommandDiscoveryPresentation.retire(panel, nativeCloseInProgress: nativeCloseInProgress)
        if restoringFocus, wasKey, let parent, parent.isVisible, parent.attachedSheet == nil {
            parent.makeKeyAndOrderFront(nil)
            if let previousResponder, (previousResponder as? NSView)?.window === parent {
                parent.makeFirstResponder(previousResponder)
            }
        }
        parent = nil; previousResponder = nil
    }

    func closeAndDrain() async {
        draining = true
        defer { draining = false }
        dismiss(restoringFocus: false)
        await search.cancelAndDrain()
        await worker?.value
        await opening?.value
    }

    func windowWillClose(_ notification: Notification) { dismiss(restoringFocus: true, nativeCloseInProgress: true) }
    func windowDidResignKey(_ notification: Notification) { dismiss(restoringFocus: false) }
}
