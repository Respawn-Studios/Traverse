import AppKit
import ExplorerCore
import LocalStorage
import Search
import FileMemory

/// One editor generation per pane. Native field text remains the only editable
/// value; the ghost is a noninteractive overlay and never enters Undo or IME.
@MainActor
final class BrowserAddressCompletionController: NSObject {
    private weak var browser: BrowserViewController?
    private weak var editor: NSTextView?
    private var task: Task<Void, Never>?
    private var session: DirectoryCompletionSession?
    private let nameIndex = SpotlightMetadataSearch(activityGate: ApplicationFileActivity.gate)
    private var nameSession: SearchSession?
    private var savedUse: RememberedNameUse?
    private var savedOwner: ApplicationPrivateNames?
    private let savedObserver = UUID()
    private var revision = UUID()
    private var context: Context?
    private var observers: [BrowserNotificationObservation] = []
    private let ghost = AddressGhostView()
    private let panel = AddressSuggestionPanel()
    private let rows = NSStackView()
    private var buttons: [NSButton] = []
    private(set) var suggestions: [AddressSuggestion] = []
    private(set) var selectedIndex: Int?
    private(set) var explicitlySelected = false
    private(set) var result: DirectoryCompletionResult?
    private(set) var message = ""
    private var dismissedInput: String?
    private var applying = false
    var service = BrowserAddressServices.completion
    #if DEBUG
    // Nil in ordinary Debug. Qualification may refuse admission before any local lookup.
    var localAdmissionForVerification: (() -> Bool)?
    private(set) var changedInvocationsForVerification = 0
    private(set) var resumeInvocationsForVerification = 0
    var hasLocalWorkForVerification: Bool { task != nil || session != nil || nameSession != nil || savedUse != nil || savedOwner != nil }
    var nameLocationsForVerification: [FolderNameLocation]?
    var nameIndexScopeForVerification: SearchScope?
    var nameIndexDirectoryHintForVerification = false
    var nameIndexOrdinaryPlanForVerification = false
    private(set) var nameIndexCoverageForVerification: SearchCoverage?
    private(set) var nameRequestForVerification: SearchRequest?
    #endif
    private struct Context: Equatable {
        let pane: UUID; let tab: UUID; let visit: UUID; let window: ObjectIdentifier
    }
    init(browser: BrowserViewController) {
        self.browser = browser
        super.init()
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 2
        rows.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        let material = NSVisualEffectView()
        material.material = .popover; material.state = .active; material.blendingMode = .withinWindow
        material.wantsLayer = true; material.layer?.cornerRadius = 9; material.layer?.masksToBounds = true
        panel.contentView = material
        panel.hasShadow = true; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = true
        panel.setAccessibilityLabel("Folder address suggestions")
        pin(rows, inside: material)
    }
    isolated deinit { task?.cancel(); session?.cancel(); nameSession?.cancel(); savedOwner?.stopObserving(savedObserver); panel.orderOut(nil); ghost.removeFromSuperview() }

    private var permitsLocalCompletion: Bool {
        guard let browser else { return false }
        switch browser.location {
        case .computer: return true
        case .directory(let url): return url.isFileURL
        case .sftp, .smb, .archive: return false
        }
    }
    private func liveContext() -> Context? {
        guard permitsLocalCompletion, let browser, !browser.isBrowserSuspended, browser.isActiveCommandPane, !browser.pathField.isHidden,
              let window = browser.view.window, let editor, browser.pathField.currentEditor() === editor else { return nil }
        #if DEBUG
        guard browser.permitsBackgroundVerification || window.isKeyWindow else { return nil }
        #else
        guard window.isKeyWindow else { return nil }
        #endif
        return Context(pane: browser.paneID, tab: browser.activeID, visit: browser.sessionID, window: ObjectIdentifier(window))
    }
    func beganEditing(_ editor: NSTextView) {
        cancel()
        guard permitsLocalCompletion else { return }
        self.editor = editor; context = liveContext()
        editor.addSubview(ghost)
        for name in [NSTextView.didChangeSelectionNotification, NSView.boundsDidChangeNotification] {
            observers.append(BrowserNotificationObservation(name: name) { [weak self] notification in
                let object = notification.object.map { ObjectIdentifier($0 as AnyObject) }
                MainActor.assumeIsolated {
                    guard let self, let editor = self.editor,
                          object == ObjectIdentifier(editor) || object == editor.enclosingScrollView.map({ ObjectIdentifier($0.contentView) }) else { return }
                    if name == NSTextView.didChangeSelectionNotification { self.selectionChanged() }
                    else { self.updateGhost() }
                }
            })
        }
        if let window = browser?.view.window {
            for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                observers.append(BrowserNotificationObservation(name: name, object: window) { [weak self] _ in
                    MainActor.assumeIsolated {
                        // Settings can take key status without ending native
                        // address editing. Retire work/presentation, not the
                        // editor binding needed on return.
                        if name == NSWindow.didResignKeyNotification { self?.hideAndCancel() }
                        else if name == NSWindow.didBecomeKeyNotification { self?.changed() }
                        else { self?.layout() }
                    }
                })
            }
        }
        changed()
    }
    func changed() {
        #if DEBUG
        changedInvocationsForVerification += 1
        #endif
        guard permitsLocalCompletion else { cancel(); return }
        guard !applying, let browser else { return }
        // AppKit can restore a suspended field editor without a fresh begin
        // notification. A real text change must rebind that same editor too.
        if editor == nil, !browser.pathField.isHidden,
           let current = browser.pathField.currentEditor() as? NSTextView { beganEditing(current); return }
        guard let editor else { return }
        #if DEBUG
        nameRequestForVerification = nil
        nameIndexCoverageForVerification = nil
        #endif
        revision = UUID(); task?.cancel(); session?.cancel(); session = nil; nameSession?.cancel(); nameSession = nil
        releaseSavedNames()
        suggestions = []; selectedIndex = nil; explicitlySelected = false; result = nil; hidePresentation()
        browser.pathField.setAccessibilityHelp("Enter a folder name or local path. Tab fills a suggestion; Return opens an explicit path.")
        let text = editor.string
        guard dismissedInput != text, browser.settings.addressPresentation != .off,
              !editor.hasMarkedText(), editor.selectedRange().length == 0,
              editor.selectedRange().location == text.utf16.count,
              let context = liveContext() else { return }
        #if DEBUG
        if let localAdmissionForVerification, !localAdmissionForVerification() { return }
        #endif
        let pathRequest = BrowsingHome.completionHome(for: text).flatMap { home in
            try? AddressCompletionRequest(text: text, home: home,
                showsHidden: browser.settings.showsHiddenFiles, symbolTolerant: browser.settings.symbolTolerantNames)
        }
        let nameRequest = try? FolderNameRequest(text: text, showsHidden: browser.settings.showsHiddenFiles, symbolTolerant: browser.settings.symbolTolerantNames)
        guard pathRequest != nil || nameRequest != nil else { return }
        self.context = context
        let token = revision
        let policy = DirectoryCompletionPolicy(maximumSuggestions: browser.settings.addressSuggestionLimit)
        task = Task { [weak self, weak browser] in
            do {
                try await Task.sleep(for: .milliseconds(90))
                guard let browser, !ApplicationFileActivity.gate.isClosed,
                      self?.liveContext() == context else { return }
                if let nameRequest {
                    try await self?.completeName(nameRequest, input: text, token: token, context: context)
                    return
                }
                guard let request = pathRequest else { return }
                let lifetime = await browser.accessLifetime(for: [request.parent])
                try Task.checkCancellation()
                guard let self, self.revision == token, self.liveContext() == context else { return }
                let session = self.service.start(owner: browser.paneID, request: request, policy: policy,
                                                 visits: browser.settings.directoryVisits.counts, retaining: lifetime)
                self.session = session
                for try await value in session.results {
                    guard !Task.isCancelled, self.revision == token, self.liveContext() == context,
                          self.editor?.string == text, self.editor?.hasMarkedText() == false else { return }
                    self.result = value; self.suggestions = value.suggestions
                    self.selectedIndex = value.suggestions.first?.match == .approximate ? nil : (value.suggestions.isEmpty ? nil : 0)
                    self.message = value.isTruncated ? "More folders may exist · keep typing"
                        : value.suggestions.isEmpty ? "No matching folders" : "Tab completes · Return opens"
                    self.render()
                    if value.suggestions.isEmpty { _ = try await self.completeDriveCorrection(input: text, token: token, context: context) }
                }
            } catch is CancellationError { }
            catch {
                guard let self, self.revision == token, self.liveContext() == context else { return }
                if (try? await self.completeDriveCorrection(input: text, token: token, context: context)) == true { return }
                self.message = "Suggestions unavailable here · you can still type a path"
                self.render()
            }
        }
    }

    private func familiarLocations() -> [FolderNameLocation] {
        #if DEBUG
        if let nameLocationsForVerification { return nameLocationsForVerification }
        #endif
        let familiar = BrowsingHome.url.map { home in [FolderNameLocation(name: "Home", url: home, source: .familiar)]
            + ["Downloads", "Desktop", "Documents", "Pictures", "Music", "Movies", "Public"].map {
                FolderNameLocation(name: $0, url: home.appendingPathComponent($0, isDirectory: true), source: .familiar)
            }
        } ?? []
        let mounted = browser?.operationCoordinator.drives.volumes.compactMap { volume -> FolderNameLocation? in
            guard let url = volume.url,
                  url.path == "/" || url.deletingLastPathComponent().path == "/Volumes",
                  volume.deviceKind != .unknown else { return nil }
            return FolderNameLocation(name: volume.name, url: url, source: .volume)
        } ?? []
        return familiar + mounted
    }

    private func completeDriveCorrection(input: String, token: UUID, context: Context) async throws -> Bool {
        // `/Workspace/` remains a literal path. Only offer a visibly labelled
        // mounted-drive alternative; neither Return nor an error rewrites it.
        guard permitsLocalCompletion, liveContext() == context, revision == token, !Task.isCancelled,
              input.hasPrefix("/"), let query = try? FolderNameRequest(text: String(input.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: "/")), symbolTolerant: browser?.settings.symbolTolerantNames ?? true),
              !input.dropFirst().dropLast(input.hasSuffix("/") ? 1 : 0).contains("/") else { return false }
        return try await completeName(query, input: input, token: token, context: context, drivesOnly: true)
    }

    @discardableResult
    private func completeName(_ query: FolderNameRequest, input: String, token: UUID, context: Context,
                              drivesOnly: Bool = false) async throws -> Bool {
        guard permitsLocalCompletion, let browser, revision == token,
              liveContext() == context, !Task.isCancelled else { return false }
        let hints = familiarLocations().filter { !drivesOnly || $0.source == .volume }
        let lifetime = await browser.accessLifetime(for: hints.filter { query.match($0.name) != nil }.map(\.url))
        try Task.checkCancellation()
        guard revision == token, liveContext() == context else { return false }
        let known = service.startLocations(owner: browser.paneID, request: query, locations: hints,
            policy: .init(maximumSuggestions: browser.settings.addressSuggestionLimit),
            visits: browser.settings.directoryVisits.counts, retaining: lifetime)
        session = known
        var ranking = FolderNameSuggestionRanking(request: query, limit: browser.settings.addressSuggestionLimit,
            visits: browser.settings.directoryVisits.counts)
        for try await value in known.results {
            guard !Task.isCancelled, revision == token, liveContext() == context, editor?.string == input else { return false }
            result = value
            for hint in value.suggestions { ranking.consider(.init(name: hint.name, url: hint.url, source: hint.source)) }
            publishNames(ranking.suggestions, message: drivesOnly ? "Mounted drive · Tab fills its actual path" : "Mac folders and drives · checking indexed folder names…")
        }
        guard permitsLocalCompletion, revision == token, liveContext() == context, !Task.isCancelled else { return false }
        if drivesOnly { return !suggestions.isEmpty }
        // A one-letter input gets familiar hints only. Each pane owns one
        // replaceable, capped index session; no per-keystroke filesystem crawl.
        guard query.text.count >= 2 else {
            publishNames(ranking.suggestions, message: "Type two characters for indexed folder names"); return !suggestions.isEmpty
        }
        var heldSavedUse: RememberedNameUse?
        defer { withExtendedLifetime(heldSavedUse) {} }
        if browser.settings.privateNamesAddressSuggestions {
            let owner = browser.privateNames
            savedOwner = owner
            owner.observe(savedObserver) { [weak self] _ in self?.hideAndCancel() }
            if let savedQuery = try? RememberedNameQuery(text: query.text, separatorTolerant: query.symbolTolerant, pageSize: 16),
               let (page, use) = try? await owner.search(savedQuery) {
                heldSavedUse = use
                var matches: [RememberedNameMatch] = []
                if page.publish({ matches = $0 }) {
                    guard revision == token, !Task.isCancelled else { return false }
                    savedUse = use
                    await withTaskGroup(of: (RememberedNameMatch, FileEntry?).self) { group in
                        var index = 0
                        func add(_ match: RememberedNameMatch) {
                            group.addTask { (match, try? await owner.entry(match.item.id, showHidden: query.showsHidden)) }
                        }
                        while index < min(2, matches.count) { add(matches[index]); index += 1 }
                        while let (match, entry) = await group.next() {
                            guard revision == token, !Task.isCancelled, liveContext() == context else { group.cancelAll(); return }
                            if let entry, entry.kind == .directory, let reason = match.reasons.first {
                                ranking.consider(.init(name: reason.value, url: entry.url, source: .savedName))
                                publishNames(ranking.suggestions, message: "Mac folders, saved names and indexed folders · Tab fills the real path")
                            }
                            if index < matches.count { add(matches[index]); index += 1 }
                        }
                    }
                }
            }
        }
        guard revision == token, !Task.isCancelled, liveContext() == context else { return false }
        let request = try SearchRequest(filename: query.text, kind: .directory, symbolTolerant: query.symbolTolerant)
        #if DEBUG
        nameRequestForVerification = request
        if browser.isControlledVerification && nameIndexScopeForVerification == nil
            && !nameIndexDirectoryHintForVerification && !nameIndexOrdinaryPlanForVerification {
            publishNames(ranking.suggestions, message: "Generated familiar-folder hints"); return !suggestions.isEmpty
        }
        #endif
        let policy = SearchPolicy(maximumResults: 128, maximumVisitedEntries: 256, maximumIssues: 16, maximumDuration: 0.6)
        let indexed: SearchSession
        #if DEBUG
        if nameIndexDirectoryHintForVerification {
            indexed = nameIndex.startDirectoryHintForQualification(request: request, scope: nameIndexScopeForVerification, policy: policy, retaining: lifetime)
        } else if let scope = nameIndexScopeForVerification { indexed = nameIndex.start(request: request, scope: scope, policy: policy, retaining: lifetime) }
        else { indexed = nameIndex.start(request: request, includeExternalVolumes: true, policy: policy, retaining: lifetime) }
        #else
        indexed = nameIndex.start(request: request, includeExternalVolumes: true, policy: policy, retaining: lifetime)
        #endif
        nameSession = indexed
        for await event in indexed.events {
            guard !Task.isCancelled, revision == token, liveContext() == context, editor?.string == input,
                  indexed.generation.accepts(event) else { return false }
            switch event.payload {
            case .batch(let matches):
                for match in matches { ranking.consider(.init(name: match.entry.name, url: match.entry.url, source: .index)) }
                publishNames(ranking.suggestions, message: "Indexed folder names · locations not indexed may be missing")
            case .progress: break
            case .finished(let coverage):
                #if DEBUG
                nameIndexCoverageForVerification = coverage
                #endif
                let limited = coverage.completion != .completed ? " · limited results; keep typing" : ""
                publishNames(ranking.suggestions, message: "Folder names only · index coverage varies" + limited)
            }
        }
        return !suggestions.isEmpty
    }
    private func publishNames(_ values: [AddressSuggestion], message: String) {
        let selected = selectedIndex.flatMap { suggestions.indices.contains($0) ? suggestions[$0].id : nil }
        suggestions = values
        if explicitlySelected { selectedIndex = values.firstIndex { $0.id == selected } }
        else { selectedIndex = values.first?.match == .approximate ? nil : (values.isEmpty ? nil : 0) }
        self.message = message; render()
    }
    private func selectionChanged() {
        guard !applying, let editor else { return }
        if editor.hasMarkedText() || editor.selectedRange().length != 0 || editor.selectedRange().location != editor.string.utf16.count {
            hideAndCancel()
        } else if editor.string != resultInput { changed() }
        else { updateGhost() }
    }
    private var resultInput: String? { suggestions.first.map { _ in lastRenderedInput } ?? nil }
    private var lastRenderedInput = ""

    func handle(_ selector: Selector, editor: NSTextView) -> Bool {
        guard self.editor === editor, !editor.hasMarkedText(), liveContext() == context,
              editor.selectedRange() == NSRange(location: editor.string.utf16.count, length: 0) else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)), !suggestions.isEmpty || panel.isVisible {
            dismissedInput = editor.string; hideAndCancel(); return true
        }
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            guard !suggestions.isEmpty else { return false }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            selectedIndex = max(0, min(suggestions.count - 1, (selectedIndex ?? (delta > 0 ? -1 : suggestions.count)) + delta))
            explicitlySelected = true; render(); return true
        }
        if selector == #selector(NSResponder.insertTab(_:)), let selectedIndex, suggestions.indices.contains(selectedIndex) {
            accept(selectedIndex); return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)), explicitlySelected, let selectedIndex {
            accept(selectedIndex); browser?.locationEntered(nil); return true
        }
        return false
    }
    @objc private func clicked(_ sender: NSButton) { accept(sender.tag) }
    private func accept(_ index: Int) {
        guard suggestions.indices.contains(index), let editor, liveContext() == context, !editor.hasMarkedText() else { return }
        let text = suggestions[index].completedText
        applying = true
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        browser?.pathField.stringValue = text
        editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        applying = false; dismissedInput = nil
        changed()
    }
    func endedEditing() { cancel() }
    func resumeIfEditing() {
        #if DEBUG
        resumeInvocationsForVerification += 1
        #endif
        guard permitsLocalCompletion else { cancel(); return }
        guard let browser, !browser.pathField.isHidden,
              let current = browser.pathField.currentEditor() as? NSTextView else { return }
        if editor !== current { beganEditing(current) }
        else { changed() }
    }
    func cancel() {
        hideAndCancel(); editor = nil; context = nil; observers.removeAll(); dismissedInput = nil
        ghost.removeFromSuperview()
    }
    private func hideAndCancel() {
        #if DEBUG
        nameRequestForVerification = nil
        #endif
        revision = UUID(); task?.cancel(); task = nil; session?.cancel(); session = nil; nameSession?.cancel(); nameSession = nil
        releaseSavedNames()
        suggestions = []; selectedIndex = nil; explicitlySelected = false; result = nil
        hidePresentation()
    }
    private func releaseSavedNames() { savedUse = nil; savedOwner?.stopObserving(savedObserver); savedOwner = nil }
    private func hidePresentation() { panel.parent?.removeChildWindow(panel); panel.orderOut(nil); ghost.isHidden = true }
    func layout() {
        updateGhost()
        guard let field = browser?.pathField, let window = field.window, !rows.arrangedSubviews.isEmpty else { return }
        let anchor = window.convertToScreen(field.convert(field.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? anchor.insetBy(dx: -500, dy: -500)
        let width = min(600, max(260, anchor.width)), height = suggestions.reduce(CGFloat(38)) { $0 + ($1.source == .directoryLevel ? 30 : 48) }
        let x = min(max(anchor.minX, screen.minX + 4), screen.maxX - width - 4)
        let above = anchor.maxY + 5, below = anchor.minY - height - 5
        let prefersAbove = browser?.settings.showsPathBar == true
        let y = prefersAbove && above + height <= screen.maxY ? above
            : below >= screen.minY ? below : above
        panel.setFrame(NSRect(x: x, y: max(screen.minY + 4, y), width: width, height: height), display: false)
    }
    private func render() {
        guard let browser, liveContext() == context else { hidePresentation(); return }
        lastRenderedInput = editor?.string ?? ""
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }; buttons = []
        if browser.settings.addressPresentation.showsDropdown && (!suggestions.isEmpty || !message.isEmpty) {
            for (index, value) in suggestions.enumerated() {
                let contextual = value.source != .directoryLevel
                let button = AddressSuggestionButton(value: value, target: self, action: #selector(clicked(_:)))
                button.tag = index; button.bezelStyle = .recessed; button.isBordered = selectedIndex == index
                button.alignment = .left
                button.refusesFirstResponder = true
                button.setAccessibilityLabel(value.name + (value.match == .approximate ? ", similar spelling" : "") + (contextual ? ", " + value.url.path : "") + ", complete folder address")
                button.toolTip = value.url.path
                rows.addArrangedSubview(button); buttons.append(button)
                button.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -12).isActive = true
                button.heightAnchor.constraint(equalToConstant: contextual ? 46 : 28).interfaceScaled.isActive = true
            }
            let footer = label(message, size: 11, color: .secondaryLabelColor)
            footer.lineBreakMode = .byTruncatingTail
            rows.addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -12).isActive = true
            layout()
            panel.appearance = browser.view.effectiveAppearance
            if !browser.isControlledVerification, let window = browser.view.window, panel.parent !== window {
                window.addChildWindow(panel, ordered: .above)
                if browser.settings.motion.allows(.pages), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    panel.alphaValue = browser.settings.motion.mode.initialOpacity(0)
                    panel.orderFront(nil)
                    NSAnimationContext.runAnimationGroup { $0.duration = 0.10 * browser.settings.motion.mode.durationScale; panel.animator().alphaValue = 1 }
                } else { panel.alphaValue = 1; panel.orderFront(nil) }
            }
        } else { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        updateGhost()
        browser.pathField.setAccessibilityHelp(suggestions.isEmpty ? message : "\(suggestions.count) folder suggestions. Up and Down select; Tab completes; Return opens the address.")
    }
    private func updateGhost() {
        ghost.isHidden = true
        guard let browser, browser.settings.addressPresentation.showsInline,
              let editor, !editor.hasMarkedText(), editor.selectedRange() == NSRange(location: editor.string.utf16.count, length: 0),
              liveContext() == context, let selectedIndex, suggestions.indices.contains(selectedIndex),
              let suffix = suggestions[selectedIndex].ghostSuffix(after: editor.string), let window = editor.window else { return }
        let screenRect = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        let rect = editor.convert(window.convertFromScreen(screenRect), from: nil)
        let width = max(0, editor.visibleRect.maxX - rect.minX - 3)
        guard width > 3 else { return }
        ghost.frame = NSRect(x: rect.minX + 1, y: rect.minY, width: width, height: rect.height)
        ghost.text = suffix; ghost.font = editor.font ?? .systemFont(ofSize: 13)
        ghost.isHidden = false; ghost.needsDisplay = true
    }
    #if DEBUG
    var ghostTextForVerification: String? { ghost.isHidden ? nil : ghost.text }
    var panelForVerification: NSPanel { panel }
    var taskForVerification: Task<Void, Never>? { task }
    var geometryForVerification: String {
        guard let editor else { return "no editor" }
        return "selection=\(editor.selectedRange()); visible=\(editor.visibleRect); editor=\(editor.frame); ghost=\(ghost.frame); window=\(editor.window != nil); context=\(liveContext() == context); marked=\(editor.hasMarkedText())"
    }
    #endif
}

/// NSButton keeps native tracking/keyboard/AX behavior. Its contextual text is
/// drawn within fixed row bounds: NSButtonCell's bordered multiline title both
/// collapsed the selected subtitle and inflated the child window's minimum size.
@MainActor
private final class AddressSuggestionButton: NSButton {
    private let name: String
    private let detail: String?
    private let folder = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))
    init(value: AddressSuggestion, target: AnyObject, action: Selector) {
        name = value.name + (value.match == .approximate ? " · similar spelling" : "")
        if value.source == .directoryLevel { detail = nil }
        else {
            let source = value.source == .familiar ? "Mac folder" : value.source == .volume ? "Mounted drive" : value.source == .savedName ? "Saved folder name" : "Indexed folder"
            detail = source + " · " + value.url.path
        }
        super.init(frame: .zero)
        self.target = target; self.action = action
        title = detail == nil ? name : ""
        if detail == nil { image = symbol("folder", "Folder"); imagePosition = .imageLeading }
        cell?.lineBreakMode = .byTruncatingMiddle
        cell?.usesSingleLineMode = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: detail == nil ? 180 : 240, height: detail == nil ? 28 : 46) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let detail else { return }
        folder?.draw(in: NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16), from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingMiddle
        let width = max(0, bounds.width - 38)
        let titleY: CGFloat = isFlipped ? 6 : bounds.height - 22
        let detailY: CGFloat = isFlipped ? 25 : 6
        (name as NSString).draw(in: NSRect(x: 29, y: titleY, width: width, height: 16),
            withAttributes: [.font: InterfaceMetrics.font(12), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        (detail as NSString).draw(in: NSRect(x: 29, y: detailY, width: width, height: 14),
            withAttributes: [.font: InterfaceMetrics.font(10), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
    }
}

@MainActor
private final class AddressSuggestionPanel: NSPanel {
    init() { super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false) }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AddressGhostView: NSView {
    var text = ""
    var font = InterfaceMetrics.font(13)
    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byClipping
        (text as NSString).draw(in: bounds, withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
    }
}
