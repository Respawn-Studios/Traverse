import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

enum SFTPPaneUploadFeature {
    static let enabled = true
    #if DEBUG
    @MainActor static var qualifying = false
    @MainActor static var available: Bool { SFTPUploadFeature.available && (enabled || qualifying) }
    #else
    static var available: Bool { SFTPUploadFeature.available && enabled }
    #endif
}

@MainActor final class BrowserSFTPPaneUpload: NSObject {
    struct Destination: Equatable {
        let pane: UUID, tab: UUID, visit: UUID, connection: UUID, generation: UUID, title: String
    }
    private weak var browser: BrowserViewController?
    private var menu: NSMenu?, chosen: UUID?
    #if DEBUG
    var presentForVerification: ((NSMenu) -> Void)?
    #endif
    private struct Peer {
        let pane: UUID, tab: UUID, visit: UUID, connection: UUID, generation: UUID, title: String
        let browser: BrowserViewController, owner: SFTPTabController
        var destination: Destination { .init(pane: pane, tab: tab, visit: visit, connection: connection, generation: generation, title: title) }
    }
    init(browser: BrowserViewController) { self.browser = browser }
    var hasDestination: Bool { guard let browser else { return false }; return SFTPPaneUploadFeature.available && !peers(browser, folder: capture(browser)?.hasFolders ?? false).isEmpty }
    var canRequest: Bool {
        guard SFTPPaneUploadFeature.available, menu == nil, let browser, browser.hasFileCommandFocus,
              !(browser.view.window?.firstResponder is NSTextView),
              browser.canAdmitTransfer, browser.canRunExclusiveFileCommand, capture(browser) != nil else { return false }
        return !peers(browser, folder: capture(browser)?.hasFolders ?? false).isEmpty
    }
    var destinations: [Destination] {
        guard canRequest, let browser, let source = capture(browser) else { return [] }
        return peers(browser, folder: source.hasFolders).map(\.destination)
    }
    private func capture(_ browser: BrowserViewController) -> LocalPaneUploadSelection? {
        guard let value = LocalPaneUploadSelection(browser: browser), !value.hasFolders || SFTPFolderUploadFeature.available else { return nil }
        return value
    }
    private func peers(_ browser: BrowserViewController, folder: Bool) -> [Peer] {
        guard let workspace = browser.workspace, !workspace.isClosing, workspace.browsers[browser.paneID] === browser else { return [] }
        return workspace.layout.paneIDs.enumerated().compactMap { index, id in
            guard id != browser.paneID, let remote = workspace.browsers[id], !remote.isBrowserSuspended,
                  let owner = remote.sftpTabs[remote.activeID], let generation = owner.session.latest.generation,
                  remote.sftpDropUpload.canRequest(from: owner),
                  !folder || SFTPFolderUploadFeature.available && owner.session.allowsFreshFolderUploads else { return nil }
            return .init(pane: id, tab: remote.activeID, visit: remote.sessionID, connection: owner.connectionID, generation: generation,
                title: "Pane \(index + 1) — \(remote.location.displayName)", browser: remote, owner: owner)
        }
    }
    func request(to destination: Destination? = nil) {
        guard canRequest, let browser, let source = capture(browser), let first = peers(browser, folder: source.hasFolders).first else { return }
        let offered = peers(browser, folder: source.hasFolders); var target = first
        if let destination {
            guard let selected = offered.first(where: { $0.destination == destination }) else {
                browser.status.stringValue = "The SFTP destination changed. Choose the transfer again."; return
            }
            target = selected
        } else if offered.count > 1 {
            let list = NSMenu(title: "Upload to SFTP Pane"); list.autoenablesItems = false
            for peer in offered { let item = list.addItem(withTitle: peer.title, action: #selector(choose(_:)), keyEquivalent: ""); item.target = self; item.representedObject = peer.pane }
            menu = list; chosen = nil
            #if DEBUG
            if let presentForVerification { presentForVerification(list) }
            else { list.popUp(positioning: nil, at: .init(x: 24, y: 24), in: browser.view) }
            #else
            list.popUp(positioning: nil, at: .init(x: 24, y: 24), in: browser.view)
            #endif
            let id = chosen; menu = nil; chosen = nil; guard let selected = offered.first(where: { $0.pane == id }) else { return }; target = selected
        }
        guard source.isCurrent, peers(browser, folder: source.hasFolders).contains(where: { $0.pane == target.pane && $0.tab == target.tab && $0.visit == target.visit
            && $0.connection == target.connection && $0.generation == target.generation && $0.owner === target.owner }) else {
            browser.status.stringValue = "The selection or SFTP pane changed. Choose Upload to SFTP Pane again."; return
        }
        _ = target.browser.sftpDropUpload.request(source, owner: target.owner)
    }
    @objc private func choose(_ item: NSMenuItem) { guard menu?.items.contains(where: { $0 === item }) == true else { return }; chosen = item.representedObject as? UUID }
}

@MainActor extension BrowserViewController {
    @objc func uploadToSFTPPane(_ sender: Any?) { sftpPaneUpload.request() }
}
