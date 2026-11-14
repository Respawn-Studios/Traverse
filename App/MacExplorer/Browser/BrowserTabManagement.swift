import AppKit
import ExplorerCore

/// Closed-tab history is deliberately session-only. It holds current view
/// state, never grants access and never revives a prepared file operation.
struct ClosedBrowserTab {
    let location: BrowserLocation
    let state: NavigationState
    let sort: DirectorySort
    let filter: String
    let presentationMode: DirectoryViewMode?
    let folderViewResolved: Bool
    let connectionBookmark: WorkspaceConnectionBookmark?
    let archiveState: ArchiveBrowseState?

    init(_ tab: BrowserTab) {
        location = tab.location; state = tab.state; sort = tab.sort; filter = tab.filter
        presentationMode = tab.presentationMode; folderViewResolved = tab.folderViewResolved
        connectionBookmark = tab.connectionBookmark
        archiveState = tab.archiveState
    }

    func restored() -> BrowserTab {
        var tab = (try? connectionBookmark?.disconnectedTab()) ?? BrowserTab(location: location)
        tab.state = state; tab.sort = sort; tab.filter = filter
        tab.archiveState = archiveState
        if folderViewResolved { tab.resolveFolderView(mode: presentationMode) }
        return tab
    }
}

@MainActor
extension BrowserViewController {
    var canOpenBrowserTab: Bool {
        !isBrowserSuspended && view.window?.attachedSheet == nil
    }

    var canManageBrowserTabs: Bool {
        canOpenBrowserTab && !hasExclusiveBrowserOperation && cutPreparationTask == nil
            && (hasFileCommandFocus || tabStrip.ownsManagementMenuContext)
    }

    func rememberClosedTab(_ tab: BrowserTab) {
        closedTabs.append(ClosedBrowserTab(tab))
        if closedTabs.count > 10 { closedTabs.removeFirst(closedTabs.count - 10) }
    }

    func duplicateTab(id: UUID) {
        guard canManageBrowserTabs, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[index].location.isRemote, tabs[index].connectionBookmark == nil { status.stringValue = "Remember this server in Connect to Server before duplicating its saved location."; return }
        saveViewState()
        let duplicate = ClosedBrowserTab(tabs[index]).restored()
        tabs.insert(duplicate, at: index + 1)
        activeID = duplicate.id
        loadLocation(animatingTab: true)
        focusBrowserContent()
    }

    @objc func duplicateCurrentTab(_ sender: Any?) { duplicateTab(id: activeID) }

    @objc func reopenClosedTab(_ sender: Any? = nil) {
        guard canManageBrowserTabs, let closed = closedTabs.popLast() else { return }
        saveViewState()
        let restored = closed.restored()
        tabs.insert(restored, at: activeIndex + 1)
        activeID = restored.id
        loadLocation(animatingTab: true)
        focusBrowserContent()
    }

    func moveTab(id: UUID, before beforeID: UUID?) {
        guard canManageBrowserTabs, id != beforeID,
              let sourceIndex = tabs.firstIndex(where: { $0.id == id }),
              beforeID == nil || tabs.contains(where: { $0.id == beforeID }) else { return }
        // Reordering does not change the active identity/visit, restart a
        // listing or invalidate the origin of any unrelated read.
        saveViewState()
        let tab = tabs.remove(at: sourceIndex)
        let destination = beforeID.flatMap { target in tabs.firstIndex { $0.id == target } } ?? tabs.count
        tabs.insert(tab, at: destination)
        tabStrip.update(tabs: tabs, activeID: activeID)
        recordBrowserSession()
    }

    @objc func moveCurrentTabLeft(_ sender: Any?) {
        guard activeIndex > 0 else { return }
        moveTab(id: activeID, before: tabs[activeIndex - 1].id)
    }

    @objc func moveCurrentTabRight(_ sender: Any?) {
        let index = activeIndex
        guard index + 1 < tabs.count else { return }
        moveTab(id: activeID, before: index + 2 < tabs.count ? tabs[index + 2].id : nil)
    }
}
