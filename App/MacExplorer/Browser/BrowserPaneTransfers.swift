import AppKit
import ExplorerCore
import FileOperations
@_spi(Qualification) import LocalStorage

enum PaneTransferFeature {
    static let enabled = true
    static var available: Bool {
        #if DEBUG
            enabled || ProcessInfo.processInfo.arguments.contains("--check-pane-transfers")
        #else
            enabled
        #endif
    }
}

@MainActor extension BrowserViewController {
    var canTransferToOtherPane: Bool { paneTransfers.canRequest }
    var canCopyToOtherPane: Bool {
        guard !isBrowserSuspended, view.window != nil, view.window?.attachedSheet == nil,
              !(view.window?.firstResponder is NSTextView), canRunExclusiveFileCommand else { return false }
        if isSFTPLocation {
            guard let owner = sftpTabs[activeID], owner.rows.onDownloadToPane != nil else { return false }
            return owner.rows.paneDownloadAllowed?() == true
        }
        if isSMBLocation {
            guard let owner = smbTabs[activeID], owner.rows.onDownloadToPane != nil else { return false }
            return owner.rows.paneDownloadAllowed?() == true
        }
        return paneTransfers.canRequest || sftpPaneUpload.canRequest || paneTransfers.canUploadFilesToSMBPane
    }
    @objc func copyToOtherPane(_ sender: Any?) {
        guard canCopyToOtherPane else { return }
        if isSFTPLocation { sftpTabs[activeID]?.rows.onDownloadToPane?() }
        else if isSMBLocation { smbTabs[activeID]?.rows.onDownloadToPane?() }
        else { paneTransfers.requestCopy() }
    }
    @objc func moveToOtherPane(_ sender: Any?) { paneTransfers.request(move: true) }
}

/// Native intent capture only. The shared queue owns access, fresh observations,
/// planning, conflicts and all mutations; the clipboard is never involved.
@MainActor final class BrowserPaneTransfers: NSObject {
    private weak var browser: BrowserViewController?
    private var menu: NSMenu?
    private var chosen: UUID?
    #if DEBUG
        var presentForVerification: ((NSMenu) -> Void)?
    #endif

    private typealias Peer = LocalPaneDestination
    private struct SMBPeer {
        let pane: UUID, tab: UUID, visit: UUID, connection: UUID
        let snapshot: SMBDirectorySnapshot, components: [SMBRemoteName], title: String
        let browser: BrowserViewController, owner: SMBTabController
    }
    private struct Intent {
        let tab: UUID
        let visit: UUID
        let directory: URL
        let sources: [URL]
        let peers: [Peer]
        let move: Bool
        let engine: RecoverableFileOperations
        let metadata: TransferMetadataPolicy
        let execution: CopyExecutionRequest
    }

    init(browser: BrowserViewController) { self.browser = browser }

    var canRequest: Bool { !eligiblePeers().isEmpty }
    func copyDestination(in pane: UUID) -> LocalPaneDestination? { eligiblePeers().first { $0.pane == pane } }

    private func eligiblePeers() -> [Peer] {
        guard PaneTransferFeature.available, menu == nil, let browser,
            browser.canAdmitTransfer, browser.recoverableFileOperations != nil,
            (1...1_024).contains(browser.selectedItemCount),
            !(browser.view.window?.firstResponder is NSTextView),
            let workspace = browser.workspace, !workspace.isClosing,
            workspace.browsers[browser.paneID] === browser
        else { return [] }
        return peers(in: workspace, from: browser)
    }

    var canUploadFilesToSMBPane: Bool {
        guard menu == nil, let browser, let source = selectedSMBSource(browser) else { return false }
        return smbPeers(browser).contains { !source.hasFolders || $0.browser.smbUpload.acceptsFolders(from: $0.owner) }
    }

    private func selectedSMBSource(_ browser: BrowserViewController) -> LocalPaneUploadSelection? {
        guard SMBUploadFeature.paneCopyAvailable, PaneTransferFeature.available, browser.hasFileCommandFocus,
              !(browser.view.window?.firstResponder is NSTextView), browser.canAdmitTransfer,
              browser.canRunExclusiveFileCommand, let source = LocalPaneUploadSelection(browser: browser),
              source.isCurrent, source.urls.count <= SMBUploadFeature.selectionLimit else { return nil }
        return source
    }

    private func smbPeers(_ browser: BrowserViewController) -> [SMBPeer] {
        guard let workspace = browser.workspace, !workspace.isClosing,
              workspace.browsers[browser.paneID] === browser else { return [] }
        return workspace.layout.paneIDs.enumerated().compactMap { index, id in
            guard id != browser.paneID, let peer = workspace.browsers[id],
                  let owner = peer.smbTabs[peer.activeID], peer.smbUpload.canRequest(from: owner),
                  let destination = owner.uploadDestination else { return nil }
            return .init(pane: id, tab: peer.activeID, visit: peer.sessionID, connection: owner.connectionID,
                snapshot: destination.snapshot, components: destination.components,
                title: "Pane \(index + 1) — \(peer.location.displayName)", browser: peer, owner: owner)
        }
    }

    private func admitSMB(_ source: LocalPaneUploadSelection, to peer: SMBPeer) {
        guard SMBUploadFeature.paneCopyAvailable, source.isCurrent, let browser, browser.workspace === peer.browser.workspace,
              browser.workspace?.browsers[peer.pane] === peer.browser,
              peer.browser.activeID == peer.tab, peer.browser.sessionID == peer.visit,
              peer.browser.smbTabs[peer.tab] === peer.owner, peer.owner.connectionID == peer.connection,
              let current = peer.owner.uploadDestination, current.snapshot == peer.snapshot,
              current.components == peer.components, peer.browser.smbUpload.canRequest(from: peer.owner) else {
            browser?.status.stringValue = "The selection or SMB destination changed. Choose Copy to Other Pane again."
            return
        }
        guard !source.hasFolders || peer.browser.smbUpload.acceptsFolders(from: peer.owner) else { return }
        peer.browser.smbUpload.request(from: peer.owner, selectedGroup: source)
    }

    /// One native choice across local, SFTP and selected-file SMB destinations.
    /// Each existing owner still admits, revalidates and performs its operation.
    func requestCopy() {
        guard menu == nil, let browser else { return }
        let remote = browser.sftpPaneUpload.destinations
        let smbSource = selectedSMBSource(browser)
        let smb = smbSource.map { source in smbPeers(browser).filter { !source.hasFolders || $0.browser.smbUpload.acceptsFolders(from: $0.owner) } } ?? []
        if remote.isEmpty && smb.isEmpty { request(move: false); return }
        let local = canRequest ? LocalPaneDestination.available(from: browser, excluding: browser.location.directoryURL) : []
        if local.isEmpty && smb.isEmpty { browser.sftpPaneUpload.request(); return }
        if local.isEmpty && remote.isEmpty && smb.count == 1, let source = smbSource {
            admitSMB(source, to: smb[0]); return
        }
        guard let engine = browser.recoverableFileOperations, let directory = browser.location.directoryURL,
              let workspace = browser.workspace else { return }
        let intent = Intent(tab: browser.activeID, visit: browser.sessionID, directory: directory,
            sources: browser.orderedSelectedURLs(upTo: 1_025), peers: local, move: false, engine: engine,
            metadata: browser.settings.transferMetadata.policy, execution: browser.settings.copyExecutionRequest)
        let offered = NSMenu(title: "Copy to Pane"); offered.autoenablesItems = false
        for peer in local {
            let item = offered.addItem(withTitle: "Copy to " + peer.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = peer.pane
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            item.toolTip = peer.directory.path
        }
        for peer in remote {
            let item = offered.addItem(withTitle: "Upload to " + peer.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = peer.pane
            item.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
            item.toolTip = "Upload to this SFTP folder. Existing items are kept."
        }
        for peer in smb {
            let item = offered.addItem(withTitle: "Upload to " + peer.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = peer.pane
            item.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
            item.toolTip = "Upload the selection to this SMB folder. Existing names are kept."
        }
        menu = offered; chosen = nil
        #if DEBUG
        if let presentForVerification { presentForVerification(offered) }
        else { present(offered, browser: browser) }
        #else
        present(offered, browser: browser)
        #endif
        let selected = chosen; menu = nil; chosen = nil
        guard selected != nil else { return }
        guard browser.workspace === workspace, !workspace.isClosing, browser.activeID == intent.tab,
              browser.sessionID == intent.visit, browser.location.directoryURL == directory,
              browser.orderedSelectedURLs(upTo: 1_025) == intent.sources,
              browser.recoverableFileOperations === engine else {
            browser.status.stringValue = "The selection or destination changed. Choose Copy to Other Pane again."; return
        }
        if let peer = local.first(where: { $0.pane == selected }) { admit(intent, to: peer) }
        else if let peer = remote.first(where: { $0.pane == selected }) { browser.sftpPaneUpload.request(to: peer) }
        else if let peer = smb.first(where: { $0.pane == selected }), let source = smbSource { admitSMB(source, to: peer) }
    }

    @discardableResult
    func request(move: Bool, to pane: UUID? = nil) -> Bool {
        let options = eligiblePeers()
        guard !options.isEmpty, let browser,
            let engine = browser.recoverableFileOperations,
            let directory = browser.location.directoryURL
        else { return false }
        let sources = browser.orderedSelectedURLs(upTo: 1_025)
        guard (1...1_024).contains(sources.count), Set(sources).count == sources.count,
            sources.allSatisfy({ $0.isFileURL && BrowserLocation.directory($0.deletingLastPathComponent()) == .directory(directory) })
        else { return false }
        let intent = Intent(tab: browser.activeID, visit: browser.sessionID, directory: directory,
            sources: sources, peers: pane.map { id in options.filter { $0.pane == id } } ?? options, move: move, engine: engine,
            metadata: browser.settings.transferMetadata.policy,
            execution: move ? .standard : browser.settings.copyExecutionRequest)
        guard let first = intent.peers.first else { return false }
        if intent.peers.count == 1 { return admit(intent, to: first) }

        let offered = NSMenu(title: move ? "Move to Pane" : "Copy to Pane")
        offered.autoenablesItems = false
        for peer in intent.peers {
            let item = offered.addItem(withTitle: peer.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = peer.pane
            item.toolTip = peer.directory.path
        }
        menu = offered
        chosen = nil
        #if DEBUG
            if let presentForVerification { presentForVerification(offered) }
            else { present(offered, browser: browser) }
        #else
            present(offered, browser: browser)
        #endif
        let selected = chosen
        menu = nil
        chosen = nil
        guard let peer = intent.peers.first(where: { $0.pane == selected }) else { return false }
        return admit(intent, to: peer)
    }

    private func peers(in workspace: BrowserWorkspaceController, from source: BrowserViewController) -> [Peer] {
        guard source.workspace === workspace, let current = source.location.directoryURL else { return [] }
        return LocalPaneDestination.available(from: source, excluding: current)
    }

    @discardableResult
    private func admit(_ intent: Intent, to peer: Peer) -> Bool {
        guard canRequest, let browser, let workspace = browser.workspace,
            browser.activeID == intent.tab, browser.sessionID == intent.visit,
            browser.location.directoryURL == intent.directory,
            browser.orderedSelectedURLs(upTo: 1_025) == intent.sources,
            browser.recoverableFileOperations === intent.engine,
            peers(in: workspace, from: browser).contains(where: {
                $0.pane == peer.pane && $0.tab == peer.tab && $0.visit == peer.visit && $0.directory == peer.directory
            })
        else {
            browser?.status.stringValue = "The selection or destination pane changed. Choose the transfer again."
            return false
        }
        let id = browser.operationCoordinator.transfers.enqueue(sources: intent.sources, destination: peer.directory,
            move: intent.move, title: intent.move ? "Moving to another pane…" : "Copying to another pane…",
            origin: browser, engine: intent.engine, metadataPolicy: intent.metadata, copyExecution: intent.execution)
        browser.status.stringValue = id == nil ? "The transfer queue is full or another command is active."
            : "\(intent.move ? "Move" : "Copy") to \(peer.directory.lastPathComponent) added to the queue."
        return id != nil
    }

    private func present(_ menu: NSMenu, browser: BrowserViewController) {
        let surface = browser.activeFileView
        let point = surface.convert(browser.view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        let anchor = surface.bounds.contains(point) ? point : NSPoint(x: 24, y: surface.bounds.minY + 24)
        menu.popUp(positioning: nil, at: anchor, in: surface)
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard menu?.items.contains(where: { $0 === item }) == true,
            let id = item.representedObject as? UUID else { return }
        chosen = id
    }
}
