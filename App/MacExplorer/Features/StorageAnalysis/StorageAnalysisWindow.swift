import AppKit
import FileOperations
@_spi(ApplicationOwnership) import StorageAnalysis
import SwiftUI

/// Presentation only: root admission, scanning, access and I/O drain belong to
/// the coordinator. This window never resolves icons or reads the filesystem.
@MainActor
final class StorageAnalysisWindowController: NSWindowController, NSWindowDelegate,
    NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outlineView = NSOutlineView()
    let scopeLabel = label("Choose a folder to inspect its observed storage.")
    private let scanTimeLabel = label("", size: 12, color: .secondaryLabelColor)
    let statusLabel = NSTextField(wrappingLabelWithString: "Ready")
    let progressLabel = label("No scan is running", size: 12, color: .secondaryLabelColor)
    let summaryLabel = NSTextField(wrappingLabelWithString: "Size observations appear during scanning.")
    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    let scanEveryFolderButton = NSButton(title: "Scan Every Folder", target: nil, action: nil)
    var onScanEveryFolder: (() -> Void)?
    let coverageButton = NSButton(title: "Scan details…", target: nil, action: nil)
    let includeApplicationDataButton = NSButton(checkboxWithTitle: "Include application data for next analysis", target: nil, action: nil)
    let rememberApplicationDataButton = NSButton(checkboxWithTitle: "Remember choice at this location", target: nil, action: nil)
    private var defaultNextPolicy = AnalysisMetadataPolicy.standard
    private var nextScopeOverridden = false
    private var policyOptionsView: NSView?
    let metadataPolicyLabel = label("Current: Standard metadata", size: 11, color: .secondaryLabelColor)
    let expandBreakdownButton = NSButton(title: "Show Breakdown", target: nil, action: nil)
    let appStorageButton = NSButton(title: "App Storage", target: nil, action: nil)
    var onReviewAccess: (() -> Void)?
    var onClearSessionResults: (@MainActor () -> Void)?
    var onRepairSavedAnalyses: (@MainActor () -> Void)?
    private var maintenanceButtons: [NSButton] = []
    func setMaintenanceRunning(_ value: Bool) {
        maintenanceButtons.forEach { $0.isEnabled = !value }
    }
    var onClose: (@MainActor () -> Void)?
    var onChooseStartupData: (@MainActor () -> Void)?
    var onLocationAction: ((StorageAnalysisResult, UInt64, StoredLocationAction, @escaping (String) -> Void) -> Void)?
    var onCancelLocationAction: ((UUID) -> Void)?
    private(set) var isPreparingRows = false
    private(set) var renderGeneration: UInt64 = 0
    private(set) var isClosed = false
    var preparedFolderCount: Int { prepared?.snapshot.folders.count ?? 0 }
    var preparedRowsWereOffMain: Bool? { prepared?.wasPreparedOffMain }
    var appComponentRows: [AppStorageComponent] { appStorageSupplements + (appComponents ?? []) }

    private let onChooseFolder: @MainActor () -> Void
    private let onRefresh: @MainActor () -> Void
    private let onStop: @MainActor () -> Void
    private let onAppStorage: @MainActor () -> Void
    private let spinner = NSProgressIndicator()
    private let startupDataButton = NSButton(title: "Analyze Data Volume…", target: nil, action: nil)
    private let rowStateLabel = label("Folder rows appear after a scan finishes.", size: 12, color: .secondaryLabelColor)
    private let explanation = NSTextField(wrappingLabelWithString:
        "Data fork and all-fork logical sizes are distinct. Allocated bytes are observed allocation, not exclusive physical usage or reclaimable space. Folder sums count names; hard links can overlap. Partial rows are observed subtotals.")
    private let appStorageExplanation = NSTextField(wrappingLabelWithString:
        "Local app state and a separate shallow observation of the declared temporary-analysis pool. Recovery files elsewhere, developer tooling and macOS Spotlight storage are excluded. No persistent content index is created.")
    private var currentSession: UUID?
    private var rootName = "Selected folder"
    private var volumeCapacity: PropertyVolumeCapacity?
    private var startupAccounting: StartupStorageAccounting?
    func showStartupAccounting(_ value: StartupStorageAccounting?) {
        guard !isClosed else { return }
        startupAccounting = value; updateBreakdown()
    }
    func showVolumeCapacity(_ value: PropertyVolumeCapacity?) {
        guard !isClosed else { return }
        volumeCapacity = value
        updateBreakdown()
    }
    private var requestPreparing = false
    private var workerActive = false
    private var breakdownPreparing = false
    private var statusBeforeBreakdown: String?
    private var stopRequested = false
    private var sort = StorageAnalysisRowSort(field: .logical, ascending: false)
    private var folderItems: [Int: StorageAnalysisFolderItem] = [:]
    var allocatedFolderItemCount: Int { folderItems.count }
    private var prepared: StorageAnalysisPreparedRows?
    private struct PreparationRequest {
        let generation: UInt64
        let snapshot: StorageAnalysisSnapshot
    }
    private var pendingPreparation: PreparationRequest?
    private var preparationTask: Task<StorageAnalysisPreparedRows?, Never>?
    private var preparationID: UUID?
    #if DEBUG
    var rowPreparationHookForVerification: (@Sendable () throws -> Void)?
    var rowWorkIsDrainedForVerification: Bool { preparationTask == nil && pendingPreparation == nil }
    var pagedRowCountForVerification: Int { pagedModel?.rows.count ?? 0 }
    var pagedReadyForVerification: Bool { pagedModel != nil && pagedModel?.loading == false }
    var compactBreakdownForVerification: Bool { !expandBreakdownButton.isHidden && attributionHost.isHidden }
    var provisionalBreakdownForVerification: Bool { attributionReport?.isProvisional == true }
    var chartCanBrowseForVerification: Bool { chartDrill.canBrowse }
    var chartDrillForVerification: StorageBreakdownChartModel { chartDrill }
    var pagedModelForVerification: PagedAnalysisBrowserModel? { pagedModel }
    func openFirstPagedFolderForVerification() { if let row = pagedModel?.rows.first(where: { $0.kind == .directory && $0.value.counts.total > 0 }) { pagedModel?.open(row) } }
    func nextPagedForVerification() { pagedModel?.next() }
    #endif
    private let attributionHost = InterfaceHostingView<AnyView>(content: AnyView(EmptyView()))
    private let pagedHost = InterfaceHostingView<AnyView>(content: AnyView(EmptyView()))
    private var pagedModel: PagedAnalysisBrowserModel?
    private var historicalStatus: String?
    private var retiringPageQueries: Task<Void, Never>?
    private var retiringPageQueriesID: UUID?
    var hasRetiringSessionConsumers: Bool { retiringPageQueries != nil }
    #if DEBUG
    var displayedResultForSessionReuseVerification: UUID? { pagedResult?.id }
    var hasVisibleReportForSessionReuseVerification: Bool { attributionReport != nil && !attributionHost.isHidden }
    var hasPageRequestForSessionReuseVerification: Bool { pagedModel?.hasWork == true }
    func requestFirstPageForSessionReuseVerification() { pagedModel?.start() }
    func stopThroughNativeControlForSessionReuseVerification() { stopButton.performClick(nil) }
    #endif
    func waitUntilRetiredQueriesDrained() async { await retiringPageQueries?.value }
    func waitUntilAllQueriesDrained() async {
        await waitUntilRetiredQueriesDrained()
        await chartDrill.waitUntilQueriesDrained()
        await pagedModel?.waitUntilQueriesDrained()
    }
    func revokeAnalysisQueries(ifShowing catalogID: UUID) {
        guard currentSession == catalogID else { return }
        retirePagedModel(); chartDrill.close()
        // Revoke row authority immediately, while keeping the flexible viewport
        // through reader drain. Detaching it makes the status row absorb its
        // height before the replacement presentation arrives.
        pagedHost.content = AnyView(EmptyView())
        updateBreakdown()
    }
    private func retirePagedModel() {
        recordedQueries = nil
        guard let previousModel = pagedModel else { return }
        previousModel.close(); pagedModel = nil; pagedResult = nil
        let previousTask = retiringPageQueries, id = UUID()
        retiringPageQueriesID = id
        retiringPageQueries = Task { @MainActor [weak self] in
            await previousTask?.value
            await previousModel.waitUntilQueriesDrained()
            if self?.retiringPageQueriesID == id {
                self?.retiringPageQueries = nil; self?.retiringPageQueriesID = nil
            }
        }
    }
    func showOperationFeedback(_ feedback: AnalysisOperationFeedback, node: UInt64, browser: BrowserViewController,
                               engine: RecoverableFileOperations, succeeded: Bool) {
        pagedModel?.operationFeedback?.close()
        pagedModel?.operationFeedback = feedback
        if succeeded { pagedModel?.recordTrash(node: node, recordID: feedback.id, browser: browser, engine: engine); chartDrill.recordTrash(node: node, recordID: feedback.id) }
    }
    func showConfirmedUndo(recordID: UUID) { pagedModel?.recordUndo(recordID: recordID); chartDrill.recordUndo(recordID: recordID) }
    private var pagedResult: StorageAnalysisResult?
    private var recordedQueries: RecordedAnalysisQueries?
    private let chartDrill = StorageBreakdownChartModel()
    private var attributionReport: AnalysisAttributionReport?
    private var accountingValue: StoredAnalysisValue?
    private var appComponents: [AppStorageComponent]?
    private var appStorageSupplements: [AppStorageComponent] = []
    private var attributionHeight: NSLayoutConstraint?
    private var coverageDetail = ""
    private var coveragePopover: NSPopover?
    private var policyPopover: NSPopover?
    private var optionsPopover: NSPopover?
    private var optionsContent: NSView?
    private var applicationDataAvailable = false

    init(onChooseFolder: @escaping @MainActor () -> Void,
         onRefresh: @escaping @MainActor () -> Void,
         onStop: @escaping @MainActor () -> Void,
         onAppStorage: @escaping @MainActor () -> Void,
         appearance: NSAppearance? = nil) {
        self.onChooseFolder = onChooseFolder; self.onRefresh = onRefresh
        self.onStop = onStop; self.onAppStorage = onAppStorage
        let window = ToolWindowChrome.makeWindow(title: "Storage Analysis", size: .init(width: 960, height: 780),
            minimumSize: .init(width: 740, height: 480))
        window.acceptsMouseMovedEvents = true
        window.appearance = appearance
        super.init(window: window)
        window.delegate = self

        let choose = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseFolder(_:)))
        let appStorage = appStorageButton
        appStorage.target = self; appStorage.action = #selector(showAppStorage(_:))
        refreshButton.target = self; refreshButton.action = #selector(refresh(_:))
        stopButton.target = self; stopButton.action = #selector(stop(_:))
        coverageButton.target = self; coverageButton.action = #selector(showCoverage(_:))
        expandBreakdownButton.target = self; expandBreakdownButton.action = #selector(expandBreakdown(_:))
        expandBreakdownButton.isHidden = true
        expandBreakdownButton.setAccessibilityIdentifier("storage-analysis-show-breakdown")
        expandBreakdownButton.toolTip = "Expand the window to show the chart and storage breakdown."
        coverageButton.isHidden = true
        coverageButton.setAccessibilityIdentifier("storage-analysis-coverage")
        for button in [choose, refreshButton, stopButton, appStorage, coverageButton, expandBreakdownButton] { button.bezelStyle = .rounded }
        choose.setAccessibilityIdentifier("storage-analysis-choose")
        refreshButton.setAccessibilityIdentifier("storage-analysis-refresh")
        refreshButton.toolTip = StorageScanPresentation.refreshHelp
        stopButton.setAccessibilityIdentifier("storage-analysis-stop")
        appStorage.setAccessibilityIdentifier("storage-analysis-app-storage")
        stopButton.isEnabled = false; refreshButton.isEnabled = false
        let accessButton = NSButton(title: "Review Access…", target: self, action: #selector(reviewAccess(_:)))
        accessButton.bezelStyle = .rounded
        accessButton.setAccessibilityIdentifier("storage-analysis-review-access")
        let optionsButton = NSButton(title: "Scan Options…", target: self, action: #selector(showOptions(_:)))
        optionsButton.bezelStyle = .rounded
        optionsButton.setAccessibilityIdentifier("storage-analysis-options")
        let flexibleSpace = NSView()
        flexibleSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = stack([choose, refreshButton, stopButton, flexibleSpace, optionsButton, accessButton, expandBreakdownButton], orientation: .horizontal)
        actions.detachesHiddenViews = true
        includeApplicationDataButton.setAccessibilityIdentifier("storage-analysis-include-app-data")
        includeApplicationDataButton.toolTip = AnalysisMetadataPolicy.applicationDataHelp
        includeApplicationDataButton.target = self; includeApplicationDataButton.action = #selector(nextScopeChanged(_:))
        rememberApplicationDataButton.toolTip = "Local, exact-path preference for Refresh of this location. Choose a new folder before remembering its choice. Clear remembered choices in Settings."
        rememberApplicationDataButton.isEnabled = false
        metadataPolicyLabel.setAccessibilityIdentifier("storage-analysis-metadata-policy")
        let policyHelp = NSButton(title: "", target: self, action: #selector(showPolicyHelp(_:)))
        policyHelp.bezelStyle = .helpButton; policyHelp.setAccessibilityLabel("About application-data analysis")
        policyHelp.toolTip = AnalysisMetadataPolicy.applicationDataHelp
        let policyOptions = stack([stack([includeApplicationDataButton, policyHelp, NSView(), metadataPolicyLabel], orientation: .horizontal), rememberApplicationDataButton], orientation: .vertical, spacing: 3)
        policyOptionsView = policyOptions
        policyOptions.alignment = .leading
        let clearSession = NSButton(title: "Forget Saved Analyses", target: self, action: #selector(clearSessionResults(_:)))
        clearSession.bezelStyle = .rounded
        clearSession.setAccessibilityIdentifier("storage-analysis-clear-session")
        clearSession.toolTip = "Close the displayed analysis and remove saved analyses after their reads finish. Your files are untouched."
        let repair = NSButton(title: "Repair Saved Analyses", target: self, action: #selector(repairSavedAnalyses(_:)))
        repair.bezelStyle = .rounded
        repair.toolTip = "Check saved analyses after an interrupted update. Your files are untouched."
        repair.setAccessibilityIdentifier("storage-analysis-repair-saved")
        maintenanceButtons = [clearSession, repair]
        scanEveryFolderButton.target = self; scanEveryFolderButton.action = #selector(scanEveryFolder(_:))
        scanEveryFolderButton.bezelStyle = .rounded
        scanEveryFolderButton.setAccessibilityIdentifier("storage-analysis-scan-every-folder")
        scanEveryFolderButton.toolTip = StorageScanPresentation.fullScanHelp
        let options = stack([scanEveryFolderButton, policyOptions, appStorage, clearSession, repair], orientation: .vertical, spacing: 16)
        options.alignment = .leading
        optionsContent = options

        scopeLabel.isSelectable = true
        scopeLabel.setAccessibilityIdentifier("storage-analysis-scope")
        scopeLabel.setAccessibilityLabel("Analysis scope")
        scopeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scopeLabel.lineBreakMode = .byTruncatingMiddle
        scanTimeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        scanTimeLabel.setAccessibilityIdentifier("storage-analysis-scan-time")
        scanTimeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        scanTimeLabel.isHidden = true
        let scopeCaption = label("Location:", size: 12, color: .secondaryLabelColor)
        scopeCaption.setContentCompressionResistancePriority(.required, for: .horizontal)
        let scopeAndTiming = stack([scopeCaption, scopeLabel, NSView(), scanTimeLabel], orientation: .horizontal, spacing: 12)
        scopeAndTiming.detachesHiddenViews = true
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.setAccessibilityIdentifier("storage-analysis-status")
        startupDataButton.target = self; startupDataButton.action = #selector(chooseStartupData(_:))
        startupDataButton.bezelStyle = .rounded; startupDataButton.isHidden = true
        startupDataButton.setAccessibilityIdentifier("storage-analysis-startup-data")
        startupDataButton.toolTip = "Choose the Data volume or one of its folders to analyze files separately. This does not include the macOS System volume."
        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        summaryLabel.setAccessibilityIdentifier("storage-analysis-summary")
        progressLabel.setAccessibilityIdentifier("storage-analysis-progress")
        spinner.style = .spinning; spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let state = stack([spinner, statusLabel, NSView(), coverageButton], orientation: .horizontal)
        state.detachesHiddenViews = true

        for (id, title, width) in [("name", "Name", 300.0), ("logical", "Logical", 125.0),
                                  ("allocated", "Allocated", 125.0), ("files", "Files", 90.0),
                                  ("folders", "Folders", 90.0), ("status", "Status", 100.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title; column.width = width; column.minWidth = id == "name" ? 160 : 75
            if ["logical", "allocated", "files", "folders"].contains(id) {
                column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: false)
            }
            outlineView.addTableColumn(column)
        }
        outlineView.outlineTableColumn = outlineView.tableColumns.first
        outlineView.dataSource = self; outlineView.delegate = self
        InterfaceMetrics.setRowHeight(outlineView, base: 27); outlineView.indentationPerLevel = 16
        outlineView.allowsMultipleSelection = false
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing
        outlineView.style = .plain; outlineView.backgroundColor = .controlBackgroundColor
        outlineView.sortDescriptors = [NSSortDescriptor(key: "logical", ascending: false)]
        outlineView.setAccessibilityLabel("Observed folder storage")
        outlineView.setAccessibilityIdentifier("storage-analysis-folders")
        let listing = NSScrollView()
        listing.documentView = outlineView; listing.hasVerticalScroller = true; listing.hasHorizontalScroller = true
        listing.drawsBackground = true; listing.backgroundColor = .controlBackgroundColor
        listing.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        listing.setContentHuggingPriority(.init(1), for: .vertical)
        for text in [explanation, appStorageExplanation] {
            text.font = .systemFont(ofSize: 11); text.textColor = .secondaryLabelColor
            text.setContentHuggingPriority(.required, for: .vertical)
        }
        appStorageExplanation.isHidden = true
        // The native window owns its dimensions. A hosting view's default
        // intrinsic-size constraints can otherwise shrink the whole window to
        // EmptyView's width before a result arrives.
        attributionHost.sizingOptions = []
        attributionHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        attributionHost.isHidden = true
        pagedHost.sizingOptions = []; pagedHost.isHidden = true
        pagedHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        pagedHost.setContentHuggingPriority(.init(1), for: .vertical)
        attributionHeight = attributionHost.heightAnchor.constraint(equalToConstant: 210)
        attributionHeight?.isActive = true
        summaryLabel.toolTip = StorageScanPresentation.sizeHelp()
        let layout = stack([actions, scopeAndTiming, state, progressLabel, startupDataButton, summaryLabel, attributionHost, rowStateLabel,
                            listing, pagedHost, appStorageExplanation], orientation: .vertical, spacing: 8)
        layout.detachesHiddenViews = true
        // Only the file viewport absorbs spare height. Without an explicit
        // priority, the empty refresh placeholder and fixed header stacks tie,
        // briefly stretching the labels and moving the chart down the window.
        for view in [actions, scopeAndTiming, state, progressLabel, summaryLabel, rowStateLabel] {
            view.setContentHuggingPriority(.required, for: .vertical)
        }
        guard let content = window.contentView else { return }
        pin(layout, inside: content, inset: 16)
        for view in [scopeAndTiming, state, progressLabel, summaryLabel, attributionHost, rowStateLabel, listing, pagedHost, appStorageExplanation] {
            view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        }
        updateWrappingWidths()
        ToolWindowChrome.install(in: window)
        ToolWindowChrome.position(window, relativeTo: NSApp.mainWindow)
    }

    required init?(coder: NSCoder) { nil }
    deinit { preparationTask?.cancel() }

    override func showWindow(_ sender: Any?) {
        isClosed = false
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--verify-ui"), ProcessInfo.processInfo.arguments.contains("--offscreen") { return }
        #endif
        super.showWindow(sender)
    }

    func applyAppearance(_ appearance: NSAppearance?) { window?.appearance = appearance }
    func applyToolStyle(_ settings: BrowserSettings?) {
        if let window { ToolWindowChrome.install(in: window, settings: settings) }
    }

    /// Next-request controls never rewrite the policy of stored observations.
    /// A new request/handoff resets the pending choice, not the current badge.
    func setRequestPolicy(_ policy: AnalysisMetadataPolicy, available: Bool) {
        applicationDataAvailable = available
        includeApplicationDataButton.state = .off
        includeApplicationDataButton.isEnabled = available
        rememberApplicationDataButton.state = .off; rememberApplicationDataButton.isEnabled = false
        defaultNextPolicy = .standard; nextScopeOverridden = false
        showMetadataPolicy(policy)
    }
    func configureNextScope(_ policy: AnalysisMetadataPolicy, remember: Bool, canRemember: Bool) {
        defaultNextPolicy = applicationDataAvailable ? policy : .standard; nextScopeOverridden = false
        includeApplicationDataButton.state = defaultNextPolicy == .applicationData ? .on : .off
        rememberApplicationDataButton.state = remember ? .on : .off
        rememberApplicationDataButton.isEnabled = applicationDataAvailable && canRemember
    }
    @objc private func nextScopeChanged(_ sender: NSButton) { nextScopeOverridden = true }
    func takeNextMetadataPolicy(default requested: AnalysisMetadataPolicy? = nil) -> AnalysisMetadataPolicy {
        let chosen: AnalysisMetadataPolicy = applicationDataAvailable && includeApplicationDataButton.state == .on ? .applicationData : .standard
        let result = applicationDataAvailable ? (nextScopeOverridden || chosen != defaultNextPolicy ? chosen : requested ?? defaultNextPolicy) : .standard
        includeApplicationDataButton.state = defaultNextPolicy == .applicationData ? .on : .off; nextScopeOverridden = false
        return result
    }
    private func showMetadataPolicy(_ policy: AnalysisMetadataPolicy) {
        metadataPolicyLabel.stringValue = "Current: " + policy.title
        metadataPolicyLabel.toolTip = policy == .standard ? "Standard exclusions apply to the current observation. The checkbox applies only to the next request." : AnalysisMetadataPolicy.applicationDataHelp
    }

    @objc private func showPolicyHelp(_ sender: NSButton) {
        let content = NSViewController(), text = NSTextField(wrappingLabelWithString: AnalysisMetadataPolicy.applicationDataHelp)
        text.font = .systemFont(ofSize: 12)
        text.preferredMaxLayoutWidth = 302
        content.view = NSView(frame: .init(x: 0, y: 0, width: 330, height: 150))
        pin(text, inside: content.view, inset: 14)
        let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = content
        policyPopover?.close(); policyPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func showOptions(_ sender: NSButton) {
        guard let optionsContent else { return }
        updateScanEveryFolderAvailability()
        if optionsPopover?.isShown == true { optionsPopover?.close(); return }
        let content = NSViewController()
        content.view = NSView(frame: .init(x: 0, y: 0, width: 470, height: 226 * InterfaceMetrics.scale))
        pin(optionsContent, inside: content.view, inset: 16)
        let popover = NSPopover(); popover.behavior = .transient
        popover.contentViewController = content
        optionsPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func scanEveryFolder(_ sender: Any?) {
        updateScanEveryFolderAvailability()
        guard scanEveryFolderButton.isEnabled else { return }
        optionsPopover?.close()
        onScanEveryFolder?()
    }

    private func updateScanEveryFolderAvailability() {
        scanEveryFolderButton.isEnabled = refreshButton.isEnabled && !workerActive && !requestPreparing
    }

    func showAttribution(_ report: AnalysisAttributionReport?) {
        guard !isClosed else { return }
        let firstBreakdown = attributionReport == nil && report != nil
        if report == nil { accountingValue = nil }
        attributionReport = report
        if firstBreakdown { ToolContentMotion.crossfade(attributionHost) }
        updateBreakdown()
    }

    #if DEBUG
    func showSyntheticForVerification(_ snapshot: StorageAnalysisSnapshot, report: AnalysisAttributionReport) {
        render(root: nil, update: nil)
        showAttribution(report)
        prepare(snapshot)
    }
    func showScanForVerification(_ snapshot: StorageAnalysisSnapshot?, report: AnalysisAttributionReport?, status: StorageScanStatus, working: Bool) {
        render(root: URL(fileURLWithPath: "/Generated/Orion"), update: nil)
        workerActive = working
        let presentation = StorageScanPresentation(status: status, working: working)
        statusLabel.stringValue = presentation.title; statusLabel.toolTip = presentation.guidance
        if let snapshot {
            summaryLabel.stringValue = StorageScanPresentation.size(snapshot.root.namespaceSubtotals, files: snapshot.root.counts.regularFiles, live: working)
            summaryLabel.toolTip = StorageScanPresentation.sizeHelp()
            progressLabel.stringValue = StorageScanPresentation.counts(snapshot.root.counts)
            if !working { prepare(snapshot) }
        }
        showAttribution(report)
        updateSpinner(); updateWrappingWidths()
    }
    #endif

    func showAppComponents(_ components: [AppStorageComponent]?) {
        guard !isClosed else { return }
        appComponents = components; updateBreakdown()
    }

    func showAppStorageSupplement(_ component: AppStorageComponent?) {
        showAppStorageSupplements(component.map { [$0] } ?? [])
    }
    func showAppStorageSupplements(_ components: [AppStorageComponent]) {
        guard !isClosed else { return }
        appStorageSupplements = components; updateBreakdown()
    }

    func setBreakdownPreparing(_ value: Bool) {
        guard !isClosed else { return }
        let wasPreparing = breakdownPreparing
        breakdownPreparing = value
        if let historicalStatus {
            statusLabel.stringValue = historicalStatus
            if value { progressLabel.stringValue = "Finishing refreshed results…" }
        } else if value && !workerActive {
            if !wasPreparing { statusBeforeBreakdown = statusLabel.stringValue }
            statusLabel.stringValue = "Finishing your results…"
        } else if !value, wasPreparing, !requestPreparing, !workerActive,
                  statusLabel.stringValue == "Finishing your results…", let statusBeforeBreakdown {
            // Restore only the label this preparation replaced. A newer render,
            // failure or request keeps its own status instead of an older one.
            statusLabel.stringValue = statusBeforeBreakdown
        }
        if !value { statusBeforeBreakdown = nil }
        updateBreakdown(); updateSpinner()
    }

    /// The coordinator can own prior-work drain or access preparation before
    /// a StorageScanSession exists. Keep that phase visible and cancellable
    /// without claiming an actual worker has started.
    func showRequestPreparing() {
        guard !isClosed else { return }
        requestPreparing = true
        if historicalStatus == nil { showScanTime(nil) }
        statusLabel.stringValue = historicalStatus ?? "Getting ready…"
        progressLabel.stringValue = "Preparing access to your chosen location."
        updateBreakdown(); updateSpinner(); updateWrappingWidths()
    }

    private func updateBreakdown() {
        if attributionReport == nil || attributionReport?.isProvisional == true { chartDrill.close() }
        else if let recordedQueries { chartDrill.configureRecorded(recordedQueries) }
        else { chartDrill.configure(pagedResult) }
        if pagedResult != nil {
            chartDrill.onLocationAction = { [weak self] result, node, action, completion in
                guard let self, !self.isClosed, self.pagedResult?.id == result.id, let handler = self.onLocationAction else {
                    completion("This analysis is no longer available."); return
                }
                handler(result, node, action, completion)
            }
            chartDrill.onCancelLocationAction = { [weak self] result in self?.onCancelLocationAction?(result) }
        }
        attributionHost.isHidden = attributionReport == nil && appComponentRows.isEmpty && volumeCapacity == nil && startupAccounting == nil
        attributionHost.content = AnyView(ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !appComponentRows.isEmpty { AppStorageAccountingView(rows: appComponentRows) }
                if let attributionReport { StorageAttributionView(report: attributionReport, overview: true, drill: chartDrill, folderRootTitle: rootName) }
                else if requestPreparing || workerActive || breakdownPreparing { StorageScanPlaceholder(working: true) }
                if let accountingValue { StorageAccountingView(bytes: accountingValue.bytes, regularFiles: accountingValue.counts.regularFiles) }
                if startupAccounting != nil || volumeCapacity != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        if let startupAccounting = self.startupAccounting { StartupStorageAccountingView(value: startupAccounting) }
                        else if let volumeCapacity = self.volumeCapacity { StorageVolumeAccountingView(value: volumeCapacity) }
                    }.help("Drive capacity comes from macOS and includes storage the file scan may not count.")
                }
            }.padding(.vertical, 4)
        })
        updateCompactBreakdown()
    }

    /// A request can fail admission before a scan session or update exists.
    /// This is presentation of that request, not an assertion about other I/O.
    func showUnavailable(_ message: String) {
        guard !isClosed else { return }
        startupDataButton.isHidden = true
        historicalStatus = nil
        showScanTime(nil)
        retirePagedModel()
        pagedHost.content = AnyView(EmptyView()); pagedHost.isHidden = true
        outlineView.enclosingScrollView?.isHidden = false
        showAttribution(nil)
        showAppComponents(nil)
        invalidatePreparation()
        coverageButton.isHidden = true; coverageDetail = ""
        coveragePopover?.close(); coveragePopover = nil
        requestPreparing = false; workerActive = false; breakdownPreparing = false; stopRequested = false
        stopButton.isEnabled = false; stopButton.title = "Stop"
        statusLabel.stringValue = message
        progressLabel.stringValue = "Choose another folder, or review your access and try again."
        summaryLabel.stringValue = "Size observations are unavailable for this request."
        rowStateLabel.stringValue = "No folder observation is available."
        rowStateLabel.isHidden = false
        updateBreakdown(); updateSpinner(); updateWrappingWidths()
    }

    func showStartupUnavailable(_ message: String) {
        showUnavailable(message)
        guard !isClosed else { return }
        startupDataButton.isHidden = false
        progressLabel.stringValue = "You can analyze the Data volume or a folder separately. The macOS System volume won’t be included."
        updateWrappingWidths()
    }

    func showFailure(_ failure: StorageScanFailure) {
        guard !isClosed else { return }
        let presentation = StorageScanPresentation(status: .failed(failure), working: false)
        showUnavailable(presentation.title)
        progressLabel.stringValue = presentation.guidance
        summaryLabel.stringValue = ""
        rowStateLabel.stringValue = "No scan results to display."
        updateWrappingWidths()
    }

    @objc private func reviewAccess(_ sender: Any?) { onReviewAccess?() }

    /// Call showWindow before render when reopening a previously closed window.
    /// Late publications after close cannot resurrect preparation or old rows.
    func render(root: URL?, update: StorageScanUpdate?, appStorage: Bool = false) {
        startupDataButton.isHidden = true
        guard !isClosed else { return }
        historicalStatus = nil
        requestPreparing = false
        retirePagedModel(); pagedHost.content = AnyView(EmptyView()); pagedHost.isHidden = true
        outlineView.enclosingScrollView?.isHidden = false
        showAttribution(nil)
        showAppComponents(nil)
        invalidatePreparation()
        if currentSession != update?.session {
            stopRequested = false
            coveragePopover?.close(); coveragePopover = nil
        }
        currentSession = update?.session
        coverageButton.isHidden = update?.coverage.hasExplanation != true
        coverageDetail = update.map { StorageAnalysisCoverageText.details($0.coverage, root: root) } ?? ""
        rootName = appStorage ? "App storage" : root.map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent } ?? "Selected folder"
        scopeLabel.stringValue = root?.path ?? (appStorage ? "App-owned local state" : "Choose a folder to inspect its observed storage.")
        scopeLabel.toolTip = root?.path
        showMetadataPolicy(.standard)
        appStorageExplanation.isHidden = !appStorage
        policyOptionsView?.isHidden = appStorage
        window?.title = appStorage ? "App Storage" : "Storage Analysis"
        workerActive = update.map { !$0.workerDrained } ?? false
        breakdownPreparing = false
        if update?.workerDrained == true { stopRequested = false }
        stopButton.isEnabled = workerActive && !stopRequested
        stopButton.title = stopRequested && workerActive ? "Stopping…" : "Stop"
        refreshButton.isEnabled = root != nil || appStorage
        statusLabel.stringValue = update.map { StorageScanPresentation(status: $0.status, working: !$0.workerDrained, coverage: $0.coverage).title }
            ?? (appStorage ? "App storage has not been measured" : "Ready")
        statusLabel.toolTip = update.map { StorageScanPresentation(status: $0.status, working: !$0.workerDrained, coverage: $0.coverage).guidance }
        if stopRequested && workerActive { statusLabel.stringValue = "Stopping — waiting for the worker to finish" }
        let counts = update?.progress?.acceptedCounts ?? update?.snapshot?.root.counts
        showScanTime(update?.elapsed, working: workerActive)
        if let counts {
            progressLabel.stringValue = StorageScanPresentation.counts(counts)
        } else if update != nil {
            progressLabel.stringValue = "Waiting for observations"
        } else { progressLabel.stringValue = "No scan is running" }
        if let bytes = update?.progress?.namespaceSubtotals ?? update?.snapshot?.root.namespaceSubtotals {
            let files = counts?.regularFiles ?? 0
            summaryLabel.stringValue = StorageScanPresentation.size(bytes, files: files, live: workerActive)
            summaryLabel.toolTip = StorageScanPresentation.sizeHelp()
        } else { summaryLabel.stringValue = "Size observations appear during scanning." }
        if let snapshot = update?.snapshot { prepare(snapshot) }
        else {
            rowStateLabel.stringValue = workerActive ? "Folder rows appear when the scan finishes. Live values above are observations so far." : "No folder rows to display."
            rowStateLabel.isHidden = false
        }
        updateBreakdown(); updateSpinner(); updateWrappingWidths()
    }

    override func close() {
        finishClosing()
        super.close()
    }

    func windowWillClose(_ notification: Notification) { finishClosing() }

    private func finishClosing() {
        // A controller can be closed repeatedly while its native window is
        // already hidden. Cleanup belongs to this owner and remains idempotent.
        guard !isClosed else { return }
        isClosed = true; requestPreparing = false; workerActive = false; breakdownPreparing = false
        includeApplicationDataButton.state = .off; policyPopover?.close(); policyPopover = nil
        chartDrill.close(); attributionReport = nil; appComponents = nil; appStorageSupplements = []; accountingValue = nil
        attributionHost.content = AnyView(EmptyView()); attributionHost.isHidden = true
        retirePagedModel(); pagedHost.content = AnyView(EmptyView())
        coveragePopover?.close(); coveragePopover = nil
        optionsPopover?.close(); optionsPopover = nil
        invalidatePreparation(); updateSpinner()
        onClose?()
    }

    func renderPaged(root: URL, update: PagedStorageScanUpdate, summary: StoredAnalysisSummary? = nil,
                     report: AnalysisAttributionReport? = nil, metadataPolicy: AnalysisMetadataPolicy = .standard) {
        guard !isClosed else { return }
        historicalStatus = nil
        if currentSession != update.session {
            invalidatePreparation(); retirePagedModel()
            pagedHost.content = AnyView(EmptyView()); stopRequested = false
            // A completed Refresh replaces the static previous overview in
            // place. Clearing it first replayed the initial fade with an old
            // chart snapshot at a different layout position.
            if report == nil || attributionReport == nil { showAttribution(nil) }
        }
        currentSession = update.session; requestPreparing = false; workerActive = !update.workerDrained
        rootName = root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
        scopeLabel.stringValue = root.path
        scopeLabel.toolTip = root.path
        showMetadataPolicy(update.result?.metadataPolicy ?? metadataPolicy)
        appStorageExplanation.isHidden = true; showAppComponents(nil)
        policyOptionsView?.isHidden = false
        outlineView.enclosingScrollView?.isHidden = true
        rowStateLabel.isHidden = true
        showScanTime(workerActive ? update.elapsed : update.result?.scanElapsed ?? update.elapsed,
            working: workerActive)
        progressLabel.stringValue = "Waiting for observations"
        let presentation = StorageScanPresentation(status: update.status, working: workerActive, coverage: update.coverage,
            hasCurrentResults: update.provisionalFileTypes != nil || summary != nil || update.result != nil)
        statusLabel.stringValue = presentation.title; statusLabel.toolTip = presentation.guidance
        coverageButton.isHidden = !update.coverage.hasExplanation
        coverageDetail = StorageAnalysisCoverageText.details(update.coverage, root: root, paired: update.isStartupPair)
        refreshButton.isEnabled = true
        var displayedReport = report
        if let prefix = update.provisionalFileTypes {
            accountingValue = prefix.value; displayedReport = prefix.attributionReport()
            summaryLabel.stringValue = StorageScanPresentation.size(prefix.value.bytes, files: prefix.value.counts.regularFiles, live: true)
            progressLabel.stringValue = StorageScanPresentation.counts(prefix.value.counts)
            summaryLabel.toolTip = StorageScanPresentation.sizeHelp("Committed observations only. Percentages describe observed bytes, never scan completion.")
        } else if let summary {
            accountingValue = summary.value
            summaryLabel.stringValue = StorageScanPresentation.size(summary.value.bytes, files: summary.value.counts.regularFiles, live: false)
            progressLabel.stringValue = StorageScanPresentation.counts(summary.value.counts)
            summaryLabel.toolTip = StorageScanPresentation.sizeHelp(summary.sources.isEmpty ? nil : summary.sources.map {
                "\($0.title): \($0.value.counts.total) observed entries · " + ($0.traversalFinished ? "traversal finished" : "incomplete")
            }.joined(separator: "\n") + "\n\(summary.verifiedAliases) verified path aliases are not counted twice; \(summary.unresolvedAliases) are unresolved.")
        } else {
            accountingValue = nil
            if workerActive { summaryLabel.stringValue = "Counting files…" }
            else if update.result != nil { summaryLabel.stringValue = "Organizing your results…" }
            else {
                summaryLabel.stringValue = ""
                progressLabel.stringValue = presentation.guidance
                rowStateLabel.stringValue = "No scan results to display."
                rowStateLabel.isHidden = false
            }
            summaryLabel.toolTip = nil
        }
        if update.isStartupPair { progressLabel.stringValue += " · System + Data" }
        if let result = update.result, pagedModel == nil {
            pagedResult = result
            let model = PagedAnalysisBrowserModel(result: result, title: rootName)
            model.onLocationAction = { [weak self] result, node, action, completion in
                guard let self, !self.isClosed, let handler = self.onLocationAction else {
                    completion("This analysis window is no longer available."); return
                }
                handler(result, node, action, completion)
            }
            model.onCancelLocationAction = { [weak self] result in self?.onCancelLocationAction?(result) }
            model.allowsPageMotion = { [weak self] in
                (self?.window?.contentViewController as? ToolWindowChrome)?.motion.allows(.pages) ?? true
            }
            model.pageMotionMode = { [weak self] in (self?.window?.contentViewController as? ToolWindowChrome)?.motion.mode ?? .full }
            pagedModel = model; pagedHost.content = AnyView(PagedAnalysisBrowser(model: model))
        }
        pagedHost.isHidden = pagedModel == nil
        if update.workerDrained, let result = update.result, let note = StorageScanPresentation.refreshResult(result) {
            statusLabel.stringValue = note
            statusLabel.toolTip = "These are dated observations. Refresh checks for changes; Scan Every Folder checks everything."
        }
        showAttribution(displayedReport)
        updateSpinner(); updateWrappingWidths()
    }

    func detachSessionConsumersAndDrain() async {
        revokeRecordedPresentation()
        await waitUntilRetiredQueriesDrained()
        await chartDrill.waitUntilQueriesDrained()
        _ = await preparationTask?.value
    }

    /// Synchronous revocation precedes the owner's asynchronous query drain.
    /// Source files and durable history are controlled by the analysis owner.
    func revokeRecordedPresentation() {
        retirePagedModel()
        chartDrill.close()
        showUnavailable("Closing this analysis…")
    }

    func showRecordedAnalysis(root: URL, presentation: RecordedAnalysisPresentation,
                              summary: StoredAnalysisSummary, report: AnalysisAttributionReport,
                              coverage: AnalysisScanCoverage) {
        guard !isClosed else { return }
        showRecordedOverview(root: root, catalogID: presentation.metadata.catalogID,
            summary: summary, report: report, observedAt: presentation.metadata.observedThrough,
            policy: presentation.metadata.metadataPolicy, coverage: coverage, refreshing: false,
            scanElapsed: presentation.metadata.scanElapsed)
        let queries = presentation.queries
        recordedQueries = queries
        let model = PagedAnalysisBrowserModel(recordedView: queries, title: rootName)
        model.allowsPageMotion = { [weak self] in
            (self?.window?.contentViewController as? ToolWindowChrome)?.motion.allows(.pages) ?? true
        }
        model.pageMotionMode = { [weak self] in
            (self?.window?.contentViewController as? ToolWindowChrome)?.motion.mode ?? .full
        }
        pagedModel = model; pagedHost.content = AnyView(PagedAnalysisBrowser(model: model)); pagedHost.isHidden = false
        refreshButton.isEnabled = true
        historicalStatus = StorageScanPresentation.retainedObservation(presentation.metadata.observedThrough,
            complete: summary.complete, refresh: presentation.metadata.refreshCheckpoint)
        statusLabel.stringValue = historicalStatus ?? "Previous analysis"
        showAttribution(report); updateSpinner(); updateWrappingWidths()
    }

    func showRecordedOverview(root: URL, catalogID: UUID, summary: StoredAnalysisSummary,
                              report: AnalysisAttributionReport, observedAt: Date,
                              policy: AnalysisMetadataPolicy, coverage: AnalysisScanCoverage,
                              refreshing: Bool, scanElapsed: TimeInterval? = nil) {
        guard !isClosed else { return }
        showScanTime(scanElapsed, previous: true)
        if refreshing, workerActive, currentSession == catalogID, historicalStatus != nil {
            progressLabel.stringValue = "Refreshing with a full metadata scan…"
            updateSpinner()
            return
        }
        if refreshing, let window { ToolContentMotion.finish(in: window) }
        invalidatePreparation(); retirePagedModel(); chartDrill.close()
        currentSession = catalogID; requestPreparing = false
        workerActive = refreshing; breakdownPreparing = false; stopRequested = false
        rootName = root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
        scopeLabel.stringValue = root.path; scopeLabel.toolTip = root.path
        showMetadataPolicy(policy)
        appStorageExplanation.isHidden = true; showAppComponents(nil)
        outlineView.enclosingScrollView?.isHidden = true; rowStateLabel.isHidden = true
        accountingValue = summary.value
        // This static overview has no live row authority. Keep its viewport
        // until replacement queries publish, including the interval after the
        // worker drains but before the final report is ready.
        pagedHost.content = AnyView(Text(refreshing ? "Updating file details…" : "Refresh for current file details.")
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity))
        pagedHost.isHidden = false
        historicalStatus = StorageScanPresentation.retainedObservation(observedAt,
            complete: summary.complete, refreshing: refreshing)
        statusLabel.stringValue = historicalStatus ?? "Previous analysis"
        statusLabel.toolTip = "Saved observations reopen without scanning. Refresh checks this location for changes."
        summaryLabel.stringValue = StorageScanPresentation.size(summary.value.bytes,
            files: summary.value.counts.regularFiles, live: false)
        progressLabel.stringValue = StorageScanPresentation.counts(summary.value.counts)
        summaryLabel.toolTip = StorageScanPresentation.sizeHelp()
        coverageButton.isHidden = !coverage.hasExplanation
        coverageDetail = StorageAnalysisCoverageText.details(coverage, root: root, paired: false)
        refreshButton.isEnabled = true
        showAttribution(report); updateSpinner(); updateWrappingWidths()
    }

    func showRecordedAnalysis(_ snapshot: SessionAnalysisObservation, refreshing: Bool, note: String? = nil) {
        if refreshing {
            showRecordedOverview(root: snapshot.root, catalogID: snapshot.result.id,
                summary: snapshot.summary, report: snapshot.report, observedAt: snapshot.observedAt,
                policy: snapshot.result.metadataPolicy, coverage: snapshot.update.coverage, refreshing: true,
                scanElapsed: snapshot.result.scanElapsed ?? snapshot.update.elapsed)
        } else {
            renderPaged(root: snapshot.root, update: snapshot.update, summary: snapshot.summary,
                report: snapshot.report, metadataPolicy: snapshot.result.metadataPolicy)
        }
        guard !isClosed else { return }
        requestPreparing = false; workerActive = refreshing; breakdownPreparing = false
        let status = StorageScanPresentation.retainedObservation(snapshot.observedAt,
            complete: snapshot.summary.complete, refreshing: refreshing, refresh: snapshot.result.refreshCheckpoint)
        historicalStatus = status; statusLabel.stringValue = status
        statusLabel.toolTip = "These are earlier observations. Refresh checks this location for changes."
        showScanTime(snapshot.result.scanElapsed ?? snapshot.update.elapsed, previous: true)
        progressLabel.stringValue = [StorageScanPresentation.counts(snapshot.summary.value.counts),
            note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        stopButton.isEnabled = refreshing && !stopRequested
        refreshButton.isEnabled = true
        updateSpinner(); updateWrappingWidths()
    }
    @objc private func clearSessionResults(_ sender: Any?) {
        optionsPopover?.close(); onClearSessionResults?()
    }
    @objc private func repairSavedAnalyses(_ sender: Any?) {
        optionsPopover?.close(); onRepairSavedAnalyses?()
    }

    func windowDidResize(_ notification: Notification) { updateWrappingWidths() }

    @objc private func showCoverage(_ sender: NSButton) {
        guard !coverageButton.isHidden, !coverageDetail.isEmpty else { return }
        let text = NSTextField(wrappingLabelWithString: coverageDetail)
        text.font = .systemFont(ofSize: 12); text.isSelectable = true
        text.preferredMaxLayoutWidth = 390
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 422, height: 320))
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.documentView = text
        text.frame = NSRect(x: 0, y: 0, width: 390, height: text.fittingSize.height)
        pin(scroll, inside: content.view, inset: 16)
        let popover = NSPopover(); popover.behavior = .transient
        popover.contentViewController = content
        coveragePopover?.close(); coveragePopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    private func invalidatePreparation() {
        renderGeneration &+= 1
        pendingPreparation = nil
        // Cancellation requests do not release the processing slot. Rapid
        // result/sort changes retain at most one running task and one latest
        // snapshot until the old task has actually returned.
        preparationTask?.cancel()
        isPreparingRows = false; prepared = nil
        folderItems.removeAll(keepingCapacity: false)
        outlineView.deselectAll(nil); outlineView.reloadData()
    }

    private func prepare(_ snapshot: StorageAnalysisSnapshot) {
        pendingPreparation = PreparationRequest(generation: renderGeneration, snapshot: snapshot)
        isPreparingRows = true
        rowStateLabel.stringValue = "Preparing folder rows…"; rowStateLabel.isHidden = false
        updateSpinner()
        pumpPreparation()
    }

    private func pumpPreparation() {
        guard !isClosed, preparationTask == nil, let request = pendingPreparation else { return }
        pendingPreparation = nil
        let generation = request.generation, snapshot = request.snapshot, sort = sort, job = UUID()
        #if DEBUG
        let hook = rowPreparationHookForVerification
        #endif
        let task = Task.detached(priority: .utility) { () -> StorageAnalysisPreparedRows? in
            do {
                try Task.checkCancellation()
                #if DEBUG
                try hook?()
                #endif
                return try StorageAnalysisPreparedRows.make(snapshot, sort: sort)
            } catch { return nil as StorageAnalysisPreparedRows? }
        }
        preparationTask = task; preparationID = job
        Task { @MainActor [weak self] in
            let result = await task.value
            guard let self, self.preparationID == job else { return }
            self.preparationTask = nil; self.preparationID = nil
            guard !self.isClosed, self.renderGeneration == generation else {
                self.pumpPreparation()
                return
            }
            if self.sort != sort, let snapshot = result?.snapshot {
                self.invalidatePreparation(); self.prepare(snapshot); return
            }
            self.isPreparingRows = false
            self.prepared = result
            self.rowStateLabel.stringValue = result == nil ? "Folder rows are unavailable for this observation." : ""
            self.rowStateLabel.isHidden = result != nil
            self.outlineView.reloadData()
            if result != nil { self.outlineView.expandItem(self.folderItem(at: 0)) }
            self.updateSpinner()
        }
    }

    private func updateSpinner() {
        if requestPreparing || workerActive || isPreparingRows || breakdownPreparing { spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil) }
        stopButton.isEnabled = !isClosed && !stopRequested && (requestPreparing || workerActive || isPreparingRows || breakdownPreparing)
        stopButton.title = stopRequested && workerActive ? "Stopping…" : "Stop"
    }

    private func updateWrappingWidths() {
        let width = max(250, (window?.contentView?.bounds.width ?? 960) - 32)
        // Keep room for the folder table at the window's minimum height. The
        // breakdown remains scrollable instead of breaking native constraints.
        // Reserve a usable folder viewport as well as navigation, row actions
        // and their persistent outcome. The chart gives up space first.
        attributionHeight?.constant = max(80, min(320, (window?.contentView?.bounds.height ?? 780) - 340))
        updateCompactBreakdown()
        for text in [statusLabel, summaryLabel, explanation, appStorageExplanation] {
            text.preferredMaxLayoutWidth = text === statusLabel ? width - 24 : width
            text.invalidateIntrinsicContentSize()
        }
    }

    private func updateCompactBreakdown() {
        let hasBreakdown = attributionReport != nil || !appComponentRows.isEmpty || volumeCapacity != nil || startupAccounting != nil
            || requestPreparing || workerActive || breakdownPreparing
        let compact = (window?.contentView?.bounds.height ?? 780) < 700
        attributionHost.isHidden = !hasBreakdown || compact
        expandBreakdownButton.isHidden = !hasBreakdown || !compact
    }
    @objc private func expandBreakdown(_ sender: Any?) {
        guard let window else { return }
        window.setContentSize(.init(width: window.contentView?.bounds.width ?? 960, height: 780))
        updateWrappingWidths()
    }

    private func statusText(_ status: StorageScanStatus, drained: Bool) -> String {
        let text: String
        switch status {
        case .preparing: text = "Preparing the selected folder"
        case .scanning: text = "Scanning metadata — coverage is still incomplete"
        case .completed: text = "Complete observation"
        case .partial: text = "Partial observation — some items or metadata were unavailable"
        case .cancelled: text = "Stopped — values cover only the observed items"
        case .failed(let failure):
            switch failure {
            case .busy: text = "Storage is busy — try again when current file activity finishes"
            case .accessDenied: text = "Access denied — choose a folder you can read"
            case .unavailable: text = "The selected folder is unavailable or disconnected"
            case .unsupportedLocation: text = "This location is not eligible for metadata analysis"
            case .changed: text = "The selected folder changed — refresh to inspect it again"
            case .workerUnavailable: text = "The storage scanner is unavailable"
            case .workerFailed: text = "The scanner stopped unexpectedly — the observation is incomplete"
            case .invalidOutput: text = "The scanner result could not be validated"
            case .resourceLimit: text = "A scan limit was reached — the observation is incomplete"
            }
        }
        return drained || status == .preparing || status == .scanning ? text : text + " · waiting for the worker to finish"
    }

    private func byteText(_ value: UInt64?) -> String {
        guard let value else { return "Unavailable" }
        if value > UInt64(Int64.max) { return "\(value) bytes" }
        return FileSizeText.string(Int64(value))
    }

    /// A returned zero remains numeric. Entirely missing metadata is unknown,
    /// while mixed support reports only the known namespace subtotal.
    func metricText(_ subtotal: AnalysisMetricSubtotal, observedRegularFiles: UInt64) -> String {
        guard !subtotal.overflowed, subtotal.knownBytes != nil else { return "Unavailable" }
        let (missing, overflow) = subtotal.notReturnedCount.addingReportingOverflow(subtotal.failedCount)
        if observedRegularFiles > 0, overflow || missing >= observedRegularFiles { return "Unknown" }
        let formatted = byteText(subtotal.knownBytes)
        return missing > 0 || overflow ? "Known " + formatted : formatted
    }

    private func showScanTime(_ duration: TimeInterval?, working: Bool = false, previous: Bool = false) {
        let text = StorageScanPresentation.scanTime(duration, working: working, previous: previous)
        scanTimeLabel.stringValue = text ?? ""
        scanTimeLabel.isHidden = text == nil
    }

    @objc private func chooseFolder(_ sender: Any?) { onChooseFolder() }
    @objc private func chooseStartupData(_ sender: Any?) { onChooseStartupData?() }
    @objc private func refresh(_ sender: Any?) { onRefresh() }
    @objc private func showAppStorage(_ sender: Any?) { onAppStorage() }
    @objc private func stop(_ sender: Any?) {
        guard requestPreparing || workerActive || isPreparingRows || breakdownPreparing, !stopRequested else { return }
        stopRequested = true; stopButton.isEnabled = false; stopButton.title = "Stopping…"
        if workerActive {
            statusLabel.stringValue = historicalStatus ?? "Stopping — waiting for the worker to finish"
            if historicalStatus != nil { progressLabel.stringValue = "Stopping Refresh — waiting for the worker to finish" }
        } else {
            if isPreparingRows {
                invalidatePreparation()
                rowStateLabel.stringValue = "Folder row preparation stopped. Refresh to show rows."
                rowStateLabel.isHidden = false
            }
            breakdownPreparing = false
            statusLabel.stringValue = historicalStatus ?? "Stopped preparing results · scan observations retained"
            if historicalStatus != nil { progressLabel.stringValue = "Refresh stopped. The dated observation is unchanged." }
        }
        onStop()
        updateSpinner()
    }

    private func index(for item: Any?) -> Int? {
        guard let item = item as? StorageAnalysisFolderItem, let prepared,
              prepared.snapshot.folders.indices.contains(item.index), folderItems[item.index] === item else { return nil }
        return item.index
    }

    private func folderItem(at index: Int) -> StorageAnalysisFolderItem {
        if let item = folderItems[index] { return item }
        let item = StorageAnalysisFolderItem(index)
        folderItems[index] = item
        return item
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let prepared else { return 0 }
        guard item != nil else { return 1 }
        return index(for: item).map { prepared.children(of: $0).count } ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child: Int, ofItem item: Any?) -> Any {
        guard let prepared else { return NSNull() }
        guard item != nil else { return folderItem(at: 0) }
        guard let index = index(for: item), child >= 0, child < prepared.children(of: index).count else { return NSNull() }
        let children = prepared.children(of: index)
        return folderItem(at: children[children.startIndex + child])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let index = index(for: item), let prepared else { return false }
        return !prepared.children(of: index).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let index = index(for: item), let prepared, let column = tableColumn else { return nil }
        let folder = prepared.snapshot.folders[index], id = column.identifier
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView { cell = reused }
        else {
            cell = NSTableCellView(); cell.identifier = id
            let text = label("")
            text.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(text); cell.textField = text
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        guard let text = cell.textField else { return cell }
        let numeric = ["logical", "allocated", "files", "folders"].contains(id.rawValue)
        text.alignment = numeric ? .right : .left
        text.font = numeric ? .monospacedDigitSystemFont(ofSize: 12, weight: index == 0 ? .semibold : .regular)
            : .systemFont(ofSize: 12, weight: index == 0 ? .semibold : .regular)
        text.textColor = id.rawValue == "status" && !folder.isComplete ? .systemOrange : .labelColor
        switch id.rawValue {
        case "name":
            if index == 0 { text.stringValue = rootName }
            else {
                let path = folder.relativePath
                let start = path.lastIndex(of: 47).map { path.index(after: $0) } ?? path.startIndex
                text.stringValue = String(data: path[start...], encoding: .utf8) ?? "Non-UTF-8 folder name"
            }
        case "logical": text.stringValue = metricText(folder.namespaceSubtotals.allForkLogical, observedRegularFiles: folder.counts.regularFiles)
        case "allocated": text.stringValue = metricText(folder.namespaceSubtotals.allForkAllocated, observedRegularFiles: folder.counts.regularFiles)
        case "files": text.stringValue = String(folder.counts.regularFiles)
        case "folders": text.stringValue = String(folder.counts.directories)
        default: text.stringValue = folder.isComplete ? "Complete" : "Partial"
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first,
              let field = StorageAnalysisRowSort.Field(rawValue: descriptor.key ?? "") else { return }
        sort = .init(field: field, ascending: descriptor.ascending)
        guard let snapshot = prepared?.snapshot else { return }
        invalidatePreparation(); prepare(snapshot)
    }
}

/// Identity wrappers contain no AppKit state and are created on the utility task.
/// Stable objects let NSOutlineView virtualize cells without retaining names.
private final class StorageAnalysisFolderItem: NSObject, @unchecked Sendable {
    let index: Int
    init(_ index: Int) { self.index = index }
}

private struct StorageAnalysisRowSort: Equatable, Sendable {
    enum Field: String, Sendable { case logical, allocated, files, folders }
    let field: Field
    let ascending: Bool
    func value(_ folder: AnalysisFolderSummary) -> UInt64? {
        switch field {
        case .logical: folder.namespaceSubtotals.allForkLogical.knownBytes
        case .allocated: folder.namespaceSubtotals.allForkAllocated.knownBytes
        case .files: folder.counts.regularFiles
        case .folders: folder.counts.directories
        }
    }
}

private struct StorageAnalysisPreparedRows: Sendable {
    let wasPreparedOffMain = !Thread.isMainThread
    let snapshot: StorageAnalysisSnapshot
    let childOffsets: [Int]
    let childIndexes: [Int]

    // Callers translate the table's child ordinal through this slice's base.
    func children(of index: Int) -> ArraySlice<Int> {
        childIndexes[childOffsets[index]..<childOffsets[index + 1]]
    }

    static func make(_ snapshot: StorageAnalysisSnapshot, sort: StorageAnalysisRowSort) throws -> Self {
        try Task.checkCancellation()
        let count = snapshot.folders.count
        guard count > 0, snapshot.folders[0].id == .root, snapshot.folders[0].parent == nil else { throw CancellationError() }
        var offsets = [Int](repeating: 0, count: count + 1)
        for (index, folder) in snapshot.folders.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            guard folder.id.rawValue == index else { throw CancellationError() }
            if index > 0 {
                guard let parent = folder.parent?.rawValue, parent >= 0, parent < index else { throw CancellationError() }
                offsets[parent + 1] += 1
            }
        }
        for index in 1...count { offsets[index] += offsets[index - 1] }
        var next = offsets
        var children = [Int](repeating: 0, count: count - 1)
        if count > 1 {
            for index in 1..<count {
                if index % 256 == 0 { try Task.checkCancellation() }
                let parent = snapshot.folders[index].parent!.rawValue
                children[next[parent]] = index
                next[parent] += 1
            }
        }
        try children.withUnsafeMutableBufferPointer { buffer in
            for index in snapshot.folders.indices {
                if index % 256 == 0 { try Task.checkCancellation() }
                let range = offsets[index]..<offsets[index + 1]
                var siblings = UnsafeMutableBufferPointer(rebasing: buffer[range])
                try siblings.sort { left, right in
                    try Task.checkCancellation()
                    let lhs = snapshot.folders[left], rhs = snapshot.folders[right]
                    switch (sort.value(lhs), sort.value(rhs)) {
                    case (.some(let a), .some(let b)) where a != b: return sort.ascending ? a < b : a > b
                    case (.none, .some): return false
                    case (.some, .none): return true
                    default: return lhs.relativePath.lexicographicallyPrecedes(rhs.relativePath)
                    }
                }
            }
        }
        try Task.checkCancellation()
        return Self(snapshot: snapshot, childOffsets: offsets, childIndexes: children)
    }
}
