#if DEBUG
import AppKit
import Foundation
@_spi(Qualification) import LocalStorage

/// Real view controllers with generated presentation/empty local state only.
/// No connection, hardware-health, trust, password or benchmark operation is
/// called. The embedded benchmark owner may discover mounted-volume metadata.
@MainActor enum DevelopmentToolWindowChecks {
    private struct Topology: DriveTopologyReading {
        let snapshot: DriveTopologySnapshot
        func readTopology() async throws -> DriveTopologySnapshot { snapshot }
    }
    private struct Inspection: VolumeInspecting {
        func inspect(_ volume: ManagedVolume) async throws -> VolumeInspection {
            .init(volume: volume, deviceName: "generated-device", fields: .init(fileSystem: "apfs",
                model: "Generated SSD", transport: "PCI-Express", mediaBytes: 512 << 30, writable: true))
        }
    }
    private static func presentationHealth() -> ApplicationDriveDetails {
        let health = ApplicationDriveDetails(reader: Inspection(), utilityHandoff: { false })
        health.healthCheckForVerification = { _ in
            .init(outcome: .warning(kind: .nvme, rawByte: 0, capturedAt: Date()), childReaped: true, nativeCleanupConfirmed: true,
                nvmeMeasurements: .init(temperatureKelvin: 310, availableSpare: 97, spareThreshold: 10,
                    percentageUsed: 12, counters: [1_000_000, 2_000_000, 500, 600, 70, 121, 2_000, 3, 0, 4]))
        }
        return health
    }
    static func run(root: URL, settings: BrowserSettings) async throws -> (checks: [String: Any], clips: [[String: Any]]) {
        var clips: [[String: Any]] = [], decisions = 0, copies = 0, details = 0, trustDrains = 0
        let health = presentationHealth()
        let drives = ApplicationDriveManagement(reader: Topology(snapshot: try DriveManagementVerification.fixture()),
            health: health, details: { _, _ in details += 1 })
        let trustModel = SFTPTrustModel(review: .init(host: "generated.invalid", port: 22,
            fingerprint: "SHA256:generated-new-key-not-connection-evidence",
            previousFingerprint: "SHA256:generated-old-key-not-connection-evidence"),
            copy: { _ in copies += 1 }, decision: { _ in decisions += 1; throw Failure.unexpectedAction },
            drain: { trustDrains += 1; return true })
        let trust = SFTPTrustWindowController(settings: settings, model: trustModel)
        let settingsPath = root.appendingPathComponent("state/UncreatedServerSettings")
        let poolPath = root.appendingPathComponent("state/UncreatedCatalogPool")
        let state = SFTPRememberedState(settings: .init(directory: settingsPath), passwords: .loginKeychain())
        let storage = SFTPConnectionStorageWindow(settings: settings, remembered: state,
            storage: try .init(directory: poolPath, sessionByteLimit: 1 << 20, poolByteLimit: 2 << 20))
        let source = try await SFTPUploadSourceReview.inspect(root.appendingPathComponent("source/Upload.txt"), excluding: [])
        let upload = SFTPUploadPreview(source: source, destination: "Generated server · no connection", settings: settings)
        let folderSource = try await SFTPFolderUploadSourceReview.inspect(root.appendingPathComponent("source"), excluding: [])
        let folderUpload = SFTPFolderUploadPreview(source: folderSource, destination: "Generated server · no connection", settings: settings)
        let folderDownload = SFTPFolderDownloadPreview(summary: .init(generatedFiles: 2, folders: 1, bytes: 128),
            parentPath: "Generated destination · no transfer", name: "Generated Folder", settings: settings)
        var benchmarkBrowser: BrowserWindowController?

        func closeAndDrain() async {
            await drives.closeAndDrain()
            await health.closeAndDrain()
            trustModel.cancel()
            try? await wait { trustModel.finished != nil }
            trust.close()
            await storage.closeAndDrain(); await state.drain()
            upload.finish(nil); upload.close()
            folderUpload.finish(nil); folderUpload.close()
            folderDownload.finish(.cancel); folderDownload.close()
            if let browser = benchmarkBrowser?.browser {
                browser.suspendBrowser()
                await browser.privateNames.close(); await browser.flushBrowserSession()
            }
            benchmarkBrowser?.window?.close(); benchmarkBrowser = nil
        }
        func capture(_ label: String, _ window: NSWindow, field: (() -> NSTextField?)? = nil, over background: NSWindow? = nil,
                     includingChildWindows: Bool = true,
                     action: @MainActor () -> Void) async throws {
            window.title = label + " · generated review"
            if let background { ToolWindowChrome.position(window, relativeTo: background) } else { window.center() }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(250))
            let movie = try await NativeMotionRecorder.record(window: window, over: background, root: root, label: label,
                sampling: .diagnostic(for: window), includingChildWindows: includingChildWindows, action: action)
            try JSONEncoder().encode(movie).write(to: root.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
            var measured = DevelopmentMotionVerification.clip(label, report: movie, field: field?(), window: window)
            let expected: NSAppearance.Name = settings.appearance == .system
                ? NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
                : settings.appearance == .light ? .aqua : .darkAqua
            measured["expectedAppearance"] = expected.rawValue
            measured["appearanceMatches"] = measured["windowAppearance"] as? String == expected.rawValue && measured["contentAppearance"] as? String == expected.rawValue
            clips.append(measured)
        }
        do {
            drives.show(settings: settings); await drives.drain()
            guard let window = drives.window else { throw Failure.presentation }
            try await wait { health.inspection != nil && !health.isReading }
            if health.health == nil { health.checkHardwareHealth() }
            await health.drainHealth()
            let next: UInt64 = drives.selectedRootID == 6 ? 1 : 6
            try await capture("tool-drive-selection", window) { drives.selectRoot(next) }
            guard drives.selectedRootID == next else { throw Failure.presentation }
            let backdrop = window
            try await wait { health.inspection != nil && !health.isReading }
            if health.health == nil { health.checkHardwareHealth() }
            await health.drainHealth()
            try await capture("tool-drive-health-page", window) { drives.selectPage(.health) }
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/tool-drive-health.png"))

            // Exercise the existing native indicator's presentation with an
            // injected reconnect callback. Actual saved reconnect is covered
            // separately by the existing generated SMB connection flow.
            var reconnects = 0, hoverShown = false
            let indicator = ConnectionStatusControl { reconnects += 1 }
            guard let content = window.contentView else { throw Failure.presentation }
            indicator.frame = .init(x: 22, y: 24, width: 33, height: 24); content.addSubview(indicator)
            indicator.configure(.connected, detail: "SFTP · Connected\nGenerated server\nFolder: Generated server · /fixture/Projects/Client project/Build assets\nSecurity: SSH encrypted\nAccess: Read and write\nItems: 64\nLatest directory read: 12 ms\nIncludes server response and local processing; not a network ping.\nConnected: Today, 10:30 AM", motion: settings.motion)
            var gesture: Task<Void, Error>?
            let indicatorParentFrame = window.frame
            try await capture("tool-connection-status", window, includingChildWindows: false) {
                gesture = Task { @MainActor in
                    for index in 0..<12 {
                        let local = NSPoint(x: CGFloat(index) * 2.5 + 2, y: 13)
                        let location = indicator.convert(local, to: nil)
                        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { continue }
                        if index == 0 { indicator.mouseEntered(with: event) }
                        else { indicator.mouseMoved(with: event) }
                        try? await Task.sleep(for: .milliseconds(45))
                        hoverShown = hoverShown || indicator.detailsVisibleForVerification
                    }
                    if let details = indicator.detailsWindowForVerification {
                        try await GlassVerification.captureOwnedWindow(details,
                            to: root.appendingPathComponent("evidence/tool-connection-details.png"))
                    }
                    indicator.performClick(nil)
                }
            }
            try await gesture?.value
            guard reconnects == 0, hoverShown, window.frame == indicatorParentFrame else { throw Failure.presentation }
            indicator.configure(.disconnected, detail: "SFTP · Disconnected\nClick to reconnect.", motion: settings.motion)
            indicator.performClick(nil)
            guard reconnects == 1 else { throw Failure.presentation }
            indicator.configure(nil, detail: "", motion: settings.motion); indicator.removeFromSuperview()

            trust.present()
            guard let window = trust.window else { throw Failure.presentation }
            try await capture("tool-trust-replacement", window) { trustModel.showReplacement() }
            guard trustModel.page == .replacement else { throw Failure.presentation }
            try await capture("tool-trust-back", window) { trustModel.back() }
            trustModel.cancel(); try await wait { trustModel.finished != nil }; trust.close()

            backdrop.makeKeyAndOrderFront(nil)
            storage.present(relativeTo: backdrop); try await wait { !storage.model.busy }
            guard let window = storage.window, storage.model.notice.isEmpty else { throw Failure.presentation }
            try await capture("tool-connection-storage", window, over: backdrop) { window.performClose(nil) }
            guard !window.isVisible, !ToolWindowCloseMotion.isClosing(window) else { throw Failure.presentation }
            await storage.closeAndDrain(); await state.drain()
            backdrop.close(); await drives.drain()

            guard let window = upload.window else { throw Failure.presentation }
            window.setContentSize(window.contentMinSize)
            try await capture("tool-upload-details", window, field: {
                descendants(window.contentView).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "New filename" }
            }) { upload.model.details = true }
            guard let field = descendants(window.contentView).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "New filename" }),
                  window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else { throw Failure.presentation }
            editor.selectAll(nil); editor.insertText("Reviewed.txt", replacementRange: .init(location: 0, length: field.stringValue.utf16.count))
            guard upload.model.name == "Reviewed.txt", upload.model.valid else { throw Failure.presentation }
            _ = window.makeFirstResponder(nil)
            let original = settings.appearance
            settings.appearance = original == .light ? .dark : .light
            try await capture("tool-live-theme-change", window) {}
            settings.appearance = .system
            try await capture("tool-live-system-theme", window) {}
            settings.appearance = original
            try await capture("tool-live-theme-restore", window) {}
            for (label, controller) in [("tool-folder-upload-size", folderUpload as NSWindowController),
                                        ("tool-folder-download-size", folderDownload as NSWindowController)] {
                guard let window = controller.window else { throw Failure.presentation }
                window.setContentSize(window.contentMinSize)
                try await capture(label, window) {
                    if controller === folderUpload { folderUpload.model.details = true }
                    else { folderDownload.model.details = true }
                }
                window.orderOut(nil)
            }

            // Exercise the actual workspace handoff from a physical root, whose
            // descriptor intentionally has no filesystem ID or mount URL.
            let browserOwner = BrowserWindowController(settings: settings)
            benchmarkBrowser = browserOwner
            browserOwner.browser.readVolumesForVerification = { [] }
            drives.show(settings: settings, browser: browserOwner.browser)
            await drives.drain(); drives.selectRoot(1)
            guard drives.selectedNode?.volume.url == nil, drives.canBenchmarkSelection,
                  let benchmarkWindow = drives.window else { throw Failure.presentation }
            try await capture("tool-drive-benchmark-navigation", benchmarkWindow) { drives.benchmarkSelection() }
            guard drives.page == .benchmark, drives.benchmark.isEmbedded(in: benchmarkWindow),
                  drives.benchmark.volumeName == "Macintosh HD",
                  !drives.benchmark.hasPendingWork, !drives.benchmark.canRun else { throw Failure.presentation }
            drives.selectRoot(6); drives.benchmarkSelection()
            guard drives.canBenchmarkSelection, drives.benchmark.volumeName == "Generated Media",
                  !drives.benchmark.hasPendingWork, !drives.benchmark.canRun else { throw Failure.presentation }
            await closeAndDrain()
        } catch { await closeAndDrain(); throw error }

        let expected: NSAppearance.Name = settings.appearance == .light ? .aqua : .darkAqua
        let matches = clips.allSatisfy { $0["appearanceMatches"] as? Bool == true }
        let absent = !FileManager.default.fileExists(atPath: settingsPath.path) && !FileManager.default.fileExists(atPath: poolPath.path)
        let observations: [String: Any] = ["appearanceMatches": matches, "expectedAppearance": expected.rawValue,
            "windows": clips, "trustDecisions": decisions, "clipboardCalls": copies, "deviceDetailsCalls": details,
            "trustDrains": trustDrains, "uncreatedStateRemainsAbsent": absent]
        try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("evidence/tool-appearance.json"), options: .withoutOverwriting)
        guard matches, absent, decisions == 0, copies == 0, details == 0, trustDrains == 1 else { throw Failure.presentation }
        return (["passed": true, "actualWindowThemeMatches": true, "uncreatedStateRemainsAbsent": absent,
            "trustDecisions": decisions, "clipboardCalls": copies, "deviceDetailsCalls": details,
            "networkCalls": 0, "passwordOperations": 0, "nativeUploadNameEditing": true,
            "minimumTransferDialogsReviewed": true,
            "deviceRootBenchmarkNavigation": true, "benchmarkWrites": 0,
            "liveLightDarkSystemChanges": true, "actualDriveSelectionChanged": true], clips)
    }
    /// Exercise the actual retained controllers, not a direct call to an
    /// animation helper. This makes the normal opening/closing path observable.
    static func verifyWindowLifecycle(root: URL, settings: BrowserSettings) async throws {
        let original = settings.motion
        let originalLive = settings.driveHealthLiveUpdates
        settings.driveHealthLiveUpdates = false
        let preferences = BrowserSettingsWindow.make(BrowserSettingsView(settings: settings))
        let analysis = StorageAnalysisWindowController(onChooseFolder: {}, onRefresh: {}, onStop: {}, onAppStorage: {})
        let properties = FilePropertiesWindowController(settings: settings, copyPaths: { _ in })
        let zip = ArchiveBrowserWindowController(model: .init(settings: settings, reader: .init()))
        let tar = TARBrowserWindowController(model: .init(settings: settings, reader: .init()))
        let health = presentationHealth()
        let drives = ApplicationDriveManagement(reader: Topology(snapshot: try DriveManagementVerification.fixture()),
            health: health, details: { _, _ in })
        let help = TraverseHelpController.shared
        var windows: [NSWindow] = [preferences]
        var stage = "startup", passed = false
        var observations: [[String: Any]] = []
        var capturedClips: [String] = []
        var alphaSamples: [CGFloat] = []
        var alphaSampleTimes: [TimeInterval] = []
        defer {
            try? JSONSerialization.data(withJSONObject: ["passed": passed, "stage": stage, "windows": observations,
                "capturedClips": capturedClips,
                "nativeWindowAlpha": windows.map { $0.alphaValue },
                "lastOpeningAlphaSamples": alphaSamples,
                "lastOpeningSampleTimes": alphaSampleTimes,
                "independentEffects": passed, "programmaticCloseImmediate": passed,
                "systemReduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion], options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("evidence/tool-window-lifecycle.json"), options: .withoutOverwriting)
            for window in windows { ToolWindowCloseMotion.cancel(window); window.close() }
            properties.cancel(); help.history.cancel(); settings.motion = original
            settings.driveHealthLiveUpdates = originalLive
        }
        let shows: [(String, () -> NSWindow?)] = [
            ("Settings", { preferences.makeKeyAndOrderFront(nil); return preferences }),
            ("What's New", { help.showForMotionVerification(.whatsNew, settings: settings); return help.window }),
            ("Properties", { properties.show(urls: [root.appendingPathComponent("source/Upload.txt")]); return properties.window }),
            ("Analyzer", { analysis.applyToolStyle(settings); analysis.showWindow(nil); return analysis.window }),
            ("ZIP Browser", { zip.showWindow(nil); zip.window?.makeKeyAndOrderFront(nil); return zip.window }),
            ("TAR Browser", { tar.showWindow(nil); tar.window?.makeKeyAndOrderFront(nil); return tar.window }),
            ("Drives", { drives.show(settings: settings); return drives.window })
        ]
        let recordedWindows = ["Settings": "settings", "What's New": "whats-new", "Analyzer": "analyzer"]
        do {
            NSApplication.shared.activate(ignoringOtherApps: true)
            for mode in BrowserMotionMode.allCases {
                settings.motion = .init(mode: mode)
                try await Task.sleep(for: .milliseconds(30))
                for (name, show) in shows {
                    stage = name + "/" + mode.rawValue + "/opening"
                    guard let window = show(), let chrome = window.contentViewController as? ToolWindowChrome else { throw Failure.presentation }
                    if !windows.contains(where: { $0 === window }) { windows.append(window) }
                    let expected = mode != .off && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    let entrance = window.alphaValue < 1
                    try UIVerification.require(entrance == expected, name + " normal opening missed its motion policy")
                    if expected {
                        _ = ToolWindowChrome.install(in: window, settings: settings)
                        try UIVerification.require(window.alphaValue < 1,
                            name + " identical style binding ended its opening transition")
                    }
                    alphaSamples = [window.alphaValue]
                    let openingBegan = CACurrentMediaTime()
                    alphaSampleTimes = [0]
                    let openingDeadline = openingBegan + 1
                    while window.alphaValue < 1 && CACurrentMediaTime() < openingDeadline {
                        try await Task.sleep(for: .milliseconds(10))
                        alphaSamples.append(window.alphaValue)
                        alphaSampleTimes.append(CACurrentMediaTime() - openingBegan)
                    }
                    let openingAlpha = alphaSamples.first(where: { $0 > 0 && $0 < 1 }) ?? window.alphaValue
                    stage = name + "/" + mode.rawValue + "/intermediate-opacity"
                    try UIVerification.require(!expected || openingAlpha > 0 && openingAlpha < 1,
                        name + " opening did not expose an intermediate native window opacity")
                    try await wait { window.isVisible && window.isOnActiveSpace && window.occlusionState.contains(.visible) }
                    let frame = window.frame, child = chrome.children.first
                    stage = name + "/" + mode.rawValue + "/settling"
                    try await wait { window.alphaValue == 1 }
                    _ = show()
                    try UIVerification.require(window.frame == frame && chrome.children.first === child
                        && window.alphaValue == 1,
                        name + " bring-to-front replayed motion or rebuilt its allocation")
                    window.performClose(nil)
                    stage = name + "/" + mode.rawValue + "/closing"
                    let closing = ToolWindowCloseMotion.isClosing(window)
                    try UIVerification.require(closing == expected, name + " native user close missed its motion policy")
                    if expected {
                        try UIVerification.require(window.isVisible && window.ignoresMouseEvents, name + " retired before its accepted fade")
                        window.makeKeyAndOrderFront(nil)
                        try UIVerification.require(window.isVisible && !ToolWindowCloseMotion.isClosing(window)
                            && !window.ignoresMouseEvents && window.alphaValue == 1,
                            name + " Show did not cancel the pending close")
                        window.performClose(nil)
                    }
                    var closingAlpha: CGFloat?
                    let closingBegan = CACurrentMediaTime()
                    let closingDeadline = closingBegan + 1
                    var closingAlphas: [CGFloat] = [], closingSampleTimes: [Double] = []
                    while window.isVisible && CACurrentMediaTime() < closingDeadline {
                        let alpha = window.alphaValue
                        if alpha > 0 && alpha < 1 { closingAlpha = alpha }
                        closingAlphas.append(alpha)
                        closingSampleTimes.append(CACurrentMediaTime() - closingBegan)
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    try UIVerification.require(!expected || closingAlpha != nil,
                        name + " closing did not expose an intermediate native window opacity")
                    try await wait { !window.isVisible && !ToolWindowCloseMotion.isClosing(window) }
                    try UIVerification.require(window.alphaValue == 1 && !window.ignoresMouseEvents,
                        name + " retained a hidden or unresponsive presentation")
                    observations.append(["window": name, "mode": mode.rawValue,
                        "entrance": entrance, "openingIntermediateAlpha": openingAlpha,
                        "openingAlphaSamples": alphaSamples, "openingSampleTimes": alphaSampleTimes,
                        "closingIntermediateAlpha": closingAlpha ?? 1, "closingAlphaSamples": closingAlphas,
                        "closingSampleTimes": closingSampleTimes, "userCloseFade": closing, "framePreserved": true])
                    if let label = recordedWindows[name], mode == .full || name == "Settings" {
                        stage = name + "/" + mode.rawValue + "/rendered"
                        capturedClips += try await captureRetainedLifecycle(root: root, label: "lifecycle-\(label)-\(mode.rawValue)", show: show)
                    }
                }
            }
            stage = "hidden-entrance-policy-change"
            settings.motion = .init()
            try await Task.sleep(for: .milliseconds(30))
            preferences.makeKeyAndOrderFront(nil)
            preferences.orderOut(nil)
            settings.motion = .init(mode: .off)
            _ = ToolWindowChrome.install(in: preferences, settings: settings)
            preferences.makeKeyAndOrderFront(nil)
            try UIVerification.require(preferences.alphaValue == 1,
                "A hidden entrance survived reopening with motion disabled")
            try await Task.sleep(for: .milliseconds(450))
            try UIVerification.require(preferences.isVisible && preferences.alphaValue == 1,
                "A retired entrance changed the reopened window")
            preferences.close()
            // Opening and closing have separate switches. Programmatic teardown
            // must remain immediate even when both user-facing effects are on.
            for opening in [false, true] {
                stage = "independent-effects/" + String(opening)
                settings.motion = .init(windows: opening, windowClosing: !opening)
                try await Task.sleep(for: .milliseconds(30))
                preferences.makeKeyAndOrderFront(nil)
                let systemReduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                try UIVerification.require((preferences.alphaValue < 1) == (opening && !systemReduced),
                    "Independent opening preference was ignored")
                try await wait { preferences.occlusionState.contains(.visible) }
                preferences.performClose(nil)
                try UIVerification.require(ToolWindowCloseMotion.isClosing(preferences) == (!opening && !systemReduced),
                    "Independent closing preference was ignored")
                try await wait { !preferences.isVisible }
            }
            settings.motion = .init()
            stage = "programmatic-close"
            try await Task.sleep(for: .milliseconds(30))
            preferences.makeKeyAndOrderFront(nil); preferences.close()
            try UIVerification.require(!preferences.isVisible && !ToolWindowCloseMotion.isClosing(preferences),
                "Programmatic teardown acquired a user-close fade")
            try UIVerification.require(preferences.alphaValue == 1, "Programmatic teardown retained its opening fade")
            stage = "properties-discard-close"
            try await verifyPropertiesDiscardClose(root: root, settings: settings) { stage = "properties-discard/" + $0 }
            await drives.closeAndDrain(); await health.closeAndDrain()
            stage = "completed"; passed = true
        } catch {
            await drives.closeAndDrain(); await health.closeAndDrain()
            throw error
        }
    }

    private static func captureRetainedLifecycle(root: URL, label: String, show: () -> NSWindow?) async throws -> [String] {
        guard let window = show() else { throw Failure.presentation }
        try await wait { window.alphaValue == 1 && window.isVisible && window.occlusionState.contains(.visible) }
        let originalFrame = window.frame
        if originalFrame.width > 1152 || originalFrame.height > 800 {
            // This is the generated review viewport, with the same recorder
            // cap used elsewhere. The ordinary initial frame is untouched.
            window.setFrame(.init(origin: originalFrame.origin,
                size: .init(width: min(1152, originalFrame.width), height: min(800, originalFrame.height))), display: true)
        }
        let frame = window.frame
        let originalTitle = window.title
        window.title = "Tool window · generated review · " + label
        let backdrop = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.title = "Tool backdrop · generated review · " + label
        backdrop.backgroundColor = .systemTeal
        backdrop.isOpaque = true; backdrop.ignoresMouseEvents = true
        backdrop.isReleasedWhenClosed = false; backdrop.isRestorable = false
        backdrop.order(.above, relativeTo: window.windowNumber)
        defer { backdrop.close(); window.title = originalTitle; window.setFrame(originalFrame, display: false) }

        // Start with the generated cover already in front. Reopening the exact
        // retained, now ordered-out window exercises its normal Show path
        // while the recorder stays restricted to these same two window IDs.
        let opening = label + "-open", closing = label + "-close"
        let sampling = NativeMotionRecorder.Sampling.diagnostic(for: window)
        _ = try await NativeMotionRecorder.record(window: window, over: backdrop, root: root,
            label: opening, sampling: sampling, includingChildWindows: false) {
            // Only the Show action is under review. Suppress the test's own
            // outgoing utility-window snapshot before reopening the same ID.
            let animation = window.animationBehavior
            window.animationBehavior = .none
            window.orderOut(nil)
            window.animationBehavior = animation
            try UIVerification.require(show() === window, "Reopen replaced the recorded tool window")
        }
        try UIVerification.require(window.frame == frame && window.alphaValue == 1 && window.isVisible,
            "Rendered reopen did not preserve and settle the tool window")
        backdrop.order(.below, relativeTo: window.windowNumber)
        window.title = "Tool window · generated review · " + label
        _ = try await NativeMotionRecorder.record(window: window, over: backdrop, root: root,
            label: closing, sampling: sampling, includingChildWindows: false) { window.performClose(nil) }
        try UIVerification.require(!window.isVisible && !ToolWindowCloseMotion.isClosing(window),
            "Rendered close did not settle")
        return [opening, closing]
    }

    private static func verifyPropertiesDiscardClose(root: URL, settings: BrowserSettings,
                                                    onStage: (String) -> Void) async throws {
        let names = ApplicationPrivateNames(directory: root.appendingPathComponent("state/close-names"), settings: settings)
        let properties = FilePropertiesWindowController(settings: settings, namesOwner: names, copyPaths: { _ in })
        do {
            properties.show(urls: [root.appendingPathComponent("source/Upload.txt")])
            guard let window = properties.window, let editor = properties.namesEditor else { throw Failure.presentation }
            onStage("ready")
            try await wait { !editor.loading && window.alphaValue == 1 && window.occlusionState.contains(.visible) }
            editor.nickname = "Generated unsaved close draft"
            func choose(_ title: String) throws {
                guard let sheet = window.attachedSheet,
                      let button = descendants(sheet.contentView).compactMap({ $0 as? NSButton })
                        .first(where: { $0.title == title }) else { throw Failure.presentation }
                button.performClick(nil)
            }
            window.performClose(nil)
            onStage("first-sheet")
            try await wait { window.attachedSheet != nil }
            try UIVerification.require(!ToolWindowCloseMotion.isClosing(window), "Dirty Properties faded before its close decision")
            try choose("Keep Editing")
            onStage("keep-editing")
            try await wait { window.attachedSheet == nil && !properties.isChoosingDiscardForVerification }
            try UIVerification.require(window.isVisible && editor.hasChanges && !ToolWindowCloseMotion.isClosing(window),
                "Keep Editing lost its draft or closed Properties")
            window.performClose(nil)
            onStage("second-sheet")
            try await wait { window.attachedSheet != nil }
            try choose("Discard Changes")
            onStage("accepted-close")
            var sawClosing = false, sawIntermediateOpacity = false
            let deadline = CACurrentMediaTime() + 2
            while window.isVisible && CACurrentMediaTime() < deadline {
                sawClosing = sawClosing || ToolWindowCloseMotion.isClosing(window)
                sawIntermediateOpacity = sawIntermediateOpacity || window.alphaValue > 0 && window.alphaValue < 1
                try await Task.sleep(for: .milliseconds(10))
            }
            let animated = settings.motion.allows(.windowClosing) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            try UIVerification.require(!window.isVisible && !editor.hasChanges && editor.source == nil,
                "Accepted Properties discard retained the draft or its window")
            try UIVerification.require(!animated || sawClosing && sawIntermediateOpacity,
                "Accepted Properties discard bypassed the shared native close transition")
            await names.close()
        } catch {
            properties.cancel(); properties.close(); await names.close()
            throw error
        }
    }
    private static func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) }
    }
    private static func wait(_ ready: () -> Bool) async throws {
        let end = CACurrentMediaTime() + 5
        while !ready() {
            guard CACurrentMediaTime() < end else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private enum Failure: Error { case presentation, unexpectedAction, deadline }
}
#endif
