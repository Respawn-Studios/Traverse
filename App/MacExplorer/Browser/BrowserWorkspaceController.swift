import AppKit
import Combine
import ExplorerCore
import LocalStorage

enum WorkspaceVolumeRefreshResult {
    case success([VolumeInfo])
    case failure(String)
}

/// Window composition only. Every pane retains the existing browser command
/// implementation and the application coordinator remains the sole write owner.
@MainActor
final class BrowserWorkspaceController: NSViewController {
    var primaryBrowser: BrowserViewController
    var settingsWindow: NSWindow?
    var browsers: [UUID: BrowserViewController]
    var layout: PaneLayout
    var activePaneID: UUID
    var activeBrowser: BrowserViewController { browsers[activePaneID] ?? primaryBrowser }
    var onActiveBrowserChanged: ((BrowserViewController) -> Void)?
    let preview = BrowserInlinePreviewController()
    let operationButton = OperationProgressButton(frame: .zero)
    var queuePresentation: BrowserQueuePresentationController?
    weak var operationBrowser: BrowserViewController?
    var isClosing = false {
        didSet {
            if isClosing {
                profileWorkspaceController?.prepareToClose()
                paneTransition?.finish(); paneTransition = nil
                sidebarSplit?.finishAnimation()
                initialVolumeBootstrapTask?.cancel(); invalidateVolumeRefresh()
                queuePresentation?.cancel()
            }
        }
    }
    var sessionReady = false
    var restoringSession = false
    var startupGeneration = UUID()
    var startupTask: Task<Void, Never>?
    var hasIncomingFolderRequest = false
    lazy var persistence = BrowserWorkspacePersistence(stateDirectory: primaryBrowser.isVerificationSession ? nil : primaryBrowser.developmentStateDirectory)
    lazy var updateResumeStore = UpdateWorkspaceResumeStore(directory: primaryBrowser.isVerificationSession ? nil : primaryBrowser.developmentStateDirectory)
    lazy var launchProfileStore = LaunchProfileStore(directory: primaryBrowser.isVerificationSession ? nil : primaryBrowser.developmentStateDirectory)
    lazy var profileWorkspaceStore = WorkspaceProfileStore(directory: primaryBrowser.isVerificationSession ? nil : primaryBrowser.developmentStateDirectory?.appendingPathComponent("profile-workspaces", isDirectory: true))
    var profileWorkspaceController: ProfileWorkspaceController?
    var profileWorkspaces: ProfileWorkspaceController {
        if let profileWorkspaceController { return profileWorkspaceController }
        let controller = ProfileWorkspaceController(workspace: self); profileWorkspaceController = controller; return controller
    }
    private(set) var launchProfilesModel: LaunchProfilesModel?
    var launchProfiles: LaunchProfilesModel {
        if let launchProfilesModel { return launchProfilesModel }
        let model = LaunchProfilesModel(workspace: self, store: launchProfileStore)
        launchProfilesModel = model; return model
    }
    var launchProfilesWindow: LaunchProfilesWindowController?
    var quickProfileSwitcher: QuickLaunchProfiles?

    let sidebarHost = NSView()
    let paneTreeHost = NSView()
    private let sharedChromeBackdrop = NSVisualEffectView()
    private var paneTransition: WorkspacePaneTransition?
    let inspectorHost = NSView()
    let pathHost = NSView()
    let footerHost = NSView()
    let activeFooterHost = NSView()
    let sidebarRestoreButton = NSButton()
    private var sidebarControllers: [UUID: NSViewController] = [:]
    private(set) var paneHosts: [UUID: PaneHostView] = [:]
    private var paneSplits: [UUID: WorkspaceSplitView] = [:]
    private var reconcilingPaneTree = false
    private var sidebarSplit: WorkspaceSidebarSplitView?
    var isSidebarCollapsed: Bool { sidebarSplit?.isSidebarCollapsed == true }
    var sidebarSnapshot: PaneWorkspaceSnapshot.Sidebar { sidebarSplit?.snapshot ?? .init() }
    private var rootBody: NSStackView?
    private var pathHeight: NSLayoutConstraint?
    var footerHeight: NSLayoutConstraint?
    var operationCardBottomConstraints: [UUID: NSLayoutConstraint] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var startedBrowsers: Set<UUID> = []
    private var observedVolumes: [VolumeInfo]?
    private var volumeRefreshTicket: UUID?
    private var volumeRefreshOwner: UUID?
    private var initialVolumeBootstrapTask: Task<Void, Never>?
    private var initialVolumeBootstrapFinished = false
    private var initialVolumeBootstrapFailed = false
    #if DEBUG
    var queueSharedRendersForVerification = 0
    var hasPaneTransitionForVerification: Bool { paneTransition != nil }
    var hasSidebarAnimationForVerification: Bool { sidebarSplit?.isAnimating == true }
    var paneTransitionOriginForVerification: WorkspacePaneTransition.Origin? { paneTransition?.origin }
    var paneTransitionFramesForVerification: [UUID: WorkspacePaneTransition.Frame] { paneTransition?.frames ?? [:] }
    var paneTransitionHasOpaqueBackdropForVerification: Bool {
        paneTransition?.subviews.contains { ($0.layer?.backgroundColor?.alpha ?? 0) > 0 } ?? false
    }
    var queuePresentationPendingForVerification: Bool {
        queuePresentation?.isPendingForVerification == true
            || browsers.values.contains { $0.queueRevisionCallbacksPendingForVerification > 0 }
    }
    var willStartBrowserForVerification: ((BrowserViewController) -> Void)?
    var didConstructPaneHostForVerification: ((PaneHostView, BrowserViewController) -> Void)?
    var hasInitialVolumeBootstrapForVerification: Bool { initialVolumeBootstrapTask != nil }
    #endif

    init(primaryBrowser: BrowserViewController) {
        self.primaryBrowser = primaryBrowser
        browsers = [primaryBrowser.paneID: primaryBrowser]
        activePaneID = primaryBrowser.paneID
        layout = PaneLayout(paneID: primaryBrowser.paneID)
        observedVolumes = primaryBrowser.volumes.isEmpty ? nil : primaryBrowser.volumes
        super.init(nibName: nil, bundle: nil)
    }
    convenience init(settings: BrowserSettings) { self.init(primaryBrowser: BrowserViewController(settings: settings)) }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        // Build at a valid initial allocation before this controller attaches
        // to its window; early layout must not solve the live hierarchy at zero.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1140, height: 760))
        view.setAccessibilityLabel("File browser workspace")
        sharedChromeBackdrop.material = .underWindowBackground
        sharedChromeBackdrop.blendingMode = .behindWindow
        sharedChromeBackdrop.state = .followsWindowActiveState
        pin(sharedChromeBackdrop, inside: view, belowTitlebar: true)
        inspectorHost.widthAnchor.constraint(equalToConstant: 300).isActive = true
        paneTreeHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        paneTreeHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let mainContent = stack([paneTreeHost, inspectorHost], orientation: .horizontal, spacing: 1)
        mainContent.alignment = .top
        mainContent.distribution = .fill
        for child in mainContent.arrangedSubviews { child.heightAnchor.constraint(equalTo: mainContent.heightAnchor).isActive = true }
        let content = WorkspaceSidebarSplitView()
        sidebarSplit = content
        content.remainingMinimum = { [weak self] in
            guard let self else { return 400 }
            return self.minimumSize(for: self.layout.rootID).width + (self.preview.isEnabled ? 301 : 0)
        }
        content.motion = primaryBrowser.settings.motion
        content.canCollapse = { [weak self] in self?.canToggleSidebar == true }
        content.onToggleRequested = { [weak self] in self?.toggleSidebar() }
        content.onCollapsedChanged = { [weak self] in self?.sidebarPresentationChanged() }
        content.onPresentationChanged = { [weak self] in self?.updateSidebarRestorePresentation() }
        content.onWidthChanged = { [weak self] in
            self?.enforceWindowMinimum(grow: false)
            self?.recordSession()
        }
        sidebarHost.frame = NSRect(x: 0, y: 0, width: 200, height: 500)
        mainContent.frame = NSRect(x: 201, y: 0, width: 619, height: 500)
        for child in [sidebarHost, mainContent] {
            child.translatesAutoresizingMaskIntoConstraints = true
            child.autoresizingMask = []
            content.addArrangedSubview(child)
        }
        content.adjustSubviews()
        inspectorHost.isHidden = true
        pin(preview.view, inside: inspectorHost)
        operationButton.isHidden = true
        sidebarRestoreButton.bezelStyle = .recessed
        sidebarRestoreButton.controlSize = .small
        sidebarRestoreButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Show Sidebar")
        sidebarRestoreButton.imagePosition = .imageOnly
        sidebarRestoreButton.toolTip = "Show Sidebar"
        sidebarRestoreButton.setAccessibilityLabel("Show Sidebar")
        sidebarRestoreButton.target = self
        sidebarRestoreButton.action = #selector(showSidebar(_:))
        sidebarRestoreButton.isHidden = true
        activeFooterHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pin(activeFooterHost, inside: footerHost)
        pathHeight = pathHost.heightAnchor.constraint(equalToConstant: 26).interfaceScaled
        pathHeight?.isActive = true
        footerHeight = footerHost.heightAnchor.constraint(equalToConstant: 28).interfaceScaled
        footerHeight?.isActive = true
        let body = stack([content, pathHost, footerHost], orientation: .vertical, spacing: 0)
        rootBody = body
        body.distribution = .fill
        body.alignment = .leading
        for child in body.arrangedSubviews { child.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        content.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        pin(body, inside: view, belowTitlebar: true)
        attachBrowser(primaryBrowser)
        rebuildPaneTree(animated: false)
        installSharedViews()
        InterfacePresentation.shared.register(view)
        primaryBrowser.settings.$showsPathBar.sink { [weak self] value in
            self?.pathHost.isHidden = true // each pane owns its bottom address
            self?.updateOperationBottomReservation(bottomAddress: value)
            Task { @MainActor [weak self] in self?.enforceWindowMinimum(grow: true) }
        }.store(in: &subscriptions)
        primaryBrowser.settings.$paneFocus.sink { [weak self] value in
            self?.paneHosts.values.forEach { $0.focusPreferences = value }
        }.store(in: &subscriptions)
        primaryBrowser.clipboardState.didChange = { [weak self] in
            guard let self else { return }
            for browser in browsers.values {
                browser.renderTransferFeedback()
                browser.reloadFileRows(preserving: browser.selectedURLs)
            }
        }
        queuePresentation = BrowserQueuePresentationController(workspace: self)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        preview.endSession()
    }

    var canChangePaneLayout: Bool {
        !isClosing && view.window != nil && view.window?.attachedSheet == nil
            && browsers.values.allSatisfy { !$0.isBrowserSuspended && !$0.hasExclusiveBrowserOperation && $0.cutPreparationTask == nil }
    }

    func attachBrowser(_ browser: BrowserViewController) {
        guard paneHosts[browser.paneID] == nil else { return }
        browser.workspace = self
        if let observedVolumes { browser.volumes = observedVolumes }
        browser.pinsController = primaryBrowser.pinsController
        browser.sidebarLayoutOwner = primaryBrowser.sidebarLayoutOwner
        browser.folderAccess = primaryBrowser.folderAccess
        browser.clipboardState = primaryBrowser.clipboardState
        browser.operationHistory = primaryBrowser.operationHistory
        browser.clipboardWriter = primaryBrowser.clipboardWriter
        if browser !== primaryBrowser { browser.recoverableFileOperations = primaryBrowser.recoverableFileOperations }
        addChild(browser)
        _ = browser.view
        configureOperationHost(for: browser)
        if let item = browser.splitController.splitViewItems.first, browser.splitController.splitViewItems.count > 1 {
            sidebarControllers[browser.paneID] = item.viewController
            browser.splitController.removeSplitViewItem(item)
        }
        if let body = browser.paneBody {
            for child in [browser.statusSurface].compactMap({ $0 }) {
                body.removeArrangedSubview(child)
                child.removeFromSuperview()
            }
        }
        browser.footerOperationButton.isHidden = true
        let host = PaneHostView(paneID: browser.paneID, content: browser.view, workspace: self)
        host.focusPreferences = browser.settings.paneFocus
        #if DEBUG
        didConstructPaneHostForVerification?(host, browser)
        #endif
        paneHosts[browser.paneID] = host
        browser.tabStrip.canDragTab = { [weak self, weak browser] id in
            guard let self, let browser else { return false }
            return self.canChangePaneLayout && browser.tabs.contains { $0.id == id } && self.browsers.count > 1
        }
        browser.tabStrip.canReceiveTab = { [weak self, weak browser] strip, id in
            guard let self, let browser, let source = self.browsers.values.first(where: { $0.tabStrip === strip }) else { return false }
            return source !== browser && self.canChangePaneLayout && source.tabs.contains { $0.id == id }
        }
        browser.tabStrip.onReceiveTab = { [weak self, weak browser] strip, id, before in
            guard let self, let browser, let source = self.browsers.values.first(where: { $0.tabStrip === strip }) else { return false }
            return self.moveTab(id, from: source, into: browser, before: before)
        }
        browser.tabStrip.onRouteTabDrag = { [weak self, weak strip = browser.tabStrip] info, phase in
            guard let self, let strip else { return [] }
            return self.routeTabDrag(info, receiver: strip, phase: phase)
        }
        browser.tabStrip.onRouteTabDragExit = { [weak self, weak strip = browser.tabStrip] info in
            guard let self, let strip else { return }
            self.exitTabDrag(info, receiver: strip)
        }
        browser.tabStrip.onDragMoved = { [weak self] strip, point, footprint in
            guard let self else { return }
            guard self.canChangePaneLayout, self.browsers.values.contains(where: { $0.tabStrip === strip }) else {
                self.clearTabDropPreviews(); return
            }
            self.revokeTabDropPreviews(from: strip, pointer: point, footprint: footprint)
        }
        browser.tabStrip.onDragEnded = { [weak self] in self?.clearTabDropPreviews() }
    }

    private func clearTabDropPreviews() {
        paneHosts.values.forEach { $0.clearSnap() }
        browsers.values.forEach { $0.tabStrip.clearDropPreview() }
    }

    /// Initial volume discovery belongs to the workspace, independently of
    /// whichever pane is still awaiting remembered-folder startup. Only one
    /// bootstrap read runs at a time, using the existing bounded read worker.
    func requestInitialVolumeObservationIfNeeded() {
        guard !isClosing, observedVolumes == nil, !initialVolumeBootstrapFinished,
              initialVolumeBootstrapTask == nil else { return }
        initialVolumeBootstrapTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.initialVolumeBootstrapTask = nil }
            while !Task.isCancelled, !self.isClosing, self.observedVolumes == nil {
                let source = self.primaryBrowser
                guard self.browsers[source.paneID] === source, !source.isBrowserSuspended else { return }
                // This Mac's loadLocation already queues its ordinary read.
                // Another live query also owns the current observation.
                if source.location == .computer || self.volumeRefreshTicket != nil { return }
                await source.refreshVolumes()
                guard !Task.isCancelled, !self.isClosing else { return }
                if self.observedVolumes != nil { self.initialVolumeBootstrapFinished = true; return }
                if self.browsers[source.paneID] !== source || source.isBrowserSuspended {
                    // Wait for the old read to finish before handing off; do
                    // not add another active bootstrap worker during teardown.
                    continue
                }
                self.initialVolumeBootstrapFinished = true
                if self.volumeRefreshTicket == nil {
                    self.initialVolumeBootstrapFailed = true
                    for browser in self.browsers.values { self.applyInitialVolumeObservationHint(to: browser) }
                }
                return // Live-source failure requires an explicit retry.
            }
        }
    }

    func applyInitialVolumeObservationHint(to browser: BrowserViewController) {
        guard observedVolumes == nil, initialVolumeBootstrapFailed, browser.isViewLoaded,
              let group = browser.sidebarRoots.first(where: { $0.title == "Locations" }) else { return }
        let hint = SidebarNode("Locations unavailable — open This Mac and Refresh to retry",
                               icon: "exclamationmark.triangle", children: [])
        group.children = [hint]
        browser.outline.reloadItem(group, reloadChildren: true)
        browser.outline.expandItem(group)
    }

    /// Request age is shared across panes. A valid per-browser token alone
    /// cannot order one pane's older result against another pane's newer one.
    func beginVolumeRefresh(from browser: BrowserViewController) -> UUID? {
        guard !isClosing, browsers[browser.paneID] === browser, !browser.isBrowserSuspended else { return nil }
        let ticket = UUID()
        volumeRefreshTicket = ticket; volumeRefreshOwner = browser.paneID
        for peer in browsers.values where peer.isViewLoaded && peer.showsComputerVolumes {
            peer.isLoading = true; peer.loadError = nil
            // Keep the cached cards and valid selection while showing that a
            // newer shared observation is pending. Clear any old error overlay.
            peer.refreshStatus()
        }
        return ticket
    }

    @discardableResult
    func completeVolumeRefresh(_ result: WorkspaceVolumeRefreshResult, from browser: BrowserViewController, ticket: UUID) -> Bool {
        guard !isClosing, !browser.isBrowserSuspended, browsers[browser.paneID] === browser,
              volumeRefreshTicket == ticket, volumeRefreshOwner == browser.paneID else { return false }
        volumeRefreshTicket = nil; volumeRefreshOwner = nil
        switch result {
        case .success(let volumes):
            observedVolumes = volumes
            initialVolumeBootstrapFailed = false
            for peer in browsers.values {
                peer.volumes = volumes
                guard peer.isViewLoaded else { continue }
                peer.updateSidebarVolumes()
                peer.updateBreadcrumbs()
                if peer.showsComputerVolumes {
                    peer.isLoading = false; peer.loadError = nil
                    peer.renderVolumes(); peer.refreshStatus()
                }
            }
        case .failure(let message):
            // Retain the last successful observation, while completing every
            // This Mac view waiting on this shared observation lifecycle.
            for peer in browsers.values where peer.isViewLoaded && peer.showsComputerVolumes {
                peer.isLoading = false; peer.loadError = message
                peer.renderVolumes(); peer.refreshStatus()
            }
        }
        return true
    }

    @discardableResult
    func cancelVolumeRefresh(from browser: BrowserViewController, ticket: UUID) -> Bool {
        guard browsers[browser.paneID] === browser, volumeRefreshTicket == ticket,
              volumeRefreshOwner == browser.paneID else { return false }
        invalidateVolumeRefresh()
        return true
    }

    private func invalidateVolumeRefresh(owner browser: BrowserViewController? = nil) {
        guard volumeRefreshTicket != nil, browser == nil || volumeRefreshOwner == browser?.paneID else { return }
        volumeRefreshTicket = nil; volumeRefreshOwner = nil
        guard !isClosing else { return }
        for peer in browsers.values where peer !== browser && peer.isViewLoaded && peer.showsComputerVolumes && peer.isLoading {
            peer.isLoading = false
            peer.loadError = "Locations refresh was interrupted. Refresh to try again."
            peer.renderVolumes(); peer.refreshStatus()
        }
    }

    func activate(_ browser: BrowserViewController, focus: Bool = true) {
        guard browsers[browser.paneID] === browser, !browser.isBrowserSuspended else { return }
        if activePaneID != browser.paneID {
            activeBrowser.folderSummary.cancel()
            activeBrowser.addressCompletion.cancel()
            activeBrowser.folderFilter.contextWillChange()
            activeBrowser.inlineRename.cancel()
            activeBrowser.selectionGroupDraft.contextChanged()
            activeBrowser.openAndShare.contextWillChange()
            activeBrowser.metadataSearch.openContextWillChange()
            preview.endSession()
            activePaneID = browser.paneID
            installSharedViews()
            for (index, id) in layout.paneIDs.enumerated() {
                paneHosts[id]?.isSplit = layout.paneIDs.count > 1
                paneHosts[id]?.isActive = id == activePaneID
                paneHosts[id]?.setAccessibilityLabel("Pane \(index + 1)" + (id == activePaneID ? ", active" : ""))
            }
            onActiveBrowserChanged?(browser)
            recordSession()
        }
        if focus { browser.focusBrowserContent() }
        // BrowserWindow activates the clicked pane before AppKit dispatches to
        // its controls. Refresh synchronously: an inactive listing may have
        // disabled its close buttons, and a disabled NSButton never sends the
        // action that would otherwise close the explicitly clicked tab.
        for pane in browsers.values { pane.tabStrip.refreshManagementAvailability() }
        preview.updateSelection(from: browser)
    }

    func activatePane(at windowPoint: NSPoint) {
        for id in layout.paneIDs {
            guard let host = paneHosts[id], host.bounds.contains(host.convert(windowPoint, from: nil)), let browser = browsers[id] else { continue }
            activate(browser, focus: false)
            return
        }
    }

    func focusOtherPane() {
        let ids = layout.paneIDs
        guard ids.count > 1, let index = ids.firstIndex(of: activePaneID), let browser = browsers[ids[(index + 1) % ids.count]] else { return }
        activate(browser)
    }

    func selectionDidChange(in browser: BrowserViewController) {
        guard activeBrowser === browser else { return }
        preview.updateSelection(from: browser)
    }
    func locationWillChange(in browser: BrowserViewController) {
        if activeBrowser === browser { preview.endSession() }
    }
    func paneWillSuspend(_ browser: BrowserViewController) {
        invalidateVolumeRefresh(owner: browser)
        if activeBrowser === browser { preview.endSession() }
        paneHosts[browser.paneID]?.clearSnap()
    }
    @objc func togglePreview(_ sender: Any? = nil) {
        if !preview.isEnabled {
            let requested = workspaceMinimum(previewEnabled: true)
            if let window = view.window, let screen = window.screen,
               requested.width > screen.visibleFrame.width || requested.height + (window.frame.height - window.contentLayoutRect.height) > screen.visibleFrame.height {
                activeBrowser.status.stringValue = "There is not enough screen space for Preview beside these panes. Close a pane to continue."
                return
            }
        }
        preview.setEnabled(!preview.isEnabled)
        inspectorHost.isHidden = !preview.isEnabled
        enforceWindowMinimum(grow: preview.isEnabled)
        view.layoutSubtreeIfNeeded()
        if preview.isEnabled { preview.updateSelection(from: activeBrowser) }
    }

    var canToggleSidebar: Bool {
        !isClosing && isViewLoaded && view.window != nil && view.window?.attachedSheet == nil
            && !activeBrowser.isBrowserSuspended
    }
    @objc func showSidebar(_ sender: Any?) { setSidebarCollapsed(false) }
    func toggleSidebar() { setSidebarCollapsed(!isSidebarCollapsed) }
    func setSidebarCollapsed(_ collapsed: Bool, animated: Bool = true) {
        guard canToggleSidebar, let sidebarSplit, isSidebarCollapsed != collapsed else { return }
        if !collapsed {
            let requested = workspaceMinimum(previewEnabled: preview.isEnabled, sidebarCollapsed: false)
            if let window = view.window, let screen = window.screen,
               requested.width > screen.visibleFrame.width || requested.height + (window.frame.height - window.contentLayoutRect.height) > screen.visibleFrame.height {
                activeBrowser.status.stringValue = "There is not enough screen space to show the sidebar beside these panes. Close a pane or hide Preview."
                return
            }
        }
        sidebarSplit.setCollapsed(collapsed, animated: animated)
    }
    private func sidebarPresentationChanged() {
        // Keep an existing editor/list focus. Only move focus when its sidebar
        // owner, or the now-hidden restore button, is being removed from view.
        if let responder = view.window?.firstResponder as? NSView,
           (isSidebarCollapsed && responder.isDescendant(of: sidebarHost))
            || (!isSidebarCollapsed && responder === sidebarRestoreButton) {
            activeBrowser.focusBrowserContent()
        }
        enforceWindowMinimum(grow: !isSidebarCollapsed)
        recordSession()
    }

    private func updateSidebarRestorePresentation() {
        let moving = sidebarSplit?.isAnimating == true
        let visible = isSidebarCollapsed || moving
        if sidebarRestoreButton.isHidden == visible { sidebarRestoreButton.isHidden = !visible }
        sidebarRestoreButton.alphaValue = moving ? (sidebarSplit?.collapsedFraction ?? 0) : (isSidebarCollapsed ? 1 : 0)
        sidebarRestoreButton.isEnabled = isSidebarCollapsed
        sidebarRestoreButton.setAccessibilityHidden(!isSidebarCollapsed)
    }

    func canSplitActive(at edge: PaneDropEdge) -> Bool {
        canChangePaneLayout && browsers.count < PaneLayout.maximumPanes && fitsSplit(beside: activePaneID, edge: edge)
    }

    @discardableResult
    func splitActive(at edge: PaneDropEdge) -> Bool {
        guard canSplitActive(at: edge) else { explainSplitRefusal(); return false }
        let source = activeBrowser
        source.saveViewState()
        let peer = BrowserViewController(settings: source.settings)
        preparePaneTransition(source: source, tabID: source.activeID, edge: edge)
        peer.paneViewMode = source.isArchiveLocation ? source.paneViewMode : source.effectiveViewMode
        peer.folderViews = source.folderViews
        let duplicate = source.isRemoteLocation ? BrowserTab(location: .computer) : ClosedBrowserTab(source.tabs[source.activeIndex]).restored()
        peer.tabs = [duplicate]; peer.activeID = duplicate.id
        do { try layout.split(source.paneID, inserting: peer.paneID, at: edge) }
        catch { explainSplitRefusal(); return false }
        browsers[peer.paneID] = peer
        attachBrowser(peer)
        paneTransition?.arrivingPaneID = peer.paneID
        rebuildPaneTree()
        activate(peer)
        startBrowser(peer)
        recordSession()
        return true
    }

    @discardableResult
    func closeActivePane() -> Bool {
        guard canChangePaneLayout, browsers.count > 1,
              let targetID = layout.paneIDs.first(where: { $0 != activePaneID }), let target = browsers[targetID] else { return false }
        let source = activeBrowser
        preparePaneTransition()
        source.saveViewState(); target.saveViewState()
        target.tabs.append(contentsOf: source.tabs)
        // Close Pane retains its tabs and their live connection owners. Move
        // ownership before retirement, which closes any owners still left.
        for (tab, owner) in source.smbTabs { target.smbTabs[tab] = owner }
        for (tab, owner) in source.sftpTabs { target.sftpTabs[tab] = owner }
        for (tab, owner) in source.archiveTabs { target.archiveTabs[tab] = owner; owner.rebind(to: target) }
        for (tab, notice) in source.sftpClosedUploadNotices { target.sftpClosedUploadNotices[tab] = notice }
        for (tab, action) in source.smbClosedUploadNotices { target.smbClosedUploadNotices[tab] = action }
        source.sftpTabs = [:]
        source.sftpClosedUploadNotices = [:]
        source.smbClosedUploadNotices = [:]
        source.smbTabs = [:]
        source.archiveTabs = [:]
        removePane(source)
        rebuildPaneTree()
        activate(target)
        target.tabStrip.update(tabs: target.tabs, activeID: target.activeID)
        recordSession()
        return true
    }

    /// Explicit Close Tab differs from Close Pane: retain the closed current
    /// visit in bounded Reopen history, then collapse the now-empty pane.
    @discardableResult
    func closeLastTab(in source: BrowserViewController) -> Bool {
        guard canChangePaneLayout, browsers.count > 1, browsers[source.paneID] === source,
              source.tabs.count == 1, let sourceIndex = layout.paneIDs.firstIndex(of: source.paneID) else { return false }
        let ids = layout.paneIDs
        let targetID = ids[sourceIndex > 0 ? sourceIndex - 1 : 1]
        guard let target = browsers[targetID] else { return false }
        preparePaneTransition()
        source.saveViewState()
        target.rememberClosedTab(source.tabs[0])
        removePane(source)
        rebuildPaneTree()
        activate(target)
        recordSession()
        return true
    }

    func canMoveTab(_ id: UUID, from source: BrowserViewController, beside targetID: UUID, edge: PaneDropEdge) -> Bool {
        guard canChangePaneLayout, browsers[source.paneID] === source, browsers[targetID] != nil,
              source.tabs.contains(where: { $0.id == id }), !(source.paneID == targetID && source.tabs.count == 1) else { return false }
        let movingWholePane = source.tabs.count == 1 && source.paneID != targetID
        guard movingWholePane || browsers.count < PaneLayout.maximumPanes else { return false }
        if movingWholePane {
            var proposed = layout
            guard (try? proposed.relocate(source.paneID, beside: targetID, at: edge)) != nil else { return false }
            return fitsLayout(proposed)
        }
        return fitsSplit(beside: targetID, edge: edge)
    }

    @discardableResult
    func moveTab(_ id: UUID, from source: BrowserViewController, beside target: BrowserViewController,
                 edge: PaneDropEdge, dropFrame: NSRect? = nil) -> Bool {
        guard canMoveTab(id, from: source, beside: target.paneID, edge: edge),
              let index = source.tabs.firstIndex(where: { $0.id == id }) else { explainSplitRefusal(); return false }
        preparePaneTransition(source: source, tabID: id, edge: edge, dropFrame: dropFrame)
        preview.endSession()
        source.saveViewState()
        if source.tabs.count == 1 {
            paneTransition?.arrivingPaneID = source.paneID
            do { try layout.relocate(source.paneID, beside: target.paneID, at: edge) }
            catch { return false }
            rebuildPaneTree()
            activate(source)
        } else {
            let tab = source.tabs[index]
            let peer = BrowserViewController(settings: source.settings)
            peer.paneViewMode = source.isArchiveLocation ? source.paneViewMode : source.effectiveViewMode
            peer.folderViews = source.folderViews
            peer.tabs = [tab]; peer.activeID = tab.id
            do { try layout.split(target.paneID, inserting: peer.paneID, at: edge) }
            catch { return false }
            peer.smbTabs[id] = source.smbTabs.removeValue(forKey: id)
            peer.sftpTabs[id] = source.sftpTabs.removeValue(forKey: id)
            peer.archiveTabs[id] = source.archiveTabs.removeValue(forKey: id)
            peer.archiveTabs[id]?.rebind(to: peer)
            peer.sftpClosedUploadNotices[id] = source.sftpClosedUploadNotices.removeValue(forKey: id)
            peer.smbClosedUploadNotices[id] = source.smbClosedUploadNotices.removeValue(forKey: id)
            source.tabs.remove(at: index)
            if source.activeID == id { source.activeID = source.tabs[min(index, source.tabs.count - 1)].id; source.loadLocation() }
            else { source.tabStrip.update(tabs: source.tabs, activeID: source.activeID) }
            browsers[peer.paneID] = peer
            attachBrowser(peer)
            paneTransition?.arrivingPaneID = peer.paneID
            rebuildPaneTree()
            activate(peer)
            startBrowser(peer)
        }
        recordSession()
        return true
    }

    @discardableResult
    func moveTab(_ id: UUID, from source: BrowserViewController, into target: BrowserViewController, before beforeID: UUID?) -> Bool {
        guard source !== target, canChangePaneLayout, browsers[source.paneID] === source, browsers[target.paneID] === target,
              let index = source.tabs.firstIndex(where: { $0.id == id }),
              beforeID == nil || target.tabs.contains(where: { $0.id == beforeID }) else { return false }
        preparePaneTransition()
        preview.endSession()
        source.saveViewState(); target.saveViewState()
        let tab = source.tabs[index]
        let destination = beforeID.flatMap { before in target.tabs.firstIndex { $0.id == before } } ?? target.tabs.count
        target.tabs.insert(tab, at: destination)
        target.smbTabs[id] = source.smbTabs.removeValue(forKey: id)
        target.sftpTabs[id] = source.sftpTabs.removeValue(forKey: id)
        target.archiveTabs[id] = source.archiveTabs.removeValue(forKey: id)
        target.archiveTabs[id]?.rebind(to: target)
        target.sftpClosedUploadNotices[id] = source.sftpClosedUploadNotices.removeValue(forKey: id)
        target.smbClosedUploadNotices[id] = source.smbClosedUploadNotices.removeValue(forKey: id)
        target.activeID = tab.id
        if source.tabs.count == 1 {
            // Retirement still saves view state and releases native sessions.
            // Keep its last visit valid through that complete lifecycle.
            removePane(source)
            rebuildPaneTree()
        } else {
            source.tabs.remove(at: index)
            if source.activeID == id { source.activeID = source.tabs[min(index, source.tabs.count - 1)].id; source.loadLocation() }
            else { source.tabStrip.update(tabs: source.tabs, activeID: source.activeID) }
        }
        activate(target)
        target.loadLocation()
        recordSession()
        return true
    }

    private func removePane(_ browser: BrowserViewController) {
        // Layout was validated and the caller has another nonempty pane.
        do { try layout.remove(browser.paneID) } catch { return }
        invalidateVolumeRefresh(owner: browser)
        if activePaneID == browser.paneID { preview.endSession() }
        retireOperationHost(for: browser)
        browser.suspendBrowser()
        browser.view.removeFromSuperview()
        browser.removeFromParent()
        browsers.removeValue(forKey: browser.paneID)
        paneHosts.removeValue(forKey: browser.paneID)
        sidebarControllers.removeValue(forKey: browser.paneID)
        startedBrowsers.remove(browser.paneID)
        if primaryBrowser === browser, let replacement = layout.paneIDs.compactMap({ browsers[$0] }).first { primaryBrowser = replacement }
        requestInitialVolumeObservationIfNeeded()
    }

    func startBrowser(_ browser: BrowserViewController) {
        guard startedBrowsers.insert(browser.paneID).inserted else { return }
        #if DEBUG
        willStartBrowserForVerification?(browser)
        #endif
        browser.begin()
    }

    func applyRestoredSnapshot(_ snapshot: PaneWorkspaceSnapshot) throws {
        try snapshot.validate()
        invalidateVolumeRefresh()
        preview.setEnabled(false)
        inspectorHost.isHidden = true
        let settings = primaryBrowser.settings
        let sharedPins = primaryBrowser.pinsController
        let sharedAccess = primaryBrowser.folderAccess
        let sharedClipboard = primaryBrowser.clipboardState
        let sharedWriter = primaryBrowser.clipboardWriter
        let sharedHistory = primaryBrowser.operationHistory
        let sharedEngine = primaryBrowser.recoverableFileOperations
        let sharedNames = primaryBrowser.privateNames
        let sharedSidebarLayout = primaryBrowser.sidebarLayoutOwner
        let sharedFolderViews = primaryBrowser.folderViews
        let old = Array(browsers.values)
        for browser in old {
            retireOperationHost(for: browser)
            browser.suspendBrowser(); browser.view.removeFromSuperview(); browser.removeFromParent()
        }
        browsers = [:]; paneHosts = [:]; sidebarControllers = [:]; startedBrowsers = []
        for pane in snapshot.panes {
            let browser = BrowserViewController(settings: settings, paneID: pane.id)
            let tabs = try pane.tabs.restoredTabs()
            browser.tabs = tabs.tabs; browser.activeID = tabs.activeID
            browser.paneViewMode = BrowserViewMode(rawValue: pane.viewMode) ?? .details
            for index in browser.tabs.indices { browser.tabs[index].resolveFolderView(mode: browser.paneViewMode, sort: browser.tabs[index].sort) }
            browser.pinsController = sharedPins; browser.folderAccess = sharedAccess; browser.clipboardState = sharedClipboard
            browser.sidebarLayoutOwner = sharedSidebarLayout
            browser.clipboardWriter = sharedWriter; browser.operationHistory = sharedHistory; browser.recoverableFileOperations = sharedEngine
            browser.privateNames = sharedNames
            browser.folderViews = sharedFolderViews
            browsers[browser.paneID] = browser
        }
        guard let primary = browsers[snapshot.layout.paneIDs[0]] else { throw PaneLayout.Failure.invalidLayout }
        primaryBrowser = primary
        layout = snapshot.layout; activePaneID = snapshot.activePane
        for id in layout.paneIDs { if let browser = browsers[id] { attachBrowser(browser) } }
        rebuildPaneTree(animated: false)
        installSharedViews()
        sidebarSplit?.restore(snapshot.sidebar)
        updateSidebarRestorePresentation()
        enforceWindowMinimum(grow: true)
        onActiveBrowserChanged?(activeBrowser)
    }

    func rebuildPaneTree(animated: Bool = true) {
        guard isViewLoaded, !reconcilingPaneTree else { return }
        reconcilingPaneTree = true
        defer { reconcilingPaneTree = false }
        var retainedSplits = Set<UUID>()
        func build(_ id: UUID, size: NSSize) -> NSView {
            guard let node = layout.node(id) else { return NSView() }
            switch node.content {
            case .pane(let pane):
                let host = paneHosts[pane] ?? NSView()
                host.frame = NSRect(origin: .zero, size: size)
                return host
            case .split(let axis, let fraction, let first, let second):
                // Keep unchanged branches attached. Reparenting every native
                // glass host needlessly resets its backdrop during a split.
                let split = paneSplits[id] ?? WorkspaceSplitView(axis: axis, fraction: fraction,
                    firstMinimum: minimumSize(for: first), secondMinimum: minimumSize(for: second))
                paneSplits[id] = split; retainedSplits.insert(id)
                split.isVertical = axis == .columns
                split.fraction = fraction
                split.firstMinimum = minimumSize(for: first); split.secondMinimum = minimumSize(for: second)
                split.frame = NSRect(origin: .zero, size: size)
                let a = minimumSize(for: first), b = minimumSize(for: second)
                let available = max(0, (axis == .columns ? size.width : size.height) - split.dividerThickness)
                let firstLength = min(available - (axis == .columns ? b.width : b.height),
                    max(axis == .columns ? a.width : a.height, available * fraction))
                let sizes = axis == .columns
                    ? [NSSize(width: firstLength, height: size.height), NSSize(width: available - firstLength, height: size.height)]
                    : [NSSize(width: size.width, height: firstLength), NSSize(width: size.width, height: available - firstLength)]
                let children = [first, second].enumerated().map { index, child in build(child, size: sizes[index]) }
                for retired in split.arrangedSubviews where !children.contains(where: { $0 === retired }) {
                    split.removeArrangedSubview(retired); retired.removeFromSuperview()
                }
                for (index, child) in children.enumerated() {
                    if split.arrangedSubviews.indices.contains(index), split.arrangedSubviews[index] === child { continue }
                    // Set frame ownership before insertion: attaching a zero
                    // subtree to a live window otherwise solves its controls at zero.
                    child.translatesAutoresizingMaskIntoConstraints = true
                    child.autoresizingMask = []
                    if child.superview === split { split.removeArrangedSubview(child); child.removeFromSuperview() }
                    split.insertArrangedSubview(child, at: min(index, split.arrangedSubviews.count))
                }
                split.fraction = fraction
                split.resizeSubviews(withOldSize: split.bounds.size)
                split.onFractionChanged = { [weak self] value in
                    guard let self, !self.reconcilingPaneTree else { return }
                    try? self.layout.setFraction(value, for: id)
                    self.recordSession()
                }
                return split
            }
        }
        let minimum = minimumSize(for: layout.rootID)
        let tree = build(layout.rootID, size: NSSize(width: max(minimum.width, paneTreeHost.bounds.width),
            height: max(minimum.height, paneTreeHost.bounds.height)))
        if tree.superview !== paneTreeHost {
            paneTreeHost.subviews.forEach { $0.removeFromSuperview() }
            pin(tree, inside: paneTreeHost)
        }
        for (id, retired) in paneSplits where !retainedSplits.contains(id) { retired.removeFromSuperview() }
        paneSplits = paneSplits.filter { retainedSplits.contains($0.key) }
        for (index, id) in layout.paneIDs.enumerated() {
            paneHosts[id]?.isSplit = layout.paneIDs.count > 1
            paneHosts[id]?.isActive = id == activePaneID
            paneHosts[id]?.setAccessibilityLabel("Pane \(index + 1)" + (id == activePaneID ? ", active" : ""))
        }
        view.layoutSubtreeIfNeeded()
        enforceWindowMinimum(grow: animated)
        if animated, let transition = paneTransition {
            transition.play(to: paneHosts, in: paneTreeHost) { [weak self, weak transition] in
                guard let self, self.paneTransition === transition else { return }
                for host in self.paneHosts.values { host.alphaValue = 1 }
                self.paneTransition = nil
            }
        } else {
            paneTransition?.finish(); paneTransition = nil
        }
    }

    private func preparePaneTransition(source: BrowserViewController? = nil, tabID: UUID? = nil,
                                       edge: PaneDropEdge? = nil, dropFrame: NSRect? = nil) {
        paneTransition?.finish(); paneTransition = nil
        for host in paneHosts.values { host.alphaValue = 1 }
        for browser in browsers.values { browser.canvasTransition?.finish(); browser.canvasTransition = nil }
        guard primaryBrowser.settings.motion.allows(.panes) else { return }
        let transition = WorkspacePaneTransition()
        transition.mode = primaryBrowser.settings.motion.mode
        transition.capture(paneHosts, in: paneTreeHost) { browsers[$0]?.paneTransitionForeground ?? [] }
        guard !transition.frames.isEmpty else { return }
        if let source, let tabID, let edge,
           let tab = source.tabStrip.paneTransitionFrame(for: tabID, in: paneTreeHost) {
            transition.origin = .init(tab: tab, dropFrame: dropFrame, edge: edge)
        }
        paneTransition = transition
        // Failed/no-op commands cannot retain a visual capture indefinitely.
        Task { @MainActor [weak self, weak transition] in
            guard let self, let transition, self.paneTransition === transition, transition.superview == nil else { return }
            transition.finish(); self.paneTransition = nil
        }
    }

    func applyMotionPreferences(_ value: BrowserMotionPreferences) {
        if sidebarSplit?.motion != value {
            sidebarSplit?.motion = value
            sidebarSplit?.finishAnimation()
        }
        guard !value.allows(.panes) || paneTransition?.mode != value.mode else { return }
        paneTransition?.finish(); paneTransition = nil
        for host in paneHosts.values { host.alphaValue = 1 }
    }

    func updateChromeBackdrop() {
        let settings = primaryBrowser.settings
        sharedChromeBackdrop.isHidden = settings.navigationStyle != .glass
            || !(settings.glassNavigation || settings.glassSidebar || settings.glassStatusBar || settings.glassFileContent)
    }

    private func installSharedViews() {
        guard isViewLoaded else { return }
        applyInitialVolumeObservationHint(to: activeBrowser)
        if let oldRow = operationButton.superview as? NSStackView { oldRow.removeArrangedSubview(operationButton) }
        operationButton.removeFromSuperview()
        if let oldRow = sidebarRestoreButton.superview as? NSStackView { oldRow.removeArrangedSubview(sidebarRestoreButton) }
        sidebarRestoreButton.removeFromSuperview()
        for host in [sidebarHost, activeFooterHost, pathHost] { host.subviews.forEach { $0.removeFromSuperview() } }
        if let sidebar = sidebarControllers[activePaneID]?.view { pin(sidebar, inside: sidebarHost) }
        if let footer = activeBrowser.statusSurface { pin(footer, inside: activeFooterHost) }
        activeBrowser.statusRow?.insertArrangedSubview(sidebarRestoreButton, at: 0)
        updateSidebarRestorePresentation()
        if let row = activeBrowser.statusRow,
           let index = row.arrangedSubviews.firstIndex(of: activeBrowser.viewModeControl) {
            row.insertArrangedSubview(operationButton, at: index)
        }
        pathHost.isHidden = true
        activeBrowser.footerOperationButton.isHidden = true
    }

    private func fitsSplit(beside paneID: UUID, edge: PaneDropEdge) -> Bool {
        var proposed = layout
        guard (try? proposed.split(paneID, inserting: UUID(), at: edge)) != nil else { return false }
        return fitsLayout(proposed)
    }
    private func fitsLayout(_ proposed: PaneLayout) -> Bool {
        view.layoutSubtreeIfNeeded()
        let minimum = minimumSize(for: proposed.rootID, in: proposed)
        if let window = view.window, let screen = window.screen {
            let chromeHeight = window.frame.height - window.contentLayoutRect.height
            guard Self.fits(minimum: NSSize(width: minimum.width + sidebarReservation + (preview.isEnabled ? 301 : 0),
                                           height: minimum.height + InterfaceMetrics.points(40 + (primaryBrowser.settings.showsPathBar ? 26 : 0)) + chromeHeight),
                            in: screen.visibleFrame.size) else { return false }
        }
        return Self.fits(minimum: minimum, in: paneTreeHost.bounds.size)
    }
    static func fits(minimum: NSSize, in available: NSSize) -> Bool {
        minimum.width <= available.width && minimum.height <= available.height
    }
    private var sidebarReservation: CGFloat { sidebarSplit?.reservedWidth ?? 201 }
    var minimumWorkspaceSize: NSSize { workspaceMinimum(previewEnabled: preview.isEnabled) }
    private func workspaceMinimum(previewEnabled: Bool, sidebarCollapsed: Bool? = nil) -> NSSize {
        let minimum = minimumSize(for: layout.rootID)
        let sidebar = (sidebarCollapsed ?? isSidebarCollapsed) ? 0 : (sidebarSplit?.sidebarWidth ?? 200) + 1
        // Reserve the expanded operation row even while it is hidden so a job
        // starting at minimum size cannot shrink the smallest pane below its limit.
        return NSSize(width: max(820, minimum.width + sidebar + (previewEnabled ? 301 : 0)),
                      height: max(500, minimum.height + InterfaceMetrics.points(40 + (primaryBrowser.settings.showsPathBar ? 26 : 0))))
    }
    private func enforceWindowMinimum(grow: Bool) {
        guard let window = view.window else { return }
        let minimum = minimumWorkspaceSize
        let chromeHeight = window.frame.height - window.contentLayoutRect.height
        if let screen = window.screen,
           minimum.width > screen.visibleFrame.width || minimum.height + chromeHeight > screen.visibleFrame.height {
            activeBrowser.status.stringValue = "This pane layout needs more screen space. Close a pane or hide Preview."
            return
        }
        let inset = max(0, (window.contentView?.bounds.height ?? window.contentLayoutRect.height) - window.contentLayoutRect.height)
        let contentMinimum = NSSize(width: minimum.width, height: minimum.height + inset)
        window.contentMinSize = contentMinimum
        if grow, let content = window.contentView, content.bounds.width < contentMinimum.width || content.bounds.height < contentMinimum.height {
            window.setContentSize(NSSize(width: max(content.bounds.width, contentMinimum.width), height: max(content.bounds.height, contentMinimum.height)))
            if let screen = window.screen {
                var frame = window.frame
                frame.origin.x = min(max(frame.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, screen.visibleFrame.minY), screen.visibleFrame.maxY - frame.height)
                window.setFrame(frame, display: true)
            }
        }
    }
    private func explainSplitRefusal() {
        activeBrowser.status.stringValue = browsers.count >= PaneLayout.maximumPanes
            ? "A workspace supports up to four panes. Move a tab into an existing pane instead."
            : "There is not enough room to split this pane. Enlarge the window or choose a different edge."
    }
    private func minimumSize(for id: UUID) -> NSSize { minimumSize(for: id, in: layout) }
    private func minimumSize(for id: UUID, in proposed: PaneLayout) -> NSSize {
        guard let node = proposed.node(id) else { return NSSize(width: 400, height: 220) }
        switch node.content {
        case .pane: return NSSize(width: 400, height: 220)
        case .split(let axis, _, let first, let second):
            let left = minimumSize(for: first, in: proposed), right = minimumSize(for: second, in: proposed)
            return axis == .columns ? NSSize(width: left.width + right.width + 1, height: max(left.height, right.height))
                : NSSize(width: max(left.width, right.width), height: left.height + right.height + 1)
        }
    }
}

@MainActor
private final class WorkspaceSplitView: NSSplitView, NSSplitViewDelegate {
    var firstMinimum: NSSize
    var secondMinimum: NSSize
    var fraction: Double
    var onFractionChanged: ((Double) -> Void)?
    private var positioning = false
    // AppKit converts drag-image coordinates concurrently. This invariant
    // reads no view state; mutable layout and delegate work stay on MainActor.
    nonisolated override var isFlipped: Bool { true }
    init(axis: PaneSplitAxis, fraction: Double, firstMinimum: NSSize, secondMinimum: NSSize) {
        self.fraction = fraction; self.firstMinimum = firstMinimum; self.secondMinimum = secondMinimum
        super.init(frame: .zero)
        isVertical = axis == .columns
        dividerStyle = .thin
        delegate = self
    }
    required init?(coder: NSCoder) { nil }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard subviews.count == 2 else { return }
        positioning = true
        defer { positioning = false }
        let available = max(0, (isVertical ? bounds.width : bounds.height) - dividerThickness)
        let minimum = isVertical ? firstMinimum.width : firstMinimum.height
        let other = isVertical ? secondMinimum.width : secondMinimum.height
        let first = available >= minimum + other ? min(available - other, max(minimum, available * fraction)) : available * fraction
        if isVertical {
            subviews[0].frame = NSRect(x: 0, y: 0, width: first, height: bounds.height)
            subviews[1].frame = NSRect(x: first + dividerThickness, y: 0, width: max(0, available - first), height: bounds.height)
        } else {
            subviews[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: first)
            subviews[1].frame = NSRect(x: 0, y: first + dividerThickness, width: bounds.width, height: max(0, available - first))
        }
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, isVertical ? firstMinimum.width : firstMinimum.height)
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, (isVertical ? bounds.width - secondMinimum.width : bounds.height - secondMinimum.height) - dividerThickness)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !positioning, subviews.count == 2 else { return }
        let available = (isVertical ? bounds.width : bounds.height) - dividerThickness
        guard available > 0 else { return }
        fraction = min(0.9, max(0.1, Double(isVertical ? subviews[0].frame.width : subviews[0].frame.height) / available))
        onFractionChanged?(fraction)
    }
}
