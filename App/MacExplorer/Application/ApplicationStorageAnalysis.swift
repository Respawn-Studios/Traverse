import AppKit
import Combine
import ExplorerCore
import LocalStorage
@_spi(ApplicationOwnership) import StorageAnalysis

extension Notification.Name {
    static let recentAnalysesDidChange = Notification.Name("TraverseRecentAnalysesDidChange")
}

extension AnalysisMetadataPolicy {
    static let applicationDataHelp = "Uses local names and sizes in application Containers and Group Containers, never file contents. macOS may deny access. Credentials, cloud-only locations and excluded private apps stay excluded. Defaults and remembered locations are managed in Settings."
}

struct FolderSummaryValue {
    let counts: AnalysisEntryCounts?
    let bytes: AnalysisByteSubtotals?
    let isRunning: Bool
    let isComplete: Bool
    let message: String
    let observedAt: Date
    var scanStatus: StorageScanStatus? = nil
    var coverage = AnalysisScanCoverage()
    var observationIsPrevious = false
    var scanElapsed: TimeInterval? = nil

    static func waiting(_ message: String) -> Self {
        .init(counts: nil, bytes: nil, isRunning: false, isComplete: false, message: message, observedAt: Date())
    }
    static func failed(_ failure: StorageScanFailure, message: String) -> Self {
        .init(counts: nil, bytes: nil, isRunning: false, isComplete: false, message: message,
            observedAt: Date(), scanStatus: .failed(failure))
    }
}

/// One application owner schedules foreground analysis and hover demand. Losing
/// a UI consumer never releases an actual scanner or access lease prematurely.
@MainActor
final class ApplicationStorageAnalysis {
    static let shared = ApplicationStorageAnalysis()
    private var scannerWorkerURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/storage-scanner-worker")
    private lazy var scanner = StorageScanner(
        workerURL: scannerWorkerURL,
        activityGate: ApplicationFileActivity.gate)
    private let startupDiscovery = StartupVolumeDiscovery(activityGate: ApplicationFileActivity.gate)
    private(set) var toolWindow: StorageAnalysisWindowController?
    private(set) var activeSession: StorageScanSession?
    private(set) var activePagedSession: PagedStorageScanSession?
    private var lastPagedUpdate: PagedStorageScanUpdate?
    private var lastPagedSummary: StoredAnalysisSummary?
    private let sessionReuse = SessionAnalysisReuse()
    private let recordedAnalyses = ApplicationRecordedAnalysis()
    private var recordedObservation: ApplicationRecordedAnalysis.Prepared?
    private var refreshRecordedObservation: ApplicationRecordedAnalysis.Prepared?
    private var updatingRecordedChanges = false
    private var forgetSavedOnDrain = false
    private var repairSavedOnDrain = false
    private var shutdownDrainPending = false
    private(set) var savedAnalysesMaintenanceMessage = ""
    private var keepsRecordedAnalyses: Bool {
        #if DEBUG
        if qualificationStorage != nil && !recordedAnalysesForQualification { return false }
        #endif
        return scopeSettings?.analysisKeepsResults ?? true
    }
    private var displayedObservation: SessionAnalysisObservation?
    private var sessionPresentationIsPrevious = false
    private var refreshPreviousObservation: SessionAnalysisObservation?
    private var scanReuseEpoch: UUID?
    private var sessionClearTask: Task<Void, Never>?
    private var sessionClearTaskID: UUID?
    private var clearingSessionResults = false
    private var acceptsAnalysisDemand: Bool { !isShuttingDown && !clearingSessionResults }
    private var reuseAccessObservation: AnyCancellable?
    private var reuseAccessControllerID: ObjectIdentifier?
    private var pagedPresentation: Task<Void, Never>?
    private var retiringResult: StorageAnalysisResult?
    private var retiringResultTask: Task<Void, Never>?
    // The ordinary one-root route passed the amended native memory/time gates.
    // Startup pairing passed its separate physical-source, alias and native
    // handoff/disposal gates; owner approved explicit-root activation18 October.
    private var fullResultQualified = true
    private var startupResultQualified = true
    // Activation follows the separately signed policy/control gates. Automatic
    // summaries and app-owned-state accounting never use the broader policy.
    let applicationDataControlsQualified = true
    #if DEBUG
    private(set) var pagedScanStartsForSessionReuseVerification = 0
    private(set) var allScanStartsForSessionReuseVerification = 0
    var pagedProjectionAdmissionForSessionReuseVerification: (@MainActor (StorageAnalysisResult) -> Void)?
    var cacheInsertionAdmissionForSessionReuseVerification: (@MainActor () -> Void)?
    var clearActiveForSessionReuseVerification: Bool { clearingSessionResults }
    var demandStateForSessionReuseVerification: (generation: UUID, hover: UUID?, pending: Bool, choosing: Bool) {
        (generation, hoverOwner, pendingRequest != nil, choosing != nil)
    }
    private var qualificationStorage: AnalysisResultStorage?
    private var qualificationClassificationRevision: AnalysisClassificationRevision?
    private var recordedAnalysesForQualification = false
    func enableRecordedAnalysesForQualification() { recordedAnalysesForQualification = true }
    var recordedMetadataForVerification: RecordedAnalysisMetadata? { recordedAnalyses.current?.metadata }
    var recordedOpenIssueForVerification: RecordedAnalysisIssue? { recordedAnalyses.lastOpenIssue }
    func recentOwnerStateForVerification() async -> String {
        await recordedAnalyses.recentOwnerStateForVerification()
    }
    func beginSavedForVerification(_ row: RecentAnalysis) -> Bool {
        beginExplicit(root: row.root, appState: false, metadataPolicy: row.policy,
            access: { FileAccessLifetimes(leases: []) }, cacheOnly: true, expectedCatalogID: row.id)
    }
    var beforeFinalDrainForVerification: (@MainActor () async -> Void)?
    var repairPendingForVerification: Bool { repairSavedOnDrain }
    func enablePagedForQualification(storage: AnalysisResultStorage, workerURL: URL? = nil,
                                    classificationRevision: AnalysisClassificationRevision? = nil) {
        fullResultQualified = true; qualificationStorage = storage
        qualificationClassificationRevision = classificationRevision
        if let workerURL {
            scannerWorkerURL = workerURL
            scanner = StorageScanner(workerURL: workerURL, activityGate: ApplicationFileActivity.gate)
        }
    }
    func useLegacyReferenceForQualification() { fullResultQualified = false }
    var pagedResultForVerification: StorageAnalysisResult? { lastPagedUpdate?.result }
    var sessionReuseCountForVerification: Int { sessionReuse.count }
    var sessionSnapshotForVerification: SessionAnalysisObservation? { displayedObservation }
    var sessionPresentationIsPreviousForVerification: Bool { sessionPresentationIsPrevious }
    func refreshForSessionReuseVerification() { refresh() }
    func invalidateNextRefreshHistoryForVerification() { scanner.invalidateNextRefreshHistoryForQualification() }
    func stopForSessionReuseVerification() { stop() }
    func invalidateSessionReuseForVerification() { invalidateSessionReuse() }
    func invalidateOnlyReopenCacheForSessionReuseVerification() { sessionReuse.invalidate() }
    func reviewReusedTrashForVerification(_ completion: @escaping (String) -> Void) {
        guard let snapshot = displayedObservation else { completion("No reused observation."); return }
        performLocationAction(result: snapshot.result, node: 0, action: .reviewTrash, completion: completion)
    }
    var requiresAnalysisSelectionForVerification: Bool?
    var pagedDiagnosticForVerification: [String: String] { scanner.qualificationPagedDiagnostic }
    func refreshEventsForVerification(root: URL, access: FolderAccessController) async throws -> [String: String] {
        guard !hasWork else { throw StorageScanFailure.busy }
        try configureRecordedAnalyses()
        return try await recordedAnalyses.refreshEventsForVerification(root: root, using: access)
    }
    var pagedSummaryForVerification: StoredAnalysisSummary? { lastPagedSummary }
    var pagedUpdateForVerification: PagedStorageScanUpdate? { lastPagedUpdate }
    func seedStartupAccountingForVerification(_ value: StartupStorageAccounting) { startupAccounting = value }
    #endif
    private var observation: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    private var appStorageObservation: Task<AppStorageComponent, Never>?
    private var choosing: Task<Void, Never>?
    private struct Request {
        let token: UUID
        let root: URL
        let entry: FileEntry?
        let metadataPolicy: AnalysisMetadataPolicy
        let access: @MainActor () async -> any Sendable
        let allowReuse: Bool
        let cacheOnly: Bool
        let expectedCatalogID: UUID?
        let updatingChanges: Bool
        init(token: UUID, root: URL, entry: FileEntry?, metadataPolicy: AnalysisMetadataPolicy,
             allowReuse: Bool = true, cacheOnly: Bool = false, expectedCatalogID: UUID? = nil,
             updatingChanges: Bool = false,
             access: @escaping @MainActor () async -> any Sendable) {
            self.token = token; self.root = root; self.entry = entry; self.metadataPolicy = metadataPolicy
            self.access = access; self.allowReuse = allowReuse; self.cacheOnly = cacheOnly
            self.expectedCatalogID = expectedCatalogID; self.updatingChanges = updatingChanges
        }
    }
    private struct ExplicitScanAccess: Sendable {
        let originatingAccess: any Sendable
        let selectedAccess: FolderAccessLease?
    }
    private var pendingRequest: Request?
    private let volumeReader = FilePropertiesReader()
    private let temporaryStorageReader = AnalysisTemporaryStorageReader(activityGate: ApplicationFileActivity.gate)
    private var volumeCapacity: PropertyVolumeCapacity?
    private var startupAccounting: StartupStorageAccounting?
    private var startupFallback: (generation: UUID, message: String)?
    private var generation = UUID()
    private var hoverOwner: UUID?
    private let recordedHover = RecordedHoverLookup()
    private var hoverCallback: ((FolderSummaryValue) -> Void)?
    private var explicitDemand = false
    private var stopping = false
    private var isShuttingDown = false
    private(set) var currentRoot: URL?
    private(set) var currentMetadataPolicy: AnalysisMetadataPolicy = .standard
    private var currentAccess: (@MainActor () async -> any Sendable)?
    private weak var pickerBrowser: BrowserViewController?
    private weak var analysisOriginBrowser: BrowserViewController?
    private var locationAction: Task<Void, Never>?
    private var locationActionResult: UUID?
    private var selectedOperationOwner: UUID?
    private var explicitOwner: UUID?
    private var propertyQueryDrain: (@MainActor () async -> Void)?
    private var retiringPropertyQueries: Task<Void, Never>?
    private var retiringPropertyDrainID: UUID?
    private var propertyCallback: ((FolderSummaryValue, AnalysisAttributionReport?) -> Void)?
    private var lastUpdate: StorageScanUpdate?
    private var attribution: AnalysisAttributionReport?
    private struct Projection: Sendable {
        let attribution: AnalysisAttributionReport
        let components: [AppStorageComponent]?
    }
    private var projection: Task<Projection?, Never>?
    private var projectionID: UUID?
    private var retiringProjection: (id: UUID, task: Task<Projection?, Never>)?
    private var currentIsAppState = false
    private var appStateRoot: URL?
    private struct CachedFolderSummary {
        let value: FolderSummaryValue
        let access: FolderAnalysisAccessIdentity
    }
    private var cache: [FileEntry: CachedFolderSummary] = [:]
    private var hoverAccessIdentity: FolderAnalysisAccessIdentity?
    private let chooser = FolderAccessController()
    private var pickerSettings: BrowserSettings?
    private weak var scopeSettings: BrowserSettings?
    private var scopePreferenceSubscription: AnyCancellable?
    func configureScopePreferences(_ settings: BrowserSettings?) {
        guard scopeSettings !== settings else { return }
        scopePreferenceSubscription?.cancel(); scopePreferenceSubscription = nil; scopeSettings = settings
        toolWindow?.applyToolStyle(settings)
        if let settings {
            scopePreferenceSubscription = Publishers.CombineLatest(settings.$analysisIncludesApplicationDataByDefault, settings.$analysisLocationChoices)
                .dropFirst().receive(on: RunLoop.main).sink { [weak self, weak settings] _ in
                    guard let self, let settings, self.scopeSettings === settings, !self.currentIsAppState else { return }
                    self.invalidateSessionReuse()
                    self.toolWindow?.configureNextScope(self.currentRoot.map { settings.analysisPolicy(for: $0) }
                        ?? (settings.analysisIncludesApplicationDataByDefault ? .applicationData : .standard),
                        remember: self.currentRoot.map { settings.hasAnalysisChoice(for: $0) } ?? false,
                        canRemember: self.currentRoot != nil)
                }
        }
    }
    private func configureNextScope(_ policy: AnalysisMetadataPolicy, available: Bool) {
        toolWindow?.setRequestPolicy(policy, available: available)
        if let currentRoot, !currentIsAppState {
            toolWindow?.configureNextScope(scopeSettings?.analysisPolicy(for: currentRoot) ?? .standard,
                remember: scopeSettings?.hasAnalysisChoice(for: currentRoot) == true,
                canRemember: scopeSettings != nil)
        } else if currentRoot == nil {
            toolWindow?.configureNextScope(scopeSettings?.analysisIncludesApplicationDataByDefault == true ? .applicationData : .standard,
                remember: false, canRemember: false)
        }
    }
    private func takeToolScope(for root: URL) -> AnalysisMetadataPolicy {
        let policy = toolWindow?.takeNextMetadataPolicy(default: scopeSettings?.analysisPolicy(for: root) ?? .standard) ?? .standard
        if root.standardizedFileURL == currentRoot?.standardizedFileURL, !currentIsAppState {
            scopeSettings?.rememberAnalysisPolicy(policy, for: root, remember: toolWindow?.rememberApplicationDataButton.state == .on)
        }
        return policy
    }
    private var pickerAccess: FolderAccessController?
    private var pickerVolumes: [VolumeInfo] = []
    private var customPicker: AnalysisFolderPickerController?
    private var hasActiveAnalysisWork: Bool {
        preparation != nil || appStorageObservation != nil || activeSession != nil || activePagedSession != nil
            || choosing != nil || projection != nil || pagedPresentation != nil || locationAction != nil
            || selectedOperationOwner != nil || sessionClearTask != nil
    }
    var hasWork: Bool { hasActiveAnalysisWork || retiringProjection != nil || retiringResult != nil
        || sessionReuse.isDraining || retiringPropertyQueries != nil
        || toolWindow?.hasRetiringSessionConsumers == true || recordedAnalyses.hasWork || recordedHover.hasWork }
    #if DEBUG
    var chooseFolderForVerification: (@MainActor (NSWindow, URL?) async -> FolderAccessChoice?)?
    var startupFailureForVerification: StartupStorageFailure?
    var projectionHookForVerification: (@Sendable () throws -> Void)?
    var updateForVerification: StorageScanUpdate? { lastUpdate }
    var attributionForVerification: AnalysisAttributionReport? { attribution }
    var temporaryStorageDirectoryForVerification: URL?
    var temporaryStorageReaderForVerification: AnalysisTemporaryStorageReader { temporaryStorageReader }
    var folderPickerForVerification: AnalysisFolderPickerController? { customPicker }
    func openFolderPickerForVerification() { chooseFolder() }
    #endif

    func show(from browser: BrowserViewController, root requestedRoot: URL? = nil) {
        guard acceptsAnalysisDemand else { return }
        appStateRoot = browser.settings.storageStateDirectory
        configurePicker(from: browser)
        let window = ensureWindow(appearance: browser.view.window?.effectiveAppearance)
        window.showWindow(nil)
        if let root = requestedRoot ?? browser.location.directoryURL {
            beginExplicit(root: root, appState: false, metadataPolicy: browser.settings.analysisPolicy(for: root)) { [weak browser] in
                await browser?.accessLifetime(for: [root]) ?? FileAccessLifetimes(leases: [])
            }
        } else {
            invalidateDemand(); currentRoot = nil; currentAccess = nil; currentMetadataPolicy = .standard
            window.render(root: nil, update: nil)
            window.setRequestPolicy(.standard, available: applicationDataControlsQualified)
            window.configureNextScope(browser.settings.analysisIncludesApplicationDataByDefault ? .applicationData : .standard, remember: false, canRemember: false)
        }
    }

    func showAfterUpdate(from browser: BrowserViewController) {
        guard acceptsAnalysisDemand else { return }
        configurePicker(from: browser)
        let window = ensureWindow(appearance: browser.view.window?.effectiveAppearance)
        window.render(root: nil, update: nil)
        window.showUnavailable("Choose a location to reopen its saved analysis, or start a fresh scan.")
        window.showWindow(nil)
    }

    func chooseFromDriveWorkspace(from browser: BrowserViewController) {
        guard acceptsAnalysisDemand else { return }
        configurePicker(from: browser)
        let window = ensureWindow(appearance: browser.view.window?.effectiveAppearance)
        window.showWindow(nil)
        chooseFolder()
    }

    /// The Drives page reads only the existing saved index. It does not
    /// acquire a folder grant or prepare the scanner's result pool.
    func recentSavedAnalyses(keepingResults: Bool) async -> RecentAnalysisInventory {
        guard keepingResults else { return .disabled }
        guard !isShuttingDown else { return .busy }
        do { try configureRecordedAnalyses() }
        catch { return .unavailable }
        return await recordedAnalyses.inspectRecent()
    }

    /// A dated row selects one catalog generation, not a scan request. The
    /// normal preparation pump obtains fresh selected access before reopening.
    func showSavedFromDriveWorkspace(from browser: BrowserViewController, row: RecentAnalysis) {
        guard acceptsAnalysisDemand else { return }
        configurePicker(from: browser)
        let window = ensureWindow(appearance: browser.view.window?.effectiveAppearance)
        window.showWindow(nil)
        guard beginExplicit(root: row.root, appState: false, metadataPolicy: row.policy,
            access: { [weak browser] in
                await browser?.accessLifetime(for: [row.root]) ?? FileAccessLifetimes(leases: [])
            }, cacheOnly: true, expectedCatalogID: row.id) else {
            window.showUnavailable("This saved analysis cannot be opened in the current state. Review its scope or finish the active analysis action.")
            return
        }
    }

    func showAppStorage(settings: BrowserSettings) {
        guard acceptsAnalysisDemand else { return }
        configureScopePreferences(settings)
        appStateRoot = settings.storageStateDirectory
        pickerSettings = settings
        let window = ensureWindow(appearance: NSApplication.shared.appearance)
        window.showWindow(nil)
        guard let root = appStateRoot else {
            invalidateDemand(); currentRoot = nil; currentAccess = nil; currentMetadataPolicy = .standard
            window.render(root: nil, update: nil, appStorage: true)
            window.setRequestPolicy(.standard, available: false)
            window.showUnavailable("Local settings storage is unavailable in this session.")
            return
        }
        beginExplicit(root: root, appState: true) { FileAccessLifetimes(leases: []) }
    }

    private func ensureWindow(appearance: NSAppearance?) -> StorageAnalysisWindowController {
        if let toolWindow {
            if let scopeSettings { toolWindow.applyToolStyle(scopeSettings) }
            else { toolWindow.applyAppearance(appearance) }
            return toolWindow
        }
        let window = StorageAnalysisWindowController(onChooseFolder: { [weak self] in self?.chooseFolder() },
            onRefresh: { [weak self] in self?.refresh() }, onStop: { [weak self] in self?.stop() },
            onAppStorage: { [weak self] in self?.analyzeAppState() }, appearance: appearance)
        window.onScanEveryFolder = { [weak self] in self?.refresh(scanEveryFolder: true) }
        window.setRequestPolicy(.standard, available: applicationDataControlsQualified)
        window.onClearSessionResults = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.forgetRecordedAnalyses()
            }
        }
        window.onRepairSavedAnalyses = { [weak self] in
            Task { @MainActor in await self?.repairRecordedAnalyses() }
        }
        window.onReviewAccess = { [weak self] in self?.reviewAccess() }
        window.onChooseStartupData = { [weak self] in self?.chooseStartupDataVolume() }
        window.onLocationAction = { [weak self] result, node, action, completion in
            guard let self else { completion("This analysis is no longer available."); return }
            self.performLocationAction(result: result, node: node, action: action, completion: completion)
        }
        window.onCancelLocationAction = { [weak self] result in self?.cancelLocationAction(result: result) }
        window.onClose = { [weak self] in
            guard let self else { return }
            self.cancelChooser()
            if self.explicitOwner == nil {
                let hadRecorded = self.recordedAnalyses.currentCatalogID != nil
                self.recordedAnalyses.revokeCurrent(); self.recordedObservation = nil
                self.displayedObservation = nil; self.refreshPreviousObservation = nil
                self.currentAccess = nil
                if self.explicitDemand { self.invalidateDemand() }
                else { self.cancelPagedPresentation(); self.retirePagedResult() }
                self.lastUpdate = nil
                if hadRecorded {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.recordedAnalyses.drainReleasedCatalogs()
                        NotificationCenter.default.post(name: .recentAnalysesDidChange, object: nil)
                    }
                }
            }
        }
        toolWindow = window
        if let scopeSettings { window.applyToolStyle(scopeSettings) }
        return window
    }

    private func chooseFolder(initialDirectory: URL? = nil) {
        guard acceptsAnalysisDemand, selectedOperationOwner == nil, choosing == nil, let host = toolWindow?.window else { return }
        let token = generation
        choosing = Task { [weak self] in
            guard let self else { return }
            defer { self.choosing = nil }
            guard self.acceptsAnalysisDemand else { return }
            let root: URL?
            let access = self.pickerAccess ?? self.chooser
            #if DEBUG
            if let choose = self.chooseFolderForVerification { root = await choose(host, initialDirectory ?? self.currentRoot)?.selection.url }
            else { root = await self.presentFolderPicker(in: host, access: access, initialDirectory: initialDirectory) }
            #else
            root = await self.presentFolderPicker(in: host, access: access, initialDirectory: initialDirectory)
            #endif
            guard let root, self.acceptsAnalysisDemand, self.generation == token, !Task.isCancelled, self.toolWindow?.isClosed == false else { return }
            self.choosing = nil
            let policy = self.takeToolScope(for: root)
            self.beginExplicit(root: root, appState: false, metadataPolicy: policy) {
                // Refresh acquires a fresh explicit lease. The chooser's first
                // lease is not held forever by a saved callback.
                let lease = await access.acquireAccess(to: root)
                return FileAccessLifetimes(leases: lease.map { [$0] } ?? [])
            }
        }
    }

    func canOfferStartupDataVolume(owner: UUID) -> Bool {
        explicitOwner == owner && startupFallback?.generation == generation
            && currentRoot?.path == "/" && !explicitDemand && !stopping
    }

    /// A separate explicit selection, never a silent downgrade of the verified
    /// System + Data request. The ordinary single-root owner grants and scans
    /// only the location the user actually chooses.
    func chooseStartupDataVolume(owner: UUID? = nil) {
        guard acceptsAnalysisDemand, let fallback = startupFallback,
              fallback.generation == generation, currentRoot?.path == "/",
              !explicitDemand, !stopping, selectedOperationOwner == nil,
              owner == nil || explicitOwner == owner else { return }
        let window = ensureWindow(appearance: NSApp.appearance)
        window.showWindow(nil)
        window.render(root: currentRoot, update: nil)
        window.showStartupUnavailable(fallback.message)
        chooseFolder(initialDirectory: URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true))
    }

    private func cancelChooser() {
        choosing?.cancel()
        customPicker?.cancel()
        chooser.invalidatePendingRequests()
        pickerAccess?.invalidatePendingRequests()
    }

    func configurePicker(from browser: BrowserViewController) {
        pickerBrowser = browser
        pickerSettings = browser.settings; pickerAccess = browser.folderAccess; pickerVolumes = browser.volumes
        configureScopePreferences(browser.settings)
        bindReuseAccess(browser.folderAccess)
    }
    private func bindReuseAccess(_ access: FolderAccessController) {
        let identity = ObjectIdentifier(access)
        if reuseAccessControllerID != identity {
            reuseAccessControllerID = identity
            reuseAccessObservation = access.$locations.dropFirst().sink { [weak self] _ in self?.invalidateSessionReuse() }
        }
    }
    func reviewAccess() {
        guard acceptsAnalysisDemand else { return }
        guard let browser = pickerBrowser else { return }
        TraverseSetupController.shared.show(from: browser)
        TraverseSetupController.shared.model?.page = 2
    }

    private func presentFolderPicker(in host: NSWindow, access: FolderAccessController,
                                     initialDirectory: URL? = nil) async -> URL? {
        guard acceptsAnalysisDemand else { return nil }
        guard let settings = pickerSettings, settings.analysisFolderPicker != .system else {
            return await access.chooseFolder(in: host, initialDirectory: initialDirectory ?? currentRoot)?.selection.url
        }
        let model = AnalysisFolderPickerModel(initialDirectory: initialDirectory ?? currentRoot, volumes: pickerVolumes,
            access: access, showsHidden: settings.showsHiddenFiles)
        let picker = AnalysisFolderPickerController(model: model, settings: settings, style: settings.analysisFolderPicker)
        picker.window?.appearance = host.effectiveAppearance
        customPicker = picker
        let root = await picker.choose(in: host)
        if customPicker === picker { customPicker = nil }
        return root
    }

    private func analyzeAppState() {
        guard acceptsAnalysisDemand else { return }
        guard let root = appStateRoot else {
            invalidateDemand(); currentRoot = nil; currentAccess = nil; currentMetadataPolicy = .standard
            toolWindow?.render(root: nil, update: nil, appStorage: true)
            toolWindow?.setRequestPolicy(.standard, available: false)
            toolWindow?.showUnavailable("Local settings storage is unavailable in this session.")
            return
        }
        beginExplicit(root: root, appState: true) { FileAccessLifetimes(leases: []) }
    }

    private func canUpdateChangedFolders(root: URL, metadataPolicy: AnalysisMetadataPolicy) -> Bool {
        guard acceptsAnalysisDemand, !explicitDemand, activePagedSession == nil,
              !currentIsAppState, metadataPolicy == .standard, currentMetadataPolicy == metadataPolicy,
              keepsRecordedAnalyses, currentAccess != nil, let currentRoot,
              currentRoot.standardizedFileURL.path.utf8.elementsEqual(root.standardizedFileURL.path.utf8),
              let metadata = recordedAnalyses.current?.metadata,
              !metadata.isStartupPair, metadata.metadataPolicy == .standard,
              let checkpoint = metadata.refreshCheckpoint, checkpoint.catalogID == metadata.catalogID,
              let savedRoot = metadata.recordedSingleRoot,
              savedRoot.standardizedFileURL.path.utf8.elementsEqual(currentRoot.standardizedFileURL.path.utf8),
              case .complete = metadata.status else { return false }
        return true
    }

    private func prepareChangedFolderRefresh(root: URL, policy: AnalysisMetadataPolicy, scanEveryFolder: Bool) -> Bool {
        guard !scanEveryFolder, scopeSettings?.analysisRefreshesChangedFolders != false,
              canUpdateChangedFolders(root: root, metadataPolicy: policy) else { return false }
        if recordedObservation == nil, let presentation = recordedAnalyses.current,
           let summary = lastPagedSummary, let report = attribution {
            recordedObservation = .init(presentation: presentation, summary: summary, report: report)
        }
        return true
    }

    private func refresh(scanEveryFolder: Bool = false) {
        guard acceptsAnalysisDemand else { return }
        guard let currentRoot, let currentAccess else { chooseFolder(); return }
        // Consume the next request's scope before deciding on reuse. A newly
        // selected application-data scope must never reuse the standard result.
        let policy = currentIsAppState ? AnalysisMetadataPolicy.standard : takeToolScope(for: currentRoot)
        let changes = prepareChangedFolderRefresh(root: currentRoot, policy: policy, scanEveryFolder: scanEveryFolder)
        beginExplicit(root: currentRoot, appState: currentIsAppState, metadataPolicy: policy,
            access: currentAccess, forceRefresh: true, updatingChanges: changes)
    }

    @discardableResult
    private func beginExplicit(root: URL, appState: Bool, metadataPolicy: AnalysisMetadataPolicy = .standard,
                               access: @escaping @MainActor () async -> any Sendable,
                               owner: UUID? = nil, forceRefresh: Bool = false, cacheOnly: Bool = false,
                               expectedCatalogID: UUID? = nil, updatingChanges: Bool = false,
                               drainQueries: (@MainActor () async -> Void)? = nil,
                               onChange: ((FolderSummaryValue, AnalysisAttributionReport?) -> Void)? = nil) -> Bool {
        // The existing preparation pump retains the latest explicit request
        // while previous Properties readers close. Admitting it now exposes
        // Preparing/Stop instead of dropping an enabled Analyze gesture.
        // A catalog selection is never authority to fall through to a scan.
        guard expectedCatalogID == nil || cacheOnly else { return false }
        guard acceptsAnalysisDemand else { return false }
        guard selectedOperationOwner == nil else {
            onChange?(.waiting("Finish the selected-item review before starting another analysis."), nil)
            return false
        }
        guard metadataPolicy == .standard || (applicationDataControlsQualified && fullResultQualified && !appState) else {
            let message = "Application-data analysis is unavailable in this mode. Choose standard analysis instead."
            onChange?(.waiting(message), nil)
            if owner == nil { toolWindow?.statusLabel.stringValue = message }
            return false
        }
        let policy = metadataPolicy
        let priorSaved = forceRefresh && currentRoot?.standardizedFileURL == root.standardizedFileURL
            && currentMetadataPolicy == policy ? recordedObservation : nil
        let keepsPreviousConsumer = updatingChanges && priorSaved != nil
        updatingRecordedChanges = updatingChanges
        if !keepsPreviousConsumer { recordedAnalyses.revokeCurrent(); recordedObservation = nil }
        let prior = forceRefresh && currentRoot?.standardizedFileURL == root.standardizedFileURL
            && currentMetadataPolicy == policy ? displayedObservation : nil
        startupFallback = nil
        propertyCallback?(.waiting("Stopped · another explicit analysis was requested."), nil)
        if explicitOwner != owner { retirePropertyQueries() }
        propertyQueryDrain = drainQueries
        propertyCallback = onChange; explicitOwner = owner
        appStorageObservation?.cancel()
        toolWindow?.showAppStorageSupplement(nil)
        cancelLocationAction()
        cancelProjection()
        if !keepsPreviousConsumer { cancelPagedPresentation(); retirePagedResult() }
        attribution = nil; lastUpdate = nil
        displayedObservation = prior; refreshPreviousObservation = prior
        refreshRecordedObservation = priorSaved
        sessionPresentationIsPrevious = prior != nil || priorSaved != nil
        cancelChooser()
        generation = UUID()
        let token = generation
        startupFallback = nil
        explicitDemand = true; hoverOwner = nil; hoverCallback = nil; stopping = false
        currentRoot = root; currentAccess = access; currentIsAppState = appState
        analysisOriginBrowser = pickerBrowser
        currentMetadataPolicy = policy
        // Clear before the synchronous first Properties publication. Waiting
        // until enqueue lets a reused Properties owner read the prior drive's
        // accounting under the new folder's Preparing state.
        volumeCapacity = nil; startupAccounting = nil
        if owner == nil {
            if let priorSaved { showRecordedObservation(priorSaved, root: root, refreshing: true, queryAvailable: false) }
            else if let prior { toolWindow?.showRecordedAnalysis(prior, refreshing: true) }
            else {
                toolWindow?.render(root: root, update: nil, appStorage: appState)
                toolWindow?.showRequestPreparing()
            }
        }
        else {
            toolWindow?.render(root: nil, update: nil)
            toolWindow?.showUnavailable("Analysis continues in Properties.")
            if let priorSaved { showRecordedObservation(priorSaved, root: root, refreshing: true, queryAvailable: false) }
            else if let prior { onChange?(prior.value(refreshing: true), prior.report) }
            else {
                onChange?(.init(counts: nil, bytes: nil, isRunning: true, isComplete: false,
                    message: "Preparing storage analysis…", observedAt: Date(), scanStatus: .preparing), nil)
            }
        }
        configureNextScope(policy, available: applicationDataControlsQualified && !appState)
        enqueue(.init(token: token, root: root, entry: nil, metadataPolicy: policy,
            allowReuse: !forceRefresh && expectedCatalogID == nil, cacheOnly: cacheOnly,
            expectedCatalogID: expectedCatalogID, updatingChanges: updatingChanges, access: access))
        return true
    }

    func analyzeProperties(owner: UUID, root: URL, metadataPolicy: AnalysisMetadataPolicy = .standard,
                           scanEveryFolder: Bool = false,
                           access: @escaping @MainActor () async -> any Sendable,
                           drainQueries: (@MainActor () async -> Void)? = nil,
                           onChange: @escaping (FolderSummaryValue, AnalysisAttributionReport?) -> Void) {
        let changes = prepareChangedFolderRefresh(root: root, policy: metadataPolicy, scanEveryFolder: scanEveryFolder)
        beginExplicit(root: root, appState: false, metadataPolicy: metadataPolicy, access: access, owner: owner,
            forceRefresh: true, updatingChanges: changes, drainQueries: drainQueries, onChange: onChange)
    }

    /// Opening Properties only attempts an existing session observation. A miss
    /// or failed fresh access/identity check never silently starts a new scan.
    @discardableResult
    func restoreProperties(owner: UUID, root: URL, metadataPolicy: AnalysisMetadataPolicy,
                           access: @escaping @MainActor () async -> any Sendable,
                           drainQueries: (@MainActor () async -> Void)? = nil,
                           onChange: @escaping (FolderSummaryValue, AnalysisAttributionReport?) -> Void) -> Bool {
        guard acceptsAnalysisDemand, !hasActiveAnalysisWork, let identity = reuseAccessIdentity(root: root),
              keepsRecordedAnalyses || sessionReuse.candidate(root: root, policy: metadataPolicy, access: identity) != nil else { return false }
        return beginExplicit(root: root, appState: false, metadataPolicy: metadataPolicy, access: access,
            owner: owner, cacheOnly: true, drainQueries: drainQueries, onChange: onChange)
    }
    private func reuseAccessIdentity(root: URL) -> FolderAnalysisAccessIdentity? {
        let controller = pickerAccess ?? chooser
        #if DEBUG
        let needsSelection = requiresAnalysisSelectionForVerification ?? FolderAccessController.requiresAnalysisSelection
        #else
        let needsSelection = FolderAccessController.requiresAnalysisSelection
        #endif
        return controller.analysisReuseIdentity(for: root, requiringSelection: needsSelection)
    }
    private func retirePropertyQueries() {
        guard let drain = propertyQueryDrain else { return }
        propertyQueryDrain = nil
        // Query admission below is closed throughout retirement. A newer
        // waiting owner therefore has no newly granted readers to join: retain
        // the one real drain instead of chaining one task per replaced demand.
        guard retiringPropertyQueries == nil else { return }
        let id = UUID()
        retiringPropertyDrainID = id
        retiringPropertyQueries = Task { @MainActor [weak self] in
            await drain()
            if self?.retiringPropertyDrainID == id {
                self?.retiringPropertyQueries = nil; self?.retiringPropertyDrainID = nil
            }
        }
    }
    private func invalidateSessionReuse() {
        sessionReuse.invalidate()
        if sessionPresentationIsPrevious || refreshPreviousObservation != nil || recordedObservation != nil || refreshRecordedObservation != nil {
            recordedAnalyses.revokeCurrent(); recordedObservation = nil; refreshRecordedObservation = nil
            // Revoke cached UI readers before the old reference can be retired.
            // Keep no asynchronous callback capable of republishing the chart.
            generation = UUID(); pendingRequest = nil; explicitDemand = false
            activeSession?.cancel(); activePagedSession?.cancel(); cancelPagedPresentation()
            propertyCallback?(.waiting("Access or analysis scope changed. Choose Analyze to inspect this location again."), nil)
            retirePropertyQueries()
            toolWindow?.render(root: nil, update: nil)
            retirePagedResult()
        }
        displayedObservation = nil; refreshPreviousObservation = nil; sessionPresentationIsPrevious = false
    }
    private func showRecorded(_ snapshot: SessionAnalysisObservation, refreshing: Bool, note: String? = nil) {
        if explicitOwner == nil { toolWindow?.showRecordedAnalysis(snapshot, refreshing: refreshing, note: note) }
        else { propertyCallback?(snapshot.value(refreshing: refreshing, note: note), snapshot.report) }
    }

    func stopProperties(owner: UUID) { if explicitOwner == owner { stop() } }

    func closeProperties(owner: UUID) {
        guard explicitOwner == owner else { return }
        invalidateDemand(); currentAccess = nil
    }
    func resultForProperties(owner: UUID) -> StorageAnalysisResult? {
        guard retiringPropertyQueries == nil, explicitOwner == owner,
              refreshPreviousObservation == nil, refreshRecordedObservation == nil else { return nil }
        return displayedObservation?.result ?? lastPagedUpdate?.result
    }
    func recordedQueriesForProperties(owner: UUID) -> RecordedAnalysisQueries? {
        retiringPropertyQueries == nil && explicitOwner == owner ? recordedAnalyses.recordedQueries : nil
    }
    func startupAccountingForProperties(owner: UUID) -> StartupStorageAccounting? {
        explicitOwner == owner ? startupAccounting : nil
    }

    @discardableResult
    func openFullAnalysis(owner: UUID, root requested: URL, metadataPolicy: AnalysisMetadataPolicy = .standard) -> Bool {
        guard acceptsAnalysisDemand else { return false }
        let hasRequest = explicitDemand && (preparation != nil || pendingRequest != nil || activeSession != nil || activePagedSession != nil)
        guard explicitOwner == owner || explicitOwner == nil,
              currentRoot == requested, currentMetadataPolicy == metadataPolicy, let root = currentRoot,
              lastUpdate != nil || lastPagedUpdate != nil || recordedObservation != nil || hasRequest else { return false }
        // Detach the Properties drill owner before transferring the full result.
        propertyCallback?(.waiting("Continues in Storage Analysis."), nil)
        retirePropertyQueries()
        propertyCallback = nil; explicitOwner = nil
        let window = ensureWindow(appearance: NSApplication.shared.appearance)
        window.showWindow(nil)
        let recorded = refreshPreviousObservation ?? (sessionPresentationIsPrevious ? displayedObservation : nil)
        if let saved = recordedObservation {
            window.showRecordedAnalysis(root: root, presentation: saved.presentation,
                summary: saved.summary, report: saved.report, coverage: saved.coverage)
        } else if let saved = refreshRecordedObservation {
            showRecordedObservation(saved, root: root, refreshing: hasRequest, queryAvailable: false)
        } else if let recorded { window.showRecordedAnalysis(recorded, refreshing: hasRequest) }
        else if let update = lastPagedUpdate { window.renderPaged(root: root, update: update, summary: lastPagedSummary, report: attribution, metadataPolicy: currentMetadataPolicy) }
        else { window.render(root: root, update: lastUpdate, appStorage: currentIsAppState) }
        if lastUpdate == nil && lastPagedUpdate == nil && (preparation != nil || pendingRequest != nil) && explicitDemand {
            window.showRequestPreparing()
        }
        window.showAttribution(recordedObservation?.report ?? refreshRecordedObservation?.report ?? recorded?.report ?? attribution)
        window.showVolumeCapacity(volumeCapacity)
        window.showStartupAccounting(startupAccounting)
        configureNextScope(currentMetadataPolicy, available: applicationDataControlsQualified && !currentIsAppState)
        window.setBreakdownPreparing(projection != nil || pagedPresentation != nil)
        return true
    }

    private func prepareAttribution(_ snapshot: StorageAnalysisSnapshot, root: URL, token: UUID) {
        guard acceptsAnalysisDemand, generation == token else { return }
        cancelProjection()
        let job = UUID()
        let appState = currentIsAppState
        #if DEBUG
        let diagnosticHook = projectionHookForVerification
        #endif
        let task = Task.detached(priority: .utility) { () -> Projection? in
            do {
                #if DEBUG
                try diagnosticHook?()
                #endif
                let report = try AnalysisAttributionReport.make(snapshot, scopePath: root.path)
                let components = appState ? try AppStorageInventory.inspect(root: root, snapshot: snapshot) : nil
                return Projection(attribution: report, components: components)
            } catch { return nil }
        }
        projection = task
        projectionID = job
        if explicitOwner == nil { toolWindow?.setBreakdownPreparing(true) }
        else if let update = lastUpdate { propertyCallback?(summary(update), nil) }
        Task { @MainActor [weak self] in
            let result = await task.value
            guard let self else { return }
            if self.retiringProjection?.id == job { self.retiringProjection = nil }
            guard self.acceptsAnalysisDemand, self.generation == token, self.projectionID == job else { return }
            self.projection = nil; self.projectionID = nil; self.attribution = result?.attribution
            if self.activeSession == nil { self.explicitDemand = false }
            if self.explicitOwner == nil {
                self.toolWindow?.setBreakdownPreparing(false)
                self.toolWindow?.showAttribution(result?.attribution)
                self.toolWindow?.showAppComponents(result?.components)
            } else if let update = self.lastUpdate { self.propertyCallback?(self.summary(update), result?.attribution) }
        }
    }

    func beginHover(owner: UUID, entry: FileEntry, browser: BrowserViewController,
                    onChange: @escaping (FolderSummaryValue) -> Void) {
        guard acceptsAnalysisDemand, keepsRecordedAnalyses, canReadHover(entry: entry, browser: browser) else {
            beginFreshHover(owner: owner, entry: entry, browser: browser, onChange: onChange); return
        }
        let visit = browser.sessionID, presentation = browser.filePresentationID
        let access = browser.folderAccess
        let accessIdentity = access.analysisReuseIdentity(for: entry.url,
            requiringSelection: FolderAccessController.requiresAnalysisSelection)
        recordedHover.request(owner: owner, read: { [weak self] in
            guard let self, acceptsAnalysisDemand, keepsRecordedAnalyses, !ApplicationFileActivity.gate.isClosed else { return nil }
            do { try configureRecordedAnalyses() } catch { return nil }
            return await recordedAnalyses.datedFolderSummary(root: entry.url, using: access)
        }, receive: { [weak self, weak browser] value in
            guard let self, let browser, acceptsAnalysisDemand, browser.sessionID == visit,
                  browser.filePresentationID == presentation, canReadHover(entry: entry, browser: browser) else { return }
            guard access.analysisReuseIdentity(for: entry.url,
                requiringSelection: FolderAccessController.requiresAnalysisSelection) == accessIdentity else {
                onChange(.waiting("Folder access changed. Choose this folder or its drive again.")); return
            }
            if let value, keepsRecordedAnalyses {
                onChange(value)
                ApplicationDiagnostics.shared.event(.analysisQuery, .completed, context: .init(.hoverScan))
            } else { beginFreshHover(owner: owner, entry: entry, browser: browser, onChange: onChange) }
        })
    }
    private func canReadHover(entry: FileEntry, browser: BrowserViewController) -> Bool {
        guard entry.kind == .directory, StorageAnalysisPolicy.allowsAutomaticRoot(entry.url),
              !browser.isBrowserSuspended, !browser.isOfflineCurrentFolder,
              !browser.isLoading, browser.loadError == nil, browser.issueCount == 0,
              browser.location.directoryURL == entry.url.deletingLastPathComponent(),
              browser.displayedEntries.contains(entry), browser.summaryBrowsingAccess != nil,
              !ApplicationFileActivity.gate.isClosed,
              let volume = browser.volumes.filter({ volume in
                  volume.url.path == "/" || entry.url.path == volume.url.path || entry.url.path.hasPrefix(volume.url.path + "/")
              }).max(by: { $0.url.path.count < $1.url.path.count }) else { return false }
        return volume.kind == .internalDisk || volume.kind == .externalDisk
    }
    private func beginFreshHover(owner: UUID, entry: FileEntry, browser: BrowserViewController,
                                 onChange: @escaping (FolderSummaryValue) -> Void) {
        guard acceptsAnalysisDemand else { onChange(.waiting(isShuttingDown ? "Traverse is closing." : "Session analyses are being cleared.")); return }
        guard selectedOperationOwner == nil else {
            ApplicationDiagnostics.shared.event(.analysis, .blocked, context: .init(.hoverScan, flags: [.scannerBusy]))
            onChange(.waiting("Selected-item review is using the analyzer.")); return
        }
        guard !explicitDemand, propertyCallback == nil, toolWindow?.window?.isVisible != true else {
            ApplicationDiagnostics.shared.event(.analysis, .blocked, context: .init(.hoverScan, flags: [.scannerBusy]))
            onChange(.waiting("A storage analysis is open. Close it to calculate another folder.")); return
        }
        guard canReadHover(entry: entry, browser: browser), let retained = browser.summaryBrowsingAccess else {
            var flags: [DiagnosticStateFlag] = []
            if !StorageAnalysisPolicy.allowsAutomaticRoot(entry.url) { flags.append(.policyExcluded) }
            if browser.isBrowserSuspended { flags.append(.browserSuspended) }
            if browser.isOfflineCurrentFolder { flags.append(.offline) }
            if browser.isLoading { flags.append(.browserLoading) }
            if browser.loadError != nil || browser.issueCount > 0 { flags.append(.listingIncomplete) }
            if browser.summaryBrowsingAccess != nil { flags.append(.retainedScope) }
            if ApplicationFileActivity.gate.isClosed { flags.append(.volumeBarrier) }
            ApplicationDiagnostics.shared.event(.analysis, .blocked, context: .init(.hoverScan, flags: flags))
            onChange(.waiting("Automatic summary is unavailable here. Use Storage Analysis to choose a folder.")); return
        }
        generation = UUID()
        let token = generation
        hoverOwner = owner; hoverCallback = onChange; stopping = false
        hoverAccessIdentity = browser.folderAccess.analysisReuseIdentity(for: entry.url,
            requiringSelection: FolderAccessController.requiresAnalysisSelection)
        if FolderAccessController.requiresAnalysisSelection && hoverAccessIdentity == nil {
            pendingRequest = nil; activeSession?.cancel(); activePagedSession?.cancel()
            onChange(.waiting("Choose this folder or its drive again to see a summary."))
            return
        }
        if let cached = cache[entry], cached.access == hoverAccessIdentity,
           (0...30).contains(Date().timeIntervalSince(cached.value.observedAt)) {
            // A repeated dwell reuses only a complete, short-lived observation
            // under the same access revision. It never launches another scan.
            pendingRequest = nil; activeSession?.cancel(); activePagedSession?.cancel()
            let value = cached.value
            let age = max(0, Int(Date().timeIntervalSince(value.observedAt)))
            let note = age == 0 ? "Observed just now" : "Observed \(age) \(age == 1 ? "second" : "seconds") ago"
            onChange(.init(counts: value.counts, bytes: value.bytes, isRunning: false, isComplete: true,
                message: note, observedAt: value.observedAt, scanStatus: value.scanStatus,
                coverage: value.coverage, observationIsPrevious: true, scanElapsed: value.scanElapsed))
            return
        }
        enqueue(.init(token: token, root: entry.url, entry: entry, metadataPolicy: .standard, access: { retained }))
    }

    func endHover(owner: UUID) {
        recordedHover.cancel(owner: owner)
        guard hoverOwner == owner else { return }
        invalidateDemand()
    }

    func clearCachedSummaries() {
        recordedHover.cancelAll()
        cache.removeAll(); sessionReuse.invalidate()
        if hoverOwner != nil { invalidateDemand() }
    }

    private func cancelLocationAction(result: UUID? = nil) {
        guard result == nil || result == locationActionResult else { return }
        locationAction?.cancel()
    }

    private func performLocationAction(result: StorageAnalysisResult, node: UInt64, action: StoredLocationAction,
                                       completion: @escaping (String) -> Void) {
        guard action.availableInCurrentBuild else {
            completion(action.unavailableHelp ?? "This action is unavailable in this build."); return
        }
        if action == .reviewTrash {
            sessionReuse.invalidate()
            if sessionPresentationIsPrevious || refreshPreviousObservation != nil {
                completion("This is a dated observation. Refresh the analysis before reviewing Trash."); return
            }
        }
        guard locationAction == nil else { completion("Finishing the previous location check. Try again shortly."); return }
        guard acceptsAnalysisDemand, result.supportsStoredLocations, lastPagedUpdate?.result?.id == result.id,
              let access = currentAccess, let browser = analysisOriginBrowser else {
            completion("Reopen this analysis from a browser window to inspect its locations."); return
        }
        let token = generation
        locationActionResult = result.id
        locationAction = Task { [weak self, weak browser] in
            guard let self else { return }
            defer { self.locationAction = nil; self.locationActionResult = nil }
            let retained = await access()
            guard self.acceptsAnalysisDemand, self.generation == token, !Task.isCancelled, self.lastPagedUpdate?.result?.id == result.id else {
                completion("Location check cancelled."); return
            }
            do {
                let location = try await result.resolveLocation(node: node, retainingAccess: retained)
                guard self.acceptsAnalysisDemand, self.generation == token, !Task.isCancelled, self.lastPagedUpdate?.result?.id == result.id else {
                    completion("Location check cancelled."); return
                }
                guard let browser else { completion("The original browser has closed."); return }
                if action == .reviewTrash {
                    guard !location.isSourceRoot else {
                        completion("Drive and analysis roots are protected. Select an ordinary file or folder inside the result."); return
                    }
                    let (owner, suspension) = try await self.suspendForSelectedOperation(result)
                    var operationSucceeded: Bool?
                    defer { suspension.release(); self.finishSelectedOperation(owner, succeeded: operationSucceeded) }
                    try Task.checkCancellation()
                    var protected = [Bundle.main.bundleURL] + AppStorageLocations.protectedDirectories
                    #if DEBUG
                    if let qualificationStorage = self.qualificationStorage { protected.append(qualificationStorage.directory) }
                    #endif
                    let resultID = result.id
                    let message = await browser.reviewAnalysisTrash(location, metadataPolicy: result.metadataPolicy,
                        protecting: protected, host: self.toolWindow?.window) { [weak self, weak browser] engine, outcome in
                            operationSucceeded = outcome.result.disposition == .succeeded
                            guard let self, let browser, self.lastPagedUpdate?.result?.id == resultID,
                                  let feedback = AnalysisOperationFeedback(browser: browser, engine: engine, outcome: outcome,
                                    scopeIsCurrent: { [weak self] in self?.lastPagedUpdate?.result?.id == resultID },
                                    undoConfirmed: { [weak self] recordID in
                                        guard let self, self.lastPagedUpdate?.result?.id == resultID else { return }
                                        self.toolWindow?.showConfirmedUndo(recordID: recordID)
                                    }) else { return }
                            self.toolWindow?.showOperationFeedback(feedback, node: node, browser: browser, engine: engine,
                                succeeded: outcome.result.disposition == .succeeded)
                        }
                    completion(message)
                } else { completion(browser.performAnalysisLocationAction(action, location: location)) }
            } catch is CancellationError { completion("Location check cancelled.") }
            catch StorageScanFailure.busy { completion("Another analysis read is finishing. Try again shortly.") }
            catch {
                completion("This recorded location changed, is excluded or cannot be accessed. Analyze Again to refresh.")
            }
        }
    }

    /// Analyzer-only exclusion; never closes the shared drive activity gate.
    /// Keep the selected result, but invalidate every old scan publication.
    private func suspendForSelectedOperation(_ result: StorageAnalysisResult) async throws -> (UUID, AnalysisResultReadSuspension) {
        guard selectedOperationOwner == nil, lastPagedUpdate?.result?.id == result.id else { throw StorageScanFailure.busy }
        let owner = UUID(); selectedOperationOwner = owner; generation = UUID()
        pendingRequest = nil; stopping = true; explicitDemand = false
        hoverOwner = nil; hoverCallback = nil
        startupDiscovery.cancelCurrentInquiry(); cancelChooser(); cancelProjection(); cancelPagedPresentation()
        appStorageObservation?.cancel(); activeSession?.cancel(); activePagedSession?.cancel()
        toolWindow?.statusLabel.stringValue = "Preparing selected-item review · waiting for analysis work to finish…"
        do {
            let lease = try await result.suspendReaders()
            await choosing?.value; await preparation?.value; _ = await appStorageObservation?.value
            await activeSession?.waitUntilDrained(); await activePagedSession?.waitUntilDrained()
            await pagedPresentation?.value; await drainPreviousProjection(); await drainRetiringResult()
            if Task.isCancelled { lease.release(); throw CancellationError() }
            propertyCallback?(.init(counts: lastPagedSummary?.value.counts, bytes: lastPagedSummary?.value.bytes,
                isRunning: false, isComplete: false, message: "Analysis paused for selected-item review · recorded values only.",
                observedAt: Date()), attribution)
            return (owner, lease)
        } catch { selectedOperationOwner = nil; throw error }
    }
    private func finishSelectedOperation(_ owner: UUID, succeeded: Bool?) {
        guard selectedOperationOwner == owner else { return }
        selectedOperationOwner = nil; cache.removeAll()
        switch succeeded {
        case true?: toolWindow?.statusLabel.stringValue = "Confirmed item changes are shown · chart sizes remain recorded until Refresh"
        case false?: toolWindow?.statusLabel.stringValue = "Selected operation needs attention · review its recorded locations"
        case nil: toolWindow?.statusLabel.stringValue = "Recorded analysis · selected-item review finished"
        }
    }

    func prepareForVolumeQuiescence() {
        cache.removeAll(); sessionReuse.invalidate(); stop()
    }

    func stopAndDrain(shuttingDown: Bool = false, forgettingSaved: Bool = false, repairingSaved: Bool = false) async {
        if shuttingDown { isShuttingDown = true; shutdownDrainPending = true }
        if forgettingSaved { forgetSavedOnDrain = true }
        if repairingSaved { repairSavedOnDrain = true }
        var requiresDrain = true
        while true {
            if let task = sessionClearTask, let id = sessionClearTaskID {
                await task.value
                // Another waiter may already have started the next coalesced
                // drain. Never clear its task or reopen its admission fence.
                if sessionClearTaskID == id {
                    sessionClearTask = nil; sessionClearTaskID = nil
                    clearingSessionResults = false
                    toolWindow?.setMaintenanceRunning(isShuttingDown)
                    if !isShuttingDown { sessionReuse.resumeAdmissions() }
                }
                requiresDrain = false
            } else if requiresDrain || forgetSavedOnDrain || repairSavedOnDrain || shutdownDrainPending {
                // Install both fences before any owner can suspend. A request
                // arriving in final discard drain remains flagged for another
                // pass; every waiter stays until that pass really finishes.
                clearingSessionResults = true; sessionReuse.suspendAdmissions()
                toolWindow?.setMaintenanceRunning(true)
                sessionClearTaskID = UUID()
                sessionClearTask = Task { @MainActor [self] in await performStopAndClearSessionResults() }
            } else { return }
        }
    }
    private func performStopAndClearSessionResults() async {
        await recordedHover.cancelAndDrain()
        // Only this explicit clear/Quit path revokes ALL app presentation owners.
        // Ordinary eviction never globally closes another consumer's handle.
        let retained = sessionReuse.takeAll()
        var results = retained.map(\.result)
        if let result = refreshPreviousObservation?.result { results.append(result) }
        if let result = displayedObservation?.result { results.append(result) }
        if let result = lastPagedUpdate?.result { results.append(result) }
        if let result = retiringResult { results.append(result) }
        propertyCallback?(.waiting("Session analysis references are being cleared."), nil)
        invalidateDemand()
        await toolWindow?.detachSessionConsumersAndDrain()
        currentAccess = nil
        await locationAction?.value
        await choosing?.value
        await preparation?.value
        await activeSession?.waitUntilDrained()
        await activePagedSession?.waitUntilDrained()
        await observation?.value
        await pagedPresentation?.value
        await drainRetiringResult()
        await drainPreviousProjection()
        await sessionReuse.drainEviction()
        await retiringPropertyQueries?.value
        var closed = Set<UUID>()
        for result in results where closed.insert(result.id).inserted {
            if !recordedAnalyses.managedResults.contains(result.id) {
                await result.closeAfterRevokingApplicationConsumersAndDrain()
            }
        }
        repeat {
            shutdownDrainPending = false
            let forget = forgetSavedOnDrain; forgetSavedOnDrain = false
            let repair = repairSavedOnDrain; repairSavedOnDrain = false
            await recordedAnalyses.stopAndDrain(forgetting: forget)
            if !isShuttingDown { await recordedAnalyses.resume() }
            if repair && !isShuttingDown {
                await recordedAnalyses.repairSavedAnalyses()
                savedAnalysesMaintenanceMessage = recordedAnalyses.maintenanceMessage
                if isShuttingDown { await recordedAnalyses.stopAndDrain() }
            }
        } while forgetSavedOnDrain || repairSavedOnDrain || shutdownDrainPending
        #if DEBUG
        await beforeFinalDrainForVerification?()
        #endif
        await StorageAnalysisResult.waitForScheduledStoreDiscardsAndDrain()
    }

    func resumeAfterCancelledTermination() {
        isShuttingDown = false
        recordedAnalyses.resumeWhenReady()
        if !clearingSessionResults { sessionReuse.resumeAdmissions() }
    }

    func forgetRecordedAnalyses() async {
        // Composition is inert. Only the explicit Forget opens the existing
        // history; it never starts a source scan or changes a user's files.
        try? configureRecordedAnalyses()
        await stopAndDrain(forgettingSaved: true)
        savedAnalysesMaintenanceMessage = recordedAnalyses.forgetCompleted
            ? "Saved analyses were removed. Your files are untouched."
            : "Saved analyses are unavailable or still need attention. Your files are untouched."
        NotificationCenter.default.post(name: .recentAnalysesDidChange, object: nil)
        if !isShuttingDown { toolWindow?.showUnavailable(savedAnalysesMaintenanceMessage) }
    }

    func repairRecordedAnalyses() async {
        try? configureRecordedAnalyses()
        await stopAndDrain(repairingSaved: true)
        NotificationCenter.default.post(name: .recentAnalysesDidChange, object: nil)
        if !isShuttingDown { toolWindow?.showUnavailable(savedAnalysesMaintenanceMessage) }
    }

    private func stop() {
        recordedHover.cancelAll()
        ApplicationDiagnostics.shared.event(.scanStop, .requested, trace: generation)
        stopping = true
        appStorageObservation?.cancel()
        cancelLocationAction()
        startupDiscovery.cancelCurrentInquiry()
        cancelProjection()
        cancelChooser()
        pendingRequest = nil
        activeSession?.cancel(); activePagedSession?.cancel(); cancelPagedPresentation()
        if explicitDemand, activeSession == nil, activePagedSession == nil {
            if updatingRecordedChanges, let saved = refreshRecordedObservation, let root = currentRoot {
                explicitDemand = false; updatingRecordedChanges = false
                recordedObservation = saved
                showRecordedObservation(saved, root: root, refreshing: false, queryAvailable: true)
                toolWindow?.progressLabel.stringValue = "Update stopped. The saved observation is unchanged."
                return
            }
            if let previous = refreshPreviousObservation {
                generation = UUID(); explicitDemand = false
                showRecorded(previous, refreshing: false, note: "Refresh cancelled. The dated observation is unchanged.")
                return
            }
            if let update = lastPagedUpdate {
                toolWindow?.statusLabel.stringValue = "Stopped preparing the storage breakdown · stored observations retained"
                propertyCallback?(pagedSummary(update, observed: lastPagedSummary, running: false), attribution)
                return
            }
            generation = UUID(); explicitDemand = false
            if let update = lastUpdate {
                if explicitOwner == nil {
                    toolWindow?.statusLabel.stringValue = "Stopped preparing the storage breakdown · scan observations retained"
                }
                let previous = summary(update)
                propertyCallback?(.init(counts: previous.counts, bytes: previous.bytes, isRunning: false,
                    isComplete: previous.isComplete, message: "Stopped preparing the storage breakdown.", observedAt: previous.observedAt,
                    scanStatus: .cancelled, coverage: previous.coverage), nil)
            } else {
                toolWindow?.showUnavailable("The scan was cancelled before it started.")
                propertyCallback?(.waiting("Stopped before the scan started."), nil)
            }
        }
    }

    private func invalidateDemand() {
        recordedHover.cancelAll()
        recordedAnalyses.revokeCurrent(); recordedObservation = nil; refreshRecordedObservation = nil
        generation = UUID(); pendingRequest = nil
        appStorageObservation?.cancel()
        toolWindow?.showAppStorageSupplement(nil)
        cancelLocationAction()
        startupDiscovery.cancelCurrentInquiry()
        cancelChooser()
        explicitDemand = false; hoverOwner = nil; hoverCallback = nil; hoverAccessIdentity = nil
        propertyCallback?(.waiting("Stopped · observed items only."), nil)
        retirePropertyQueries()
        propertyCallback = nil; explicitOwner = nil
        cancelProjection(); cancelPagedPresentation(); retirePagedResult(); lastUpdate = nil; attribution = nil
        displayedObservation = nil; refreshPreviousObservation = nil; scanReuseEpoch = nil; sessionPresentationIsPrevious = false
        activeSession?.cancel(); activePagedSession?.cancel()
    }

    /// One preparation pump and one replaceable pending request. Pointer churn
    /// cannot accumulate drain waiters or permission-preparation tasks.
    private func enqueue(_ request: Request) {
        guard acceptsAnalysisDemand else { return }
        if request.entry == nil {
            volumeCapacity = nil; startupAccounting = nil
            toolWindow?.showVolumeCapacity(nil); toolWindow?.showStartupAccounting(nil)
        }
        pendingRequest = request
        activeSession?.cancel(); activePagedSession?.cancel()
        guard preparation == nil else { return }
        preparation = Task { [weak self] in
            guard let self else { return }
            while let request = self.pendingRequest {
                self.pendingRequest = nil
                guard self.acceptsAnalysisDemand else { continue }
                await self.locationAction?.value
                await self.cancelPreviousWorker()
                await self.drainPreviousProjection()
                await self.sessionReuse.drainEviction()
                await self.retiringPropertyQueries?.value
                await self.toolWindow?.waitUntilRetiredQueriesDrained()
                await self.recordedAnalyses.drainReleasedCatalogs()
                await StorageAnalysisResult.waitForScheduledStoreDiscardsAndDrain()
                guard self.acceptsAnalysisDemand, self.generation == request.token, !self.stopping else { continue }
                let scanAccess = self.pickerAccess ?? self.chooser
                self.bindReuseAccess(scanAccess)
                #if DEBUG
                let needsSelection = self.requiresAnalysisSelectionForVerification ?? FolderAccessController.requiresAnalysisSelection
                #else
                let needsSelection = FolderAccessController.requiresAnalysisSelection
                #endif
                if request.cacheOnly && request.expectedCatalogID == nil && needsSelection
                    && !scanAccess.hasSelectedAccess(to: request.root) {
                    await self.sessionReuse.remove(root: request.root)
                    self.reportReuseMiss(); continue
                }
                if request.entry == nil && !self.currentIsAppState && needsSelection
                    && !scanAccess.hasSelectedAccess(to: request.root) {
                    let host = NSApplication.shared.keyWindow ?? self.toolWindow?.window ?? self.pickerBrowser?.view.window
                    guard let host else {
                        self.reportAccessPreparationFailure(request.expectedCatalogID == nil
                            ? "Choose Folder in Storage Analysis to grant access before scanning."
                            : "Choose the saved folder to grant access before reviewing its analysis.")
                        continue
                    }
                    let chosen: FolderAccessChoice?
                    #if DEBUG
                    if let choose = self.chooseFolderForVerification { chosen = await choose(host, request.root) }
                    else { chosen = await scanAccess.chooseFolder(in: host, initialDirectory: request.root, purpose: .analysis) }
                    #else
                    chosen = await scanAccess.chooseFolder(in: host, initialDirectory: request.root, purpose: .analysis)
                    #endif
                    guard self.acceptsAnalysisDemand, self.generation == request.token, !self.stopping else { continue }
                    guard chosen != nil, scanAccess.hasSelectedAccess(to: request.root) else {
                        let message: String
                        if request.expectedCatalogID != nil {
                            message = chosen == nil
                                ? "Saved analysis was not opened: folder access was cancelled."
                                : "Saved analysis was not opened: select its recorded folder or a permitted parent."
                        } else {
                            message = chosen == nil
                                ? "Analysis did not start: folder access was cancelled. Analyze Again to choose the location."
                                : "Analysis did not start: select the requested folder or drive, or one of its parents."
                        }
                        self.reportAccessPreparationFailure(message, cancelled: chosen == nil)
                        continue
                    }
                }
                let originatingAccess = await request.access()
                let selectedAccess = request.entry == nil && !self.currentIsAppState ? await scanAccess.acquireAccess(to: request.root) : nil
                let retained = ExplicitScanAccess(originatingAccess: originatingAccess, selectedAccess: selectedAccess)
                guard self.acceptsAnalysisDemand, self.generation == request.token, !self.stopping else { continue }
                // Reject a closed drive-activity admission before even the
                // shallow volume read or app-cache preparation can start.
                guard !ApplicationFileActivity.gate.isClosed else {
                    let message = "Storage Analysis is waiting for drive activity to finish. Try again afterward."
                    if self.explicitDemand { self.reportPreparationFailure(.busy, message: message) }
                    else { self.hoverCallback?(.waiting(message)) }
                    continue
                }
                if request.entry == nil && !self.currentIsAppState {
                    if request.allowReuse && request.root.path != "/" && request.root.path != "/System/Volumes/Data",
                       let identity = self.reuseAccessIdentity(root: request.root),
                       let previous = self.sessionReuse.candidate(root: request.root, policy: request.metadataPolicy, access: identity) {
                        let cacheEpoch = self.sessionReuse.epoch
                        do {
                            let stamp = try await previous.result.validateSessionReuse(root: request.root,
                                metadataPolicy: request.metadataPolicy, retainingAccess: retained)
                            guard self.acceptsAnalysisDemand, self.generation == request.token, !self.stopping else { continue }
                            guard self.sessionReuse.epoch == cacheEpoch, stamp == previous.stamp,
                                  self.reuseAccessIdentity(root: request.root) == identity else { throw StorageScanFailure.changed }
                            self.sessionReuse.touch(previous)
                            self.displayedObservation = previous; self.refreshPreviousObservation = nil; self.sessionPresentationIsPrevious = true
                            self.lastPagedUpdate = previous.update; self.lastPagedSummary = previous.summary
                            self.attribution = previous.report; self.explicitDemand = false
                            self.showRecorded(previous, refreshing: false)
                            continue
                        } catch {
                            guard self.acceptsAnalysisDemand, self.generation == request.token, !self.stopping else { continue }
                            await self.sessionReuse.remove(root: request.root)
                        }
                    }
                    if (request.allowReuse || request.expectedCatalogID != nil), self.keepsRecordedAnalyses,
                       request.expectedCatalogID != nil || (request.root.path != "/"
                           && request.root.path != "/System/Volumes/Data") {
                        try? self.configureRecordedAnalyses()
                        if let saved = await self.recordedAnalyses.open(root: request.root,
                            policy: request.metadataPolicy, expectedCatalogID: request.expectedCatalogID,
                            using: scanAccess) {
                            guard self.acceptsAnalysisDemand, self.generation == request.token,
                                  !self.stopping, !Task.isCancelled, self.keepsRecordedAnalyses else {
                                await self.recordedAnalyses.discard(saved); continue
                            }
                            let callbacks = self.recordedConsumerCallbacks(token: request.token,
                                catalogID: saved.presentation.metadata.catalogID)
                            guard self.recordedAnalyses.install(saved, revoke: callbacks.revoke, join: callbacks.join) else {
                                await self.recordedAnalyses.discard(saved)
                                if request.expectedCatalogID != nil { self.reportSavedOpenMiss(.busy) }
                                continue
                            }
                            self.recordedObservation = saved
                            self.lastPagedUpdate = nil; self.lastPagedSummary = saved.summary
                            self.displayedObservation = nil; self.refreshPreviousObservation = nil
                            self.sessionPresentationIsPrevious = true; self.attribution = saved.report
                            self.explicitDemand = false
                            self.showRecordedObservation(saved, root: request.root)
                            continue
                        }
                    }
                    if request.cacheOnly {
                        if request.expectedCatalogID != nil {
                            self.reportSavedOpenMiss(self.keepsRecordedAnalyses
                                ? self.recordedAnalyses.lastOpenIssue : .unavailable)
                        } else { self.reportReuseMiss() }
                        continue
                    }
                    self.scanReuseEpoch = self.sessionReuse.epoch
                }
                if request.entry == nil {
                    // Part of the existing single preparation owner: Stop,
                    // replacement and drive quiescence drain this shallow read.
                    let report = try? await self.volumeReader.read([request.root])
                    guard self.acceptsAnalysisDemand, self.generation == request.token, !self.stopping else { continue }
                    if self.currentIsAppState {
                        // The supplement stays independently visible when the
                        // app-state root has never been created. One existing
                        // preparation owner drains the real reader on Stop,
                        // replacement, close and device quiescence.
                        #if DEBUG
                        let pool = self.temporaryStorageDirectoryForVerification ?? AppStorageLocations.layout?.analysisDirectory
                        #else
                        let pool = AppStorageLocations.layout?.analysisDirectory
                        #endif
                        let reader = self.temporaryStorageReader
                        let task = Task.detached(priority: .utility) { await AppStorageInventory.temporaryPool(reader: reader, directory: pool) }
                        self.appStorageObservation = task
                        let component = await task.value
                        self.appStorageObservation = nil
                        guard self.acceptsAnalysisDemand, self.generation == request.token, !self.stopping else { continue }
                        let archiveComponent = ApplicationCompressedArchives.shared.storageComponent.map { [$0] } ?? []
                        self.toolWindow?.showAppStorageSupplements([component] + archiveComponent)
                        guard let state = report?.observations.first, state.failure == nil, state.isDirectory, !state.isSymbolicLink else {
                            self.toolWindow?.showUnavailable("Local app state is unavailable. Temporary analysis storage is shown below.")
                            self.explicitDemand = false
                            continue
                        }
                    } else {
                        self.volumeCapacity = report?.observations.first?.volumeCapacity
                        self.toolWindow?.showVolumeCapacity(self.volumeCapacity)
                    }
                }
                if self.explicitDemand && !self.currentIsAppState && self.fullResultQualified {
                    do { try await AppStoragePreparation.preparePortableCache() }
                    catch {
                        guard self.acceptsAnalysisDemand, self.generation == request.token, !self.stopping else { continue }
                        let message = "Private analysis storage is unavailable. Existing temporary results were preserved."
                        ApplicationDiagnostics.shared.event(.analysis, .failed, trace: request.token,
                            error: DiagnosticErrors.project(error), context: .init(.analysisTerminal), causes: DiagnosticErrors.causes(error))
                        self.reportPreparationFailure(.workerFailed, message: message)
                        continue
                    }
                    guard self.acceptsAnalysisDemand, self.generation == request.token, !self.stopping else { continue }
                }
                if self.startupResultQualified && request.entry == nil && !self.currentIsAppState && request.root.path == "/" {
                    do {
                        #if DEBUG
                        if let failure = self.startupFailureForVerification { throw failure }
                        #endif
                        let plan = try await self.startupDiscovery.discover()
                        guard self.acceptsAnalysisDemand, self.generation == request.token, !self.stopping else { continue }
                        let accounting = try? await StartupStorageAccounting.observe(plan, discovery: self.startupDiscovery, reader: self.volumeReader)
                        guard self.acceptsAnalysisDemand, self.generation == request.token, !self.stopping else { continue }
                        self.startupAccounting = accounting
                        self.toolWindow?.showStartupAccounting(accounting)
                        await self.start(root: request.root, retained: retained, token: request.token, entry: request.entry, metadataPolicy: request.metadataPolicy, startup: plan)
                    } catch {
                        guard self.acceptsAnalysisDemand, self.generation == request.token, !self.stopping else { continue }
                        let message: String
                        switch error as? StartupStorageFailure {
                        case .unsupportedSchema:
                            message = "This macOS startup layout is not yet supported for combined System + Data analysis. Choose a specific folder to analyze; Review Access explains folder permissions."
                        case .changed:
                            message = "The startup volumes changed while being checked. Analyze Again to verify them afresh."
                        case .cancelled:
                            message = "Startup analysis was cancelled before scanning."
                        default:
                            message = "The startup volumes could not be verified. Choose a specific folder, or use Review Access to select the drive and review macOS privacy settings."
                        }
                        self.explicitDemand = false
                        if error as? StartupStorageFailure != .cancelled && error as? StartupStorageFailure != .changed {
                            self.startupFallback = (request.token, message)
                            self.toolWindow?.showStartupUnavailable(message)
                        } else { self.toolWindow?.showUnavailable(message) }
                        self.propertyCallback?(.waiting(message), nil)
                    }
                } else { await self.start(root: request.root, retained: retained, token: request.token, entry: request.entry, metadataPolicy: request.metadataPolicy, updatingChanges: request.updatingChanges) }
            }
            self.preparation = nil
        }
    }

    private func cancelPreviousWorker() async {
        if let previous = activeSession {
            previous.cancel(); await previous.waitUntilDrained()
            if activeSession?.id == previous.id { activeSession = nil }
        }
        if let previous = activePagedSession {
            previous.cancel(); await previous.waitUntilDrained()
            if activePagedSession?.id == previous.id { activePagedSession = nil }
        }
        await pagedPresentation?.value
        await drainRetiringResult()
    }

    private func reportReuseMiss() {
        explicitDemand = false
        propertyCallback?(.waiting("No saved analysis is available for this location. Choose Analyze to scan it."), nil)
    }
    private func reportSavedOpenMiss(_ issue: RecordedAnalysisIssue?) {
        let message: String = switch issue {
        case .accessDenied: "Access to this saved analysis was denied. Choose its folder again to review it."
        case .busy: "Saved analyses are busy. Try again shortly."
        case .indexRequiresAttention, .retentionPending, .consumerDrainPending:
            "Saved analyses are in use or need attention. Try again after closing Storage Analysis; check Settings if this persists."
        case .cancelled: "Opening this saved analysis was cancelled."
        case .changed:
            "This saved analysis changed or was removed. Refresh Recent Analyses to see what is available."
        case .unavailable, .scan, nil:
            "This saved analysis is unavailable. Refresh Recent Analyses or review saved analyses in Settings."
        }
        toolWindow?.showUnavailable(message)
        propertyCallback?(.waiting(message), nil)
        explicitDemand = false
    }
    private func reportAccessPreparationFailure(_ message: String, cancelled: Bool = false) {
        if let previous = refreshPreviousObservation {
            showRecorded(previous, refreshing: false, note: message); explicitDemand = false; return
        }
        if cancelled {
            toolWindow?.showUnavailable("Scan cancelled")
            propertyCallback?(.init(counts: nil, bytes: nil, isRunning: false, isComplete: false,
                message: message, observedAt: Date(), scanStatus: .cancelled), nil)
        } else {
            toolWindow?.showFailure(.accessDenied)
            propertyCallback?(.failed(.accessDenied, message: message), nil)
        }
        explicitDemand = false
    }

    private func reportPreparationFailure(_ failure: StorageScanFailure, message: String) {
        if let previous = refreshPreviousObservation {
            showRecorded(previous, refreshing: false, note: message); explicitDemand = false; return
        }
        toolWindow?.showFailure(failure)
        propertyCallback?(.failed(failure, message: message), nil)
        explicitDemand = false
    }

    private func cancelPagedPresentation() {
        pagedPresentation?.cancel(); lastPagedUpdate?.result?.cancelReaders()
    }
    private func retirePagedResult() {
        if let result = lastPagedUpdate?.result {
            recordedAnalyses.release(result: result.id)
            result.cancelReaders()
            if result.activeReaderCount > 0 {
                retiringResult = result
                retiringResultTask = Task { [weak self] in
                    await result.waitUntilReadersDrained()
                    if let self, self.retiringResult?.id == result.id {
                        self.retiringResult = nil; self.retiringResultTask = nil
                    }
                }
            }
        }
        lastPagedUpdate = nil; lastPagedSummary = nil
    }
    private func drainRetiringResult() async {
        guard let old = retiringResult else { return }
        await old.waitUntilReadersDrained()
        await retiringResultTask?.value
        if retiringResult?.id == old.id { retiringResult = nil }
    }

    private func cancelProjection() {
        guard let projection, let projectionID else { return }
        projection.cancel()
        toolWindow?.setBreakdownPreparing(false)
        // The preparation pump drains this owner before admitting another job.
        // Keep its handle after Stop so quit/drive barriers can still await it.
        retiringProjection = (projectionID, projection)
        self.projection = nil; self.projectionID = nil
    }

    private func drainPreviousProjection() async {
        guard let previous = retiringProjection else { return }
        _ = await previous.task.value
        if retiringProjection?.id == previous.id { retiringProjection = nil }
    }

    private func start(root: URL, retained: any Sendable, token: UUID, entry: FileEntry?, metadataPolicy: AnalysisMetadataPolicy, startup: StartupStoragePlan? = nil, updatingChanges: Bool = false) async {
        guard acceptsAnalysisDemand, generation == token else { return }
        ApplicationDiagnostics.shared.event(.analysis, .preparing, trace: token)
        guard !ApplicationFileActivity.gate.isClosed else {
            let message = "Storage Analysis is waiting for drive activity to finish. Try again afterward."
            if explicitDemand { reportPreparationFailure(.busy, message: message) }
            else { hoverCallback?(.waiting(message)) }
            explicitDemand = false
            return
        }
        if explicitDemand && !currentIsAppState && fullResultQualified {
            await startPaged(root: root, retained: retained, token: token, metadataPolicy: metadataPolicy, startup: startup, updatingChanges: updatingChanges); return
        }
        do {
            let session = try scanner.start(root: root, retainingAccess: retained)
            activeSession = session
            #if DEBUG
            allScanStartsForSessionReuseVerification += 1
            #endif
            observation = Task { [weak self] in
                for await update in session.updates {
                    guard let self, self.acceptsAnalysisDemand, self.generation == token else { continue }
                    if update.workerDrained {
                        let error: DiagnosticErrorCode? = if case .failed(let reason) = update.status { DiagnosticErrors.project(reason) } else { nil }
                        ApplicationDiagnostics.shared.event(.analysis, DiagnosticErrors.scanPhase(update.status), trace: token,
                            duration: DiagnosticErrors.milliseconds(update.elapsed), error: error, context: .init(.analysisTerminal))
                    }
                    if self.explicitDemand {
                        self.lastUpdate = update
                        if self.explicitOwner == nil {
                            self.toolWindow?.render(root: root, update: update, appStorage: self.currentIsAppState)
                        } else { self.propertyCallback?(self.summary(update), self.attribution) }
                        if update.workerDrained, let snapshot = update.snapshot {
                            self.prepareAttribution(snapshot, root: root, token: token)
                        }
                        if self.stopping && !update.workerDrained {
                            self.toolWindow?.statusLabel.stringValue = "Stopping scan…"
                            self.toolWindow?.stopButton.isEnabled = false
                        }
                    } else if let entry {
                        let value = self.summary(update)
                        self.hoverCallback?(value)
                        if update.workerDrained, update.status == .completed, value.isComplete,
                           let identity = self.hoverAccessIdentity {
                            if self.cache.count >= 64, let oldest = self.cache.min(by: { $0.value.value.observedAt < $1.value.value.observedAt })?.key {
                                self.cache.removeValue(forKey: oldest)
                            }
                            self.cache[entry] = CachedFolderSummary(value: value, access: identity)
                        }
                    }
                }
                await session.waitUntilDrained()
                guard let self, self.activeSession?.id == session.id else { return }
                self.activeSession = nil
                if self.generation == token && self.projection == nil { self.explicitDemand = false }
            }
        } catch {
            ApplicationDiagnostics.shared.event(.analysis, .failed, trace: token,
                error: DiagnosticErrors.project(error), context: .init(.analysisTerminal), causes: DiagnosticErrors.causes(error))
            let message = error as? StorageScanFailure == .busy ? "The previous scan is still stopping. Try again shortly." : "The scan could not start. Try choosing the folder again."
            if explicitDemand { toolWindow?.showUnavailable(message); propertyCallback?(.waiting(message), nil) }
            else { hoverCallback?(.waiting(message)) }
            explicitDemand = false
        }
    }

    private func resultStorage() throws -> AnalysisResultStorage {
        #if DEBUG
        if let qualificationStorage {
            if !recordedAnalysesForQualification {
                guard qualificationStorage.retentionStateDirectory != nil ||
                    qualificationStorage.directory.standardizedFileURL.path != AppStorageLocations.layout?.analysisDirectory.standardizedFileURL.path else {
                    throw StorageScanFailure.unsupportedLocation
                }
                return qualificationStorage
            }
            return try AnalysisResultStorage(directory: qualificationStorage.directory,
                sessionByteLimit: qualificationStorage.sessionByteLimit, poolByteLimit: qualificationStorage.poolByteLimit,
                preserveAfterClose: qualificationStorage.preserveAfterClose, retentionStateDirectory: recordedIndexDirectory())
        }
        #endif
        guard let directory = AppStorageLocations.layout?.analysisDirectory else { throw StorageScanFailure.unavailable }
        return try AnalysisResultStorage(directory: directory, retentionStateDirectory: recordedIndexDirectory())
    }
    private func configureRecordedAnalyses() throws {
        try recordedAnalyses.configure(scanner: scanner, storage: resultStorage(), worker: scannerWorkerURL,
            indexDirectory: recordedIndexDirectory())
    }
    private func recordedIndexDirectory() throws -> URL {
        #if DEBUG
        if let qualificationStorage {
            return qualificationStorage.directory.deletingLastPathComponent()
                .appendingPathComponent("retained-analysis", isDirectory: true)
        }
        #endif
        guard let state = AppStorageLocations.stateDirectory else { throw StorageScanFailure.unavailable }
        return state.appendingPathComponent("retained-analysis", isDirectory: true)
    }
    private func startPaged(root: URL, retained: any Sendable, token: UUID, metadataPolicy: AnalysisMetadataPolicy, startup: StartupStoragePlan? = nil, updatingChanges: Bool = false) async {
        guard acceptsAnalysisDemand, generation == token else { return }
        ApplicationDiagnostics.shared.event(.analysis, .preparing, trace: token)
        var preparingSharedPool = false
        do {
            let storage = try resultStorage()
            let session: PagedStorageScanSession
            var admission: RecordedScanAdmission?
            if let index = storage.retentionStateDirectory {
                preparingSharedPool = true
                try await AppStoragePreparation.owner(for: index.deletingLastPathComponent()).prepare()
                try await RecordedAnalysisOwner.prepareSharedPoolForExplicitAnalysis(storage: storage,
                    activityGate: ApplicationFileActivity.gate)
                preparingSharedPool = false
            }
            guard acceptsAnalysisDemand, generation == token, !stopping, !Task.isCancelled else { return }
            if keepsRecordedAnalyses, startup == nil {
                do {
                    try configureRecordedAnalyses()
                    admission = await recordedAnalyses.begin(root: root, retainingAccess: retained, policy: metadataPolicy,
                        using: pickerAccess ?? chooser, updatingChanges: updatingChanges)
                } catch {
                    ApplicationDiagnostics.shared.event(.analysisQuery, .failed, trace: token,
                        error: DiagnosticErrors.project(error), context: .init(.analysisTerminal))
                }
            }
            guard acceptsAnalysisDemand, generation == token, !stopping, !Task.isCancelled else {
                if let admission { await recordedAnalyses.abandon(admission) }
                return
            }
            #if DEBUG
            if let qualificationClassificationRevision {
                session = try startup.map { try scanner.startStartupWithPrefixesForQualification(plan: $0, discovery: startupDiscovery,
                    storage: storage, metadataPolicy: metadataPolicy, retainingAccess: retained, checkpointRows: 16384,
                    classificationRevision: qualificationClassificationRevision) }
                    ?? scanner.startPagedDataClassificationForQualification(root: root, storage: storage, metadataPolicy: metadataPolicy,
                        retainingAccess: retained, classificationRevision: qualificationClassificationRevision)
            } else if let admission { session = admission.session }
            else {
                session = try startup.map { try scanner.startStartup(plan: $0, discovery: startupDiscovery, storage: storage, metadataPolicy: metadataPolicy, retainingAccess: retained) }
                    ?? scanner.startPaged(root: root, storage: storage, metadataPolicy: metadataPolicy, retainingAccess: retained)
            }
            #else
            if let admission { session = admission.session }
            else {
                session = try startup.map { try scanner.startStartup(plan: $0, discovery: startupDiscovery, storage: storage, metadataPolicy: metadataPolicy, retainingAccess: retained) }
                    ?? scanner.startPaged(root: root, storage: storage, metadataPolicy: metadataPolicy, retainingAccess: retained)
            }
            #endif
            #if DEBUG
            pagedScanStartsForSessionReuseVerification += 1
            allScanStartsForSessionReuseVerification += 1
            #endif
            activePagedSession = session
            let recording = recordedAnalyses, scanAdmission = admission
            observation = Task { [weak self] in
                var pendingAdmission = scanAdmission
                var terminalResult: StorageAnalysisResult?
                for await update in session.updates {
                    if update.workerDrained { terminalResult = update.result }
                    guard let self, self.acceptsAnalysisDemand, self.generation == token else { continue }
                    let previous = self.lastPagedUpdate
                    if updatingChanges, update.workerDrained, update.status != .completed {
                        if let admitted = pendingAdmission {
                            await recording.abandon(admitted, result: update.result); pendingAdmission = nil
                        }
                        if let result = update.result, !recording.managedResults.contains(result.id) {
                            await result.closeAfterRevokingApplicationConsumersAndDrain()
                        }
                        self.lastPagedUpdate = nil; self.updatingRecordedChanges = false
                        if let saved = self.refreshRecordedObservation {
                            self.recordedObservation = saved
                            self.showRecordedObservation(saved, root: root, refreshing: false, queryAvailable: true)
                            self.toolWindow?.progressLabel.stringValue = "Update did not complete. The saved observation is unchanged."
                        }
                        continue
                    }
                    if update.workerDrained && previous?.workerDrained != true {
                        let error: DiagnosticErrorCode? = if case .failed(let reason) = update.status { DiagnosticErrors.project(reason) } else { nil }
                        ApplicationDiagnostics.shared.event(.analysis, DiagnosticErrors.scanPhase(update.status), trace: token, count: update.committedEntries,
                            duration: DiagnosticErrors.milliseconds(update.elapsed), error: error, context: .init(.analysisTerminal))
                    }
                    self.lastPagedUpdate = update
                    if update.workerDrained { self.updatingRecordedChanges = false }
                    if update.workerDrained, let admitted = pendingAdmission {
                        if self.keepsRecordedAnalyses, let result = update.result,
                           update.status == .completed || update.status == .partial {
                            let callbacks = self.recordedConsumerCallbacks(token: token, catalogID: result.id)
                            let adoption = await recording.adopt(admitted, terminal: update, root: root,
                                using: self.pickerAccess ?? self.chooser, replacingCurrent: updatingChanges,
                                revoke: callbacks.revoke, join: callbacks.join)
                            pendingAdmission = nil
                            NotificationCenter.default.post(name: .recentAnalysesDidChange, object: nil)
                            guard self.acceptsAnalysisDemand, self.generation == token, !Task.isCancelled else {
                                if adoption.managed, let id = update.result?.id { recording.release(result: id) }
                                continue
                            }
                            if !adoption.canPresent {
                                self.reportPreparationFailure(.unavailable,
                                    message: "This analysis needs attention before it can be reopened. Refresh for a new result.")
                                continue
                            }
                        } else {
                            await recording.abandon(admitted, result: update.result); pendingAdmission = nil
                        }
                    }
                    if let saved = self.refreshRecordedObservation {
                        self.showRecordedObservation(saved, root: root, refreshing: !update.workerDrained, queryAvailable: false)
                        if update.workerDrained, let result = update.result,
                           update.status == .completed || update.status == .partial {
                            self.presentPaged(result, root: root, update: update, token: token)
                        }
                        continue
                    }
                    if let previous = self.refreshPreviousObservation {
                        self.showRecorded(previous, refreshing: !update.workerDrained,
                            note: update.workerDrained && update.status != .completed && update.status != .partial
                                ? "Refresh did not complete. The dated observation is unchanged." : "Refreshing with a full metadata scan…")
                        if update.workerDrained, let result = update.result,
                           update.status == .completed || update.status == .partial {
                            self.presentPaged(result, root: root, update: update, token: token)
                        }
                        continue
                    }
                    // One latest native projection, at the worker's bounded
                    // cadence. Scalar progress can repeat the same prefix.
                    if !update.workerDrained, update.status == previous?.status,
                       let prefix = update.provisionalFileTypes,
                       prefix.sequence == previous?.provisionalFileTypes?.sequence { continue }
                    self.attribution = update.provisionalFileTypes?.attributionReport()
                    if self.explicitOwner == nil { self.toolWindow?.renderPaged(root: root, update: update, metadataPolicy: metadataPolicy) }
                    else { self.propertyCallback?(self.pagedSummary(update, observed: nil, running: !update.workerDrained || update.result != nil), self.attribution) }
                    if update.workerDrained, let result = update.result { self.presentPaged(result, root: root, update: update, token: token) }
                }
                await session.waitUntilDrained()
                if let pendingAdmission { await recording.abandon(pendingAdmission, result: terminalResult) }
                guard let self, self.activePagedSession?.id == session.id else { return }
                self.activePagedSession = nil
                if self.generation == token && self.pagedPresentation == nil { self.explicitDemand = false }
            }
        } catch {
            let message = preparingSharedPool
                ? "Saved analyses couldn’t be opened. Check that Traverse’s storage is available and accessible, or choose Repair Saved Analyses in Settings. Your files are untouched."
                : "Storage analysis could not start. Its temporary storage may be full or unavailable."
            ApplicationDiagnostics.shared.event(.analysis, .failed, trace: token, error: DiagnosticErrors.project(error))
            let failure = error as? StorageScanFailure
            reportPreparationFailure(failure == .busy ? .busy : failure == .resourceLimit ? .resourceLimit : .workerFailed, message: message)
        }
    }

    private func presentPaged(_ result: StorageAnalysisResult, root: URL, update: PagedStorageScanUpdate, token: UUID) {
        guard acceptsAnalysisDemand, generation == token, pagedPresentation == nil else { return }
        #if DEBUG
        pagedProjectionAdmissionForSessionReuseVerification?(result)
        #endif
        ApplicationDiagnostics.shared.event(.analysisQuery, .reading, trace: token)
        toolWindow?.setBreakdownPreparing(true)
        pagedPresentation = Task { [weak self] in
            defer {
                if let self {
                    self.pagedPresentation = nil
                    if self.acceptsAnalysisDemand, self.generation == token { self.explicitDemand = false; self.toolWindow?.setBreakdownPreparing(false) }
                }
            }
            do {
                let summary = try await result.summary()
                let report = try await result.attribution(scopeName: root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent, summary: summary)
                guard let self, self.acceptsAnalysisDemand, self.generation == token, !Task.isCancelled else { return }
                self.lastPagedSummary = summary; self.attribution = report
                // Display ownership is independent of optional reopen caching.
                // Even capacity zero or a refused insert must retain Refresh fallback.
                let observation: SessionAnalysisObservation?
                if !self.currentIsAppState, !update.isStartupPair, let report {
                    observation = try? SessionAnalysisObservation(root: root, update: update, summary: summary, report: report, observedAt: Date())
                } else { observation = nil }
                self.refreshPreviousObservation = nil; self.refreshRecordedObservation = nil
                self.recordedObservation = nil; self.displayedObservation = observation; self.sessionPresentationIsPrevious = false
                ApplicationDiagnostics.shared.event(.analysisQuery, .completed, trace: token)
                if self.explicitOwner == nil { self.toolWindow?.renderPaged(root: root, update: update, summary: summary, report: report, metadataPolicy: result.metadataPolicy) }
                else { self.propertyCallback?(self.pagedSummary(update, observed: summary, running: false), report) }
                await self.retainSessionObservation(observation, token: token)
            } catch {
                if let self, self.acceptsAnalysisDemand, self.generation == token, !Task.isCancelled {
                    ApplicationDiagnostics.shared.event(.analysisQuery, .failed, trace: token,
                        error: DiagnosticErrors.project(error), context: .init(.analysisTerminal), causes: DiagnosticErrors.causes(error))
                    if let previous = self.refreshPreviousObservation {
                        self.showRecorded(previous, refreshing: false, note: "Refresh results could not be validated. The dated observation is unchanged.")
                    } else {
                        self.toolWindow?.showFailure(.invalidOutput)
                        self.propertyCallback?(.failed(.invalidOutput, message: "Stored observations could not be read. Scan again for a fresh result."), nil)
                    }
                }
            }
        }
    }

    private func retainSessionObservation(_ observation: SessionAnalysisObservation?, token: UUID) async {
        guard acceptsAnalysisDemand, let observation, generation == token, !Task.isCancelled,
              !recordedAnalyses.managedResults.contains(observation.result.id),
              let expectedEpoch = scanReuseEpoch, expectedEpoch == sessionReuse.epoch,
              let identity = reuseAccessIdentity(root: observation.root), let access = currentAccess else { return }
        var poolLimit = AnalysisResultStorage.maximumPoolBytes
        #if DEBUG
        if let qualificationStorage { poolLimit = qualificationStorage.poolByteLimit }
        #endif
        let capacity = SessionAnalysisReuse.capacity(poolLimit: poolLimit)
        guard capacity > 0 else { return }
        let originatingAccess = await access()
        guard acceptsAnalysisDemand, generation == token, !Task.isCancelled else { return }
        let selectedAccess = await (pickerAccess ?? chooser).acquireAccess(to: observation.root)
        let retained = ExplicitScanAccess(originatingAccess: originatingAccess, selectedAccess: selectedAccess)
        guard acceptsAnalysisDemand, generation == token, !Task.isCancelled, reuseAccessIdentity(root: observation.root) == identity else { return }
        do {
            let stamp = try await observation.result.validateSessionReuse(root: observation.root, metadataPolicy: currentMetadataPolicy, retainingAccess: retained)
            guard acceptsAnalysisDemand, generation == token, !Task.isCancelled, expectedEpoch == sessionReuse.epoch,
                  reuseAccessIdentity(root: observation.root) == identity else { return }
            let snapshot = try SessionAnalysisSnapshot(root: observation.root, update: observation.update,
                summary: observation.summary, report: observation.report, observedAt: observation.observedAt,
                stamp: stamp, accessIdentity: identity)
            #if DEBUG
            cacheInsertionAdmissionForSessionReuseVerification?()
            #endif
            guard acceptsAnalysisDemand, generation == token, !Task.isCancelled,
                  await sessionReuse.insert(snapshot, capacity: capacity, expectedEpoch: expectedEpoch),
                  acceptsAnalysisDemand, generation == token, !Task.isCancelled else { return }
            // The displayed observation already exists. Cache insertion never
            // owns its lifetime or changes its analysis time.
        } catch { /* Reopen caching may fail; displayed Refresh fallback survives. */ }
    }

    private func recordedConsumerCallbacks(token: UUID, catalogID: UUID) -> (
        revoke: @MainActor () -> Void, join: @MainActor () async -> Void
    ) {
        let callback = propertyCallback, propertyDrain = propertyQueryDrain
        // One shared controller also covers a later Properties -> Full Analysis
        // handoff. Creating it here does not show a window or launch a query.
        let window = ensureWindow(appearance: NSApp.appearance)
        return (
            { [weak self] in
                if self?.generation == token { callback?(.waiting("This saved analysis was closed."), nil) }
                window.revokeAnalysisQueries(ifShowing: catalogID)
            },
            {
                await propertyDrain?()
                await window.waitUntilAllQueriesDrained()
            }
        )
    }

    private func showRecordedObservation(_ saved: ApplicationRecordedAnalysis.Prepared, root: URL,
                                         refreshing: Bool = false, queryAvailable: Bool = true) {
        if explicitOwner == nil {
            if queryAvailable {
                toolWindow?.showRecordedAnalysis(root: root, presentation: saved.presentation,
                    summary: saved.summary, report: saved.report, coverage: saved.coverage)
            } else {
                toolWindow?.showRecordedOverview(root: root, catalogID: saved.presentation.metadata.catalogID,
                    summary: saved.summary, report: saved.report, observedAt: saved.presentation.metadata.observedThrough,
                    policy: saved.presentation.metadata.metadataPolicy, coverage: saved.coverage, refreshing: refreshing,
                    scanElapsed: saved.presentation.metadata.scanElapsed)
            }
            if refreshing && updatingRecordedChanges { toolWindow?.progressLabel.stringValue = "Checking changed folders…" }
        } else {
            let metadata = saved.presentation.metadata
            let status: StorageScanStatus = switch metadata.status { case .complete: .completed; case .partial: .partial }
            propertyCallback?(.init(counts: saved.summary.value.counts, bytes: saved.summary.value.bytes,
                isRunning: refreshing, isComplete: saved.summary.complete,
                message: StorageScanPresentation.recordedObservation(metadata.observedThrough, refresh: metadata.refreshCheckpoint)
                    + ". Refresh to check for changes.",
                observedAt: metadata.observedThrough, scanStatus: status,
                coverage: saved.coverage, observationIsPrevious: true, scanElapsed: metadata.scanElapsed), saved.report)
        }
    }

    private func pagedSummary(_ update: PagedStorageScanUpdate, observed: StoredAnalysisSummary?, running: Bool) -> FolderSummaryValue {
        let message: String
        switch update.status {
        case .preparing: message = "Preparing metadata analysis…"
        case .scanning: message = "Scanning · observed so far · \(update.committedEntries) stored entries"
        case .completed: message = running ? "Preparing stored breakdown…"
            : update.result.flatMap(StorageScanPresentation.refreshResult) ?? "Observed just now · metadata only"
        case .partial:
            message = observed.map { !$0.sources.isEmpty && $0.sources.allSatisfy(\.traversalFinished) } == true
                ? "Traversal finished · access or coverage gaps remain"
                : StorageAnalysisCoverageText.short(update.coverage) ?? "Incomplete · admitted items only"
        case .cancelled: message = "Stopped · committed observations only"
        case .failed: message = "Analysis is unavailable. Try choosing this folder again."
        }
        let systemOnly = currentRoot?.path == "/" && !update.isStartupPair
        let coverageMessage = systemOnly ? "System volume only · user files on the Data volume are not included. " + message : message
        let value = observed?.value ?? update.provisionalFileTypes?.value
        return .init(counts: value?.counts, bytes: value?.bytes, isRunning: running,
            isComplete: observed?.complete == true && !systemOnly, message: coverageMessage, observedAt: Date(),
            scanStatus: update.status, coverage: update.coverage,
            observationIsPrevious: update.result?.refreshCheckpoint?.mayContainEarlierObservations == true,
            scanElapsed: update.result?.scanElapsed ?? update.elapsed)
    }

    #if DEBUG
    func datedHoverSummaryForVerification(root: URL, access: FolderAccessController) async -> FolderSummaryValue? {
        try? configureRecordedAnalyses()
        return await recordedAnalyses.datedFolderSummary(root: root, using: access)
    }
    func verificationBegin(root: URL, access: @escaping @MainActor () async -> FileAccessLifetimes) {
        guard acceptsAnalysisDemand else { return }
        _ = ensureWindow(appearance: NSApplication.shared.appearance)
        beginExplicit(root: root, appState: false, access: access)
    }
    #endif

    private func summary(_ update: StorageScanUpdate) -> FolderSummaryValue {
        let running = !update.workerDrained || projection != nil
        let message: String
        switch update.status {
        case .preparing: message = "Preparing folder summary…"
        case .scanning: message = "Calculating… values are still incomplete"
        case .completed: message = "Observed just now · metadata only"
        case .cancelled: message = "Stopped · observed items only"
        case .partial: message = StorageAnalysisCoverageText.short(update.coverage)
            ?? "Incomplete · some items were excluded or unavailable"
        case .failed(.accessDenied): message = "Folder access was denied"
        case .failed(.unsupportedLocation): message = "Automatic summary is unavailable for this location"
        case .failed: message = "Summary unavailable · use Storage Analysis for details"
        }
        return .init(counts: update.progress?.acceptedCounts, bytes: update.progress?.namespaceSubtotals,
                     isRunning: running, isComplete: update.status == .completed && update.snapshot?.isComplete == true,
                     message: update.workerDrained && running ? "Preparing storage breakdown · " + message : message,
                     observedAt: Date(), scanStatus: update.status, coverage: update.coverage, scanElapsed: update.elapsed)
    }
}

@MainActor
extension BrowserViewController {
    @objc func showStorageAnalysis(_ sender: Any?) { ApplicationStorageAnalysis.shared.show(from: self) }
}
