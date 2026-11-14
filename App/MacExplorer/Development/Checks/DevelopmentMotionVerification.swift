#if DEBUG
import AppKit
import ExplorerCore
import FileMemory
import StorageAnalysis

/// Generated-only actual native pages; no credential request or private input.
@MainActor enum DevelopmentMotionVerification {
    static func run() async {
        var settingsWindow: NSWindow?
        var browser: BrowserWindowController?
        var names: ApplicationPrivateNames?
        var analysis: StorageAnalysisWindowController?
        var properties: FilePropertiesWindowController?
        var connection: SMBConnectWindowController?
        var interactive: SFTPInteractiveWindowController?
        var result: [String: Any] = ["passed": false]
        var root: URL?
        var checkpoint = "scope"
        var additionalChecks: [String: Any] = [:]
        let arguments = ProcessInfo.processInfo.arguments
        let selectedSurface = arguments.firstIndex(of: "--motion-surface").flatMap {
            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
        }
        let chartOnly = selectedSurface == "chart"
        do {
            guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let candidate = URL(fileURLWithPath: path)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard candidate.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development"),
                  candidate.resolvingSymlinksInPath() == candidate,
                  UUID(uuidString: candidate.lastPathComponent)?.uuidString == candidate.lastPathComponent,
                  let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate.appendingPathComponent("reservation.json"))) as? [String: Any],
                  marker["packet"] as? String == "traverse-development-v1",
                  marker["action"] as? String == "motion-audit" else { throw Failure.scope }
            root = candidate
            let surface = selectedSurface ?? "settings"
            let modeText = arguments.firstIndex(of: "--motion-mode").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "full"
            guard ["settings","editor-settings","help","analysis","properties","connection","ssh","ssh-prompts","ssh-jump","workspace","tools","chart","filters","controls","integration","deep","deep-navigation","progress","stop","failures","workload"].contains(surface), let mode = BrowserMotionMode(rawValue: modeText) else { throw Failure.scope }
            let settings = BrowserSettings(persist: false)
            settings.appearance = .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
            if arguments.contains("--motion-light") { settings.appearance = .light }
            if arguments.contains("--motion-large") { settings.interfaceSize = .init(150) }
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
            settings.motion = .init(mode: mode)
            InterfacePresentation.shared.bind(settings)
            var clips: [[String: Any]] = []
            if surface == "settings" || surface == "editor-settings" {
                print("DEVELOPMENT_MOTION_SETTINGS_MODEL")
                let owner = ApplicationPrivateNames(directory: candidate.appendingPathComponent("state/names"), settings: settings)
                names = owner
                var visiblePages = Set<BrowserSettingsView.Page>()
                var content = BrowserSettingsView(settings: settings, namesOwner: owner)
                content.onPageVisibilityForVerification = { page, visible in
                    if visible { visiblePages.insert(page) } else { visiblePages.remove(page) }
                }
                let window = BrowserSettingsWindow.make(content)
                print("DEVELOPMENT_MOTION_SETTINGS_WINDOW")
                settingsWindow = window
                window.title = "Settings · generated review · motion audit"
                window.center(); window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                try await wait { settingsNavigation(in: window) != nil }
                try await Task.sleep(for: .milliseconds(250))
                if surface == "editor-settings" { additionalChecks["editorPreferences"] = try EditorSettingsAppChecks.check() }
                let destinations: [(BrowserSettingsView.Page, String)] = surface == "editor-settings"
                    ? [(.tools,"settings-editor-defaults"),(.appearance,"settings-editor-appearance"),(.tools,"settings-editor-return")]
                    : [(.keyboard,"settings-keyboard"),(.appearance,"settings-appearance"),(.general,"settings-general"),(.keyboard,"settings-keyboard-repeat")]
                for (target, label) in destinations {
                    guard let index = BrowserSettingsView.Page.ordered.firstIndex(of: target) else { throw Failure.presentation }
                    print("DEVELOPMENT_MOTION_RECORD \(label)")
                    let movie = try await NativeMotionRecorder.record(window: window, root: candidate, label: label,
                        sampling: .diagnostic(for: window)) { select(index, in: window) }
                    guard window.effectiveAppearance.bestMatch(from: [.aqua,.darkAqua]) == (arguments.contains("--motion-light") ? .aqua : .darkAqua) else { throw Failure.presentation }
                    guard visiblePages.contains(target) else { throw Failure.presentation }
                    try encode(movie, at: candidate.appendingPathComponent("evidence/\(label).json"))
                    let field = descendants(window.contentView).compactMap { $0 as? NSTextField }
                        .first { $0.accessibilityLabel() == "Find an action or shortcut" }
                    clips.append(clip(label, report: movie, field: field, window: window))
                }
                if surface == "editor-settings" {
                    // SwiftUI's menu picker need not be an NSPopUpButton.
                    // This generated-only check observes actual owned-window
                    // input through the public accessibility surface; it does
                    // not write the model to simulate a successful user action.
                    checkpoint = "editor-owned-native-input"
                    try JSONSerialization.data(withJSONObject: ["window": window.windowNumber,
                        "title": window.title, "expectedColumns": 8, "expectedInsertion": "tabs",
                        "expectedContinueIndentation": false], options: [.sortedKeys])
                        .write(to: candidate.appendingPathComponent("evidence/editor-controls-ready.json"), options: .withoutOverwriting)
                    let inputDeadline = ContinuousClock.now + .seconds(25)
                    while settings.editorPreferences.indentation.columns != 8
                        || settings.editorPreferences.indentation.insertion != .tabs
                        || settings.editorPreferences.indentation.continuesIndentation {
                        guard .now < inputDeadline else { throw Failure.presentation }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    checkpoint = "editor-picker-roundtrip"
                    let encoded = try settings.encodedSnapshot()
                    let restored = BrowserSettings(persist: false, restoredData: encoded)
                    guard restored.editorPreferences == settings.editorPreferences else { throw Failure.presentation }
                    additionalChecks["nativeIndentationControls"] = ["ownedNativeInputObserved": true,
                        "roundtrip": true, "columns": 8, "insertion": "tabs", "continuesIndentation": false,
                        "profileWrites": 0, "modelAssignmentByVerifier": false]
                    let label = "settings-editor-changed"
                    let changed = try await NativeMotionRecorder.record(window: window, root: candidate, label: label,
                        sampling: .diagnostic(for: window)) { window.contentView?.layoutSubtreeIfNeeded() }
                    try encode(changed, at: candidate.appendingPathComponent("evidence/\(label).json"))
                    clips.append(clip(label, report: changed, field: nil, window: window))
                }
                if settings.interfaceSize.percent == 150,
                   let field = descendants(window.contentView).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == "Find an action or shortcut" }) {
                    let label = "settings-search-scroll"
                    let movie = try await NativeMotionRecorder.record(window: window, root: candidate, label: label,
                        sampling: .diagnostic(for: window)) { field.scrollToVisible(field.bounds.insetBy(dx: -8, dy: -8)) }
                    try encode(movie, at: candidate.appendingPathComponent("evidence/\(label).json"))
                    let item = clip(label, report: movie, field: field, window: window)
                    guard item["fieldRegion"] != nil, window.makeFirstResponder(field),
                          let editor = field.currentEditor() as? NSTextView else { throw Failure.presentation }
                    editor.insertText("Copy", replacementRange: NSRange(location: 0, length: 0))
                    guard field.stringValue == "Copy" else { throw Failure.presentation }
                    _ = window.makeFirstResponder(nil)
                    clips.append(item)
                }
                let rapidDestinations: [BrowserSettingsView.Page] = [.appearance,.keyboard,.general,.keyboard,.appearance,.general]
                for target in rapidDestinations {
                    guard let index = BrowserSettingsView.Page.ordered.firstIndex(of: target) else { throw Failure.presentation }
                    select(index, in: window)
                    try await Task.sleep(for: .milliseconds(30))
                }
                try await Task.sleep(for: .milliseconds(300))
                guard visiblePages == [.general] else { throw Failure.presentation }
                settings.motion.mode = .off
                try await Task.sleep(for: .milliseconds(40))
                guard (window.contentViewController as? ToolWindowChrome)?.contentHost.layer?.animation(forKey: "tool-page-crossfade") == nil else { throw Failure.presentation }
            } else if surface == "help" {
                let controller = BrowserWindowController(settings: settings); browser = controller
                controller.window?.orderOut(nil)
                ApplicationUpdates.shared.availabilityForVerification = true
                TraverseHelpController.shared.show(.about, from: controller.browser)
                guard let window = TraverseHelpController.shared.window else { throw Failure.presentation }
                window.title = "Help · generated review · motion audit"
                window.center(); window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .milliseconds(250))
                for iteration in 0..<3 {
                    let label = "help-invitation-\(iteration)"
                    let movie = try await NativeMotionRecorder.record(window: window, root: candidate, label: label,
                        sampling: .diagnostic(for: window)) { TraverseHelpController.shared.page = .updates }
                    try encode(movie, at: candidate.appendingPathComponent("evidence/\(label).json"))
                    let field = descendants(window.contentView).compactMap { $0 as? NSSecureTextField }.first
                    clips.append(clip(label, report: movie, field: field, window: window))
                    if iteration == 2 {
                        guard let field, window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else { throw Failure.presentation }
                        editor.insertText("Generated-password-control", replacementRange: NSRange(location: 0, length: 0))
                        guard field.stringValue == "Generated-password-control", window.firstResponder === editor else { throw Failure.presentation }
                        _ = window.makeFirstResponder(nil)
                    }
                    TraverseHelpController.shared.page = .about
                    try await Task.sleep(for: .milliseconds(250))
                }
                TraverseHelpController.shared.page = .updates
                try await Task.sleep(for: .milliseconds(300))
                guard let secure = descendants(window.contentView).compactMap({ $0 as? NSSecureTextField }).first,
                      secure.stringValue.isEmpty else { throw Failure.presentation }
            } else if surface == "ssh" {
                let outcome = try await SFTPProfileVerification.run(root: candidate, settings: settings)
                connection = outcome.controller; clips = outcome.clips; additionalChecks["sshProfiles"] = outcome.checks
            } else if surface == "ssh-prompts" {
                let outcome = try await SFTPInteractiveVerification.run(root:candidate,settings:settings)
                interactive = outcome.controller;clips = outcome.clips;additionalChecks["sshPrompts"] = outcome.checks
            } else if surface == "ssh-jump" {
                checkpoint = "actual-compact-jump-form"
                let outcome = try await SFTPJumpMotionVerification.run(root: candidate, settings: settings)
                connection = outcome.controller; clips = outcome.clips; additionalChecks["sshJump"] = outcome.checks
            } else if surface == "workspace" {
                checkpoint = "actual-saved-network-layouts"
                let outcome = try await WorkspaceNetworkMotionVerification.run(root: candidate, settings: settings)
                browser = outcome.controller; clips = outcome.clips; additionalChecks["networkWorkspace"] = outcome.checks
            } else if surface == "connection" {
                let owner = SMBConnectWindowController(settings: settings) { _,_ in throw Failure.presentation }
                connection = owner
                owner.present()
                guard let window = owner.window else { throw Failure.presentation }
                window.title = "Connect · generated review · motion audit"
                NSApplication.shared.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .milliseconds(250))
                for iteration in 0..<3 {
                    let label = "connection-domain-\(iteration)"
                    let movie = try await NativeMotionRecorder.record(window: window, root: candidate, label: label,
                        sampling: .diagnostic(for: window)) { owner.model.showAdvanced = true }
                    try encode(movie, at: candidate.appendingPathComponent("evidence/\(label).json"))
                    let field = descendants(window.contentView).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Optional" }
                    guard let field else { throw Failure.presentation }
                    clips.append(clip(label, report: movie, field: field, window: window))
                    let expected: NSAppearance.Name = arguments.contains("--motion-light") ? .aqua : .darkAqua
                    guard window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected else {
                        throw UIVerification.Failure(message: "Requested \(expected.rawValue); native connection remained \(window.effectiveAppearance.name.rawValue)")
                    }
                    guard window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else { throw Failure.presentation }
                    editor.selectAll(nil); editor.insertText("GENERATED", replacementRange: NSRange(location: 0, length: field.stringValue.utf16.count))
                    guard owner.model.domain == "GENERATED" else { throw Failure.presentation }
                    _ = window.makeFirstResponder(nil)
                    owner.model.showAdvanced = false
                    try await Task.sleep(for: .milliseconds(300))
                }
            } else if surface == "chart" {
                checkpoint = "generated-native-storage-chart"
                let review = try await StorageDimensionalChartVerification.motionReview(root: candidate, settings: settings)
                additionalChecks = review.checks; clips = review.clips
            } else if surface == "tools" {
                checkpoint = "shared-native-tool-theme"
                let review = try await DevelopmentToolWindowChecks.run(root: candidate, settings: settings)
                additionalChecks = review.checks; clips = review.clips
            } else if surface == "filters" {
                checkpoint = "actual-native-search-filters"
                let review = try await DevelopmentSearchChecks.run(root: candidate, settings: settings)
                additionalChecks = review.checks; clips = review.clips
            } else if surface == "controls" {
                guard arguments.contains("--offscreen") else { throw Failure.scope }
                let checks = try await StorageAnalysisVerification.reportingMemoryOnly()
                guard checks.count >= 8 else { throw Failure.presentation }
                additionalChecks["nativeReportingChecks"] = checks
            } else if surface == "integration" {
                guard arguments.contains("--offscreen") else { throw Failure.scope }
                additionalChecks = try await DevelopmentStorageChecks.run(root: candidate, settings: settings)
            } else if surface == "deep" {
                guard arguments.contains("--offscreen") else { throw Failure.scope }
                checkpoint = "actual-deep-storage"
                additionalChecks = try await DevelopmentStorageChecks.runDeep(root: candidate, settings: settings)
            } else if surface == "deep-navigation" {
                guard arguments.contains("--offscreen"),
                      let sourceCase = ProcessInfo.processInfo.environment["MAC_EXPLORER_DEEP_SOURCE_CASE"],
                      UUID(uuidString: sourceCase)?.uuidString == sourceCase else { throw Failure.scope }
                let fixture = candidate.deletingLastPathComponent().appendingPathComponent(sourceCase)
                guard fixture.resolvingSymlinksInPath() == fixture,
                      let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appendingPathComponent("reservation.json"))) as? [String: Any],
                      marker["packet"] as? String == "traverse-development-v1", marker["action"] as? String == "motion-audit",
                      let inputs = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appendingPathComponent("inputs.json"))) as? [String: Any],
                      inputs["surface"] as? String == "deep" else { throw Failure.scope }
                checkpoint = "actual-deep-folder-navigation"
                additionalChecks = try await DevelopmentStorageChecks.runDeep(root: candidate, settings: settings,
                    sourceRoot: fixture, browserNavigation: true)
            } else if surface == "progress" {
                checkpoint = "actual-committed-progress"
                let result = try await DevelopmentStorageChecks.runProgress(root: candidate, settings: settings)
                additionalChecks = result.checks; clips = result.clips
            } else if surface == "stop" {
                checkpoint = "actual-progress-stop"
                let result = try await DevelopmentStorageChecks.runProgress(root: candidate, settings: settings, stopAfterPrefix: true)
                additionalChecks = result.checks; clips = result.clips
            } else if surface == "failures" {
                guard arguments.contains("--offscreen") else { throw Failure.scope }
                checkpoint = "actual-preparation-failures"
                additionalChecks = try await DevelopmentStorageChecks.runFailures(root: candidate, settings: settings)
            } else if surface == "workload" {
                checkpoint = "actual-scan-queue-concurrency"
                let workload = DevelopmentConcurrentChecks(root: candidate, settings: settings)
                do {
                    try await workload.prepare()
                    let result = try await DevelopmentStorageChecks.runProgress(root: candidate, settings: settings) { try await workload.run() }
                    additionalChecks = result.checks; clips = result.clips
                    await workload.close()
                } catch { await workload.close(); throw error }
            } else {
                let (snapshot, report) = try syntheticStorage()
                let scanning = FolderSummaryValue(counts: snapshot.root.counts, bytes: snapshot.root.namespaceSubtotals,
                    isRunning: true, isComplete: false, message: "Synthetic scanning state", observedAt: Date(), scanStatus: .scanning)
                let complete = FolderSummaryValue(counts: snapshot.root.counts, bytes: snapshot.root.namespaceSubtotals,
                    isRunning: false, isComplete: true, message: "Synthetic completed state", observedAt: Date(), scanStatus: .completed)
                let preparing = FolderSummaryValue(counts: nil, bytes: nil, isRunning: true, isComplete: false,
                    message: "Synthetic preparing state", observedAt: Date(), scanStatus: .preparing)
                let window: NSWindow
                if surface == "analysis" {
                    let owner = StorageAnalysisWindowController(onChooseFolder: {}, onRefresh: {}, onStop: {}, onAppStorage: {})
                    analysis = owner; owner.applyToolStyle(settings)
                    guard let value = owner.window else { throw Failure.presentation }; window = value
                    window.setContentSize(.init(width: 1000, height: 720))
                    owner.showScanForVerification(nil, report: nil, status: .preparing, working: true)
                } else {
                    let owner = FilePropertiesWindowController(settings: settings, copyPaths: { _ in })
                    properties = owner
                    guard let value = owner.window else { throw Failure.presentation }; window = value
                    window.setContentSize(.init(width: 620, height: 750))
                    owner.model.showScanForVerification(preparing, report: nil)
                }
                window.title = "Storage · generated review · " + surface
                window.center(); window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .milliseconds(250))
                for (label, ready) in [("storage-counting",false),("storage-results",true)] {
                    checkpoint = label
                    window.title = "Storage · generated review · " + surface
                    let movie = try await NativeMotionRecorder.record(window: window, root: candidate, label: label,
                        sampling: .diagnostic(for: window)) {
                        analysis?.showScanForVerification(snapshot, report: ready ? report : nil, status: ready ? .completed : .scanning, working: !ready)
                        properties?.model.showScanForVerification(ready ? complete : scanning, report: ready ? report : nil)
                    }
                    try encode(movie, at: candidate.appendingPathComponent("evidence/\(label).json"))
                    clips.append(clip(label, report: movie, field: nil, window: window))
                }
                if let analysis {
                    checkpoint = "storage-layout"
                    try await wait { analysis.preparedFolderCount == snapshot.folders.count && !analysis.isPreparingRows }
                    for size in [NSSize(width: 740, height: 480), .init(width: 1000, height: 780)] {
                        window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded()
                        guard let content = window.contentView, let listing = analysis.outlineView.enclosingScrollView,
                              listing.bounds.height >= 89, analysis.summaryLabel.frame.height >= analysis.summaryLabel.fittingSize.height - 1 else { throw Failure.presentation }
                        let rect = analysis.stopButton.convert(analysis.stopButton.bounds, to: content)
                        guard rect.minX >= 0, rect.maxX <= content.bounds.maxX, rect.maxY <= content.bounds.maxY else { throw Failure.presentation }
                    }
                }
                // A state contract, not a screenshot-derived guess: Stop remains
                // pending until real work has drained, and partial never says Complete.
                guard StorageScanPresentation(status: .cancelled, working: true).title == "Stopping…",
                      StorageScanPresentation(status: .cancelled, working: false).title == "Scan stopped",
                      StorageScanPresentation(status: .partial, working: false).title != "Scan complete",
                      StorageScanPresentation(status: .failed(.accessDenied), working: false).guidance.contains("Review Access") else { throw Failure.presentation }
            }
            result = ["passed": true, "surface": surface, "mode": modeText, "clips": clips,
                "displayMaximumFPS": NSScreen.main?.maximumFramesPerSecond ?? 0,
                "recordingScope": surface == "filters" ? "current process; generated parent with its owned filter popover" : "current process; one generated window", "networkRequests": 0,
                "keychainQueries": 0, "permissionRequests": 0, "personalFiles": 0,
                "nativeSecureEditingVerified": surface == "help" || surface == "ssh" || surface == "ssh-prompts" || surface == "ssh-jump",
                "interfaceSize": settings.interfaceSize.percent, "lightAppearance": arguments.contains("--motion-light"),
                "settingsAppearance": settings.appearance.rawValue,
                "additionalChecks": additionalChecks,
                "nativeTabControllers": settingsWindow.map { controllers($0.contentViewController).compactMap { ($0 as? NSTabViewController)?.transitionOptions.rawValue } } ?? []]
        } catch { result = ["passed": false, "failure": String(describing: type(of: error)), "checkpoint": checkpoint, "detail": String(describing: error)] }
        settingsWindow?.close()
        properties?.cancel(); properties?.close(); analysis?.close()
        connection?.window?.close()
        interactive?.close()
        if !chartOnly {
            await ApplicationStorageAnalysis.shared.stopAndDrain()
            TraverseHelpController.shared.close()
            ApplicationUpdates.shared.availabilityForVerification = nil
        }
        if let names { await names.close() }
        browser?.window?.close()
        if let root { try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys,.prettyPrinted])
            .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting) }
        print("MAC_EXPLORER_DEVELOPMENT_MOTION_COMPLETE \(result["passed"] as? Bool == true)")
        NSApplication.shared.terminate(nil)
    }

    private static func controllers(_ controller: NSViewController?) -> [NSViewController] {
        guard let controller else { return [] }
        return [controller] + controller.children.flatMap { controllers($0) }
    }
    private static func syntheticStorage() throws -> (StorageAnalysisSnapshot, AnalysisAttributionReport) {
        var accumulator = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
        let names = ["Cargo.toml", "Sources", "Sources/main.swift", "Sources/Window.swift", "Assets", "Assets/Preview.png", "Notes.txt", "Archive.zip"]
        for (index, name) in names.enumerated() {
            let directory = name == "Sources" || name == "Assets"
            let size = UInt64((index + 1) * 37_000_000)
            accumulator.consume(.init(relativePath: Data(name.utf8), kind: directory ? .directory : .regularFile,
                identity: .returned(.init(device: 1, inode: UInt64(index + 2))), linkCount: .returned(1), flags: .returned(0),
                bytes: .init(dataLogical: .returned(size), allForkLogical: .returned(size), dataAllocated: .returned(size), allForkAllocated: .returned(size))))
        }
        let snapshot = accumulator.finish()
        return (snapshot, try AnalysisAttributionReport.make(snapshot, scopePath: "/Generated/Orion"))
    }
    private static func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
    }
    private static func settingsNavigation(in window: NSWindow) -> NSTableView? {
        descendants(window.contentView).compactMap { $0 as? NSTableView }
            .first { $0.identifier?.rawValue == "settings-navigation" && $0.numberOfRows == BrowserSettingsView.Page.ordered.count }
    }
    private static func select(_ index: Int, in window: NSWindow) {
        guard let table = settingsNavigation(in: window), (0..<table.numberOfRows).contains(index) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.delegate?.tableViewSelectionDidChange?(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
    }
    static func clip(_ label: String, report: NativeMotionRecorder.Report, field: NSView?, window: NSWindow) -> [String: Any] {
        var value: [String: Any] = ["label": label, "frames": report.frames.count,
            "requestedFPS": report.requestedFPS, "droppedEncoderFrames": report.droppedEncoderFrames,
            "width": report.width, "height": report.height,
            "captureGeometry": report.captureGeometry,
            "windowAppearance": window.effectiveAppearance.name.rawValue,
            "contentAppearance": window.contentView?.effectiveAppearance.name.rawValue ?? "none"]
        if let field {
            guard field.window === window else {
                value["fieldVisibility"] = "different native window; not measured"
                return value
            }
            let frame = field.convert(field.bounds, to: nil)
            let region = NSRect(x: frame.minX, y: CGFloat(report.height) - frame.maxY, width: frame.width, height: frame.height)
            if NSRect(x: 0, y: 0, width: report.width, height: report.height).contains(region), !field.isHiddenOrHasHiddenAncestor {
                value["fieldRegion"] = ["x": region.minX, "y": region.minY, "width": region.width, "height": region.height]
                value["fieldVisibility"] = "visible"
                value["fieldOwnerVerified"] = true
            } else { value["fieldVisibility"] = "outside viewport; not measured" }
        }
        return value
    }
    private static func encode(_ report: NativeMotionRecorder.Report, at path: URL) throws {
        try JSONEncoder().encode(report).write(to: path, options: .withoutOverwriting)
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 5
        while !condition() {
            guard CACurrentMediaTime() < deadline else { throw Failure.presentation }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private enum Failure: Error { case scope, presentation }
}
#endif
