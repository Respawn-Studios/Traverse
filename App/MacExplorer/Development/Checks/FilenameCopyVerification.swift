#if DEBUG
import AppKit
import Darwin
import ExplorerCore
import FileOperations

@MainActor enum FilenameCopyVerification {
    @MainActor private final class Pulse {
        var last = CACurrentMediaTime(), gap = 0.0, ticks = 0
        func tick() { let now = CACurrentMediaTime(); gap = max(gap, now-last); last = now; ticks += 1 }
    }
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"), root.resolvingSymlinksInPath() == root,
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              let data = try? Data(contentsOf: root.appendingPathComponent("reservation.json")),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any], marker["action"] as? String == "traverse-filename-copy-ui" else { exit(2) }
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.folderSummariesEnabled = false
        settings.showsDockProgress = false; settings.motion.mode = .off; settings.showsFileExtensions = false
        let owner = BrowserWindowController(settings: settings), board = NSPasteboard.withUniqueName(), pulse = Pulse()
        let timer = Timer(timeInterval: 0.016, repeats: true) { _ in MainActor.assumeIsolated { pulse.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        var checks: [String] = [], failures: [String] = [], metrics: [String: Any] = [:]
        do { try await verify(root: root, owner: owner, settings: settings, board: board, pulse: pulse, checks: &checks, metrics: &metrics) }
        catch { failures.append(String(describing: error)) }
        owner.suspendBrowsing(); await owner.flushSession(); owner.window?.close(); board.releaseGlobally(); timer.invalidate()
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        if usage.ru_maxrss > 256*1024*1024 { failures.append("Native memory gate failed") }
        if pulse.gap > 0.4 { failures.append("Native response gap gate failed") }
        if pulse.ticks < 10 { failures.append("Native response sampling incomplete") }
        if ApplicationFileActivity.gate.activeCount != 0 { failures.append("Actual filesystem work remains") }
        try? JSONSerialization.data(withJSONObject: ["passed": failures.isEmpty, "checks": checks, "failures": failures, "metrics": metrics,
            "peakRSSBytes": usage.ru_maxrss, "maximumMainActorGapSeconds": pulse.gap, "activityCount": ApplicationFileActivity.gate.activeCount,
            "generatedOnly": true, "systemClipboardReads": 0, "systemClipboardWrites": 0, "privateTestPasteboardOnly": true,
            "fileMutations": 0, "network": 0, "physicalInput": false], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
        NSApp.terminate(nil)
    }
    private static func verify(root: URL, owner: BrowserWindowController, settings: BrowserSettings, board: NSPasteboard,
        pulse: Pulse, checks: inout [String], metrics: inout [String: Any]) async throws {
        try UIVerification.require(owner.isWorkspacePresentation, "Filename copy needs actual workspace")
        guard let window = owner.window else { throw UIVerification.Failure(message: "Browser window missing") }
        window.setFrame(.init(x: -12000, y: -12000, width: 1040, height: 700), display: true); window.makeKeyAndOrderFront(nil)
        let browser = owner.browser
        browser.permitsBackgroundVerification = true; browser.transferPasteboard = board
        browser.folderAccess = FolderAccessController(stateDirectory: nil); browser.pinsController = BrowserPinsController(stateDirectory: nil)
        browser.operationErrorPresenter = { _ in }; browser.operationResultPresenter = { _ in }
        var publications = 0, failPublication = false
        let writer: (String?, [URL]) -> BrowserClipboard.Publication = { text, urls in
            publications += 1
            return failPublication ? .failed : BrowserClipboard.publish(text, urls: urls, to: board)
        }
        browser.clipboardWriter = writer
        browser.recoverableFileOperations = browser.operationCoordinator.engine(at: root.appendingPathComponent("history"))
        owner.beginBrowsing(); try await wait("workspace") { owner.workspace.sessionReady }
        browser.navigate(to: .directory(root.appendingPathComponent("source"))); try await settled(browser)
        let data = try Data(contentsOf: root.appendingPathComponent("oracle.json"))
        guard let oracle = try JSONSerialization.jsonObject(with: data) as? [String: Any], let names = oracle["names"] as? [String], names.count == 2 else { throw UIVerification.Failure(message: "Independent names missing") }
        let expected = names.joined(separator: "\n")
        let urls = try names.map { name in
            guard let entry = browser.displayedEntries.first(where: { $0.name == name }) else { throw UIVerification.Failure(message: "Generated selected file absent") }
            return entry.url
        }
        for mode in BrowserViewMode.allCases {
            browser.setPaneViewMode(mode); try await settled(browser)
            browser.reloadFileRows(preserving: Set(urls))
            try await wait("Real mode selection missing") { browser.selectedItemCount == 2 }
            let file = BrowserMenus.menu(.file, target: browser), context = BrowserMenus.fileContextMenu(target: browser)
            for (menu, title) in [(file, "Copy Names"), (context, "Copy Relative Paths")] {
                let selector = title == "Copy Names" ? #selector(BrowserViewController.copyNames(_:))
                    : #selector(BrowserViewController.copyRelativePaths(_:))
                guard let item = BrowserMenus.commandItem(selector, in: menu), let action = item.action else { throw UIVerification.Failure(message: "Native filename action missing") }
                try UIVerification.require(browser.commandEnabled(action) && NSApp.sendAction(action, to: item.target, from: item), "Native filename action refused")
                try UIVerification.require(board.string(forType: .string) == expected && board.availableType(from: [.fileURL]) == nil,
                    "Native selection order/names/relative text differ from independent Unicode-equivalent oracle, or published file references")
            }
        }
        checks.append("Actual Details/List/Icons File/context actions preserve selected order and real extensions despite hidden extensions, on a private text-only pasteboard")

        browser.setPaneViewMode(.details); try await settled(browser)
        browser.reloadFileRows(preserving: [urls[0]])
        browser.focusBrowserContent()
        settings.customizeBehavior()
        var preferences = settings.shortcutPreferences
        preferences.overrides[.copyNames] = [.init(.special(.f8), [.control, .option])]
        settings.shortcutPreferences = preferences
        let nativeKey = BrowserShortcut(.special(.f8), [.control, .option])
        try UIVerification.require(settings.shortcutMap.resolve(nativeKey, fileSurface: true) == .copyNames,
            "Native test did not activate its explicit Custom shortcut profile")
        guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: String(UnicodeScalar(NSF8FunctionKey)!), charactersIgnoringModifiers: String(UnicodeScalar(NSF8FunctionKey)!), isARepeat: false, keyCode: 100) else { throw UIVerification.Failure(message: "Native custom event missing") }
        let beforeKey = publications
        try UIVerification.require(browser.routeBrowserShortcut(key) && publications == beforeKey + 1, "Optional native shortcut did not use new command")
        browser.focusLocation(nil)
        try UIVerification.require(window.firstResponder is NSTextView, "Native location editor missing")
        let editing = publications
        try UIVerification.require(!browser.routeBrowserShortcut(key) && publications == editing, "Custom filename key overrode native text editing")
        browser.focusBrowserContent()
        checks.append("Optional registered shortcut invokes the native action from files and preserves text/IME precedence")

        let presentationTick = pulse.ticks
        try await wait("Native presentation turn") { pulse.ticks > presentationTick }
        let sheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 340, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet, completionHandler: nil)
        let modalCalls = publications
        try UIVerification.require(!browser.commandEnabled(#selector(browser.copyNames(_:))), "Modal underlying copy enabled")
        browser.copyNames(nil); browser.copyRelativePaths(nil)
        try UIVerification.require(publications == modalCalls, "Underlying copy crossed sheet boundary")
        let beganTick = pulse.ticks; try await wait("Sheet presentation turn") { pulse.ticks > beganTick }
        window.endSheet(sheet); sheet.orderOut(nil)
        let endedTick = pulse.ticks; try await wait("Sheet ended") { window.attachedSheet == nil && pulse.ticks > endedTick }
        checks.append("An actual attached sheet refuses both direct callbacks and enabled-state publication")

        guard let unsafe = browser.displayedEntries.first(where: { $0.name.contains("\n") })?.url else { throw UIVerification.Failure(message: "Generated control-line entry absent") }
        browser.reloadFileRows(preserving: [urls[0]]); browser.focusBrowserContent()
        browser.cutFileURLs(nil)
        try await wait("Actual generated Cut intent") { browser.cutPreparationTask == nil && browser.pendingCut != nil }
        let cutRevision = browser.clipboardRevision, cutCount = board.changeCount, cutPublications = publications
        browser.reloadFileRows(preserving: [unsafe]); browser.copyNames(nil)
        try UIVerification.require(publications == cutPublications && board.changeCount == cutCount
            && browser.clipboardRevision == cutRevision && browser.pendingCut != nil, "Invalid name clobbered native Cut or clipboard")
        checks.append("A real prepared Cut remains intact when a control-line filename fails complete validation before publication")

        _ = owner.workspace.splitActive(at: .trailing)
        guard let peer = owner.workspace.browsers.values.first(where: { $0 !== browser }) else { throw UIVerification.Failure(message: "Peer pane missing") }
        peer.permitsBackgroundVerification = true; peer.clipboardWriter = writer
        peer.navigate(to: .directory(root.appendingPathComponent("source"))); try await settled(peer)
        peer.reloadFileRows(preserving: [urls[1]])
        peer.copyRelativePaths(nil)
        try UIVerification.require(browser.pendingCut == nil && peer.pendingCut == nil && board.string(forType: .string) == names[1]
            && board.availableType(from: [.fileURL]) == nil, "Peer metadata Copy retained Cut authority or published file references")
        failPublication = true; peer.copyNames(nil); failPublication = false
        try UIVerification.require(peer.status.stringValue.contains("clipboard"), "Failed native text publication claimed success")
        checks.append("Peer-pane relative Copy replaces shared Cut with text-only data; actual writer failure reports failure")
        metrics["privatePublications"] = publications
        metrics["nativeNameComparison"] = "Unicode canonical equality; formatter separately proves received URI byte preservation"

        owner.suspendBrowsing(); await owner.flushSession(); window.close()
        let closed = publications
        browser.copyNames(nil); peer.copyRelativePaths(nil)
        try UIVerification.require(publications == closed && !browser.canCopyFilenameMetadata && !peer.canCopyFilenameMetadata, "Closed/suspended callback wrote stale filename text")
        checks.append("Closed/suspended original and peer callbacks refuse without reading or changing the system clipboard")
    }
    private static func settled(_ browser: BrowserViewController) async throws {
        try await wait("Native folder display") { !browser.isLoading && browser.orderingTask == nil }
    }
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let end = CACurrentMediaTime() + 12
        while !condition() { try UIVerification.require(CACurrentMediaTime() < end, message); try await Task.sleep(for: .milliseconds(10)) }
    }
}
#endif
