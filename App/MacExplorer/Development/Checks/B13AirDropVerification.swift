#if DEBUG
import AppKit
import ExplorerCore

/// Generated native dispatch and ownership. Real service perform is forbidden.
private final class B13AirDropProbe: @unchecked Sendable {
    private struct HoldTimeout: Error {}
    private let lock = NSLock()
    private var armed = false
    private let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
    private var onMain = false
    var wasOnMain: Bool { lock.withLock { onMain } }
    func arm() { lock.withLock { armed = true } }
    func read(_ stage: BrowserSharePreparationStage, _ urls: [URL]) throws {
        let hold = lock.withLock { onMain = onMain || Thread.isMainThread; if armed && stage == .observing { armed = false; return true }; return false }
        if hold { entered.signal(); guard released.wait(timeout: .now() + 10) == .success else { throw HoldTimeout() } }
    }
    func awaitEntry() -> Bool { entered.wait(timeout: .now() + 10) == .success }
    func release() { released.signal() }
}
private final class B13AirDropProviderLoadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var loads: Int { lock.withLock { count } }
    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: "public.data", visibility: .all) { [self] complete in
            lock.withLock { count += 1 }
            complete(nil, CocoaError(.fileReadUnknown)); return nil
        }
        return provider
    }
}
@MainActor enum B13AirDropVerification {
    private struct Failure: Error { let stage: String }
    /// Distinct public service objects model equal, ephemeral native callback proxies.
    /// Equality is confined to generated controls; no real service is performed.
    @MainActor private final class FixtureService: NSSharingService {
        nonisolated let equalityID: UUID
        nonisolated let acceptsEquality: Bool
        init(equalityID: UUID = UUID(), acceptsEquality: Bool = true) {
            self.equalityID = equalityID; self.acceptsEquality = acceptsEquality
            super.init(title: "Generated verification service", image: NSImage(size: .init(width: 1, height: 1)), alternateImage: nil, handler: {})
        }
        nonisolated override func isEqual(_ object: Any?) -> Bool {
            acceptsEquality && (object as? FixtureService)?.equalityID == equalityID
        }
        nonisolated override var hash: Int { equalityID.hashValue }
    }
    @MainActor private final class ForeignDelegate: NSObject, NSSharingServiceDelegate, NSSharingServicePickerDelegate {}
    @MainActor private final class Handoff {
        let service: NSSharingService, willService: NSSharingService, sourceService: NSSharingService, terminalService: NSSharingService, urls: [URL]
        let delegate: (any NSSharingServiceDelegate)?
        init(_ service: NSSharingService, _ urls: [URL], callbackOwner: (any NSSharingServiceDelegate)? = nil) {
            self.service = service; self.urls = urls; delegate = callbackOwner ?? service.delegate
            willService = B13AirDropVerification.service(matching: service)
            sourceService = B13AirDropVerification.service(matching: service)
            terminalService = B13AirDropVerification.service(matching: service)
            willService.delegate = delegate; sourceService.delegate = delegate; terminalService.delegate = delegate
        }
        func will(service other: NSSharingService? = nil, items: [Any]? = nil) {
            delegate?.sharingService?(other ?? willService, willShareItems: items ?? urls)
        }
        func finish(_ error: Error? = nil, service other: NSSharingService? = nil, items: [Any]? = nil) {
            if let error { delegate?.sharingService?(other ?? terminalService, didFailToShareItems: items ?? urls, error: error) }
            else { delegate?.sharingService?(other ?? terminalService, didShareItems: items ?? urls) }
        }
        func sourceWindow(service other: NSSharingService? = nil, items: [Any]? = nil) -> NSWindow? {
            var scope = NSSharingService.SharingContentScope.item
            return delegate?.sharingService?(other ?? sourceService, sourceWindowForShareItems: items ?? urls, sharingContentScope: &scope) ?? nil
        }
    }
    @MainActor private final class ClosedSourceLifetime {
        weak var browser: BrowserViewController?
        weak var window: NSWindow?
        init(browser: BrowserViewController, window: NSWindow) { self.browser = browser; self.window = window }
    }
    @MainActor private final class Context {
        let root: URL, owner: BrowserWindowController
        var browser: BrowserViewController { owner.workspace.activeBrowser }
        var source: URL { root.appendingPathComponent("source") }
        var available = true, performable = true, sourceChanged = false
        var handoffs = [Handoff](), probes = [B13AirDropProbe](), windows = [NSWindow](), browsers = [BrowserViewController]()
        var namedRequests = [NSSharingService.Name](), checks = [String](), metrics = [String: Any]()
        var genericCalls = 0, externalCalls = 0
        var nextService: NSSharingService?
        var beforeWill: (@MainActor (Handoff) -> Void)?
        var emitsWill = true
        var synchronousTerminal = false
        var synchronousTerminalError: Error?
        var genericFinish: (@MainActor @Sendable (Error?) -> Void)?
        init(root: URL, owner: BrowserWindowController) { self.root = root; self.owner = owner }
        func configure(_ browser: BrowserViewController) {
            browser.permitsBackgroundVerification = true; browser.readVolumesForVerification = { [] }
            browser.folderAccess = FolderAccessController(stateDirectory: nil)
            browser.pinsController = BrowserPinsController(stateDirectory: nil)
            browser.openAndShare.permitsVerification = true
            browser.defaultOpenForVerification = { [weak self] _ in self?.externalCalls += 1; return false }
            browser.openAndShare.hooks.airDropService = { [weak self] name in
                guard let self else { return nil }; namedRequests.append(name)
                guard available else { return nil }
                if let nextService { self.nextService = nil; return nextService }
                return B13AirDropVerification.service()
            }
            browser.openAndShare.hooks.airDropCanPerform = { [weak self] _, _ in self?.performable == true }
            browser.openAndShare.hooks.airDropPerform = { [weak self] service, urls in
                guard let self else { return }
                let handoff = Handoff(service, urls); handoffs.append(handoff)
                beforeWill?(handoff)
                if emitsWill { handoff.will() }
                if synchronousTerminal { handoff.finish(synchronousTerminalError, items: [NSItemProvider()]) }
            }
            browser.openAndShare.hooks.share = { [weak self] _, finish in self?.genericCalls += 1; self?.genericFinish = finish }
        }
    }
    private static func service(matching original: NSSharingService? = nil, acceptsEquality: Bool = true) -> NSSharingService {
        FixtureService(equalityID: (original as? FixtureService)?.equalityID ?? UUID(), acceptsEquality: acceptsEquality)
    }
    private static func require(_ value: Bool, _ stage: String) throws { if !value { throw Failure(stage: stage) } }
    private static func wait(_ stage: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() { try require(.now < deadline, stage); try await Task.sleep(for: .milliseconds(10)) }
    }
    private static func local(_ browser: BrowserViewController, _ source: URL) async throws {
        browser.navigate(to: .directory(source))
        try await wait("generated-local-list") { !browser.isLoading && browser.orderingTask == nil && browser.location == .directory(source) }
    }
    private static func select(_ browser: BrowserViewController, _ urls: [URL]) {
        browser.setFileSelection(Set(urls)); browser.fileSelectionDidChange()
        _ = browser.view.window?.makeFirstResponder(browser.activeFileView)
    }
    private static func begin(_ test: Context, browser: BrowserViewController? = nil, urls: [URL]) async throws -> Handoff {
        let browser = browser ?? test.browser, count = test.handoffs.count
        select(browser, urls)
        try require(browser.canSendViaAirDrop && browser.commandEnabled(#selector(BrowserViewController.sendViaAirDrop(_:))), "actual-airdrop-command-disabled")
        try require(NSApp.sendAction(#selector(BrowserViewController.sendViaAirDrop(_:)), to: browser, from: nil), "native-airdrop-action-undelivered")
        try await wait("fixture-native-handoff") { test.handoffs.count == count + 1 }
        return test.handoffs[count]
    }
    private static func terminal(_ browser: BrowserViewController) async throws {
        try await wait("actual-native-terminal") { !browser.openAndShare.verificationState.sharing && !ApplicationNativeSharing.hasPendingPreparation }
    }
    static func run() async {
        var test: Context?, root: URL?, mode = "", failure: String?
        do {
            let args = ProcessInfo.processInfo.arguments
            guard args.count == 5, Array(args.dropFirst(1).prefix(3)) == ["--verify-ui", "--check-airdrop-native", "--airdrop-mode"],
                  ["full", "reduced", "off"].contains(args[4]), let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure(stage: "exact-airdrop-flags") }
            mode = args[4]
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let area = URL(fileURLWithPath: raw)
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("reservation.json"))) as? [String: Any]
            let admission = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("airdrop-admission.json"))) as? [String: Any]
            try require(area.resolvingSymlinksInPath() == area && area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString: area.lastPathComponent)?.uuidString == area.lastPathComponent
                && marker?["action"] as? String == "airdrop-native" && marker?["packet"] as? String == "traverse-development-v1"
                && admission?["master"] as? String == "7B4FE5D0-444E-4676-A91F-25E69FDDAF8D" && admission?["mode"] as? String == mode
                && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/traverse-release/tooling/derived/Build/Products/Debug/Mac Explorer.app"), "exact-generated-airdrop-scope")
            root = area
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false
            settings.restoresSession = false; settings.reviewsRecoveryAtStartup = false
            settings.motion.mode = mode == "full" ? .full : mode == "reduced" ? .reduced : .off
            settings.appearance = mode == "off" ? .light : .dark; settings.keyboardProfile = .explorer
            let owner = BrowserWindowController(settings: settings), current = Context(root: area, owner: owner); test = current
            try require(owner.isWorkspacePresentation, "airdrop-workspace-dispatch")
            owner.workspace.sessionReady = true
            owner.workspace.willStartBrowserForVerification = { [weak current] in current?.configure($0) }
            current.configure(current.browser)
            owner.window?.setContentSize(.init(width: 1100, height: 680)); owner.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await local(current.browser, current.source)
            try await dispatch(current); try await discovery(current); try await callbacks(current)
            try await pickerCallbacks(current); try await preparation(current); try await capacity(current)
            try require(current.namedRequests.allSatisfy { $0 == .sendViaAirDrop } && current.externalCalls == 0, "wrong-service-name-or-external-open")
            let actual = NSSharingService(named: .sendViaAirDrop)
            current.metrics["realNamedServicePresent"] = actual != nil
            current.metrics["realNamedCanPerformGeneratedURLs"] = actual?.canPerform(withItems: [current.source.appendingPathComponent("First.txt")]) ?? false
            current.checks.append("Actual public named AirDrop availability is observed without real perform, recipients or device transfer")
        } catch { failure = (error as? Failure)?.stage ?? "unexpected-\(String(reflecting: type(of: error)))" }
        if let test {
            test.probes.forEach { $0.release() }
            test.handoffs.forEach { $0.finish(CocoaError(.userCancelled)) }
            test.genericFinish?(CocoaError(.userCancelled)); test.genericFinish = nil
            test.owner.suspendBrowsing(); test.browsers.forEach { $0.suspendBrowser() }
            let drained = await ApplicationNativeSharing.cancelPreparationsAndDrain()
            if !drained { failure = failure ?? "final-preparation-drain-timeout" }
            test.windows.forEach { $0.close() }; test.owner.window?.close()
        }
        if ApplicationNativeSharing.hasActiveHandoff || ApplicationNativeSharing.hasPendingPreparation || ApplicationFileActivity.gate.activeCount != 0 { failure = failure ?? "final-native-ownership-not-drained" }
        if let root {
            let value: [String: Any] = ["passed": failure == nil, "failureStage": failure.map { $0 as Any } ?? NSNull(), "mode": mode,
                "checks": test?.checks ?? [], "metrics": test?.metrics ?? [:], "sourceChanged": test?.sourceChanged ?? false,
                "activityAfter": ApplicationFileActivity.gate.activeCount, "hasActiveHandoffAfter": ApplicationNativeSharing.hasActiveHandoff,
                "hasPendingPreparationAfter": ApplicationNativeSharing.hasPendingPreparation, "externalOpenCalls": test?.externalCalls ?? 0,
                "realServicePerformCalls": 0, "recipientSelections": 0, "actualSend": false, "simulatedNativeService": true,
                "networkRequests": 0, "keychainCalls": 0, "physicalPointer": false, "generatedOnly": true]
            try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("evidence/native-airdrop.json"), options: .withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
    private static func dispatch(_ test: Context) async throws {
        let browser = test.browser, first = test.source.appendingPathComponent("First.txt"), second = test.source.appendingPathComponent("Second.txt")
        for tag in 0...2 {
            let item = NSMenuItem(); item.tag = tag; browser.changeViewMode(item)
            try await wait("actual-file-mode-settled") { !browser.isLoading && browser.orderingTask == nil
                && (!browser.usesFileIcons || browser.iconBrowser.itemCount == browser.displayedEntries.count) }
            select(browser, [first, second])
            let menu = tag == 0 ? BrowserMenus.menu(.file, target: browser) : BrowserMenus.fileContextMenu(target: browser)
            guard let index = menu.items.firstIndex(where: { $0.action == #selector(BrowserViewController.sendViaAirDrop(_:)) }) else { throw Failure(stage: "dedicated-airdrop-menu-missing") }
            let count = test.handoffs.count
            try require(browser.validateMenuItem(menu.items[index]), "dedicated-airdrop-menu-refused")
            menu.performActionForItem(at: index)
            try await wait("native-menu-airdrop-handoff") { test.handoffs.count == count + 1 }
            let handoff = test.handoffs[count]
            try require(handoff.urls == [first, second] && browser.openAndShare.verificationState.shareAccessRetained, "captured-local-ordered-selection")
            handoff.finish(); try await terminal(browser)
        }
        let item = NSMenuItem(); item.tag = 0; browser.changeViewMode(item)
        select(browser, [])
        try require(!browser.canSendViaAirDrop, "empty-selection-airdrop-enabled")
        select(browser, [test.source.appendingPathComponent("Link")])
        try require(!browser.canSendViaAirDrop, "symlink-airdrop-enabled")
        select(browser, (0..<65).map { test.source.appendingPathComponent(String(format: "Count%02d", $0)) })
        try require(!browser.canSendViaAirDrop, "oversized-selection-airdrop-enabled")
        select(browser, [first]); browser.focusLocation(nil)
        try require(browser.pathField.currentEditor() is NSTextView, "real-visible-address-text-editor")
        try require(!browser.canSendViaAirDrop, "text-editor-airdrop-enabled")
        select(browser, [first]); test.available = false; let count = test.handoffs.count
        browser.sendViaAirDrop(nil)
        try await wait("unavailable-preparation-drain") { !ApplicationNativeSharing.hasPendingPreparation }
        try require(test.handoffs.count == count && browser.status.stringValue.contains("isn’t available"), "unavailable-service-handoff")
        test.available = true; test.performable = false; browser.sendViaAirDrop(nil)
        try await wait("cannot-perform-preparation-drain") { !ApplicationNativeSharing.hasPendingPreparation }
        try require(test.handoffs.count == count, "cannot-perform-handoff"); test.performable = true
        browser.navigate(to: .archive(try ArchiveLocation(source: test.source.appendingPathComponent("Review.zip"), format: .zip)))
        try require(browser.orderedSelectedURLs.isEmpty && browser.selectedItemCount == 0 && !browser.canSendViaAirDrop
            && !browser.commandEnabled(#selector(BrowserViewController.sendViaAirDrop(_:)))
            && browser.smbRejectsLocalAction(#selector(BrowserViewController.sendViaAirDrop(_:))), "archive-or-remote-hidden-local-row-escape")
        try await local(browser, test.source)
        test.checks.append("Actual File/context native actions in Details/List/Icons preserve ordered selection; empty/65/symlink/text/archive/remote guards and unavailable service refuse")
    }
    private static func callbacks(_ test: Context) async throws {
        let browser = test.browser, first = test.source.appendingPathComponent("First.txt"), second = test.source.appendingPathComponent("Second.txt")
        let providerProbe = B13AirDropProviderLoadProbe(), provider = providerProbe.provider(), foreign = ForeignDelegate()
        var refused = [Bool]()
        browser.openAndShare.hooks.airDropBeforeArming = { selected, urls in
            let unarmed = Handoff(selected, urls)
            unarmed.will(); unarmed.finish(items: [provider])
            refused.append(browser.openAndShare.verificationState.sharing && unarmed.sourceWindow() == nil)
        }
        test.beforeWill = { handoff in
            let wrong = service(); wrong.delegate = handoff.delegate
            handoff.will(service: wrong); handoff.finish(service: wrong)
            refused.append(browser.openAndShare.verificationState.sharing)
            let asymmetric = service(matching: handoff.service, acceptsEquality: false); asymmetric.delegate = handoff.delegate
            handoff.will(service: asymmetric); handoff.finish(service: asymmetric)
            refused.append(browser.openAndShare.verificationState.sharing)
            handoff.service.delegate = foreign; handoff.will(); handoff.finish()
            refused.append(browser.openAndShare.verificationState.sharing)
            handoff.service.delegate = handoff.delegate
            handoff.terminalService.delegate = foreign; handoff.finish()
            refused.append(browser.openAndShare.verificationState.sharing)
            handoff.terminalService.delegate = handoff.delegate
            handoff.will(items: [second])
            refused.append(handoff.sourceWindow(items: [provider]) == nil)
        }
        let original = try await begin(test, urls: [first])
        test.beforeWill = nil; browser.openAndShare.hooks.airDropBeforeArming = nil
        try require(refused.count == 6 && refused.allSatisfy { $0 }, "unarmed-or-unowned-channel-retired")
        try require(ApplicationNativeSharing.hasActiveHandoff && ApplicationFileActivity.gate.activeCount > 0, "chosen-native-ownership-missing")
        try require(original.willService !== original.service && original.sourceService !== original.willService
            && original.terminalService !== original.willService && original.terminalService !== original.sourceService
            && original.service.isEqual(original.terminalService) && original.terminalService.isEqual(original.service)
            && original.sourceWindow() === browser.view.window && original.sourceWindow(items: [provider]) == nil,
            "terminal-authority-leaked-into-presentation")
        original.terminalService.delegate = foreign; original.finish()
        try require(browser.openAndShare.verificationState.sharing && original.terminalService.delegate === foreign, "foreign-terminal-delegate-retired")
        original.terminalService.delegate = original.delegate
        original.service.delegate = nil; original.finish()
        try require(browser.openAndShare.verificationState.sharing && original.sourceWindow() == nil,
            "direct-nil-original-delegate-retired")
        original.service.delegate = original.delegate
        original.service.delegate = foreign; original.finish()
        try require(browser.openAndShare.verificationState.sharing && original.service.delegate === foreign, "foreign-original-delegate-retired")
        original.service.delegate = original.delegate
        guard let delegate = NSApp.delegate as? ApplicationDelegate else { throw Failure(stage: "actual-app-delegate") }
        let refusals = ApplicationNativeSharing.quitRefusalsForVerification
        try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel
            && ApplicationNativeSharing.quitRefusalsForVerification == refusals + 1, "actual-pending-sharing-quit-guard")
        original.finish(items: [provider]); try await terminal(browser)
        try require(original.service.delegate == nil && original.terminalService.delegate == nil
            && browser.status.stringValue == "AirDrop handoff finished.", "owned-terminal-not-neutrally-retired")
        // Reuse the original factory object only after its genuine terminal. The
        // old callback owner remains captured to exercise stale delivery to it.
        test.nextService = original.service
        let newer = try await begin(test, urls: [first])
        original.finish(service: newer.terminalService, items: [provider])
        try require(newer.service === original.service && browser.openAndShare.verificationState.sharing
            && newer.service.delegate === newer.delegate, "late-callback-cleared-new-session")
        let freshTerminal = service(matching: newer.service); freshTerminal.delegate = newer.delegate
        newer.finish(service: freshTerminal, items: [provider]); try await terminal(browser)
        try require(browser.status.stringValue == "AirDrop handoff finished.", "provider-terminal-reported-delivery")
        try require(freshTerminal.delegate == nil, "fresh-terminal-proxy-delegate-not-retired")
        let different = try await begin(test, urls: [second])
        newer.finish(); try require(browser.openAndShare.verificationState.sharing, "same-to-different-stale-terminal")
        different.finish(NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError), items: [provider]); try await terminal(browser)
        try require(browser.status.stringValue == "AirDrop did not complete.", "native-error-reported-success")
        let finished = try await begin(test, urls: [first]); finished.finish(items: []); try await terminal(browser)
        finished.finish(CocoaError(.userCancelled)); try require(browser.status.stringValue == "AirDrop handoff finished.", "duplicate-callback-changed-terminal")
        test.emitsWill = false; test.synchronousTerminal = true
        _ = try await begin(test, urls: [first]); try await terminal(browser)
        try require(browser.status.stringValue == "AirDrop handoff finished.", "synchronous-terminal-replaced-by-opened")
        test.synchronousTerminalError = CocoaError(.userCancelled)
        _ = try await begin(test, urls: [second]); try await terminal(browser)
        try require(browser.status.stringValue == "AirDrop cancelled.", "failure-before-will-not-retired")
        test.synchronousTerminalError = nil; test.synchronousTerminal = false; test.emitsWill = true
        let occupied = service(); occupied.delegate = foreign; test.nextService = occupied
        let count = test.handoffs.count
        browser.sendViaAirDrop(nil)
        try await wait("foreign-delegate-preparation-drain") { !ApplicationNativeSharing.hasPendingPreparation }
        try require(test.handoffs.count == count && !browser.openAndShare.verificationState.sharing
            && occupied.delegate === foreign, "foreign-delegate-overwritten")
        try require(providerProbe.loads == 0, "terminal-item-provider-was-loaded")
        test.metrics["opaqueProviderLoadCalls"] = providerProbe.loads
        browser.shareSelection(nil)
        try await wait("generic-share-fixture") { test.genericFinish != nil }
        test.genericFinish?(CocoaError(.userCancelled)); test.genericFinish = nil; try await terminal(browser)
        try require(test.genericCalls == 1 && browser.status.stringValue == "Sharing cancelled.", "generic-share-regressed")
        test.checks.append("One-use armed delegate channel rejects wrong/asymmetric/unarmed/delegate-lost callbacks; distinct will/source/terminal proxies and opaque or empty terminals work without provider loads; no-will synchronous success/failure, factory-object reuse, stale/duplicate callbacks and same/different next selections preserve ownership")
    }
    private static func pickerCallbacks(_ test: Context) async throws {
        let browser = test.browser, first = test.source.appendingPathComponent("First.txt")
        let originalHooks = browser.openAndShare.hooks
        defer { browser.openAndShare.hooks = originalHooks }
        browser.openAndShare.hooks.share = nil
        let providerProbe = B13AirDropProviderLoadProbe(), provider = providerProbe.provider()
        var previous: Handoff?, nilOriginalCases = 0
        for (delegateFirst, retainsOriginalDelegate) in [(true, false), (false, false), (true, true), (false, true)] {
            var chosen: Handoff?, seenPicker: NSSharingServicePicker?, heldAfterFirstChoice = false, wrongPickerRefused = false
            browser.openAndShare.hooks.pickerPresentation = { picker, urls in
                seenPicker = picker
                let owner = picker.delegate, selected = service(), otherPicker = NSSharingServicePicker(items: urls)
                let selectedHint = service(matching: selected)
                owner?.sharingServicePicker?(otherPicker, didChoose: selected)
                let wrong = owner?.sharingServicePicker?(otherPicker, delegateFor: selected) ?? nil
                wrongPickerRefused = wrong == nil && !ApplicationNativeSharing.hasActiveHandoff
                var callbackOwner: (any NSSharingServiceDelegate)?
                if delegateFirst {
                    callbackOwner = owner?.sharingServicePicker?(picker, delegateFor: selected) ?? nil
                    if retainsOriginalDelegate { selected.delegate = callbackOwner }
                    browser.openAndShare.contextWillChange()
                    heldAfterFirstChoice = ApplicationNativeSharing.hasActiveHandoff && browser.openAndShare.verificationState.shareAccessRetained
                    owner?.sharingServicePicker?(picker, didChoose: selectedHint)
                } else {
                    owner?.sharingServicePicker?(picker, didChoose: selectedHint)
                    browser.openAndShare.contextWillChange()
                    heldAfterFirstChoice = ApplicationNativeSharing.hasActiveHandoff && browser.openAndShare.verificationState.shareAccessRetained
                    callbackOwner = owner?.sharingServicePicker?(picker, delegateFor: selected) ?? nil
                    if retainsOriginalDelegate { selected.delegate = callbackOwner }
                }
                // AppKit's observed picker path leaves this retained argument's
                // delegate nil and supplies the owner on distinct live proxies.
                let handoff = Handoff(selected, urls, callbackOwner: callbackOwner)
                chosen = handoff; test.handoffs.append(handoff); handoff.will()
                // A later selected-service hint cannot replace the armed owner.
                owner?.sharingServicePicker?(picker, didChoose: service())
                owner?.sharingServicePicker?(picker, didChoose: nil)
            }
            select(browser, [first])
            try require(NSApp.sendAction(#selector(BrowserViewController.shareSelection(_:)), to: browser, from: nil), "picker-native-action-undelivered")
            try await wait("picker-order-handoff") { chosen != nil }
            guard let chosen, let seenPicker else { throw Failure(stage: "picker-order-control-missing") }
            try require(wrongPickerRefused && heldAfterFirstChoice && chosen.sourceWindow() === browser.view.window
                && chosen.delegate != nil && browser.openAndShare.verificationState.sharing,
                "picker-order-invalidation-released-chosen-work")
            try require(retainsOriginalDelegate ? chosen.service.delegate === chosen.delegate : chosen.service.delegate == nil,
                "picker-original-delegate-fixture-not-exact")
            if !retainsOriginalDelegate { nilOriginalCases += 1 }
            try require(chosen.willService !== chosen.service && chosen.sourceService !== chosen.willService
                && chosen.terminalService !== chosen.sourceService && chosen.terminalService !== chosen.willService
                && chosen.willService.delegate === chosen.delegate && chosen.sourceService.delegate === chosen.delegate
                && chosen.terminalService.delegate === chosen.delegate, "picker-callback-proxies-not-distinct-owned")
            previous?.finish(service: chosen.terminalService, items: [provider])
            try require(browser.openAndShare.verificationState.sharing, "retired-picker-cleared-current-handoff")
            let originalDelegate = chosen.service.delegate, foreign = ForeignDelegate()
            chosen.service.delegate = foreign; chosen.will(); chosen.finish(items: [provider])
            try require(browser.openAndShare.verificationState.sharing && chosen.sourceWindow() == nil
                && chosen.service.delegate === foreign, "picker-foreign-original-delegate-retired")
            chosen.service.delegate = originalDelegate
            chosen.terminalService.delegate = nil; chosen.finish(items: [provider])
            try require(browser.openAndShare.verificationState.sharing, "picker-lost-incoming-delegate-retired")
            chosen.terminalService.delegate = foreign; chosen.finish(items: [provider])
            try require(browser.openAndShare.verificationState.sharing && chosen.terminalService.delegate === foreign,
                "picker-foreign-incoming-delegate-retired")
            chosen.terminalService.delegate = chosen.delegate
            let wrongRole = service(); wrongRole.delegate = chosen.delegate
            chosen.will(service: wrongRole); chosen.finish(service: wrongRole, items: [provider])
            let asymmetric = service(matching: chosen.service, acceptsEquality: false); asymmetric.delegate = chosen.delegate
            chosen.will(service: asymmetric); chosen.finish(service: asymmetric, items: [provider])
            try require(browser.openAndShare.verificationState.sharing && chosen.sourceWindow(service: wrongRole) == nil
                && chosen.sourceWindow(service: asymmetric) == nil && chosen.sourceWindow(items: [provider]) == nil,
                "picker-wrong-role-or-items-authorized")
            chosen.sourceService.delegate = nil
            try require(chosen.sourceWindow() == nil, "picker-source-window-lost-delegate-authorized")
            chosen.sourceService.delegate = chosen.delegate
            seenPicker.delegate = foreign
            chosen.finish(items: [provider]); try await terminal(browser)
            try require(seenPicker.delegate === foreign, "retirement-cleared-foreign-picker-delegate")
            chosen.finish(CocoaError(.userCancelled))
            try require(browser.status.stringValue == "Sharing handoff finished.", "picker-duplicate-terminal-changed-outcome")
            previous = chosen
        }
        for cancelled in [false, true] {
            var synchronous: Handoff?
            browser.openAndShare.hooks.pickerPresentation = { picker, urls in
                let owner = picker.delegate, selected = service()
                owner?.sharingServicePicker?(picker, didChoose: service(matching: selected))
                let callbackOwner = owner?.sharingServicePicker?(picker, delegateFor: selected) ?? nil
                let handoff = Handoff(selected, urls, callbackOwner: callbackOwner)
                synchronous = handoff; test.handoffs.append(handoff)
                handoff.finish(cancelled ? CocoaError(.userCancelled) : nil, items: [provider])
            }
            select(browser, [first]); browser.shareSelection(nil)
            try await wait("picker-synchronous-no-will-terminal") { synchronous != nil && !ApplicationNativeSharing.hasPendingPreparation }
            try await terminal(browser)
            try require(synchronous?.service.delegate == nil && !browser.openAndShare.verificationState.shareAccessRetained
                && browser.status.stringValue == (cancelled ? "Sharing cancelled." : "Sharing handoff finished."),
                "picker-no-will-synchronous-outcome")
            nilOriginalCases += 1
        }
        var unchosenPicker: NSSharingServicePicker?, reentrant: Handoff?, closeCalls = 0
        browser.openAndShare.hooks.pickerPresentation = { picker, _ in unchosenPicker = picker }
        browser.openAndShare.hooks.pickerClose = { picker in
            closeCalls += 1
            let owner = picker.delegate, selected = service()
            let callbackOwner = owner?.sharingServicePicker?(picker, delegateFor: selected) ?? nil
            owner?.sharingServicePicker?(picker, didChoose: selected)
            let handoff = Handoff(selected, [first], callbackOwner: callbackOwner); reentrant = handoff; test.handoffs.append(handoff)
            handoff.will()
        }
        select(browser, [first]); browser.shareSelection(nil)
        try await wait("reentrant-picker-presented") { unchosenPicker != nil && !ApplicationNativeSharing.hasPendingPreparation }
        try require(!ApplicationNativeSharing.hasActiveHandoff && !browser.canShareSelection, "unchosen-picker-global-slot-missing")
        browser.openAndShare.contextWillChange()
        guard let reentrant else { throw Failure(stage: "reentrant-choice-not-observed") }
        try require(closeCalls == 1 && reentrant.service.delegate == nil && reentrant.sourceWindow() === browser.view.window
            && ApplicationNativeSharing.hasActiveHandoff && browser.openAndShare.verificationState.shareAccessRetained,
            "reentrant-picker-close-released-chosen-work")
        nilOriginalCases += 1
        reentrant.finish(); try await terminal(browser)
        unchosenPicker = nil
        browser.openAndShare.hooks.pickerClose = { picker in
            closeCalls += 1
            picker.delegate?.sharingServicePicker?(picker, didChoose: nil)
        }
        select(browser, [first]); browser.shareSelection(nil)
        try await wait("unchosen-cancel-picker-presented") { unchosenPicker != nil && !ApplicationNativeSharing.hasPendingPreparation }
        browser.openAndShare.contextWillChange(); try await terminal(browser)
        try require(closeCalls == 2 && !ApplicationNativeSharing.hasActiveHandoff
            && browser.status.stringValue == "Sharing cancelled.", "unchosen-picker-cancel-not-retired")
        try require(nilOriginalCases == 5 && providerProbe.loads == 0, "picker-nil-original-or-provider-load-coverage")
        test.metrics["pickerNilOriginalDelegateCases"] = nilOriginalCases
        test.metrics["pickerOpaqueProviderLoadCalls"] = providerProbe.loads
        test.checks.append("Real picker owner accepts nil/self retained-original delegates in both callback orders with distinct owned live proxies; foreign-original/lost-or-foreign-incoming/wrong-or-asymmetric roles refuse; stale/duplicate/no-will/synchronous and reentrant-close controls preserve ownership without provider loads")
    }
    private static func discovery(_ test: Context) async throws {
        let browser = test.browser, first = test.source.appendingPathComponent("First.txt")
        guard let window = browser.view.window else { throw Failure(stage: "discovery-source-window") }
        window.makeKeyAndOrderFront(nil); select(browser, [first])
        let finder = browser.commandFinder, count = test.handoffs.count
        browser.findCommand(nil); finder.query.stringValue = "Send via AirDrop"; finder.updateMatches()
        try require(finder.matches.first?.command == .sendViaAirDrop && finder.matches.first?.enabled == true, "airdrop-command-finder-missing")
        finder.activateSelection(nil)
        try await wait("command-finder-native-airdrop") { test.handoffs.count == count + 1 }
        test.handoffs[count].finish(); try await terminal(browser)
        let candidates: [(ShortcutSpecialKey, UInt16)] = [(.f7, 98), (.f8, 100), (.f9, 101), (.f10, 109), (.f11, 103), (.f12, 111)]
        func event(_ candidate: (ShortcutSpecialKey, UInt16)) throws -> NSEvent {
            let chord = BrowserShortcut(.special(candidate.0), [.control, .option, .shift])
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: chord.nativeModifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: chord.menuEquivalent, charactersIgnoringModifiers: chord.menuEquivalent, isARepeat: false, keyCode: candidate.1) else { throw Failure(stage: "native-shortcut-event") }
            return event
        }
        SystemShortcutSnapshot.shared.refresh()
        guard let chosen = try candidates.first(where: { try !SystemShortcutSnapshot.shared.conflicts(event($0)) }) else { throw Failure(stage: "no-free-generated-airdrop-chord") }
        let original = browser.settings.keyboardProfile, preferences = browser.settings.shortcutPreferences
        browser.settings.customizeBehavior()
        browser.settings.shortcutPreferences = .init(overrides: [.sendViaAirDrop: [BrowserShortcut(.special(chosen.0), [.control, .option, .shift])]])
        defer { browser.settings.shortcutPreferences = preferences; browser.settings.keyboardProfile = original }
        select(browser, [first]); let before = test.handoffs.count
        try require(try browser.routeBrowserShortcut(event(chosen)), "custom-airdrop-shortcut-unrouted")
        try await wait("custom-shortcut-native-airdrop") { test.handoffs.count == before + 1 }
        test.handoffs[before].finish(); try await terminal(browser)
        browser.focusLocation(nil)
        try require(browser.pathField.currentEditor() is NSTextView, "real-shortcut-text-editor")
        _ = try browser.routeBrowserShortcut(event(chosen))
        try await Task.sleep(for: .milliseconds(20))
        try require(test.handoffs.count == before + 1, "text-editor-shortcut-shared-files")
        select(browser, [first])
        test.checks.append("Find a Command and an unreserved custom native chord dispatch the dedicated route once; text focus cannot share selected files")
    }
    private static func preparation(_ test: Context) async throws {
        let browser = test.browser, first = test.source.appendingPathComponent("First.txt"), probe = B13AirDropProbe()
        test.probes.append(probe); probe.arm(); browser.openAndShare.hooks.sharePreparation = probe.read
        select(browser, [first]); let count = test.handoffs.count; browser.sendViaAirDrop(nil)
        try require(await Task.detached { probe.awaitEntry() }.value, "actual-held-observation")
        guard let delegate = NSApp.delegate as? ApplicationDelegate else { throw Failure(stage: "actual-app-delegate") }
        test.owner.suspendBrowsing()
        let started = ContinuousClock.now
        let drained = await delegate.drainNativeSharingForTermination(test.owner, maximumWait: .milliseconds(30))
        try require(!drained && started.duration(to: .now) < .seconds(2)
            && !browser.isBrowserSuspended && test.owner.window?.isVisible == true
            && browser.status.stringValue == ApplicationNativeSharing.pendingPreparationMessage
            && ApplicationNativeSharing.hasPendingPreparation && ApplicationFileActivity.gate.activeCount > 0,
            "held-preparation-quit-did-not-resume-browsing")
        try await wait("quit-timeout-resumed-local-list") { !browser.isLoading && browser.orderingTask == nil }
        try require(browser.location == .directory(test.source), "quit-timeout-lost-local-location")
        let stillHeld = await ApplicationNativeSharing.cancelPreparationsAndDrain(maximumWait: .milliseconds(20))
        try require(!stillHeld && ApplicationNativeSharing.hasPendingPreparation && test.handoffs.count == count,
            "deadline-discarded-real-preparation")
        probe.release()
        let released = await ApplicationNativeSharing.cancelPreparationsAndDrain()
        try require(released && !probe.wasOnMain && !ApplicationNativeSharing.hasPendingPreparation && test.handoffs.count == count,
            "held-preparation-published-late")
        let terminationReady = await delegate.drainNativeSharingForTermination(test.owner, maximumWait: .milliseconds(100))
        try require(terminationReady, "released-preparation-quit-helper-still-blocked")
        browser.openAndShare.hooks.sharePreparation = nil
        try await paneRevocation(test, browser: browser, first: first)
        let mutable = test.source.appendingPathComponent("Mutable.txt"), replacement = test.source.appendingPathComponent("Replacement.txt")
        browser.openAndShare.hooks.sharePreparation = { stage, urls in
            if stage == .revalidating && urls == [mutable] { try Data(contentsOf: replacement).write(to: mutable) }
        }
        select(browser, [mutable]); browser.sendViaAirDrop(nil)
        try await wait("source-change-preparation-drain") { !ApplicationNativeSharing.hasPendingPreparation }
        test.sourceChanged = true
        try require(test.handoffs.count == count && browser.status.stringValue.contains("unavailable or changed"), "changed-source-was-handed-off")
        browser.openAndShare.hooks.sharePreparation = nil
        test.checks.append("Held off-main observation times out without false drain, real Quit helper resumes usable browsing, and later release actually drains; changed generated source refuses handoff")
    }
    private static func paneRevocation(_ test: Context, browser: BrowserViewController, first: URL) async throws {
        let workspace = test.owner.workspace
        test.owner.window?.setContentSize(.init(width: 1400, height: 780))
        try require(workspace.splitActive(at: .trailing), "airdrop-revocation-pane-split")
        let peer = workspace.activeBrowser
        try require(peer !== browser, "airdrop-revocation-peer")
        try await local(peer, test.source)
        workspace.activate(browser)
        let probe = B13AirDropProbe(); test.probes.append(probe)
        browser.openAndShare.hooks.sharePreparation = probe.read; probe.arm()
        select(browser, [first]); let count = test.handoffs.count; browser.sendViaAirDrop(nil)
        try require(await Task.detached { probe.awaitEntry() }.value, "pane-held-observation")
        workspace.activate(peer); workspace.activate(browser)
        try require(workspace.activeBrowser === browser && ApplicationNativeSharing.hasPendingPreparation,
            "pane-switch-discarded-actual-preparation")
        probe.release()
        try await wait("pane-revoked-actual-drain") { !ApplicationNativeSharing.hasPendingPreparation }
        try require(test.handoffs.count == count && !probe.wasOnMain, "pane-return-revalidated-revoked-request")
        browser.openAndShare.hooks.sharePreparation = nil
        workspace.activate(peer)
        try require(workspace.closeActivePane() && workspace.activeBrowser === browser, "airdrop-revocation-pane-retirement")
        test.checks.append("Actual A-to-B-to-A pane activation revokes the original held request permanently while retaining its real worker until return")
    }
    private static func capacity(_ test: Context) async throws {
        let first = test.source.appendingPathComponent("First.txt"), start = test.handoffs.count
        let lifetime = try await closedSource(test, first: first, chosenCount: 1)
        try await wait("closed-source-ui-retained-by-native-session") { lifetime.browser == nil && lifetime.window == nil }
        try await wait("closed-source-workers-not-actually-drained") { ApplicationFileActivity.gate.activeCount == 1 }
        try require(ApplicationNativeSharing.activeHandoffsForVerification == 1
            && test.handoffs[start].sourceWindow() == nil, "releasing-source-ui-released-native-handoff")
        test.metrics["maximumSimultaneousAuxiliarySourceUI"] = 1
        test.metrics["closedSourceUIWeaklyReleased"] = 1
        test.metrics["chosenSessionsAfterSourceUIRelease"] = ApplicationNativeSharing.activeHandoffsForVerification
        let lookups = test.namedRequests.count
        select(test.browser, [first]); test.browser.sendViaAirDrop(nil)
        try require(test.handoffs.count == start + 1 && test.namedRequests.count == lookups
            && ApplicationNativeSharing.activeHandoffsForVerification == 1 && !test.browser.canSendViaAirDrop,
            "global-one-native-service-cap")
        test.handoffs[start].finish(); try require(ApplicationNativeSharing.activeHandoffsForVerification == 0, "actual-terminal-did-not-release-slot")
        let replacement = try await begin(test, urls: [first]); replacement.finish()
        try await terminal(test.browser)
        test.checks.append("One app-wide chosen handoff remains charged after source window/browser weakly deallocate and workers drain; source-window queries detach, no second factory lookup occurs while active, and the next invocation waits for actual terminal retirement")
    }
    private static func closedSource(_ test: Context, first: URL, chosenCount: Int) async throws -> ClosedSourceLifetime {
        // Retain only the current source for failure cleanup. The native session,
        // not this harness's full UI graphs, must retain each chosen handoff.
        try require(test.windows.isEmpty && test.browsers.isEmpty, "previous-source-ui-still-harness-owned")
        let browser = BrowserViewController(settings: test.browser.settings); test.configure(browser)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 480, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = browser
        test.windows.append(window); test.browsers.append(browser)
        let lifetime = ClosedSourceLifetime(browser: browser, window: window)
        try await local(browser, test.source)
        let handoff = try await begin(test, browser: browser, urls: [first])
        try require(handoff.sourceWindow() === window && browser.openAndShare.verificationState.shareAccessRetained,
            "chosen-source-window-or-access-unavailable-before-close")
        browser.suspendBrowser(); window.close()
        let drained = await ApplicationNativeSharing.cancelPreparationsAndDrain()
        try require(drained && ApplicationNativeSharing.activeHandoffsForVerification == chosenCount
            && browser.openAndShare.verificationState.shareAccessRetained && handoff.sourceWindow() == nil,
            "source-close-did-not-detach-only-window")
        ApplicationNativeSharing.explainPendingSharing(from: browser)
        try require(!window.isVisible && browser.isBrowserSuspended, "pending-helper-resurrected-closed-window")
        test.windows.removeAll(); test.browsers.removeAll()
        return lifetime
    }
}
#endif
