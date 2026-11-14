import AppKit
import Darwin
import ExplorerCore
import LocalStorage
import UniformTypeIdentifiers

struct OpenWithApplication: Sendable, Equatable {
    let url: URL
    let title: String
}

fileprivate struct OpenShareIdentity: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode; size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }
}

fileprivate struct OpenShareItem: Sendable, Equatable {
    let url: URL
    let identity: OpenShareIdentity
}

private enum OpenShareFailure: Error, Equatable {
    case unavailable, selectionChanged, applicationUnavailable
}

/// One off-main executor bounds shallow observations and LaunchServices queries.
/// No content reads, thumbnail creation, recursive enumeration, or application launch.
actor OpenWithApplicationReader {
    static let shared = OpenWithApplicationReader()
    static let maximumItems = 64

    fileprivate func acquire(_ preparation: FolderAccessPreparation) throws -> FileAccessLifetimes {
        let activity = try ApplicationFileActivity.gate.begin()
        defer { withExtendedLifetime(activity) {} }
        return FileAccessLifetimes(leases: try preparation.acquire())
    }

    fileprivate func observe(_ urls: [URL], before: (@Sendable () throws -> Void)? = nil) throws -> [OpenShareItem] {
        let activity = try ApplicationFileActivity.gate.begin()
        defer { withExtendedLifetime(activity) {} }
        try before?()
        guard !urls.isEmpty, urls.count <= Self.maximumItems, Set(urls).count == urls.count else {
            throw OpenShareFailure.unavailable
        }
        return try urls.map { url in
            try Task.checkCancellation()
            guard url.isFileURL, url.query == nil, url.fragment == nil,
                  url.host == nil || url.host == "" || url.host == "localhost" else {
                throw OpenShareFailure.unavailable
            }
            var current = URL(fileURLWithPath: "/", isDirectory: true)
            var value = stat()
            for component in url.pathComponents.dropFirst() {
                current.appendPathComponent(component)
                guard current.withUnsafeFileSystemRepresentation({ $0.map { lstat($0, &value) } ?? -1 }) == 0,
                      value.st_mode & S_IFMT != S_IFLNK else { throw OpenShareFailure.unavailable }
            }
            guard [S_IFREG, S_IFDIR].contains(value.st_mode & S_IFMT) else { throw OpenShareFailure.unavailable }
            return OpenShareItem(url: url, identity: OpenShareIdentity(value))
        }
    }

    fileprivate func revalidate(_ items: [OpenShareItem], before: (@Sendable () throws -> Void)? = nil) throws {
        guard try observe(items.map(\.url), before: before) == items else { throw OpenShareFailure.selectionChanged }
    }

    func applicationForHandoff(_ url: URL, excludingTraverse: Bool = false) throws -> URL {
        let activity = try ApplicationFileActivity.gate.begin()
        defer { withExtendedLifetime(activity) {} }
        try Task.checkCancellation()
        guard url.isFileURL, url.pathExtension.lowercased() == "app" else { throw OpenShareFailure.applicationUnavailable }
        // App installations may be symbolic links (for example package-manager
        // installs). Resolve the deliberately chosen app, never document links.
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        do {
            let before = try observe([canonical])
            let metadata = try observe([canonical.appendingPathComponent("Contents/Info.plist")])
            guard ((before.first?.identity.mode ?? 0) & S_IFMT) == S_IFDIR,
                  ((metadata.first?.identity.mode ?? 0) & S_IFMT) == S_IFREG,
                  (metadata.first?.identity.size ?? 0) <= 2_097_152,
                  try canonical.resourceValues(forKeys: [.isApplicationKey]).isApplication == true,
                  let identifier = Bundle(url: canonical)?.bundleIdentifier, !identifier.isEmpty else {
                throw OpenShareFailure.applicationUnavailable
            }
            if excludingTraverse && (canonical == Bundle.main.bundleURL.standardizedFileURL
                || identifier == "com.respawnstudios.traverse" || identifier.hasPrefix("local.macexplorer")) {
                throw OpenShareFailure.applicationUnavailable
            }
            try revalidate(before + metadata)
            return canonical
        } catch { throw OpenShareFailure.applicationUnavailable }
    }

    func applications(for urls: [URL], candidates: (@Sendable (URL) -> [URL])? = nil) throws -> [OpenWithApplication] {
        let activity = try ApplicationFileActivity.gate.begin()
        defer { withExtendedLifetime(activity) {} }
        guard !urls.isEmpty, urls.count <= Self.maximumItems else { throw OpenShareFailure.unavailable }
        var common: Set<URL>?
        var ordered: [URL] = []
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            let found = (candidates?(url) ?? NSWorkspace.shared.urlsForApplications(toOpen: url)).prefix(128).map(\.standardizedFileURL)
            if index == 0 { ordered = found; common = Set(found) }
            else { common?.formIntersection(found) }
            if common?.isEmpty == true { break }
        }
        var seen = Set<URL>()
        return try ordered.filter { common?.contains($0) == true && seen.insert($0).inserted }.prefix(32).map { url in
            try Task.checkCancellation()
            let title = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
                ?? url.deletingPathExtension().lastPathComponent
            return OpenWithApplication(url: url, title: title)
        }
    }
}

/// Optional seams are explicitly installed by generated-fixture verification.
/// Production uses NSWorkspace and the native sharing picker.
@MainActor
struct BrowserOpenShareHooks {
    var discover: (@Sendable ([URL]) async throws -> [OpenWithApplication])?
    var chooseApplication: (@MainActor (NSWindow) async -> URL?)?
    var launch: (@MainActor ([URL], URL, @escaping @MainActor @Sendable (Error?) -> Void) -> Void)?
    var share: (@MainActor ([URL], @escaping @MainActor @Sendable (Error?) -> Void) -> Void)?
    var airDropService: (@MainActor (NSSharingService.Name) -> NSSharingService?)?
    var airDropCanPerform: (@MainActor (NSSharingService, [URL]) -> Bool)?
    var airDropPerform: (@MainActor (NSSharingService, [URL]) -> Void)?
    var sharePreparation: (@Sendable (BrowserSharePreparationStage, [URL]) throws -> Void)?
    #if DEBUG
    var preferredOpeningBeforeRevalidation: (@Sendable () async -> Void)?
    var airDropBeforeArming: (@MainActor (NSSharingService, [URL]) -> Void)?
    var pickerPresentation: (@MainActor (NSSharingServicePicker, [URL]) -> Void)?
    var pickerClose: (@MainActor (NSSharingServicePicker) -> Void)?
    #endif
}

enum BrowserSharePreparationStage: Sendable, Equatable { case observing, revalidating }

/// Sharing has no public service Cancel. Terminal callbacks own its lifetime;
/// ordinary Quit must not discard a chosen service to manufacture drain.
@MainActor
enum ApplicationNativeSharing {
    private static let controllers = NSHashTable<BrowserOpenAndShareController>.weakObjects()
    private static var preparationDrains = 0
    static let pendingMessage = "Finish or cancel the sharing request in macOS, then try Quit again."
    static let pendingPreparationMessage = "A sharing preparation is still stopping. You can keep browsing and try Quit again shortly."
    static var hasActiveHandoff: Bool { BrowserNativeShareSession.hasActiveHandoff }
    static var hasPendingPreparation: Bool { controllers.allObjects.contains { $0.hasPendingPreparation } }
    fileprivate static var canPrepare: Bool { preparationDrains == 0 && controllers.allObjects.reduce(0) { $0 + $1.preparationCount } < 8 }
    fileprivate static func register(_ controller: BrowserOpenAndShareController) { controllers.add(controller) }
    static func cancelPreparationsAndDrain(maximumWait: Duration = .seconds(2)) async -> Bool {
        preparationDrains += 1; defer { preparationDrains -= 1 }
        let owners = controllers.allObjects
        owners.forEach { $0.cancelPreparation() }
        let deadline = ContinuousClock.now + max(.zero, maximumWait)
        while hasPendingPreparation {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            let remaining = max(Duration.zero, ContinuousClock.now.duration(to: deadline))
            do { try await Task.sleep(for: min(.milliseconds(10), remaining)) }
            catch { return false }
        }
        return true
    }
    static func explainPendingSharing(from browser: BrowserViewController?) {
        #if DEBUG
        quitRefusalsForVerification += 1
        #endif
        let target = browser ?? controllers.allObjects.first(where: { $0.hasChosenHandoff })?.browser
        if let target, !target.isBrowserSuspended, let window = target.view.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
        target?.status.stringValue = pendingMessage
    }
    #if DEBUG
    private(set) static var quitRefusalsForVerification = 0
    static var activeHandoffsForVerification: Int { BrowserNativeShareSession.activeHandoffsForVerification }
    #endif
}

enum NativeAirDropFeature {
    static var available: Bool {
        AppFeatureAvailability.allows(.airDrop)
    }
}

@MainActor
private final class OpenShareRequest {
    let id = UUID()
    let visit: UUID
    let tab: UUID
    let presentation: UUID
    let urls: [URL]
    weak var window: NSWindow?
    init(browser: BrowserViewController, urls: [URL]) {
        visit = browser.sessionID; tab = browser.activeID; presentation = browser.filePresentationID
        self.urls = urls; window = browser.view.window
    }
}

@MainActor
private final class OpenWithChoice: NSObject {
    let request: OpenShareRequest
    let items: [OpenShareItem]
    let access: FileAccessLifetimes
    let application: URL?
    init(request: OpenShareRequest, items: [OpenShareItem], access: FileAccessLifetimes, application: URL?) {
        self.request = request; self.items = items; self.access = access; self.application = application
    }
}

private struct OpenShareSelectionContext: Equatable {
    let visit: UUID
    let tab: UUID
    let presentation: UUID
    let urls: [URL]
    let suspended: Bool
    let window: ObjectIdentifier?
}

private struct OpenWithPreparedSelection: Sendable {
    let items: [OpenShareItem]
    let applications: [OpenWithApplication]
    let access: FileAccessLifetimes
}

@MainActor
final class BrowserOpenAndShareController: NSObject, NSMenuDelegate {
    weak var browser: BrowserViewController?
    let reader = OpenWithApplicationReader.shared
    var hooks = BrowserOpenShareHooks()
    private enum PreparationPurpose { case discovery, opening, sharing }
    private var preparationPurpose: PreparationPurpose?
    private var preparation: Task<Void, Never>? {
        didSet {
            if let oldValue {
                let id = UUID()
                retiringPreparations[id] = Task { [self] in
                    await oldValue.value
                    retiringPreparations.removeValue(forKey: id)
                }
            }
            if preparation == nil { preparationPurpose = nil }
        }
    }
    private var retiringPreparations: [UUID: Task<Void, Never>] = [:]
    private var revision = UUID()
    private weak var discoveryMenu: NSMenu?
    private weak var originMenu: NSMenu?
    private var menuOrigin: OpenShareRequest?
    private var shareSession: BrowserNativeShareSession?
    private var chooser: NSOpenPanel?
    private var launchCount = 0
    private var lastSelectionContext: OpenShareSelectionContext?
    private let menus = NSHashTable<NSMenu>.weakObjects()
    #if DEBUG
    var permitsVerification = false
    #endif

    init(browser: BrowserViewController) {
        self.browser = browser; super.init(); ApplicationNativeSharing.register(self)
    }

    var canOpen: Bool { !ApplicationFileActivity.gate.isClosed && ApplicationNativeSharing.canPrepare && eligibleURLs != nil }
    var canShare: Bool {
        canOpen && (preparation == nil || preparationPurpose == .discovery)
            && shareSession == nil && BrowserNativeShareSession.canStart
    }
    var canSendViaAirDrop: Bool { NativeAirDropFeature.available && canShare }
    fileprivate var preparationCount: Int { retiringPreparations.count + (preparation == nil ? 0 : 1) }
    fileprivate var hasPendingPreparation: Bool { preparationCount > 0 }
    fileprivate var hasChosenHandoff: Bool { shareSession?.hasChosenService == true }
    fileprivate func cancelPreparation() { invalidatePreparation(); discoveryMenu = nil }

    private var eligibleURLs: [URL]? {
        guard let browser, let urls = eligibleSelection, let window = browser.view.window,
              browser.hasFileCommandFocus || ownsMenuContext(window: window, urls: urls) else { return nil }
        return urls
    }

    private var eligibleSelection: [URL]? {
        guard let browser, browser.isActiveCommandPane, !browser.isBrowserSuspended, !browser.isLoading,
              !browser.isMetadataAccessQualification, !browser.showsComputerVolumes,
              browser.view.window != nil, browser.view.window?.attachedSheet == nil,
              !(browser.view.window?.firstResponder is NSTextView) else { return nil }
        #if DEBUG
        if browser.isVerificationSession && !permitsVerification { return nil }
        #endif
        guard browser.selectedItemCount > 0 && browser.selectedItemCount <= OpenWithApplicationReader.maximumItems else { return nil }
        let urls = browser.orderedSelectedURLs
        guard !urls.isEmpty, urls.count <= OpenWithApplicationReader.maximumItems else { return nil }
        guard urls.allSatisfy({ url in
            guard let row = browser.rowsByURL[url], browser.displayedEntries.indices.contains(row) else { return false }
            let kind = browser.displayedEntries[row].kind
            return kind == .file || kind == .directory || kind == .package
        }) else { return nil }
        return urls
    }

    private func current(_ request: OpenShareRequest, requireFocus: Bool = true) -> Bool {
        guard let browser, browser.isActiveCommandPane, let window = request.window, browser.view.window === window,
              !browser.isBrowserSuspended, browser.sessionID == request.visit,
              browser.activeID == request.tab, browser.filePresentationID == request.presentation,
              browser.selectedItemCount == request.urls.count,
              browser.orderedSelectedURLs == request.urls else { return false }
        #if DEBUG
        if browser.isVerificationSession && permitsVerification && browser.permitsBackgroundVerification { return true }
        #endif
        return !requireFocus || NSApplication.shared.keyWindow === window
            || ownsMenuContext(window: window, urls: request.urls)
    }

    private func ownsMenuContext(window: NSWindow, urls: [URL]) -> Bool {
        guard let menuOrigin, originMenu != nil, menuOrigin.window === window,
              menuOrigin.urls == urls, eligibleSelection == urls, window.isVisible,
              NSApplication.shared.isActive,
              NSApplication.shared.mainWindow === window else { return false }
        return current(menuOrigin, requireFocus: false)
    }

    func selectionDidChange() {
        let context = browser.map { browser in
            OpenShareSelectionContext(visit: browser.sessionID, tab: browser.activeID,
                presentation: browser.filePresentationID,
                urls: browser.selectedItemCount <= OpenWithApplicationReader.maximumItems ? browser.orderedSelectedURLs : [],
                suspended: browser.isBrowserSuspended,
                window: browser.view.window.map(ObjectIdentifier.init))
        }
        guard context != lastSelectionContext else { return }
        lastSelectionContext = context
        invalidatePreparation()
    }

    private func invalidatePreparation() {
        revision = UUID()
        originMenu = nil; menuOrigin = nil
        preparation?.cancel(); preparation = nil
        chooser?.cancel(nil); chooser = nil
        for menu in menus.allObjects { resetOpenWith(menu) }
        // Chosen services continue to own their captured items/access until terminal
        // callbacks. Selection changes cannot replace the items being shared.
        if shareSession?.hasChosenService == false { shareSession?.closeUnchosenPicker() }
    }

    func contextWillChange() {
        lastSelectionContext = nil
        invalidatePreparation()
        discoveryMenu = nil
    }

    func windowWillClose() {
        contextWillChange()
        shareSession?.detachSourceWindow()
    }

    func makeOpenWithMenu() -> NSMenu {
        let menu = NSMenu(title: "Open With")
        menu.autoenablesItems = false
        menu.delegate = self
        resetOpenWith(menu)
        menus.add(menu)
        return menu
    }

    private func resetOpenWith(_ menu: NSMenu) {
        menu.removeAllItems()
        // AppKit does not traverse a native submenu with no items. Retain a
        // non-actionable placeholder while releasing all captured choices.
        let placeholder = NSMenuItem(title: "Finding Applications…", action: nil, keyEquivalent: "")
        placeholder.isEnabled = true
        menu.addItem(placeholder)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        prepareOpenWith(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let browser, let urls = eligibleSelection, let window = browser.view.window,
           NSApplication.shared.isActive, NSApplication.shared.mainWindow === window {
            originMenu = menu
            menuOrigin = OpenShareRequest(browser: browser, urls: urls)
        }
        prepareOpenWith(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        if discoveryMenu === menu {
            if preparationPurpose == .discovery { preparation?.cancel(); preparation = nil }
            discoveryMenu = nil
        }
        let closedItems = menu.items
        let closedOrigin = originMenu === menu ? menuOrigin?.id : nil
        // AppKit may dispatch the chosen action after menuDidClose. Let that
        // synchronous action capture its choice before releasing closed-menu
        // scopes; do not erase newer choices or a reopened tracking session.
        Task { @MainActor [weak self, weak menu] in
            guard let self, let menu else { return }
            if let closedOrigin, self.originMenu === menu, self.menuOrigin?.id == closedOrigin {
                self.originMenu = nil; self.menuOrigin = nil
            }
            guard self.discoveryMenu !== menu,
                  menu.items.count == closedItems.count,
                  zip(menu.items, closedItems).allSatisfy({ $0.0 === $0.1 }) else { return }
            self.resetOpenWith(menu)
        }
    }

    private func prepareOpenWith(_ menu: NSMenu) {
        if discoveryMenu === menu && preparation != nil { return }
        menu.removeAllItems()
        guard ApplicationNativeSharing.canPrepare else {
            menu.addItem(disabled("Wait for the previous request to finish")); return
        }
        guard preparation == nil || preparationPurpose == .discovery else {
            menu.addItem(disabled("Wait for the selected request to finish")); return
        }
        guard let browser, let urls = eligibleURLs else {
            menu.addItem(disabled("Select up to 64 accessible files or folders")); return
        }
        if browser.isVerificationSession && hooks.discover == nil {
            menu.addItem(disabled("Application discovery requires a verification fixture seam")); return
        }
        preparation?.cancel(); revision = UUID()
        let token = revision, request = OpenShareRequest(browser: browser, urls: urls)
        let accessPreparation = browser.folderAccess.prepareAccess(to: urls)
        discoveryMenu = menu
        menu.addItem(disabled("Finding Applications…"))
        let discover = hooks.discover
        // Main-actor Tasks cannot advance inside NSMenu's tracking loop. Start
        // independently, then publish on the main run loop in both modes. Only
        // immutable observations cross this seam; no filesystem work runs there.
        preparationPurpose = .discovery
        preparation = Task.detached { [weak self, reader] in
            let result: Result<OpenWithPreparedSelection, Error>
            do {
                let access = try await reader.acquire(accessPreparation)
                let items = try await reader.observe(urls)
                let apps: [OpenWithApplication]
                if let discover { apps = try await discover(urls) }
                else { apps = try await reader.applications(for: urls) }
                try Task.checkCancellation()
                result = .success(OpenWithPreparedSelection(items: items, applications: apps, access: access))
            } catch { result = .failure(error) }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                RunLoop.main.perform(inModes: [.default, .eventTracking]) { [weak self] in
                    MainActor.assumeIsolated {
                        defer { continuation.resume() }
                        guard let self, self.revision == token else { return }
                        self.preparation = nil
                        guard let browser = self.browser, self.current(request),
                              browser.folderAccess.isCurrent(accessPreparation),
                              let menu = self.discoveryMenu else { return }
                        self.publishOpenWith(result, request: request, into: menu)
                    }
                }
            }
        }
    }


    private func publishOpenWith(_ result: Result<OpenWithPreparedSelection, Error>,
                                 request: OpenShareRequest, into menu: NSMenu) {
        menu.removeAllItems()
        switch result {
        case .success(let selection):
            if browser?.isVerificationSession == true && hooks.launch == nil { return }
            for app in selection.applications {
                let item = NSMenuItem(title: app.title, action: #selector(chooseOpenWith(_:)), keyEquivalent: "")
                item.target = self
                item.toolTip = app.url.path
                item.representedObject = OpenWithChoice(request: request, items: selection.items,
                    access: selection.access, application: app.url)
                menu.addItem(item)
            }
            if selection.applications.isEmpty { menu.addItem(disabled("No Common Application")) }
            menu.addItem(.separator())
            let other = NSMenuItem(title: "Other…", action: #selector(chooseOpenWith(_:)), keyEquivalent: "")
            other.target = self
            other.representedObject = OpenWithChoice(request: request, items: selection.items,
                access: selection.access, application: nil)
            menu.addItem(other)
        case .failure(let error):
            if error is CancellationError { return }
            menu.addItem(disabled("Applications Unavailable"))
            report("The selected items are unavailable or changed. Select them again.", request: request)
        }
    }

    func showOpenWith() {
        guard let browser, canOpen, preparation == nil else { return }
        let menu = makeOpenWithMenu()
        let anchor = browser.activeFileSelectionAnchor(for: browser.orderedSelectedURLs)
        _ = menu.popUp(positioning: nil, at: anchor?.rect.origin ?? NSPoint(x: 16, y: 16),
                       in: anchor?.view ?? browser.activeFileView)
    }

    /// A saved app URL is a preference, not authority. The existing access,
    /// observation, request fencing and launch owner remain authoritative.
    func openPreferredApplication(_ application: URL, for entry: FileEntry) {
        guard canOpen, preparation == nil || preparationPurpose == .discovery,
              let browser, eligibleURLs == [entry.url], entry.kind == .file || entry.kind == .package else {
            browser?.status.stringValue = "Select this item again before opening it with the chosen application."
            return
        }
        let target = EditorOpeningTarget.externalApplication(application)
        guard browser.settings.editorPreferences.target(forFilename: entry.name) == target else { return }
        let request = OpenShareRequest(browser: browser, urls: [entry.url])
        let accessPreparation = browser.folderAccess.prepareAccess(to: request.urls)
        preparation?.cancel(); discoveryMenu = nil; revision = UUID()
        let token = revision
        preparationPurpose = .opening
        preparation = Task { [weak self, weak browser, reader] in
            guard let self, let browser else { return }
            defer { if self.revision == token { self.preparation = nil } }
            do {
                let access = try await reader.acquire(accessPreparation)
                let items = try await reader.observe(request.urls)
                #if DEBUG
                if let hold = self.hooks.preferredOpeningBeforeRevalidation { await hold() }
                #endif
                try Task.checkCancellation()
                try await reader.revalidate(items)
                let chosen = try await reader.applicationForHandoff(application, excludingTraverse: true)
                try await reader.revalidate(items)
                guard !Task.isCancelled, self.revision == token, self.current(request),
                      browser.folderAccess.isCurrent(accessPreparation),
                      browser.settings.editorPreferences.target(forFilename: entry.name) == target else { return }
                let choice = OpenWithChoice(request: request, items: items, access: access, application: chosen)
                self.launchPreparedChoice(choice, application: chosen)
            } catch {
                guard !Task.isCancelled, self.revision == token else { return }
                let message = (error as? OpenShareFailure) == .applicationUnavailable
                    ? "The chosen application is unavailable. Choose it again in Settings or use Open in Default App."
                    : "This item changed or is unavailable. Select it again before opening."
                self.report(message, request: request)
            }
        }
    }

    @objc private func chooseOpenWith(_ sender: NSMenuItem) {
        guard ApplicationNativeSharing.canPrepare,
              let choice = sender.representedObject as? OpenWithChoice, current(choice.request),
              let browser, let window = choice.request.window else { return }
        // This accepted item action now owns the handoff. Native menu windows
        // need not restore key focus before their close callbacks complete.
        if !browser.isControlledVerification && NSApplication.shared.keyWindow !== window { window.makeKeyAndOrderFront(nil) }
        discoveryMenu = nil
        preparation?.cancel(); revision = UUID()
        let token = revision
        preparationPurpose = .opening
        preparation = Task { [weak self, reader, weak browser] in
            guard let self, let browser else { return }
            defer { if self.revision == token { self.preparation = nil } }
            var application = choice.application
            if application == nil {
                if let choose = self.hooks.chooseApplication { application = await choose(window) }
                else {
                    if browser.isVerificationSession { self.preparation = nil; return }
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.applicationBundle]
                    panel.canChooseFiles = true; panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
                    panel.prompt = "Open"; panel.message = "Choose an application for this opening only."
                    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
                    self.chooser = panel
                    let response = await panel.beginSheetModal(for: window)
                    if response == .OK { application = panel.url }
                    if self.chooser === panel { self.chooser = nil }
                }
            }
            guard !Task.isCancelled, self.revision == token, self.current(choice.request), let application else {
                if self.revision == token { self.preparation = nil }; return
            }
            do {
                try await reader.revalidate(choice.items)
                let handoffApplication = try await reader.applicationForHandoff(application)
                guard !Task.isCancelled, self.revision == token, self.current(choice.request) else { return }
                self.launchPreparedChoice(choice, application: handoffApplication)
            } catch {
                if self.revision == token { self.preparation = nil }
                if !Task.isCancelled {
                    let text = (error as? OpenShareFailure) == .applicationUnavailable
                        ? "The selected application is unavailable or could not be validated. Choose another application."
                        : "The selected items are unavailable or changed before opening. Select them again."
                    self.report(text, request: choice.request)
                }
            }
        }
    }

    private func launchPreparedChoice(_ choice: OpenWithChoice, application: URL) {
        guard let browser, current(choice.request) else { return }
        preparation = nil
        if browser.isVerificationSession && hooks.launch == nil { return }
        guard launchCount < 8 else {
            report("Wait for pending opening requests before opening more items.", request: choice.request); return
        }
        launchCount += 1
        browser.status.stringValue = "Opening \(choice.items.count) selected item(s)…"
        let finish: @MainActor @Sendable (Error?) -> Void = { [weak self, choice] error in
            withExtendedLifetime(choice.access) {}
            guard let self else { return }
            self.launchCount = max(0, self.launchCount - 1)
            self.report(error == nil ? "Opening request accepted by the selected application."
                : "The selected application could not open these items.", request: choice.request)
        }
        if let launch = hooks.launch { launch(choice.request.urls, application, finish) }
        else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.allowsRunningApplicationSubstitution = false
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.open(choice.request.urls, withApplicationAt: application, configuration: configuration) { _, error in
                Task { @MainActor in finish(error) }
            }
        }
    }

    private enum SharingPurpose { case picker, airDrop }
    func shareSelection() { beginSharing(.picker) }
    func sendViaAirDrop() { guard NativeAirDropFeature.available else { return }; beginSharing(.airDrop) }
    private func beginSharing(_ purpose: SharingPurpose) {
        guard let browser, canShare, let urls = eligibleURLs else { return }
        if browser.isVerificationSession {
            switch purpose {
            case .picker:
                #if DEBUG
                guard hooks.share != nil || hooks.pickerPresentation != nil else { return }
                #else
                guard hooks.share != nil else { return }
                #endif
            case .airDrop: guard hooks.airDropService != nil, hooks.airDropCanPerform != nil,
                                hooks.airDropPerform != nil else { return }
            }
        }
        preparation?.cancel(); revision = UUID()
        let token = revision, request = OpenShareRequest(browser: browser, urls: urls)
        let accessPreparation = browser.folderAccess.prepareAccess(to: urls)
        let preparationProbe = hooks.sharePreparation
        // Explicit Share replaces application discovery, including its menu
        // cleanup authority. Closing that old submenu must not cancel Share.
        discoveryMenu = nil
        for menu in menus.allObjects { resetOpenWith(menu) }
        preparationPurpose = .sharing
        preparation = Task { [weak self, reader, weak browser] in
            guard let self, let browser else { return }
            defer { if self.revision == token { self.preparation = nil } }
            let access = await browser.accessLifetime(for: urls)
            do {
                let items = try await reader.observe(urls, before: { try preparationProbe?(.observing, urls) })
                guard !Task.isCancelled, self.revision == token, self.current(request),
                      browser.folderAccess.isCurrent(accessPreparation) else { return }
                try await reader.revalidate(items, before: { try preparationProbe?(.revalidating, urls) })
                guard !Task.isCancelled, self.revision == token, self.current(request),
                      browser.folderAccess.isCurrent(accessPreparation) else { return }
                guard BrowserNativeShareSession.canStart, self.shareSession == nil else {
                    self.report("Wait for an active sharing service before starting another share.", request: request); return
                }
                let service: NSSharingService?
                switch purpose {
                case .picker: service = nil
                case .airDrop:
                    if let make = self.hooks.airDropService { service = make(.sendViaAirDrop) }
                    else { service = NSSharingService(named: .sendViaAirDrop) }
                    guard let service, self.hooks.airDropCanPerform?(service, urls) ?? service.canPerform(withItems: urls) else {
                        self.report("AirDrop isn’t available for these selected items.", request: request); return
                    }
                }
                let session = try BrowserNativeShareSession(urls: urls, access: access, window: request.window) { [weak self] id, error in
                    guard let self, self.shareSession?.id == id else { return }
                    self.shareSession = nil
                    let text: String
                    let name = purpose == .airDrop ? "AirDrop" : "Sharing"
                    if let error = error as? CocoaError, error.code == .userCancelled { text = name + " cancelled." }
                    else { text = error == nil ? name + " handoff finished." : name + " did not complete." }
                    self.report(text, request: request)
                }
                self.shareSession = session
                if let service {
                    #if DEBUG
                    session.beforeDirectArmingForVerification = self.hooks.airDropBeforeArming
                    #endif
                    self.report("AirDrop opened for \(urls.count) selected item(s). Choose a recipient or cancel in macOS.", request: request)
                    session.performAirDrop(service, fixture: self.hooks.airDropPerform)
                } else {
                    if let share = self.hooks.share { session.performFixtureShare(share) }
                    else {
                        #if DEBUG
                        if let present = self.hooks.pickerPresentation {
                            session.presentFixturePicker(present, close: self.hooks.pickerClose)
                            return
                        }
                        #endif
                        guard let anchor = browser.activeFileSelectionAnchor(for: request.urls) else {
                            session.closeUnchosenPicker(); return
                        }
                        session.show(relativeTo: anchor.rect, of: anchor.view)
                    }
                }
            } catch {
                guard !Task.isCancelled, self.revision == token else { return }
                self.preparation = nil
                self.report("The selected items are unavailable or changed. Select them again.", request: request)
            }
        }
    }

    /// Compatibility inspection returns coordinates in the active file surface.
    /// Real picker presentation uses the paired view and rectangle together.
    func sharingAnchor(for urls: [URL]) -> NSRect? {
        browser?.activeFileSelectionAnchor(for: urls)?.rect
    }

    private func report(_ text: String, request: OpenShareRequest) {
        if current(request, requireFocus: false) { browser?.status.stringValue = text }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.isEnabled = false; return item
    }

    #if DEBUG
    var verificationState: (preparing: Bool, sharing: Bool, launches: Int, shareAccessRetained: Bool) {
        (hasPendingPreparation, shareSession != nil, launchCount, shareSession?.hasAccess == true)
    }
    func prepareOpenWithForVerification(_ menu: NSMenu) { prepareOpenWith(menu) }
    #endif
}

/// Chosen services outlive a browser window. The registry retains only active
/// explicit sessions until a service's terminal callback, not through app history.
@MainActor
private final class BrowserNativeShareSession: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private static var active: [UUID: BrowserNativeShareSession] = [:]
    // Named services need not be fresh objects. One app-wide invocation prevents
    // concurrent requests from replacing the same native object's weak delegate.
    static var canStart: Bool { active.isEmpty }
    static var hasActiveHandoff: Bool { active.values.contains { $0.hasChosenService } }
    #if DEBUG
    static var activeHandoffsForVerification: Int { active.values.filter(\.hasChosenService).count }
    #endif
    let id: UUID
    private let urls: [URL]
    private let trace: UUID
    private var access: FileAccessLifetimes?
    private var activity: (any Sendable)?
    private weak var window: NSWindow?
    private var picker: NSSharingServicePicker?
    private var originalService: NSSharingService?
    private var pickerAnnouncedService: NSSharingService?
    private var completion: ((UUID, Error?) -> Void)?
    private var directExecutionArmed = false
    private var pickerExecutionArmed = false
    private var capturedWillObserved = false
    private var refusedTerminalRecorded = false
    private(set) var hasChosenService = false
    var hasAccess: Bool { access != nil }
    #if DEBUG
    var beforeDirectArmingForVerification: (@MainActor (NSSharingService, [URL]) -> Void)?
    private var pickerCloseForVerification: (@MainActor (NSSharingServicePicker) -> Void)?
    #endif

    init(urls: [URL], access: FileAccessLifetimes, window: NSWindow?, completion: @escaping (UUID, Error?) -> Void) throws {
        guard Self.canStart else { throw OpenShareFailure.unavailable }
        let id = UUID(); self.id = id
        activity = try ApplicationFileActivity.gate.begin()
        trace = ApplicationDiagnostics.shared.currentTrace ?? id
        self.urls = urls; self.access = access; self.window = window; self.completion = completion
        super.init()
        Self.active[id] = self
        record(.presenting)
    }

    private var isLive: Bool { completion != nil && Self.active[id] === self }

    private func record(_ phase: DiagnosticPhase) {
        // Existing closed vocabulary only. Counts describe the captured input,
        // never a native provider's data or recipient/destination information.
        ApplicationDiagnostics.shared.event(.share, phase, trace: trace,
            count: UInt64(urls.count), context: .init(.nativeStatus,
                flags: capturedWillObserved ? [.sourceObserved] : [.sourceNotPrepared]))
    }

    private func makePicker() -> NSSharingServicePicker {
        let picker = NSSharingServicePicker(items: urls)
        picker.delegate = self; self.picker = picker
        return picker
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        guard view.window === window, !rect.isEmpty, rect.intersects(view.visibleRect) else {
            finish(OpenShareFailure.unavailable, phase: .blocked); return
        }
        let picker = makePicker()
        picker.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }

    #if DEBUG
    /// Generated controls enter the same real picker delegate methods without
    /// displaying a native recipient UI or constructing this private owner.
    func presentFixturePicker(_ present: @MainActor (NSSharingServicePicker, [URL]) -> Void,
                              close: (@MainActor (NSSharingServicePicker) -> Void)?) {
        pickerCloseForVerification = close
        present(makePicker(), urls)
    }
    #endif

    func performFixtureShare(_ action: @MainActor ([URL], @escaping @MainActor @Sendable (Error?) -> Void) -> Void) {
        hasChosenService = true
        action(urls) { [weak self] error in self?.finish(error, phase: Self.terminalPhase(error)) }
    }

    func performAirDrop(_ service: NSSharingService,
                        fixture: (@MainActor (NSSharingService, [URL]) -> Void)?) {
        guard isLive, originalService == nil,
              service.delegate == nil || service.delegate === self else {
            if isLive && !hasChosenService { finish(OpenShareFailure.unavailable, phase: .blocked) }
            return
        }
        originalService = service; service.delegate = self
        #if DEBUG
        beforeDirectArmingForVerification?(service, urls)
        #endif
        guard isLive else { return }
        guard service.delegate === self else { finish(OpenShareFailure.unavailable, phase: .blocked); return }
        // Native callbacks may occur synchronously inside perform. This one-use
        // delegate channel is armed before entering the documented native API.
        hasChosenService = true; directExecutionArmed = true
        record(.dispatched)
        if let fixture { fixture(service, urls) }
        else { service.perform(withItems: urls) }
    }

    func closeUnchosenPicker() {
        guard isLive, !hasChosenService else { return }
        if let picker {
            #if DEBUG
            if let close = pickerCloseForVerification { close(picker) }
            else { picker.close() }
            #else
            picker.close()
            #endif
        }
        // close() can invoke delegates before returning. A newly chosen service
        // keeps its access; closing a picker is not cancellation of that service.
        guard isLive, !hasChosenService else { return }
        finish(CocoaError(.userCancelled), phase: .cancelled)
    }

    func detachSourceWindow() { window = nil }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        guard sharingServicePicker === picker, sharingServicePicker.delegate === self, isLive else { return }
        guard let service else {
            if !hasChosenService { finish(CocoaError(.userCancelled), phase: .cancelled) }
            return
        }
        hasChosenService = true
        // Selection is a hint until delegateFor authoritatively supplies the
        // service receiving this owner. A later hint cannot replace that service.
        if originalService == nil && pickerAnnouncedService == nil { pickerAnnouncedService = service }
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? {
        guard sharingServicePicker === picker, sharingServicePicker.delegate === self, isLive else { return nil }
        // Both documented selection callbacks latch this state. Their ordering
        // must not expose chosen work to closeUnchosenPicker().
        hasChosenService = true
        guard sharingService.delegate == nil || sharingService.delegate === self,
              originalService.map({ Self.sameLogicalService($0, sharingService) }) ?? true,
              pickerAnnouncedService.map({ Self.sameLogicalService($0, sharingService) }) ?? true else { return nil }
        if originalService == nil { originalService = sharingService }
        // AppKit installs the returned delegate before executing this choice.
        // This is the generic picker's arming point; it is not our perform stack.
        if !pickerExecutionArmed { pickerExecutionArmed = true; record(.dispatched) }
        return self
    }

    private func exactCapturedItems(_ items: [Any]) -> Bool {
        items.count == urls.count && zip(items, urls).allSatisfy { ($0.0 as? URL) == $0.1 }
    }

    func sharingService(_ sharingService: NSSharingService, willShareItems items: [Any]) {
        guard ownsCallbackChannel(sharingService), exactCapturedItems(items), !capturedWillObserved else { return }
        capturedWillObserved = true
        record(.verifying)
    }

    private static func sameLogicalService(_ original: NSSharingService, _ incoming: NSSharingService) -> Bool {
        original.isEqual(incoming) && incoming.isEqual(original)
    }

    private func ownsCallbackChannel(_ service: NSSharingService) -> Bool {
        guard isLive, hasChosenService, directExecutionArmed || pickerExecutionArmed,
              let originalService, service.delegate === self else { return false }
        let originalDelegate = originalService.delegate
        // A picker may retain a delegateFor argument whose public delegate stays
        // nil while its distinct live callback proxies carry the returned owner.
        // Direct perform still requires our explicit delegate installation.
        let pickerWithNilOriginal = pickerExecutionArmed && !directExecutionArmed && originalDelegate == nil
        guard originalDelegate === self || pickerWithNilOriginal else { return false }
        // AppKit may supply a fresh proxy for every callback. Logical equality
        // corroborates service semantics; this private one-use delegate supplies
        // invocation correlation. Neither items nor proxy pointers supply it.
        return Self.sameLogicalService(originalService, service)
    }

    private static func terminalPhase(_ error: Error?) -> DiagnosticPhase {
        if let error = error as? CocoaError, error.code == .userCancelled { return .cancelled }
        return error == nil ? .finished : .failed
    }

    private func nativeTerminal(_ service: NSSharingService, error: Error?) {
        guard isLive else { return }
        guard ownsCallbackChannel(service) else {
            if !refusedTerminalRecorded { refusedTerminalRecorded = true; record(.blocked) }
            return
        }
        // A terminal can precede willShare (for example a pre-start failure).
        // Missing will is diagnostic, never an invented native work lifetime.
        finish(error, phase: Self.terminalPhase(error), terminalService: service)
    }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        // Native AirDrop terminals may carry opaque item providers, including
        // after native Cancel. Never load/resolve them or infer recipient delivery.
        nativeTerminal(sharingService, error: nil)
    }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        nativeTerminal(sharingService, error: error)
    }
    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any], sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        guard ownsCallbackChannel(sharingService), exactCapturedItems(items) else { return nil }
        return window
    }

    private func finish(_ error: Error?, phase: DiagnosticPhase, terminalService: NSSharingService? = nil) {
        guard isLive, let completion else { return }
        self.completion = nil
        record(phase)
        if picker?.delegate === self { picker?.delegate = nil }
        if originalService?.delegate === self { originalService?.delegate = nil }
        if terminalService !== originalService, terminalService?.delegate === self { terminalService?.delegate = nil }
        picker = nil; originalService = nil; pickerAnnouncedService = nil
        #if DEBUG
        beforeDirectArmingForVerification = nil
        pickerCloseForVerification = nil
        #endif
        access = nil
        activity = nil
        Self.active.removeValue(forKey: id)
        completion(id, error)
    }
}

@MainActor
extension BrowserViewController {
    var canOpenWithSelection: Bool { openAndShare.canOpen }
    var canShareSelection: Bool { openAndShare.canShare }
    var canSendViaAirDrop: Bool { openAndShare.canSendViaAirDrop }
    @objc func openWithSelection(_ sender: Any?) { openAndShare.showOpenWith() }
    @objc func shareSelection(_ sender: Any?) { openAndShare.shareSelection() }
    @objc func sendViaAirDrop(_ sender: Any?) { openAndShare.sendViaAirDrop() }
}
