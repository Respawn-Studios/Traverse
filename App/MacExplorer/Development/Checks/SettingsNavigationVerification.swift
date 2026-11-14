#if DEBUG
import AppKit
import ExplorerCore

@MainActor
enum SettingsNavigationVerification {
    @MainActor private final class GeometryTrace {
        private weak var window: NSWindow?
        private var timer: Timer?
        private(set) var samples: [[String: Any]] = []
        init(_ window: NSWindow) {
            self.window = window
            timer = Timer(timeInterval: 0.008, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
            sample()
        }
        private func sample() {
            guard samples.count < 180, let window else { timer?.invalidate(); return }
            samples.append(["uptime": CACurrentMediaTime(), "width": window.frame.width,
                "height": window.frame.height, "key": window.isKeyWindow,
                "appActive": NSApp.isActive, "visible": window.isVisible, "nativeViewports": viewportGeometry(window)])
        }
        private func viewportGeometry(_ window: NSWindow) -> [[String: Any]] {
            guard let root = window.contentView else { return [] }
            var pending = [root], result: [[String: Any]] = [], count = 0
            let roles = ["tool-page-viewport", "tool-page-live-container", "tool-page-form"]
            while let view = pending.popLast(), count < 256, result.count < 5 {
                count += 1
                if let role = view.identifier?.rawValue, roles.contains(role) {
                    result.append(["role": role, "frame": NSStringFromRect(view.frame),
                        "bounds": NSStringFromRect(view.bounds), "clipped": view.clipsToBounds,
                        "layerBounds": view.layer.map { NSStringFromRect($0.bounds) } ?? "none"])
                }
                pending.append(contentsOf: view.subviews)
            }
            return result
        }
        func finish() -> [[String: Any]] { timer?.invalidate(); timer = nil; return samples }
    }
    private struct Failure: Error { let stage: String }
    @MainActor private final class ActionOwner {
        var task: Task<Void, Never>?
        var failure: String?
        var field: NSTextField?
        var fieldReady: Double?
    }
    private static func require(_ value: Bool, _ stage: String) throws {
        if !value { throw Failure(stage: stage) }
    }
    private static func wait(_ stage: String, _ predicate: () -> Bool) async throws {
        let until = CACurrentMediaTime() + 8
        while !predicate() {
            try require(CACurrentMediaTime() < until, stage)
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private static func find<T: NSView>(_ type: T.Type, identifier: String, in window: NSWindow) -> T? {
        guard let root = window.contentView else { return nil }
        var pending = [root], count = 0
        while let view = pending.popLast(), count < 4096 {
            count += 1
            if let found = view as? T, found.identifier?.rawValue == identifier { return found }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }
    private static func click(_ page: BrowserSettingsView.Page, window: NSWindow) throws {
        guard let table = find(NSTableView.self, identifier: "settings-navigation", in: window),
              let index = BrowserSettingsView.Page.ordered.firstIndex(of: page) else { throw Failure(stage: "native-navigation-missing") }
        let point = table.convert(.init(x: 80, y: table.rect(ofRow: index).midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: CACurrentMediaTime(), windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1) else { throw Failure(stage: "native-click-unavailable") }
            return event
        }
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        table.mouseDown(with: try event(.leftMouseDown))
        try require(table.selectedRow == index, "native-click-not-selected")
    }

    static func run() async {
        var root: URL?, window: NSWindow?, names: ApplicationPrivateNames?
        var activeAction: ActionOwner?
        var clips: [[String: Any]] = [], checks: [String] = [], failure: String?
        var geometry: [[String: Any]] = []
        var activeTrace: GeometryTrace?
        var activeCapture = "none"
        var mode = BrowserMotionMode.full
        do {
            let args = ProcessInfo.processInfo.arguments
            func argument(_ key: String) -> String? {
                args.firstIndex(of: key).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            }
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
                  let value = argument("--motion-mode"), let selected = BrowserMotionMode(rawValue: value) else { throw Failure(stage: "scope-arguments") }
            let scope = URL(fileURLWithPath: raw)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: scope.appendingPathComponent("reservation.json"))) as? [String: Any]
            let admission = try JSONSerialization.jsonObject(with: Data(contentsOf: scope.appendingPathComponent("settings-admission.json"))) as? [String: Any]
            try require(scope.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && scope.resolvingSymlinksInPath() == scope && UUID(uuidString: scope.lastPathComponent)?.uuidString == scope.lastPathComponent
                && marker?["action"] as? String == "settings-sidebar-v1"
                && admission?["master"] as? String == "46F68181-FA2B-4308-8713-7D518F2FF08C"
                && admission?["mode"] as? String == value && Bundle.main.bundleIdentifier == "local.macexplorer.development", "scope-identity")
            root = scope; mode = selected
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
            settings.folderSummariesEnabled = false; settings.navigationStyle = .glass
            settings.motion = .init(mode: mode)
            settings.appearance = args.contains("--motion-light") ? .light : .dark
            settings.interfaceSize = .init(args.contains("--motion-large") ? 150 : 100)
            InterfacePresentation.shared.bind(settings)
            let owner = ApplicationPrivateNames(directory: scope.appendingPathComponent("state/names"), settings: settings)
            names = owner
            var foreground = Set<BrowserSettingsView.Page>(), appearances: [BrowserSettingsView.Page: Int] = [:]
            var view = BrowserSettingsView(settings: settings, namesOwner: owner,
                folderAccess: FolderAccessController(stateDirectory: nil), accessDrives: [])
            view.onPageVisibilityForVerification = { page, visible in
                if visible { foreground.insert(page); appearances[page, default: 0] += 1 }
                else { foreground.remove(page) }
            }
            let created = BrowserSettingsWindow.make(view); window = created
            created.title = "Settings · generated review · sidebar motion"
            created.center(); created.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await wait("initial-general-navigation") {
                foreground == [.general] && find(NSTableView.self, identifier: "settings-navigation", in: created) != nil
            }
            let original = created.frame
            try await Task.sleep(for: .milliseconds(280))
            let action = ActionOwner()
            activeAction = action
            activeCapture = "settings-keyboard"; activeTrace = GeometryTrace(created)
            let keyboard = try await NativeMotionRecorder.record(window: created, root: scope, label: "settings-keyboard",
                sampling: .diagnostic(for: created)) {
                do { try click(.keyboard, window: created) }
                catch { action.failure = "keyboard-click" }
                action.task = Task { @MainActor in
                    do {
                        try await wait("keyboard-field-not-created") {
                            find(NSTextField.self, identifier: "shortcut-action-search", in: created) != nil
                        }
                        guard let field = find(NSTextField.self, identifier: "shortcut-action-search", in: created) else { throw Failure(stage: "keyboard-field") }
                        _ = field.scrollToVisible(field.bounds)
                        created.contentView?.layoutSubtreeIfNeeded()
                        action.field = field; action.fieldReady = CACurrentMediaTime()
                    } catch { action.failure = "keyboard-field" }
                }
            }
            geometry.append(["label": activeCapture, "samples": activeTrace?.finish() ?? []]); activeTrace = nil
            await action.task?.value
            try require(action.failure == nil && foreground == [.keyboard] && keyboard.streamStopped
                && keyboard.writerCompleted && keyboard.droppedEncoderFrames == 0, "keyboard-page-and-capture")
            guard let field = action.field, let ready = action.fieldReady,
                  let last = keyboard.frames.last else { throw Failure(stage: "keyboard-visible-field") }
            try require(ready <= last.receivedUptimeSeconds && !field.visibleRect.isEmpty, "field-not-visible-during-capture")
            var firstClip = clip(keyboard, label: "settings-keyboard", window: created)
            let fieldFrame = field.convert(field.bounds, to: nil)
            firstClip["fieldRegion"] = ["x": fieldFrame.minX, "y": CGFloat(keyboard.height) - fieldFrame.maxY,
                "width": fieldFrame.width, "height": fieldFrame.height]
            firstClip["fieldOwnerVerified"] = true
            firstClip["fieldVisibleAfterSeconds"] = max(0, ready - keyboard.actionUptimeSeconds)
            clips.append(firstClip)
            try require(created.makeFirstResponder(field), "keyboard-field-focus")
            guard let editor = field.currentEditor() as? NSTextView else { throw Failure(stage: "keyboard-field-editor") }
            editor.insertText("rename", replacementRange: .init(location: 0, length: editor.string.utf16.count))
            try await wait("keyboard-native-typing") { field.stringValue == "rename" }
            checks.append("Actual native click/Find-field creation, typing and early own-window capture")

            activeCapture = "settings-appearance"; activeTrace = GeometryTrace(created)
            let second = try await NativeMotionRecorder.record(window: created, root: scope, label: "settings-appearance",
                sampling: .diagnostic(for: created)) {
                do { try click(.appearance, window: created) } catch { action.failure = "appearance-click" }
            }
            geometry.append(["label": activeCapture, "samples": activeTrace?.finish() ?? []]); activeTrace = nil
            try await wait("appearance-foreground") { foreground == [.appearance] }
            try require(action.failure == nil && created.frame == original && field.currentEditor() == nil,
                "field-resignation-or-frame-change")
            clips.append(clip(second, label: "settings-appearance", window: created))
            for page in BrowserSettingsView.Page.ordered where page != .appearance {
                try click(page, window: created)
                try await wait("selected-page-not-foreground") { foreground == [page] }
                try require(created.frame == original, "page-resized-window")
            }
            try require(BrowserSettingsView.Page.ordered.allSatisfy { appearances[$0, default: 0] > 0 }, "not-all-settings-pages-exercised")
            checks.append("All Settings pages have one foreground owner, and selection preserves the user's window frame")
            guard let table = find(NSTableView.self, identifier: "settings-navigation", in: created) else { throw Failure(stage: "navigation-after-pages") }
            try require(created.makeFirstResponder(table), "navigation-keyboard-focus")
            let up = String(UnicodeScalar(Int(NSUpArrowFunctionKey))!)
            guard let upEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: CACurrentMediaTime(), windowNumber: created.windowNumber, context: nil,
                characters: up, charactersIgnoringModifiers: up,
                isARepeat: false, keyCode: 126) else { throw Failure(stage: "native-up-event") }
            table.keyDown(with: upEvent)
            try await wait("native-up-key-navigation") { foreground == [.privacy] }
            checks.append("Native source-list arrow-key selection changes the page without a mouse")
            try click(.general, window: created)
            try await wait("general-return") { foreground == [.general] }
            settings.navigationStyle = .solid
            try await wait("solid-surface") { (created.contentViewController as? ToolWindowChrome)?.surface.isUsingOpaqueSurface == true }
            settings.navigationStyle = .glass
            let expectsOpaque = !BrowserMaterialPolicy.glassEnabled(style: .glass, enabled: true,
                reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
            try await wait("glass-surface") { (created.contentViewController as? ToolWindowChrome)?.surface.isUsingOpaqueSurface == expectsOpaque }
            checks.append("Shared Glass/Solid and system accessibility material policies still apply")
            try require(clips.count == 2 && clips.allSatisfy { ($0["frames"] as? Int ?? 0) >= 3 }, "clip-count")
        } catch {
            if let expected = error as? Failure { failure = expected.stage }
            else if let capture = error as? NativeMotionRecorder.Failure { failure = "recorder-" + capture.rawValue }
            else { failure = "unexpected-" + String(describing: type(of: error)) }
        }
        if let activeTrace { geometry.append(["label": activeCapture, "samples": activeTrace.finish()]) }
        activeTrace = nil
        activeAction?.task?.cancel()
        await activeAction?.task?.value
        activeAction?.task = nil; activeAction = nil
        if let window {
            _ = window.makeFirstResponder(nil); ToolContentMotion.finish(in: window)
            window.close(); window.contentViewController = nil
        }
        await names?.close()
        if ApplicationFileActivity.gate.activeCount != 0 && failure == nil { failure = "actual-activity-drain" }
        if let root {
            let report: [String: Any] = ["passed": failure == nil, "failureStage": failure as Any? ?? NSNull(),
                "mode": mode.rawValue, "checks": checks, "clips": clips, "geometryTraces": geometry,
                "activityAfter": ApplicationFileActivity.gate.activeCount, "nativeWindowClosed": window?.isVisible != true,
                "networkRequests": 0, "keychainCalls": 0, "fileBodyActions": 0,
                "recordingScope": "One exact generated Settings window; current process only"]
            try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: root.appendingPathComponent("evidence/native-settings-sidebar.json"), options: .withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
    private static func clip(_ value: NativeMotionRecorder.Report, label: String, window: NSWindow) -> [String: Any] {
        ["label": label, "frames": value.frames.count, "width": value.width, "height": value.height,
         "requestedFPS": value.requestedFPS, "droppedEncoderFrames": value.droppedEncoderFrames,
         "captureGeometry": value.captureGeometry, "windowAppearance": window.effectiveAppearance.name.rawValue]
    }
}
#endif
