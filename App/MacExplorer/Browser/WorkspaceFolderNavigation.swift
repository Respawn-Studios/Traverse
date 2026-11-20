import AppKit
import ExplorerCore
import LocalStorage

/// Pairs the two displayed tabs, not their screen positions. Only a completed
/// explicit folder visit can ask the other tab to follow.
@MainActor
final class WorkspaceFolderNavigation {
    private struct Endpoint {
        let pane: UUID
        let tab: UUID
        let visit: UUID
        let root: URL

        @MainActor init(_ browser: BrowserViewController, root: URL) {
            pane = browser.paneID
            tab = browser.activeID
            visit = browser.sessionID
            self.root = root
        }
    }

    private final class Pair {
        let first: Endpoint
        let second: Endpoint
        var roots: LinkedFolderRoots?
        var task: Task<Void, Never>?
        var notice: (visit: UUID, message: String)?
        var followingVisit: UUID?

        init(_ first: Endpoint, _ second: Endpoint) { self.first = first; self.second = second }
        func endpoint(for pane: UUID) -> Endpoint { pane == first.pane ? first : second }
        func peer(of pane: UUID) -> Endpoint { pane == first.pane ? second : first }
        func stop() { task?.cancel(); task = nil; notice = nil }
    }

    private weak var workspace: BrowserWorkspaceController?
    private var links: [UUID: Pair] = [:]

    init(workspace: BrowserWorkspaceController) { self.workspace = workspace }

    func isLinked(_ split: UUID?) -> Bool { split.map { links[$0] != nil } ?? false }
    func canToggle(_ split: UUID) -> Bool { isLinked(split) || pairToLink(split) != nil }

    func toggle(_ split: UUID) -> Bool {
        guard let workspace else { return false }
        if isLinked(split) {
            remove(split)
            workspace.activeBrowser.refreshStatus()
            return true
        }
        guard let (first, second) = pairToLink(split), let origin = workspace.browsers[first.pane],
              let peer = workspace.browsers[second.pane] else { return false }
        let pair = Pair(first, second)
        links[split] = pair
        let access = origin.folderAccess, fileSystem = origin.fileSystem
        let directories = [first.root, second.root]
        let preparation = access.prepareAccess(to: directories)
        pair.task = Task { [weak self, weak pair, weak workspace, weak origin, weak peer] in
            guard let self, let pair else { return }
            let lifetime = await access.retainAccess(for: directories)
            guard !Task.isCancelled, links[split] === pair, let origin, let peer else { return }
            do {
                guard access.isCurrent(preparation), Self.covers(directories, in: lifetime) else {
                    throw LinkedFolderFailure.unavailable
                }
                let roots = try await fileSystem.linkFolderNavigation(first.root, second.root, retaining: lifetime)
                guard !Task.isCancelled, links[split] === pair, let workspace else { return }
                guard canContinue(origin), canContinue(peer), access.isCurrent(preparation),
                      origin.sessionID == first.visit, peer.sessionID == second.visit else {
                    remove(split); return
                }
                pair.task = nil
                pair.roots = roots
                if workspace.activeBrowser === origin || workspace.activeBrowser === peer {
                    workspace.activeBrowser.status.stringValue = "Pane navigation linked for these folders."
                }
            } catch {
                guard !Task.isCancelled, links[split] === pair, let workspace else { return }
                remove(split)
                if workspace.activeBrowser === origin || workspace.activeBrowser === peer {
                    workspace.activeBrowser.status.stringValue = "Both folders need to be local and accessible to link navigation."
                }
            }
        }
        return true
    }

    func locationWillChange(in browser: BrowserViewController) {
        guard let split = workspace?.layout.parent(of: browser.paneID)?.id, let pair = links[split] else { return }
        let endpoint = pair.endpoint(for: browser.paneID)
        guard pair.roots != nil, browser.activeID == endpoint.tab, !browser.metadataSearch.isShowingResults,
              let next = browser.location.directoryURL, LinkedFolderRoots.contains(next, under: endpoint.root) else {
            remove(split); return
        }
        if pair.followingVisit == browser.sessionID { pair.followingVisit = nil }
        pair.stop()
    }

    func folderDidLoad(in browser: BrowserViewController, at directory: URL) {
        guard let workspace, workspace.activeBrowser === browser, canContinue(browser),
              let split = workspace.layout.parent(of: browser.paneID)?.id, let pair = links[split], let roots = pair.roots,
              let peer = workspace.browsers[pair.peer(of: browser.paneID).pane],
              canContinue(peer, replacing: pair.followingVisit),
              let currentPeerDirectory = peer.location.directoryURL else { return }
        let from = pair.endpoint(for: browser.paneID), to = pair.peer(of: browser.paneID)
        guard browser.activeID == from.tab, peer.activeID == to.tab,
              LinkedFolderRoots.contains(directory, under: from.root),
              LinkedFolderRoots.contains(currentPeerDirectory, under: to.root) else { remove(split); return }
        let sourceVisit = browser.sessionID, peerVisit = peer.sessionID
        let directories = [from.root, to.root], access = browser.folderAccess, fileSystem = browser.fileSystem
        let preparation = access.prepareAccess(to: directories)
        pair.stop()
        pair.task = Task { [weak self, weak pair, weak browser, weak peer] in
            guard let self, let pair, let browser, let peer else { return }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && links[split] === pair && self.workspace?.activeBrowser === browser
                    && browser.activeID == from.tab && browser.sessionID == sourceVisit
                    && peer.activeID == to.tab && peer.sessionID == peerVisit
                    && canContinue(browser) && canContinue(peer, replacing: pair.followingVisit)
            }
            defer { if !Task.isCancelled { pair.task = nil } }
            do {
                let lifetime = await access.retainAccess(for: directories)
                guard isCurrent() else { return }
                guard access.isCurrent(preparation), Self.covers(directories, in: lifetime) else {
                    throw LinkedFolderFailure.rootsChanged
                }
                let next = try await fileSystem.correspondingFolder(in: roots, from: from.root, visited: directory, retaining: lifetime)
                guard isCurrent() else { return }
                guard access.isCurrent(preparation) else { throw LinkedFolderFailure.rootsChanged }
                if peer.location != .directory(next) {
                    pair.task = nil
                    peer.navigate(to: .directory(next), followingLinkedPane: true)
                    pair.followingVisit = peer.sessionID
                }
            } catch {
                guard isCurrent() else { return }
                if error as? LinkedFolderFailure == .rootsChanged {
                    remove(split)
                    browser.status.stringValue = "A linked folder changed or lost access. Link the panes again to continue."
                } else {
                    let message: String
                    if let storage = error as? LocalStorageError, case .busy = storage {
                        message = "Folder checks are busy. Navigate again to follow."
                    } else { message = "Matching folder unavailable in the linked pane." }
                    pair.notice = (sourceVisit, message)
                    browser.refreshStatus()
                }
            }
        }
    }

    func notice(in browser: BrowserViewController) -> String? {
        guard let split = workspace?.layout.parent(of: browser.paneID)?.id,
              let notice = links[split]?.notice, notice.visit == browser.sessionID else { return nil }
        return notice.message
    }

    func reconcileLayout() {
        guard let workspace else { close(); return }
        for (id, pair) in Array(links) {
            guard case .split(_, _, let first, let second)? = workspace.layout.node(id)?.content,
                  Set([first, second]) == Set([pair.first.pane, pair.second.pane]) else {
                remove(id); continue
            }
        }
    }

    func paneWillSuspend(_ pane: UUID) {
        for (id, pair) in Array(links) where pair.first.pane == pane || pair.second.pane == pane { remove(id) }
    }

    func close() {
        for pair in links.values { pair.stop() }
        links.removeAll()
    }

    private func remove(_ split: UUID) { links.removeValue(forKey: split)?.stop() }

    private func pairToLink(_ split: UUID) -> (Endpoint, Endpoint)? {
        guard let workspace, case .split(_, _, let first, let second)? = workspace.layout.node(split)?.content,
              let left = workspace.browsers[first], let right = workspace.browsers[second],
              canContinue(left), canContinue(right),
              let firstRoot = left.location.directoryURL, let secondRoot = right.location.directoryURL,
              left.location != right.location, LinkedFolderRoots.permits(firstRoot), LinkedFolderRoots.permits(secondRoot) else { return nil }
        return (.init(left, root: firstRoot), .init(right, root: secondRoot))
    }

    private func canContinue(_ browser: BrowserViewController, replacing linkedVisit: UUID? = nil) -> Bool {
        guard let workspace else { return false }
        return workspace.canChangePaneLayout && !ApplicationFileActivity.gate.isClosed
            && workspace.browsers[browser.paneID] === browser && !browser.isReadOnlyFileSession
            && (!browser.isLoading || browser.sessionID == linkedVisit)
            && !browser.isOfflineCurrentFolder && !browser.metadataSearch.isShowingResults
            && browser.loadError == nil && browser.location.directoryURL != nil
    }

    private static func covers(_ directories: [URL], in lifetime: FileAccessLifetimes) -> Bool {
        !TraverseAccessPolicy.requiresFolderSelection || directories.allSatisfy(lifetime.covers)
    }
}
