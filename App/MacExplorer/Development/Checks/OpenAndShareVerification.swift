import AppKit
import Foundation

#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
private final class OpenShareThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var onMain = false
    func record() { lock.withLock { calls += 1; onMain = onMain || Thread.isMainThread } }
    var snapshot: (Int, Bool) { lock.withLock { (calls, onMain) } }
}

private final class OpenShareDiscoveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[OpenWithApplication], Never>?
    var isHeld: Bool { lock.withLock { continuation != nil } }
    func hold() async -> [OpenWithApplication] {
        await withCheckedContinuation { pending in lock.withLock { continuation = pending } }
    }
    func resume(_ apps: [OpenWithApplication]) {
        let pending = lock.withLock { let pending = continuation; continuation = nil; return pending }
        pending?.resume(returning: apps)
    }
}

/// Executes inside AppKit's actual tracking loop, where a direct delegate call
/// with background verification enabled cannot reproduce menu presentation.
@MainActor
private final class OpenShareMenuTrackingProbe: NSObject {
    let menu: NSMenu
    weak var browser: BrowserViewController?
    var samples: [[String: Any]] = []
    private var timer: Timer?

    init(menu: NSMenu, browser: BrowserViewController) { self.menu = menu; self.browser = browser }

    func run(at point: NSPoint, in view: NSView) {
        let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(sample), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        _ = menu.popUp(positioning: nil, at: point, in: view)
        timer.invalidate(); self.timer = nil
    }

    @objc private func sample() {
        guard let browser else { menu.cancelTrackingWithoutAnimation(); return }
        samples.append(["titles": menu.items.map(\.title),
            "browserKey": NSApplication.shared.keyWindow === browser.view.window,
            "textEditing": browser.view.window?.firstResponder is NSTextView,
            "selectedCount": browser.orderedSelectedURLs.count,
            "canOpen": browser.canOpenWithSelection])
        if samples.count >= 20 || menu.items.contains(where: { $0.title == "Other…" }) {
            menu.cancelTrackingWithoutAnimation()
        }
    }
}

@MainActor
private final class OpenShareTrackingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Tracks the persistent parent hierarchy and requests its child with one local
/// Right Arrow event. Physical hover transitions remain owner qualification.
@MainActor
private final class OpenShareParentMenuProbe: NSObject, NSMenuDelegate {
    let parent: NSMenu
    let item: NSMenuItem
    let child: NSMenu
    weak var browser: BrowserViewController?
    private weak var forwardedDelegate: (any NSMenuDelegate)?
    private var timer: Timer?
    private var postedNavigation = false
    private(set) var childWillOpen = false
    private(set) var samples: [[String: Any]] = []

    init(parent: NSMenu, item: NSMenuItem, child: NSMenu, browser: BrowserViewController) {
        self.parent = parent; self.item = item; self.child = child; self.browser = browser
        forwardedDelegate = child.delegate
    }

    func run() {
        child.delegate = self
        defer { child.delegate = forwardedDelegate }
        let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(sample), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        let cursor = NSEvent.mouseLocation
        // With nil view, positioning uses screen coordinates. The item's top
        // left sits 30pt left and 8pt above the untouched cursor, inside its row.
        _ = parent.popUp(positioning: item, at: NSPoint(x: cursor.x - 30, y: cursor.y + 8), in: nil)
        timer.invalidate(); self.timer = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) { forwardedDelegate?.menuNeedsUpdate?(menu) }
    func menuWillOpen(_ menu: NSMenu) {
        if menu === child { childWillOpen = true }
        forwardedDelegate?.menuWillOpen?(menu)
    }
    func menuDidClose(_ menu: NSMenu) { forwardedDelegate?.menuDidClose?(menu) }

    @objc private func sample() {
        samples.append(["parentHighlighted": parent.highlightedItem?.title ?? "",
            "openWithHighlighted": parent.highlightedItem === item,
            "openWithEnabled": item.isEnabled,
            "childWillOpen": childWillOpen,
            "childTitles": child.items.map(\.title),
            "browserKey": NSApplication.shared.keyWindow === browser?.view.window,
            "canOpen": browser?.canOpenWithSelection == true])
        if !postedNavigation, parent.highlightedItem === item, let window = browser?.view.window {
            postedNavigation = true
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}",
                isARepeat: false, keyCode: 124) {
                NSApplication.shared.postEvent(event, atStart: false)
            }
        }
        if samples.count >= 50 || (childWillOpen && child.items.contains { $0.title == "Other…" }) {
            parent.cancelTrackingWithoutAnimation()
        }
    }
}

@MainActor
extension UIVerification {
    /// All candidate apps, launches, chooser responses and service completion
    /// are injected. No external app, sharing picker or recipient is invoked.
    static func verifyOpenAndShareWorkflows(_ browser: BrowserViewController, fixture: URL,
                                           output: URL) async throws -> [String] {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let build = project.appendingPathComponent(".build", isDirectory: true).path + "/"
        try require(output.path.hasPrefix(build) && output.resolvingSymlinksInPath() == output,
                    "Open/share verification output is not an owned repository build root")
        let root = output.appendingPathComponent("open-share-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false,
                                         attributes: [.posixPermissions: 0o700])
        try Data("MacExplorer generated Open With/share fixture v1\n".utf8)
            .write(to: root.appendingPathComponent(".owned-fixture"), options: .withoutOverwriting)
        let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt")
        try Data("generated first".utf8).write(to: first, options: .withoutOverwriting)
        try Data("generated second".utf8).write(to: second, options: .withoutOverwriting)
        let appA = root.appendingPathComponent("Generated A.app", isDirectory: true)
        let appB = root.appendingPathComponent("Generated B.app", isDirectory: true)
        for (index, app) in [appA, appB].enumerated() {
            let contents = app.appendingPathComponent("Contents", isDirectory: true)
            try FileManager().createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: String] = ["CFBundleIdentifier": "com.macexplorer.generated.OpenShareFixture\(index)",
                "CFBundlePackageType": "APPL", "CFBundleName": "Generated Fixture \(index)",
                "CFBundleExecutable": "NeverLaunchedFixture"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"), options: .withoutOverwriting)
            let binaries = contents.appendingPathComponent("MacOS", isDirectory: true)
            try FileManager().createDirectory(at: binaries, withIntermediateDirectories: false)
            try Data("Generated nonexecutable fixture; never launch.\n".utf8)
                .write(to: binaries.appendingPathComponent("NeverLaunchedFixture"), options: .withoutOverwriting)
        }

        let coordinator = browser.openAndShare
        let originalHooks = coordinator.hooks
        let originalVerification = coordinator.permitsVerification
        let originalBackground = browser.permitsBackgroundVerification
        try require(!coordinator.verificationState.sharing && coordinator.verificationState.launches == 0,
                    "Open/share verification cannot replace an active external session")
        coordinator.permitsVerification = true
        browser.permitsBackgroundVerification = true
        defer {
            coordinator.windowWillClose()
            coordinator.hooks = originalHooks
            coordinator.permitsVerification = originalVerification
            browser.permitsBackgroundVerification = originalBackground
        }
        var launches: [([URL], URL)] = []
        var launchCompletion: (@MainActor @Sendable (Error?) -> Void)?
        var shareItems: [URL] = []
        var shareCompletion: (@MainActor @Sendable (Error?) -> Void)?
        let probe = OpenShareThreadProbe()
        let reader = coordinator.reader
        coordinator.hooks = BrowserOpenShareHooks(
            discover: { urls in
                try await reader.applications(for: urls, candidates: { url in
                    probe.record()
                    return url == first ? [appA, appB] : [appB]
                })
            },
            chooseApplication: { _ in nil },
            launch: { urls, app, completion in launches.append((urls, app)); launchCompletion = completion },
            share: { urls, completion in shareItems = urls; shareCompletion = completion })

        browser.navigate(to: .directory(root))
        try await settled(browser)
        func select(_ urls: [URL]) {
            browser.table.selectRowIndexes(IndexSet(urls.compactMap { browser.rowsByURL[$0] }), byExtendingSelection: false)
        }
        try await verifyShareSupersedesInFlightDiscovery(browser, selected: first, application: appB)
        select([first, second])
        coordinator.selectionDidChange()
        let menu = coordinator.makeOpenWithMenu()
        coordinator.prepareOpenWithForVerification(menu)
        // Repeated status notifications with the same context must not cancel
        // the submenu's own discovery or disable its parent command.
        coordinator.selectionDidChange(); coordinator.selectionDidChange()
        try require(browser.canOpenWithSelection, "Discovery disabled its own Open With command")
        try await waitUntil("Bounded common application discovery") { !coordinator.verificationState.preparing && menu.items.contains { $0.title == "Other…" } }
        try require(menu.items.filter { $0.action != nil && $0.title != "Other…" }.count == 1,
                    "Open With did not intersect the whole captured selection")
        try require(probe.snapshot.0 == 2 && !probe.snapshot.1, "Application discovery ran on the main thread or lost an item")
        guard let appIndex = menu.items.firstIndex(where: { $0.action != nil && $0.title != "Other…" }) else {
            throw Failure(message: "Common generated application is missing")
        }
        coordinator.menuDidClose(menu)
        menu.performActionForItem(at: appIndex)
        try await waitUntil("Injected one-time application handoff") { launches.count == 1 }
        try await waitUntil("Closed Open With menu releases its choices") {
            !menu.items.contains { $0.representedObject != nil }
        }
        try require(launches[0].0 == [first, second] && launches[0].1 == appB,
                    "Open With handed off an unselected item or wrong application")
        try require(coordinator.verificationState.launches == 1, "Opening access was released before completion")
        launchCompletion?(nil); launchCompletion = nil
        try await waitUntil("Injected opening completion") { coordinator.verificationState.launches == 0 }
        try requireControlledWindowsHidden("injected Open With handoff")

        var menuTrackingExercised = false
        var menuOriginHandoffExercised = false
        if !originalBackground && NSApplication.shared.isActive, let window = browser.view.window {
            browser.permitsBackgroundVerification = false
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(browser.table)
            select([])
            let context = BrowserMenus.fileContextMenu(target: browser)
            guard let trackingMenu = context.items.first(where: { $0.title == "Open With" })?.submenu else {
                throw Failure(message: "Context Open With submenu is missing")
            }
            coordinator.menuNeedsUpdate(trackingMenu)
            try require(trackingMenu.items.first?.title == "Select up to 64 accessible files or folders",
                        "Empty-selection Open With did not expose its unavailable state")
            select([first])
            let probe = OpenShareMenuTrackingProbe(menu: trackingMenu, browser: browser)
            let row = try requireIndex(browser.rowsByURL[first])
            browser.table.scrollRowToVisible(row)
            probe.run(at: browser.table.rect(ofRow: row).origin, in: browser.table)
            try JSONSerialization.data(withJSONObject: ["samples": probe.samples], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("open-with-native-tracking.json"), options: .atomic)
            try require(probe.samples.contains { ($0["titles"] as? [String])?.contains("Other…") == true },
                        "Native Open With tracking never displayed application choices")
            try await waitUntil("Native dismissed submenu releases its choices") {
                !trackingMenu.items.contains { $0.representedObject != nil }
            }
            select([])
            browser.focusLocation(nil)
            guard let persistentContext = browser.table.menu,
                  let persistentChild = persistentContext.items.first(where: { $0.title == "Open With" })?.submenu else {
                throw Failure(message: "Persistent context Open With hierarchy is missing")
            }
            coordinator.menuNeedsUpdate(persistentChild)
            let rowPoint = browser.table.convert(NSPoint(x: 80, y: browser.table.rect(ofRow: row).midY), to: nil)
            guard let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: rowPoint,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                throw Failure(message: "Generated native context event is unavailable")
            }
            do {
                let alternate = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                         styleMask: [.titled], backing: .buffered, defer: false)
                alternate.title = "Generated background context verification"
                defer { alternate.orderOut(nil); window.makeKeyAndOrderFront(nil) }
                alternate.makeKeyAndOrderFront(nil)
                try require(NSApplication.shared.keyWindow === alternate, "Owned background-context window did not become key")
                _ = browser.table.menu(for: rightClick)
                let focused = NSApplication.shared.keyWindow === window
                try JSONSerialization.data(withJSONObject: ["browserKeyAfterContext": focused,
                    "canOpenAfterContext": browser.canOpenWithSelection,
                    "textEditingAfterContext": window.firstResponder is NSTextView,
                    "selectedCountAfterContext": browser.orderedSelectedURLs.count,
                    "backgroundBypass": browser.permitsBackgroundVerification], options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("open-with-background-context.json"), options: .atomic)
                try require(focused && browser.canOpenWithSelection,
                            "Explicit context request in the background browser did not acquire file-command focus")
            }
            guard let hoverContext = browser.table.menu(for: rightClick), hoverContext === persistentContext else {
                throw Failure(message: "Native context preparation did not retain the table's existing menu")
            }
            guard let hoverItem = hoverContext.items.first(where: { $0.title == "Open With" }),
                  let hoverChild = hoverItem.submenu else {
                throw Failure(message: "Parent Open With hierarchy is missing")
            }
            let hover = OpenShareParentMenuProbe(parent: hoverContext, item: hoverItem, child: hoverChild, browser: browser)
            hover.run()
            try JSONSerialization.data(withJSONObject: ["samples": hover.samples,
                "physicalCursorMovement": false, "parentActionChosen": false,
                "localMenuMouseMove": false, "localRightArrow": true,
                "persistentTableContext": true], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("open-with-parent-navigation.json"), options: .atomic)
            try require(hover.samples.contains { $0["openWithHighlighted"] as? Bool == true },
                        "Native parent navigation did not highlight Open With")
            try require(hover.childWillOpen && hover.samples.contains {
                ($0["childTitles"] as? [String])?.contains("Other…") == true
            }, "Native parent navigation never opened its populated child submenu")
            try await waitUntil("Native parent submenu releases its choices") {
                !hoverChild.items.contains { $0.representedObject != nil }
            }
            do {
                let panel = OpenShareTrackingPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                defer { panel.orderOut(nil); window.makeKeyAndOrderFront(nil) }
                panel.makeKeyAndOrderFront(nil)
                try require(NSApplication.shared.keyWindow === panel && NSApplication.shared.mainWindow === window,
                            "Owned menu-focus panel did not preserve the originating main browser")
                coordinator.menuWillOpen(hoverChild)
                try await waitUntil("Menu-origin discovery survives temporary native key-window transfer") {
                    hoverChild.items.contains { $0.title == "Other…" }
                }
                try require(browser.canOpenWithSelection && NSApplication.shared.keyWindow === panel,
                            "Origin-bound discovery depended on global key-window focus")
                coordinator.menuDidClose(hoverChild)
                try await waitUntil("Closed menu origin releases discovery and choices") {
                    !hoverChild.items.contains { $0.representedObject != nil } && !browser.canOpenWithSelection
                }
                coordinator.menuWillOpen(hoverChild)
                try await waitUntil("Origin-bound accepted application choice preparation") {
                    hoverChild.items.contains { $0.title == "Other…" }
                }
                let index = try requireIndex(hoverChild.items.firstIndex { $0.action != nil && $0.title != "Other…" })
                coordinator.menuDidClose(hoverChild)
                hoverChild.performActionForItem(at: index)
                try await waitUntil("Accepted origin-bound action survives menu close") { launches.count == 2 }
                try require(launches.last?.0 == [first] && launches.last?.1 == appA,
                            "Origin-bound action handed off another item/application")
                launchCompletion?(nil); launchCompletion = nil
                try await waitUntil("Origin-bound handoff releases its access") { coordinator.verificationState.launches == 0 }
                launches.removeLast()
                menuOriginHandoffExercised = true
            }
            browser.permitsBackgroundVerification = true
            select([first, second])
            menuTrackingExercised = true
        }

        guard let selectedAnchor = coordinator.sharingAnchor(for: [first, second]) else {
            throw Failure(message: "Selected Share anchor is missing")
        }
        try require(!selectedAnchor.isEmpty && selectedAnchor.intersects(browser.table.visibleRect)
            && selectedAnchor.intersects(browser.table.rect(ofRow: try requireIndex(browser.rowsByURL[first]))),
                    "Share anchor is not beside a visible captured selection")
        try require(coordinator.sharingAnchor(for: []) == nil
            && coordinator.sharingAnchor(for: [root.appendingPathComponent("not-a-listed-item")]) == nil,
                    "Share manufactured an anchor for an unavailable selection")
        do {
            let table = browser.table
            let name = table.tableColumns[try requireIndex(table.tableColumns.firstIndex {
                $0.identifier.rawValue == BrowserColumn.name.rawValue
            })]
            let width = name.width, sizing = table.columnAutoresizingStyle, origin = table.visibleRect.origin
            defer {
                name.width = width; table.columnAutoresizingStyle = sizing
                browser.folderScroll.contentView.scroll(to: origin)
                browser.folderScroll.reflectScrolledClipView(browser.folderScroll.contentView)
            }
            table.columnAutoresizingStyle = .noColumnAutoresizing
            name.width = table.visibleRect.width + 600
            table.layoutSubtreeIfNeeded()
            browser.folderScroll.contentView.scroll(to: NSPoint(x: 300, y: origin.y))
            browser.folderScroll.reflectScrolledClipView(browser.folderScroll.contentView)
            try require(table.visibleRect.minX >= 250, "Owned horizontal Share-anchor fixture did not scroll")
            guard let anchor = coordinator.sharingAnchor(for: [first]) else {
                throw Failure(message: "Horizontally hidden filename suppressed Share")
            }
            try require(anchor.intersects(table.visibleRect) && table.visibleRect.minX < 150,
                        "Share did not bring the selected filename back into view")
        }

        var focusReturnExercised = false
        if !originalBackground && NSApplication.shared.isActive, let browserWindow = browser.view.window {
            let alternate = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                     styleMask: [.titled], backing: .buffered, defer: false)
            alternate.title = "Generated focus-loss verification"
            let discover = coordinator.hooks.discover
            let gate = OpenShareDiscoveryGate()
            defer {
                gate.resume([])
                coordinator.hooks.discover = discover
                browser.permitsBackgroundVerification = true
                alternate.orderOut(nil)
                browserWindow.makeKeyAndOrderFront(nil)
            }
            browser.permitsBackgroundVerification = false
            browserWindow.makeKeyAndOrderFront(nil)
            coordinator.hooks.discover = { _ in await gate.hold() }
            coordinator.prepareOpenWithForVerification(menu)
            try await waitUntil("Held discovery before native focus loss") { gate.isHeld }
            alternate.makeKeyAndOrderFront(nil)
            try require(NSApplication.shared.keyWindow === alternate, "Owned focus fixture did not become key")
            gate.resume([OpenWithApplication(url: appB, title: "Generated B")])
            try await waitUntil("Focus-stale discovery clears its preparation") { !coordinator.verificationState.preparing }
            try require(!menu.items.contains { $0.title == "Other…" }, "Focus-stale discovery published an application choice")
            coordinator.hooks.discover = discover
            browserWindow.makeKeyAndOrderFront(nil)
            coordinator.prepareOpenWithForVerification(menu)
            try await waitUntil("Same selection prepares after focus returns") {
                !coordinator.verificationState.preparing && menu.items.contains { $0.title == "Other…" }
            }
            // Admission occurs while the browser is key; the owned alternate
            // takes focus before the async shallow observation can resume.
            coordinator.shareSelection()
            try require(coordinator.verificationState.preparing, "Focus-loss share was not admitted for preparation")
            alternate.makeKeyAndOrderFront(nil)
            try await waitUntil("Focus-stale Share clears its preparation") { !coordinator.verificationState.preparing }
            try require(!coordinator.verificationState.sharing && shareCompletion == nil,
                        "Focus-stale Share dispatched an injected service")
            browserWindow.makeKeyAndOrderFront(nil)
            try require(coordinator.canShare, "The unchanged selection cannot share after focus returns")
            focusReturnExercised = true
        }

        try require(browser.canOpenWithSelection,
                    "Other chooser lost selection/content focus (count=\(browser.orderedSelectedURLs.count), editor=\(browser.view.window?.firstResponder is NSTextView))")
        coordinator.prepareOpenWithForVerification(menu)
        try await waitUntil("Other application chooser preparation") { !coordinator.verificationState.preparing && menu.items.contains { $0.title == "Other…" } }
        let otherIndex = try requireIndex(menu.items.firstIndex { $0.title == "Other…" })
        menu.performActionForItem(at: otherIndex)
        try await waitUntil("Cancelled application chooser") { !coordinator.verificationState.preparing }
        try require(launches.count == 1, "Cancelling Other opened an application")

        coordinator.hooks.chooseApplication = { _ in root.appendingPathComponent("Missing.app") }
        coordinator.prepareOpenWithForVerification(menu)
        try await waitUntil("Missing application chooser preparation") { !coordinator.verificationState.preparing && menu.items.contains { $0.title == "Other…" } }
        menu.performActionForItem(at: try requireIndex(menu.items.firstIndex { $0.title == "Other…" }))
        try await waitUntil("Missing chosen application refused") { !coordinator.verificationState.preparing && browser.status.stringValue.contains("application is unavailable") }
        try require(launches.count == 1, "Missing application reached the launch handoff")

        var chooseContinuation: CheckedContinuation<URL?, Never>?
        coordinator.hooks.chooseApplication = { _ in await withCheckedContinuation { chooseContinuation = $0 } }
        coordinator.prepareOpenWithForVerification(menu)
        try await waitUntil("Stale chooser preparation") { !coordinator.verificationState.preparing && menu.items.contains { $0.title == "Other…" } }
        menu.performActionForItem(at: try requireIndex(menu.items.firstIndex { $0.title == "Other…" }))
        try await waitUntil("Held generated chooser") { chooseContinuation != nil }
        select([])
        chooseContinuation?.resume(returning: appB); chooseContinuation = nil
        try await Task.sleep(for: .milliseconds(30))
        try require(launches.count == 1, "A stale selection launched the delayed Other choice")
        coordinator.hooks.chooseApplication = { _ in nil }

        select([first, second])
        coordinator.prepareOpenWithForVerification(menu)
        try await waitUntil("Changed-item opening preparation") { !coordinator.verificationState.preparing && menu.items.contains { $0.title == "Other…" } }
        try Data("generated first changed size before handoff".utf8).write(to: first)
        menu.performActionForItem(at: try requireIndex(menu.items.firstIndex { $0.action != nil && $0.title != "Other…" }))
        try await Task.sleep(for: .milliseconds(60))
        try require(launches.count == 1, "Opening handed off an item changed after discovery")

        // Settle the generated fixture refresh before taking a new share snapshot.
        browser.navigate(to: .directory(root))
        try await settled(browser)
        select([first, second])
        coordinator.shareSelection()
        try await waitUntil("Injected explicit share session") { coordinator.verificationState.sharing }
        try require(shareItems == [first, second] && coordinator.verificationState.shareAccessRetained,
                    "Share lost its captured selection or access lifetime")
        select([])
        coordinator.windowWillClose()
        try require(coordinator.verificationState.sharing && coordinator.verificationState.shareAccessRetained,
                    "Chosen share service released access on selection/window change")
        shareCompletion?(nil); shareCompletion = nil
        try await waitUntil("Injected terminal service callback releases access") { !coordinator.verificationState.sharing && !coordinator.verificationState.shareAccessRetained }

        select([first])
        coordinator.shareSelection()
        try await waitUntil("Injected cancellation session") { shareCompletion != nil }
        shareCompletion?(CocoaError(.userCancelled)); shareCompletion = nil
        try await waitUntil("Injected sharing cancellation") { !coordinator.verificationState.sharing }
        try require(browser.status.stringValue == "Sharing cancelled.", "Sharing cancellation was reported as a successful send")
        browser.navigate(to: .directory(fixture))
        try await settled(browser)
        let checks = [
            "Off-main bounded common-handler intersection for captured generated URLs; no real app discovery or launch",
            "Injected one-time Open With handoff survives closed-menu scope cleanup; cancelled Other chooser, stale selection and changed-file refusal",
            "Injected explicit share captures only selected generated URLs and retains access through terminal completion",
            "Chosen share survives selection/window cleanup; cancellation is honest; no native picker, recipient or actual send",
            "Share anchor uses the visible selected name cell in table coordinates; empty/stale selection has no anchor",
            "Explicit Share supersedes held Open With discovery; late choices cannot replace the captured share and duplicate requests stay bounded"
        ] + [focusReturnExercised
            ? "Owned native window focus loss clears stale discovery/Share preparation; the unchanged selection works after focus returns"
            : "Native focus-loss/return regression not exercised: foreground active-app qualification is required"]
            + [menuTrackingExercised
                ? "Actual native Open With tracking and parent Right Arrow open bounded injected choices; background context obtains originating-window focus"
                : "Native menu tracking not exercised: foreground active-app qualification is required"]
            + [menuOriginHandoffExercised
                ? "Non-main native key-window transfer preserves origin-bound discovery and accepted action; dismissal releases scope"
                : "Native menu-origin action regression not exercised: foreground active-app qualification is required"]
        try JSONSerialization.data(withJSONObject: ["checks": checks, "externalLaunchExercised": false,
            "nativeMenuOriginHandoffExercised": menuOriginHandoffExercised,
            "nativeMenuTrackingExercised": menuTrackingExercised,
            "nativeFocusReturnExercised": focusReturnExercised,
            "nativeSharePickerExercised": false, "actualSharingExercised": false, "airDropExercised": false],
            options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("open-share-verification.json"), options: .atomic)
        return checks
    }

    /// Drive the actual enabled context-menu Share action while discovery is
    /// deliberately suspended. No native picker, recipient or service send occurs.
    private static func verifyShareSupersedesInFlightDiscovery(_ browser: BrowserViewController,
        selected: URL, application: URL) async throws {
        let coordinator = browser.openAndShare
        let originalHooks = coordinator.hooks
        let gate = OpenShareDiscoveryGate()
        var shared: [[URL]] = []
        var completion: (@MainActor @Sendable (Error?) -> Void)?
        coordinator.hooks.discover = { _ in await gate.hold() }
        coordinator.hooks.share = { urls, finish in shared.append(urls); completion = finish }
        defer {
            gate.resume([])
            completion?(CocoaError(.userCancelled))
            coordinator.windowWillClose()
            coordinator.hooks = originalHooks
        }
        browser.setFileSelection([selected])
        browser.fileSelectionDidChange()
        browser.focusBrowserContent()
        let context = BrowserMenus.fileContextMenu(target: browser)
        let copyIndex = context.items.firstIndex { $0.action == #selector(BrowserViewController.copyFileURLs(_:)) }
        let pathIndex = context.items.firstIndex { $0.action == #selector(BrowserViewController.copyPath(_:)) }
        try require(copyIndex != nil && pathIndex == copyIndex.map { $0 + 1 },
            "Copy Path must remain directly below Copy in the selected-item menu")
        guard let shareIndex = context.items.firstIndex(where: { $0.action == #selector(BrowserViewController.shareSelection(_:)) }),
              context.items[shareIndex].isEnabled else {
            throw Failure(message: "Generated context Share command was not enabled before Open With discovery")
        }
        let menu = coordinator.makeOpenWithMenu()
        coordinator.prepareOpenWithForVerification(menu)
        try await waitUntil("Held Open With discovery before explicit Share") { gate.isHeld && coordinator.verificationState.preparing }
        let shareEligibleDuringDiscovery = coordinator.canShare
        context.performActionForItem(at: shareIndex)
        let duplicateBlockedDuringPreparation = !coordinator.canShare
        coordinator.shareSelection()
        coordinator.menuDidClose(menu)
        let preparationSurvivedOldMenuClose = coordinator.verificationState.preparing
        // An existing rejection is deterministic immediately from its guard;
        // an admitted request gets time to complete real off-main observations.
        if shareEligibleDuringDiscovery {
            try await waitUntil("Explicit Share supersedes held discovery") { shared.count == 1 && coordinator.verificationState.sharing }
        }
        try require(shareEligibleDuringDiscovery && shared.count == 1 && coordinator.verificationState.sharing,
            "Enabled Share action was silently rejected while unrelated Open With discovery was in flight")
        try require(duplicateBlockedDuringPreparation,
            "A second Share request was eligible while the captured Share was preparing")
        try require(preparationSurvivedOldMenuClose,
            "Closing the superseded Open With menu cancelled accepted Share preparation")
        try require(shared == [[selected]] && coordinator.verificationState.shareAccessRetained,
            "Superseding Share lost its captured generated selection or access")
        coordinator.shareSelection()
        try require(shared.count == 1 && !coordinator.canShare, "Repeated Share created a duplicate active session")
        gate.resume([OpenWithApplication(url: application, title: "Late generated application")])
        try await Task.sleep(for: .milliseconds(60))
        try require(menu.items.allSatisfy { $0.representedObject == nil }
            && shared.count == 1 && coordinator.verificationState.sharing,
            "Cancelled Open With discovery published stale choices or replaced the explicit Share")
        completion?(CocoaError(.userCancelled)); completion = nil
        try await waitUntil("Superseding fixture Share releases access") {
            !coordinator.verificationState.sharing && !coordinator.verificationState.shareAccessRetained
        }
    }

    private static func requireIndex(_ index: Int?) throws -> Int {
        guard let index else { throw Failure(message: "Generated menu action is missing") }; return index
    }
}
#endif
