import AppKit
import ExplorerCore
import QuickLookUI

#if DEBUG
@MainActor
extension UIVerification {
    /// Only marked listing fixtures are passed by the normal verification
    /// harness. The rename prompt is cancelled; body previews are opt-in here.
    static func verifyFinderWorkflows(_ browser: BrowserViewController, fixture: URL, output: URL,
                                      interactive: Bool) async throws -> [String] {
        guard let window = browser.view.window else { throw Failure(message: "Finder workflow window is missing") }
        let originalProfile = browser.settings.keyboardProfile
        let originalPathBar = browser.settings.showsPathBar
        let originalPrompt = browser.operationNamePrompt
        let originalWriter = browser.clipboardWriter
        defer {
            browser.quickLook.endSession()
            browser.settings.keyboardProfile = originalProfile
            browser.settings.showsPathBar = originalPathBar
            browser.operationNamePrompt = originalPrompt
            browser.clipboardWriter = originalWriter
        }
        browser.navigate(to: .directory(fixture))
        try await settled(browser)
        browser.focusBrowserContent()
        guard let directoryRow = browser.displayedEntries.firstIndex(where: { $0.name == "Folder A" }) else {
            throw Failure(message: "Owned folder is missing")
        }
        browser.table.selectRowIndexes(IndexSet(integer: directoryRow), byExtendingSelection: false)
        var renamePrompts = 0
        browser.operationNamePrompt = { _, _ in renamePrompts += 1; return nil }
        browser.settings.keyboardProfile = .mac
        try await Task.sleep(for: .milliseconds(30))
        browser.table.keyDown(with: key("\r", code: 36, flags: [], window: window))
        try await waitUntil("Mac Return rename prompt") { renamePrompts == 1 }
        try await waitUntil("Cancelled rename preparation") { !browser.hasPendingFileOperation }
        try require(browser.location == .directory(fixture), "Mac Return opened instead of renaming")
        browser.table.selectRowIndexes(IndexSet(), byExtendingSelection: false)
        browser.table.keyDown(with: key("\r", code: 36, flags: [], window: window))
        try await Task.sleep(for: .milliseconds(30))
        try require(renamePrompts == 1, "Mac Return renamed an empty selection")
        browser.table.selectRowIndexes(IndexSet(integer: directoryRow), byExtendingSelection: false)
        browser.settings.keyboardProfile = .explorer
        try await Task.sleep(for: .milliseconds(30))
        browser.table.keyDown(with: key("\r", code: 36, flags: [], window: window))
        try await settled(browser)
        try require(browser.location == .directory(fixture.appendingPathComponent("Folder A", isDirectory: true)),
                    "Explorer Return no longer opens folders")
        browser.navigate(to: .directory(fixture.appendingPathComponent("Folder A/Child", isDirectory: true)))
        try await settled(browser)
        browser.settings.showsPathBar = true
        await Task.yield()
        browser.view.layoutSubtreeIfNeeded()
        let path = browser.pathControl
        try require(browser.addressLayout?.bottomSurface.isHidden == false && path.locations == browser.breadcrumbLocations,
                    "Bottom path bar did not expose the current folder ancestors")
        guard let cell = path.cell as? NSPathCell,
              let component = cell.pathComponentCells.last else { throw Failure(message: "Bottom path cells are missing") }
        let rect = cell.rect(of: component, withFrame: path.bounds, in: path)
        try require(!rect.isEmpty, "Current bottom path component is invisible")
        let point = path.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        var copied: String?
        browser.clipboardWriter = { text, _ in copied = text; return .text }
        guard let context = path.menu(for: event), let index = context.items.firstIndex(where: { $0.title == "Copy Path" }) else { throw Failure(message: "Path context menu is missing") }
        context.performActionForItem(at: index)
        try require(copied == browser.location.directoryURL?.path, "Bottom path Copy Path used file selection or the wrong ancestor")
        let pathItem = BrowserMenus.menu(.view, target: browser).items.first { $0.action == #selector(BrowserViewController.togglePathBar(_:)) }
        try require(pathItem?.keyEquivalent == "p" && pathItem?.keyEquivalentModifierMask == [.command, .option],
                    "Path bar keyboard/menu discovery is missing")
        try await snapshot(window, to: output.appendingPathComponent("finder-path-bar.png"))
        browser.navigate(to: .directory(fixture))
        try await settled(browser)
        let linked = browser.displayedEntries.filter { $0.kind == .symbolicLink }.map(\.url)
        let plain = fixture.appendingPathComponent("Résumé – नमस्ते – 日本語.txt")
        let reader = QuickLookSelectionReader()
        let eligible = try await reader.eligibleURLs([plain] + linked)
        try require(eligible == [plain], "Quick Look eligibility followed symbolic links or lost the selected owned file")
        browser.table.selectRowIndexes(IndexSet(browser.displayedEntries.indices.filter { browser.displayedEntries[$0].kind == .symbolicLink }),
                                           byExtendingSelection: false)
        try require(!browser.canQuickLook && browser.quickLookSelection.isEmpty,
                    "Symbolic links enabled Quick Look")
        let fileMenu = BrowserMenus.menu(.file, target: browser)
        try require(fileMenu.items.contains { $0.action == #selector(BrowserViewController.showQuickLook(_:)) && $0.keyEquivalent == "y" },
                    "Native Quick Look command is missing")
        try require(BrowserMenus.commandItem(#selector(BrowserViewController.moveCopiedFiles(_:)), in: fileMenu).map {
            $0.keyEquivalent == "v" && $0.keyEquivalentModifierMask == [.command, .option] } == true,
                    "Native Move Copied Items command is missing")
        var checks = ["Mac Return routes to cancelled guarded Rename; empty selection is inert; Explorer Return still opens folders",
                      "Optional native bottom path bar, clicked-component Copy Path and Option-Command-P discovery",
                      "Quick Look selected-file metadata eligibility excludes owned symbolic links; Command-Y and Move Copied Items menu wiring"]
        if interactive {
            browser.focusBrowserContent()
            guard let row = browser.rowsByURL[plain] else { throw Failure(message: "Owned Quick Look file is missing") }
            browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            browser.table.keyDown(with: key(" ", code: 49, flags: [], window: window))
            try await waitUntil("Native owned-fixture Quick Look panel") {
                QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
                    && (QLPreviewPanel.shared()?.currentController as AnyObject?) === browser.table
            }
            try require(browser.quickLook.previewURLs == [plain], "Native Quick Look received unselected items")
            if let panel = QLPreviewPanel.shared() {
                try await snapshot(panel, to: output.appendingPathComponent("finder-quick-look.png"))
                let beforeClose = browser.quickLook.cleanupState(of: panel)
                _ = browser.quickLook.previewPanel(panel, handle: key(" ", code: 49, flags: [], window: panel))
                let immediateClose = browser.quickLook.cleanupState(of: panel)
                do {
                    // QL's native orderOut can animate. Wait for the real native
                    // postcondition, while keeping the original source-nil check.
                    try await waitUntil("Quick Look dismisses and releases its source") {
                        !panel.isVisible && panel.dataSource == nil && panel.delegate == nil
                            && browser.quickLook.hasReleasedSession
                    }
                } catch {
                    let states: [String: Any] = ["before": beforeClose, "immediate": immediateClose,
                                                "settled": browser.quickLook.cleanupState(of: panel)]
                    try JSONSerialization.data(withJSONObject: states, options: [.prettyPrinted, .sortedKeys])
                        .write(to: output.appendingPathComponent("finder-quick-look-cleanup.json"), options: .atomic)
                    throw error
                }
                let states: [String: Any] = ["before": beforeClose, "immediate": immediateClose,
                                            "settled": browser.quickLook.cleanupState(of: panel)]
                try JSONSerialization.data(withJSONObject: states, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("finder-quick-look-cleanup.json"), options: .atomic)
                try require(browser.quickLook.hasReleasedSession, "Quick Look retained its app session after closing")
            }
            checks.append("Explicit Space opens native QLPreviewPanel for one generated fixture, with native responder ownership and cleanup")
        }
        return checks
    }
}
#endif
