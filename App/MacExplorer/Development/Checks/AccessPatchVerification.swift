#if DEBUG
import AppKit
import ExplorerCore
import FileOperations
import LocalStorage
import SwiftUI

/// One small generated-only patch packet. No personal folder scan, credentials,
/// device mutation, system privacy query or saved ordinary profile is admitted.
@MainActor enum AccessPatchVerification {
    private static var browserWindow: BrowserWindowController?
    private static var preferences: NSWindow?
    static func run() async {
        guard let text = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: text)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-patch-0.1.1"),
              UUID(uuidString: root.lastPathComponent) != nil, root.resolvingSymlinksInPath() == root,
              (try? String(contentsOf: root.appendingPathComponent("owned.txt"), encoding: .utf8)) == "Traverse generated access patch v1\n" else { exit(2) }
        do {
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
            settings.appearance = .dark; settings.glassFileContent = true
            try require(settings.motion.mode == .full && !settings.initialSetupCompleted, "First-run defaults")
            let old = try JSONSerialization.jsonObject(with: settings.encodedSnapshot()) as! [String: Any]
            var legacy = old; legacy.removeValue(forKey: "initialSetupCompleted")
            let restored = BrowserSettings(persist: false, restoredData: try JSONSerialization.data(withJSONObject: legacy))
            try require(!restored.initialSetupCompleted && restored.glassFileContent, "Additive settings compatibility")
            try await settings.completeInitialSetup()
            let completed = BrowserSettings(persist: false, restoredData: try settings.encodedSnapshot())
            try require(completed.initialSetupCompleted, "Setup round trip")
            let persistedFile = root.appendingPathComponent("settings/preferences.json")
            let persistent = BrowserSettings(persist: false, persistenceFile: persistedFile, skipDiskRead: true)
            try await persistent.completeInitialSetup()
            let persistedData = try await Task.detached { try Data(contentsOf: persistedFile) }.value
            try require(BrowserSettings(persist: false, restoredData: persistedData).initialSetupCompleted, "Setup completion was not actually saved")
            let failed = BrowserSettings(persist: false, persistenceFile: root.appendingPathComponent("Blocker/preferences.json"), skipDiskRead: true)
            do { try await failed.completeInitialSetup(); throw UIVerification.Failure(message: "Blocked setup write reported success") }
            catch is UIVerification.Failure { throw UIVerification.Failure(message: "Blocked setup write reported success") }
            catch { try require(!failed.initialSetupCompleted, "Failed setup write suppressed future setup") }
            let blocked = BrowserSettings(persist: false, restoredData: Data("invalid".utf8))
            do { try await blocked.completeInitialSetup(); throw UIVerification.Failure(message: "Incompatible preferences accepted") }
            catch FileOperationFailure.unavailable { }
            let controller = BrowserWindowController(settings: settings); browserWindow = controller
            let browser = controller.browser
            browser.permitsBackgroundVerification = true
            browser.readVolumesForVerification = { [.init(url: root.appendingPathComponent("Files"), name: "Generated Drive", kind: .externalDisk,
                totalBytes: 1_000_000, availableBytes: 700_000, isReadOnly: false)] }
            guard let window = controller.window else { throw UIVerification.Failure(message: "Missing browser") }
            window.title = "Traverse access patch · generated review"
            window.setContentSize(.init(width: 900, height: 540)); window.center()
            controller.showWindow(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            browser.navigate(to: .directory(root.appendingPathComponent("Files")))
            try await settled(browser)
            let before = browser.table.headerView
            var outgoingPixels = 0
            var motionFailures: [String] = []
            window.title = "Traverse access patch · generated review"
            let toComputer = try await NativeMotionRecorder.record(window: window, root: root, label: "to-this-mac") {
                browser.navigate(to: .computer)
                outgoingPixels = pixels(browser.canvasTransition?.image)
            }
            try JSONEncoder().encode(toComputer).write(to: root.appendingPathComponent("evidence/to-this-mac.json"), options: .withoutOverwriting)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                if outgoingPixels <= 10 { motionFailures.append("This Mac transition captured no outgoing folder content") }
            }
            try await settled(browser)
            window.title = "Traverse access patch · generated review"
            let fromComputer = try await NativeMotionRecorder.record(window: window, root: root, label: "from-this-mac") {
                browser.navigate(to: .directory(root.appendingPathComponent("Files")))
                outgoingPixels = pixels(browser.canvasTransition?.image)
            }
            try JSONEncoder().encode(fromComputer).write(to: root.appendingPathComponent("evidence/from-this-mac.json"), options: .withoutOverwriting)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                if outgoingPixels <= 10 { motionFailures.append("This Mac transition captured no outgoing drive content") }
            }
            try await settled(browser)
            try require(before === browser.table.headerView, "Navigation replaced the native column header")
            settings.motion.mode = .off
            browser.navigate(to: .computer)
            try require(browser.canvasTransition == nil, "Off mode created a navigation transition")
            try await settled(browser)
            settings.motion.mode = .full
            let access = browser.folderAccess
            try require(!access.hasSelectedAccess(to: root), "Unselected path claimed a grant")
            let chosen = await access.acceptChosenFolder(root.appendingPathComponent("Files"))
            try require(chosen != nil && access.hasSelectedAccess(to: root.appendingPathComponent("Files/Folder"))
                && !access.hasSelectedAccess(to: root), "Selected-access containment")
            for wrongSelection in [false, true] {
                let analysis = ApplicationStorageAnalysis()
                analysis.configurePicker(from: browser)
                analysis.requiresAnalysisSelectionForVerification = true
                var choices = 0, reads = 0
                var message = ""
                analysis.chooseFolderForVerification = { _, _ in choices += 1; return wrongSelection ? chosen : nil }
                analysis.analyzeProperties(owner: UUID(), root: root.appendingPathComponent("Unselected"), access: {
                    reads += 1; return FileAccessLifetimes(leases: [])
                }, onChange: { value, _ in message = value.message })
                for _ in 0..<100 {
                    if message.contains("did not start") { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try require(choices == 1 && reads == 0 && message.contains("did not start"), "Cancelled/unrelated folder selection started analysis")
                await analysis.stopAndDrain()
            }
            TraverseSetupController.shared.show(from: browser)
            guard let setup = TraverseSetupController.shared.window, let model = TraverseSetupController.shared.model else {
                throw UIVerification.Failure(message: "Missing setup")
            }
            setup.title = "Traverse setup · generated review"
            for page in 0...2 {
                model.page = page
                try await Task.sleep(for: .milliseconds(300))
                try require(setup.frame.width >= 630 && setup.frame.height >= 590, "Setup collapsed its optional access content")
                try await GlassVerification.captureOwnedWindow(setup, to: root.appendingPathComponent("evidence/setup-\(page).png"))
            }
            setup.close()
            let view = browser.makeSettingsView(initialPage: .appearance)
            let preferences = BrowserSettingsWindow.make(view); self.preferences = preferences
            preferences.title = "Traverse Keyboard · generated review"
            preferences.center(); preferences.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(350))
            guard let tabs = find(preferences.contentView?.superview, as: NSSegmentedControl.self).first(where: { $0.segmentCount == 6 }) else {
                throw UIVerification.Failure(message: "Missing Settings tabs")
            }
            let report = try await NativeMotionRecorder.record(window: preferences, root: root, label: "keyboard-entrance") {
                tabs.selectedSegment = 2; _ = tabs.sendAction(tabs.action, to: tabs.target)
            }
            try JSONEncoder().encode(report).write(to: root.appendingPathComponent("evidence/keyboard-entrance.json"), options: .withoutOverwriting)
            try await GlassVerification.captureOwnedWindow(preferences, to: root.appendingPathComponent("evidence/keyboard.png"))
            guard let query = find(preferences.contentView, as: NSTextField.self).first(where: { $0.identifier?.rawValue == "shortcut-action-search" }) else {
                throw UIVerification.Failure(message: "Missing live shortcut search editor")
            }
            try require(!query.drawsBackground && !query.isBezeled && preferences.makeFirstResponder(query), "Shortcut query retained an opaque bezel or lost focus")
            _ = query.scrollToVisible(NSRect(x: 0, y: -120, width: query.bounds.width, height: query.bounds.height + 240))
            query.stringValue = "Select All Files"
            query.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: query))
            try await Task.sleep(for: .milliseconds(150))
            try await GlassVerification.captureOwnedWindow(preferences, to: root.appendingPathComponent("evidence/keyboard-filter.png"))
            // SwiftUI retains offscreen representables in its lazy cache. Only
            // currently visible controls describe the displayed search result.
            let recorders = find(preferences.contentView, as: NSButton.self).filter {
                $0.title == "Record…" && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty && $0.window === preferences
            }.count
            try require(recorders == 1, "Shortcut typing retained \(recorders) recorders instead of one")
            preferences.close(); browser.suspendBrowser(); window.close()
            try require(motionFailures.isEmpty, motionFailures.joined(separator: "; "))
            try JSONSerialization.data(withJSONObject: ["passed": true, "generatedOnly": true,
                "recordings": 3, "settingsCompatibility": true, "nativeHeaderRetained": true,
                "cancelledAndUnrelatedGrantsRefused": true, "shortcutEditorFilters": true], options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
            NSApplication.shared.terminate(nil)
        } catch {
            let message = String(describing: error)
            try? JSONSerialization.data(withJSONObject: ["passed": false, "failure": message], options: [.prettyPrinted])
                .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
            preferences?.close(); browserWindow?.browser.suspendBrowser(); browserWindow?.window?.close()
            TraverseSetupController.shared.window?.close()
            fputs("Generated patch verification failed: \(message)\n", stderr)
            NSApplication.shared.terminate(nil)
        }
    }
    private static func settled(_ browser: BrowserViewController) async throws {
        for _ in 0..<200 {
            if !browser.isLoading && browser.orderingTask == nil && browser.canvasTransition == nil {
                browser.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(90)); return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw UIVerification.Failure(message: "Generated browser did not settle")
    }
    private static func pixels(_ image: NSImage?) -> Int {
        guard let bitmap = image?.representations.first as? NSBitmapImageRep else { return 0 }
        var count = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { count += 1 }
        }
        return count
    }
    private static func find<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
        guard let root else { return [] }
        return (root as? T).map { [$0] } ?? root.subviews.flatMap { find($0, as: type) }
    }
    private static func require(_ condition: Bool, _ message: String) throws { try UIVerification.require(condition, message) }
}
#endif
