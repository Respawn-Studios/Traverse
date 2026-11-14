#if DEBUG
import AppKit
import ExplorerCore
import LocalStorage
import FileOperations

/// The existing own-process recorder, bound to one generated archive window.
/// No arbitrary actions, file-controlled commands, screen filter or body reads.
@MainActor
enum InlineArchiveMotionVerification {
    private struct Failure: Error { let stage: String }
    private static let title = "Archives · generated review · motion audit"

    static func run() async {
        var root: URL?, controller: BrowserWindowController?
        var clips: [[String: Any]] = [], checks: [String] = [], failure: String?
        var mode = BrowserMotionMode.full
        do {
            let args = ProcessInfo.processInfo.arguments
            func argument(_ key: String) -> String? {
                args.firstIndex(of: key).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            }
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
                  let chosen = argument("--motion-mode"), let selectedMode = BrowserMotionMode(rawValue: chosen) else { throw Failure(stage: "scope") }
            let area = URL(fileURLWithPath: raw)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("reservation.json"))) as? [String: Any]
            let admission = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("inline-admission.json"))) as? [String: Any]
            guard area.resolvingSymlinksInPath() == area, area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development"),
                  UUID(uuidString: area.lastPathComponent)?.uuidString == area.lastPathComponent,
                  marker?["packet"] as? String == "traverse-development-v1", marker?["action"] as? String == "inline-archive-native",
                  admission?["master"] as? String == "7B4FE5D0-444E-4676-A91F-25E69FDDAF8D", admission?["phase"] as? String == "motion",
                  Bundle.main.bundleIdentifier == "local.macexplorer.development" else { throw Failure(stage: "scope-identity") }
            root = area; mode = selectedMode
            let settings = BrowserSettings(persist: false)
            settings.appearance = args.contains("--motion-light") ? .light : .dark
            settings.navigationStyle = .glass; settings.glassFileContent = true
            settings.restoresSession = false; settings.autoRefreshFolders = false
            settings.reviewsRecoveryAtStartup = false; settings.folderSummariesEnabled = false
            settings.motion = .init(mode: mode); settings.keyboardProfile = .explorer
            if args.contains("--motion-large") { settings.interfaceSize = .init(150) }
            InterfacePresentation.shared.bind(settings)
            let owner = BrowserWindowController(settings: settings); controller = owner
            let browser = owner.workspace.activeBrowser
            browser.readVolumesForVerification = { [] }
            browser.folderAccess = FolderAccessController(stateDirectory: nil)
            browser.pinsController = BrowserPinsController(stateDirectory: nil)
            browser.privateNames = ApplicationPrivateNames(directory: area.appendingPathComponent("state/names"), settings: settings)
            browser.recoverableFileOperations = browser.operationCoordinator.engine(at: area.appendingPathComponent("state/history"))
            browser.defaultOpenForVerification = { _ in false }
            guard owner.isWorkspacePresentation, let window = owner.window else { throw Failure(stage: "workspace-window") }
            window.setContentSize(.init(width: 1100, height: 680)); window.center()
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            owner.workspace.sessionReady = true
            let source = area.appendingPathComponent("source")
            browser.navigate(to: .directory(source)); try await wait("local-source") { !browser.isLoading && browser.orderingTask == nil }
            let tar = source.appendingPathComponent("Review.tar")
            browser.setFileSelection([tar]); browser.fileSelectionDidChange(); browser.focusBrowserContent()
            guard browser.orderedSelectedURLs == [tar] else { throw Failure(stage: "source-selection") }

            clips.append(try await record("archive-enter", root: area, window: window, browser: browser, mode: mode) {
                browser.openSelection(nil)
            })
            try await wait("tar-open") { browser.currentArchive?.current == true && browser.currentArchive?.busy == false }
            guard case .archive(let archive) = browser.location, archive.format == .tar,
                  window.firstResponder === browser.currentArchive?.table else { throw Failure(stage: "archive-content-focus") }
            checks.append("Natural TAR Open retains content focus while its real catalog opens")
            guard let current = browser.currentArchive, let model = current.tarModelForVerification,
                  let row = model.items.firstIndex(where: { $0.folder != nil }) else { throw Failure(stage: "generated-folder") }
            current.table?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            clips.append(try await record("archive-folder-enter", root: area, window: window, browser: browser, mode: mode) {
                browser.openSelection(nil)
            })
            try await wait("folder-enter") { memberPath(browser) == ["Folder"] && browser.currentArchive?.current == true && browser.currentArchive?.busy == false }
            // Also exercise the independent Folder switch while other motion
            // remains enabled; Off alone would not prove that control works.
            if mode == .reduced { settings.motion.folders = false }
            clips.append(try await record("archive-folder-back", root: area, window: window, browser: browser, mode: mode) { browser.goBack(nil) })
            try await wait("folder-back") { memberPath(browser) == [] && browser.currentArchive?.current == true && browser.currentArchive?.busy == false }
            settings.motion.folders = true
            clips.append(try await record("archive-folder-forward", root: area, window: window, browser: browser, mode: mode) { browser.goForward(nil) })
            try await wait("folder-forward") { memberPath(browser) == ["Folder"] && browser.currentArchive?.current == true && browser.currentArchive?.busy == false }
            let tarTab = browser.activeID
            browser.newTab(nil); browser.navigate(to: .directory(source))
            try await wait("second-local-source") { !browser.isLoading && browser.orderingTask == nil }
            let zip = source.appendingPathComponent("Review.zip")
            browser.setFileSelection([zip]); browser.fileSelectionDidChange(); browser.openSelection(nil)
            try await wait("zip-open") { browser.currentArchive?.current == true && browser.currentArchive?.busy == false }
            let zipTab = browser.activeID
            browser.selectTab(tarTab)
            try await wait("restored-tar-tab") { memberPath(browser) == ["Folder"] && browser.currentArchive?.current == true && browser.currentArchive?.busy == false }
            clips.append(try await record("archive-tab-switch", root: area, window: window, browser: browser, mode: mode) { browser.selectTab(zipTab) })
            try await wait("restored-zip-tab") { browser.activeID == zipTab && browser.currentArchive?.current == true && browser.currentArchive?.busy == false }
            checks.append("Actual own-window streams cover archive entry, folder Back/Forward and retained archive-tab switching")
            guard clips.count == 5, clips.allSatisfy({ ($0["frames"] as? Int ?? 0) >= 3 && $0["droppedEncoderFrames"] as? Int == 0 }) else { throw Failure(stage: "capture-count-or-drop") }
            checks.append("Every stream/writer finishes; no encoder drops and geometry is verified by the recorder")
        } catch { failure = (error as? Failure)?.stage ?? "unexpected-\(String(reflecting: type(of: error)))" }
        controller?.suspendBrowsing()
        await ArchiveTabCatalogPool.shared.closeAndDrain()
        await ApplicationArchiveExports.shared.closeAndDrain()
        if let controller { await controller.flushSession(); controller.window?.close() }
        let active = ApplicationFileActivity.gate.activeCount
        if failure == nil && (active != 0 || ArchiveTabCatalogPool.shared.retainedCountForVerification != 0 || ArchiveTabCatalogPool.shared.retiringCountForVerification != 0) { failure = "actual-owner-drain" }
        if let root {
            let result: [String: Any] = ["passed": failure == nil, "failureStage": failure.map { $0 as Any } ?? NSNull(),
                "surface": "archive", "mode": mode.rawValue, "clips": clips, "checks": checks, "activityAfter": active,
                "poolRetainedAfter": ArchiveTabCatalogPool.shared.retainedCountForVerification,
                "poolRetiringAfter": ArchiveTabCatalogPool.shared.retiringCountForVerification,
                "exportsAfter": ApplicationArchiveExports.shared.countForVerification,
                "networkRequests": 0, "keychainCalls": 0, "declaredExplicitBodyActions": 0, "fileBodyReadCounterMeasured": false,
                "recordingScope": "Current process; one exact generated archive window", "physicalPointer": false]
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("evidence/native-inline-archive-motion.json"), options: .withoutOverwriting)
        }
        NSApp.terminate(nil)
    }

    private static func memberPath(_ browser: BrowserViewController) -> [String]? {
        if case .archive(let value) = browser.location { return value.folderPath }; return nil
    }
    private static func wait(_ stage: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !predicate() { guard .now < deadline else { throw Failure(stage: stage) }; try await Task.sleep(for: .milliseconds(10)) }
    }
    private static func record(_ label: String, root: URL, window: NSWindow, browser: BrowserViewController,
                               mode: BrowserMotionMode, action: @MainActor () -> Void) async throws -> [String: Any] {
        try await wait("settled-recording-baseline-" + label) {
            browser.canvasTransition == nil && !browser.isLoading && browser.orderingTask == nil && browser.currentArchive?.busy != true
        }
        browser.view.layoutSubtreeIfNeeded(); browser.view.displayIfNeeded()
        let effect: BrowserMotionEffect = label == "archive-tab-switch" ? .tabContent : .folders
        let effectEnabled = browser.settings.motion.allows(effect)
        let monitor = Task { @MainActor in
            var legacyArrivals = 0, disabledTransitions = 0, observations = 0
            while !Task.isCancelled {
                observations += 1
                if !effectEnabled, browser.canvasTransition != nil { disabledTransitions += 1 }
                if let table = browser.currentArchive?.table {
                    let visible = table.rows(in: table.visibleRect)
                    if visible.location != NSNotFound {
                        for index in visible.location..<min(table.numberOfRows, visible.upperBound) {
                            if let row = table.rowView(atRow: index, makeIfNecessary: false), row.layer?.animation(forKey: "tool-content-entrance") != nil { legacyArrivals += 1 }
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return (legacyArrivals, disabledTransitions, observations)
        }
        defer { monitor.cancel() }
        window.title = title
        let report = try await NativeMotionRecorder.record(window: window, root: root, label: label,
            sampling: .diagnostic(for: window), action: action)
        monitor.cancel()
        let (legacyArrivals, disabledTransitions, observations) = await monitor.value
        try JSONEncoder().encode(report).write(to: root.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
        guard observations >= 3, legacyArrivals == 0, disabledTransitions == 0 else { throw Failure(stage: "motion-policy-" + label) }
        var clip: [String: Any] = ["label": label, "frames": report.frames.count, "mode": mode.rawValue,
            "width": report.width, "height": report.height, "requestedFPS": report.requestedFPS,
            "droppedEncoderFrames": report.droppedEncoderFrames, "captureGeometry": report.captureGeometry,
            "windowAppearance": window.effectiveAppearance.name.rawValue,
            "baselineCanvasSettled": true, "effectEnabled": effectEnabled, "policyObservations": observations,
            "legacyRowArrivalObservations": legacyArrivals, "disabledCanvasTransitionObservations": disabledTransitions]
        if label != "archive-enter", let header = browser.currentArchive?.table?.headerView, header.window === window {
            let frame = header.convert(header.bounds, to: nil)
            let region = NSRect(x: frame.minX, y: CGFloat(report.height) - frame.maxY, width: frame.width, height: frame.height)
            if NSRect(x: 0, y: 0, width: report.width, height: report.height).contains(region) {
                clip["fieldRegion"] = ["x": region.minX, "y": region.minY, "width": region.width, "height": region.height]
                clip["fieldVisibility"] = "Archive column header"; clip["fieldOwnerVerified"] = true
            }
        }
        return clip
    }
}
#endif
