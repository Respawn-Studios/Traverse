import AppKit
import ExplorerCore

/// A local pane's current visit, with no filesystem authority. Callers obtain
/// real folder access independently of the pane chooser.
struct LocalPaneDestination: Identifiable, Equatable, Sendable {
    enum Purpose { case transfer, comparison }
    let pane: UUID
    let tab: UUID
    let visit: UUID
    let directory: URL
    let title: String
    var id: UUID { pane }

    @MainActor static func available(from source: BrowserViewController, excluding directory: URL? = nil,
                                     for purpose: Purpose = .transfer) -> [Self] {
        guard let workspace = source.workspace, !workspace.isClosing,
              workspace.browsers[source.paneID] === source else { return [] }
        return workspace.layout.paneIDs.enumerated().compactMap { index, id in
            guard id != source.paneID, let peer = workspace.browsers[id],
                  !peer.isBrowserSuspended, !peer.isOfflineCurrentFolder, !peer.isReadOnlyFileSession,
                  !peer.metadataSearch.isShowingResults, !peer.isLoading,
                  let target = peer.location.directoryURL, target.isFileURL,
                  directory.map({ BrowserLocation.directory(target) != .directory($0) }) ?? true else { return nil }
            if purpose == .transfer,
               peer.operationTask != nil || peer.operationPreparationTask != nil || peer.cutPreparationTask != nil { return nil }
            return .init(pane: id, tab: peer.activeID, visit: peer.sessionID, directory: target,
                title: "Pane \(index + 1) — \(peer.location.displayName)")
        }
    }

    @MainActor func currentBrowser(from source: BrowserViewController, excluding directory: URL? = nil,
                                   for purpose: Purpose = .transfer) -> BrowserViewController? {
        guard Self.available(from: source, excluding: directory, for: purpose).contains(where: {
            $0.pane == pane && $0.tab == tab && $0.visit == visit && $0.directory == self.directory
        }) else { return nil }
        return source.workspace?.browsers[pane]
    }

    @MainActor static func choose(_ destinations: [Self], from source: BrowserViewController,
                                 in anchor: NSView, title: String, for purpose: Purpose = .transfer,
                                 present: (NSMenu, NSView) -> Void = { menu, view in
                                     menu.popUp(positioning: nil, at: .init(x: 24, y: 24), in: view)
                                 }) -> Self? {
        guard let first = destinations.first else { return nil }
        if destinations.count == 1 { return first }
        let tab = source.activeID, visit = source.sessionID
        let chooser = LocalPaneDestinationMenu(destinations, title: title)
        present(chooser.menu, anchor)
        guard let selected = chooser.selection, source.activeID == tab, source.sessionID == visit,
              selected.currentBrowser(from: source, for: purpose) != nil else { return nil }
        return selected
    }
}

@MainActor private final class LocalPaneDestinationMenu: NSObject {
    let menu: NSMenu
    private let destinations: [LocalPaneDestination]
    private(set) var selection: LocalPaneDestination?

    init(_ destinations: [LocalPaneDestination], title: String) {
        self.destinations = destinations
        menu = NSMenu(title: title)
        super.init()
        menu.autoenablesItems = false
        for (index, destination) in destinations.enumerated() {
            let item = menu.addItem(withTitle: destination.title, action: #selector(select(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
        }
    }

    @objc private func select(_ item: NSMenuItem) {
        guard destinations.indices.contains(item.tag), menu.items[item.tag] === item else { return }
        selection = destinations[item.tag]
    }
}
