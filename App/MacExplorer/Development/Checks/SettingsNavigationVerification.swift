#if DEBUG
import AppKit
import ExplorerCore
import QuartzCore

@MainActor
enum SettingsNavigationVerification {
    @MainActor private final class EditingValidation: NSObject, NSTextFieldDelegate {
        var permitsEnd = false
        private(set) var refusals = 0
        func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
            if !permitsEnd { refusals += 1 }
            return permitsEnd
        }
    }
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
    static func table(in window: NSWindow) -> NSTableView? {
        guard let table = find(NSTableView.self, identifier: "settings-navigation", in: window),
              table.numberOfRows == BrowserSettingsView.Page.ordered.count else { return nil }
        return table
    }

    static func select(_ page: BrowserSettingsView.Page, window: NSWindow, interactive: Bool = true) async throws {
        guard let table = table(in: window),
              let index = BrowserSettingsView.Page.ordered.firstIndex(of: page)
        else { throw Failure(stage: "native-navigation-missing") }
        if interactive { try await UIVerification.clickRow(index, in: table) }
        else { table.selectRowIndexes([index], byExtendingSelection: false) }
        try require(table.selectedRow == index, "native-page-not-selected")
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
            var editor = settings.editorPreferences
            try editor.setTarget(.traverse, forExtension: "traverseqa")
            settings.updateEditorPreferences(editor)
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
                foreground == [.general] && table(in: created) != nil
            }
            let original = created.frame
            try await Task.sleep(for: .milliseconds(280))
            let action = ActionOwner()
            activeAction = action
            activeCapture = "settings-keyboard"; activeTrace = GeometryTrace(created)
            let keyboard = try await NativeMotionRecorder.record(window: created, root: scope, label: "settings-keyboard",
                sampling: .diagnostic(for: created)) {
                action.task = Task { @MainActor in
                    do {
                        try await select(.keyboard, window: created)
                        try await wait("keyboard-field-not-created") {
                            find(NSTextField.self, identifier: "shortcut-action-search", in: created) != nil
                        }
                        guard let field = find(NSTextField.self, identifier: "shortcut-action-search", in: created) else { throw Failure(stage: "keyboard-field") }
                        _ = field.scrollToVisible(field.bounds)
                        created.contentView?.layoutSubtreeIfNeeded()
                        action.field = field; action.fieldReady = CACurrentMediaTime()
                    } catch { action.failure = (error as? UIVerification.Failure)?.message ?? "keyboard-field" }
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
            try verifyNavigationRefusal(field: field, window: created) { foreground == [.keyboard] }
            checks.append("Rejected native field validation preserves the editor, selected row and current page")

            activeCapture = "settings-appearance"; activeTrace = GeometryTrace(created)
            let second = try await NativeMotionRecorder.record(window: created, root: scope, label: "settings-appearance",
                sampling: .diagnostic(for: created)) {
                action.task = Task { @MainActor in
                    do { try await select(.appearance, window: created) }
                    catch { action.failure = (error as? UIVerification.Failure)?.message ?? "appearance-click" }
                }
            }
            await action.task?.value
            geometry.append(["label": activeCapture, "samples": activeTrace?.finish() ?? []]); activeTrace = nil
            try await wait("appearance-foreground") { foreground == [.appearance] }
            try require(action.failure == nil && created.frame == original && field.currentEditor() == nil,
                "field-resignation-or-frame-change")
            clips.append(clip(second, label: "settings-appearance", window: created))
            for page in BrowserSettingsView.Page.ordered where page != .appearance {
                try await select(page, window: created)
                try await wait("selected-page-not-foreground") { foreground == [page] }
                try require(created.frame == original, "page-resized-window")
            }
            try require(BrowserSettingsView.Page.ordered.allSatisfy { appearances[$0, default: 0] > 0 }, "not-all-settings-pages-exercised")
            checks.append("All Settings pages have one foreground owner, and selection preserves the user's window frame")
            guard let table = table(in: created) else { throw Failure(stage: "navigation-after-pages") }
            try require(created.makeFirstResponder(table), "navigation-keyboard-focus")
            let up = String(UnicodeScalar(Int(NSUpArrowFunctionKey))!)
            guard let upEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: CACurrentMediaTime(), windowNumber: created.windowNumber, context: nil,
                characters: up, charactersIgnoringModifiers: up,
                isARepeat: false, keyCode: 126) else { throw Failure(stage: "native-up-event") }
            table.keyDown(with: upEvent)
            try await wait("native-up-key-navigation") { foreground == [.privacy] }
            checks.append("Native source-list arrow-key selection changes the page without a mouse")
            try await verifySettingsSearch(created, settings: settings, root: scope, visiblePages: { foreground })
            checks.append("Command-F focuses Settings Search. Results reveal the native control, a nested file type, an inactive prerequisite or a specific shortcut row. Clear and Escape return focus to the section list.")
            try await select(.general, window: created)
            try await wait("general-return") { foreground == [.general] }
            settings.navigationStyle = .solid
            try await wait("solid-surface") { (created.contentViewController as? ToolWindowChrome)?.surface.isUsingOpaqueSurface == true }
            settings.navigationStyle = .glass
            let expectsOpaque = !BrowserMaterialPolicy.glassEnabled(style: .glass, enabled: true,
                reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
            try await wait("glass-surface") { (created.contentViewController as? ToolWindowChrome)?.surface.isUsingOpaqueSurface == expectsOpaque }
            checks.append("Shared Glass/Solid and system accessibility material policies still apply")
            let sizing = try await InterfaceSizingVerification.preview(settings: settings, root: scope)
            try require(sizing["passed"] as? Bool == true, "sizing-preview-failed")
            try await wait("sizing-preferences-not-restored") {
                (created.contentViewController as? ToolWindowChrome)?.motion == settings.motion
                    && InterfacePresentation.shared.size == settings.interfaceSize
            }
            checks.append("The native sizing slider retains identity and focus through scale and width reflows in Full, Reduced and Off motion")
            if settings.motion.allows(.pages) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                try await verifyNativePageRetirement(window: created, settings: settings)
                checks.append("Live page hosts settle on the current form before resizing, restyling or disabling page motion")
                try verifySizingRetiresPageFade(window: created, settings: settings)
                checks.append("Interface sizing retires an active outgoing page fade before revealing the current layout")
                try await verifyAppearanceRetiresContentFade(window: created, settings: settings)
                checks.append("Appearance changes retire an outgoing-layout fade before applying new colors")
                try await verifyMotionRetiresPageFade(window: created, settings: settings)
                checks.append("Disabling motion retires an active page fade without removing unrelated animations")
            }
            try require(clips.count == 2 && clips.allSatisfy { ($0["frames"] as? Int ?? 0) >= 3 }, "clip-count")
        } catch {
            if let expected = error as? Failure { failure = expected.stage }
            else if let input = error as? UIVerification.Failure { failure = input.message }
            else if let capture = error as? NativeMotionRecorder.Failure { failure = "recorder-" + capture.rawValue }
            else { failure = "unexpected-" + String(describing: type(of: error)) }
        }
        if let activeTrace { geometry.append(["label": activeCapture, "samples": activeTrace.finish()]) }
        activeTrace = nil
        let actionFailure = activeAction?.failure
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
                "actionFailure": actionFailure as Any? ?? NSNull(),
                "mode": mode.rawValue, "checks": checks, "clips": clips, "geometryTraces": geometry,
                "activityAfter": ApplicationFileActivity.gate.activeCount, "nativeWindowClosed": window?.isVisible != true,
                "networkRequests": 0, "keychainCalls": 0, "fileBodyActions": 0,
                "recordingScope": "One exact generated Settings window; current process only"]
            try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: root.appendingPathComponent("evidence/native-settings-sidebar.json"), options: .withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
    private static func verifySettingsSearch(_ window: NSWindow, settings: BrowserSettings, root: URL,
                                             visiblePages: () -> Set<BrowserSettingsView.Page>) async throws {
        func field() -> NSSearchField? {
            find(NSSearchField.self, identifier: "settings-search", in: window)
        }
        func type(_ text: String) throws {
            guard let field = field(), window.isKeyWindow, window.makeFirstResponder(field),
                  let editor = field.currentEditor() as? NSTextView else {
                throw UIVerification.Failure(message: "Settings search field did not take focus")
            }
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
        func visible(_ title: String, actionable: Bool = true) -> Bool {
            let frame = FolderCompositionOwnedControls.frame(title, in: window, actionable: actionable)
            return frame.width > 0 && frame.height > 0 && window.frame.insetBy(dx: 8, dy: 28).contains(frame)
        }
        guard let navigation = table(in: window), window.makeFirstResponder(navigation) else {
            throw Failure(stage: "search-shortcut-navigation-focus")
        }
        NSApp.sendEvent(UIVerification.key("f", code: 3, flags: .command, window: window))
        try await wait("search-shortcut-focuses-settings-search") {
            guard let editor = field()?.currentEditor() else { return false }
            return window.firstResponder === editor
        }
        let trash = "Ask before moving items to Trash"
        try type("trash-confirmation")
        try await UIVerification.waitUntil("Search matches a setting instead of only a page") { visible("Show " + trash) }
        window.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: window))
        try await UIVerification.waitUntil("Search opens Operations") { visiblePages() == [.operations] }
        try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/settings-search-trash.png"))
        try await UIVerification.waitUntil("Search reveals the exact Trash confirmation control") {
            visible(trash, actionable: false)
        }
        try UIVerification.require(field()?.currentEditor() === window.firstResponder,
            "Changing the Settings page took focus away from its search field")
        try type("compact journal")
        try await UIVerification.waitUntil("Search matches the deep journal control") { visible("Show Compact Journal Metadata") }
        window.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: window))
        try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/settings-search-journal.png"))
        try await UIVerification.waitUntil("Search scrolls the same Settings page to the selected control") {
            visible("Compact Journal Metadata") && !visible(trash, actionable: false)
        }
        try type("open_with Swift")
        try await UIVerification.waitUntil("Search finds the exact Swift opening option") { visible("Show Swift") }
        window.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: window))
        try await UIVerification.waitUntil("Search opens Tools") { visiblePages() == [.tools] }
        try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/settings-search-swift.png"))
        try await UIVerification.waitUntil("Search opens the Swift setting inside its collapsed section") {
            visible("Swift", actionable: false)
        }
        try type("open_with .traverseqa")
        try await UIVerification.waitUntil("Search finds a configured extension") { visible("Show .traverseqa files") }
        window.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: window))
        try await UIVerification.waitUntil("Search reveals the exact nested custom file type") {
            visible(".traverseqa files", actionable: false)
        }
        try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/settings-search-custom-extension.png"))
        try UIVerification.require(FolderCompositionOwnedControls.press("Dismiss Settings Search", in: window),
            "The native search dismiss button was unavailable")
        try await wait("search-dismissed") {
            field()?.stringValue == "" && table(in: window) != nil && visiblePages() == [.tools]
                && visible(".traverseqa files", actionable: false)
        }
        try await wait("search-clear-focuses-section-list") { table(in: window) === window.firstResponder }
        window.sendEvent(UIVerification.key("\u{f701}", code: 125, flags: [], window: window))
        try await wait("search-clear-allows-arrow-navigation") { visiblePages() == [.keyboard] }
        try type("trash confirmation")
        try await wait("search-escape-has-a-result") { visible("Show " + trash) }
        guard let searchField = field(), let editor = searchField.currentEditor(), window.firstResponder === editor else {
            throw Failure(stage: "search-escape-field-is-native-first-responder")
        }
        window.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: window))
        try await wait("search-escape-clears-query") { field()?.stringValue == "" }
        try await wait("search-escape-restores-section-list") { table(in: window) != nil && visiblePages() == [.keyboard] }
        try require(field() === searchField, "search-escape-keeps-the-native-field")
        try await wait("search-escape-focuses-section-list") { table(in: window) === window.firstResponder }
        try type("outline color")
        try await wait("search-finds-outline-color-with-system-accent") { visible("Show Outline color") }
        window.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: window))
        try await wait("search-reveals-outline-color-and-its-prerequisite") {
            visiblePages() == [.appearance] && visible("Outline color", actionable: false)
                && visible("Choose Custom color under Focus indication.", actionable: false)
        }
        try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/settings-search-outline-color.png"))
        try UIVerification.require(FolderCompositionOwnedControls.press("Dismiss Settings Search", in: window),
            "The native search dismiss button was unavailable")
        try await wait("search-dismiss-hides-inactive-outline-color") {
            field()?.stringValue == "" && visiblePages() == [.appearance] && !visible("Outline color", actionable: false)
        }
        let eject = "Show Eject Buttons on All Drives"
        let saved = UUID()
        settings.showsSidebarEject = false; settings.hiddenEjectVolumes = [saved]
        defer { settings.hiddenEjectVolumes = [] }
        try type("eject buttons on all drives")
        try await wait("search-finds-hidden-eject-reset") { visible("Show " + eject) }
        window.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: window))
        try await wait("search-reveals-eject-reset-and-its-prerequisite") {
            visiblePages() == [.general] && visible(eject, actionable: false)
                && visible("Enable Eject buttons beside external drives first.", actionable: false)
        }
        try require(!FolderCompositionOwnedControls.isEnabled(eject, in: window)
            && !settings.showsSidebarEject && settings.hiddenEjectVolumes == [saved], "search-keeps-eject-preferences")
        try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/settings-search-eject.png"))
        try require(FolderCompositionOwnedControls.press("Dismiss Settings Search", in: window), "search-eject-reset-dismiss")
        try await wait("search-dismiss-hides-inactive-eject-reset") {
            field()?.stringValue == "" && visiblePages() == [.general] && !visible(eject, actionable: false)
        }
        let swap = BrowserCommand.swapPaneSides
        let originalBindings = settings.shortcutPreferences
        try type("swap pane shortcut")
        try await wait("search-finds-a-specific-shortcut") { visible("Show " + swap.title) }
        window.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: window))
        try await wait("search-mounts-the-matching-shortcut-filter") {
            let filter = find(NSTextField.self, identifier: "shortcut-action-search", in: window)
            return visiblePages() == [.keyboard] && filter?.stringValue == swap.title
        }
        try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/settings-search-shortcut.png"))
        try await wait("search-reveals-the-exact-shortcut-row") {
            let row = FolderCompositionOwnedControls.frame("Record…", in: window)
            let reset = FolderCompositionOwnedControls.frame("Reset Shortcut Bindings to These Behavior Choices", in: window)
            let gap = row.midY - reset.midY
            return visible(swap.title, actionable: false) && visible("Record…")
                && FolderCompositionOwnedControls.isEnabled("Record…", in: window)
                && !reset.isEmpty && gap > 0 && gap < 90
        }
        try require(settings.shortcutPreferences == originalBindings && field()?.currentEditor() === window.firstResponder,
            "search-keeps-shortcuts-and-query-focus")
        try require(FolderCompositionOwnedControls.press("Dismiss Settings Search", in: window), "search-shortcut-dismiss")
        try await wait("search-shortcut-draft-dismissed") { field()?.stringValue == "" && table(in: window) === window.firstResponder }
    }
    private static func verifyNavigationRefusal(field: NSTextField, window: NSWindow,
                                                pageUnchanged: () -> Bool) throws {
        guard let table = find(NSTableView.self, identifier: "settings-navigation", in: window),
              let editor = field.currentEditor(),
              let attempted = BrowserSettingsView.Page.ordered.firstIndex(of: .appearance) else {
            throw Failure(stage: "navigation-refusal-setup")
        }
        let original = table.selectedRow, oldFieldDelegate = field.delegate
        let validation = EditingValidation()
        defer {
            validation.permitsEnd = true
            _ = window.makeFirstResponder(table)
            field.delegate = oldFieldDelegate
        }
        field.delegate = validation
        table.selectRowIndexes([attempted], byExtendingSelection: false)
        try require(validation.refusals > 0, "native-field-validation-did-refuse")
        try require(window.firstResponder === editor && field.currentEditor() === editor,
            "rejected-field-navigation-kept-editor")
        try require(pageUnchanged(), "rejected-field-navigation-kept-page")
        try require(table.selectedRow == original, "rejected-field-navigation-kept-row")
        validation.permitsEnd = true
        try require(window.makeFirstResponder(table), "validated-field-can-resign")
        field.delegate = oldFieldDelegate
    }
    private static func verifyNativePageRetirement(window: NSWindow, settings: BrowserSettings) async throws {
        guard let viewport = find(NSView.self, identifier: "tool-page-viewport", in: window) else {
            throw Failure(stage: "live-page-viewport")
        }
        let size = settings.interfaceSize, appearance = settings.appearance, motion = settings.motion
        defer {
            settings.interfaceSize = size
            settings.appearance = appearance
            settings.motion = motion
        }
        func begin(_ page: BrowserSettingsView.Page) async throws -> NSView {
            try await wait("prior-native-page-did-not-settle") { viewport.subviews.count == 1 }
            try await select(page, window: window)
            try await wait("live-page-overlap-not-observed") { viewport.subviews.count == 2 }
            guard let incoming = viewport.subviews.last else { throw Failure(stage: "live-page-incoming") }
            return incoming
        }
        func finished(_ incoming: NSView, _ stage: String) throws {
            try require(viewport.subviews == [incoming] && incoming.alphaValue == 1, stage)
        }
        let keyboard = try await begin(.keyboard)
        let independent = CABasicAnimation(keyPath: "transform.scale")
        independent.fromValue = 1; independent.toValue = 1; independent.duration = 5
        keyboard.layer?.add(independent, forKey: "independent-page-motion")
        settings.interfaceSize = .init(size.percent == 150 ? 100 : 150)
        try finished(keyboard, "sizing-kept-outgoing-native-page")
        try require(keyboard.layer?.animation(forKey: "independent-page-motion") != nil,
                    "sizing-removed-unrelated-native-page-animation")
        keyboard.layer?.removeAnimation(forKey: "independent-page-motion")
        settings.interfaceSize = size

        let appearancePage = try await begin(.appearance)
        settings.appearance = appearance == .light ? .dark : .light
        let appearanceName: NSAppearance.Name = settings.appearance == .light ? .aqua : .darkAqua
        try await wait("live-page-appearance-not-applied") { window.appearance?.name == appearanceName }
        try finished(appearancePage, "appearance-kept-outgoing-native-page")
        settings.appearance = appearance
        let restoredName: NSAppearance.Name? = appearance == .system ? nil : appearance == .light ? .aqua : .darkAqua
        try await wait("live-page-appearance-not-restored") { window.appearance?.name == restoredName }

        let general = try await begin(.general)
        settings.motion.pages = false
        try finished(general, "disabled-motion-kept-outgoing-native-page")
    }
    private static func verifySizingRetiresPageFade(window: NSWindow, settings: BrowserSettings) throws {
        guard let chrome = window.contentViewController as? ToolWindowChrome else { throw Failure(stage: "sizing-fade-chrome") }
        let original = settings.interfaceSize
        defer { settings.interfaceSize = original }
        ToolContentMotion.crossfadePage(chrome.contentHost, motion: settings.motion)
        try require(ToolContentMotion.hasCrossfade(in: chrome.contentHost, kind: .page), "sizing-page-fade-not-started")
        settings.interfaceSize = .init(original.percent == 150 ? 100 : 150)
        try require(!ToolContentMotion.hasCrossfade(in: chrome.contentHost), "sizing-kept-outgoing-page-fade")
    }
    private static func verifyAppearanceRetiresContentFade(window: NSWindow, settings: BrowserSettings) async throws {
        guard let chrome = window.contentViewController as? ToolWindowChrome else { throw Failure(stage: "appearance-fade-chrome") }
        let original = settings.appearance
        defer { if settings.appearance != original { settings.appearance = original } }
        ToolContentMotion.crossfade(chrome.contentHost)
        try require(ToolContentMotion.hasCrossfade(in: chrome.contentHost), "appearance-fade-not-started")
        ToolContentMotion.reveal(chrome.contentHost, movesContent: false)
        try require(ToolContentMotion.hasContentEntrance(in: chrome.contentHost), "appearance-content-reveal-not-started")
        settings.appearance = original == .light ? .dark : .light
        let expected: NSAppearance.Name = settings.appearance == .light ? .aqua : .darkAqua
        try await wait("appearance-change-not-applied") { window.appearance?.name == expected }
        try require(!ToolContentMotion.hasCrossfade(in: chrome.contentHost), "appearance-kept-old-content-fade")
        try require(!ToolContentMotion.hasContentEntrance(in: chrome.contentHost), "appearance-kept-old-content-reveal")
        settings.appearance = original
        let restored: NSAppearance.Name? = original == .system ? nil : original == .light ? .aqua : .darkAqua
        try await wait("appearance-not-restored") { window.appearance?.name == restored }
    }
    private static func verifyMotionRetiresPageFade(window: NSWindow, settings: BrowserSettings) async throws {
        guard let chrome = window.contentViewController as? ToolWindowChrome else { throw Failure(stage: "motion-fade-chrome") }
        let original = settings.motion
        defer { settings.motion = original }
        ToolContentMotion.crossfadePage(chrome.contentHost, motion: original)
        try require(ToolContentMotion.hasCrossfade(in: chrome.contentHost, kind: .page), "motion-fade-not-started")
        settings.motion.mode = .off
        try await wait("motion-change-not-applied") { chrome.motion.mode == .off }
        try require(!ToolContentMotion.hasCrossfade(in: chrome.contentHost), "disabled-motion-kept-page-fade")

        let unrelated = NSView(); unrelated.wantsLayer = true
        let property = CABasicAnimation(keyPath: "opacity"); property.duration = 1
        let transition = CATransition(); transition.duration = 1
        unrelated.layer?.add(property, forKey: "unrelated-property")
        unrelated.layer?.add(transition, forKey: kCATransition)
        ToolContentMotion.finishCrossfade(in: unrelated)
        try require(unrelated.layer?.animation(forKey: "unrelated-property") != nil
            && unrelated.layer?.animation(forKey: kCATransition) != nil, "foreign-animation-was-removed")
    }
    private static func clip(_ value: NativeMotionRecorder.Report, label: String, window: NSWindow) -> [String: Any] {
        var receipt: [String: Any] = ["label": label, "frames": value.frames.count, "width": value.width, "height": value.height,
         "requestedFPS": value.requestedFPS, "droppedEncoderFrames": value.droppedEncoderFrames,
         "captureGeometry": value.captureGeometry, "windowAppearance": window.effectiveAppearance.name.rawValue]
        if let viewport = find(NSView.self, identifier: "tool-page-viewport", in: window),
           let region = DevelopmentMotionVerification.visibleRegion(of: viewport, in: window, report: value) {
            // The live form may fade while the sidebar selection responds instantly.
            let x = Int(region.minX.rounded(.up)) + 20, y = Int(region.minY.rounded(.up)) + 20
            let width = min(550, Int(region.maxX.rounded(.down)) - x - 16)
            let height = min(190, Int(region.maxY.rounded(.down)) - y - 16)
            if width > 3, height > 3 { receipt["toolPageRegion"] = [x, y, width, height] }
        }
        return receipt
    }
}
#endif
