import AppKit
import ExplorerCore
import Search
import FileMemory

/// One ephemeral search generation per pane. File commands continue through the
/// browser's existing observed boundary; result rows grant no mutation authority.
@MainActor
final class BrowserSearchController: NSObject {
    weak var browser: BrowserViewController?
    let view: NSView
    let queryField = NSSearchField()
    let scopePopup = NSPopUpButton()
    let externalToggle = NSButton(checkboxWithTitle: "Include external drives in This Mac", target: nil, action: nil)
    let kindPopup = NSPopUpButton()
    let datePopup = NSPopUpButton()
    let exactToggle = NSButton(checkboxWithTitle: "Match the complete filename", target: nil, action: nil)
    let extensionField = NSTextField()
    let minimumSizeField = NSTextField()
    let maximumSizeField = NSTextField()
    let searchButton = NSButton()
    let closeButton = NSButton()
    let filtersButton = NSButton()
    var onVisibilityChanged: (() -> Void)?
    private(set) var isShowingResults = false
    private(set) var coverage: SearchCoverage?
    private(set) var hasActiveSession = false
    var resultViewState = NavigationState()
    private let local = LocalMetadataSearch(activityGate: ApplicationFileActivity.gate)
    private let indexed = SpotlightMetadataSearch(activityGate: ApplicationFileActivity.gate)
    private let openReader = SearchResultOpenReader()
    private var openTask: Task<Void, Never>?
    private var openRevision = UUID()
    private(set) var isValidatingResultOpen = false
    private var session: SearchSession?
    private var task: Task<Void, Never>?
    private var revision = UUID()
    private var searchButtonAction: (() -> Void)?
    private var displayedActionRevision: UUID?
    private var hasDisplayedAction = false
    private var wasStopped = false
    lazy var savedNames: BrowserSavedNames = {
        let lane = BrowserSavedNames(browser: browser!)
        lane.changed = { [weak self] in
            guard let self, self.isShowingResults, let browser = self.browser else { return }
            browser.isLoading = self.hasActiveSession || self.savedNames.isRunning
            browser.requestOrdering(); browser.refreshStatus(); self.rebuildSearchMenu()
        }
        lane.forgotten = { [weak self] in self?.clearForgottenSearch() }
        return lane
    }()
    var sources: PrivateNameSources
    private var ranFiles = true
    private var fileQueryUnavailable = false
    private var effectiveQuery = ""
    private var effectiveScope = "Folder and subfolders"
    private var effectiveFilters = ""
    private var notice: String?
    private var presentedLocation: BrowserLocation?
    private let filtersPopover = NSPopover()
    private let filterFeedback = label("", size: 11, color: .secondaryLabelColor)
    private var filtersContent: NSStackView?
    private enum FilterInputFailure: Error {
        case minimum(FileSizeInput.Failure), maximum(FileSizeInput.Failure), reversedRange
    }
    var canSearchFolder: Bool {
        guard let root = browser?.location.directoryURL else { return false }
        return (try? SearchScope(root: root)) != nil
    }
    #if DEBUG
    /// Controlled native verification can execute an index query only within its
    /// explicitly owned fixture. Ordinary production UI never sets this property.
    var indexedFixtureScope: SearchScope?
    var resultOpenHandler: ((FileEntry) -> Void)?
    var beforeResultOpenValidation: (() async -> Void)?
    var localForVerification: LocalMetadataSearch?
    var capturedButtonActionForVerification: (() -> Void)? { searchButtonAction }
    #endif

    init(browser: BrowserViewController) {
        self.browser = browser
        sources = browser.settings.privateNamesSources
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        view = row
        super.init()
        queryField.placeholderString = "Search filenames and saved names"
        queryField.sendsSearchStringImmediately = false
        queryField.sendsWholeSearchString = true
        queryField.maximumRecents = 0
        queryField.recentSearches = []
        queryField.recentsAutosaveName = nil
        queryField.target = self
        queryField.action = #selector(submitAction(_:))
        queryField.controlSize = .small
        queryField.delegate = browser
        queryField.setAccessibilityLabel("Search files and saved names; press Return to search")
        queryField.toolTip = "Choose Files, Saved Names or Both in the search menu. Press Return or Search to run."
        queryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        queryField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scopePopup.addItems(withTitles: ["This Folder", "This Mac"])
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged(_:))
        scopePopup.controlSize = .small
        scopePopup.setAccessibilityLabel("Search scope")
        scopePopup.toolTip = "This Folder includes subfolders. This Mac searches the existing Spotlight filename index."
        scopePopup.widthAnchor.constraint(equalToConstant: 110).interfaceScaled.isActive = true
        if browser.location == .computer { scopePopup.selectItem(at: 1) }
        for (button, image, title, action) in [
            (filtersButton, "line.3.horizontal.decrease", "Search filters", #selector(showFilters(_:))),
            (searchButton, "magnifyingglass", "Search filenames", #selector(submitAction(_:))),
            (closeButton, "xmark", "Close search and return to folder", #selector(closeSearch(_:)))
        ] {
            button.image = symbol(image, title)
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.target = self
            button.action = action
            button.toolTip = title
            button.setAccessibilityLabel(title)
            button.widthAnchor.constraint(equalToConstant: 26).interfaceScaled.isActive = true
        }
        for child in [scopePopup, filtersButton, searchButton, closeButton] { row.addArrangedSubview(child) }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.heightAnchor.constraint(equalToConstant: 40).interfaceScaled.isActive = true
        buildFilters()
        rebuildSearchMenu()
        updateSearchAction()
        view.isHidden = true
    }

    private func admittedLocalSearchBrowser() -> BrowserViewController? {
        guard let browser else { return nil }
        guard !browser.isBrowserSuspended, !browser.isRemoteLocation, !browser.isArchiveLocation else {
            if !browser.isBrowserSuspended { browser.status.stringValue = "Use Find in loaded items (⌘F). Searching remote subfolders or file contents is unavailable." }
            let diagnostic = ApplicationDiagnostics.shared
            let trace = diagnostic.currentTrace ?? diagnostic.begin(.search)
            diagnostic.event(.search, .blocked, trace: trace,
                context: .init(.commandDispatch, flags: browser.isBrowserSuspended ? [.browserSuspended] : []))
            return nil
        }
        return browser
    }

    func show(scopeIndex: Int? = nil, copyFilter: Bool = true) {
        if browser?.isArchiveLocation == true { browser?.focusFilter(nil); return }
        guard admittedLocalSearchBrowser() != nil else { return }
        let priorFilter = copyFilter && browser?.folderFilter.displaysSearch == false ? browser?.filterField.stringValue : nil
        browser?.addressCompletion.cancel()
        browser?.folderFilter.contextWillChange()
        browser?.inlineRename.cancel()
        browser?.selectionGroupDraft.contextChanged()
        if let scopeIndex {
            let index = scopeIndex == 0 && !canSearchFolder ? 1 : scopeIndex
            let changed = index != scopePopup.indexOfSelectedItem
            scopePopup.selectItem(at: index)
            if changed { filtersChanged(nil) }
        }
        else if !isShowingResults, let location = browser?.location, presentedLocation != location {
            scopePopup.selectItem(at: location == .computer || !canSearchFolder || browser?.settings.defaultSearchScope == .thisMac ? 1 : 0)
            presentedLocation = location
        }
        presentedLocation = browser?.location
        scopePopup.item(at: 0)?.isEnabled = canSearchFolder
        rebuildSearchMenu()
        externalToggle.isEnabled = scopePopup.indexOfSelectedItem == 1
        browser?.folderFilter.showSearchField()
        if let priorFilter { queryField.stringValue = priorFilter }
        view.isHidden = false
        updateSearchAction()
        onVisibilityChanged?()
        browser?.folderFilter.focus()
    }

    func submit() {
        guard let browser = admittedLocalSearchBrowser() else { return }
        let text = queryField.stringValue
        let request: SearchRequest
        do { request = try makeRequest(filename: "") }
        catch { presentFilterError(error); return }
        clearFilterError()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presentError("Enter a name to search", detail: "Press Return or Search after entering a filename, nickname or label."); return
        }
        let filenameRequest = sources == .saved ? nil : try? makeRequest(filename: text)
        let nameQuery = sources == .files ? nil : try? RememberedNameQuery(text: text,
            match: exactToggle.state == .on ? .exact : .prefixAndWords,
            separatorTolerant: browser.settings.symbolTolerantNames)
        guard filenameRequest != nil || nameQuery != nil else {
            presentError("Check the search text", detail: "Files use filename text without path separators. Saved names allow up to 512 UTF-8 bytes and 16 words."); return
        }
        let folderScope: SearchScope?
        if scopePopup.indexOfSelectedItem == 0 {
            guard !browser.isOfflineCurrentFolder else {
                presentError("This drive is not available", detail: "Mount it in Drives, choose another folder, or use This Mac to search the existing filename index."); return
            }
            guard let root = browser.location.directoryURL, let scope = try? SearchScope(root: root, showHidden: browser.settings.showsHiddenFiles) else {
                presentError("Choose a folder first", detail: "Open a folder, or select This Mac to query the existing filename index."); return
            }
            folderScope = scope
        } else { folderScope = nil }
        if !isShowingResults { browser.saveViewState() }
        invalidateSession()
        ApplicationDiagnostics.shared.event(.search, .reading, trace: revision)
        isShowingResults = true
        resultViewState = NavigationState()
        coverage = nil
        notice = nil
        wasStopped = false
        ranFiles = sources != .saved
        fileQueryUnavailable = ranFiles && filenameRequest == nil
        effectiveQuery = text
        effectiveScope = folderScope == nil ? (externalToggle.state == .on ? "This Mac + external drives · Spotlight" : "This Mac · Spotlight") : "This Folder + subfolders"
        effectiveFilters = filterDescription(request)
        browser.cancelDirectoryObservation()
        browser.listingTask?.cancel()
        browser.listingTask = nil
        browser.orderingTask?.cancel()
        browser.orderingTask = nil
        browser.sessionID = UUID()
        browser.orderRevision += 1
        browser.workspace?.locationWillChange(in: browser)
        browser.quickLook.endSession()
        browser.openAndShare.selectionDidChange()
        browser.rawEntries = []
        browser.displayedEntries = []
        browser.rowsByURL = [:]
        browser.isBackgroundRefreshing = false
        browser.restoringScroll = true
        browser.loadError = nil
        browser.accessDiagnostic = nil
        browser.issueCount = 0
        browser.isLoading = true
        browser.loadStarted = Date()
        browser.firstRowsMilliseconds = nil
        browser.enumerationMilliseconds = nil
        browser.completeDisplayMilliseconds = nil
        browser.filterField.isEnabled = false
        browser.folderFilter.synchronize()
        browser.renderFilePresentation(selection: [])
        browser.updateFilePresentationVisibility()
        show(copyFilter: false)
        browser.refreshStatus()
        let token = revision
        let browserToken = browser.sessionID
        let includeExternal = externalToggle.state == .on
        if let nameQuery {
            savedNames.begin(query: nameQuery, filters: request, scope: folderScope, external: includeExternal, showsHidden: browser.settings.showsHiddenFiles)
        }
        guard let filenameRequest else {
            browser.isLoading = savedNames.isRunning; browser.requestOrdering(); browser.refreshStatus(); return
        }
        hasActiveSession = true
        updateSearchAction(); rebuildSearchMenu()
        task = Task { [weak self, weak browser] in
            guard let self, let browser else { return }
            let request = filenameRequest
            let lease: FolderAccessLease?
            if let folderScope { lease = await browser.folderAccess.acquireAccess(to: folderScope.root) }
            else { lease = nil }
            guard self.revision == token, browser.sessionID == browserToken, !Task.isCancelled else { return }
            let session: SearchSession
            if let folderScope {
                #if DEBUG
                let local = self.localForVerification ?? self.local
                #else
                let local = self.local
                #endif
                session = local.start(request: request, scope: folderScope, retaining: lease)
            }
            else {
                #if DEBUG
                if let fixture = self.indexedFixtureScope { session = self.indexed.start(request: request, scope: fixture) }
                else { session = self.indexed.start(request: request, includeExternalVolumes: includeExternal) }
                #else
                session = self.indexed.start(request: request, includeExternalVolumes: includeExternal)
                #endif
            }
            self.session = session
            self.hasActiveSession = true
            let generation = session.generation
            for await event in session.events {
                guard self.revision == token, browser.sessionID == browserToken,
                      generation.accepts(event), !Task.isCancelled else { return }
                switch event.payload {
                case .batch(let matches):
                    self.savedNames.rememberFilename(matches.map(\.entry))
                    if browser.displayedEntries.isEmpty || Date().timeIntervalSince(browser.lastOrderRequest) > 0.15 { browser.requestOrdering() }
                case .progress(let coverage): self.coverage = coverage
                case .finished(let coverage):
                    ApplicationDiagnostics.shared.event(.search, coverage.isComplete ? .completed : .partial, trace: token,
                        count: UInt64(coverage.matchedEntries))
                    self.coverage = coverage
                    self.hasActiveSession = false
                    browser.isLoading = self.savedNames.isRunning
                    browser.enumerationMilliseconds = Date().timeIntervalSince(browser.loadStarted) * 1000
                    browser.requestOrdering()
                    self.rebuildSearchMenu()
                }
                browser.refreshStatus()
            }
        }
    }

    func cancel(restoreFolder: Bool = true) {
        let showing = isShowingResults
        invalidateSession()
        isShowingResults = false
        presentedLocation = nil
        coverage = nil
        notice = nil
        wasStopped = false
        resultViewState = NavigationState()
        if showing, let browser {
            // Preserve the ordinary visit through close/suspend/session flush.
            // Once search mode ends, stale result rows must not be observable as
            // the folder's selection by a subsequent capture callback.
            browser.restoringScroll = true
            browser.orderingTask?.cancel()
            browser.orderingTask = nil
            browser.sessionID = UUID()
            browser.orderRevision += 1
            browser.isLoading = false
            browser.rawEntries = []
            browser.displayedEntries = []
            browser.rowsByURL = [:]
            browser.renderFilePresentation(selection: [])
        }
        filtersPopover.close()
        view.isHidden = true
        browser?.folderFilter.showFilterField()
        browser?.folderFilter.synchronize()
        onVisibilityChanged?()
        if showing && restoreFolder { browser?.loadLocation() }
        else if restoreFolder { browser?.consumePendingDirectoryRefresh() }
    }

    /// Forget withdraws copied search text and native field Undo as well as
    /// saved matches. Stop the independent filename lane so it cannot refill
    /// this cleared presentation from the previous submitted query.
    private func clearForgottenSearch() {
        invalidateSession()
        queryField.stringValue = ""
        if let editor = queryField.currentEditor() as? NSTextView {
            editor.undoManager?.removeAllActions(); editor.string = ""
        }
        effectiveQuery = ""; coverage = nil
        notice = "Saved information was forgotten. Enter a new search."
        guard let browser else { return }
        browser.orderingTask?.cancel(); browser.orderingTask = nil
        browser.orderRevision += 1
        browser.rawEntries = []; browser.displayedEntries = []; browser.rowsByURL = [:]
        browser.isLoading = false
        browser.renderFilePresentation(selection: [])
        browser.refreshStatus()
    }

    /// Navigation already owns the next folder/tab. Never reload or retarget it.
    func locationWillChange(preservingIdleScope: Bool = false) {
        let wasSearch = browser?.folderFilter.displaysSearch == true
        cancel(restoreFolder: false)
        queryField.stringValue = ""
        if preservingIdleScope {
            if wasSearch { browser?.folderFilter.showSearchField() }
        } else { browser?.folderFilter.resetDefaultAfterNavigation() }
    }

    /// Actual selection/focus events invalidate pending Open, even if focus or
    /// selection later returns to the same pane/path before a worker completes.
    func openContextWillChange() {
        openRevision = UUID()
        openTask?.cancel()
        openTask = nil
        isValidatingResultOpen = false
    }

    func openSelection(_ entry: FileEntry, intent: BrowserLocalFileOpenIntent = .ordinary) {
        guard isShowingResults, let browser, browser.orderedSelectedURLs == [entry.url],
              !browser.isBrowserSuspended, browser.isActiveCommandPane else { return }
        openContextWillChange()
        let token = openRevision
        let queryToken = revision
        let tab = browser.activeID
        let visit = browser.sessionID
        let presentation = browser.filePresentationID
        let pane = browser.paneID
        isValidatingResultOpen = true
        openTask = Task { [weak self, weak browser] in
            guard let self, let browser else { return }
            let lifetime = await browser.accessLifetime(for: [entry.url])
            defer {
                withExtendedLifetime(lifetime) {}
                if self.openRevision == token { self.isValidatingResultOpen = false; self.openTask = nil }
            }
            #if DEBUG
            if let hook = self.beforeResultOpenValidation { await hook() }
            #endif
            guard !Task.isCancelled else { return }
            let rememberedID = self.savedNames.matches[entry.url]?.id
            let work: @Sendable (URL) async throws -> Void = { url in
                guard url == entry.url else { throw RememberedReferenceFailure.changed }
                let result = await self.openReader.validate(entry)
                await MainActor.run {
                    guard !Task.isCancelled, self.openRevision == token, self.revision == queryToken,
                          self.isShowingResults, !browser.isBrowserSuspended, browser.paneID == pane,
                          browser.activeID == tab, browser.sessionID == visit, browser.filePresentationID == presentation,
                          browser.orderedSelectedURLs == [entry.url], browser.isActiveCommandPane,
                          browser.hasFileCommandFocus else { return }
                    guard result == .ready else {
                        if result != .cancelled { self.notice = result.userMessage; browser.refreshStatus() }
                        return
                    }
                    #if DEBUG
                    if let handler = self.resultOpenHandler { handler(entry); return }
                    #endif
                    if entry.kind == .directory { browser.navigate(to: .directory(entry.url)) }
                    else { browser.openVerifiedLocalFile(entry, intent: intent) }
                }
            }
            do {
                if let rememberedID { try await browser.privateNames.use(rememberedID, perform: work) }
                else { try await work(entry.url) }
            } catch {
                if self.openRevision == token, !Task.isCancelled { self.notice = ApplicationPrivateNames.message(error); browser.refreshStatus() }
            }
        }
    }

    @discardableResult func renderStatusIfNeeded() -> Bool {
        updateSearchAction()
        guard isShowingResults, let browser else { return false }
        let count = browser.rawEntries.count
        let prefix = "\(effectiveScope) · \(count) " + (count == 1 ? "match" : "matches")
        let detail: String
        if let notice { detail = notice }
        else if hasActiveSession {
            detail = coverage.map { "Searching… \($0.visitedEntries.formatted()) items seen" } ?? "Searching…"
        }
        else if let coverage {
            switch coverage.completion {
            case .completed:
                if coverage.indexedCoverageUnverified { detail = "Index finished; coverage unverified" }
                else if coverage.isComplete { detail = "Search complete" }
                else {
                    let problems: [SearchBoundary] = [.denied, .unavailable, .metadataUnavailable, .depthLimit, .changedDuringSearch]
                    detail = problems.contains { (coverage.boundaryCounts[$0] ?? 0) > 0 }
                        ? "Finished with unread or changed locations" : "Finished with selected exclusions"
                }
            case .cancelled: detail = "Stopped; partial results"
            case .resultLimit: detail = "Result/candidate limit reached; incomplete"
            case .traversalLimit: detail = "Folder scan limit reached; incomplete"
            case .timedOut: detail = "Time limit reached; incomplete"
            case .failed: detail = "Search unavailable; coverage incomplete"
            }
        } else { detail = "Search stopped; coverage incomplete" }
        let denied = coverage?.boundaryCounts[.denied] ?? 0
        let unavailable = (coverage?.boundaryCounts[.unavailable] ?? 0) + (coverage?.boundaryCounts[.metadataUnavailable] ?? 0)
        let gaps = denied + unavailable > 0 ? " · \(denied) denied, \(unavailable) unavailable" : ""
        let filesDetail = fileQueryUnavailable ? "Files: input valid only for saved names" : "Files: " + detail + gaps
        let laneDetail = [ranFiles ? filesDetail : nil, savedNames.status.isEmpty ? nil : savedNames.status].compactMap { $0 }.joined(separator: " · ")
        browser.status.stringValue = prefix + " · " + laneDetail
        let boundaries = coverage.map { value in
            value.boundaryCounts.map { reason, count in "\(count) \(Self.boundaryName(reason))" }.sorted().joined(separator: ", ")
        } ?? ""
        browser.status.toolTip = "Search: \(effectiveQuery)\n\(effectiveFilters)\n\(laneDetail)" + (boundaries.isEmpty ? "" : "\n" + boundaries)
        browser.overlayActions.isHidden = true
        browser.overlay.isHidden = !browser.displayedEntries.isEmpty
        if browser.displayedEntries.isEmpty {
            browser.overlayTitle.stringValue = browser.isLoading ? "Searching…" : wasStopped ? "Search stopped" : "No results in checked locations"
            let explanation = ranFiles ? detail : savedNames.status
            browser.overlayDetail.stringValue = explanation + ". Close search to return to the folder."
        }
        return true
    }

    private static func boundaryName(_ boundary: SearchBoundary) -> String {
        switch boundary {
        case .hidden: "hidden items excluded"
        case .excluded: "excluded locations"
        case .symbolicLink: "links not followed"
        case .package: "packages not scanned"
        case .nestedVolume: "nested volumes excluded"
        case .cloudItem: "cloud/provider locations not scanned"
        case .credentialLocation: "credential locations excluded"
        case .denied: "access denied"
        case .unavailable: "unavailable locations"
        case .metadataUnavailable: "unread metadata"
        case .depthLimit: "depth limits"
        case .changedDuringSearch: "locations changed during search"
        }
    }

    private func invalidateSession() {
        openContextWillChange()
        revision = UUID()
        session?.cancel()
        session = nil
        task?.cancel()
        task = nil
        savedNames.reset()
        hasActiveSession = false
        wasStopped = false
    }

    private func makeRequest(filename: String? = nil) throws -> SearchRequest {
        let kind: FileKind?
        switch kindPopup.indexOfSelectedItem {
        case 1: kind = .file
        case 2: kind = .directory
        case 3: kind = .package
        case 4: kind = .symbolicLink
        default: kind = nil
        }
        let minimum: Int64?
        let maximum: Int64?
        do { minimum = try FileSizeInput.bytes(minimumSizeField.stringValue) }
        catch let error as FileSizeInput.Failure { throw FilterInputFailure.minimum(error) }
        do { maximum = try FileSizeInput.bytes(maximumSizeField.stringValue) }
        catch let error as FileSizeInput.Failure { throw FilterInputFailure.maximum(error) }
        var byteRange: ClosedRange<Int64>?
        if minimum != nil || maximum != nil {
            let low = minimum ?? 0, high = maximum ?? Int64.max
            guard low <= high else { throw FilterInputFailure.reversedRange }
            byteRange = low...high
        }
        let now = Date()
        let days = [0, 1, 7, 30][max(0, min(3, datePopup.indexOfSelectedItem))]
        let dateRange: ClosedRange<Date>? = days == 0 ? nil : now.addingTimeInterval(-Double(days) * 86_400)...now
        let suffix = extensionField.stringValue.trimmingCharacters(in: .whitespaces)
        return try SearchRequest(filename: filename ?? queryField.stringValue, filenameMatch: exactToggle.state == .on ? .exact : .contains,
                                 kind: kind, filenameExtension: suffix.isEmpty ? nil : suffix, byteRange: byteRange, dateRange: dateRange,
                                 symbolTolerant: browser?.settings.symbolTolerantNames ?? true)
    }

    private func filterDescription(_ request: SearchRequest) -> String {
        var values = [request.filenameMatch == .exact ? "Complete filename" : "Filename contains"]
        if let kind = request.kind { values.append("Type: " + kind.rawValue) }
        if let suffix = request.filenameExtension { values.append("Extension: " + suffix) }
        if request.byteRange != nil {
            let minimum = minimumSizeField.stringValue.trimmingCharacters(in: .whitespaces)
            let maximum = maximumSizeField.stringValue.trimmingCharacters(in: .whitespaces)
            func supplied(_ value: String) -> String {
                value.utf8.contains(where: { (65...90).contains($0) || (97...122).contains($0) }) ? value : value + " bytes"
            }
            if minimum.isEmpty { values.append("At most " + supplied(maximum)) }
            else if maximum.isEmpty { values.append("At least " + supplied(minimum)) }
            else { values.append(supplied(minimum) + " to " + supplied(maximum) + ", inclusive") }
        }
        if request.dateRange != nil { values.append(datePopup.titleOfSelectedItem ?? "Modified date") }
        return values.joined(separator: " · ")
    }

    private func buildFilters() {
        kindPopup.addItems(withTitles: ["Any type", "Files", "Folders", "Packages", "Symbolic links"])
        datePopup.addItems(withTitles: ["Any modified date", "Modified in past day", "Modified in past week", "Modified in past 30 days"])
        extensionField.placeholderString = "Extension, e.g. pdf"
        minimumSizeField.placeholderString = "e.g. 10 MB"
        maximumSizeField.placeholderString = "e.g. 1 GiB"
        for control in [kindPopup, datePopup] { control.target = self; control.action = #selector(filtersChanged(_:)) }
        for control in [externalToggle, exactToggle] { control.target = self; control.action = #selector(filtersChanged(_:)) }
        for field in [extensionField, minimumSizeField, maximumSizeField] {
            field.controlSize = .small
            field.target = self
            field.action = #selector(filtersChanged(_:))
        }
        minimumSizeField.setAccessibilityLabel("Minimum size")
        maximumSizeField.setAccessibilityLabel("Maximum size")
        let unitHelp = "Leave blank for no limit. Plain numbers mean bytes. KB, MB, GB and TB use 1000; KiB, MiB, GiB and TiB use 1024. Use a decimal point for fractions that equal whole bytes."
        for field in [minimumSizeField, maximumSizeField] { field.toolTip = unitHelp; field.setAccessibilityHelp(unitHelp) }
        extensionField.setAccessibilityLabel("Filename extension")
        let minimum = stack([label("Minimum size", size: 12), minimumSizeField], orientation: .vertical, spacing: 4)
        let maximum = stack([label("Maximum size", size: 12), maximumSizeField], orientation: .vertical, spacing: 4)
        let sizes = stack([minimum, maximum], orientation: .horizontal, spacing: 10); sizes.distribution = .fillEqually
        let suffix = stack([label("Extension", size: 12), extensionField], orientation: .vertical, spacing: 4)
        let clear = NSButton(title: "Clear file filters", target: self, action: #selector(clearFileFilters(_:)))
        clear.controlSize = .small
        let explanation = label("Press Search to apply these filters.\nExternal drives use their existing index.", size: 11, color: .secondaryLabelColor)
        filterFeedback.lineBreakMode = .byWordWrapping; filterFeedback.maximumNumberOfLines = 3
        filterFeedback.heightAnchor.constraint(equalToConstant: 40).interfaceScaled.isActive = true
        let content = stack([label("File filters", weight: .semibold), exactToggle, kindPopup, datePopup, suffix, sizes,
            filterFeedback, externalToggle, clear, explanation], orientation: .vertical, spacing: 8)
        content.alignment = .leading
        content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        content.widthAnchor.constraint(equalToConstant: 320).interfaceScaled.isActive = true
        for child in [suffix, sizes, filterFeedback, explanation] {
            child.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24).isActive = true
        }
        for (field, group) in [(extensionField, suffix), (minimumSizeField, minimum), (maximumSizeField, maximum)] {
            field.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        }
        let controller = NSViewController()
        controller.view = content
        filtersPopover.contentViewController = controller
        filtersPopover.behavior = .transient
        filtersContent = content
        clearFilterError()
        InterfacePresentation.shared.register(content)
    }

    private func clearFilterError() {
        filterFeedback.stringValue = "Leave either size blank for no limit.\nPlain numbers mean bytes."
        filterFeedback.textColor = .secondaryLabelColor
        filterFeedback.setAccessibilityLabel("File size help")
    }

    private func presentFilterError(_ error: Error) {
        let field: NSTextField
        let message: String
        switch error as? FilterInputFailure {
        case .minimum(let reason): field = minimumSizeField; message = sizeError(reason)
        case .maximum(let reason): field = maximumSizeField; message = sizeError(reason)
        case .reversedRange: field = maximumSizeField; message = "Maximum size must be at least the minimum size."
        case nil: field = extensionField; message = "Use one extension without a dot, such as pdf."
        }
        ApplicationDiagnostics.shared.event(.search, .blocked)
        filterFeedback.stringValue = message; filterFeedback.textColor = .systemRed
        filterFeedback.setAccessibilityLabel("Search filter error")
        showFilters(nil)
        field.selectText(nil)
        NSAccessibility.post(element: filterFeedback, notification: .valueChanged)
    }

    private func sizeError(_ error: FileSizeInput.Failure) -> String {
        switch error {
        case .fractionalByte: "Use a size equal to whole bytes, such as 0.5 KiB."
        case .tooLarge: "This size is too large. Use a smaller value."
        case .negativeValue: "Use zero or a larger size."
        case .invalidFormat, .unknownUnit: "Use a size such as 10 MB or 1 GiB, with a decimal point for fractions."
        }
    }

    var onSearchMenuChanged: (() -> Void)?
    private func rebuildSearchMenu() {
        let menu = NSMenu(title: "Search scope")
        menu.autoenablesItems = false
        for (title, action, selected) in [("This Folder and subfolders", #selector(selectFolder(_:)), scopePopup.indexOfSelectedItem == 0),
                                           ("This Mac — indexed filenames", #selector(selectMac(_:)), scopePopup.indexOfSelectedItem == 1)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = selected ? .on : .off
            item.isEnabled = action != #selector(selectFolder(_:)) || canSearchFolder
            menu.addItem(item)
        }
        appendSearchOptions(to: menu)
        queryField.searchMenuTemplate = menu
        onSearchMenuChanged?()
    }
    func appendSearchOptions(to menu: NSMenu) {
        let stop = NSMenuItem(title: "Stop Search and Keep Results", action: #selector(stopSearch(_:)), keyEquivalent: "")
        stop.target = self; stop.representedObject = revision
        stop.isEnabled = hasActiveSession || savedNames.isRunning
        menu.addItem(stop)
        menu.addItem(.separator())
        for source in PrivateNameSources.allCases {
            let item = NSMenuItem(title: "Sources: " + source.rawValue, action: #selector(selectSources(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = source.rawValue; item.state = sources == source ? .on : .off
            menu.addItem(item)
        }
        if savedNames.hasNext {
            let more = NSMenuItem(title: "Check next saved-name page", action: #selector(moreSavedNames(_:)), keyEquivalent: "")
            more.target = self; menu.addItem(more)
        }
        let external = NSMenuItem(title: "Include external drives", action: #selector(toggleExternal(_:)), keyEquivalent: "")
        external.target = self
        external.state = externalToggle.state
        external.isEnabled = scopePopup.indexOfSelectedItem == 1
        menu.addItem(external)
        menu.addItem(.separator())
        let filters = NSMenuItem(title: "Type, date and size filters…", action: #selector(showFilters(_:)), keyEquivalent: "")
        filters.target = self
        menu.addItem(filters)
    }

    private func presentError(_ title: String, detail: String) {
        ApplicationDiagnostics.shared.event(.search, .blocked)
        guard let window = browser?.view.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }

    @objc private func submitAction(_ sender: Any?) {
        if sender as? NSButton === searchButton { searchButtonAction?(); return }
        if sender as? NSSearchField === queryField && queryField.stringValue.isEmpty {
            if isShowingResults { cancel() }
            else {
                browser?.folderFilter.synchronize()
                browser?.consumePendingDirectoryRefresh()
            }
            return // Native Cancel of an idle draft does not submit an empty query.
        }
        submit()
    }
    private func updateSearchAction() {
        let running = isShowingResults && (hasActiveSession || savedNames.isRunning)
        let token = running ? revision : nil
        guard !hasDisplayedAction || displayedActionRevision != token else { return }
        let symbolChanged = !hasDisplayedAction || (displayedActionRevision != nil) != running
        hasDisplayedAction = true; displayedActionRevision = token
        if running {
            let token = revision
            searchButtonAction = { [weak self] in self?.stopKeepingResults(expected: token) }
        } else { searchButtonAction = { [weak self] in self?.submit() } }
        guard symbolChanged else { return }
        let title = running ? "Stop search and keep results" : "Search filenames and saved names"
        searchButton.image = symbol(running ? "stop.fill" : "magnifyingglass", title)
        searchButton.setAccessibilityLabel(title); searchButton.toolTip = title
    }
    @objc private func stopSearch(_ item: NSMenuItem) {
        guard let token = item.representedObject as? UUID else { return }; stopKeepingResults(expected: token)
    }
    private func stopKeepingResults(expected: UUID) {
        guard revision == expected, isShowingResults, let browser,
              !browser.isBrowserSuspended,
              hasActiveSession || savedNames.isRunning else { return }
        wasStopped = true
        savedNames.stopKeepingResults()
        if let session, hasActiveSession { session.cancel() }
        else {
            task?.cancel(); hasActiveSession = false
            if ranFiles { notice = "Search stopped; partial results" }
        }
        browser.isLoading = hasActiveSession || savedNames.isRunning
        browser.requestOrdering(); browser.refreshStatus(); rebuildSearchMenu()
    }
    @objc private func closeSearch(_ sender: Any?) { cancel() }
    @objc private func showFilters(_ sender: Any?) {
        if view.isHidden { show(scopeIndex: scopePopup.indexOfSelectedItem, copyFilter: false) }
        externalToggle.isEnabled = scopePopup.indexOfSelectedItem == 1
        if let content = filtersContent {
            content.layoutSubtreeIfNeeded()
            filtersPopover.contentSize = content.fittingSize
        }
        let motion = browser?.settings.motion ?? .init()
        filtersPopover.animates = motion.mode == .full && motion.allows(.pages) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !filtersPopover.isShown { filtersPopover.show(relativeTo: filtersButton.bounds, of: filtersButton, preferredEdge: .maxY) }
    }
    @objc private func selectSources(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = PrivateNameSources(rawValue: raw) else { return }
        sources = value; filtersChanged(sender); rebuildSearchMenu(); browser?.folderFilter.synchronize()
    }
    @objc private func moreSavedNames(_ sender: Any?) { savedNames.loadMore() }
    @objc private func scopeChanged(_ sender: Any?) { filtersChanged(sender); rebuildSearchMenu(); browser?.folderFilter.synchronize() }
    @objc private func selectFolder(_ sender: Any?) { guard canSearchFolder else { return }; scopePopup.selectItem(at: 0); scopeChanged(sender) }
    @objc private func selectMac(_ sender: Any?) { scopePopup.selectItem(at: 1); scopeChanged(sender) }
    @objc private func toggleExternal(_ sender: Any?) { externalToggle.state = externalToggle.state == .on ? .off : .on; filtersChanged(sender) }
    @objc private func clearFileFilters(_ sender: Any?) {
        exactToggle.state = .off; kindPopup.selectItem(at: 0); datePopup.selectItem(at: 0)
        extensionField.stringValue = ""; minimumSizeField.stringValue = ""; maximumSizeField.stringValue = ""
        filtersChanged(sender)
    }
    @objc private func filtersChanged(_ sender: Any?) {
        do { _ = try makeRequest(filename: "") }
        catch { presentFilterError(error); return }
        clearFilterError()
        externalToggle.isEnabled = scopePopup.indexOfSelectedItem == 1
        rebuildSearchMenu()
        guard isShowingResults, let browser else { return }
        invalidateSession()
        coverage = nil
        resultViewState = NavigationState()
        notice = "Filters changed; press Search"
        effectiveScope = scopePopup.indexOfSelectedItem == 0 ? "This Folder + subfolders"
            : externalToggle.state == .on ? "This Mac + external drives · Spotlight" : "This Mac · Spotlight"
        browser.isLoading = false
        browser.rawEntries = []
        browser.requestOrdering()
        browser.refreshStatus()
    }
}
