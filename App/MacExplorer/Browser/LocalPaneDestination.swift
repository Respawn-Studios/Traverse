import AppKit
import ExplorerCore

/// Native destination intent only, with no filesystem authority. Callers obtain
/// the chosen browser's real access separately and recheck after that await.
struct LocalPaneDestination: Identifiable, Equatable, Sendable {
    let pane: UUID
    let tab: UUID
    let visit: UUID
    let directory: URL
    let title: String
    var id: UUID { pane }

    @MainActor static func available(from source: BrowserViewController, excluding directory: URL? = nil) -> [Self] {
        guard let workspace = source.workspace, !workspace.isClosing,
              workspace.browsers[source.paneID] === source else { return [] }
        return workspace.layout.paneIDs.enumerated().compactMap { index, id in
            guard id != source.paneID, let peer = workspace.browsers[id],
                  !peer.isBrowserSuspended, !peer.isOfflineCurrentFolder, !peer.isReadOnlyFileSession,
                  !peer.metadataSearch.isShowingResults, !peer.isLoading,
                  peer.operationTask == nil, peer.operationPreparationTask == nil, peer.cutPreparationTask == nil,
                  let target = peer.location.directoryURL, target.isFileURL,
                  directory.map({ BrowserLocation.directory(target) != .directory($0) }) ?? true else { return nil }
            return .init(pane: id, tab: peer.activeID, visit: peer.sessionID, directory: target,
                title: "Pane \(index + 1) — \(peer.location.displayName)")
        }
    }

    @MainActor func currentBrowser(from source: BrowserViewController, excluding directory: URL? = nil) -> BrowserViewController? {
        guard Self.available(from: source, excluding: directory).contains(where: {
            $0.pane == pane && $0.tab == tab && $0.visit == visit && $0.directory == self.directory
        }) else { return nil }
        return source.workspace?.browsers[pane]
    }
}
