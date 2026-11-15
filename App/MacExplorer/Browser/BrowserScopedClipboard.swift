import AppKit
@_spi(Qualification) import LocalStorage

/// Private app intent only. The pasteboard contains an opaque identifier, never
/// an item path, credential, local file URL or transferable session handle.
@MainActor final class ScopedItemClipboardIntent {
    enum Source { case sftp(SFTPClipboardSource), smb(SMBClipboardSource), zip(ZIPClipboardSource), tar(TARClipboardSource) }
    nonisolated static let pasteboardType = NSPasteboard.PasteboardType("com.respawnstudios.traverse.remote-cut")
    let id = UUID()
    let source: Source
    let operation: TransferClipboardFeedback.Intent
    private(set) weak var sftpOwner: SFTPTabController?
    private(set) weak var smbOwner: SMBTabController?
    private(set) weak var archiveOwner: ArchiveTabController?

    init(owner: SFTPTabController, source: SFTPClipboardSource, operation: TransferClipboardFeedback.Intent = .move) {
        sftpOwner = owner; self.source = .sftp(source); self.operation = operation
    }
    init(owner: SMBTabController, source: SMBClipboardSource, operation: TransferClipboardFeedback.Intent = .move) {
        smbOwner = owner; self.source = .smb(source); self.operation = operation
    }
    init(owner: ArchiveTabController, source: ZIPClipboardSource, operation: TransferClipboardFeedback.Intent) {
        archiveOwner = owner; self.source = .zip(source); self.operation = operation
    }
    init(owner: ArchiveTabController, source: TARClipboardSource, operation: TransferClipboardFeedback.Intent) {
        archiveOwner = owner; self.source = .tar(source); self.operation = operation
    }

    var isAlive: Bool {
        switch source {
        case .sftp(let cut):
            return sftpOwner.map { !$0.isClosing && $0.connectionID == cut.connectionID && $0.session.latest.failure == nil } == true
        case .smb(let cut):
            return smbOwner.map { !$0.isClosing && $0.connectionID == cut.connectionID && $0.session.latest.failure == nil } == true
        case .zip(let source): return archiveOwner?.retainsClipboard(source) == true
        case .tar(let source): return archiveOwner?.retainsClipboard(source) == true
        }
    }
    var display: TransferClipboardFeedback.ScopedItems {
        switch source {
        case .sftp(let cut): .server(cut.row.entry.name.displayName,
            (cut.directory.root == .home ? "~" : "") + "/" + cut.directory.components.map(\.displayName).joined(separator: "/"))
        case .smb(let cut): .server(cut.row.name.displayName, "/" + cut.directory.map(\.displayName).joined(separator: "/"))
        case .zip(let cut): .archive("ZIP", cut.archiveURL.lastPathComponent, cut.archivePaths)
        case .tar(let copied): .archive("TAR", copied.archiveURL.lastPathComponent, copied.paths)
        }
    }
    func matchesCurrentSelection(in browser: BrowserViewController) -> Bool {
        switch source {
        case .sftp(let cut):
            guard browser.sftpTabs[browser.activeID] === sftpOwner,
                  let now = sftpOwner?.captureClipboardSource(operation) else { return false }
            return now.connectionID == cut.connectionID && now.directory == cut.directory && now.row == cut.row
        case .smb(let cut):
            guard browser.smbTabs[browser.activeID] === smbOwner,
                  let now = smbOwner?.captureClipboardSource(operation) else { return false }
            return now.connectionID == cut.connectionID && now.directory == cut.directory && now.row == cut.row
        case .zip(let source):
            return browser.currentArchive === archiveOwner && archiveOwner?.matchesClipboardSelection(source) == true
        case .tar(let source):
            return browser.currentArchive === archiveOwner && archiveOwner?.matchesClipboardSelection(source) == true
        }
    }

    /// The action owner reobserves the sealed source and destination before
    /// constructing the real request. A server item never leaves its session here.
    func canPaste(in browser: BrowserViewController) -> Bool {
        guard isAlive, !browser.isBrowserSuspended,
              browser.hasFileCommandFocus, browser.canRunExclusiveFileCommand,
              !(browser.view.window?.firstResponder is NSTextView),
              browser.view.window?.attachedSheet == nil else { return false }
        switch source {
        case .sftp(let cut):
            guard RemoteClipboardFeature.available, case .sftp(let location) = browser.location,
                  let owner = browser.sftpTabs[browser.activeID], owner === sftpOwner,
                  owner.sealedActionSnapshot != nil, let destination = owner.navigationDirectory(location),
                  ApplicationRemoteTextEditors.shared.canBeginDirectoryMutation else { return false }
            if operation == .copy {
                return RemoteClipboardFeature.sftpCopyAvailable && owner.allowsServerCopy
                    && cut.row.entry.isDirectory == false
            }
            guard RemoteClipboardFeature.movesAvailable, destination.root == .server,
                  destination != cut.directory else { return false }
            let folder = cut.row.entry.permissions.map { $0 & 0o170000 == 0o040000 } == true
            guard folder ? owner.allowsDirectoryMove : owner.allowsFileMove else { return false }
            return !folder || !destination.components.starts(with: cut.directory.components + [cut.row.entry.name])
        case .smb(let cut):
            guard RemoteClipboardFeature.available, case .smb = browser.location,
                  let owner = browser.smbTabs[browser.activeID], owner === smbOwner,
                  let destination = owner.clipboardDestination else { return false }
            if operation == .copy { return SMBRemoteActionFeature.copiesAvailable && !cut.row.isDirectory }
            guard RemoteClipboardFeature.movesAvailable, destination.components != cut.directory,
                  SMBRemoteActionFeature.movesAvailable else { return false }
            return !cut.row.isDirectory || !destination.components.starts(with: cut.directory + [cut.row.name])
        case .zip(let source):
            if browser.currentArchive === archiveOwner {
                return archiveOwner?.canPasteMembers(source, operation: operation) == true
            }
            return operation == .copy && browser.canPasteArchiveIntoLocalFolder
                && archiveOwner?.canExportClipboard(source) == true
        case .tar(let source):
            if browser.currentArchive === archiveOwner {
                return archiveOwner?.canPasteMembers(source, operation: operation) == true
            }
            return operation == .copy && browser.canPasteArchiveIntoLocalFolder
                && archiveOwner?.canExportClipboard(source) == true
        }
    }

    var pasteExplanation: String {
        switch source {
        case .zip: operation == .move ? "Paste the cut items in another folder in this ZIP tab."
            : "Paste the copied items in this ZIP or an available local folder."
        case .tar: operation == .move ? "Paste the cut items in another folder in this TAR tab."
            : "Paste the copied items in this TAR or an available local folder."
        case .sftp, .smb: "Paste this item in a folder in its original server tab."
        }
    }
}

@MainActor enum RemoteClipboardFeature {
    // Both protocols passed native Cut/navigation/Paste and independent server
    // inventory. The shared product policy keeps this flow in both packages.
    #if DEBUG
    static var qualifying = false
    #endif
    static var movesAvailable: Bool {
        #if DEBUG
        if qualifying { return true }
        #endif
        return AppFeatureAvailability.allows(.serverCut)
    }
    static var available: Bool {
        movesAvailable || SMBRemoteActionFeature.copiesAvailable || sftpCopyAvailable
    }
    static var sftpCopyAvailable: Bool {
        #if DEBUG
        if qualifying { return SFTPRemoteActionFeature.copiesAvailable }
        #endif
        // The signed Copy backend and native clipboard journey qualify these
        // two layers together. Clipboard generations, fresh source observations
        // and exact-session action admission remain mandatory at their owners.
        return SFTPRemoteActionFeature.copiesAvailable
    }
}

/// A Paste captures one clipboard generation. The exact native board is checked
/// before the final in-memory fence; later completions cannot clear a newer Cut.
@MainActor final class ScopedItemPaste {
    let intent: ScopedItemClipboardIntent
    private weak var state: BrowserClipboardState?
    private let board: NSPasteboard
    private let changeCount: Int, revision: UUID
    init?(state: BrowserClipboardState) {
        state.synchronize()
        guard let intent = state.scopedItem, let count = state.scopedItemChangeCount,
              intent.isAlive, state.pasteboard.changeCount == count else { return nil }
        self.intent = intent; self.state = state; board = state.pasteboard
        changeCount = count; revision = state.revision
    }
    func isCurrent() -> Bool {
        matchesReceipt() && intent.isAlive
    }
    private func matchesReceipt() -> Bool {
        let observed = board.changeCount
        let marker = board.string(forType: ScopedItemClipboardIntent.pasteboardType)
        let afterRead = board.changeCount
        return observed == changeCount && afterRead == changeCount && marker == intent.id.uuidString
            && state?.pasteboard === board && state?.revision == revision
            && state?.scopedItem === intent && state?.scopedItemChangeCount == changeCount
    }
    func finish(confirmed: Bool, canRetain: Bool = false) {
        guard matchesReceipt(), let state else { return }
        if confirmed {
            // Any archive rewrite retires the sealed catalog that supplied
            // these item IDs. Copy can be repeated only from the new catalog.
            if intent.operation == .move || intent.archiveOwner != nil { state.clear() }
        } else if !canRetain { state.clear() }
    }
}

@MainActor extension BrowserViewController {
    var canPasteArchiveIntoLocalFolder: Bool {
        !GeneratedSandboxReview.publicationOnlyReviewAdmitted
            && ArchiveMemberDragActivation.available
            && ArchiveExtractionActivation.wholeArchiveAvailable && canStartArchiveExtraction && canModifyCurrentFolder
            && !ApplicationFileActivity.gate.isClosed && ApplicationArchiveExtraction.shared.canAcceptPreparedSelection
    }

    func configureRemoteClipboard(on owner: SFTPTabController) {
        guard RemoteClipboardFeature.available, owner.allowsFileMove || owner.allowsDirectoryMove || owner.allowsServerCopy else { return }
        let rows = owner.rows
        rows.onCut = { [weak self, weak owner] in
            guard let self, let owner, sftpTabs[activeID] === owner else { return }; cutRemoteSelection()
        }
        rows.onCopyFile = { [weak self, weak owner] in
            guard let self, let owner, sftpTabs[activeID] === owner else { return }; copyRemoteSelection()
        }
        rows.copyFileAllowed = { [weak self, weak owner] in
            guard let self, let owner, sftpTabs[activeID] === owner else { return false }; return canCopyRemoteSelection
        }
        rows.cutAllowed = { [weak self, weak owner] in
            guard let self, let owner, sftpTabs[activeID] === owner else { return false }; return canCutRemoteSelection
        }
        rows.cutAppearanceForEntry = { [weak self, weak owner] entry in
            guard let self, let owner, let intent = clipboardState.scopedItem, intent.operation == .move, intent.sftpOwner === owner,
                  case .sftp(let source) = intent.source, case .sftp(let location) = owner.currentBrowserLocation,
                  owner.navigationDirectory(location) == source.directory else { return false }
            return intent.isAlive && source.row.entry == entry
        }
        rows.onPaste = { [weak self, weak owner] in
            guard let self, let owner, sftpTabs[activeID] === owner else { return }; pasteFileURLs(nil)
        }
        rows.pasteAllowed = { [weak self, weak owner] in
            guard let self, let owner, sftpTabs[activeID] === owner else { return false }
            return hasScopedItemPasteboardType ? canPasteScopedItem : sftpDropUpload.canPasteClipboard(to: owner)
        }
        rows.table.onCopy = rows.onCopyFile; rows.table.copyAllowed = rows.copyFileAllowed
        rows.table.onCut = rows.onCut; rows.table.cutAllowed = rows.cutAllowed
        rows.table.onPaste = rows.onPaste; rows.table.pasteAllowed = rows.pasteAllowed
    }
    func configureRemoteClipboard(on owner: SMBTabController) {
        guard RemoteClipboardFeature.available, owner.remoteActions != nil else { return }
        let rows = owner.rows
        rows.onCut = { [weak self, weak owner] in
            guard let self, let owner, smbTabs[activeID] === owner else { return }; cutRemoteSelection()
        }
        rows.onCopyFile = { [weak self, weak owner] in
            guard let self, let owner, smbTabs[activeID] === owner else { return }; copyRemoteSelection()
        }
        rows.copyFileAllowed = { [weak self, weak owner] in
            guard let self, let owner, smbTabs[activeID] === owner else { return false }; return canCopyRemoteSelection
        }
        rows.cutAllowed = { [weak self, weak owner] in
            guard let self, let owner, smbTabs[activeID] === owner else { return false }; return canCutRemoteSelection
        }
        rows.cutAppearanceForEntry = { [weak self, weak owner] entry in
            guard let self, let owner, let intent = clipboardState.scopedItem, intent.operation == .move, intent.smbOwner === owner,
                  case .smb(let source) = intent.source, case .smb(let location) = owner.currentBrowserLocation,
                  owner.navigationComponents(location) == source.directory else { return false }
            return intent.isAlive && source.matches(entry)
        }
        rows.onPaste = { [weak self, weak owner] in
            guard let self, let owner, smbTabs[activeID] === owner else { return }; pasteFileURLs(nil)
        }
        rows.pasteAllowed = { [weak self, weak owner] in
            guard let self, let owner, smbTabs[activeID] === owner else { return false }
            return hasScopedItemPasteboardType ? canPasteScopedItem : smbUpload.canPasteClipboard(to: owner)
        }
        rows.table.onCopy = rows.onCopyFile; rows.table.copyAllowed = rows.copyFileAllowed
        rows.table.onCut = rows.onCut; rows.table.cutAllowed = rows.cutAllowed
        rows.table.onPaste = rows.onPaste; rows.table.pasteAllowed = rows.pasteAllowed
    }
    func clearRemoteClipboard(for owner: SFTPTabController) {
        if clipboardState.scopedItem?.sftpOwner === owner { clipboardState.clear() }
    }
    func clearRemoteClipboard(for owner: SMBTabController) {
        if clipboardState.scopedItem?.smbOwner === owner { clipboardState.clear() }
    }
    func renderScopedClipboardAppearance() {
        let current = clipboardState.scopedItem?.id
        guard presentedScopedItemID != current else { return }; presentedScopedItemID = current
        guard let table = (currentArchive?.table as NSTableView?) ?? remoteTable else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
            columnIndexes: IndexSet(integer: 0))
    }
    var hasScopedItemPasteboardType: Bool {
        transferPasteboard.availableType(from: [ScopedItemClipboardIntent.pasteboardType]) != nil
    }
    var canCutRemoteSelection: Bool {
        guard RemoteClipboardFeature.movesAvailable, !(view.window?.firstResponder is NSTextView) else { return false }
        if let owner = sftpTabs[activeID], isSFTPLocation { return owner.captureClipboardSource(.move) != nil }
        if let owner = smbTabs[activeID], isSMBLocation { return owner.captureClipboardSource(.move) != nil }
        return false
    }
    var canCopyRemoteSelection: Bool {
        guard RemoteClipboardFeature.available, !(view.window?.firstResponder is NSTextView) else { return false }
        if let owner = sftpTabs[activeID], isSFTPLocation { return owner.captureClipboardSource(.copy) != nil }
        if let owner = smbTabs[activeID], isSMBLocation { return owner.captureClipboardSource(.copy) != nil }
        return false
    }
    func cutRemoteSelection() { publishRemoteClipboard(.move) }
    func copyRemoteSelection() { publishRemoteClipboard(.copy) }
    private func publishRemoteClipboard(_ operation: TransferClipboardFeedback.Intent) {
        guard operation == .move ? canCutRemoteSelection : canCopyRemoteSelection else {
            let diagnostic = ApplicationDiagnostics.shared.workflow(.browse, context: .init(.clipboardPublish))
            diagnostic.event(.blocked, context: .init(.clipboardPublish, flags: [.selectionUnavailable]), count: 0)
            return
        }
        let intent: ScopedItemClipboardIntent
        if isSFTPLocation, let owner = sftpTabs[activeID], let source = owner.captureClipboardSource(operation) {
            intent = .init(owner: owner, source: source, operation: operation)
        } else if isSMBLocation, let owner = smbTabs[activeID], let source = owner.captureClipboardSource(operation) {
            intent = .init(owner: owner, source: source, operation: operation)
        } else { return }
        publishScopedClipboard(intent)
    }
    func publishScopedClipboard(_ intent: ScopedItemClipboardIntent) {
        let diagnostic = ApplicationDiagnostics.shared.workflow(.browse, context: .init(.clipboardPublish))
        clearCutSelection()
        let state = clipboardState, revision = state.revision, board = transferPasteboard
        let tab = activeID, visit = sessionID
        let item = NSPasteboardItem()
        guard item.setString(intent.id.uuidString, forType: ScopedItemClipboardIntent.pasteboardType) else { return }
        let count = board.clearContents()
        guard board.changeCount == count, board.writeObjects([item]), board.changeCount == count,
              board.string(forType: ScopedItemClipboardIntent.pasteboardType) == intent.id.uuidString,
              clipboardState === state, state.revision == revision, transferPasteboard === board,
              activeID == tab, sessionID == visit, intent.isAlive,
              intent.matchesCurrentSelection(in: self) else { return }
        state.feedback = TransferClipboardFeedback(intent: intent.operation, urls: [], changeCount: count, scopedItem: intent.display)
        state.scopedItem = intent; state.scopedItemChangeCount = count
        state.beginObservation(); renderTransferFeedback()
        diagnostic.event(.completed, context: .init(.clipboardPublish), count: 1)
    }
    var canPasteScopedItem: Bool {
        guard let context = ScopedItemPaste(state: clipboardState) else { return false }
        return context.isCurrent() && context.intent.canPaste(in: self)
    }
    /// A scoped marker never falls through to local URL Paste or an upload.
    @discardableResult func pasteScopedItem() -> Bool {
        guard hasScopedItemPasteboardType else { return false }
        guard let context = ScopedItemPaste(state: clipboardState), context.isCurrent() else {
            status.stringValue = "This Cut or Copy has expired. Select the items again."
            return true
        }
        guard context.intent.canPaste(in: self) else {
            status.stringValue = context.intent.pasteExplanation
            return true
        }
        switch context.intent.source {
        case .sftp:
            if let owner = context.intent.sftpOwner { sftpFileActions.requestClipboardPaste(context, from: owner) }
        case .smb:
            if let owner = context.intent.smbOwner { smbFileActions.requestClipboardPaste(context, from: owner) }
        case .zip(let source):
            if let owner = context.intent.archiveOwner {
                if currentArchive === owner { owner.pasteMembers(source, context: context) }
                else { owner.exportClipboard(source, context: context, to: self) }
            }
        case .tar(let source):
            if let owner = context.intent.archiveOwner {
                if currentArchive === owner { owner.pasteMembers(source, context: context) }
                else { owner.exportClipboard(source, context: context, to: self) }
            }
        }
        return true
    }
}
