import AppKit
import ExplorerCore
import FileOperations
@_spi(Qualification) import LocalStorage

@MainActor
private final class InlineFilenameCell: NSTextFieldCell {
    var initialSelection: NSRange?
    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                         delegate: Any?, start: Int, length: Int) {
        let range = initialSelection; initialSelection = nil
        super.select(withFrame: rect, in: controlView, editor: editor, delegate: delegate,
                     start: range?.location ?? start, length: range?.length ?? length)
    }
}

@MainActor
private final class InlineFilenameField: NSTextField {
    override class var cellClass: AnyClass? {
        get { InlineFilenameCell.self }
        set { }
    }
}

/// Owns one text-editing lifetime, never filesystem mutation. The command keeps
/// its observed source and access lease while awaiting the user's answer.
@MainActor
final class BrowserInlineRenameController: NSObject, NSTextFieldDelegate {
    weak var browser: BrowserViewController?
    private(set) var field: NSTextField?
    private var request: Request?
    private var session: Session?
    private var observations: [BrowserNotificationObservation] = []
    private var interactionMonitor: Any?
    private var creation: CreatedFolder?
    private weak var hiddenLabel: NSTextField?
    private var previousLabelHidden = false
    var isEditing: Bool { session != nil }

    private enum Target: Equatable {
        case local(URL)
        case sftp(connection: UUID, generation: UUID, observation: UInt64)
        case smb(connection: UUID, read: UUID, revision: UInt64, observation: Int64)
    }
    private struct Session {
        let id: UUID
        let target: Target
        let originalName: String
        let tab: UUID
        let visit: UUID
        let presentation: UUID
        let continuation: CheckedContinuation<String?, Never>
        let validation: ((String) -> String?)?
    }

    private struct Request {
        let id: UUID
        let target: Target
        let tab: UUID
        let visit: UUID
        let presentation: UUID
        let requiresContentFocus: Bool
    }

    private struct CreatedFolder {
        enum Phase { case preparing, refreshPermitted, listing }
        let id: UUID, parent: URL, tab: UUID, presentation: UUID
        let selection: Set<URL>, filter: String
        var visit: UUID
        var destination: URL?
        var phase: Phase = .preparing
    }

    init(browser: BrowserViewController) { self.browser = browser }

    /// A presentation intent only. It carries no file identity or mutation
    /// authority and survives only the explicitly named successful refresh.
    func reserveCreatedFolder(in parent: URL) -> UUID? {
        cancel()
        guard let browser, hasContentFocus, browser.location.directoryURL == parent else { return nil }
        let id = UUID()
        creation = CreatedFolder(id: id, parent: parent, tab: browser.activeID,
            presentation: browser.filePresentationID, selection: browser.selectedURLs,
            filter: browser.tabs[browser.activeIndex].filter, visit: browser.sessionID)
        observeContext(requestID: id, guardingCreation: true)
        return id
    }

    func canAdmitCreatedFolder(_ id: UUID?) -> Bool {
        guard let id, let creation, creation.id == id, creation.phase == .preparing,
              creationIsCurrent(creation), let browser else { return false }
        return browser.selectedURLs == creation.selection
    }

    func creationPreparationFinished(_ id: UUID?) {
        guard let id, let creation, creation.id == id else { return }
        if creation.phase == .preparing && browser?.operationTask == nil { cancel() }
        else { consumeCreatedFolderIfReady() }
    }

    func creationOperationFinished(_ id: UUID?) {
        guard let id, let creation, creation.id == id else { return }
        if creation.phase != .listing { cancel() }
        else { consumeCreatedFolderIfReady() }
    }

    func prepareCreatedFolderRefresh(_ id: UUID?, result: FileOperationResult) -> UUID? {
        guard canAdmitCreatedFolder(id), result.disposition == .succeeded, !result.cancellationRequested,
              result.items.count == 1, result.items[0].status == .succeeded,
              let destination = result.items[0].destination, let parent = creation?.parent,
              destination.deletingLastPathComponent().path == parent.path else {
            if let id, creation?.id == id { cancel() }
            return nil
        }
        creation?.destination = destination
        creation?.phase = .refreshPermitted
        return id
    }

    func prepareForLocationChange(preservingCreatedFolder id: UUID?) {
        cancelEditing()
        guard let id, let creation, creation.id == id, creation.phase == .refreshPermitted,
              creationIsCurrent(creation) else { cancel(); return }
    }

    func createdFolderListingStarted(_ id: UUID?) {
        guard let id, creation?.id == id, creation?.phase == .refreshPermitted, let browser else { return }
        creation?.visit = browser.sessionID
        creation?.phase = .listing
    }

    func prepareForRender() {
        cancelEditing()
        if let creation, creation.phase != .listing || !creationIsCurrent(creation) { cancel() }
    }

    func orderingWillChange() {
        if let creation, !creationIsCurrent(creation) { cancel() }
    }

    func consumeCreatedFolderIfReady() {
        guard let creation, creation.phase == .listing, let browser,
              !browser.isLoading, browser.orderingTask == nil,
              browser.operationTask == nil, browser.operationPreparationTask == nil else { return }
        let destination = creation.destination
        let current = creationIsCurrent(creation)
        cancel()
        guard current, browser.loadError == nil, browser.issueCount == 0, let destination else { return }
        let matches = browser.displayedEntries.filter { $0.url.path == destination.path }
        guard matches.count == 1, let entry = matches.first, entry.kind == .directory,
              browser.selectedURLs.count == 1, browser.selectedURLs.first?.path == entry.url.path else {
            browser.status.stringValue = "Folder created. It is not available in this filtered view for renaming."
            return
        }
        // Result/listing DTOs expose no journal after-image identity. Do not
        // treat this URL as authority: ordinary Rename freshly observes/seals
        // its current source, then the engine revalidates it at mutation time.
        browser.revealFile(entry.url)
        browser.activeFileView.layoutSubtreeIfNeeded()
        browser.renameCreatedFolderSelection()
    }

    private var hasContentFocus: Bool {
        guard let browser, browser.hasFileCommandFocus, let window = browser.view.window,
              window.attachedSheet == nil, let responder = window.firstResponder as? NSView else { return false }
        return responder === browser.activeFileView || responder.isDescendant(of: browser.activeFileView)
    }

    private func creationIsCurrent(_ value: CreatedFolder) -> Bool {
        guard let browser else { return false }
        return !browser.isBrowserSuspended && browser.isActiveCommandPane && hasContentFocus
            && !browser.metadataSearch.isShowingResults && browser.location.directoryURL?.path == value.parent.path
            && browser.activeID == value.tab && browser.sessionID == value.visit
            && browser.filePresentationID == value.presentation && browser.tabs[browser.activeIndex].filter == value.filter
    }

    /// Reserve before off-main source observation. An away-and-back focus or
    /// selection change revokes the request even before an editor exists.
    func reserve(source: URL, requiresContentFocus: Bool = false) -> UUID {
        reserve(target: .local(source), requiresContentFocus: requiresContentFocus)
    }
    func reserveRemote(owner: SFTPTabController) -> UUID? {
        guard let snapshot = owner.sealedActionSnapshot, let row = owner.rows.selectedObservation else { return nil }
        return reserve(target: .sftp(connection: owner.connectionID, generation: snapshot.generation, observation: row.observation))
    }
    func reserveRemote(owner: SMBTabController) -> UUID? {
        guard let value = owner.sealedFileAction, value.row.id > 0 else { return nil }
        return reserve(target: .smb(connection: owner.connectionID, read: value.snapshot.readID,
            revision: value.snapshot.revision, observation: value.row.id))
    }
    private func reserve(target: Target, requiresContentFocus: Bool = false) -> UUID {
        cancel()
        let id = UUID()
        guard let browser else { return id }
        request = Request(id: id, target: target, tab: browser.activeID, visit: browser.sessionID,
                          presentation: browser.filePresentationID, requiresContentFocus: requiresContentFocus)
        observeContext(requestID: id, guardingCreation: requiresContentFocus)
        return id
    }

    private func observeContext(requestID id: UUID, guardingCreation: Bool = false) {
        guard let browser else { return }
        if let window = browser.view.window {
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didResizeNotification] {
                observe(name, object: window, requestID: id)
            }
        }
        observe(NSApplication.didResignActiveNotification, object: NSApplication.shared, requestID: id)
        // Ordinary Rename retains its original preflight/focus lifetime. Only
        // the automatic creation handoff needs stronger pending-edit guards.
        guard guardingCreation else { return }
        observe(NSMenu.didBeginTrackingNotification, object: nil, requestID: id)
        if let window = browser.view.window {
            observations.append(BrowserNotificationObservation(name: NSWindow.didUpdateNotification, object: window) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.session == nil, self.request?.id == id || self.creation?.id == id else { return }
                    if !self.hasContentFocus { self.cancel() }
                }
            })
        }
        observations.append(BrowserNotificationObservation(name: NSControl.textDidBeginEditingNotification) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.session == nil, self.request?.id == id || self.creation?.id == id else { return }
                self.cancel()
            }
        })
        interactionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.session == nil, self.request?.id == id || self.creation?.id == id else { return }
                self.cancel()
            }
            return event
        }
    }

    private func observe(_ name: Notification.Name, object: Any?, requestID: UUID) {
        observations.append(BrowserNotificationObservation(name: name, object: object) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.request?.id == requestID || self?.creation?.id == requestID else { return }
                self?.cancel()
            }
        })
    }

    func begin(source: URL, name: String, ordinaryFile: Bool, requestID: UUID) async -> String? {
        guard let request, request.id == requestID, request.target == .local(source),
              let browser, let anchor = browser.inlineFilenameAnchor(for: source), isCurrent(request) else { return nil }
        return await begin(requestID: requestID, name: name, ordinaryFile: ordinaryFile, anchor: anchor,
            clip: browser.activeFileScrollView.contentView)
    }
    func beginRemote(owner: SFTPTabController, name: String, ordinaryFile: Bool, requestID: UUID,
                     validating validation: @escaping (String) -> String?) async -> String? {
        guard let request, request.id == requestID, let browser, isCurrent(request),
              browser.sftpTabs[browser.activeID] === owner, let anchor = owner.rows.inlineFilenameAnchor() else { return nil }
        return await begin(requestID: requestID, name: name, ordinaryFile: ordinaryFile, anchor: anchor,
            clip: owner.rows.scroll.contentView, validation: validation)
    }
    func beginRemote(owner: SMBTabController, name: String, requestID: UUID,
                     validating validation: @escaping (String) -> String?) async -> String? {
        guard let request, request.id == requestID, let browser, isCurrent(request),
              browser.smbTabs[browser.activeID] === owner, let anchor = owner.rows.inlineFilenameAnchor() else { return nil }
        return await begin(requestID: requestID, name: name, ordinaryFile: owner.sealedFileAction?.row.isDirectory == false, anchor: anchor,
            clip: owner.rows.scroll.contentView, validation: validation)
    }
    private func begin(requestID: UUID, name: String, ordinaryFile: Bool,
                       anchor: (view: NSView, rect: NSRect, label: NSTextField), clip: NSClipView,
                       validation: ((String) -> String?)? = nil) async -> String? {
        guard let request, request.id == requestID, let browser, let window = browser.view.window,
              isCurrent(request) else { return nil }
        let id = requestID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, self.request?.id == id else { continuation.resume(returning: nil); return }
                let field = InlineFilenameField(string: name)
                field.delegate = self
                field.font = anchor.label.font ?? .systemFont(ofSize: 13)
                field.alignment = anchor.label.alignment
                field.focusRingType = .exterior
                field.isBezeled = true
                field.isBordered = true
                field.drawsBackground = true
                field.cell?.isScrollable = true
                field.setAccessibilityLabel(ordinaryFile ? "Rename filename, including editable extension" : "Rename folder")
                let range: NSRange
                if ordinaryFile, let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex {
                    range = NSRange(name.startIndex..<dot, in: name)
                } else { range = NSRange(location: 0, length: name.utf16.count) }
                (field.cell as? InlineFilenameCell)?.initialSelection = range
                var rect = anchor.rect
                let height = min(max(22, rect.height), 28)
                rect.origin.y = rect.midY - height / 2
                rect.size.height = height
                field.frame = rect
                self.field = field
                hiddenLabel = anchor.label
                previousLabelHidden = anchor.label.isHidden
                anchor.label.isHidden = true
                session = Session(id: id, target: request.target, originalName: name, tab: browser.activeID,
                                  visit: browser.sessionID, presentation: browser.filePresentationID, continuation: continuation, validation: validation)
                anchor.view.addSubview(field)
                observe(NSView.boundsDidChangeNotification, object: clip, requestID: id)
                guard window.makeFirstResponder(field) else { cancel(); return }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.session?.id == id else { return }
                self?.cancel()
            }
        }
    }

    func selectionDidChange() {
        if creation != nil { cancel(); return }
        guard let request, let browser else { return }
        if !targetIsCurrent(request.target, browser: browser) { cancel() }
    }

    func cancel() {
        creation = nil
        cancelEditing()
    }

    func cancelEditing() {
        request = nil
        if creation == nil { clearObservations() }
        finish(nil, restoreFocus: false)
    }

    private func clearObservations() {
        observations = []
        if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor); self.interactionMonitor = nil }
    }

    func cancel(requestID: UUID) {
        if request?.id == requestID { cancel() }
    }

    /// Consume once immediately before engine admission. Lifecycle events can
    /// revoke a confirmed answer while its continuation is still queued.
    func consume(requestID: UUID, source: URL) -> Bool {
        defer { cancel(requestID: requestID) }
        guard let request, let browser, request.id == requestID, request.target == .local(source) else { return false }
        return !browser.isBrowserSuspended && browser.isActiveCommandPane && !browser.metadataSearch.isShowingResults
            && browser.activeID == request.tab && browser.sessionID == request.visit
            && browser.filePresentationID == request.presentation && browser.selectedURLs == [source]
            && (!request.requiresContentFocus || hasContentFocus)
    }

    func consumeRemote(requestID: UUID) -> Bool {
        defer { cancel(requestID: requestID) }
        guard let request, request.id == requestID else { return false }
        if case .local = request.target { return false }
        return isCurrent(request)
    }
    private func targetIsCurrent(_ target: Target, browser: BrowserViewController) -> Bool {
        switch target {
        case .local(let source): return !browser.metadataSearch.isShowingResults && browser.selectedURLs == [source]
        case .sftp(let connection, let generation, let observation):
            guard let owner = browser.sftpTabs[browser.activeID], !owner.isClosing, owner.connectionID == connection,
                  owner.sealedActionSnapshot?.generation == generation else { return false }
            return owner.rows.selectedObservation?.observation == observation
        case .smb(let connection, let read, let revision, let observation):
            guard let owner = browser.smbTabs[browser.activeID], owner.connectionID == connection,
                  let value = owner.sealedFileAction, value.snapshot.readID == read,
                  value.snapshot.revision == revision else { return false }
            return value.row.id == observation
        }
    }
    private func isCurrent(_ request: Request) -> Bool {
        guard let browser else { return false }
        return !browser.isBrowserSuspended && browser.isActiveCommandPane
            && (!request.requiresContentFocus || hasContentFocus)
            && browser.activeID == request.tab && browser.sessionID == request.visit
            && browser.filePresentationID == request.presentation && targetIsCurrent(request.target, browser: browser)
    }
    private func isCurrent(_ session: Session) -> Bool {
        guard let browser else { return false }
        return !browser.isBrowserSuspended && browser.isActiveCommandPane
            && browser.activeID == session.tab && browser.sessionID == session.visit
            && browser.filePresentationID == session.presentation && targetIsCurrent(session.target, browser: browser)
    }

    private func finish(_ name: String?, restoreFocus: Bool) {
        guard let session else { return }
        let spellingChanged = name.map { Data($0.utf8) != Data(session.originalName.utf8) } ?? false
        let accepted = request?.id == session.id && isCurrent(session) && spellingChanged ? name : nil
        if accepted == nil { request = nil; clearObservations() }
        self.session = nil
        hiddenLabel?.isHidden = previousLabelHidden
        hiddenLabel = nil
        if let field {
            field.delegate = nil
            if let editor = field.currentEditor(), field.window?.firstResponder === editor {
                field.window?.makeFirstResponder(restoreFocus ? browser?.activeFileView : nil)
            }
            field.removeFromSuperview()
        }
        field = nil
        session.continuation.resume(returning: accepted)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch NSStringFromSelector(commandSelector) {
        case "insertNewline:":
            if let message = session?.validation?(textView.string) {
                field?.textColor = .systemRed; field?.toolTip = message
                browser?.status.stringValue = message; NSSound.beep(); return true
            }
            finish(textView.string, restoreFocus: true); return true
        case "cancelOperation:": finish(nil, restoreFocus: true); return true
        default: return false
        }
    }

    func controlTextDidChange(_ notification: Notification) { field?.textColor = .labelColor; field?.toolTip = nil }
    func controlTextDidEndEditing(_ notification: Notification) { cancel() }
}

@MainActor
extension BrowserViewController {
    /// Resolves the actual filename label after preflight. The table icon and
    /// metadata columns never become editable; icon tiles use their own label.
    func inlineFilenameAnchor(for source: URL) -> (view: NSView, rect: NSRect, label: NSTextField)? {
        guard !showsComputerVolumes, let row = rowsByURL[source], displayedEntries.indices.contains(row) else { return nil }
        if usesFileIcons {
            guard let anchor = iconBrowser.inlineFilenameAnchor(for: source) else { return nil }
            return (iconBrowser.collectionView, anchor.rect, anchor.label)
        }
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == BrowserColumn.name.rawValue }) else { return nil }
        table.scrollRowToVisible(row)
        table.layoutSubtreeIfNeeded()
        guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
              let label = cell.textField else { return nil }
        let rect = table.convert(label.bounds, from: label).intersection(table.visibleRect)
        return rect.width >= 24 && !rect.isEmpty ? (table, rect, label) : nil
    }
}
