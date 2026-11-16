import AppKit
import Combine
import ExplorerCore
import LocalStorage
import FileOperations
import SwiftUI

@MainActor
final class BrowserViewController: NSViewController {
    let settings: BrowserSettings
    let paneID: UUID
    weak var workspace: BrowserWorkspaceController?
    var paneViewMode: BrowserViewMode
    var effectiveViewMode: BrowserViewMode { location.isRemote || location.isArchive ? .details : tabs[activeIndex].presentationMode ?? (workspace == nil ? settings.viewMode : paneViewMode) }
    lazy var folderViews: ApplicationFolderViews = isVerificationSession || isReadOnlyFileSession
        ? ApplicationFolderViews(store: FolderViewStore(directory: nil)) : .shared
    var folderViewRevision = UUID()
    var showsComputerVolumes: Bool { location == .computer && !metadataSearch.isShowingResults }
    lazy var metadataSearch = BrowserSearchController(browser: self)
    lazy var inlineRename = BrowserInlineRenameController(browser: self)
    lazy var selectionGroupDraft = BrowserSelectionGroupDraftController(browser: self)
    var isActiveCommandPane: Bool { workspace.map { $0.activeBrowser === self } ?? true }
    var paneBody: NSStackView?
    lazy var pinsController = BrowserPinsController(stateDirectory: isVerificationSession ? nil : developmentStateDirectory)
    // Share one layout owner per private profile before view loading.
    lazy var sidebarLayoutOwner = BrowserSidebarLayoutRegistry.controller(directory: isVerificationSession ? nil : developmentStateDirectory)
    lazy var sidebarLayout = BrowserSidebarLayoutAdapter(browser: self, owner: sidebarLayoutOwner)
    lazy var savedServerLocations = SavedServerLocations.controller(directory: isVerificationSession ? nil : developmentStateDirectory)
    lazy var connectionService = ApplicationSMBConnections.shared
    var disconnectedServerSnapshot: [WorkspaceConnectionBookmark] = []
    let pinnedSidebar = BrowserPinnedSidebar()
    var connectionProperties: ConnectionPropertiesController?
    var addressEditingContext: BrowserAddressEditingContext?
    let fileSystem = LocalFileSystem(activityGate: ApplicationFileActivity.gate)
    let ordering = RowOrdering()
    var tabs: [BrowserTab]
    var smbTabs: [UUID: SMBTabController] = [:]
    let smbHost = NSView()
    var sftpTabs: [UUID: SFTPTabController] = [:]
    var archiveTabs: [UUID: ArchiveTabController] = [:]
    let archiveHost = ArchiveFocusHost()
    var isArchiveLocation: Bool { location.isArchive }
    #if DEBUG
    var reconnectPresenterForVerification: ((WorkspaceReconnectTarget) -> Void)?
    var defaultOpenForVerification: ((URL) -> Bool)?
    #endif
    var sftpClosedUploadNotices: [UUID: RemoteClosedTransferNotice] = [:]
    let sftpHost = NSView()
    var isSFTPLocation: Bool { if case .sftp = location { true } else { false } }
    var isRemoteLocation: Bool { location.isRemote }
    var isSMBLocation: Bool { if case .smb = location { true } else { false } }
    var activeID: UUID
    /// Native editor end/selection notifications may reenter persistence while
    /// a new logical visit is replacing the previously visible surface.
    var isInstallingLocation = false
    var closedTabs: [ClosedBrowserTab] = []
    var activeIndex: Int { tabs.firstIndex { $0.id == activeID } ?? 0 }
    var location: BrowserLocation { tabs[activeIndex].location }
    var isControlledVerification: Bool {
        #if DEBUG
        isVerificationSession && ProcessInfo.processInfo.arguments.contains("--offscreen")
        #else
        false
        #endif
    }

    let tabStrip = TabStripView()
    var navigationSurface: NavigationGlassSurface?
    var sidebarSurface: NavigationGlassSurface?
    var contentSurface: NavigationGlassSurface?
    var statusSurface: NavigationGlassSurface?
    var statusRow: NSStackView?
    var addressLayout: BrowserAddressLayout?
    let pathControl = ExplorerPathControl()
    lazy var quickLook = BrowserQuickLookController(browser: self)
    lazy var openAndShare = BrowserOpenAndShareController(browser: self)
    lazy var dragDrop = BrowserDragDropController(browser: self)
    lazy var paneTransfers = BrowserPaneTransfers(browser: self)
    lazy var sftpDownload = BrowserSFTPDownload(browser: self)
    lazy var remoteBatchDownload = BrowserRemoteBatchDownload(browser: self)
    lazy var smbDownload = BrowserSMBDownload(browser: self)
    lazy var smbFolderDownload = BrowserSMBFolderDownload(browser: self)
    lazy var sftpFolderDownload = BrowserSFTPFolderDownload(browser: self)
    lazy var sftpUpload = BrowserSFTPUpload(browser: self)
    lazy var sftpNewFile = BrowserSFTPNewFile(browser: self)
    lazy var smbUpload = BrowserSMBUpload(browser: self)
    lazy var smbNewItems = BrowserSMBNewItems(browser: self)
    var smbClosedUploadNotices: [UUID: RemoteClosedTransferNotice] = [:]
    lazy var sftpFolderUpload = BrowserSFTPFolderUpload(browser: self)
    lazy var sftpPaneUpload = BrowserSFTPPaneUpload(browser: self)
    lazy var sftpDropUpload = BrowserSFTPDropUpload(browser: self)
    lazy var sftpFileActions = BrowserSFTPFileActions(browser: self)
    lazy var smbFileActions = BrowserSMBFileActions(browser: self)
    lazy var pinDrop = BrowserPinDrop(browser: self)
    var breadcrumbLocations: [BrowserLocation] = []
    let pathField = NSTextField()
    lazy var addressCompletion = BrowserAddressCompletionController(browser: self)
    let pathContainer = BrowserAddressRow()
    var navigationButtons: [(NSButton, Selector)] = []
    let filterField = NSSearchField()
    lazy var folderFilter = BrowserLocalFilterController(browser: self)
    lazy var commandFinder = CommandFinderController(browser: self)
    let outline = BrowserSidebarOutlineView()
    let table = FileTableView()
    var detailsHeader: NSTableHeaderView?
    let folderScroll = NSScrollView()
    let iconBrowser = FileIconBrowserView()
    var presentedFileViewMode = BrowserViewMode.details
    var filePresentationID = UUID()
    let volumeBrowser = VolumeBrowserView()
    var computerScroll: NSScrollView { volumeBrowser.scrollView }
    let overlay = NSView()
    let overlayTitle = label("Loading…", size: 18, weight: .semibold)
    let overlayDetail = label("", size: 13, color: .secondaryLabelColor)
    let overlayActions = NSStackView()
    var overlayPrivacyAction: NSButton?
    var overlayDriveAction: NSButton?
    var accessDiagnostic: FolderAccessDiagnostic?
    lazy var folderAccess = FolderAccessController(stateDirectory: isVerificationSession ? nil : developmentStateDirectory)
    var rememberedFolders: [FolderAccessRestoreResult] = []
    lazy var sessionPersistence = BrowserSessionController(stateDirectory: isVerificationSession ? nil : developmentStateDirectory)
    let rememberedFolderSidebar = RememberedFolderSidebar()
    let directoryMonitor = DirectoryMonitor(activityGate: ApplicationFileActivity.gate)
    lazy var folderSummary = BrowserFolderSummaryController(browser: self)
    var directoryObservation: DirectoryObservation?
    /// Exact access already acquired for the successfully listed visit. Hover
    /// may retain it, but must never activate another saved/bookmarked grant.
    var summaryBrowsingAccess: FileAccessLifetimes?
    var directoryRefreshTask: Task<Void, Never>?
    var directoryRefreshPending = false
    var isBackgroundRefreshing = false
    private var isBrowserClosed = false
    var isBrowserSuspended: Bool {
        get { isBrowserClosed || ApplicationFileActivity.gate.isClosed }
        set {
            isBrowserClosed = newValue
            if newValue { sidebarLayout.invalidate() }
        }
    }
    var browserObservers: [BrowserNotificationObservation] = []
    var fileOperations = LocalFileOperations(activity: ApplicationFileActivity.beginOperation)
    let operationCoordinator = ApplicationOperationCoordinator.shared
    var privateNames = ApplicationPrivateNames.shared { didSet { if isViewLoaded { installPrivateNamesAttention() } } }
    var privateNamesAttentionObservation: AnyCancellable?
    var privateNamesSheet: PrivateNamesSheet?
    lazy var recoverableFileOperations: RecoverableFileOperations? = {
        // Cold SMB Saved Versions needs the history context, not persistent
        // local browsing, pins, folder grants or workspace restoration.
        let historyRoot = GeneratedSandboxReview.smbOriginalSaveReviewAdmitted
            ? AppStorageLocations.stateDirectory : developmentStateDirectory
        guard !isVerificationSession,
              !isReadOnlyFileSession || GeneratedSandboxReview.smbOriginalSaveReviewAdmitted
                  || GeneratedSandboxReview.retainedEditorReadOnlyAdmitted,
              let directory = historyRoot else { return nil }
        return operationCoordinator.engine(at: directory.appendingPathComponent("operation-recovery", isDirectory: true))
    }()
    var recoveryRecords: [OperationRecoveryRecord] = []
    var refusedRecoveryEntries: [URL] = []
    var recoveryNextCursor: UUID?
    var recoveryUnfinishedCount = 0
    var recoveryHistoryReadiness: OperationHistoryReadiness = .absent
    var recoveryInspectionTask: Task<Void, Never>?
    #if DEBUG
    var beforeRecoveryInspectionReturnsForVerification: (@MainActor () async -> Void)?
    var beforeSelectionGroupPerformForVerification: (@MainActor () async -> Void)?
    var beforeSelectionGroupReviewActionForVerification: (@MainActor () async -> Void)?
    var operationFolderAccessRequestForVerification: ((URL?) -> Void)?
    var requiresUndoFolderSelectionForVerification = false
    var undoFolderSelectionForVerification: ((URL) async -> FolderAccessChoice?)?
    #endif
    var recoveryWindow: OperationRecoveryWindowController?
    lazy var ownedTrash = BrowserOwnedTrash(browser: self)
    var groupedCopyRecoveryWindow: GroupedCopyRecoveryWindowController?
    var selectionGroupWindow: SelectionGroupResultsWindow?
    var retentionInspectionTask: Task<Void, Never>?
    var operationDiagnosticTrace: UUID?
    var completedOperationDiagnosticTrace: UUID?
    var retentionInspectionID: UUID?
    #if DEBUG
    var beforeRetentionInspectionForVerification: (@MainActor () async -> Void)?
    #endif
    var retentionRecords: [RecoveryRetentionRecord] = []
    var operationHistory = BrowserOperationHistory()
    var lastRecoveryRecordID: UUID? { get { operationHistory.recoveryRecordID } set { operationHistory.recoveryRecordID = newValue } }
    var transferConflictPrompt: (([TransferConflict]) async -> [UUID: TransferConflictResolution]?)?
    var transferMetadataPrompt: ((TransferMetadataPolicy) async -> TransferMetadataPolicy?)?
    var operationTask: Task<Void, Never>?
    var operationPreparationTask: Task<Void, Never>?
    var operationPreparationID: UUID?
    var clipboardState = BrowserClipboardState()
    var presentedScopedItemID: UUID?
    var cutPreparationTask: Task<Void, Never>? { get { clipboardState.cutPreparation } set { clipboardState.cutPreparation = newValue } }
    var clipboardRevision: UUID { get { clipboardState.revision } set { clipboardState.revision = newValue } }
    var pendingCut: FileOperationSelection? { get { clipboardState.pendingCut } set { clipboardState.pendingCut = newValue } }
    var pendingCutChangeCount: Int? { get { clipboardState.pendingCutChangeCount } set { clipboardState.pendingCutChangeCount = newValue } }
    var cutURLs: Set<URL> { get { clipboardState.cutURLs } set { clipboardState.cutURLs = newValue } }
    var transferPasteboard: NSPasteboard { get { clipboardState.pasteboard } set { clipboardState.pasteboard = newValue } }
    var transferFeedback: TransferClipboardFeedback? { get { clipboardState.feedback } set { clipboardState.feedback = newValue } }
    var transferClipboardTask: Task<Void, Never>? { get { clipboardState.observationTask } set { clipboardState.observationTask = newValue } }
    var lastOperationResult: FileOperationResult? { get { operationHistory.lastResult } set { operationHistory.lastResult = newValue } }
    var lastRecoveryAction: CopyRecoveryAction? { get { operationHistory.recoveryAction } set { operationHistory.recoveryAction = newValue } }
    var lastTransferContinuation: TransferContinuation? { get { operationHistory.continuation } set { operationHistory.continuation = newValue } }
    var continuationMoveClipboard: MoveClipboardContext? { get { operationHistory.moveClipboard } set { operationHistory.moveClipboard = newValue } }
    var operationNamePrompt: ((String, String) async -> String?)?
    var operationConflictPrompt: (([URL]) async -> Bool)?
    var operationTrashPrompt: ((Int) async -> Bool)?
    var operationResultPresenter: ((FileOperationResult) -> Void)?
    var operationErrorPresenter: ((String) -> Void)?
    #if DEBUG
    var queuedTransferStatusPresentedForVerification: ((UUID, String) -> Void)?
    // Explicit offscreen verification bypasses only foreground command gating.
    // It does not establish native focus/input delivery or privacy permission.
    var permitsBackgroundVerification = false
    #endif
    let footerOperationButton = OperationProgressButton(frame: .zero)
    let navigationOperationButton = OperationProgressButton(frame: .zero)
    let operationDetailsContainer = OperationProgressCardSurface(frame: .zero)
    let operationDetails = OperationProgressDetailsView(frame: .zero)
    let transferQueueDetails = TransferQueueInspectionView(frame: .zero)
    var operationFooterHeight: NSLayoutConstraint?
    var operationPresentationID: UUID?
    var operationPresentation: OperationProgressPresentation?
    var operationProgressMailbox: OperationProgressMailbox?
    var operationProgressTask: Task<Void, Never>?
    var operationProgressSink: (@Sendable (OperationProgress) -> Void)?
    var operationProgressState = OperationProgressState()
    var operationStopRequested = false
    var listedItemPropertiesController: ListedItemPropertiesController?
    lazy var propertiesController = FilePropertiesWindowController(retainAccess: { [weak self] urls in
        await self?.accessLifetime(for: urls)
    }, settings: settings, namesOwner: privateNames, copyPaths: { [weak self] urls in
        _ = self?.clipboardWriter(urls.map(\.path).joined(separator: "\n"), [])
    })
    let status = label("", size: 12, color: .secondaryLabelColor)
    lazy var driveStatus = DriveStatusControl(browser: self)
    lazy var connectionIndicator = ConnectionStatusControl { [weak self] in self?.reconnectFromConnectionStatus(nil) }
    var reconnectAfterDisconnect: ConnectionReconnectIntent?
    let clipboardStatus = ClipboardFeedbackView(frame: .zero)
    let operationResultsButton = NSButton(title: "Results", target: nil, action: nil)
    let recoveryAttentionButton = NSButton(title: "Recovery needs attention", target: nil, action: nil)
    let privateNamesAttentionButton = NSButton(title: "Saved Names", target: nil, action: nil)
    let viewModeControl = NSSegmentedControl()
    let loadingIndicator = NSProgressIndicator()
    let splitController = NSSplitViewController()
    var sidebarRoots: [SidebarNode] = []
    var connectedLocationSnapshot: [BrowserConnectedLocation] = []
    var displayedEntries: [FileEntry] = []
    var rowsByURL: [URL: Int] = [:]
    var rawEntries: [FileEntry] = []
    var recordsNextExplicitVisit = false
    var volumes: [VolumeInfo] = []
    var listingTask: Task<Void, Never>?
    var orderingTask: Task<Void, Never>?
    var sidebarTasks: [Task<Void, Never>] = []
    var sessionID = UUID()
    var orderRevision = 0
    var isLoading = false
    var folderLoadingFeedbackTask: Task<Void, Never>?
    var folderLoadingFeedbackDeadline = 0.0
    var canvasTransition: BrowserCanvasTransition?
    var loadError: String?
    var issueCount = 0
    var updatingSelection = false
    var updatingSortIndicators = false
    var updatingSidebarSelection = false
    var restoringScroll = true
    var subscriptions: Set<AnyCancellable> = []
    var settingsWindow: NSWindow?
    var volumeObservers: [BrowserNotificationObservation] = []
    var volumeSessionID = UUID()
    #if DEBUG
    var queueRevisionCallbacksPendingForVerification = 0
    var operationProgressRendersForVerification = 0
    var beforeBeginReferencesForVerification: (() async -> Void)?
    var didFinishBeginForVerification: (() -> Void)?
    var readVolumesForVerification: (() async throws -> [VolumeInfo])?
    #endif
    var loadStarted = Date()
    var lastOrderRequest = Date.distantPast
    var firstRowsMilliseconds: Double?
    var enumerationMilliseconds: Double?
    var completeDisplayMilliseconds: Double?
    var clipboardWriter: (String?, [URL]) -> BrowserClipboard.Publication = { text, urls in
        BrowserClipboard.publish(text, urls: urls)
    }

    init(settings: BrowserSettings, paneID: UUID = UUID()) {
        self.settings = settings
        self.paneID = paneID
        paneViewMode = settings.viewMode
        let tab = BrowserTab(location: .computer)
        tabs = [tab]
        activeID = tab.id
        super.init(nibName: nil, bundle: nil)
        operationCoordinator.register(self)
        privateNames.configure(self)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        // Child split controllers may lay themselves out during construction.
        // Give them a real initial allocation before the containing window or
        // workspace installs the final frame.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1140, height: 760))
        buildAddressRow()
        buildContent()
        table.onShortcut = { [weak self] in self?.routeBrowserShortcut($0) ?? false }
        iconBrowser.collectionView.onShortcut = { [weak self] in self?.routeBrowserShortcut($0) ?? false }
        volumeBrowser.collectionView.onShortcut = { [weak self] in self?.routeBrowserShortcut($0) ?? false }
        volumeBrowser.onLocationMenu = { [weak self] in self?.locationMenu(for: $0) }
        volumeBrowser.onDriveMenu = { [weak self] in self?.driveMenu(for: $0) }
        volumeBrowser.connectedServers.onOpen = { [weak self] in self?.focusConnectedLocation($0) }
        volumeBrowser.connectedServers.onOpenSaved = { [weak self] in self?.openSavedServer($0) }
        let connectionMenu: (BrowserConnectionIdentity) -> NSMenu? = { [weak self] identity in
            guard let self, let value = self.connectedLocationSnapshot.first(where: { $0.id == identity }) else { return nil }
            return self.connectedLocationMenu(value)
        }
        volumeBrowser.connectedServers.onMenu = connectionMenu
        volumeBrowser.connectedServers.onSavedMenu = { [weak self] in self?.savedServerMenu($0) }
        outline.onConnectionMenu = connectionMenu
        outline.onSavedServerMenu = { [weak self] in self?.savedServerMenu($0) }
        outline.onLocationMenu = { [weak self] in self?.locationMenu(for: $0) }
        outline.onRemotePinMenu = { [weak self] in self?.remotePinMenu($0) }
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false
        viewModeControl.segmentCount = BrowserViewMode.allCases.count
        viewModeControl.trackingMode = .selectOne
        viewModeControl.segmentStyle = .separated
        viewModeControl.controlSize = .small
        viewModeControl.target = self
        viewModeControl.action = #selector(changeViewFromControl(_:))
        viewModeControl.setAccessibilityLabel("File view")
        for (index, mode) in BrowserViewMode.allCases.enumerated() {
            viewModeControl.setImage(symbol(mode.symbolName, mode.rawValue), forSegment: index)
            viewModeControl.setToolTip(mode.rawValue, forSegment: index)
            viewModeControl.setWidth(28, forSegment: index)
        }
        let flexible = NSView()
        flexible.setContentHuggingPriority(.defaultLow, for: .horizontal)
        clipboardStatus.isHidden = true
        clipboardStatus.lineBreakMode = .byTruncatingTail
        clipboardStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        operationResultsButton.target = self
        operationResultsButton.action = #selector(showLastOperationResult(_:))
        operationResultsButton.bezelStyle = .recessed
        operationResultsButton.image = symbol("list.clipboard", "Last operation results")
        operationResultsButton.imagePosition = .imageLeading
        operationResultsButton.toolTip = "Inspect the last operation's individual results"
        operationResultsButton.setAccessibilityLabel("Last operation results")
        operationResultsButton.isHidden = true
        if !isVerificationSession { operationCoordinator.drives.startDiscovery() }
        recoveryAttentionButton.target = self
        recoveryAttentionButton.action = #selector(showOperationRecovery(_:))
        recoveryAttentionButton.bezelStyle = .recessed
        recoveryAttentionButton.image = symbol("exclamationmark.circle", "Recovery needs attention")
        recoveryAttentionButton.imagePosition = .imageLeading
        recoveryAttentionButton.contentTintColor = .systemOrange
        recoveryAttentionButton.isHidden = true
        installPrivateNamesAttention()
        let footer = stack([loadingIndicator, connectionIndicator, status, flexible, clipboardStatus, privateNamesAttentionButton, recoveryAttentionButton, operationResultsButton, footerOperationButton, driveStatus, viewModeControl], orientation: .horizontal)
        statusRow = footer
        footer.edgeInsets = NSEdgeInsets(top: 3, left: 14, bottom: 3, right: 14)
        let tabs = addressLayout!.tabRow
        let navigation = stack([tabs, pathContainer, metadataSearch.view], orientation: .vertical, spacing: 0)
        navigation.alignment = .leading
        for child in [tabs, pathContainer, metadataSearch.view] { child.widthAnchor.constraint(equalTo: navigation.widthAnchor).isActive = true }
        let surface = NavigationGlassSurface(contentView: navigation)
        // Visible arranged rows determine the surface's height atomically.
        // Updating a separate 78/118 constraint after hiding Search leaves an
        // intermediate layout with contradictory required heights.
        metadataSearch.onVisibilityChanged = { [weak self] in
            guard let self else { return }
            self.view.needsLayout = true
        }
        navigationSurface = surface
        let footerSurface = NavigationGlassSurface(contentView: footer)
        operationFooterHeight = footerSurface.heightAnchor.constraint(equalToConstant: 28).interfaceScaled
        operationFooterHeight?.isActive = true
        statusSurface = footerSurface
        let body = stack([surface, splitController.view, addressLayout!.bottomSurface, footerSurface], orientation: .vertical, spacing: 0)
        paneBody = body
        body.distribution = .fill
        body.alignment = .leading
        splitController.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        splitController.view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        for child in body.arrangedSubviews { child.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        pin(body, inside: view, belowTitlebar: workspace == nil)
        buildOperationDetails()
        tabStrip.onNew = { [weak self] in self?.newTab(nil) }
        tabStrip.onSelect = { [weak self] in self?.selectTab($0) }
        tabStrip.onAccessibleActivation = { [weak self] id in
            guard let self, self.tabs.contains(where:{$0.id == id}) else { return false }
            return self.prepareAccessibleBrowsingInteraction()
        }
        tabStrip.onClose = { [weak self] in self?.closeTab(id: $0) }
        tabStrip.onDuplicate = { [weak self] in self?.duplicateTab(id: $0) }
        tabStrip.onReopenClosed = { [weak self] in self?.reopenClosedTab() }
        tabStrip.onMove = { [weak self] in self?.moveTab(id: $0, before: $1) }
        tabStrip.canManageTabs = { [weak self] in self?.canManageBrowserTabs ?? false }
        tabStrip.canCreateTab = { [weak self] in self?.canOpenBrowserTab ?? false }
        tabStrip.canReopenClosed = { [weak self] in
            guard let self else { return false }
            return self.canManageBrowserTabs && !self.closedTabs.isEmpty
        }
        dragDrop.configureDestinationViews()
        connectSidebarLayout()
        table.onOpen = { [weak self] in self?.openSelection(nil) }
        table.onBack = { [weak self] in self?.goBack(nil) }
        table.onCopy = { [weak self] in self?.copyFileURLs(nil) }
        table.onCut = { [weak self] in self?.cutFileURLs(nil) }
        table.onPaste = { [weak self] in self?.pasteFileURLs(nil) }
        table.nameClickRenameEnabled = { [weak self] in self?.settings.renamesSelectedNameOnClick == true }
        table.onRename = { [weak self] in self?.renameSelection(nil) }
        table.onTrash = { [weak self] in self?.trashSelection(nil) }
        table.onQuickLook = { [weak self] in self?.showQuickLook(nil) }
        table.onUndo = { [weak self] in self?.undoFileOperation(nil) }
        table.quickLookController = quickLook
        table.commandValidation = { [weak self] action in self?.fileResponderCommandEnabled(action) ?? false }
        configureFileIconPresentation()
        volumeBrowser.onOpen = { [weak self] url in
            self?.navigate(to: .directory(url))
            self?.focusBrowserContent()
        }
        volumeBrowser.onAccessibleActivation = { [weak self] in self?.prepareAccessibleBrowsingInteraction() ?? false }
        volumeBrowser.onBack = { [weak self] in self?.goBack(nil) }
        volumeBrowser.onCopy = { [weak self] in self?.copyFileURLs(nil) }
        volumeBrowser.onSelectionChange = { [weak self] in
            guard let self, self.showsComputerVolumes, !self.updatingSelection else { return }
            self.tabs[self.activeIndex].state.selection = self.selectedURLs
            self.recordBrowserSession()
            self.refreshStatus()
        }
        volumeBrowser.onCopyPath = { [weak self] urls in _ = self?.clipboardWriter(urls.map(\.path).joined(separator: "\n"), []) }
        volumeBrowser.onProperties = { [weak self] _ in self?.showProperties(nil) }
        connectPreferences()
        connectPins()
        if clipboardState.didChange == nil {
            // Standalone browser hosts also observe clipboard expiry. A real
            // workspace replaces this with its fan-out once all panes attach.
            clipboardState.didChange = { [weak self] in
                guard let self else { return }
                self.renderTransferFeedback()
                self.reloadFileRows(preserving: self.selectedURLs)
            }
        }
        configureAddressLayoutPreference()
        connectDisplayPreferences()
        InterfacePresentation.shared.register(view)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            browserObservers.append(BrowserNotificationObservation(name: name) { [weak self] notification in
                // The wrapper delivers on OperationQueue.main. A Settings or
                // another browser window must not revalidate this toolbar.
                let observedWindow = (notification.object as? NSWindow).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, let window = self.viewIfLoaded?.window,
                          observedWindow == ObjectIdentifier(window) else { return }
                    Task { @MainActor [weak self, weak window] in
                        guard let self, let window, self.viewIfLoaded?.window === window else { return }
                        self.validateNavigationButtons()
                        if name == NSWindow.didBecomeKeyNotification { self.addressCompletion.resumeIfEditing() }
                    }
                }
            })
        }
        updateMaterialSurfaces()
        for scroll in [folderScroll, iconBrowser.scrollView] {
            scroll.contentView.postsBoundsChangedNotifications = true
            browserObservers.append(BrowserNotificationObservation(name: NSView.boundsDidChangeNotification,
                object: scroll.contentView) { [weak self, weak scroll] _ in
                    Task { @MainActor [weak self, weak scroll] in
                        guard let self, let scroll, self.activeFileScrollView === scroll,
                              !self.updatingSelection, !self.restoringScroll else { return }
                        self.recordBrowserSession()
                    }
                })
        }
        browserObservers.append(BrowserNotificationObservation(center: NSWorkspace.shared.notificationCenter,
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateMaterialSurfaces() }
            })
        updateNavigation()
        _ = folderSummary
    }

    func begin() {
        // Folder-reference restoration can wait for macOS access before volume
        // discovery starts. Do not present that interval as an empty machine.
        if location == .computer { isLoading = true }
        Task { [weak self] in
            guard let self else { return }
            #if DEBUG
            defer { self.didFinishBeginForVerification?() }
            #endif
            let initialVisit = self.sessionID
            let restoresSession = self.settings.restoresSession
            #if DEBUG
            if let barrier = self.beforeBeginReferencesForVerification { await barrier() }
            #endif
            await self.refreshRememberedFolderReferences()
            if self.workspace != nil {
                // The window owns the complete pane snapshot and its writer.
            } else if self.settings.restoresSession == restoresSession {
                _ = await self.restoreBrowserSessionIfEnabled(expectedVisit: initialVisit)
            } else {
                self.sessionPersistence.setEnabled(self.settings.restoresSession)
                self.recordBrowserSession()
            }
            if self.sessionID == initialVisit, !self.isBrowserSuspended { self.loadLocation() }
            if !self.isBrowserSuspended {
                if let workspace = self.workspace { workspace.requestInitialVolumeObservationIfNeeded() }
                else if self.location != .computer { await self.refreshVolumes() }
            }
            if self.workspace == nil || self.workspace?.primaryBrowser === self {
                if let engine = self.recoverableFileOperations {
                    await self.operationCoordinator.restoreCopyPreviewIfNeeded(engine: engine, settings: self.settings)
                }
                self.inspectOperationRecovery()
            }
        }
        _ = view
        rebuildSidebar()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(BrowserNotificationObservation(center: center, name: name) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.isBrowserSuspended else { return }
                    await self.refreshVolumes()
                    if name == NSWorkspace.didUnmountNotification && self.location != .computer { self.refresh(nil) }
                }
            })
        }
    }

    func buildAddressRow() {
        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        configureBreadcrumbContext(pathControl)
        pathControl.onNavigate = { [weak self] in self?.navigate(to: $0) }
        pathControl.setAccessibilityLabel("Folder breadcrumbs")
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathField.cell = VerticallyCenteredTextFieldCell(textCell: "")
        pathField.isEditable = true
        pathField.isSelectable = true
        pathField.usesSingleLineMode = true
        pathField.cell?.wraps = false
        pathField.cell?.isScrollable = true
        pathField.font = .systemFont(ofSize: 13)
        pathField.placeholderString = "Enter a folder path"
        pathField.target = self
        pathField.action = #selector(locationEntered(_:))
        pathField.delegate = self
        pathField.setAccessibilityLabel("Folder path")
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathControl.onEdit = { [weak self] in self?.focusLocation(nil) }
        pathControl.onLocationMenu = { [weak self] location in
            guard let self else { return NSMenu() }
            self.workspace?.activate(self, focus: false)
            return self.locationMenu(for: location)
        }
        pathField.isBordered = false
        pathField.isBezeled = false
        pathField.drawsBackground = false
        let pathArea = AddressSurfaceView()
        pathArea.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathArea.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        pathArea.heightAnchor.constraint(equalToConstant: 28).interfaceScaled.isActive = true
        pathArea.installAddressControl(pathControl)
        pathArea.installAddressControl(pathField)
        pathArea.onEdit = { [weak self] in self?.toggleLocationEditing(nil) }
        pathField.isHidden = true
        let definitions: [(String, String, Selector)] = [
            ("Back", "arrow.left", #selector(goBack(_:))),
            ("Forward", "arrow.right", #selector(goForward(_:))),
            ("Up", "arrow.up", #selector(goUp(_:))),
            ("Refresh", "arrow.clockwise", #selector(refresh(_:))),
            ("Open Terminal Here", "terminal", #selector(openTerminalHere(_:)))
        ]
        let navigation = definitions.map { title, icon, action -> NSButton in
            let button = NSButton(image: symbol(icon, title) ?? NSImage(), target: self, action: action)
            button.isBordered = false
            button.bezelStyle = .recessed
            button.image = button.image?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            button.widthAnchor.constraint(equalToConstant: workspace == nil ? 28 : 24).interfaceScaled.isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).interfaceScaled.isActive = true
            button.toolTip = title
            button.setAccessibilityLabel(title)
            navigationButtons.append((button, action))
            return button
        }
        filterField.placeholderString = "Filter loaded filenames"
        filterField.delegate = self
        filterField.target = self
        filterField.action = #selector(clearEmptyFolderFilter(_:))
        filterField.setAccessibilityLabel("Filter filenames in this folder")
        filterField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folderFilter.updateLayout(paneWidth: view.bounds.width)
        addressCompletion.layout()
        let address = stack(navigation + [pathArea, folderFilter.view, navigationOperationButton], orientation: .horizontal, spacing: workspace == nil ? 8 : 4)
        address.edgeInsets = NSEdgeInsets(top: 4, left: workspace == nil ? 12 : 8, bottom: 4, right: workspace == nil ? 12 : 8)
        address.heightAnchor.constraint(equalToConstant: 42).interfaceScaled.isActive = true
        pathArea.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pin(address, inside: pathContainer)
        addressLayout = BrowserAddressLayout(browser: self, addressRow: address, pathArea: pathArea)
    }

    func buildContent() {
        addChild(splitController)
        let sidebar = NSViewController()
        let sidebarContent = NSView()
        let sidebarMaterial = NavigationGlassSurface(contentView: sidebarContent, opaqueColor: .windowBackgroundColor)
        sidebarSurface = sidebarMaterial
        sidebar.view = sidebarMaterial
        let outlineScroll = NSScrollView()
        outlineScroll.drawsBackground = false
        outlineScroll.hasVerticalScroller = true
        outlineScroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: .init("location"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        InterfaceMetrics.setRowHeight(outline, base: 27)
        outline.indentationPerLevel = 13
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("Locations and folders")
        outlineScroll.documentView = outline
        pin(outlineScroll, inside: sidebarContent, inset: 8)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true
        splitController.addSplitViewItem(sidebarItem)
        let content = NSViewController()
        let fileContent = NSView()
        let fileMaterial = NavigationGlassSurface(contentView: fileContent, isGlassEnabled: false)
        contentSurface = fileMaterial
        content.view = fileMaterial
        splitController.addSplitViewItem(NSSplitViewItem(viewController: content))
        setupTable()
        folderScroll.documentView = table
        folderScroll.hasVerticalScroller = true
        folderScroll.hasHorizontalScroller = true
        folderScroll.autohidesScrollers = true
        folderScroll.translatesAutoresizingMaskIntoConstraints = false; fileContent.addSubview(folderScroll)
        NSLayoutConstraint.activate([folderScroll.leadingAnchor.constraint(equalTo: fileContent.leadingAnchor, constant: 12).interfaceScaled,
            folderScroll.trailingAnchor.constraint(equalTo: fileContent.trailingAnchor), folderScroll.topAnchor.constraint(equalTo: fileContent.topAnchor),
            folderScroll.bottomAnchor.constraint(equalTo: fileContent.bottomAnchor)])
        table.marquee = TableMarqueeSelection(table: table, scroll: folderScroll, parent: fileContent)
        table.marquee?.onBegin = { [weak self] in guard let self else { return }; workspace?.activate(self, focus: false); folderSummary.cancel() }
        pin(iconBrowser, inside: fileContent)
        iconBrowser.isHidden = true
        pin(volumeBrowser, inside: fileContent)
        pin(smbHost, inside: fileContent); smbHost.isHidden = true
        pin(sftpHost, inside: fileContent); sftpHost.isHidden = true
        pin(archiveHost, inside: fileContent); archiveHost.isHidden = true
        overlayTitle.alignment = .center
        overlayDetail.alignment = .center
        overlayDetail.maximumNumberOfLines = 4
        overlayDetail.lineBreakMode = .byWordWrapping
        overlayActions.orientation = .horizontal
        overlayActions.spacing = 8
        overlayActions.addArrangedSubview(ActionButton(title: "Retry", action: { [weak self] in self?.refresh(nil) }))
        overlayActions.addArrangedSubview(ActionButton(title: "Choose Folder…", action: { [weak self] in self?.chooseFolder(nil) }))
        let privacy = ActionButton(title: "Privacy Settings…", action: { [weak self] in self?.openPrivacySettings(nil) })
        overlayPrivacyAction = privacy; overlayActions.addArrangedSubview(privacy)
        let drives = ActionButton(title: "Drives…", action: { [weak self] in self?.showDriveControls(nil) })
        overlayDriveAction = drives; overlayActions.addArrangedSubview(drives); drives.isHidden = true
        overlayActions.isHidden = true
        let message = stack([overlayTitle, overlayDetail, overlayActions], orientation: .vertical, spacing: 10)
        message.alignment = .centerX
        overlay.addSubview(message)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            message.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, constant: -40)
        ])
        pin(overlay, inside: fileContent)
    }

    func setupTable() {
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for definition in BrowserColumn.allCases {
            let id = definition.rawValue
            let column = NSTableColumn(identifier: .init(id))
            column.title = definition.title
            column.width = definition.width
            column.minWidth = id == "name" ? 180 : 75
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            column.resizingMask = .userResizingMask
            column.isHidden = id != "name" && (settings.viewMode == .list || !isColumnVisible(definition))
            table.addTableColumn(column)
        }
        let parent = NSTableColumn(identifier: .init("searchParent"))
        parent.title = "Containing Folder"; parent.width = 260; parent.minWidth = 140
        parent.resizingMask = .userResizingMask; parent.isHidden = true
        table.addTableColumn(parent)
        let reason = NSTableColumn(identifier: .init("searchReason"))
        reason.title = "Matched By"; reason.width = 240; reason.minWidth = 120
        reason.resizingMask = .userResizingMask; reason.isHidden = true; table.addTableColumn(reason)
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .controlBackgroundColor
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        InterfaceMetrics.setRowHeight(table, base: 25)
        table.intercellSpacing = NSSize(width: 12, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelection(_:))
        table.setAccessibilityLabel("Files in the current folder")
        table.contextMenuProvider = { [weak self] in
            guard let self else { return nil }; return BrowserMenus.fileContextMenu(target: self)
        }
        let header = FileTableHeaderView(frame: table.headerView?.frame ?? NSRect(x: 0, y: 0, width: 1000, height: 28))
        header.columnMenu = BrowserMenus.columnMenu(target: self)
        table.headerView = header
    }

    func connectPreferences() {
        savedServerLocations.$snapshot.dropFirst().sink { [weak self] _ in
            // Published values arrive before assignment; render on the next turn.
            Task { @MainActor [weak self] in self?.refreshConnectedLocations(force: true) }
        }.store(in: &subscriptions)
        savedServerLocations.$connectionProgress.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshConnectedLocations(force: true) }
        }.store(in: &subscriptions)
        savedServerLocations.restoreIfNeeded()
        settings.$showsSidebarEject.combineLatest(settings.$hiddenEjectVolumes, settings.$hiddenEjectSessions)
            .dropFirst().sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.outline.reloadData() }
            }.store(in: &subscriptions)
        operationCoordinator.drives.$volumes.combineLatest(operationCoordinator.drives.$isPreparing, operationCoordinator.drives.$pending,
                                                         operationCoordinator.drives.$protectionRevision)
            .dropFirst().sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.outline.reloadData() }
            }.store(in: &subscriptions)
        settings.$addressPresentation.combineLatest(settings.$addressSuggestionLimit, settings.$showsHiddenFiles, settings.$symbolTolerantNames)
            .dropFirst().sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.addressCompletion.changed() }
            }.store(in: &subscriptions)
        settings.$reviewsRecoveryAtStartup.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.validateNavigationButtons() }
        }.store(in: &subscriptions)
        Publishers.Merge(settings.$keyboardProfile.map { _ in () }, settings.$customBehavior.map { _ in () })
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.table.behavior = self.settings.behavior
                    self.iconBrowser.collectionView.behavior = self.settings.behavior
                    self.volumeBrowser.behavior = self.settings.behavior
                    for owner in self.smbTabs.values { owner.rows.table.behavior = self.settings.behavior }
                    for owner in self.sftpTabs.values { owner.rows.table.behavior = self.settings.behavior }
                    self.currentArchive?.render()
                }
            }.store(in: &subscriptions)
        settings.$showsHiddenFiles.removeDuplicates().dropFirst().sink { [weak self] _ in
            // @Published emits before assignment; refresh on the next main-actor turn.
            Task { @MainActor [weak self] in self?.saveViewState(); self?.rebuildSidebar(); self?.loadLocation() }
        }.store(in: &subscriptions)
    }

    func saveViewState() {
        if isArchiveLocation { captureArchiveViewState(); recordBrowserSession(); return }
        // A pending restoration still owns the visit's saved state. An empty or
        // partial table must not erase it when navigation happens again quickly.
        guard !restoringScroll else { return }
        if metadataSearch.isShowingResults {
            metadataSearch.resultViewState = NavigationState(selection: selectedURLs, scrollOffset: currentScrollOffset)
            return
        }
        tabs[activeIndex].state = NavigationState(selection: selectedURLs, scrollOffset: showsComputerVolumes ? 0 : currentScrollOffset)
        recordBrowserSession()
    }

    var currentScrollOffset: Double {
        activeFileScrollOffset
    }

    var selectedURLs: Set<URL> {
        if isRemoteLocation || isArchiveLocation { return [] }
        if showsComputerVolumes { return Set(volumeBrowser.selectedURLs) }
        if usesFileIcons { return iconBrowser.selectedURLs }
        return Set(orderedSelectedURLs)
    }

    func navigate(to next: BrowserLocation) {
        guard !isBrowserSuspended else { return }
        let oldPath = location.directoryURL?.path, newPath = next.directoryURL?.path
        let ascending: Bool
        if let oldPath, let newPath { ascending = newPath == "/" || oldPath.hasPrefix(newPath + "/") }
        else { ascending = next == .computer }
        let direction = next == location ? 0 : ascending ? -1 : 1
        if let url = next.directoryURL { operationCoordinator.drives.acknowledgeNavigation(to: url) }
        saveViewState()
        tabs[activeIndex].navigate(to: next)
        recordsNextExplicitVisit = next.directoryURL != nil
        loadLocation(directoryDirection: direction)
    }

    func loadLocation(preservingVisibleRows: Bool = false, animatingTab: Bool = false, directoryDirection: Int = 0,
                      createdFolderRename: UUID? = nil) {
        let previousInstallation = isInstallingLocation
        isInstallingLocation = true
        defer { isInstallingLocation = previousInstallation; updateConnectionStatusIndicator() }
        // Replacing an active file view can make AppKit advance its responder
        // into a neighbouring pane. Preserve only existing content focus here;
        // background refreshes and address/search editing must never steal it.
        let hadContentFocus: Bool
        if let window = viewIfLoaded?.window, let responder = window.firstResponder as? NSView,
           let content = contentSurface?.contentView {
            hadContentFocus = window.isKeyWindow && isActiveCommandPane && responder.isDescendant(of: content)
        } else { hadContentFocus = false }
        defer {
            if hadContentFocus, !isBrowserSuspended, isActiveCommandPane, view.window?.isKeyWindow == true {
                focusBrowserContent()
            }
        }
        let animate = animatingTab ? settings.motion.allows(.tabContent) : directoryDirection != 0 && settings.motion.allows(.folders)
        prepareCanvasTransition(enabled: animate, directoryDirection: directoryDirection)
        folderSummary.cancel()
        let recordsExplicitVisit = recordsNextExplicitVisit
        recordsNextExplicitVisit = false
        addressCompletion.cancel()
        inlineRename.prepareForLocationChange(preservingCreatedFolder: createdFolderRename)
        selectionGroupDraft.contextChanged()
        guard !isBrowserSuspended else { return }
        folderFilter.contextWillChange()
        workspace?.locationWillChange(in: self)
        metadataSearch.locationWillChange(preservingIdleScope: preservingVisibleRows)
        quickLook.endSession()
        openAndShare.selectionDidChange()
        dragDrop.selectionDidChange()
        cancelDirectoryObservation()
        summaryBrowsingAccess = nil
        listingTask?.cancel()
        orderingTask?.cancel()
        orderingTask = nil
        sessionID = UUID()
        inlineRename.createdFolderListingStarted(createdFolderRename)
        orderRevision += 1
        let token = sessionID
        ApplicationDiagnostics.shared.event(.browse, .reading, trace: token)
        isBackgroundRefreshing = preservingVisibleRows && location.directoryURL != nil && !isOfflineCurrentFolder
        rawEntries = []
        if !isBackgroundRefreshing { displayedEntries = []; rowsByURL = [:] }
        loadError = nil
        accessDiagnostic = nil
        overlayActions.isHidden = true
        if !tabs[activeIndex].folderViewResolved { tabs[activeIndex].sort.foldersFirst = settings.foldersFirst }
        issueCount = 0
        isLoading = true
        restoringScroll = true
        firstRowsMilliseconds = nil
        enumerationMilliseconds = nil
        completeDisplayMilliseconds = nil
        loadStarted = Date()
        beginFolderLoadingFeedback()
        canvasTransition?.bind(to: token)
        lastOrderRequest = .distantPast
        updatingSelection = true
        if !isBackgroundRefreshing {
            if isArchiveLocation {
                // A hidden previous large folder must not remain a second
                // selection model or retain its native grid/row snapshot.
                table.reloadData()
                iconBrowser.update(OrderedRows(entries: [], rowsByURL: [:]), selected: [], cut: [], showsExtensions: settings.showsFileExtensions)
            } else { renderFilePresentation(selection: []) }
        }
        updatingSelection = false
        refreshCurrentConnectionBookmark()
        updateNavigation()
        recordBrowserSession()
        refreshStatus()
        updateFilePresentationVisibility()
        if case .smb(let value) = location {
            isLoading = false; folderLoadingFeedbackTask?.cancel(); folderLoadingFeedbackTask = nil
            loadSMBLocation(value); return
        }
        if case .sftp(let value) = location {
            isLoading = false; folderLoadingFeedbackTask?.cancel(); folderLoadingFeedbackTask = nil
            loadSFTPLocation(value); return
        }
        if case .archive(let value) = location { loadArchiveLocation(value); return }
        if let url = location.directoryURL, let offline = operationCoordinator.drives.offlineVolume(containing: url) {
            ApplicationDiagnostics.shared.event(.browse, .blocked, trace: token)
            isLoading = false
            loadError = "\(offline.name) is unmounted or disconnected. Mount it in Drives or choose another location."
            refreshStatus()
            return
        }
        if location == .computer {
            renderVolumes()
            updateCanvasTransition()
            listingTask = Task { [weak self] in await self?.refreshVolumes() }
        } else if let url = location.directoryURL {
            listingTask = Task { [weak self, fileSystem, hidden = settings.showsHiddenFiles] in
                do {
                    await self?.resolveSavedFolderView(for: url.standardizedFileURL.path, session: token)
                    guard !Task.isCancelled else { return }
                    let lease = await self?.folderAccess.acquireAccess(to: url)
                    guard !Task.isCancelled else { return }
                    await self?.startDirectoryObservation(for: url, retaining: lease, token: token)
                    guard !Task.isCancelled else { return }
                    for try await event in fileSystem.entries(in: url, showHidden: hidden, retaining: lease) {
                        guard let self, self.sessionID == token, !Task.isCancelled else { return }
                        switch event {
                        case .batch(let batch):
                            self.rawEntries.append(contentsOf: batch)
                            if !self.isBackgroundRefreshing && ((self.displayedEntries.isEmpty && self.orderingTask == nil) || Date().timeIntervalSince(self.lastOrderRequest) > 0.2) {
                                self.requestOrdering()
                            }
                        case .finished(let issues):
                            ApplicationDiagnostics.shared.event(.browse, issues.isEmpty ? .completed : .partial, trace: token,
                                count: UInt64(self.rawEntries.count))
                            self.summaryBrowsingAccess = issues.isEmpty ? FileAccessLifetimes(leases: lease.map { [$0] } ?? []) : nil
                            self.pinsController.recordNavigation(to: url, successful: true)
                            if recordsExplicitVisit { self.settings.directoryVisits.record(url) }
                            self.isLoading = false
                            self.issueCount = issues.count
                            self.enumerationMilliseconds = Date().timeIntervalSince(self.loadStarted) * 1000
                            self.requestOrdering()
                        }
                        self.refreshStatus()
                    }
                } catch {
                    guard let self, self.sessionID == token, !Task.isCancelled else { return }
                    ApplicationDiagnostics.shared.event(.browse, .failed, trace: token, error: DiagnosticErrors.project(error))
                    self.isLoading = false
                    self.loadError = self.message(for: error)
                    self.summaryBrowsingAccess = nil
                    self.pinsController.recordNavigation(to: url, successful: false)
                    self.accessDiagnostic = FolderAccessDiagnostic.describe(error)
                    self.requestOrdering()
                    self.refreshStatus()
                }
            }
        }
    }

    func requestOrdering() {
        guard !isArchiveLocation else { return }
        inlineRename.orderingWillChange()
        orderingTask?.cancel()
        orderRevision += 1
        let revision = orderRevision
        let token = sessionID
        let source = rawEntries
        let sort = tabs[activeIndex].sort
        let filter = metadataSearch.isShowingResults ? "" : tabs[activeIndex].filter
        lastOrderRequest = Date()
        orderingTask = Task { [weak self, ordering] in
            do {
                let result = try await ordering.order(source, sort: sort, filter: filter)
                guard let self, self.sessionID == token, self.orderRevision == revision, !Task.isCancelled else { return }
                let state = self.metadataSearch.isShowingResults ? self.metadataSearch.resultViewState : self.tabs[self.activeIndex].state
                let scroll = self.restoringScroll ? state.scrollOffset : self.currentScrollOffset
                self.updatingSelection = true
                self.displayedEntries = result.entries
                self.rowsByURL = result.rowsByURL
                // Native operation outcomes may omit a directory URL's trailing
                // slash. Match the local location, then render its actual listed
                // URL; do not lose folder selections when a Copy refreshes rows.
                let selection: Set<URL>
                let unresolved = state.selection.filter { result.rowsByURL[$0] == nil }
                if unresolved.isEmpty { selection = state.selection }
                else {
                    let paths = Set(unresolved.map(\.path))
                    selection = state.selection.subtracting(unresolved).union(result.entries.lazy.filter { paths.contains($0.url.path) }.map(\.url))
                }
                self.renderFilePresentation(selection: selection, scrollOffset: scroll)
                self.updatingSelection = false
                // A tall first batch may still omit selected items. Keep the
                // visit pending until both selection and scroll can be restored.
                let selectionLoaded = selection.count == state.selection.count
                if !self.isLoading || (selectionLoaded && self.activeFileView.bounds.height > scroll + self.activeFileScrollView.contentView.bounds.height) {
                    self.restoringScroll = false
                }
                if self.firstRowsMilliseconds == nil && !result.entries.isEmpty {
                    self.firstRowsMilliseconds = Date().timeIntervalSince(self.loadStarted) * 1000
                }
                if !self.isLoading { self.completeDisplayMilliseconds = Date().timeIntervalSince(self.loadStarted) * 1000 }
                self.orderingTask = nil
                if !self.isLoading { self.isBackgroundRefreshing = false }
                self.recordBrowserSession()
                self.refreshStatus()
                self.consumePendingDirectoryRefresh()
                self.inlineRename.consumeCreatedFolderIfReady()
            } catch {
                guard let self, self.orderRevision == revision else { return }
                self.orderingTask = nil
            }
        }
    }

    func message(for error: Error) -> String {
        if let error = error as? LocalStorageError { return error.userMessage }
        return "This location is unavailable. Check that it is connected and that you have permission, then refresh."
    }

    func refreshVolumes() async {
        let token = UUID()
        volumeSessionID = token
        let sharedTicket = workspace?.beginVolumeRefresh(from: self)
        guard workspace == nil || sharedTicket != nil else { return }
        defer {
            // Cancellation or local-token supersession can skip both result
            // branches. Only this still-current request may end shared loading.
            if let sharedTicket { workspace?.cancelVolumeRefresh(from: self, ticket: sharedTicket) }
        }
        do {
            #if DEBUG
            let result: [VolumeInfo]
            if let readVolumesForVerification { result = try await readVolumesForVerification() }
            else { result = try await fileSystem.volumes() }
            #else
            let result = try await fileSystem.volumes()
            #endif
            guard volumeSessionID == token, !Task.isCancelled, !isBrowserSuspended else { return }
            if let sharedTicket {
                workspace?.completeVolumeRefresh(.success(result), from: self, ticket: sharedTicket)
                return
            }
            guard workspace == nil else { return }
            volumes = result
            updateSidebarVolumes()
            if showsComputerVolumes {
                isLoading = false
                loadError = nil
                renderVolumes()
                refreshStatus()
            }
        } catch {
            guard volumeSessionID == token, !Task.isCancelled, !isBrowserSuspended else { return }
            if let sharedTicket {
                workspace?.completeVolumeRefresh(.failure(message(for: error)), from: self, ticket: sharedTicket)
                return
            }
            guard workspace == nil else { return }
            if showsComputerVolumes {
                isLoading = false
                loadError = message(for: error)
                renderVolumes()
                refreshStatus()
            }
        }
    }

    func syncSortIndicators() {
        guard !isArchiveLocation else { return }
        let sort = tabs[activeIndex].sort
        updatingSortIndicators = true
        table.sortDescriptors = [NSSortDescriptor(key: sort.field.rawValue, ascending: sort.ascending)]
        table.headerView?.needsDisplay = true
        updatingSortIndicators = false
    }

    /// Late volume names can refresh breadcrumbs without discarding an address
    /// draft, editor focus, tab identity or search/filter state.
    func updateBreadcrumbs() {
        if updateArchiveBreadcrumbs() || updateSMBBreadcrumbs() || updateSFTPBreadcrumbs() { return }
        // Supplying lexical items avoids NSPathControl's automatic filesystem
        // icon/title resolution on the main actor, including for remote mounts.
        breadcrumbLocations = []
        let items: [NSPathControlItem]
        if let url = location.directoryURL {
            let volume = volumes.filter {
                url.path == $0.url.path || url.path.hasPrefix($0.url.path == "/" ? "/" : $0.url.path + "/")
            }.max { $0.url.path.count < $1.url.path.count }
            var current = volume?.url ?? URL(fileURLWithPath: "/", isDirectory: true)
            let components = [volume?.name ?? "/"] + Array(url.pathComponents.dropFirst(current.pathComponents.count))
            items = components.enumerated().map { index, component in
                if index > 0 { current.appendPathComponent(component, isDirectory: true) }
                let item = NSPathControlItem()
                item.title = component
                breadcrumbLocations.append(.directory(current))
                // One root icon gives the address a stable anchor; repeated folder
                // symbols make narrow paths much harder to scan.
                if index == 0 {
                    item.image = breadcrumbSymbol(volume?.kind == .network ? "network" : "externaldrive", "Volume")
                }
                return item
            }
        } else {
            let item = NSPathControlItem()
            item.title = "This Mac"
            item.image = breadcrumbSymbol("desktopcomputer", "This Mac")
            items = [item]
            breadcrumbLocations = [.computer]
        }
        pathControl.setBreadcrumbs(items: items, locations: breadcrumbLocations)
        pathControl.placeholderString = nil
        pathControl.toolTip = (location.directoryURL?.path ?? "This Mac")
            + "\nClick a folder or … for omitted parents. Use Edit folder path, double-click the current folder, click unused space, or press ⌘L to type a path."
    }

    func updateNavigation() {
        addressEditingContext = nil
        tabStrip.update(tabs: tabs, activeID: activeID)
        pathField.isHidden = true
        pathControl.isHidden = false
        updateBreadcrumbs()
        pathField.stringValue = location.directoryURL?.path ?? "This Mac"
        if isSMBLocation { pathField.stringValue = "SMB · " + location.displayName }
        if isSFTPLocation { pathField.stringValue = "SFTP · " + location.displayName }
        if isArchiveLocation { pathField.stringValue = location.displayName }
        (pathField.superview as? AddressSurfaceView)?.setEditing(false)
        filterField.isEnabled = !showsComputerVolumes && !metadataSearch.isShowingResults
        filterField.stringValue = tabs[activeIndex].filter
        folderFilter.synchronize()
        syncSortIndicators()
        if isActiveCommandPane { view.window?.title = "\(location.displayName) — Traverse" }
        syncSidebarSelection()
        validateNavigationButtons()
    }

    func validateNavigationButtons() {
        viewModeControl.isEnabled = !isRemoteLocation && !isArchiveLocation
        tabStrip.refreshManagementAvailability()
        recoveryAttentionButton.isHidden = !hasRecoveryAttention
        recoveryAttentionButton.title = recoveryUnfinishedCount > 0 ? "Recovery (\(recoveryUnfinishedCount))" : "Recovery"
        recoveryAttentionButton.isEnabled = !isBrowserSuspended && view.window?.attachedSheet == nil
        recoveryAttentionButton.toolTip = "Review retained or interrupted operations. Nothing resumes or is removed automatically."
        recoveryAttentionButton.setAccessibilityLabel("Recovery needs attention. \(recoveryUnfinishedCount) unfinished operations. Open Operation Recovery")
        let needsAttention = operationCoordinator.transfers.reviewResult != nil
        let resultTitle = needsAttention ? "Needs attention" : "Results"
        if operationResultsButton.title != resultTitle {
            operationResultsButton.title = resultTitle
            operationResultsButton.image = symbol(needsAttention ? "exclamationmark.circle.fill" : "list.clipboard", resultTitle)
        }
        operationResultsButton.contentTintColor = needsAttention ? .systemOrange : nil
        operationResultsButton.toolTip = needsAttention
            ? "Open the transfer queue to review the paused job. Resume starts only waiting transfers."
            : "Inspect the last operation's individual results"
        operationResultsButton.setAccessibilityLabel(needsAttention ? "Transfers need attention. Open transfer queue" : "Last operation results")
        operationResultsButton.isHidden = !needsAttention && lastOperationResult == nil
        operationResultsButton.isEnabled = canInspectLastOperationResult
        for (button, action) in navigationButtons {
            button.isEnabled = commandEnabled(action)
            if action == #selector(openTerminalHere(_:)) {
                button.isHidden = !settings.showsTerminalButton || isRemoteLocation || isArchiveLocation || location.directoryURL == nil
            }
        }
        view.window?.toolbar?.validateVisibleItems()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        table.columnSizing.fit(table)
        folderFilter.updateLayout(paneWidth: view.bounds.width)
        addressCompletion.layout()
    }

    func refreshStatus() {
        if isArchiveLocation { renderCurrentArchiveStatus(); return }
        if isSMBLocation { renderCurrentSMBStatus(); return }
        if isSFTPLocation { renderCurrentSFTPStatus(); return }
        updateCanvasTransition()
        quickLook.selectionDidChange()
        openAndShare.selectionDidChange()
        dragDrop.selectionDidChange()
        if isLoading { loadingIndicator.startAnimation(nil) } else { loadingIndicator.stopAnimation(nil) }
        if metadataSearch.renderStatusIfNeeded() { validateNavigationButtons(); return }
        if !isLoading && orderingTask == nil {
            folderLoadingFeedbackTask?.cancel(); folderLoadingFeedbackTask = nil
        }
        status.toolTip = nil
        if showsComputerVolumes {
            let selection = volumeBrowser.selectedCount == 0 ? "" : " · \(volumeBrowser.selectedCount) selected"
            status.stringValue = loadError ?? (isLoading ? "Loading locations…" : "\(volumes.count) mounted volume\(volumes.count == 1 ? "" : "s")" + selection)
            overlay.isHidden = loadError == nil && (!volumes.isEmpty || isLoading)
            overlayTitle.stringValue = loadError == nil ? "No mounted volumes" : "Unable to load locations"
            overlayDetail.stringValue = loadError ?? "Refresh to check connected drives."
            validateNavigationButtons()
            return
        }
        let selectedCount = selectedItemCount
        let suffix = selectedCount == 0 ? "" : " · \(selectedCount) selected"
        if let loadError {
            status.stringValue = rawEntries.isEmpty ? loadError : "Incomplete listing · \(browserItemCount(rawEntries.count)) loaded · \(loadError)"
        } else if isLoading {
            status.stringValue = "Loading… \(browserItemCount(rawEntries.count))" + suffix
        } else {
            let count = tabs[activeIndex].filter.isEmpty ? browserItemCount(displayedEntries.count) : "\(displayedEntries.count) of \(browserItemCount(rawEntries.count))"
            status.stringValue = count + suffix + (issueCount > 0 ? " · Some item details unavailable" : "")
        }
        overlay.isHidden = !displayedEntries.isEmpty
        if displayedEntries.isEmpty {
            if let loadError {
                overlayTitle.stringValue = "Unable to load this folder"
                overlayDetail.stringValue = accessDiagnostic?.message ?? loadError
                overlayActions.isHidden = false
                overlayDriveAction?.isHidden = !isOfflineCurrentFolder
                overlayPrivacyAction?.isHidden = accessDiagnostic.map {
                    ![.permissionOrACL, .policyOrOtherRestriction, .deniedCauseUnknown].contains($0.kind)
                } ?? true
            } else if isLoading || orderingTask != nil {
                overlay.isHidden = ProcessInfo.processInfo.systemUptime < folderLoadingFeedbackDeadline
                overlayTitle.stringValue = "Loading folder…"
                overlayDetail.stringValue = "You can continue navigating while items load."
            } else if !tabs[activeIndex].filter.isEmpty {
                overlayTitle.stringValue = "No matching filenames"
                overlayDetail.stringValue = "Try a different filter, or clear it to see all items."
            } else {
                overlayTitle.stringValue = "This folder is empty"
                overlayDetail.stringValue = settings.showsHiddenFiles ? "No items were found in this folder." : "Hidden items are not shown."
            }
        }
        validateNavigationButtons()
    }

    func renderVolumes() {
        updatingSelection = true
        volumeBrowser.update(volumes: volumes)
        volumeBrowser.setSelection(tabs[activeIndex].state.selection)
        updatingSelection = false
        restoringScroll = false
    }
}

private func browserItemCount(_ count: Int) -> String { "\(count) item\(count == 1 ? "" : "s")" }
