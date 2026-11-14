#if DEBUG
import AppKit
import ExplorerCore

/// Exercises the source browser's actual commands. The external-app boundary is
/// captured; this check never asks Launch Services to open a generated fixture.
@MainActor enum ArchiveOpenRoutingVerification {
    private struct Failure: Error { let stage: String }
    private static func require(_ condition: Bool, _ stage: String) throws {
        if !condition { throw Failure(stage: stage) }
    }
    private static func wait(_ stage: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            try require(.now < deadline, stage)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func key(_ window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
        else { throw Failure(stage: "return-event-unavailable") }
        return event
    }
    static func run() async {
        var root: URL?, owner: BrowserWindowController?, browser: BrowserViewController?
        var checks = [String](), calls = [URL](), failureStage: String?
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure(stage: "scope-root") }
            let area = URL(fileURLWithPath: raw)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("reservation.json"))) as? [String: Any]
            let admission = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("day-build-admission.json"))) as? [String: Any]
            try require(area.resolvingSymlinksInPath() == area
                && area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString: area.lastPathComponent)?.uuidString == area.lastPathComponent
                && marker?["packet"] as? String == "traverse-development-v1"
                && marker?["action"] as? String == "archive-open-routing-native"
                && admission?["master"] as? String == "7B4FE5D0-444E-4676-A91F-25E69FDDAF8D"
                && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/traverse-release/tooling/derived/Build/Products/Debug/Mac Explorer.app"), "scope-identity")
            root = area
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false
            settings.restoresSession = false; settings.reviewsRecoveryAtStartup = false
            settings.keyboardProfile = .explorer; settings.viewMode = .details; settings.motion.mode = .reduced
            let controller = BrowserWindowController(settings: settings)
            owner = controller
            let sourceBrowser = controller.browser
            browser = sourceBrowser
            sourceBrowser.permitsBackgroundVerification = true
            sourceBrowser.readVolumesForVerification = { [] }
            sourceBrowser.folderAccess = FolderAccessController(stateDirectory: nil)
            sourceBrowser.recoverableFileOperations = sourceBrowser.operationCoordinator.engine(at: area.appendingPathComponent("state/history"))
            sourceBrowser.defaultOpenForVerification = { url in calls.append(url); return true }
            let source = area.appendingPathComponent("source"), tar = source.appendingPathComponent("Review.tar")
            let zip = source.appendingPathComponent("Review.zip"), text = source.appendingPathComponent("Ordinary.txt")
            let folder = source.appendingPathComponent("Folder"), link = source.appendingPathComponent("Link.tar")
            sourceBrowser.tabs = [.init(location: .directory(source))]
            sourceBrowser.activeID = sourceBrowser.tabs[0].id
            sourceBrowser.loadLocation()
            guard let window = controller.window else { throw Failure(stage: "source-window-unavailable") }
            window.title = "Archive Open routing · generated fixtures"
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await wait("source-listing") { !sourceBrowser.isLoading && sourceBrowser.orderingTask == nil && sourceBrowser.rowsByURL[tar] != nil }
            func select(_ urls: Set<URL>) {
                sourceBrowser.setFileSelection(urls); sourceBrowser.fileSelectionDidChange()
            }
            func doubleAction() throws {
                guard let action = sourceBrowser.table.doubleAction else { throw Failure(stage: "details-double-action-missing") }
                try require(NSApp.sendAction(action, to: sourceBrowser.table.target, from: sourceBrowser.table), "details-double-action-not-delivered")
            }
            func focus() async throws {
                window.makeKeyAndOrderFront(nil)
                sourceBrowser.focusBrowserContent()
                try await wait("source-file-surface-focus") { window.isKeyWindow && sourceBrowser.hasFileCommandFocus && sourceBrowser.isActiveCommandPane }
            }
            // Keep this first: the red must prove the ordinary source call site
            // handed the TAR to the system boundary before any model assertion.
            select([tar]); try doubleAction()
            try require(calls.isEmpty, "tar-default-open-routed-externally")
            try await wait("tar-controller-and-page") { ApplicationTARBrowser.shared.controller?.model.current == true && ApplicationTARBrowser.shared.controller?.model.busy == false }
            guard let tarModel = ApplicationTARBrowser.shared.controller?.model else { throw Failure(stage: "tar-controller-unavailable") }
            try require(tarModel.source == tar && tarModel.items.map(\.name) == ["Folder", "Note.txt"]
                && tarModel.summary?.files == 2 && tarModel.summary?.folders == 1, "tar-source-metadata-page")
            checks.append("Actual Details doubleAction opens the selected TAR metadata page without a system handoff")
            await ApplicationTARBrowser.shared.closeAndDrain()

            select([zip]); try doubleAction()
            try require(calls.isEmpty, "zip-default-open-routed-externally")
            try await wait("zip-controller-and-page") { ApplicationZIPBrowser.shared.controller?.model.viewIsCurrent == true && ApplicationZIPBrowser.shared.controller?.model.isLoading == false }
            guard let zipModel = ApplicationZIPBrowser.shared.controller?.model else { throw Failure(stage: "zip-controller-unavailable") }
            try require(zipModel.source == zip && zipModel.page?.items.map(\.name) == ["Folder", "Note.txt"], "zip-source-metadata-page")
            checks.append("The same Details command opens ZIP metadata without extracting or handing off")
            await ApplicationZIPBrowser.shared.stopAndDrain()

            select([folder]); try doubleAction()
            try await wait("directory-navigation") { sourceBrowser.location == .directory(folder) && !sourceBrowser.isLoading && sourceBrowser.orderingTask == nil }
            try require(calls.isEmpty, "directory-external-handoff")
            sourceBrowser.goBack(nil)
            try await wait("directory-back") { sourceBrowser.location == .directory(source) && !sourceBrowser.isLoading && sourceBrowser.orderingTask == nil }
            select([text]); try doubleAction()
            try require(calls == [text], "ordinary-text-default-open-once")
            checks.append("Directory Open/Back stays local; an ordinary text file reaches the captured default-app boundary exactly once")
            select([tar, text]); try doubleAction()
            select([]); try doubleAction()
            select([link]); try doubleAction()
            select([source.appendingPathComponent("Missing.tar")]); try doubleAction()
            try require(calls == [text] && ApplicationTARBrowser.shared.controller == nil && ApplicationZIPBrowser.shared.controller == nil,
                        "invalid-selection-open-refusal")
            checks.append("Multiple, empty, symlink and missing-row selections open neither archive nor external application")

            settings.keyboardProfile = .explorer
            select([tar]); try await focus()
            sourceBrowser.table.keyDown(with: try key(window))
            try require(calls == [text], "explorer-return-external-handoff")
            try await wait("explorer-return-tar-page") { ApplicationTARBrowser.shared.controller?.model.current == true }
            try require(ApplicationTARBrowser.shared.controller?.model.source == tar, "explorer-return-source")
            await ApplicationTARBrowser.shared.closeAndDrain()
            checks.append("Explorer Return reaches the actual source shortcut route and opens the selected TAR")

            settings.keyboardProfile = .mac
            select([tar]); try await focus()
            sourceBrowser.table.keyDown(with: try key(window))
            try await wait("mac-return-inline-rename") { sourceBrowser.inlineRename.isEditing }
            try require(calls == [text] && ApplicationTARBrowser.shared.controller == nil, "mac-return-opened-instead-of-rename")
            sourceBrowser.inlineRename.cancel()
            try await wait("mac-return-cancel-drain") { !sourceBrowser.inlineRename.isEditing && sourceBrowser.operationPreparationTask == nil }
            checks.append("Mac Return enters native Rename; Cancel drains it without changing the source")
        } catch {
            failureStage = (error as? Failure)?.stage ?? "unexpected-\(String(reflecting: type(of: error)))"
        }
        browser?.inlineRename.cancel()
        await ApplicationTARBrowser.shared.closeAndDrain()
        await ApplicationZIPBrowser.shared.stopAndDrain()
        owner?.suspendBrowsing(); await owner?.flushSession(); owner?.window?.close()
        browser?.defaultOpenForVerification = nil
        let drained = ApplicationTARBrowser.shared.controller == nil && ApplicationZIPBrowser.shared.controller == nil
            && browser?.operationTask == nil && browser?.operationPreparationTask == nil
        if failureStage == nil && (!drained || ApplicationFileActivity.gate.activeCount != 0) { failureStage = "owner-activity-drain" }
        if let root {
            let value: [String: Any] = ["passed": failureStage == nil, "failureStage": failureStage.map { $0 as Any } ?? NSNull(),
                "checks": checks, "defaultOpenCalls": calls.count, "ownersDrained": drained,
                "activityAfter": ApplicationFileActivity.gate.activeCount, "generatedOnly": true,
                "systemAppLaunches": 0, "networkRequests": 0, "keychainCalls": 0,
                "physicalPointer": false, "openWithExercised": false, "fileMutations": 0]
            try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("evidence/native-archive-open-routing.json"), options: .withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
}
#endif
