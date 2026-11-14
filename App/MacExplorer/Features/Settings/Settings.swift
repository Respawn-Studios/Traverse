import AppKit
import Combine
import FileOperations
import ExplorerCore
import LocalStorage
import SwiftUI
import StorageAnalysis

typealias KeyboardProfile = BrowserKeyboardPreset

typealias BrowserViewMode = DirectoryViewMode
extension DirectoryViewMode {
    var symbolName: String {
        switch self {
        case .details: "tablecells"
        case .list: "list.bullet"
        case .icons: "square.grid.2x2"
        }
    }
}

enum BrowserRowDensity: String, CaseIterable, Codable, Identifiable {
    case comfortable = "Comfortable"
    case compact = "Compact"
    var id: Self { self }
    var rowHeight: CGFloat { self == .compact ? 20 : 25 }
}

enum NavigationStyle: String, CaseIterable, Codable, Identifiable {
    case glass = "Glass"
    case solid = "Solid"
    var id: Self { self }
}

enum OperationIndicatorPosition: String, CaseIterable, Codable, Identifiable {
    case statusBar = "Bottom status area"
    case navigation = "Navigation"
    var id: Self { self }
}

enum TransferMetadataPreference: String, CaseIterable, Codable, Identifiable {
    case strict = "Strict preservation"
    case destinationOwnership = "Native owner/group"
    var id: Self { self }
    var policy: TransferMetadataPolicy { self == .strict ? .strict : .destinationOwnership }
}

enum BrowserDefaultSearchScope: String, CaseIterable, Codable {
    case filter = "Filter loaded items"
    case folder = "Search Folder"
    case thisMac = "Search This Mac"
    var index: Int { Self.allCases.firstIndex(of: self)! }
}

enum BrowserStartupMode: String, CaseIterable, Codable {
    case computer = "This Mac"
    case lastSession = "Last session"
    case profile = "Saved profile"
}

enum BrowserNewTabDestination: String, CaseIterable, Codable, Identifiable {
    case computer, home, currentFolder
    var id: Self { self }
    var title: String {
        switch self { case .computer: "This Mac"; case .home: "Home"; case .currentFolder: "Current folder" }
    }
    func location(current: BrowserLocation, home: URL?) -> BrowserLocation {
        switch self {
        case .computer: .computer
        case .home: home.map(BrowserLocation.directory) ?? .computer
        // New remote tabs need their own explicit connection, never a copied
        // session or credentials inherited from the foreground tab.
        case .currentFolder: current.isRemote ? .computer : current
        }
    }
}

@MainActor
final class BrowserSettings: ObservableObject {
    nonisolated static let preferencesVersion = 20
    @Published private(set) var editorPreferences = EditorPreferences() { didSet { save() } }
    func updateEditorPreferences(_ value: EditorPreferences) {
        guard value.isValid else { return }
        editorPreferences = value
    }
    @Published var interfaceSize = InterfaceSize.standard { didSet { save() } }
    @Published private(set) var previousFolderApplication: URL?
    @Published var newTabDestination = BrowserNewTabDestination.computer { didSet { save() } }
    @Published var opensArchivesInTraverse = true { didSet { save() } }
    @Published var alwaysReviewArchiveCopies = false { didSet { save() } }
    @Published var asksBeforeMovingToTrash = false { didSet { save() } }
    @Published var diagnosticHistoryEnabled = true { didSet { save() } }
    @Published var crashCaptureEnabled = true { didSet { save() } }
    @Published var automaticUpdateChecks = true { didSet { save() } }
    @Published var publicAutomaticUpdateChecks = false { didSet { save() } }
    @Published var publicLastUpdateCheck: Date? { didSet { save() } }
    @Published var supportReminders = SupportReminderPreferences() { didSet { save() } }
    @Published var updateInvitationSaved = false { didSet { save() } }
    @Published var pendingUpdateBuild: UInt64 = 0 { didSet { save() } }
    @Published var privateNamesSources = PrivateNameSources.files { didSet { save() } }
    @Published var privateNamesAddressSuggestions = true { didSet { save() } }
    @Published var privateNamesAllowFollowing = false { didSet { save() } }
    @Published private(set) var privateNamesFollowingStatus = ""
    @Published var analysisChartStyle = StorageChartStyle.tilted { didSet { save() } }
    @Published var analysisIncludesApplicationDataByDefault = false { didSet { save() } }
    @Published var analysisKeepsResults = true { didSet { save() } }
    @Published var analysisRefreshesChangedFolders = true { didSet { save() } }
    @Published private(set) var analysisLocationChoices: [String: Bool] = [:] { didSet { save() } }
    func analysisPolicy(for root: URL) -> AnalysisMetadataPolicy {
        guard let key = Self.analysisLocationKey(root) else { return .standard }
        return (analysisLocationChoices[key] ?? analysisIncludesApplicationDataByDefault) ? .applicationData : .standard
    }
    func hasAnalysisChoice(for root: URL) -> Bool { Self.analysisLocationKey(root).map { analysisLocationChoices[$0] != nil } ?? false }
    func rememberAnalysisPolicy(_ policy: AnalysisMetadataPolicy, for root: URL, remember: Bool) {
        guard let key = Self.analysisLocationKey(root) else { return }
        if !remember { if analysisLocationChoices[key] != nil { analysisLocationChoices.removeValue(forKey: key) }; return }
        guard analysisLocationChoices[key] != nil || analysisLocationChoices.count < 64 else {
            preferencesPersistenceStatus = "64 analysis locations are already remembered. Clear saved locations before adding another."; return
        }
        if analysisLocationChoices[key] != (policy == .applicationData) { analysisLocationChoices[key] = policy == .applicationData }
    }
    func clearAnalysisLocationChoices() { analysisLocationChoices = [:] }
    private static func analysisLocationKey(_ root: URL) -> String? {
        guard root.isFileURL else { return nil }
        let key = root.standardizedFileURL.path
        guard key.hasPrefix("/"), key.utf8.count <= 1024, !key.utf8.contains(0) else { return nil }
        return key
    }
    @Published var analysisFolderPicker = AnalysisFolderPickerStyle.system { didSet { save() } }
    @Published var folderSummariesEnabled = true { didSet { save() } }
    @Published var folderSummaryDelay = 1.0 { didSet { save() } }
    @Published var driveHealthLiveUpdates = true { didSet { save() } }
    @Published private(set) var driveHealthPrivateBetaLiveOptIn = false { didSet { save() } }
    @Published var driveHealthIntervalSeconds = 1 { didSet { save() } }
    var driveHealthLiveUpdatesSelected: Bool {
        driveHealthLiveUpdates && (!DriveHealthFeature.requiresLiveOptIn || driveHealthPrivateBetaLiveOptIn)
    }
    func setDriveHealthLiveUpdates(_ enabled: Bool) {
        if DriveHealthFeature.requiresLiveOptIn { driveHealthPrivateBetaLiveOptIn = enabled }
        driveHealthLiveUpdates = enabled
    }
    var storageStateDirectory: URL? { file?.deletingLastPathComponent() }
    @Published var symbolTolerantNames = true { didSet { save() } }
    @Published var defaultSearchScope = BrowserDefaultSearchScope.folder { didSet { save() } }
    @Published var addressPresentation = AddressSuggestionPresentation.both { didSet { save() } }
    @Published var addressSuggestionLimit = 8 { didSet { save() } }
    @Published var ranksAddressVisits = false { didSet { updateDirectoryVisits(); save() } }
    @Published var addressVisitEntryLimit = 200 { didSet { updateDirectoryVisits(); save() } }
    @Published var addressVisitDays = 30 { didSet { updateDirectoryVisits(); save() } }
    @Published var showsCommandRow = true { didSet { save() } }
    @Published var showsPathBar = false { didSet { save() } }
    @Published var showsHiddenFiles = false { didSet { save() } }
    @Published var keyboardProfile = KeyboardProfile.explorer { didSet { save() } }
    @Published var customBehavior = BrowserBehaviorPreferences.explorer { didSet { save() } }
    @Published var shortcutPreferences = BrowserShortcutPreferences() { didSet { save() } }
    private var cachedShortcuts: (BrowserBehaviorPreferences, BrowserShortcutPreferences, BrowserShortcutMap)?
    var effectiveShortcutPreferences: BrowserShortcutPreferences { keyboardProfile == .custom ? shortcutPreferences : .init() }
    var shortcutMap: BrowserShortcutMap {
        let preferences = effectiveShortcutPreferences
        if let cachedShortcuts, cachedShortcuts.0 == behavior, cachedShortcuts.1 == preferences { return cachedShortcuts.2 }
        let map = BrowserShortcutMap(behavior: behavior, preferences: preferences)
        cachedShortcuts = (behavior, preferences, map)
        return map
    }
    @Published private(set) var preferencesPersistenceStatus = ""
    @Published private(set) var keyboardConfigurationStatus = ""
    var behavior: BrowserBehaviorPreferences { .effective(preset: keyboardProfile, custom: customBehavior) }

    func customizeBehavior() {
        let current = behavior
        let wasRestoring = restoring; restoring = true
        if keyboardProfile != .custom { shortcutPreferences = .init() }
        customBehavior = current
        keyboardProfile = .custom
        restoring = wasRestoring; save()
    }

    func resetCustomBehavior() {
        let wasRestoring = restoring; restoring = true
        customBehavior = .explorer; shortcutPreferences = .init()
        restoring = wasRestoring; keyboardConfigurationStatus = ""; save()
    }
    func updateCustomBehavior(_ change: (inout BrowserBehaviorPreferences) -> Void) {
        var proposed = customBehavior; change(&proposed)
        guard BrowserShortcutMap(behavior: proposed, preferences: shortcutPreferences).issues.isEmpty else {
            keyboardConfigurationStatus = "These behavior choices conflict with a custom shortcut. Change or clear that binding first."
            return
        }
        customBehavior = proposed; keyboardConfigurationStatus = ""
    }
    lazy var directoryVisits: BrowserDirectoryVisits = {
        let visits = BrowserAddressServices.visits(at: file?.deletingLastPathComponent())
        visits.configure(enabled: ranksAddressVisits, policy: visitPolicy)
        return visits
    }()
    private func updateDirectoryVisits() {
        guard !restoring else { return }
        directoryVisits.configure(enabled: ranksAddressVisits, policy: visitPolicy)
    }
    var visitPolicy: DirectoryVisitPolicy { .init(maximumEntries: addressVisitEntryLimit, retentionDays: addressVisitDays) }

    @Published var appearance = BrowserAppearance.system { didSet { save() } }
    @Published var motion = BrowserMotionPreferences() { didSet { save() } }
    @Published var paneFocus = PaneFocusPreferences() { didSet { save() } }
    @Published var navigationStyle = NavigationStyle.glass { didSet { save() } }
    @Published var glassNavigation = true { didSet { save() } }
    @Published var glassSidebar = true { didSet { save() } }
    @Published var glassStatusBar = true { didSet { save() } }
    @Published var glassFileContent = false { didSet { save() } }
    @Published private(set) var initialSetupCompleted = false
    @Published var restoresSession = true {
        didSet {
            if !restoring, !updatingStartup { updatingStartup = true; startupMode = restoresSession ? .lastSession : .computer; updatingStartup = false }
            save()
        }
    }
    @Published var startupMode = BrowserStartupMode.lastSession {
        didSet {
            if !restoring, !updatingStartup { updatingStartup = true; restoresSession = startupMode == .lastSession; updatingStartup = false }
            save()
        }
    }
    @Published var startupProfileID: UUID? { didSet { save() } }
    @Published private(set) var changingStartup = false
    private var updatingStartup = false
    @Published var autoRefreshFolders = true { didSet { save() } }
    @Published var operationIndicatorPosition = OperationIndicatorPosition.statusBar { didSet { save() } }
    @Published var showsDockProgress = true { didSet { save() } }
    @Published var reviewsRecoveryAtStartup = true { didSet { save() } }
    @Published var transferMetadata = TransferMetadataPreference.strict { didSet { save() } }
    @Published var conflictPreferences = TransferConflictPreferences() { didSet { save() } }
    @Published var showsSidebarEject = false { didSet { save() } }
    @Published var renamesSelectedNameOnClick = true { didSet { save() } }
    @Published var showsDriveStatus = false { didSet { save() } }
    @Published var hiddenEjectVolumes: [UUID] = [] { didSet { save() } }
    @Published var hiddenEjectSessions: Set<UUID> = []
    @Published var ejectNewWorkPolicy = EjectNewWorkPolicy.requireCancel { didSet { save() } }
    @Published var groupedCopyPreview = false { didSet { save() } }
    @Published private(set) var copyPreviewReceipt: CopyPreviewActivationReceipt?
    @Published private(set) var copyPreviewDisclosureAccepted = false
    @Published var copyPreviewStatus = ""
    var copyExecutionRequest: CopyExecutionRequest { groupedCopyPreview ? .previewIfAvailable : .standard }
    @Published var recoveryMaintenanceStatus = ""
    @Published var viewMode = BrowserViewMode.details { didSet { save() } }
    @Published var rowDensity = BrowserRowDensity.comfortable { didSet { save() } }
    @Published var showsFileExtensions = true { didSet { save() } }
    @Published var foldersFirst = true { didSet { save() } }
    @Published var showsModifiedColumn = true { didSet { save() } }
    @Published var showsKindColumn = true { didSet { save() } }
    @Published var showsSizeColumn = true { didSet { save() } }
    @Published var showsCreatedColumn = false { didSet { save() } }
    @Published var showsAccessedColumn = false { didSet { save() } }
    @Published var showsExtensionColumn = false { didSet { save() } }
    private let file: URL?
    private var persistence: CopyPreviewPreferencePersistence?
    private var restoring = false
    private var persistenceBlocked = false
    var canPersistCopyPreview: Bool { !persistenceBlocked && persistence != nil }

    private struct Saved: Codable {
        var version = BrowserSettings.preferencesVersion
        var editorPreferences = EditorPreferences()
        var newTabDestination = BrowserNewTabDestination.computer
        var opensArchivesInTraverse = true
        var alwaysReviewArchiveCopies = false
        var asksBeforeMovingToTrash = false
        var interfaceSize = InterfaceSize.standard
        var previousFolderApplication: URL?
        var motion = BrowserMotionPreferences()
        var privateNamesSources = PrivateNameSources.files
        var privateNamesAddressSuggestions = true
        var privateNamesAllowFollowing = false
        var analysisChartStyle = StorageChartStyle.tilted
        var analysisIncludesApplicationDataByDefault = false
        var analysisKeepsResults = true
        var analysisRefreshesChangedFolders = true
        var analysisLocationChoices: [String: Bool] = [:]
        var analysisFolderPicker = AnalysisFolderPickerStyle.system
        var defaultSearchScope = BrowserDefaultSearchScope.folder
        var folderSummariesEnabled = true
        var folderSummaryDelay = 1.0
        var driveHealthLiveUpdates = true
        var driveHealthPrivateBetaLiveOptIn = false
        var driveHealthIntervalSeconds = 1
        var symbolTolerantNames = true
        var addressPresentation = AddressSuggestionPresentation.both
        var addressSuggestionLimit = 8
        var ranksAddressVisits = false
        var addressVisitEntryLimit = 200
        var addressVisitDays = 30
        var diagnosticHistoryEnabled = true
        var crashCaptureEnabled = true
        var automaticUpdateChecks = true
        var publicAutomaticUpdateChecks = false
        var publicLastUpdateCheck: Date?
        var supportReminders = SupportReminderPreferences()
        var updateInvitationSaved = false
        var pendingUpdateBuild: UInt64 = 0
        var showsCommandRow = true
        var showsPathBar = false
        var showsHiddenFiles = false
        var keyboardProfile = KeyboardProfile.explorer
        var customBehavior = BrowserBehaviorPreferences.explorer
        var shortcutPreferences = BrowserShortcutPreferences()
        var appearance = BrowserAppearance.system
        var paneFocus = PaneFocusPreferences()
        var navigationStyle = NavigationStyle.glass
        var glassNavigation = true
        var glassSidebar = true
        var glassStatusBar = true
        var glassFileContent = false
        var initialSetupCompleted = false
        var restoresSession = true
        var startupMode = BrowserStartupMode.lastSession
        var startupProfileID: UUID?
        var autoRefreshFolders = true
        var operationIndicatorPosition = OperationIndicatorPosition.statusBar
        var showsDockProgress = true
        var reviewsRecoveryAtStartup = true
        var transferMetadata = TransferMetadataPreference.strict
        var conflictPreferences = TransferConflictPreferences()
        var showsSidebarEject = false
        var renamesSelectedNameOnClick = true
        var showsDriveStatus = false
        var hiddenEjectVolumes: [UUID] = []
        var ejectNewWorkPolicy = EjectNewWorkPolicy.requireCancel
        var groupedCopyPreview = false
        var copyPreviewActivationReceipt: CopyPreviewActivationReceipt?
        var copyPreviewDisclosureAccepted = false
        var viewMode = BrowserViewMode.details
        var rowDensity = BrowserRowDensity.comfortable
        var showsFileExtensions = true
        var foldersFirst = true
        var showsModifiedColumn = true
        var showsKindColumn = true
        var showsSizeColumn = true
        var showsCreatedColumn = false
        var showsAccessedColumn = false
        var showsExtensionColumn = false

        enum CodingKeys: String, CodingKey {
            case newTabDestination, interfaceSize, previousFolderApplication, editorPreferences
            case opensArchivesInTraverse, alwaysReviewArchiveCopies, asksBeforeMovingToTrash
            case privateNamesSources, privateNamesAddressSuggestions, privateNamesAllowFollowing
            case analysisChartStyle
            case analysisIncludesApplicationDataByDefault, analysisLocationChoices, analysisKeepsResults
            case analysisRefreshesChangedFolders
            case analysisFolderPicker
            case defaultSearchScope, symbolTolerantNames, folderSummariesEnabled, folderSummaryDelay
            case driveHealthLiveUpdates, driveHealthPrivateBetaLiveOptIn, driveHealthIntervalSeconds
            case addressPresentation, addressSuggestionLimit, ranksAddressVisits, addressVisitEntryLimit, addressVisitDays
            case version, showsCommandRow, showsPathBar, showsHiddenFiles, keyboardProfile, customBehavior, appearance, navigationStyle
            case diagnosticHistoryEnabled, crashCaptureEnabled
            case automaticUpdateChecks, publicAutomaticUpdateChecks, updateInvitationSaved, pendingUpdateBuild
            case publicLastUpdateCheck
            case supportReminders
            case shortcutPreferences
            case paneFocus
            case motion
            case glassNavigation, glassSidebar, glassStatusBar, glassFileContent, restoresSession, autoRefreshFolders
            case initialSetupCompleted
            case startupMode, startupProfileID
            case operationIndicatorPosition, showsDockProgress, reviewsRecoveryAtStartup
            case transferMetadata, conflictPreferences, ejectNewWorkPolicy, groupedCopyPreview, showsSidebarEject, showsDriveStatus, renamesSelectedNameOnClick, hiddenEjectVolumes
            case copyPreviewActivationReceipt, copyPreviewDisclosureAccepted
            case viewMode, rowDensity, showsFileExtensions, foldersFirst
            case showsModifiedColumn, showsKindColumn, showsSizeColumn
            case showsCreatedColumn, showsAccessedColumn, showsExtensionColumn
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            privateNamesSources = try values.decodeIfPresent(PrivateNameSources.self, forKey: .privateNamesSources) ?? .files
            privateNamesAddressSuggestions = try values.decodeIfPresent(Bool.self, forKey: .privateNamesAddressSuggestions) ?? true
            privateNamesAllowFollowing = try values.decodeIfPresent(Bool.self, forKey: .privateNamesAllowFollowing) ?? false
            version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
            editorPreferences = try values.decodeIfPresent(EditorPreferences.self, forKey: .editorPreferences) ?? .init()
            newTabDestination = try values.decodeIfPresent(BrowserNewTabDestination.self, forKey: .newTabDestination) ?? .computer
            opensArchivesInTraverse = try values.decodeIfPresent(Bool.self, forKey: .opensArchivesInTraverse) ?? true
            alwaysReviewArchiveCopies = try values.decodeIfPresent(Bool.self, forKey: .alwaysReviewArchiveCopies) ?? false
            asksBeforeMovingToTrash = try values.decodeIfPresent(Bool.self, forKey: .asksBeforeMovingToTrash) ?? false
            interfaceSize = (try? values.decode(InterfaceSize.self, forKey: .interfaceSize)) ?? .standard
            previousFolderApplication = try values.decodeIfPresent(URL.self, forKey: .previousFolderApplication)
            if let url = previousFolderApplication, !Self.validApplicationURL(url) {
                throw DecodingError.dataCorruptedError(forKey: .previousFolderApplication, in: values, debugDescription: "Invalid previous folder app")
            }
            guard (1...BrowserSettings.preferencesVersion).contains(version) else {
                throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported preferences version")
            }
            motion = try values.decodeIfPresent(BrowserMotionPreferences.self, forKey: .motion) ?? .init()
            initialSetupCompleted = try values.decodeIfPresent(Bool.self, forKey: .initialSetupCompleted) ?? false
            analysisChartStyle = try values.decodeIfPresent(StorageChartStyle.self, forKey: .analysisChartStyle) ?? .tilted
            analysisIncludesApplicationDataByDefault = try values.decodeIfPresent(Bool.self, forKey: .analysisIncludesApplicationDataByDefault) ?? false
            analysisKeepsResults = try values.decodeIfPresent(Bool.self, forKey: .analysisKeepsResults) ?? true
            analysisRefreshesChangedFolders = try values.decodeIfPresent(Bool.self, forKey: .analysisRefreshesChangedFolders) ?? true
            analysisLocationChoices = try values.decodeIfPresent([String: Bool].self, forKey: .analysisLocationChoices) ?? [:]
            guard analysisLocationChoices.count <= 64, analysisLocationChoices.keys.allSatisfy({ key in
                key.hasPrefix("/") && key.utf8.count <= 1024 && !key.utf8.contains(0) && URL(fileURLWithPath: key).standardizedFileURL.path == key
            }) else { throw DecodingError.dataCorruptedError(forKey: .analysisLocationChoices, in: values, debugDescription: "Invalid analysis locations") }
            folderSummariesEnabled = try values.decodeIfPresent(Bool.self, forKey: .folderSummariesEnabled) ?? true
            analysisFolderPicker = try values.decodeIfPresent(AnalysisFolderPickerStyle.self, forKey: .analysisFolderPicker) ?? .system
            folderSummaryDelay = try values.decodeIfPresent(Double.self, forKey: .folderSummaryDelay) ?? 1
            guard folderSummaryDelay.isFinite, (0.3...5).contains(folderSummaryDelay) else {
                throw DecodingError.dataCorruptedError(forKey: .folderSummaryDelay, in: values, debugDescription: "Invalid folder summary delay")
            }
            driveHealthLiveUpdates = try values.decodeIfPresent(Bool.self, forKey: .driveHealthLiveUpdates) ?? true
            driveHealthPrivateBetaLiveOptIn = try values.decodeIfPresent(Bool.self, forKey: .driveHealthPrivateBetaLiveOptIn) ?? false
            driveHealthIntervalSeconds = try values.decodeIfPresent(Int.self, forKey: .driveHealthIntervalSeconds) ?? 1
            guard [1, 2, 5, 10, 30, 60].contains(driveHealthIntervalSeconds) else {
                throw DecodingError.dataCorruptedError(forKey: .driveHealthIntervalSeconds, in: values, debugDescription: "Invalid drive health interval")
            }
            symbolTolerantNames = try values.decodeIfPresent(Bool.self, forKey: .symbolTolerantNames) ?? true
            defaultSearchScope = try values.decodeIfPresent(BrowserDefaultSearchScope.self, forKey: .defaultSearchScope) ?? .folder
            addressPresentation = try values.decodeIfPresent(AddressSuggestionPresentation.self, forKey: .addressPresentation) ?? .both
            addressSuggestionLimit = try values.decodeIfPresent(Int.self, forKey: .addressSuggestionLimit) ?? 8
            ranksAddressVisits = try values.decodeIfPresent(Bool.self, forKey: .ranksAddressVisits) ?? false
            addressVisitEntryLimit = try values.decodeIfPresent(Int.self, forKey: .addressVisitEntryLimit) ?? 200
            addressVisitDays = try values.decodeIfPresent(Int.self, forKey: .addressVisitDays) ?? 30
            guard (3...12).contains(addressSuggestionLimit), (10...1_000).contains(addressVisitEntryLimit), (1...365).contains(addressVisitDays) else {
                throw DecodingError.dataCorruptedError(forKey: .addressSuggestionLimit, in: values, debugDescription: "Invalid address settings")
            }
            diagnosticHistoryEnabled = try values.decodeIfPresent(Bool.self, forKey: .diagnosticHistoryEnabled) ?? true
            crashCaptureEnabled = try values.decodeIfPresent(Bool.self, forKey: .crashCaptureEnabled) ?? true
            automaticUpdateChecks = try values.decodeIfPresent(Bool.self, forKey: .automaticUpdateChecks) ?? true
            publicAutomaticUpdateChecks = try values.decodeIfPresent(Bool.self, forKey: .publicAutomaticUpdateChecks) ?? false
            publicLastUpdateCheck = try values.decodeIfPresent(Date.self, forKey: .publicLastUpdateCheck)
            supportReminders = try values.decodeIfPresent(SupportReminderPreferences.self, forKey: .supportReminders) ?? .init()
            updateInvitationSaved = try values.decodeIfPresent(Bool.self, forKey: .updateInvitationSaved) ?? false
            pendingUpdateBuild = try values.decodeIfPresent(UInt64.self, forKey: .pendingUpdateBuild) ?? 0
            showsCommandRow = try values.decodeIfPresent(Bool.self, forKey: .showsCommandRow) ?? true
            showsPathBar = try values.decodeIfPresent(Bool.self, forKey: .showsPathBar) ?? false
            showsHiddenFiles = try values.decodeIfPresent(Bool.self, forKey: .showsHiddenFiles) ?? false
            keyboardProfile = try values.decodeIfPresent(KeyboardProfile.self, forKey: .keyboardProfile) ?? .explorer
            customBehavior = try values.decodeIfPresent(BrowserBehaviorPreferences.self, forKey: .customBehavior) ?? .explorer
            shortcutPreferences = try values.decodeIfPresent(BrowserShortcutPreferences.self, forKey: .shortcutPreferences) ?? .init()
            let map = BrowserShortcutMap(behavior: .effective(preset: keyboardProfile, custom: customBehavior),
                                         preferences: keyboardProfile == .custom ? shortcutPreferences : .init())
            let customMap = BrowserShortcutMap(behavior: customBehavior, preferences: shortcutPreferences)
            guard map.issues.isEmpty, customMap.issues.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .shortcutPreferences, in: values, debugDescription: "Invalid or conflicting shortcuts")
            }
            appearance = try values.decodeIfPresent(BrowserAppearance.self, forKey: .appearance) ?? .system
            paneFocus = try values.decodeIfPresent(PaneFocusPreferences.self, forKey: .paneFocus) ?? .init()
            guard paneFocus.isValid else {
                throw DecodingError.dataCorruptedError(forKey: .paneFocus, in: values, debugDescription: "Invalid pane focus preference")
            }
            navigationStyle = try values.decodeIfPresent(NavigationStyle.self, forKey: .navigationStyle) ?? .glass
            glassNavigation = try values.decodeIfPresent(Bool.self, forKey: .glassNavigation) ?? true
            glassSidebar = try values.decodeIfPresent(Bool.self, forKey: .glassSidebar) ?? true
            glassStatusBar = try values.decodeIfPresent(Bool.self, forKey: .glassStatusBar) ?? true
            glassFileContent = try values.decodeIfPresent(Bool.self, forKey: .glassFileContent) ?? false
            // New profiles reopen by default. Existing documents, including
            // versions predating startupMode, retain their earlier opt-in rule.
            restoresSession = try values.decodeIfPresent(Bool.self, forKey: .restoresSession) ?? false
            startupMode = try values.decodeIfPresent(BrowserStartupMode.self, forKey: .startupMode) ?? (restoresSession ? .lastSession : .computer)
            startupProfileID = try values.decodeIfPresent(UUID.self, forKey: .startupProfileID)
            guard startupMode != .profile || startupProfileID != nil else {
                throw DecodingError.dataCorruptedError(forKey: .startupProfileID, in: values, debugDescription: "Missing launch profile selection")
            }
            restoresSession = startupMode == .lastSession
            autoRefreshFolders = try values.decodeIfPresent(Bool.self, forKey: .autoRefreshFolders) ?? true
            operationIndicatorPosition = try values.decodeIfPresent(OperationIndicatorPosition.self, forKey: .operationIndicatorPosition) ?? .statusBar
            showsDockProgress = try values.decodeIfPresent(Bool.self, forKey: .showsDockProgress) ?? true
            reviewsRecoveryAtStartup = try values.decodeIfPresent(Bool.self, forKey: .reviewsRecoveryAtStartup) ?? true
            transferMetadata = try values.decodeIfPresent(TransferMetadataPreference.self, forKey: .transferMetadata) ?? .strict
            conflictPreferences = try values.decodeIfPresent(TransferConflictPreferences.self, forKey: .conflictPreferences) ?? .init()
            showsSidebarEject = try values.decodeIfPresent(Bool.self, forKey: .showsSidebarEject) ?? false
            renamesSelectedNameOnClick = try values.decodeIfPresent(Bool.self, forKey: .renamesSelectedNameOnClick) ?? true
            showsDriveStatus = try values.decodeIfPresent(Bool.self, forKey: .showsDriveStatus) ?? false
            hiddenEjectVolumes = try values.decodeIfPresent([UUID].self, forKey: .hiddenEjectVolumes) ?? []
            guard hiddenEjectVolumes.count <= 256, Set(hiddenEjectVolumes).count == hiddenEjectVolumes.count else {
                throw DecodingError.dataCorruptedError(forKey: .hiddenEjectVolumes, in: values, debugDescription: "Invalid hidden drive preferences")
            }
            ejectNewWorkPolicy = try values.decodeIfPresent(EjectNewWorkPolicy.self, forKey: .ejectNewWorkPolicy) ?? .requireCancel
            groupedCopyPreview = try values.decodeIfPresent(Bool.self, forKey: .groupedCopyPreview) ?? false
            copyPreviewActivationReceipt = try values.decodeIfPresent(CopyPreviewActivationReceipt.self, forKey: .copyPreviewActivationReceipt)
            copyPreviewDisclosureAccepted = try values.decodeIfPresent(Bool.self, forKey: .copyPreviewDisclosureAccepted) ?? false
            viewMode = try values.decodeIfPresent(BrowserViewMode.self, forKey: .viewMode) ?? .details
            rowDensity = try values.decodeIfPresent(BrowserRowDensity.self, forKey: .rowDensity) ?? .comfortable
            showsFileExtensions = try values.decodeIfPresent(Bool.self, forKey: .showsFileExtensions) ?? true
            foldersFirst = try values.decodeIfPresent(Bool.self, forKey: .foldersFirst) ?? true
            showsModifiedColumn = try values.decodeIfPresent(Bool.self, forKey: .showsModifiedColumn) ?? true
            showsKindColumn = try values.decodeIfPresent(Bool.self, forKey: .showsKindColumn) ?? true
            showsSizeColumn = try values.decodeIfPresent(Bool.self, forKey: .showsSizeColumn) ?? true
            showsCreatedColumn = try values.decodeIfPresent(Bool.self, forKey: .showsCreatedColumn) ?? false
            showsAccessedColumn = try values.decodeIfPresent(Bool.self, forKey: .showsAccessedColumn) ?? false
            showsExtensionColumn = try values.decodeIfPresent(Bool.self, forKey: .showsExtensionColumn) ?? false
        }

        static func validApplicationURL(_ url: URL) -> Bool {
            url.isFileURL && url.path.hasPrefix("/") && url.pathExtension == "app" && url.absoluteString.utf8.count <= 8192
                && !url.path.utf8.contains(0) && url.user == nil && url.password == nil && url.port == nil
                && url.query == nil && url.fragment == nil && (url.host == nil || url.host == "" || url.host == "localhost")
        }

        @MainActor init(_ settings: BrowserSettings) {
            editorPreferences = settings.editorPreferences
            initialSetupCompleted = settings.initialSetupCompleted
            motion = settings.motion
            privateNamesSources = settings.privateNamesSources
            privateNamesAddressSuggestions = settings.privateNamesAddressSuggestions
            privateNamesAllowFollowing = settings.privateNamesAllowFollowing
            analysisChartStyle = settings.analysisChartStyle
            analysisIncludesApplicationDataByDefault = settings.analysisIncludesApplicationDataByDefault
            analysisKeepsResults = settings.analysisKeepsResults
            analysisRefreshesChangedFolders = settings.analysisRefreshesChangedFolders
            analysisLocationChoices = settings.analysisLocationChoices
            analysisFolderPicker = settings.analysisFolderPicker
            folderSummariesEnabled = settings.folderSummariesEnabled
            folderSummaryDelay = settings.folderSummaryDelay
            driveHealthLiveUpdates = settings.driveHealthLiveUpdates
            driveHealthPrivateBetaLiveOptIn = settings.driveHealthPrivateBetaLiveOptIn
            driveHealthIntervalSeconds = settings.driveHealthIntervalSeconds
            symbolTolerantNames = settings.symbolTolerantNames
            defaultSearchScope = settings.defaultSearchScope
            addressPresentation = settings.addressPresentation
            addressSuggestionLimit = settings.addressSuggestionLimit
            ranksAddressVisits = settings.ranksAddressVisits
            addressVisitEntryLimit = settings.addressVisitEntryLimit
            addressVisitDays = settings.addressVisitDays
            diagnosticHistoryEnabled = settings.diagnosticHistoryEnabled
            crashCaptureEnabled = settings.crashCaptureEnabled
            automaticUpdateChecks = settings.automaticUpdateChecks
            publicAutomaticUpdateChecks = settings.publicAutomaticUpdateChecks
            publicLastUpdateCheck = settings.publicLastUpdateCheck
            supportReminders = settings.supportReminders
            updateInvitationSaved = settings.updateInvitationSaved
            pendingUpdateBuild = settings.pendingUpdateBuild
            showsCommandRow = settings.showsCommandRow
            showsPathBar = settings.showsPathBar
            showsHiddenFiles = settings.showsHiddenFiles
            keyboardProfile = settings.keyboardProfile
            customBehavior = settings.customBehavior
            shortcutPreferences = settings.shortcutPreferences
            appearance = settings.appearance
            paneFocus = settings.paneFocus
            navigationStyle = settings.navigationStyle
            glassNavigation = settings.glassNavigation
            glassSidebar = settings.glassSidebar
            glassStatusBar = settings.glassStatusBar
            glassFileContent = settings.glassFileContent
            restoresSession = settings.restoresSession
            startupMode = settings.startupMode
            newTabDestination = settings.newTabDestination
            opensArchivesInTraverse = settings.opensArchivesInTraverse
            alwaysReviewArchiveCopies = settings.alwaysReviewArchiveCopies
            asksBeforeMovingToTrash = settings.asksBeforeMovingToTrash
            interfaceSize = settings.interfaceSize
            previousFolderApplication = settings.previousFolderApplication
            startupProfileID = settings.startupProfileID
            autoRefreshFolders = settings.autoRefreshFolders
            operationIndicatorPosition = settings.operationIndicatorPosition
            showsDockProgress = settings.showsDockProgress
            reviewsRecoveryAtStartup = settings.reviewsRecoveryAtStartup
            transferMetadata = settings.transferMetadata
            conflictPreferences = settings.conflictPreferences
            showsSidebarEject = settings.showsSidebarEject
            renamesSelectedNameOnClick = settings.renamesSelectedNameOnClick
            showsDriveStatus = settings.showsDriveStatus
            hiddenEjectVolumes = settings.hiddenEjectVolumes
            ejectNewWorkPolicy = settings.ejectNewWorkPolicy
            groupedCopyPreview = settings.groupedCopyPreview
            copyPreviewActivationReceipt = settings.copyPreviewReceipt
            copyPreviewDisclosureAccepted = settings.copyPreviewDisclosureAccepted
            viewMode = settings.viewMode
            rowDensity = settings.rowDensity
            showsFileExtensions = settings.showsFileExtensions
            foldersFirst = settings.foldersFirst
            showsModifiedColumn = settings.showsModifiedColumn
            showsKindColumn = settings.showsKindColumn
            showsSizeColumn = settings.showsSizeColumn
            showsCreatedColumn = settings.showsCreatedColumn
            showsAccessedColumn = settings.showsAccessedColumn
            showsExtensionColumn = settings.showsExtensionColumn
        }
    }

    /// Portable startup supplies an already bounded background snapshot. The
    /// explicit skip also distinguishes a missing snapshot from a read request.
    init(persist: Bool, restoredData: Data? = nil, persistenceFile: URL? = nil, skipDiskRead: Bool = false) {
        if let persistenceFile { file = persistenceFile }
        else if persist, let root = AppStorageLocations.stateDirectory {
            file = root.appendingPathComponent("preferences.json")
        } else {
            file = nil
        }
        if let data = restoredData ?? (skipDiskRead ? nil : file.flatMap({ try? Data(contentsOf: $0) })) {
            guard data.count <= 128 * 1_024, let value = try? JSONDecoder().decode(Saved.self, from: data) else {
                persistenceBlocked = true
                preferencesPersistenceStatus = "Saved settings are unavailable or from a newer version. They were preserved; changes apply only for this session."
                return
            }
            restoring = true
            editorPreferences = value.editorPreferences
            initialSetupCompleted = value.initialSetupCompleted
            motion = value.motion
            privateNamesSources = value.privateNamesSources
            privateNamesAddressSuggestions = value.privateNamesAddressSuggestions
            privateNamesAllowFollowing = value.privateNamesAllowFollowing
            analysisChartStyle = value.analysisChartStyle
            analysisIncludesApplicationDataByDefault = value.analysisIncludesApplicationDataByDefault
            analysisKeepsResults = value.analysisKeepsResults
            analysisRefreshesChangedFolders = value.analysisRefreshesChangedFolders
            analysisLocationChoices = value.analysisLocationChoices
            analysisFolderPicker = value.analysisFolderPicker
            folderSummariesEnabled = value.folderSummariesEnabled
            folderSummaryDelay = value.folderSummaryDelay
            driveHealthLiveUpdates = value.driveHealthLiveUpdates
            driveHealthPrivateBetaLiveOptIn = value.driveHealthPrivateBetaLiveOptIn
            driveHealthIntervalSeconds = value.driveHealthIntervalSeconds
            symbolTolerantNames = value.symbolTolerantNames
            defaultSearchScope = value.defaultSearchScope
            addressPresentation = value.addressPresentation
            addressSuggestionLimit = value.addressSuggestionLimit
            ranksAddressVisits = value.ranksAddressVisits
            addressVisitEntryLimit = value.addressVisitEntryLimit
            addressVisitDays = value.addressVisitDays
            diagnosticHistoryEnabled = value.diagnosticHistoryEnabled
            crashCaptureEnabled = value.crashCaptureEnabled
            automaticUpdateChecks = value.automaticUpdateChecks
            publicAutomaticUpdateChecks = value.publicAutomaticUpdateChecks
            publicLastUpdateCheck = value.publicLastUpdateCheck
            supportReminders = value.supportReminders
            updateInvitationSaved = value.updateInvitationSaved
            pendingUpdateBuild = value.pendingUpdateBuild
            showsCommandRow = value.showsCommandRow
            showsPathBar = value.showsPathBar
            showsHiddenFiles = value.showsHiddenFiles
            keyboardProfile = value.keyboardProfile
            customBehavior = value.customBehavior
            shortcutPreferences = value.shortcutPreferences
            appearance = value.appearance
            paneFocus = value.paneFocus
            navigationStyle = value.navigationStyle
            glassNavigation = value.glassNavigation
            glassSidebar = value.glassSidebar
            glassStatusBar = value.glassStatusBar
            glassFileContent = value.glassFileContent
            restoresSession = value.restoresSession
            startupMode = value.startupMode
            newTabDestination = value.newTabDestination
            opensArchivesInTraverse = value.opensArchivesInTraverse
            alwaysReviewArchiveCopies = value.alwaysReviewArchiveCopies
            asksBeforeMovingToTrash = value.asksBeforeMovingToTrash
            interfaceSize = value.interfaceSize
            previousFolderApplication = value.previousFolderApplication
            startupProfileID = value.startupProfileID
            autoRefreshFolders = value.autoRefreshFolders
            operationIndicatorPosition = value.operationIndicatorPosition
            showsDockProgress = value.showsDockProgress
            reviewsRecoveryAtStartup = value.reviewsRecoveryAtStartup
            transferMetadata = value.transferMetadata
            conflictPreferences = value.conflictPreferences
            showsSidebarEject = value.showsSidebarEject
            renamesSelectedNameOnClick = value.renamesSelectedNameOnClick
            showsDriveStatus = value.showsDriveStatus
            hiddenEjectVolumes = value.hiddenEjectVolumes
            ejectNewWorkPolicy = value.ejectNewWorkPolicy
            groupedCopyPreview = value.groupedCopyPreview
            copyPreviewReceipt = value.copyPreviewActivationReceipt
            copyPreviewDisclosureAccepted = value.copyPreviewDisclosureAccepted
            viewMode = value.viewMode
            rowDensity = value.rowDensity
            showsFileExtensions = value.showsFileExtensions
            foldersFirst = value.foldersFirst
            showsModifiedColumn = value.showsModifiedColumn
            showsKindColumn = value.showsKindColumn
            showsSizeColumn = value.showsSizeColumn
            showsCreatedColumn = value.showsCreatedColumn
            showsAccessedColumn = value.showsAccessedColumn
            showsExtensionColumn = value.showsExtensionColumn
            restoring = false
        }
        if let file {
            persistence = CopyPreviewPreferencePersistence(file: file,
                receipt: groupedCopyPreview ? copyPreviewReceipt : nil, disclosed: copyPreviewDisclosureAccepted)
        }
    }

    static func loadPortable(reader: PortablePreferencesReader = .init()) async -> BrowserSettings {
        guard let root = AppStorageLocations.stateDirectory, AppStorageLocations.isPortable else {
            let settings = BrowserSettings(persist: false)
            settings.persistenceBlocked = true
            settings.preferencesPersistenceStatus = "Private app storage is unavailable. Changes apply only for this session."
            return settings
        }
        let file = root.appendingPathComponent("preferences.json")
        do {
            let lease = try ApplicationFileActivity.gate.begin()
            let data: Data?
            do { data = try await reader.read(file) }
            catch { withExtendedLifetime(lease) {}; throw error }
            withExtendedLifetime(lease) {}
            return BrowserSettings(persist: true, restoredData: data, persistenceFile: file, skipDiskRead: true)
        } catch {
            let settings = BrowserSettings(persist: false, persistenceFile: file, skipDiskRead: true)
            settings.persistenceBlocked = true
            settings.preferencesPersistenceStatus = "Saved settings could not be read safely. They were preserved; changes apply only for this session."
            return settings
        }
    }

    func encodedSnapshot() throws -> Data { try JSONEncoder().encode(Saved(self)) }

    func rememberPreviousFolderApplication(_ url: URL?) async throws {
        guard !persistenceBlocked, url.map(Saved.validApplicationURL) ?? true else { throw FileOperationFailure.unavailable }
        let previous = previousFolderApplication
        previousFolderApplication = url
        guard let persistence else { return }
        do {
            try await persistence.prepareDirectory()
            try await persistence.commit(encodedSnapshot(), receipt: copyPreviewReceipt)
        } catch { previousFolderApplication = previous; throw error }
    }

    /// Completing setup persists through the existing guarded background
    /// writer. A failed save must not falsely suppress setup on the next run.
    func completeInitialSetup() async throws {
        guard !persistenceBlocked else { throw FileOperationFailure.unavailable }
        if let persistence {
            var completed = Saved(self)
            completed.initialSetupCompleted = true
            try await persistence.prepareDirectory()
            try await persistence.commit(JSONEncoder().encode(completed), receipt: copyPreviewReceipt)
        }
        // Publish completion only after the durable acknowledgement; update
        // checks must not begin while a failed setup write is still pending.
        initialSetupCompleted = true
    }

    #if DEBUG
    func drainPreferencesForVerification() async { await persistence?.drainForVerification() }
    #endif

    private func save() {
        guard !restoring, !persistenceBlocked, let data = try? encodedSnapshot() else { return }
        ApplicationDiagnostics.shared.event(.settings, .committing)
        persistence?.saveOrdinary(data)
    }

    /// Explicit startup choice acknowledges persistence; an unconfirmed write
    /// does not claim the earlier on-disk setting survived an I/O failure.
    func chooseStartup(_ mode: BrowserStartupMode, profile: UUID? = nil) async throws {
        guard !changingStartup, !persistenceBlocked, mode != .profile || profile != nil else { throw FileOperationFailure.unavailable }
        changingStartup = true; defer { changingStartup = false }
        let previous = (startupMode, startupProfileID, restoresSession)
        restoring = true
        startupProfileID = profile ?? startupProfileID; startupMode = mode; restoresSession = mode == .lastSession
        restoring = false
        guard let persistence else { return } // Explicit nonpersistent test/session profile.
        do {
            try await persistence.prepareDirectory()
            try await persistence.commit(encodedSnapshot(), receipt: copyPreviewReceipt)
        } catch {
            restoring = true; startupMode = previous.0; startupProfileID = previous.1; restoresSession = previous.2; restoring = false
            save(); throw error
        }
    }

    func acceptPrivateNamesFollowing() async throws {
        privateNamesFollowingStatus = ""
        guard !persistenceBlocked, let persistence else {
            privateNamesFollowingStatus = "Following consent could not be saved. The preference remains off."
            throw FileOperationFailure.unavailable
        }
        restoring = true; privateNamesAllowFollowing = true; restoring = false
        do {
            try await persistence.prepareDirectory()
            try await persistence.commit(encodedSnapshot(), receipt: copyPreviewReceipt)
        } catch {
            restoring = true; privateNamesAllowFollowing = false; restoring = false
            privateNamesFollowingStatus = "Following consent could not be saved. The preference remains off."
            throw error
        }
    }

    func commitCopyPreview(_ receipt: CopyPreviewActivationReceipt?) async throws {
        guard !persistenceBlocked, let persistence else { throw FileOperationFailure.unavailable }
        try await persistence.commit(encodedSnapshot(), receipt: receipt)
        restoring = true
        copyPreviewReceipt = receipt
        if receipt != nil { copyPreviewDisclosureAccepted = true }
        groupedCopyPreview = receipt != nil
        restoring = false
    }

    func prepareCopyPreviewPreferences() async throws {
        guard !persistenceBlocked, let persistence else { throw FileOperationFailure.unavailable }
        try await persistence.prepareDirectory()
    }

    func leaveCopyPreviewOffForSession(_ message: String) {
        restoring = true; groupedCopyPreview = false; restoring = false
        copyPreviewStatus = message
    }
}

/// Create the native allocation before attaching SwiftUI. The navigation and
/// selected form share this resizable host; page changes never resize the window.
@MainActor
enum BrowserSettingsWindow {
    static let contentSize = NSSize(width: 860, height: 660)

    static func make(_ settingsView: BrowserSettingsView) -> NSWindow {
        let rect = NSRect(origin: .zero, size: contentSize)
        let window = FolderDefaultSettingsWindow(contentRect: rect, folderDefaults: settingsView.folderDefaultsOwner)
        let host = InterfaceHostingController(rootView: settingsView)
        host.sizingOptions = []
        host.view.frame = rect
        window.contentViewController = host
        window.title = "Traverse Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = .init(width: 720, height: 520)
        ToolWindowChrome.install(in: window, settings: settingsView.settings)
        return window
    }
}

struct BrowserSettingsView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @State private var reviewsPrivateFollowing = false
    enum Page: Sendable { case general, appearance, tools, keyboard, operations, privacy, permissions }
    @ObservedObject var settings: BrowserSettings
    @State private var page: Page
    @State private var settingsSearch = ""
    @State private var analysisMaintenanceRunning = false
    @State private var analysisMaintenanceMessage = ""
    @StateObject private var folderDefaultPresentation: FolderDefaultSettingsPresentation
    let folderDefaultsOwner: ApplicationFolderDefaults
    let namesOwner: ApplicationPrivateNames
    var onReviewRecovery: () -> Void
    var onCompactJournal: () -> Void
    var onPrepareHistory: () -> Void
    var onCopyPreviewChange: (Bool) -> Void
    var onManageLaunchProfiles: () -> Void
    var onShowSetup: () -> Void
    let folderAccess: FolderAccessController?
    let accessDrives: [VolumeInfo]
    var onShowConnections: (() -> Void)?
    var onAccessChanged: @MainActor () async -> Void
    @State private var startupNotice = ""
    @ObservedObject var operationCoordinator = ApplicationOperationCoordinator.shared
    let copyPreviewAvailability: CopyPreviewAvailability
    var canSelectCopyPreview: Bool { copyPreviewAvailability == .available }
#if DEBUG
    /// Actual Form lifecycle only; nil leaves the normal view unmodified.
    var onPageVisibilityForVerification: (@MainActor (Page, Bool) -> Void)? = nil
#endif

    init(settings: BrowserSettings, initialPage: Page = .general, namesOwner: ApplicationPrivateNames = .shared,
         onReviewRecovery: @escaping () -> Void = {}, onCompactJournal: @escaping () -> Void = {},
         copyPreviewAvailability: CopyPreviewAvailability = .qualificationPending,
         onPrepareHistory: @escaping () -> Void = {}, onCopyPreviewChange: @escaping (Bool) -> Void = { _ in },
         onManageLaunchProfiles: @escaping () -> Void = {}, onShowSetup: @escaping () -> Void = {},
         folderAccess: FolderAccessController? = nil, accessDrives: [VolumeInfo] = [],
         folderDefaults: ApplicationFolderDefaults = .shared,
         onShowConnections: (() -> Void)? = nil, onAccessChanged: @escaping @MainActor () async -> Void = {}) {
        self.copyPreviewAvailability = copyPreviewAvailability
        folderDefaultsOwner = folderDefaults
        self.settings = settings
        self.namesOwner = namesOwner
        _page = State(initialValue: initialPage)
        _folderDefaultPresentation = StateObject(wrappedValue: folderDefaults.makePresentation(initialGeneral: initialPage == .general))
        self.onReviewRecovery = onReviewRecovery
        self.onCompactJournal = onCompactJournal
        self.onPrepareHistory = onPrepareHistory
        self.onCopyPreviewChange = onCopyPreviewChange
        self.onManageLaunchProfiles = onManageLaunchProfiles
        self.onShowSetup = onShowSetup
        self.folderAccess = folderAccess
        self.accessDrives = accessDrives; self.onShowConnections = onShowConnections
        self.onAccessChanged = onAccessChanged
    }

    private func maintainAnalyses(forget: Bool) {
        guard !analysisMaintenanceRunning else { return }
        analysisMaintenanceRunning = true
        analysisMaintenanceMessage = "Finishing analysis work…"
        Task { @MainActor in
            let owner = ApplicationStorageAnalysis.shared
            if forget { await owner.forgetRecordedAnalyses() }
            else { await owner.repairRecordedAnalyses() }
            analysisMaintenanceMessage = owner.savedAnalysesMaintenanceMessage
            analysisMaintenanceRunning = false
        }
    }

    private func selectPage(_ next: Page) {
        guard page != next else { return }
        folderDefaultPresentation.selectGeneral(next == .general)
        page = next
    }
    private var selectedPage: Binding<Page> { Binding(get: { page }, set: { selectPage($0) }) }

    @ViewBuilder
    private func observedPage<Content: View>(_ content: Content, page: Page) -> some View {
#if DEBUG
        if let observer = onPageVisibilityForVerification {
            content.scrollContentBackground(.hidden)
                .onAppear { observer(page, true) }.onDisappear { observer(page, false) }
        } else {
            content.scrollContentBackground(.hidden)
        }
#else
        content.scrollContentBackground(.hidden)
#endif
    }

    var body: some View {
        HStack(spacing: 0) {
            ToolNavigationSidebar(scale: interfaceScale) {
                Text("Settings").interfaceFont(.headline)
            } content: {
                VStack(alignment: .leading, spacing: 8) {
                TextField("Search Settings", text: $settingsSearch)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search Settings")
                    .accessibilityIdentifier("settings-search")
                    .padding(.horizontal, 6)
                if !settingsSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Results").interfaceFont(.caption).foregroundStyle(.secondary)
                        let results = SettingsSearchCatalog.pages(matching: settingsSearch)
                        if results.isEmpty {
                            Text("No matching settings").interfaceFont(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(results, id: \.self) { result in
                                Button { selectPage(result) } label: {
                                    Label(result.title, systemImage: result.symbolName)
                                        .frame(maxWidth: .infinity, minHeight: 25 * interfaceScale, alignment: .leading)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("Show " + result.title + " settings")
                            }
                        }
                    }.padding(.horizontal, 9)
                    Divider()
                }
                BrowserSettingsNavigation(selection: selectedPage, scale: interfaceScale)
                }
            } footer: { EmptyView() }
            Divider()
            NativeSettingsPageHost(page: page, content: AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    Text(page.title).interfaceFont(.title2.bold())
                        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 4)
                    pageContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ), motion: settings.motion)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .background(FolderDefaultSettingsWindowReader { [weak folderDefaultPresentation] in
            folderDefaultPresentation?.bind($0)
        }.frame(width: 0, height: 0))
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .tools:
            observedPage(EditorSettingsTools(settings: settings, searchQuery: settingsSearch), page: .tools)
        case .general:
            observedPage(Form {
                if let coordinator = folderDefaultPresentation.owner.coordinator {
                    Section { FolderDefaultSettingsCard(owner: coordinator, presentation: folderDefaultPresentation) }
                }
                Section("Setup") {
                    Button("Personalize Traverse…", action: onShowSetup)
                    Button("Manage Permissions & Folder Access…") { selectPage(.permissions) }
                    Text("Revisit your look, navigation, search and update choices. Permissions has your remembered folders, drives and optional access.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                Section("Crash reports") {
                    Toggle("Capture crashes locally on next launch", isOn: $settings.crashCaptureEnabled)
                    Text("Applies when Traverse next starts. Native capture may contain private paths and is kept only on this Mac, up to five reports within 4 MiB. Nothing is uploaded automatically. Review, redact, export or remove copies in Help → Crash Reports & Feedback.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Button("Crash Reports & Feedback…") { ApplicationCrashReports.shared.show(settings: settings) }
                }
                Section("Community") {
                    Toggle("Show support message after updates", isOn: $settings.supportReminders.enabled)
                    Text("One optional message per released update. Support Traverse is always available in Help; no features require payment.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                Section("Window") {
                    Toggle("Open supported archives in Traverse", isOn: $settings.opensArchivesInTraverse)
                        .help("Open ZIP and supported TAR archives for browsing. Other file types keep their usual app. Browse Archive remains available in the file menu.")
                    Picker("New tabs open", selection: $settings.newTabDestination) {
                        ForEach(BrowserNewTabDestination.allCases) { Text($0.title).tag($0) }
                    }
                    Text("Duplicate Tab keeps the selected tab’s folder and view. A new server tab needs a separate connection.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Toggle("Click a selected filename to rename", isOn: $settings.renamesSelectedNameOnClick)
                        .help("Click the selected name, pause briefly, then type. Double-click still opens the item; dragging and selection modifiers keep their usual behavior.")
                    Toggle("Show menus in the window title bar", isOn: $settings.showsCommandRow)
                    Toggle("Finder-style bottom address", isOn: $settings.showsPathBar)
                    Toggle("Show Eject buttons beside external drives", isOn: $settings.showsSidebarEject)
                    Toggle("Show quick drive controls in the status bar", isOn: $settings.showsDriveStatus)
                    if settings.showsSidebarEject {
                        Button("Show Eject Buttons on All Drives") { settings.hiddenEjectVolumes = []; settings.hiddenEjectSessions = [] }
                        Text("Control-click a drive to hide its button. Choices stay on this Mac. Some drives can remember this choice only until you quit.")
                            .interfaceFont(.caption).foregroundStyle(.secondary)
                    }
                    Text("Moves the address and its suggestions to the bottom of each pane, and combines navigation and Search with the tabs. Click an ancestor to navigate or control-click for folder actions. Option-Command-P switches layouts.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Picker("Start with", selection: Binding(get: { settings.startupMode }, set: { mode in
                        Task {
                            do { try await settings.chooseStartup(mode, profile: settings.startupProfileID); startupNotice = "" }
                            catch { startupNotice = "The startup choice could not be confirmed. Review it before quitting." }
                        }
                    })) {
                        Text("This Mac").tag(BrowserStartupMode.computer)
                        Text("Last session").tag(BrowserStartupMode.lastSession)
                        if settings.startupProfileID != nil { Text("Saved profile").tag(BrowserStartupMode.profile) }
                    }.disabled(settings.changingStartup)
                    Button("Launch Profiles…", action: onManageLaunchProfiles)
                    Text("Last session remembers current tabs and folders; switching it off removes that snapshot. Saved profiles change only when you explicitly save a layout. All locations stay on this Mac and grant no access.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    if !startupNotice.isEmpty { Text(startupNotice).interfaceFont(.caption).foregroundStyle(.secondary) }
                    Text("File, View, Go and Settings also remain available in the Mac menu bar.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                Section("Search") {
                    Picker("Default search sources", selection: $settings.privateNamesSources) {
                        ForEach(PrivateNameSources.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Suggest saved folder names in the address bar", isOn: $settings.privateNamesAddressSuggestions)
                    if settings.privateNamesAllowFollowing {
                        Toggle("Allow document following when remembering", isOn: $settings.privateNamesAllowFollowing)
                    } else {
                        Button("Review document following…") { reviewsPrivateFollowing = true }
                            .alert("Follow moves and saves", isPresented: $reviewsPrivateFollowing) {
                                Button("Allow for Remember") { Task { try? await settings.acceptPrivateNamesFollowing() } }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("An explicit Remember may enable a native metadata flag so saved names can follow supported moves and saves. Contents are not read. Failed Save may leave the flag enabled; Forget removes saved information without unsetting it.")
                            }
                    }
                    Text("Only explicit Remember can enable the native metadata flag. File contents are not read. Turning this off does not undo existing native flags or saved links. Names are stored locally; older backups or exports may retain them.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    if !settings.privateNamesFollowingStatus.isEmpty { Text(settings.privateNamesFollowingStatus).interfaceFont(.caption).foregroundStyle(.secondary) }
                    Toggle("Treat spaces, hyphens and underscores as equivalent", isOn: $settings.symbolTolerantNames)
                    Text("Applies to filename search and folder-name suggestions. Complete-filename matching keeps symbols literal. Search uses filenames and allowed metadata; macOS owns the Spotlight index.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Button("Open System Settings…") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Text("In System Settings, choose Spotlight → Search Privacy to manage macOS indexing. Traverse does not rebuild or change that index.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)

                    Picker("Default folder scope", selection: $settings.defaultSearchScope) {
                        ForEach(BrowserDefaultSearchScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Text("Applies when opening a folder or tab. This Mac always starts with indexed search. Search runs only after Return; changing this preference keeps existing drafts and results.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                Section("Address suggestions") {
                    Picker("Show suggestions", selection: $settings.addressPresentation) {
                        ForEach(AddressSuggestionPresentation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Dropdown limit: \(settings.addressSuggestionLimit)", value: $settings.addressSuggestionLimit, in: 3...12)
                    Text("Tab fills a suggestion; Return opens the address. Paths check one folder level; bare names also use familiar locations and Spotlight's filename index. No content search or recursive scan runs while typing.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Toggle("Improve suggestions using folder visits", isOn: $settings.ranksAddressVisits)
                    Stepper("Keep up to \(settings.addressVisitEntryLimit) folders", value: $settings.addressVisitEntryLimit, in: 10...1_000, step: 10)
                    Stepper("Forget visits after \(settings.addressVisitDays) days", value: $settings.addressVisitDays, in: 1...365)
                    Button("Clear Visit History") { settings.directoryVisits.clear() }
                    Text("Visit history is off by default and stored only on this Mac. It contains directory paths and visit counts, never file contents. Turning it off clears saved visits; saved paths do not grant access.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    DirectoryVisitStatus(visits: settings.directoryVisits)
                }
                Section("Folder summaries and storage") {
                    Toggle("Keep recent analyses on this Mac", isOn: $settings.analysisKeepsResults)
                    HStack {
                        Button("Forget Saved Analyses") { maintainAnalyses(forget: true) }
                            .accessibilityIdentifier("settings-forget-analyses")
                        Button("Repair Saved Analyses") { maintainAnalyses(forget: false) }
                            .accessibilityIdentifier("settings-repair-analyses")
                    }
                    .disabled(analysisMaintenanceRunning)
                    if !analysisMaintenanceMessage.isEmpty {
                        Text(analysisMaintenanceMessage).interfaceFont(.caption).foregroundStyle(.secondary)
                    }
                    Text("Keep the two most recent analyses and reopen their charts without scanning again. Results include names, sizes and dates, never file contents. Switch off to stop keeping new results; Forget removes saved analyses. Your files are untouched.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Toggle("Refresh changed folders when possible", isOn: $settings.analysisRefreshesChangedFolders)
                        .accessibilityIdentifier("settings-analysis-refresh-changes")
                    Text("Refresh checks for changes using a saved analysis when available. A full scan runs when needed. Choose Scan Every Folder in Scan options to check everything, or switch this off to always run full scans.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Picker("Storage chart style", selection: $settings.analysisChartStyle) {
                        ForEach(StorageChartStyle.allCases, id: \.self) { style in Text(style.title).tag(style) }
                    }
                    .accessibilityIdentifier("storage-chart-style")
                    Text("Applies to Properties and Storage Analysis. Right-click or hold a chart to choose the same styles. This choice stays on this Mac and changes presentation without rescanning. Reduce Motion and Reduce Transparency are respected.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Toggle("Include application data by default in explicit scans", isOn: $settings.analysisIncludesApplicationDataByDefault)
                    HStack {
                        Text("\(settings.analysisLocationChoices.count) remembered analysis locations")
                        Button("Clear Location Choices") { settings.clearAnalysisLocationChoices() }.disabled(settings.analysisLocationChoices.isEmpty)
                    }
                    Text("Local only. An optional folder/drive choice overrides this default at that exact path, without applying to subfolders. Saved choices contain paths, never file contents or access grants. A replacement at the same path uses that location's choice. Automatic hover summaries always use Standard. macOS access limits and private exclusions still apply.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Picker("Analysis folder picker", selection: $settings.analysisFolderPicker) {
                        ForEach(AnalysisFolderPickerStyle.allCases) { style in Text(style.rawValue).tag(style) }
                    }
                    Text("Choose System, Explorer details or Columns for Storage Analysis. Native macOS selection remains available for granting or remembering access. Custom browsing does not grant access.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Toggle("Show folder summaries on hover", isOn: $settings.folderSummariesEnabled)
                    HStack {
                        Text("Hover delay")
                        Slider(value: $settings.folderSummaryDelay, in: 0.3...5, step: 0.1)
                        Text(settings.folderSummaryDelay.formatted(.number.precision(.fractionLength(1))) + " s")
                            .monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                    .disabled(!settings.folderSummariesEnabled)
                    Button("Clear Cached Folder Summaries") { ApplicationStorageAnalysis.shared.clearCachedSummaries() }
                    Text("Eligible local folders calculate automatically while you hover. A saved analysis of that exact folder can be shown with its date; it may have changed. Otherwise, recent hover results may be reused for up to 30 seconds. Summaries use names and metadata only, never file contents or cloud downloads. Protected, provider and unavailable folders can remain incomplete.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Text("Downloads, Desktop, Documents and private/system locations currently require explicit Analyze Storage while their automatic-access support is qualified.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Button("Inspect Traverse Storage…") { ApplicationStorageAnalysis.shared.showAppStorage(settings: settings) }
                        .disabled(settings.storageStateDirectory == nil)
                    Text("Shows local app state separately from macOS Spotlight, developer fixtures and recovery files stored elsewhere. This is read-only; no persistent content index is created.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                Section("Files and folders") {
                    Toggle("Refresh open folders when their contents change", isOn: $settings.autoRefreshFolders)
                    Toggle("Show hidden files and folders", isOn: $settings.showsHiddenFiles)
                    Toggle("Show filename extensions", isOn: $settings.showsFileExtensions)
                    Toggle("Folders first by default", isOn: $settings.foldersFirst)
                    Text("Properties and rename always show the complete filename.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped), page: .general)
        case .appearance:

            observedPage(Form {
                Section("Appearance") {
                    Picker("Theme", selection: $settings.appearance) {
                        ForEach(BrowserAppearance.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    Picker("Surface style", selection: $settings.navigationStyle) {
                        ForEach(NavigationStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Group {
                        Toggle("Glass navigation", isOn: $settings.glassNavigation)
                        Toggle("Glass sidebar", isOn: $settings.glassSidebar)
                        Toggle("Glass status bar", isOn: $settings.glassStatusBar)
                        Toggle("Translucent file content (Experimental)", isOn: $settings.glassFileContent)
                    }
                    .disabled(settings.navigationStyle == .solid)
                    Text("Solid, Reduce Transparency and Increase Contrast take priority. File content stays opaque unless its experimental option is enabled.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                Section("Interface size") { InterfaceSizePicker(settings: settings) }
                Section("File list") {
                    Picker("Default view", selection: $settings.viewMode) {
                        ForEach(BrowserViewMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Details/List row spacing", selection: $settings.rowDensity) {
                        ForEach(BrowserRowDensity.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text("Right-click a Details column heading to choose columns. The View menu offers the same choices.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                Section("Motion") {
                    Picker("Animations", selection: $settings.motion.mode) {
                        ForEach(BrowserMotionMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }.pickerStyle(.segmented)
                    ForEach(BrowserMotionEffect.allCases) { effect in
                        Toggle(effect.rawValue, isOn: Binding(get: { settings.motion.selected(effect) }, set: {
                            var value = settings.motion; value.set($0, for: effect); settings.motion = value
                        })).disabled(settings.motion.mode == .off)
                    }
                    Text("Reduced uses shorter fades and gentler movement. System Reduce Motion always takes priority. Off keeps actions and progress feedback.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                Section("Active pane") {
                    Picker("Focus indication", selection: $settings.paneFocus.style) {
                        ForEach(PaneFocusPreferences.Style.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Outline thickness", selection: $settings.paneFocus.thickness) {
                        ForEach(1...3, id: \.self) { Text("\($0) pt").tag($0) }
                    }
                    if settings.paneFocus.style == .custom {
                        ColorPicker("Outline color", selection: Binding(get: { Color(nsColor: settings.paneFocus.color) }, set: { value in
                            guard let color = NSColor(value).usingColorSpace(.sRGB) else { return }
                            var focus = settings.paneFocus
                            focus.red = color.redComponent; focus.green = color.greenComponent; focus.blue = color.blueComponent
                            settings.paneFocus = focus
                        }), supportsOpacity: false)
                    }
                    Toggle("Show Active pane caption", isOn: $settings.paneFocus.caption)
                    Text("Shown only with multiple panes. Increase Contrast enforces a stronger outline and caption. Keyboard focus remains native.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped), page: .appearance)
        case .keyboard:

            observedPage(Form {
                Section("File-browser keyboard") {
                    Picker("Preset", selection: $settings.keyboardProfile) {
                        ForEach(KeyboardProfile.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if settings.keyboardProfile != .custom {
                        Button("Customize These Choices") { settings.customizeBehavior() }
                    }
                    Picker("Return", selection: Binding(get: { settings.behavior.returnAction }, set: { value in settings.updateCustomBehavior { $0.returnAction = value } })) {
                        ForEach(BrowserReturnAction.allCases) { Text($0.rawValue).tag($0) }
                    }.disabled(settings.keyboardProfile != .custom)
                    Toggle("Backspace goes back", isOn: Binding(get: { settings.behavior.backspaceGoesBack }, set: { value in settings.updateCustomBehavior { $0.backspaceGoesBack = value } }))
                        .disabled(settings.keyboardProfile != .custom)
                    Toggle("Control shortcut aliases", isOn: Binding(get: { settings.behavior.controlAliasesEnabled }, set: { value in settings.updateCustomBehavior { $0.controlAliasesEnabled = value } }))
                        .help("Use Control shortcuts, Control-click to add to a selection and Control-drag to copy in file listings. Text fields keep their usual editing behavior.")
                        .disabled(settings.keyboardProfile != .custom)
                    Toggle("Explorer function keys and Delete", isOn: Binding(get: { settings.behavior.explorerFunctionKeysEnabled }, set: { value in settings.updateCustomBehavior { $0.explorerFunctionKeysEnabled = value } }))
                        .disabled(settings.keyboardProfile != .custom)
                    if settings.keyboardProfile == .custom {
                        Menu("Reset an Action to Explorer") {
                            Button("Return") { settings.updateCustomBehavior { $0.returnAction = BrowserBehaviorPreferences.explorer.returnAction } }
                            Button("Backspace") { settings.updateCustomBehavior { $0.backspaceGoesBack = true } }
                            Button("Control aliases") { settings.updateCustomBehavior { $0.controlAliasesEnabled = true } }
                            Button("Function keys and Delete") { settings.updateCustomBehavior { $0.explorerFunctionKeysEnabled = true } }
                        }
                        Button("Reset All Custom Choices to Explorer") { settings.resetCustomBehavior() }
                    }
                    Text("Effective Return: " + settings.behavior.returnAction.rawValue + ". Backspace: " + (settings.behavior.backspaceGoesBack ? "Back." : "native behavior."))
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Text("Control aliases cover browser tabs, navigation and file commands. Explorer keys are F2 Rename, F4 Address, F5 Refresh, F6 Focus and Delete to Trash. Space opens Quick Look in every preset.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Text("Command shortcuts remain available. Text fields, rename and input methods retain native editing keys and text Undo. These choices apply only inside Traverse.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    if !settings.keyboardConfigurationStatus.isEmpty {
                        Text(settings.keyboardConfigurationStatus).interfaceFont(.caption).foregroundStyle(.red)
                    }
                    if !settings.preferencesPersistenceStatus.isEmpty {
                        Text(settings.preferencesPersistenceStatus).interfaceFont(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Custom shortcuts") {
                    BrowserShortcutEditor(settings: settings)
                }
            }
            .formStyle(.grouped), page: .keyboard)
        case .operations:

            observedPage(Form {
                Section("Trash") {
                    Toggle("Ask before moving items to Trash", isOn: $settings.asksBeforeMovingToTrash)
                    Text("When off, selected local items move to Trash immediately. Supported moves can be undone.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                Section("Copy and cross-volume Move") {
                    Toggle("Preview faster Copy", isOn: Binding(get: { settings.groupedCopyPreview }, set: { onCopyPreviewChange($0) }))
                        .disabled(!canSelectCopyPreview || !settings.canPersistCopyPreview
                            || operationCoordinator.copyPreviewOwner != nil || operationCoordinator.copyPreviewTask != nil)
                        .accessibilityIdentifier("copy-execution-preview")
                    Text(canSelectCopyPreview
                         ? "Applies to later eligible Copy jobs. Each job captures this choice; turning it off keeps Undo and recovery available."
                         : "Preview is unavailable while qualification is being completed. Copies use the standard path; Undo and recovery remain available.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    if !settings.copyPreviewStatus.isEmpty {
                        Text(settings.copyPreviewStatus).interfaceFont(.caption).foregroundStyle(.secondary)
                    }
                    if operationCoordinator.copyPreviewOwner != nil && operationCoordinator.copyPreviewTask != nil {
                        Button(operationCoordinator.copyPreviewStopRequested ? "Stopping Setup…" : "Cancel Setup") {
                            operationCoordinator.cancelCopyPreviewSetup(settings: settings)
                        }
                        .disabled(operationCoordinator.copyPreviewStopRequested)
                    }
                    if canSelectCopyPreview && !settings.canPersistCopyPreview {
                        Text("Preview needs writable saved preferences. Existing saved settings were preserved.")
                            .interfaceFont(.caption).foregroundStyle(.secondary)
                    }
                    if canSelectCopyPreview {
                        Text("Preview eligibility: 16–1,024 regular files with unused names on the two qualified local APFS volumes, up to 64 MiB per file and 128 MiB per job. Other jobs use standard Copy.")
                            .interfaceFont(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Metadata", selection: $settings.transferMetadata) {
                        ForEach(TransferMetadataPreference.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text("Strict preservation is the default. Native owner/group allows macOS ownership differences; file data, permissions, ACLs and other supported metadata must still match. Both verify recorded native security metadata. Same-volume moves keep the original object.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Text("Use Paste with Options for a single transfer. Incompatible metadata stops the operation; the app never silently changes modes.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Text("Changing owner/group can change who existing permissions apply to. This mode does not inherit new permissions or ACLs.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                Section("Archives") {
                    Toggle("Always review archive copies", isOn: $settings.alwaysReviewArchiveCopies)
                    Text("Paste or drag one file or folder directly into its destination. Existing names and selections that need a new containing folder still open a review. Extract… always opens a review.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                Section("Existing names") {
                    Picker("Files", selection: $settings.conflictPreferences.files) {
                        ForEach(TransferConflictDefault.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Folders", selection: $settings.conflictPreferences.folders) {
                        ForEach(TransferConflictDefault.allCases) { Text($0.title).tag($0) }
                    }
                    Text("Skip and Keep Both apply automatically to matching ordinary items. Packages, links and type differences still ask. Replace and Merge always need an explicit choice. Each queued job keeps the settings captured when added.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                Section("Drives") {
                    Picker("While eject is waiting", selection: $settings.ejectNewWorkPolicy) {
                        ForEach(EjectNewWorkPolicy.allCases) { Text($0.title).tag($0) }
                    }
                    Text("Applies to each new eject request. Already accepted transfers finish first. New work can never cancel a request already submitted to macOS.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                Section("Progress") {
                    Picker("Progress indicator", selection: $settings.operationIndicatorPosition) {
                        ForEach(OperationIndicatorPosition.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Show phase progress in the Dock", isOn: $settings.showsDockProgress)
                    Text("Percentages describe the named phase. Hover for a summary or click the ring to keep details and Stop inside the window. Copy speed measures logical bytes transferred.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                Section("Recovery and retention") {
                    Toggle("Show in-window recovery attention", isOn: $settings.reviewsRecoveryAtStartup)
                    Text("Interrupted work stays available in Operation Recovery. Startup never opens a review dialog or resumes operations automatically.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Text("Development default: keep all recovery backups. Automatic expiry is off. Interrupted operations never resume automatically.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Button("Review Recovery Backups…", action: onReviewRecovery)
                    Button("Prepare History for Review…", action: onPrepareHistory)
                        .disabled(operationCoordinator.copyPreviewOwner != nil)
                    Text(OrdinaryNativeTrashFeature.available
                         ? "Review an operation before moving verified recovery copies to Trash. Cleanup ends Undo and rollback for the entire operation. Changed or unproven staging remains protected."
                         : "Recovery cleanup is paused for this beta to keep macOS file protection intact. Your recovery copies and history remain available for review.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Button("Compact Journal Metadata", action: onCompactJournal)
                    Text("Compaction reduces old progress history without removing recovery backups or their current records.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    if !settings.recoveryMaintenanceStatus.isEmpty {
                        Text(settings.recoveryMaintenanceStatus).interfaceFont(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped), page: .operations)
        case .privacy:

            observedPage(PrivateNamesPrivacyView(owner: namesOwner, settings: settings), page: .privacy)
        case .permissions:

            observedPage(Form {
                if let folderAccess {
                    Section("Folders and drives") {
                        FolderAccessManagementView(access: folderAccess, drives: accessDrives, changed: onAccessChanged)
                    }
                    Section("Additional access") {
                        TraversePermissionChecklist(access: folderAccess, showConnections: onShowConnections, motion: settings.motion)
                    }
                } else {
                    Section("Folders and drives") {
                        Text("Open Permissions from an Explorer window to choose the folders and drives you want to use.")
                    }
                }
            }.formStyle(.grouped), page: .permissions)
        }
    }
}

private struct DirectoryVisitStatus: View {
    @ObservedObject var visits: BrowserDirectoryVisits
    var body: some View {
        if !visits.status.isEmpty { Text(visits.status).interfaceFont(.caption).foregroundStyle(.secondary) }
    }
}
