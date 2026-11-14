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
    static func run(root: URL, settings: BrowserSettings) async throws -> (checks: [String: Any], clips: [[String: Any]]) {
        var clips: [[String: Any]] = [], decisions = 0, copies = 0, details = 0, trustDrains = 0
        let health = ApplicationDriveDetails(reader: Inspection(), utilityHandoff: { false })
        health.healthCheckForVerification = { _ in
            .init(outcome: .warning(kind: .nvme, rawByte: 0, capturedAt: Date()), childReaped: true, nativeCleanupConfirmed: true,
                nvmeMeasurements: .init(temperatureKelvin: 310, availableSpare: 97, spareThreshold: 10,
                    percentageUsed: 12, counters: [1_000_000, 2_000_000, 500, 600, 70, 121, 2_000, 3, 0, 4]))
        }
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
                     action: @MainActor () -> Void) async throws {
            window.title = label + " · generated review"
            if let background { ToolWindowChrome.position(window, relativeTo: background) } else { window.center() }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(250))
            let movie = try await NativeMotionRecorder.record(window: window, over: background, root: root, label: label,
                sampling: .diagnostic(for: window), action: action)
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
            try await capture("tool-connection-status", window) {
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
            guard reconnects == 0, hoverShown else { throw Failure.presentation }
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
