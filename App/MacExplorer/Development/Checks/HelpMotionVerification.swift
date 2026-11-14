#if DEBUG
import AppKit
import ExplorerCore

/// Exact generated Help window only. No updater start, submitted invitation,
/// Keychain call, website request, diagnostic export or user file is exercised.
@MainActor enum HelpMotionVerification {
    private struct Failure: Error { let stage: String }
    private final class ActionOwner {
        var task: Task<Void, Never>?
        var failure: String?
        var field: NSSecureTextField?
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
    private static func fields(in window: NSWindow) -> [NSSecureTextField] {
        guard let root = window.contentView else { return [] }
        var pending = [root], result: [NSSecureTextField] = [], count = 0
        while let view = pending.popLast(), count < 4096 {
            count += 1
            if let field = view as? NSSecureTextField, field.placeholderString == "Invitation password" {
                result.append(field)
            }
            pending.append(contentsOf: view.subviews)
        }
        return result
    }
    private static func navigation(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView else { return nil }
        var pending = [root], count = 0
        while let view = pending.popLast(), count < 4096 {
            count += 1
            if let table = view as? NSTableView, table.identifier?.rawValue == "help-navigation" { return table }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }
    private static func click(_ page: TraverseHelpPage, owner: TraverseHelpController) throws {
        guard let window = owner.window, let table = navigation(in: window),
              let row = TraverseHelpPage.allCases.firstIndex(of: page) else { throw Failure(stage: "help-navigation") }
        let point = table.convert(.init(x: 80, y: table.rect(ofRow: row).midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let value = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: CACurrentMediaTime(), windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1) else { throw Failure(stage: "help-mouse-event") }
            return value
        }
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        table.mouseDown(with: try event(.leftMouseDown))
        try require(table.selectedRow == row, "help-native-selected-row")
    }
    static func run() async {
        var root: URL?, window: NSWindow?, active: ActionOwner?
        var checks: [String] = [], clips: [[String: Any]] = [], failure: String?
        var mode = BrowserMotionMode.full
        let owner = TraverseHelpController.shared
        do {
            let args = ProcessInfo.processInfo.arguments
            func argument(_ key: String) -> String? {
                args.firstIndex(of: key).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            }
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
                  let value = argument("--motion-mode"), let selected = BrowserMotionMode(rawValue: value) else {
                throw Failure(stage: "scope-arguments")
            }
            let scope = URL(fileURLWithPath: raw)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: scope.appendingPathComponent("reservation.json"))) as? [String: Any]
            let admission = try JSONSerialization.jsonObject(with: Data(contentsOf: scope.appendingPathComponent("help-motion-admission.json"))) as? [String: Any]
            try require(scope.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && scope.resolvingSymlinksInPath() == scope && UUID(uuidString: scope.lastPathComponent)?.uuidString == scope.lastPathComponent
                && marker?["action"] as? String == "help-form-motion-v1"
                && admission?["master"] as? String == "46F68181-FA2B-4308-8713-7D518F2FF08C"
                && admission?["mode"] as? String == value && Bundle.main.bundleIdentifier == "local.macexplorer.development", "scope-identity")
            root = scope; mode = selected
            try require(ApplicationDiagnostics.shared.recorder == nil && !ApplicationUpdates.shared.hasInvitation
                && !ApplicationUpdates.shared.working, "isolated-service-state")
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
            settings.folderSummariesEnabled = false; settings.navigationStyle = .glass
            settings.motion = .init(mode: mode)
            settings.appearance = args.contains("--motion-light") ? .light : .dark
            settings.interfaceSize = .init(args.contains("--motion-large") ? 150 : 100)
            InterfacePresentation.shared.bind(settings)
            ApplicationUpdates.shared.availabilityForVerification = true
            owner.showForMotionVerification(.about, settings: settings)
            guard let created = owner.window else { throw Failure(stage: "help-window") }
            window = created
            created.title = "Help · generated review · private field motion"
            created.center(); created.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await wait("sidebar-ready") { navigation(in: created) != nil }
            try await Task.sleep(for: .milliseconds(280))
            let original = created.frame
            let action = ActionOwner(); active = action
            let first = try await NativeMotionRecorder.record(window: created, root: scope,
                label: "help-invitation", sampling: .diagnostic(for: created)) {
                do { try click(.updates, owner: owner) } catch { action.failure = "updates-click" }
                action.task = Task { @MainActor in
                    do {
                        try await wait("invitation-field-not-created") { fields(in: created).count == 1 }
                        guard let field = fields(in: created).first else { throw Failure(stage: "invitation-field") }
                        _ = field.scrollToVisible(field.bounds)
                        created.contentView?.layoutSubtreeIfNeeded()
                        action.field = field; action.fieldReady = CACurrentMediaTime()
                    } catch { action.failure = "invitation-field" }
                }
            }
            await action.task?.value
            guard let field = action.field, let ready = action.fieldReady, let last = first.frames.last else {
                throw Failure(stage: "invitation-visible")
            }
            try require(action.failure == nil && owner.page == .updates && ready <= last.receivedUptimeSeconds
                && !field.visibleRect.isEmpty && field.stringValue.isEmpty, "actual-invitation-capture")
            var firstClip = clip(first, label: "help-invitation", window: created)
            let fieldFrame = field.convert(field.bounds, to: nil)
            firstClip["fieldRegion"] = ["x": fieldFrame.minX, "y": CGFloat(first.height) - fieldFrame.maxY,
                "width": fieldFrame.width, "height": fieldFrame.height]
            firstClip["fieldOwnerVerified"] = true
            firstClip["fieldVisibleAfterSeconds"] = max(0, ready - first.actionUptimeSeconds)
            clips.append(firstClip)
            try require(created.makeFirstResponder(field), "invitation-native-focus")
            guard let editor = field.currentEditor() as? NSTextView else { throw Failure(stage: "invitation-editor") }
            editor.insertText("Generated-only-control", replacementRange: .init(location: 0, length: 0))
            try await wait("invitation-native-typing") { field.stringValue == "Generated-only-control" }
            checks.append("Actual sidebar click creates and focuses the secure native field; generated typing never submits")
            let second = try await NativeMotionRecorder.record(window: created, root: scope,
                label: "help-support", sampling: .diagnostic(for: created)) {
                do { try click(.support, owner: owner) } catch { action.failure = "support-click" }
            }
            try await wait("support-page") { owner.page == .support }
            try require(action.failure == nil && created.frame == original && field.currentEditor() == nil,
                "field-resignation-frame")
            clips.append(clip(second, label: "help-support", window: created))
            try click(.updates, owner: owner)
            try await wait("empty-return-field") { fields(in: created).count == 1 && fields(in: created).first?.stringValue.isEmpty == true }
            try await Task.sleep(for: .milliseconds(280))
            checks.append("Leaving Updates resigns the field editor, clears private input and returns an empty field")
            for page in TraverseHelpPage.allCases where page != .updates {
                try click(page, owner: owner)
                try await wait("help-selected-page-" + page.rawValue) { owner.page == page }
                try await Task.sleep(for: .milliseconds(260))
                try require(created.frame == original, "help-page-resized-window")
            }
            checks.append("Every Help page retains the window frame and repeated changes settle without a retained input owner")
            for page in [TraverseHelpPage.support, .updates, .whatsNew, .about] {
                try click(page, owner: owner)
                try await wait("rapid-page-" + page.rawValue) { owner.page == page }
            }
            try await Task.sleep(for: .milliseconds(280))
            try require(owner.page == .about && fields(in: created).isEmpty, "rapid-page-settled")
            checks.append("Rapid sidebar changes remain actionable while a previous detail transition is running")
            try require(!settings.publicAutomaticUpdateChecks, "public-checks-default-off")
            ApplicationUpdates.shared.requiresInvitationForVerification = false
            let publicClip = try await NativeMotionRecorder.record(window: created, root: scope,
                label: "help-public-updates", sampling: .diagnostic(for: created)) {
                do { try click(.updates, owner: owner) } catch { action.failure = "public-updates-click" }
            }
            try await wait("public-update-page") { owner.page == .updates && fields(in: created).isEmpty }
            try await Task.sleep(for: .milliseconds(280))
            clips.append(clip(publicClip, label: "help-public-updates", window: created))
            try require(action.failure == nil && ApplicationUpdates.shared.hasUpdateAccess && !ApplicationUpdates.shared.hasInvitation,
                "public-update-access-without-invitation")
            settings.publicAutomaticUpdateChecks = true
            let encoded = try settings.encodedSnapshot()
            try require(BrowserSettings(persist: false, restoredData: encoded).publicAutomaticUpdateChecks,
                "public-checks-roundtrip")
            var legacy = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
            legacy.removeValue(forKey: "publicAutomaticUpdateChecks")
            legacy["automaticUpdateChecks"] = true
            let old = BrowserSettings(persist: false, restoredData: try JSONSerialization.data(withJSONObject: legacy))
            try require(!old.publicAutomaticUpdateChecks && old.automaticUpdateChecks,
                "public-checks-do-not-inherit-private-choice")
            settings.publicAutomaticUpdateChecks = false
            try click(.about, owner: owner)
            try await wait("public-update-page-left") { owner.page == .about }
            ApplicationUpdates.shared.requiresInvitationForVerification = nil
            checks.append("Public Updates has no invitation field; its default-off check preference roundtrips independently of legacy private consent; no updater is started")
            guard let table = navigation(in: created), created.makeFirstResponder(table) else {
                throw Failure(stage: "help-arrow-focus")
            }
            let up = String(UnicodeScalar(Int(NSUpArrowFunctionKey))!)
            guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: CACurrentMediaTime(), windowNumber: created.windowNumber, context: nil,
                characters: up, charactersIgnoringModifiers: up, isARepeat: false, keyCode: 126) else {
                throw Failure(stage: "help-arrow-event")
            }
            table.keyDown(with: key)
            try await wait("help-native-arrow-page") { owner.page == .community }
            checks.append("Native arrow-key navigation changes the Help page without requiring a mouse")
            settings.navigationStyle = .solid
            try await wait("solid-surface") { (created.contentViewController as? ToolWindowChrome)?.surface.isUsingOpaqueSurface == true }
            settings.navigationStyle = .glass
            let expectsOpaque = !BrowserMaterialPolicy.glassEnabled(style: .glass, enabled: true,
                reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
            try await wait("glass-surface") { (created.contentViewController as? ToolWindowChrome)?.surface.isUsingOpaqueSurface == expectsOpaque }
            checks.append("Shared Glass/Solid and accessibility material fallbacks still apply")
        } catch {
            if let expected = error as? Failure { failure = expected.stage }
            else if let capture = error as? NativeMotionRecorder.Failure { failure = "recorder-" + capture.rawValue }
            else { failure = "unexpected-" + String(describing: type(of: error)) }
        }
        active?.task?.cancel(); await active?.task?.value; active?.task = nil; active = nil
        if let window {
            _ = window.makeFirstResponder(nil); ToolContentMotion.finish(in: window)
            window.close(); window.contentViewController = nil
        }
        owner.history.cancel()
        ApplicationUpdates.shared.availabilityForVerification = nil
        ApplicationUpdates.shared.requiresInvitationForVerification = nil
        if ApplicationFileActivity.gate.activeCount != 0 && failure == nil { failure = "actual-activity-drain" }
        if let root {
            let report: [String: Any] = ["passed": failure == nil, "failureStage": failure as Any? ?? NSNull(),
                "mode": mode.rawValue, "checks": checks, "clips": clips,
                "activityAfter": ApplicationFileActivity.gate.activeCount, "nativeWindowClosed": window?.isVisible != true,
                "networkRequests": 0, "keychainCalls": 0, "fileBodyActions": 0,
                "recordingScope": "One exact generated Help window; current process only"]
            try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: root.appendingPathComponent("evidence/native-help-motion.json"), options: .withoutOverwriting)
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
