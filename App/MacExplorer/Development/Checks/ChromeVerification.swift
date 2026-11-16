import AppKit
import SwiftUI
import LocalStorage
import ExplorerCore

#if DEBUG
private final class ChromeToolbarNotificationPhase: Sendable {
    let name: String
    init(_ name: String) { self.name = name }
}

private enum ChromeToolbarNotificationScope {
    @TaskLocal static var phase: ChromeToolbarNotificationPhase?
}

@MainActor
private final class ChromeCountingToolbar: NSToolbar {
    var phaseCounts: [String: Int] = [:]
    var untaggedCount = 0

    override func validateVisibleItems() {
        if let phase = ChromeToolbarNotificationScope.phase {
            phaseCounts[phase.name, default: 0] += 1
        } else {
            untaggedCount += 1
        }
        super.validateVisibleItems()
    }
}

@MainActor
extension UIVerification {
    /// Deterministic app-owned paint and actual field-editor geometry. These
    /// checks do not qualify WindowServer glass or subjective optical styling.
    static func verifyChrome(_ browser: BrowserViewController, fixture: URL, output: URL) async throws {
        let args = ProcessInfo.processInfo.arguments
        guard browser.isVerificationSession, args.contains("--check-chrome"),
              fixture.isFileURL, fixture.standardizedFileURL == fixture.resolvingSymlinksInPath().standardizedFileURL,
              fixture.deletingLastPathComponent().lastPathComponent == "fixtures",
              fixture.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".build",
              output.standardizedFileURL == output.resolvingSymlinksInPath().standardizedFileURL,
              output.path.hasPrefix(fixture.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("evidence").path + "/"),
              let window = browser.view.window, let surface = browser.navigationSurface else {
            throw Failure(message: "Chrome verification requires an explicit owned fixture/evidence session")
        }
        browser.navigate(to: .directory(fixture))
        try await settled(browser)
        guard browser.tabs.count == 1,
              let active = browser.tabStrip.selectionButton(for: browser.activeID)?.superview,
              let address = browser.pathField.superview as? AddressSurfaceView,
              let cell = browser.pathField.cell as? NSTextFieldCell else {
            throw Failure(message: "Chrome probe requires one connected tab and the real address field")
        }
        let originalAppearance = NSApp.appearance
        let originalGlass = surface.isGlassEnabled
        let originalResponder = window.firstResponder
        let originalText = browser.pathField.stringValue
        let originalFieldHidden = browser.pathField.isHidden
        let originalPathHidden = browser.pathControl.isHidden
        defer {
            window.makeFirstResponder(browser.table)
            browser.pathField.stringValue = originalText
            browser.pathField.isHidden = originalFieldHidden
            browser.pathControl.isHidden = originalPathHidden
            surface.isGlassEnabled = originalGlass
            NSApp.appearance = originalAppearance
            if let originalResponder, !(originalResponder is NSTextView) { window.makeFirstResponder(originalResponder) }
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        surface.isGlassEnabled = true
        window.contentView?.layoutSubtreeIfNeeded()
        var failures: [String] = []
        var interactionChecks: [[String: Any]] = []
        if let workspace = browser.workspace {
            do {
                for glass in [false, true] {
                    surface.isGlassEnabled = glass
                    for visible in [true, false, true, false] {
                        if visible { browser.metadataSearch.show() }
                        else { browser.metadataSearch.cancel(restoreFolder: false) }
                        window.contentView?.layoutSubtreeIfNeeded()
                        let expected: CGFloat = visible ? 118 : 78
                        try require(abs(surface.bounds.height - expected) <= 0.5,
                            "Search visibility changed the navigation row's settled height")
                    }
                }
                surface.isGlassEnabled = true
                let pointerResult = try await verifySidebarAndFilledAddress(workspace, browser: browser, window: window, fixture: fixture, output: output)
                try verifyBreadcrumbWidthCases(window: window, fixture: fixture)
                interactionChecks = pointerResult.checks
                failures += pointerResult.failures
            } catch {
                failures.append("Sidebar/address pointer regression: \(error)")
            }
        } else {
            failures.append("Sidebar/address pointer regression requires the real workspace")
        }
        do {
            interactionChecks.append(try await verifyCompactFolderFilter(browser, fixture: fixture, output: output))
        } catch {
            failures.append("Folder-filter regression: \(error)")
        }
        do {
            interactionChecks.append(try await verifyWindowNotificationScope(browser, output: output))
        } catch {
            failures.append("Window-key observation scope regression: \(error)")
        }
        do {
            if args.contains("--offscreen") {
                interactionChecks.append(["check": "Cold visible Settings content transitions", "exercised": false,
                    "reason": "Requires the explicit foreground Chrome session"])
            } else {
                interactionChecks.append(try await verifyColdSettingsTransitions(browser, output: output))
            }
        } catch {
            failures.append("Cold Settings transition regression: \(error)")
        }
        do {
            interactionChecks.append(try await verifySettingsWindowStartup(browser,
                interactive: !args.contains("--offscreen"), output: output))
        } catch {
            failures.append("Settings startup regression: \(error)")
        }
        for style in NavigationStyle.allCases {
            for enabled in [false, true] {
                for reduce in [false, true] {
                    for contrast in [false, true] {
                        let actual = BrowserMaterialPolicy.glassEnabled(style: style, enabled: enabled,
                            reduceTransparency: reduce, increaseContrast: contrast)
                        if actual != (style == .glass && enabled && !reduce && !contrast) {
                            failures.append("Material policy did not honor master/area/accessibility priority")
                        }
                    }
                }
            }
        }
        let legacy = BrowserSettings(persist: false, restoredData: Data(#"{"version":3,"navigationStyle":"Solid","showsSizeColumn":false}"#.utf8))
        if legacy.navigationStyle != .solid || legacy.showsSizeColumn || !legacy.glassNavigation
            || !legacy.glassSidebar || !legacy.glassStatusBar || legacy.glassFileContent
            || legacy.restoresSession || !legacy.autoRefreshFolders {
            failures.append("Legacy preferences lost old choices or safe new defaults")
        }
        legacy.glassNavigation = false
        legacy.glassSidebar = false
        legacy.glassStatusBar = false
        legacy.glassFileContent = true
        legacy.restoresSession = true
        legacy.autoRefreshFolders = false
        let encoded = try legacy.encodedSnapshot()
        let roundtrip = BrowserSettings(persist: false, restoredData: encoded)
        if roundtrip.glassNavigation || roundtrip.glassSidebar || roundtrip.glassStatusBar
            || !roundtrip.glassFileContent || !roundtrip.restoresSession || roundtrip.autoRefreshFolders {
            failures.append("New area/session/refresh preferences did not round-trip")
        }
        if (try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["version"] as? Int != 15 {
            failures.append("Current preference schema is not version 15")
        }
        let activePaint = try chromePaint(active) { active.draw(active.bounds) }
        let addressPaint = try chromePaint(address) { address.draw(address.bounds) }
        let activeAlpha = try chromeAlpha(activePaint, at: NSPoint(x: 5, y: active.bounds.midY))
        let addressAlpha = try chromeAlpha(addressPaint, at: NSPoint(x: 8, y: address.bounds.midY))
        // Sample actual custom fills without child controls or borders. A
        // native/semantic translucent treatment must not paint an opaque slab.
        if activeAlpha >= 0.99 { failures.append("Selected dark tab paints an opaque background over Glass") }
        if addressAlpha >= 0.99 { failures.append("Dark address surface paints an opaque background over Glass") }
        try await snapshot(window, to: output.appendingPathComponent("chrome-dark-display.png"))

        browser.pathField.stringValue = "Generated Agjp 012345"
        let titleRect = cell.titleRect(forBounds: browser.pathField.bounds)
        let drawingRect = cell.drawingRect(forBounds: browser.pathField.bounds)
        var tinyCellRows: [[String: Any]] = []
        var tinyCellPassed = true
        func cellNumbers(_ rect: NSRect) -> [Double] {
            [Double(rect.origin.x), Double(rect.origin.y), Double(rect.size.width), Double(rect.size.height)]
        }
        for width: CGFloat in [0, 1, 2, 300] {
            for height: CGFloat in [0, 1, 2, 22, 30, 44] {
                let bounds = NSRect(x: 0, y: 0, width: width, height: height)
                let drawing = cell.drawingRect(forBounds: bounds)
                let title = cell.titleRect(forBounds: bounds)
                let passed = [drawing, title].allSatisfy { rect in
                    cellNumbers(rect).allSatisfy(\.isFinite)
                        && rect.size.width >= 0 && rect.size.height >= 0
                        && rect.minX >= bounds.minX - 0.001 && rect.minY >= bounds.minY - 0.001
                        && rect.maxX <= bounds.maxX + 0.001 && rect.maxY <= bounds.maxY + 0.001
                }
                tinyCellPassed = tinyCellPassed && passed
                tinyCellRows.append(["bounds": cellNumbers(bounds), "drawing": cellNumbers(drawing),
                                     "title": cellNumbers(title), "passed": passed])
            }
        }
        try JSONSerialization.data(withJSONObject: ["cases": tinyCellRows, "passed": tinyCellPassed,
            "scope": "Actual address cell numerical input/output; ordinary native display/editor checks follow; live Xcode warning cause unqualified"],
            options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("address-cell-tiny-geometry.json"), options: .withoutOverwriting)
        if !tinyCellPassed { failures.append("Address cell returned invalid or escaping geometry for a tiny allocation; numeric observations were preserved") }
        for height in [CGFloat(22), 30, 44] {
            let bounds = NSRect(x: 0, y: 0, width: 300, height: height)
            let rect = cell.drawingRect(forBounds: bounds)
            if abs(rect.midY - bounds.midY) > 0.5 || !bounds.contains(rect) {
                failures.append("Address cell did not center native line metrics at field height \(height)")
            }
        }
        browser.pathField.isHidden = false
        browser.pathControl.isHidden = true
        window.makeFirstResponder(browser.table)
        browser.pathField.needsDisplay = true
        window.contentView?.layoutSubtreeIfNeeded()
        // AppKit supplies the actual control's flipped drawing context and
        // single-line renderer. A direct cell draw into an unflipped bitmap
        // does not represent how this field is displayed in the window.
        let textPaint = try chromePaint(browser.pathField) {}
        browser.pathField.cacheDisplay(in: browser.pathField.bounds, to: textPaint)
        if let png = textPaint.representation(using: .png, properties: [:]) {
            try png.write(to: output.appendingPathComponent("chrome-native-display-cell.png"), options: .withoutOverwriting)
        }
        let ink = chromeInkBounds(textPaint)
        let drawingInkOffset = ink.map { abs($0.midY - browser.pathField.bounds.midY) }
        if let drawingInkOffset, drawingInkOffset > 1.5 {
            failures.append("Address display glyphs are not centered in the field (\(drawingInkOffset) points)")
        }
        if ink == nil { failures.append("Address cell did not produce measurable display glyphs") }

        browser.focusLocation(nil)
        browser.pathField.stringValue = "Generated Agjp 012345"
        window.contentView?.layoutSubtreeIfNeeded()
        guard let editor = browser.pathField.currentEditor() as? NSTextView,
              let layout = editor.layoutManager, let container = editor.textContainer else {
            throw Failure(message: "Native address field editor unavailable; text alignment was not exercised")
        }
        editor.string = browser.pathField.stringValue
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(for: container)
        guard glyphs.length > 0 else { throw Failure(message: "Address editor contains no laid-out glyphs") }
        let line = layout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let origin = editor.textContainerOrigin
        let editorLine = editor.convert(line.offsetBy(dx: origin.x, dy: origin.y), to: browser.pathField)
        let editorCenterOffset = abs(editorLine.midY - browser.pathField.bounds.midY)
        if editorCenterOffset > 1 {
            failures.append("Actual address editor text line is not vertically centered (\(editorCenterOffset) points)")
        }
        if !browser.pathField.bounds.insetBy(dx: -1, dy: -1).contains(editorLine) {
            failures.append("Actual address editor text line extends outside its field")
        }
        try await snapshot(window, to: output.appendingPathComponent("chrome-dark-edit.png"))
        let report: [String: Any] = [
            "passed": failures.isEmpty, "failures": failures, "pointerInteractionChecks": interactionChecks,
            "mode": "native-custom-paint-and-field-editor-geometry",
            "activeTabFillAlpha": activeAlpha, "addressFillAlpha": addressAlpha,
            "fieldBounds": NSStringFromRect(browser.pathField.bounds),
            "cellTitleRect": NSStringFromRect(titleRect), "cellDrawingRect": NSStringFromRect(drawingRect),
            "displayInkBounds": ink.map(NSStringFromRect) ?? "unavailable",
            "displayCaptureMethod": "Actual visible NSTextField cacheDisplay with native flipped context",
            "displayInkCenterOffset": drawingInkOffset ?? -1,
            "editorLineInField": NSStringFromRect(editorLine), "editorLineCenterOffset": editorCenterOffset,
            "editorContainerOrigin": NSStringFromPoint(origin),
            "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            "increaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            "notExercised": ["WindowServer material transmission", "Changed system accessibility settings", "Subjective optical appearance", "Physical pointer delivery and hidden-window NSButton mouse tracking", "Physical ancestor-menu keyboard traversal and VoiceOver client interaction"],
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let reportURL = output.appendingPathComponent("chrome-verification.json")
        try await Task.detached { try data.write(to: reportURL, options: .atomic) }.value
        try require(failures.isEmpty, failures.joined(separator: "; "))
    }

    /// Exercise the actual browser notification handler and native toolbar.
    /// A weak phase token proves every Task that inherited its tag has finished;
    /// positive controls reject missing tag propagation instead of passing zero.
    private static func verifyWindowNotificationScope(_ browser: BrowserViewController,
        output: URL) async throws -> [String: Any] {
        guard browser.isVerificationSession, let window = browser.view.window,
              ProcessInfo.processInfo.arguments.contains("--check-chrome") else {
            throw Failure(message: "Window notification scope requires the generated Chrome browser")
        }
        final class WeakPhase {
            weak var value: ChromeToolbarNotificationPhase?
            init(_ value: ChromeToolbarNotificationPhase) { self.value = value }
        }
        let originalToolbar = window.toolbar
        let counter = ChromeCountingToolbar(identifier: "MacExplorer.Chrome.WindowNotificationScope")
        counter.isVisible = false
        counter.autosavesConfiguration = false
        window.toolbar = counter
        defer { window.toolbar = originalToolbar }
        let unrelated = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        unrelated.isReleasedWhenClosed = false
        defer { unrelated.close() }

        func post(_ phaseName: String, object: NSWindow) -> WeakPhase {
            let phase = ChromeToolbarNotificationPhase(phaseName)
            let weakPhase = WeakPhase(phase)
            ChromeToolbarNotificationScope.$phase.withValue(phase) {
                NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: object)
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: object)
            }
            return weakPhase
        }
        var phases: [[String: Any]] = []
        var counts: [Int] = []
        var allDrained = true
        for (name, object) in [("own-before", window), ("unrelated", unrelated), ("own-after", window)] {
            let untaggedBefore = counter.untaggedCount
            let token = post(name, object: object)
            let deadline = Date().addingTimeInterval(2)
            while token.value != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let drained = token.value == nil
            let calls = counter.phaseCounts[name, default: 0]
            allDrained = allDrained && drained
            counts.append(calls)
            phases.append(["phase": name, "nativeToolbarValidations": calls,
                "inheritedPhaseLifetimeDrained": drained,
                "untaggedAutomaticValidations": counter.untaggedCount - untaggedBefore,
                "browserWindowStillAttached": browser.view.window === window,
                "counterStillInstalled": window.toolbar === counter,
                "unrelatedWindowVisible": unrelated.isVisible])
            try JSONSerialization.data(withJSONObject: ["phases": phases,
                "mechanism": "Native NSToolbar override; inherited TaskLocal tag lifetime, not a timed zero-count assertion",
                "postedNames": [NSWindow.didBecomeKeyNotification.rawValue, NSWindow.didResignKeyNotification.rawValue],
                "untaggedTotal": counter.untaggedCount,
                "physicalActivationExercised": false,
                "negativeGeometryCausalityEstablished": false], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("window-key-notification-scope.json"), options: .atomic)
            if !drained { break }
        }
        try require(allDrained && counts.count == 3,
            "Window notification callbacks did not release their inherited phase; zero counts are unqualified")
        try require(counts[0] > 0 && counts[2] > 0,
            "Own-window native toolbar controls did not validate with inherited tags; unrelated zero is unqualified")
        try require(browser.view.window === window && window.toolbar === counter && !unrelated.isVisible,
            "Window notification scope lost its owned native controls")
        try require(counts[1] == 0, "Unrelated window key notifications validated the browser toolbar")
        return ["check": "Window-key notifications stay within their browser window",
            "ownBeforeValidations": counts[0], "unrelatedValidations": counts[1],
            "ownAfterValidations": counts[2], "inheritedCallbacksDrained": true,
            "physicalActivationExercised": false, "negativeGeometryCausalityEstablished": false]
    }

    /// The production factory does not premeasure or cache-render a Settings
    /// page. Keep this visible cold transition distinct from the startup suite.
    private static func verifyColdSettingsTransitions(_ browser: BrowserViewController, output: URL) async throws -> [String: Any] {
        guard browser.isVerificationSession, !browser.isControlledVerification,
              ProcessInfo.processInfo.arguments.contains("--check-chrome") else {
            throw Failure(message: "Cold Settings transitions require an explicit foreground verification session")
        }
        let settings = BrowserSettings(persist: false)
        settings.appearance = .dark
        settings.navigationStyle = .glass
        settings.glassNavigation = true
        settings.glassSidebar = true
        settings.glassStatusBar = true
        settings.glassFileContent = true
        let originalKey = NSApp.keyWindow
        final class FormLifecycle {
            weak var window: NSWindow?
            var visible = [false, false]
            var appeared = [0, 0]
            var disappeared = [0, 0]
            var eventCount = 0
            var exceeded = false
            var accepting = true
        }
        let lifecycle = FormLifecycle()
        var settingsView = BrowserSettingsView(settings: settings, initialPage: .general)
        settingsView.onPageVisibilityForVerification = { page, appeared in
            guard lifecycle.accepting else { return }
            guard lifecycle.eventCount < 32 else { lifecycle.exceeded = true; return }
            let index: Int
            switch page {
            case .general: index = 0
            case .appearance: index = 1
            default: lifecycle.exceeded = true; return
            }
            lifecycle.eventCount += 1
            lifecycle.visible[index] = appeared
            if appeared { lifecycle.appeared[index] += 1 }
            else { lifecycle.disappeared[index] += 1 }
        }
        try FileHandle.standardOutput.write(contentsOf: Data("MacExplorerSettingsCold begin-create\n".utf8))
        let window = BrowserSettingsWindow.make(settingsView)
        lifecycle.window = window
        window.appearance = NSAppearance(named: .darkAqua)
        defer {
            lifecycle.accepting = false
            window.close()
            if let originalKey, originalKey.isVisible { originalKey.makeKeyAndOrderFront(nil) }
        }
        window.center(); window.makeKeyAndOrderFront(nil)
        let titles = ["General", "Appearance", "Keyboard", "Operations", "Privacy"]
        var traversalExceeded = false
        func views(_ root: NSView) -> [NSView] {
            var pending = [root], found: [NSView] = []
            while let next = pending.popLast() {
                guard found.count + pending.count + next.subviews.count < 512 else { traversalExceeded = true; return found }
                found.append(next); pending.append(contentsOf: next.subviews)
            }
            return found
        }
        func tabs() -> NSSegmentedControl? {
            guard let root = window.contentView?.superview else { return nil }
            let matches = views(root).compactMap { $0 as? NSSegmentedControl }.filter { control in
                control.segmentCount == titles.count && titles.indices.allSatisfy { control.label(forSegment: $0) == titles[$0] }
            }
            return matches.count == 1 ? matches.first : nil
        }
        func pageReady(_ index: Int) -> Bool {
            lifecycle.window === window && !lifecycle.exceeded && window.isVisible && window.isKeyWindow
                && NSApp.isActive && tabs()?.selectedSegment == index
                && lifecycle.visible[index] && !lifecycle.visible[1 - index]
                && lifecycle.appeared[index] > 0
        }
        func awaitPage(_ index: Int) async throws -> Bool {
            let deadline = Date().addingTimeInterval(8)
            while !pageReady(index), !traversalExceeded, !lifecycle.exceeded, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
            return !traversalExceeded && !lifecycle.exceeded && pageReady(index)
        }
        var observations: [[String: Any]] = []
        func retain(_ phase: Int, expected: Int, actionDelivered: Bool, ready: Bool) throws -> Bool {
            let frames = window.contentView.map { views($0.superview ?? $0) } ?? []
            let geometry = frames.allSatisfy { view in
                [view.frame.width, view.frame.height, view.bounds.width, view.bounds.height].allSatisfy { $0.isFinite && $0 >= 0 }
            }
            let allocation = window.contentView.map {
                abs($0.bounds.width - BrowserSettingsWindow.contentSize.width) <= 0.5
                    && abs($0.bounds.height - BrowserSettingsWindow.contentSize.height) <= 0.5
            } ?? false
            observations.append(["phase": phase, "expectedPage": expected, "selectedSegment": tabs()?.selectedSegment ?? -1,
                "actionDelivered": actionDelivered, "formLifecycleReady": ready,
                "generalFormVisible": lifecycle.visible[0], "appearanceFormVisible": lifecycle.visible[1],
                "generalAppearCount": lifecycle.appeared[0], "generalDisappearCount": lifecycle.disappeared[0],
                "appearanceAppearCount": lifecycle.appeared[1], "appearanceDisappearCount": lifecycle.disappeared[1],
                "lifecycleEventCount": lifecycle.eventCount, "lifecycleBoundExceeded": lifecycle.exceeded,
                "traversalLimitExceeded": traversalExceeded, "settledGeometryFiniteNonnegative": geometry,
                "fixedAllocation": allocation,
                "contentBounds": window.contentView.map { NSStringFromRect($0.bounds) } ?? "unavailable",
                "visible": window.isVisible, "key": window.isKeyWindow, "active": NSApp.isActive])
            try JSONSerialization.data(withJSONObject: ["phases": observations,
                "preTransitionSizeThatFits": false, "preTransitionCacheDisplay": false,
                "isolatedDarkSettings": true, "isolatedAllGlassOptions": true,
                "contentObservation": "Actual General/Appearance Form onAppear/onDisappear; final screenshot after all actions",
                "accessibilityContentTraversalExercised": false,
                "physicalPointerExercised": false,
                "transientGeometryEvidence": "Captured parent stderr and phase markers; final frames cannot detect a standardized negative request"],
                options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("settings-cold-transitions.json"), options: .atomic)
            return geometry && allocation && !traversalExceeded && !lifecycle.exceeded
        }
        let initialReady = try await awaitPage(0)
        let initialGeometry = try retain(0, expected: 0, actionDelivered: false, ready: initialReady)
        try require(initialReady && initialGeometry, "Cold Settings General Form lifecycle or allocation did not materialize in its visible window")
        try FileHandle.standardOutput.write(contentsOf: Data("MacExplorerSettingsCold end-create\n".utf8))
        for (offset, index) in [1, 0, 1, 0].enumerated() {
            let phase = offset + 1
            let priorAppeared = lifecycle.appeared[index]
            let priorOppositeDisappeared = lifecycle.disappeared[1 - index]
            try FileHandle.standardOutput.write(contentsOf: Data("MacExplorerSettingsCold begin phase=\(phase) page=\(index)\n".utf8))
            guard let control = tabs(), let action = control.action, control.isEnabled, control.isEnabled(forSegment: index) else {
                throw Failure(message: "Cold Settings has no enabled native tab action")
            }
            control.selectedSegment = index
            let delivered = control.sendAction(action, to: control.target)
            let ready = try await awaitPage(index)
                && lifecycle.appeared[index] > priorAppeared
                && lifecycle.disappeared[1 - index] > priorOppositeDisappeared
            let geometry = try retain(phase, expected: index, actionDelivered: delivered, ready: ready)
            try FileHandle.standardOutput.write(contentsOf: Data("MacExplorerSettingsCold end phase=\(phase) page=\(index) ready=\(ready ? 1 : 0)\n".utf8))
            try require(delivered && ready && geometry, "Cold Settings selection did not complete the expected Form lifecycle and allocation")
        }
        // Capture only after all unprimed transitions and their observations.
        try await snapshot(window, to: output.appendingPathComponent("settings-cold-final-general.png"))
        return ["check": "Cold visible Settings General/Appearance content transitions", "exercised": true,
            "nativeSelections": 4, "actualFormLifecycleVerified": true, "accessibilityContentTraversalExercised": false,
            "preTransitionSizeThatFits": false,
            "preTransitionCacheDisplay": false, "runtimeDiagnosticsRequired": true, "physicalPointerExercised": false]
    }

    /// Exercise the exact fixed Settings factory and actual native tabs. The
    /// parent must also retain/reject startup console diagnostics: settled frames
    /// cannot prove that AppKit never received a transient negative allocation.
    private static func verifySettingsWindowStartup(_ browser: BrowserViewController,
        interactive: Bool, output: URL) async throws -> [String: Any] {
        guard browser.isVerificationSession, let workspace = browser.workspace,
              ProcessInfo.processInfo.arguments.contains("--check-chrome"),
              !interactive || !browser.isControlledVerification else {
            throw Failure(message: "Settings startup requires the owned Chrome session")
        }
        let pages: [BrowserSettingsView.Page] = [.general, .appearance, .keyboard, .operations, .privacy, .permissions]
        let originalKey = NSApp.keyWindow
        var windows: [NSWindow] = []
        defer {
            windows.forEach { $0.close() }
            if interactive, let originalKey, originalKey.isVisible { originalKey.makeKeyAndOrderFront(nil) }
        }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        func validGeometry(_ window: NSWindow) -> Bool {
            guard let content = window.contentView else { return false }
            let expected = BrowserSettingsWindow.contentSize
            return abs(content.bounds.width - expected.width) <= 0.5
                && abs(content.bounds.height - expected.height) <= 0.5
                && descendants(content.superview ?? content).allSatisfy { view in
                    [view.frame.width, view.frame.height, view.bounds.width, view.bounds.height]
                        .allSatisfy { $0.isFinite && $0 >= 0 }
                }
        }
        let pageTitles = ["General", "Appearance", "Keyboard", "Operations", "Privacy"]
        func nativeTabs(_ window: NSWindow) -> NSSegmentedControl? {
            (window.contentView?.superview ?? window.contentView).flatMap {
                let matches = descendants($0).compactMap { $0 as? NSSegmentedControl }.filter { control in
                    control.segmentCount == pageTitles.count
                        && pageTitles.indices.allSatisfy { control.label(forSegment: $0) == pageTitles[$0] }
                }
                return matches.count == 1 ? matches.first : nil
            }
        }
        var selections = 0
        for workspaceView in [false, true] {
            for (initialIndex, page) in pages.enumerated() {
                let settingsView = workspaceView ? workspace.makeWorkspaceSettingsView(initialPage: page)
                    : browser.makeSettingsView(initialPage: page)
                try require(settingsView.settings === browser.settings,
                    "Settings factory lost its live preference binding")
                try FileHandle.standardOutput.write(contentsOf: Data(
                    "MacExplorerSettingsProbe begin factory=\(workspaceView ? 1 : 0) page=\(initialIndex)\n".utf8))
                let window = BrowserSettingsWindow.make(settingsView)
                windows.append(window)
                if interactive { window.center(); window.makeKeyAndOrderFront(nil) }
                else { try require(!window.isVisible, "Hidden Settings probe revealed its window") }
                guard let host = (window.contentViewController as? InterfaceHostingController<BrowserSettingsView>)
                    ?? window.contentViewController?.children.compactMap({ $0 as? InterfaceHostingController<BrowserSettingsView> }).first else {
                    throw Failure(message: "Settings factory lost its typed hosting controller")
                }
                let measured = host.sizeThatFits(in: BrowserSettingsWindow.contentSize)
                try require(measured.width.isFinite && measured.height.isFinite
                    && measured.width > 0 && measured.height > 0,
                    "Settings positive measurement returned invalid dimensions")
                host.view.needsLayout = true
                host.view.layoutSubtreeIfNeeded()
                try FileHandle.standardOutput.write(contentsOf: Data(
                    "MacExplorerSettingsProbe measured width=\(measured.width) height=\(measured.height) visible=\(window.isVisible ? 1 : 0) attached=\(host.view.window === window ? 1 : 0) contentIsHost=\(window.contentView === host.view ? 1 : 0)\n".utf8))
                try await snapshot(window, to: output.appendingPathComponent(
                    "settings-startup-\(workspaceView ? 1 : 0)-\(initialIndex).png"))
                window.contentView?.layoutSubtreeIfNeeded()
                let deadline = Date().addingTimeInterval(8)
                while nativeTabs(window) == nil, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(30))
                    window.contentView?.layoutSubtreeIfNeeded()
                }
                if nativeTabs(window) == nil {
                    let root = window.contentView?.superview ?? host.view
                    let counts = descendants(root).compactMap { $0 as? NSTabView }.map(\.numberOfTabViewItems)
                    let segments = descendants(root).compactMap { $0 as? NSSegmentedControl }.map(\.segmentCount)
                    try FileHandle.standardOutput.write(contentsOf: Data(
                        "MacExplorerSettingsProbe missing nativeTabs=\(counts) nativeSegments=\(segments) hostSubviews=\(host.view.subviews.count)\n".utf8))
                    throw Failure(message: "Settings native tabs did not materialize")
                }
                guard let initialTabs = nativeTabs(window) else {
                    throw Failure(message: "Settings native tabs unavailable")
                }
                var tabs = initialTabs
                try require(tabs.selectedSegment == initialIndex && validGeometry(window),
                    "Settings initial page or native allocation differs")
                for index in pages.indices {
                    guard let action = tabs.action, tabs.window === window,
                          tabs.isEnabled, tabs.isEnabled(forSegment: index) else {
                        throw Failure(message: "Settings tab control has no enabled native action")
                    }
                    tabs.selectedSegment = index
                    try require(tabs.sendAction(action, to: tabs.target), "Settings native tab action was not delivered")
                    await Task.yield()
                    window.contentView?.layoutSubtreeIfNeeded()
                    guard let currentTabs = nativeTabs(window) else { throw Failure(message: "Settings detached its native tabs") }
                    try require(currentTabs.window === window
                        && currentTabs.selectedSegment == index
                        && validGeometry(window), "Settings native tab selection changed geometry")
                    tabs = currentTabs
                    if !workspaceView, initialIndex == 0 {
                        try await snapshot(window, to: output.appendingPathComponent("settings-selection-\(index).png"))
                    }
                    selections += 1
                }
                window.close()
                if interactive { window.makeKeyAndOrderFront(nil) }
                window.contentView?.layoutSubtreeIfNeeded()
                await Task.yield()
                guard let reopenedTabs = nativeTabs(window) else { throw Failure(message: "Settings reopen lost native tabs") }
                try require(validGeometry(window) && reopenedTabs.selectedSegment == 3,
                    "Settings close/reopen lost its allocation or selected page")
                if !interactive { try require(!window.isVisible, "Controlled Settings reopen became visible") }
                window.close()
                try FileHandle.standardOutput.write(contentsOf: Data(
                    "MacExplorerSettingsProbe end factory=\(workspaceView ? 1 : 0) page=\(initialIndex)\n".utf8))
            }
        }
        return ["check": interactive
                ? "Settings fixed host startup, four initial pages, native tab selection and close/reopen"
                : "Settings fixed host startup, four initial pages, native tab selection and post-close retention",
            "windowCycles": windows.count, "nativeSelections": selections, "foregroundWindows": interactive,
            "postCloseRetentionChecks": windows.count, "foregroundReopenCycles": interactive ? windows.count : 0,
            "selectionRoute": "NSSegmentedControl selectedSegment and native sendAction", "physicalKeyboardExercised": false,
            "pageContentEvidence": "Retained initial-page and four action-selected page renders require visual review",
            "transientGeometryAndCoreUI": "Require the separately retained startup console to contain neither diagnostic"]
    }

    /// Native hit testing and path tracking, plus the native edit-button action.
    /// Hidden-window checks explicitly do not qualify physical pointer delivery.
    /// A completely occupied path must still expose an on-screen editing target.
    private static func verifySidebarAndFilledAddress(_ workspace: BrowserWorkspaceController,
        browser: BrowserViewController, window: NSWindow, fixture: URL, output: URL) async throws -> (checks: [[String: Any]], failures: [String]) {
        let originalSize = window.contentView?.bounds.size ?? workspace.view.bounds.size
        let originalLocation = browser.location
        let originalReader = browser.readVolumesForVerification
        let originalVolumes = browser.volumes
        let owned = fixture.deletingLastPathComponent().appendingPathComponent("chrome-address-\(UUID().uuidString)", isDirectory: true)
        let longFolder = owned.appendingPathComponent(String(repeating: "Full address Agjp ", count: 12), isDirectory: true)
        let ancestorParent = owned.appendingPathComponent("Folder A", isDirectory: true)
        let ancestorChild = ancestorParent.appendingPathComponent("Child", isDirectory: true)
        try await Task.detached {
            let manager = FileManager()
            try manager.createDirectory(at: owned, withIntermediateDirectories: false)
            try Data("mac-explorer-chrome-address-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
            try manager.createDirectory(at: longFolder, withIntermediateDirectories: false)
            try manager.createDirectory(at: ancestorChild, withIntermediateDirectories: true)
        }.value
        let generatedVolumes = [VolumeInfo(url: owned, name: "Fixture", kind: .externalDisk)]
        var checks: [[String: Any]] = [], failures: [String] = []
        defer {
            browser.readVolumesForVerification = originalReader
            window.makeFirstResponder(browser.table)
            if browser.location != originalLocation { browser.navigate(to: originalLocation) }
            browser.pathField.isHidden = true; browser.pathControl.isHidden = false
            window.setContentSize(originalSize); window.contentView?.layoutSubtreeIfNeeded()
        }
        func observe(_ volumes: [VolumeInfo]) async throws {
            // Use the real bounded refresh path and its latest-token rejection.
            // Host bootstrap completion cannot decide this fixture's geometry.
            browser.readVolumesForVerification = { volumes }
            await browser.refreshVolumes()
            try require(browser.volumes == volumes, "Chrome fixture volume observation did not complete")
        }
        func restoreObservation() async throws {
            try await observe(originalVolumes)
            browser.readVolumesForVerification = originalReader
        }
        do {
            for width in [CGFloat(820), 1400] {
                try await observe(generatedVolumes)
                browser.navigate(to: .directory(longFolder)); try await settled(browser)
                try require(browser.breadcrumbLocations == [.directory(owned), .directory(longFolder)],
                            "Known generated volume did not produce its exact visible path")
                window.setContentSize(NSSize(width: width, height: 760))
                window.contentView?.layoutSubtreeIfNeeded()
                if abs((window.contentView?.bounds.width ?? 0) - width) > 1 {
                    failures.append("Long hidden bottom breadcrumbs forced window beyond requested width \(width)")
                }
                let before = workspace.sidebarHost.bounds.width
                let boundary = workspace.sidebarHost.convert(NSPoint(x: workspace.sidebarHost.bounds.maxX + 0.5,
                    y: workspace.sidebarHost.bounds.midY), to: nil)
                let hit = window.contentView?.hitTest(window.contentView!.convert(boundary, from: nil))
                let nativeTarget = hit as? NSSplitView
                if let nativeTarget {
                    try chromeDrag(nativeTarget, window: window, from: boundary,
                        to: NSPoint(x: boundary.x + 40, y: boundary.y))
                    window.contentView?.layoutSubtreeIfNeeded()
                }
                let after = workspace.sidebarHost.bounds.width
                if nativeTarget == nil || after <= before + 10 {
                    failures.append("Sidebar boundary has no working native resize hit target at width \(width); before=\(before), after=\(after)")
                }
                if workspace.paneHosts.values.contains(where: { $0.bounds.width < 400 || $0.bounds.height < 220 }) {
                    failures.append("Sidebar resizing violated pane minima at width \(width)")
                }
                guard let pathCell = browser.pathControl.cell as? NSPathCell,
                      let current = pathCell.pathComponentCells.last else { throw Failure(message: "Current native breadcrumb is unavailable") }
                let rawRect = pathCell.rect(of: current, withFrame: browser.pathControl.bounds, in: browser.pathControl)
                let rect = rawRect.intersection(browser.pathControl.bounds)
                let local = NSPoint(x: rect.midX, y: rect.midY)
                let valid = !rect.isEmpty && !rect.isNull && local.x.isFinite && local.y.isFinite
                    && browser.pathControl.bounds.contains(local)
                let occupied = valid && pathCell.pathComponentCell(at: local, withFrame: browser.pathControl.bounds,
                    in: browser.pathControl) === current
                let point = valid ? browser.pathControl.convert(local, to: nil) : .zero
                let dispatchable = occupied && point.x.isFinite && point.y.isFinite
                var editing = false, firstRetainedLocation = false, secondTargetIsCurrent = false
                if dispatchable {
                    chromeClick(browser.pathControl, window: window, at: point, count: 1)
                    try await settled(browser)
                    firstRetainedLocation = browser.location == .directory(longFolder)
                    if firstRetainedLocation, let secondCell = browser.pathControl.cell as? NSPathCell,
                       let secondCurrent = secondCell.pathComponentCells.last {
                        let secondLocal = browser.pathControl.convert(point, from: nil)
                        let secondRect = secondCell.rect(of: secondCurrent, withFrame: browser.pathControl.bounds,
                            in: browser.pathControl).intersection(browser.pathControl.bounds)
                        secondTargetIsCurrent = !secondRect.isEmpty && !secondRect.isNull
                            && secondLocal.x.isFinite && secondLocal.y.isFinite
                            && browser.pathControl.bounds.contains(secondLocal)
                            && secondRect.contains(secondLocal)
                            && secondCell.pathComponentCell(at: secondLocal, withFrame: browser.pathControl.bounds,
                                in: browser.pathControl) === secondCurrent
                        if secondTargetIsCurrent {
                            chromeClick(browser.pathControl, window: window, at: point, count: 2)
                            editing = !browser.pathField.isHidden && browser.pathControl.isHidden
                                && browser.pathField.currentEditor() is NSTextView
                        }
                    }
                }
                if !dispatchable || !firstRetainedLocation || !secondTargetIsCurrent || !editing
                    || browser.location != .directory(longFolder) {
                    failures.append("Fully occupied visible current breadcrumb did not enter native editing without navigation at width \(width)")
                }
                // Typing is an independent case, even if target geometry failed.
                browser.navigate(to: .directory(longFolder)); try await settled(browser)
                let typing = try verifyFilledAddressTyping(workspace, browser: browser, window: window,
                    expected: longFolder, width: width, caseLabel: "Known volume")
                failures += typing.failures
                browser.navigate(to: .directory(ancestorChild)); try await settled(browser)
                guard let ancestorCell = browser.pathControl.cell as? NSPathCell else {
                    throw Failure(message: "Native ancestor breadcrumb cells unavailable after editing")
                }
                var ancestorClickNavigated = false
                for index in ancestorCell.pathComponentCells.indices.dropLast().reversed() {
                    guard browser.pathControl.location(forDisplayedIndex: index) == .directory(ancestorParent) else { continue }
                    let component = ancestorCell.pathComponentCells[index]
                    let rect = ancestorCell.rect(of: component, withFrame: browser.pathControl.bounds,
                        in: browser.pathControl).intersection(browser.pathControl.bounds)
                    let local = NSPoint(x: rect.midX, y: rect.midY)
                    guard !rect.isEmpty, !rect.isNull, local.x.isFinite, local.y.isFinite,
                          browser.pathControl.bounds.contains(local),
                          ancestorCell.pathComponentCell(at: local, withFrame: browser.pathControl.bounds,
                            in: browser.pathControl) === component else { continue }
                    let ancestorPoint = browser.pathControl.convert(local, to: nil)
                    guard ancestorPoint.x.isFinite, ancestorPoint.y.isFinite else { continue }
                    chromeClick(browser.pathControl, window: window, at: ancestorPoint, count: 1)
                    try await settled(browser)
                    ancestorClickNavigated = browser.location == .directory(ancestorParent) && browser.pathField.isHidden
                        && !browser.pathControl.isHidden && typing.button.accessibilityLabel() == "Edit folder path"
                    break
                }
                if !ancestorClickNavigated { failures.append("Single generated ancestor breadcrumb did not immediately navigate at width \(width)") }
                var known: [String: Any] = ["case": "known-generated-volume", "windowWidth": width,
                    "actualWindowWidth": window.contentView?.bounds.width ?? 0, "nativeSidebarHitTarget": nativeTarget != nil,
                    "sidebarWidthBefore": before, "sidebarWidthAfter": after, "occupiedBreadcrumbPoint": occupied,
                    "firstClickRetainedLocation": firstRetainedLocation, "secondTargetIsCurrent": secondTargetIsCurrent,
                    "doubleClickEnteredNativeEditor": editing, "ancestorSingleClickNavigated": ancestorClickNavigated,
                    "currentComponentRawRect": NSStringFromRect(rawRect), "pathBounds": NSStringFromRect(browser.pathControl.bounds)]
                known.merge(typing.checks) { _, value in value }; checks.append(known)
                if width == 820 {
                    browser.navigate(to: .directory(longFolder)); try await settled(browser)
                    try await snapshot(window, to: output.appendingPathComponent("chrome-known-volume-narrow.png"))
                }
                // Unknown volume still collapses lexical ancestors; its current
                // component and menu must remain actual native hit targets.
                try await observe([])
                browser.navigate(to: .directory(longFolder)); try await settled(browser)
                try require(browser.volumes.isEmpty && browser.breadcrumbLocations.count > 2,
                            "Unknown-volume fixture did not exercise the deep lexical fallback")
                let unknownCell = browser.pathControl.cell as? NSPathCell
                let unknownRect = unknownCell?.pathComponentCells.last.map {
                    unknownCell!.rect(of: $0, withFrame: browser.pathControl.bounds, in: browser.pathControl)
                } ?? .zero
                try await verifyCollapsedBreadcrumbs(browser, window: window, expected: longFolder, ownedRoot: owned)
                let unknownTyping = try verifyFilledAddressTyping(workspace, browser: browser, window: window,
                    expected: longFolder, width: width, caseLabel: "Unknown volume/deep path")
                failures += unknownTyping.failures
                var unknown: [String: Any] = ["case": "unknown-volume-deep-path", "windowWidth": width,
                    "breadcrumbComponents": browser.breadcrumbLocations.count,
                    "currentComponentRawRect": NSStringFromRect(unknownRect), "doubleClickExercised": true,
                    "orderedAncestorMenuNativeActions": true, "staleMenuActionsRejected": true,
                    "displayedMapping": browser.pathControl.displayedLocations.map { $0.map(String.init) ?? "ancestors" },
                    "outsideFixtureAncestors": "native command/callback only; no browsing",
                    "currentComponentVisible": !unknownRect.isEmpty]
                unknown.merge(unknownTyping.checks) { _, value in value }; checks.append(unknown)
                if width == 820 {
                    try await snapshot(window, to: output.appendingPathComponent("chrome-unknown-volume-narrow.png"))
                }
            }
            try await restoreObservation()
            browser.navigate(to: originalLocation); try await settled(browser)
            return (checks, failures)
        } catch {
            // Restore shared workspace observation before a caller catches this
            // fixture failure and continues other Chrome checks.
            try await restoreObservation()
            throw error
        }
    }

    private static func verifyFilledAddressTyping(_ workspace: BrowserWorkspaceController,
        browser: BrowserViewController, window: NSWindow, expected: URL, width: CGFloat,
        caseLabel: String) throws -> (checks: [String: Any], failures: [String], button: NSButton) {
        let longFolder = expected
        var failures: [String] = []
        if window.isVisible {
            try require(window.isKeyWindow && NSApp.isActive,
                "Foreground address qualification lost the app's key window")
        }
        guard let address = browser.pathField.superview as? AddressSurfaceView else {
            throw Failure(message: "Address surface unavailable for Edit folder path button")
        }
        let button = address.editPathButton
        let buttonPoint = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let buttonHit = window.contentView?.hitTest(window.contentView!.convert(buttonPoint, from: nil))
        let buttonEditLabelBefore = button.accessibilityLabel()
        let buttonMouseEventExercised = chromeClick(button, window: window, at: buttonPoint, count: 1)
        let buttonEditing = !browser.pathField.isHidden && browser.pathField.currentEditor() is NSTextView
        let buttonInWorkspace = button.convert(button.bounds, to: workspace.view)
        let visibleButton = workspace.view.bounds.contains(buttonInWorkspace)
            && (window.contentView?.bounds.contains(window.contentView!.convert(button.bounds, from: button)) ?? false)
        let buttonHitIsOwned = buttonHit === button || (buttonHit?.isDescendant(of: button) ?? false)
        if !visibleButton || !buttonHitIsOwned || buttonEditLabelBefore != "Edit folder path"
            || button.accessibilityLabel() != "Show folder breadcrumbs" || !buttonEditing {
            let hitType = buttonHit.map { String(describing: type(of: $0)) } ?? "none"
            failures.append("\(caseLabel): Full address lost its accessible Edit folder path pointer target at width \(width): hit=\(hitType), ownedHit=\(buttonHitIsOwned), label=\(button.accessibilityLabel() ?? "nil"), enabled=\(button.isEnabled), hidden=\(button.isHidden), editing=\(buttonEditing), frame=\(NSStringFromRect(button.frame)), point=\(NSStringFromPoint(buttonPoint)), visible=\(visibleButton), window=\(NSStringFromSize(window.contentView?.bounds.size ?? .zero)), workspace=\(NSStringFromRect(workspace.view.bounds)), pane=\(NSStringFromRect(browser.view.frame)), paneHost=\(NSStringFromRect(workspace.paneHosts[browser.paneID]?.frame ?? .zero)), address=\(NSStringFromRect(address.frame)), path=\(NSStringFromRect(browser.pathControl.frame)), sidebarFrameOwned=\(workspace.sidebarHost.translatesAutoresizingMaskIntoConstraints), paneTree=\(NSStringFromRect(workspace.paneTreeHost.frame))")
        }
        if let editor = browser.pathField.currentEditor() as? NSTextView {
            editor.insertText("Generated unsubmitted path", replacementRange: editor.selectedRange())
        }
        chromeClick(button, window: window, at: buttonPoint, count: 1)
        let buttonRestoredBreadcrumbs = browser.pathField.isHidden && !browser.pathControl.isHidden
            && browser.location == .directory(longFolder) && browser.pathField.stringValue == longFolder.path
            && button.accessibilityLabel() == "Edit folder path"
        if !buttonRestoredBreadcrumbs {
            let actualPoint = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            failures.append("\(caseLabel): Second pencil click at width \(width): fieldHidden=\(browser.pathField.isHidden), pathHidden=\(browser.pathControl.isHidden), locationMatch=\(browser.location == .directory(longFolder)), canonicalMatch=\(browser.pathField.stringValue == longFolder.path), label=\(button.accessibilityLabel() ?? "none"), pointerDrift=\(hypot(actualPoint.x - buttonPoint.x, actualPoint.y - buttonPoint.y))")
        }
        chromeClick(button, window: window, at: buttonPoint, count: 1)
        if let editor = browser.pathField.currentEditor() as? NSTextView {
            editor.insertText("Generated Escape path", replacementRange: editor.selectedRange())
            _ = browser.control(browser.pathField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        }
        let escapeRestoredBreadcrumbs = browser.pathField.isHidden && !browser.pathControl.isHidden
            && browser.location == .directory(longFolder) && browser.pathField.stringValue == longFolder.path
            && button.accessibilityLabel() == "Edit folder path"
        if !escapeRestoredBreadcrumbs {
            failures.append("\(caseLabel): Escape from pencil-entered editing did not restore current breadcrumbs at width \(width)")
        }
        let goMenu = BrowserMenus.menu(.go, target: browser)
        guard let locationCommand = goMenu.items.first(where: { $0.action == #selector(BrowserViewController.focusLocation(_:)) }),
              locationCommand.keyEquivalent == "l", locationCommand.keyEquivalentModifierMask == .command,
              let locationAction = locationCommand.action else {
            throw Failure(message: "Native Edit Location menu lost its Command-L binding")
        }
        var commandLSelectedAll = true
        for _ in 0..<2 {
            let dispatched = NSApp.sendAction(locationAction, to: browser, from: locationCommand)
            let editor = browser.pathField.currentEditor() as? NSTextView
            commandLSelectedAll = commandLSelectedAll && dispatched && !browser.pathField.isHidden
                && browser.pathControl.isHidden && editor?.string == longFolder.path
                && editor?.selectedRange() == NSRange(location: 0, length: (longFolder.path as NSString).length)
                && button.accessibilityLabel() == "Show folder breadcrumbs"
            if let editor {
                editor.insertText("Generated selection replacement", replacementRange: editor.selectedRange())
            }
        }
        if !commandLSelectedAll {
            failures.append("\(caseLabel): Command-L native menu action did not select the full canonical location before/during editing at width \(width)")
        }
        if let editor = browser.pathField.currentEditor() as? NSTextView {
            _ = browser.control(browser.pathField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        }
        let checks: [String: Any] = [
            "editButtonHitTarget": buttonHitIsOwned, "editButtonInsideWindow": visibleButton,
            "editButtonEnteredNativeEditor": buttonEditing, "secondPencilClickRestoredBreadcrumbs": buttonRestoredBreadcrumbs,
            "escapeRestoredBreadcrumbs": escapeRestoredBreadcrumbs, "commandLSelectedCanonicalPath": commandLSelectedAll,
            "buttonMouseEventDispatchExercised": buttonMouseEventExercised, "pointerDeliveryExercised": false,
            "buttonActionCheck": "native performClick plus actual hit geometry; physical pointer delivery requires separate foreground inspection"]
        return (checks, failures, button)
    }

    /// Width transitions exercise both actual native adapters with lexical
    /// inputs only. These do not enumerate/open any represented location.
    private static func verifyBreadcrumbWidthCases(window: NSWindow, fixture: URL) throws {
        let labels = ["Drive", "…", "Ancestor Two", "Ancestor Three", "Ancestor Four", "Parent", "Current"]
        var url = fixture
        let locations: [BrowserLocation] = labels.map { name in
            url.appendPathComponent(name, isDirectory: true)
            return .directory(url)
        }
        let items = labels.enumerated().map { index, title in
            let item = NSPathControlItem(); item.title = title
            if index == 0 { item.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "Drive") }
            return item
        }
        for control in [ExplorerPathControl(frame: .zero) as CollapsingPathControl, BrowserPathBar(frame: .zero)] {
            // A hidden bottom bar and a new pane can receive their visit before
            // Auto Layout has allocated any space. They must not install native
            // hit targets or ask AppKit to fit components into an empty frame.
            control.setBreadcrumbs(items: items, locations: locations)
            try require(control.pathItems.isEmpty && control.displayedLocations.isEmpty,
                "Unallocated breadcrumb installed native path components")
            // Overlay only in a guarded native verification window, removed
            // before any capture. It is not part of production composition.
            control.setFrameSize(NSSize(width: 2000, height: 26))
            window.contentView!.addSubview(control)
            defer { control.removeFromSuperview() }
            let identity = UUID()
            control.navigationContext = { BreadcrumbNavigationContext(pane: identity,
                tab: identity, visit: identity, window: ObjectIdentifier(window)) }
            control.setBreadcrumbs(items: items, locations: locations)
            control.setFrameSize(NSSize(width: 2000, height: 26))
            try require(control.displayedLocations == labels.indices.map { Optional($0) }
                && control.pathItems.map(\.title) == labels,
                "Wide native breadcrumb failed to restore the complete unshortened path")
            control.setFrameSize(.zero)
            try require(control.pathItems.isEmpty && control.displayedLocations.isEmpty,
                "Collapsed breadcrumb retained native hit targets at zero size")
            control.setFrameSize(NSSize(width: 2000, height: 26))
            try require(control.pathItems.map(\.title) == labels,
                "Breadcrumb failed to restore the visit after a zero-size transition")
            // A literal folder named … is a location, never the menu token.
            var chosen: BrowserLocation?
            control.onNavigate = { chosen = $0 }
            guard let wide = control.cell as? NSPathCell else { throw Failure(message: "Wide native path unavailable") }
            let literal = wide.pathComponentCells[1]
            let rect = wide.rect(of: literal, withFrame: control.bounds, in: control).intersection(control.bounds)
            let local = NSPoint(x: rect.midX, y: rect.midY)
            try require(!rect.isEmpty && wide.pathComponentCell(at: local, withFrame: control.bounds, in: control) === literal,
                "Literal ellipsis folder has no native hit target")
            chromeClick(control, window: window, at: control.convert(local, to: nil), count: 1)
            try require(chosen == locations[1], "Literal ellipsis folder was mistaken for the ancestor-menu token")
            control.setFrameSize(NSSize(width: 280, height: 26))
            try require(control.displayedLocations == [0, nil, labels.count - 2, labels.count - 1],
                "Narrow breadcrumb did not retain its immediate parent when space permits")
            guard let narrow = control.cell as? NSPathCell,
                  let parentIndex = control.displayedLocations.firstIndex(where: { $0 == labels.count - 2 }) else {
                throw Failure(message: "Retained immediate-parent native cell unavailable")
            }
            let parentCell = narrow.pathComponentCells[parentIndex]
            let parentRect = narrow.rect(of: parentCell, withFrame: control.bounds, in: control).intersection(control.bounds)
            let parentPoint = NSPoint(x: parentRect.midX, y: parentRect.midY)
            try require(!parentRect.isEmpty && narrow.pathComponentCell(at: parentPoint, withFrame: control.bounds, in: control) === parentCell,
                "Retained parent has no exact native hit target")
            chromeClick(control, window: window, at: control.convert(parentPoint, to: nil), count: 1)
            try require(chosen == locations[labels.count - 2], "Retained parent did not choose its exact original location")
            // Invoke the configured accessibility command through its native
            // selector. This does not claim a physical VoiceOver client test.
            var accessibleMenu: NSMenu?
            control.presentAncestorMenuForVerification = { accessibleMenu = $0 }
            guard let menuIndex = control.displayedLocations.firstIndex(where: { $0 == nil }),
                  let accessible = narrow.pathComponentCells[menuIndex].accessibilityCustomActions()?.first,
                  let selector = accessible.selector, let target = accessible.target else {
                throw Failure(message: "Native ancestor accessibility command unavailable")
            }
            let dispatched = NSApp.sendAction(selector, to: target, from: accessible)
            control.presentAncestorMenuForVerification = nil
            try require(dispatched && accessibleMenu?.items.map(\.title) == control.hiddenAncestors.map { labels[$0] },
                "Configured accessibility command did not expose the ordered native ancestor menu")
            control.setFrameSize(NSSize(width: 90, height: 26))
            try require(control.displayedLocations.first == 0 && control.displayedLocations.last == labels.count - 1
                && control.displayedLocations.contains(where: { $0 == nil }),
                "Narrow supported address did not retain drive, menu and current")
            // Find the first native threshold, rather than asserting an SDK-
            // specific separator width. Every candidate is freshly laid out.
            for width in stride(from: 89, through: 1, by: -1) {
                control.setFrameSize(NSSize(width: CGFloat(width), height: 26))
                if control.displayedLocations.first.map({ $0 == nil }) == true { break }
            }
            try require(control.displayedLocations == [nil, labels.count - 1]
                && control.hiddenAncestors.first == 0,
                "Extreme allocation lost drive access instead of moving it into the ancestor menu")
            guard let cell = control.cell as? NSPathCell else { throw Failure(message: "Native compact path cell unavailable") }
            for component in cell.pathComponentCells {
                let rect = cell.rect(of: component, withFrame: control.bounds, in: control).intersection(control.bounds)
                let point = NSPoint(x: rect.midX, y: rect.midY)
                try require(!rect.isEmpty && !rect.isNull && control.bounds.contains(point)
                    && cell.pathComponentCell(at: point, withFrame: control.bounds, in: control) === component,
                    "Extreme native path allocation lost a valid current/menu hit target")
            }
            control.setFrameSize(NSSize(width: 2000, height: 26))
            try require(control.pathItems.map(\.title) == labels && control.hiddenAncestors.isEmpty,
                "Growing the native path retained obsolete shortened labels/menu")
            let grown = (control.cell as? NSPathCell)?.pathComponentCells[1]
            try require(grown?.accessibilityLabel() == "…" && (grown?.accessibilityCustomActions()?.isEmpty ?? true),
                "A recycled native cell kept the menu command on a literal ellipsis folder")
        }
    }

    /// Real native hit + command checks, never dispatching a zero/other cell.
    /// Menu presentation is captured only in this guarded DEBUG fixture, while
    /// NSMenu's actual target/action path performs each exact lexical choice.
    private static func verifyCollapsedBreadcrumbs(_ browser: BrowserViewController,
        window: NSWindow, expected: URL, ownedRoot: URL) async throws {
        let expectedLocation = BrowserLocation.directory(expected)
        try require(!browser.pathControl.hiddenAncestors.isEmpty,
            "Deep narrow address retained implicit native hiding instead of its ancestor menu")
        let originalPathBar = browser.settings.showsPathBar
        browser.settings.showsPathBar = true
        defer { browser.settings.showsPathBar = originalPathBar }
        window.contentView?.layoutSubtreeIfNeeded()
        func point(_ control: CollapsingPathControl, _ index: Int) throws -> NSPoint {
            guard let cell = control.cell as? NSPathCell, cell.pathComponentCells.indices.contains(index) else {
                throw Failure(message: "Collapsed path has no native component")
            }
            let component = cell.pathComponentCells[index]
            let rect = cell.rect(of: component, withFrame: control.bounds, in: control).intersection(control.bounds)
            let local = NSPoint(x: rect.midX, y: rect.midY)
            try require(!rect.isEmpty && !rect.isNull && local.x.isFinite && local.y.isFinite
                && control.bounds.contains(local)
                && cell.pathComponentCell(at: local, withFrame: control.bounds, in: control) === component,
                "Collapsed path target is hidden or resolves to a different native component: index=\(index), rect=\(NSStringFromRect(rect)), bounds=\(NSStringFromRect(control.bounds))")
            return control.convert(local, to: nil)
        }
        func presented(_ control: CollapsingPathControl) throws -> NSMenu {
            guard let index = control.displayedLocations.firstIndex(where: { $0 == nil }),
                  let cell = control.cell as? NSPathCell, cell.pathComponentCells.indices.contains(index) else {
                throw Failure(message: "Narrow deep path did not expose an ancestor-menu item")
            }
            let component = cell.pathComponentCells[index]
            try require(component.accessibilityLabel() == "Show parent folders"
                && component.accessibilityCustomActions()?.contains(where: { $0.name == "Show parent folders" }) == true,
                "Collapsed ancestor target lost its descriptive accessible action")
            var captured: NSMenu?
            control.presentAncestorMenuForVerification = { captured = $0 }
            defer { control.presentAncestorMenuForVerification = nil }
            chromeClick(control, window: window, at: try point(control, index), count: 1)
            guard let captured else {
                throw Failure(message: "Native ellipsis activation did not produce its menu: visible=\(window.isVisible), key=\(window.isKeyWindow), active=\(NSApp.isActive), controlWindow=\(control.window === window), firstResponder=\(String(describing: window.firstResponder.map { type(of: $0) }))")
            }
            try require(browser.location == expectedLocation, "Opening an ancestor menu navigated or edited the path")
            return captured
        }
        for bottomLayout in [false, true] {
            browser.settings.showsPathBar = bottomLayout
            await Task.yield()
            window.contentView?.layoutSubtreeIfNeeded()
            let control = browser.pathControl as CollapsingPathControl
            try require(control.locations == browser.breadcrumbLocations && control.logicalItems.count > 3,
                "Both layouts must retain the same full deep lexical path")
            let originals = control.logicalItems.map(\.title)
            let hidden = control.hiddenAncestors
            try require(hidden == hidden.sorted() && !hidden.contains(originals.count - 1),
                "Collapsed menu is not an ordered ancestor-only subset")
            let current = control.displayedLocations.firstIndex(where: { $0 == originals.count - 1 })
            try require(current != nil, "Current folder vanished from displayed mapping")
            _ = try point(control, current!)
            // The shared bottom bar may fit all items at its wider allocation.
            // Its current hit/full mapping remain mandatory in that case.
            if hidden.isEmpty {
                try require(control.displayedLocations == Array(control.logicalItems.indices).map { Optional($0) },
                    "A fitting path lost an item or manufactured an ancestor menu")
                continue
            }
            let menu = try presented(control)
            try require(menu.items.map(\.title) == hidden.map { originals[$0] },
                "Ancestor menu names/order differ from the full lexical path")
            // No first/last-only oracle: every omitted original index is visited.
            let destinations = hidden.map { control.locations[$0] }
            for (index, destination) in destinations.enumerated() {
                let fresh = try presented(control)
                // Unknown-root ancestors outside the marked fixture are tested
                // at the same native action/callback seam, without opening them.
                let allowed = destination.directoryURL.map {
                    $0.path == ownedRoot.path || $0.path.hasPrefix(ownedRoot.path + "/")
                } ?? false
                let originalNavigate = control.onNavigate
                var chosen: BrowserLocation?
                control.onNavigate = { location in
                    chosen = location
                    if allowed { originalNavigate?(location) }
                }
                defer { control.onNavigate = originalNavigate }
                fresh.performActionForItem(at: index)
                control.onNavigate = originalNavigate
                try require(chosen == destination && browser.location == (allowed ? destination : expectedLocation),
                    "Native ancestor menu chose a different lexical location")
                try await settled(browser)
                browser.navigate(to: expectedLocation); try await settled(browser)
                window.contentView?.layoutSubtreeIfNeeded()
            }
            // Resize invalidation must not require a changed location or key state.
            let staleResize = try presented(control)
            let size = window.contentView!.bounds.size
            window.setContentSize(NSSize(width: size.width + 20, height: size.height))
            window.contentView?.layoutSubtreeIfNeeded()
            staleResize.performActionForItem(at: 0)
            try require(browser.location == expectedLocation, "A resized presentation retained stale menu authority")
            window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded()
            let staleVisit = try presented(control)
            let parent = BrowserLocation.directory(expected.deletingLastPathComponent())
            browser.navigate(to: parent); try await settled(browser)
            staleVisit.performActionForItem(at: 0)
            try require(browser.location == parent, "An older visit's ancestor menu navigated a new visit")
            browser.navigate(to: expectedLocation); try await settled(browser)
            let staleRetired = try presented(control)
            browser.isBrowserSuspended = true
            staleRetired.performActionForItem(at: 0)
            browser.isBrowserSuspended = false
            try require(browser.location == expectedLocation, "A retired pane retained ancestor menu authority")
            if control === browser.pathControl {
                let staleEditing = try presented(control)
                browser.focusLocation(nil)
                staleEditing.performActionForItem(at: 0)
                try require(browser.location == expectedLocation && !browser.pathField.isHidden,
                    "Hidden breadcrumb menu interrupted manual path editing")
                browser.cancelLocationEditing()
            }
            // Immediate parent, when retained, is still one native click.
            if let parentIndex = control.displayedLocations.firstIndex(where: { $0 == control.logicalItems.count - 2 }) {
                chromeClick(control, window: window, at: try point(control, parentIndex), count: 1)
                try require(browser.location == parent, "Visible immediate parent lost immediate navigation")
                try await settled(browser)
                browser.navigate(to: expectedLocation); try await settled(browser)
            }
        }
        // First + second current clicks, preserving the actual first-click route.
        let currentIndex = browser.pathControl.displayedLocations.count - 1
        let firstPoint = try point(browser.pathControl, currentIndex)
        chromeClick(browser.pathControl, window: window, at: firstPoint, count: 1)
        try require(browser.location == expectedLocation, "Current-folder first click navigated an ancestor")
        try await settled(browser)
        let secondPoint = try point(browser.pathControl, browser.pathControl.displayedLocations.count - 1)
        try require(abs(firstPoint.x - secondPoint.x) < 1 && abs(firstPoint.y - secondPoint.y) < 1,
            "Current breadcrumb moved between first and second click")
        chromeClick(browser.pathControl, window: window, at: firstPoint, count: 2)
        try require(browser.pathField.currentEditor() is NSTextView && browser.pathControl.isHidden
            && browser.pathField.stringValue == expected.path && browser.location == expectedLocation,
            "Collapsed current double-click lost canonical native editing")
        browser.cancelLocationEditing()
        // Bottom Copy Path must refer to full location, never shortened text.
        let bottom = browser.pathControl
        let savedCopy = bottom.onCopyPath
        var copied: URL?
        bottom.onCopyPath = { copied = $0 }
        defer { bottom.onCopyPath = savedCopy }
        let index = bottom.displayedLocations.count - 1
        guard let menu = bottom.copyMenu(forDisplayedIndex: index,
            action: NSSelectorFromString("copyComponent:")) else { throw Failure(message: "Bottom Copy Path menu unavailable") }
        menu.performActionForItem(at: 0)
        try require(copied == expected, "Bottom Copy Path used a shortened displayed name")
        let typing = try verifyFilledAddressTyping(browser.workspace!, browser: browser, window: window,
            expected: expected, width: window.contentView!.bounds.width, caseLabel: "Collapsed deep path")
        try require(typing.failures.isEmpty, typing.failures.joined(separator: "; "))
    }

    /// Existing substantial harness supplies its real four-pane composition.
    /// It creates only a marked generated child and restores shared observation.
    static func verifyCollapsedBreadcrumbsInFourPanes(_ workspace: BrowserWorkspaceController,
        window: NSWindow, owned: URL) async throws {
        try require(workspace.browsers.count == 4, "Breadcrumb matrix requires four real panes")
        let deep = owned.appendingPathComponent("breadcrumb-root/Folder A/Folder B/Folder C/Résumé नमस्ते 日本語 " + String(repeating: "Long current Agjp ", count: 8), isDirectory: true)
        try await Task.detached {
            try FileManager().createDirectory(at: deep, withIntermediateDirectories: true)
        }.value
        let active = workspace.activeBrowser
        let size = window.contentView!.bounds.size
        let originalPathBar = active.settings.showsPathBar
        active.settings.showsPathBar = true
        for browser in workspace.browsers.values { browser.saveViewState() }
        let originalTabs = workspace.browsers.mapValues { ($0.tabs, $0.activeID) }
        let originals = workspace.browsers.values.map { ($0, $0.location, $0.readVolumesForVerification, $0.volumes) }
        defer {
            for (browser, _, reader, _) in originals { browser.readVolumesForVerification = reader }
            active.settings.showsPathBar = originalPathBar
            workspace.activate(active, focus: false)
            window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded()
        }
        func restore() async throws {
            // Volume observation is workspace-shared, so restore it once via
            // the actual accepted refresh route, then restore every live visit.
            if let first = originals.first {
                first.0.readVolumesForVerification = { first.3 }
                await first.0.refreshVolumes()
                first.0.readVolumesForVerification = first.2
            }
            for (browser, _, _, _) in originals {
                if let original = originalTabs[browser.paneID] {
                    browser.tabs = original.0; browser.activeID = original.1; browser.loadLocation()
                    try await settled(browser)
                }
            }
        }
        do {
            window.setContentSize(workspace.minimumWorkspaceSize)
            window.contentView?.layoutSubtreeIfNeeded()
            let observations = [[VolumeInfo(url: owned, name: "Fixture drive", kind: .externalDisk)], []]
            for (index, volumes) in observations.enumerated() {
                active.readVolumesForVerification = { volumes }
                await active.refreshVolumes()
                for (browser, _, _, _) in originals {
                    workspace.activate(browser, focus: false)
                    try require(browser.volumes == volumes, "Four-pane volume observation was not accepted")
                    browser.navigate(to: .directory(deep)); try await settled(browser)
                    try await verifyCollapsedBreadcrumbs(browser, window: window, expected: deep, ownedRoot: owned)
                    // Each address now remains in its own visible pane. Capture
                    // menus, switch focus, then supersede that pane's visit:
                    // old contexts must not act on its new location.
                    if let peer = originals.first(where: { $0.0 !== browser })?.0 {
                        let bottom = browser.pathControl
                        let savedCopy = bottom.onCopyPath
                        var copied: URL?
                        bottom.onCopyPath = { copied = $0 }
                        defer { bottom.onCopyPath = savedCopy }
                        let staleAncestors = bottom.ancestorMenu()
                        guard let staleCopy = bottom.copyMenu(forDisplayedIndex: bottom.displayedLocations.count - 1,
                            action: NSSelectorFromString("copyComponent:")) else {
                            throw Failure(message: "Shared bottom-bar copy context was not captured")
                        }
                        workspace.activate(peer, focus: false)
                        browser.navigate(to: .directory(owned)); try await settled(browser)
                        staleCopy.performActionForItem(at: 0)
                        staleAncestors?.performActionForItem(at: 0)
                        try require(copied == nil && browser.location == .directory(owned),
                            "An older pane visit retained copy/navigation menu authority")
                        browser.navigate(to: .directory(deep)); try await settled(browser)
                        workspace.activate(browser, focus: false)
                    }
                }
                // Paint only after geometry, exact target, native action and
                // typing assertions; capture cannot prime the preceding oracle.
                try await snapshot(window, to: owned.appendingPathComponent(index == 0
                    ? "four-panes-collapsed-known-volume.png" : "four-panes-collapsed-unknown-volume.png"))
            }
            try await restore()
        } catch {
            try await restore()
            throw error
        }
    }

    static func verifyWorkspaceSidebarResize(_ workspace: BrowserWorkspaceController, window: NSWindow) async throws {
        let active = workspace.activeBrowser
        let initialSize = window.contentView?.bounds.size ?? workspace.view.bounds.size
        let initialSidebar = workspace.sidebarSnapshot
        let initialWidth = CGFloat(initialSidebar.expandedWidth)
        let initialMotion = active.settings.motion
        let initialBranches = active.sidebarLayoutOwner.preferences
        let initialPreview = workspace.preview.isEnabled
        var sidebarObservations: [[String: Any]] = []
        func observeSidebar(_ stage: String) {
            let split = workspace.sidebarHost.superview as? WorkspaceSidebarSplitView
            sidebarObservations.append(["stage": stage,
                "frameWidth": Double(workspace.sidebarHost.frame.width),
                "boundsWidth": Double(workspace.sidebarHost.bounds.width),
                "position": Double(split?.sidebarPosition ?? -1),
                "splitWidth": Double(split?.bounds.width ?? -1),
                "savedWidth": workspace.sidebarSnapshot.expandedWidth,
                "collapsed": workspace.isSidebarCollapsed, "hidden": workspace.sidebarHost.isHidden,
                "restoreButtonHidden": workspace.sidebarRestoreButton.isHidden])
        }
        workspace.applyMotionPreferences(.init(mode: .off))
        workspace.setSidebarCollapsed(false, animated: false)
        let selections = workspace.browsers.mapValues { $0.selectedURLs }
        for browser in workspace.browsers.values {
            if browser.showsComputerVolumes { browser.volumeBrowser.setSelection([]) }
            else { browser.setFileSelection([]) }
        }
        defer {
            workspace.setSidebarCollapsed(initialSidebar.isCollapsed, animated: false)
            workspace.applyMotionPreferences(initialMotion)
            if workspace.preview.isEnabled != initialPreview { workspace.togglePreview(nil) }
            for browser in workspace.browsers.values {
                if browser.showsComputerVolumes { browser.volumeBrowser.setSelection(selections[browser.paneID] ?? []) }
                else { browser.setFileSelection(selections[browser.paneID] ?? []) }
            }
            workspace.activate(active, focus: false)
            window.setContentSize(initialSize)
            window.contentView?.layoutSubtreeIfNeeded()
        }
        window.setContentSize(NSSize(width: max(initialSize.width, workspace.minimumWorkspaceSize.width + 160), height: initialSize.height))
        window.contentView?.layoutSubtreeIfNeeded()
        func drag(by amount: CGFloat) throws {
            let boundary = workspace.sidebarHost.convert(NSPoint(x: workspace.sidebarHost.bounds.maxX + 0.5,
                y: workspace.sidebarHost.bounds.midY), to: nil)
            guard let hit = window.contentView?.hitTest(window.contentView!.convert(boundary, from: nil)) as? NSSplitView else {
                throw Failure(message: "Multipane sidebar has no native resize boundary")
            }
            try chromeDrag(hit, window: window, from: boundary, to: NSPoint(x: boundary.x + amount, y: boundary.y))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        try drag(by: 40)
        let resized = workspace.sidebarHost.bounds.width
        observeSidebar("expanded-after-drag")
        try require(resized >= initialWidth + 10, "Multipane native sidebar drag did not change width")
        try drag(by: -1000)
        observeSidebar("native-collapse")
        try require(workspace.isSidebarCollapsed && workspace.sidebarHost.isHidden
            && workspace.sidebarHost.frame.width == 0 && !workspace.sidebarRestoreButton.isHidden,
            "Native sidebar drag did not fully collapse or expose its restore control")
        workspace.sidebarRestoreButton.performClick(nil)
        observeSidebar("footer-restore")
        let sidebarTrace = String(decoding: try JSONSerialization.data(withJSONObject: sidebarObservations,
            options: [.sortedKeys]), as: UTF8.self)
        try require(!workspace.isSidebarCollapsed && workspace.sidebarRestoreButton.isHidden
            && abs(workspace.sidebarHost.bounds.width - resized) <= 1,
            "Footer restore lost the last expanded sidebar width: " + sidebarTrace)
        try drag(by: 180 - workspace.sidebarHost.bounds.width)
        try require(abs(workspace.sidebarHost.bounds.width - 180) <= 1, "Native sidebar drag escaped its lower bound")
        try drag(by: 1000)
        try require(workspace.sidebarHost.bounds.width <= 341, "Native sidebar drag escaped its upper bound")
        for browser in workspace.browsers.values {
            workspace.activate(browser, focus: false)
            window.contentView?.layoutSubtreeIfNeeded()
            try require(browser.outline.isDescendant(of: workspace.sidebarHost), "Active pane did not own the shared resized sidebar")
            for host in workspace.paneHosts.values {
                try require(host.bounds.width >= 399 && host.bounds.height >= 219, "Sidebar drag violated multipane minima")
            }
            try require(abs(workspace.footerHost.frame.width - workspace.view.bounds.width) <= 1
                && abs(workspace.pathHost.frame.width - workspace.view.bounds.width) <= 1,
                "Sidebar drag changed shared footer/path alignment")
            if workspace.preview.isEnabled {
                try require(abs(workspace.inspectorHost.bounds.width - 300) <= 1, "Sidebar drag changed Preview width")
            }
        }
        try drag(by: initialWidth - workspace.sidebarHost.bounds.width)
        if !workspace.preview.isEnabled { workspace.togglePreview(nil) }
        try require(workspace.preview.isEnabled && workspace.preview.state == .empty && !workspace.inspectorHost.isHidden,
            "Combined sidebar/Preview check did not enable the real Preview with an empty generated selection")
        func verifyPreviewGeometry(_ stage: String) throws {
            try require(abs(workspace.inspectorHost.bounds.width - 300) <= 1,
                stage + ": sidebar drag changed Preview width")
            for host in workspace.paneHosts.values {
                try require(host.bounds.width >= 399 && host.bounds.height >= 219,
                    stage + ": combined Preview/sidebar layout violated pane minima")
            }
            try require(abs(workspace.footerHost.frame.width - workspace.view.bounds.width) <= 1
                && abs(workspace.pathHost.frame.width - workspace.view.bounds.width) <= 1,
                stage + ": combined Preview/sidebar layout changed shared footer/path alignment")
        }
        window.setContentSize(NSSize(width: max(initialSize.width, workspace.minimumWorkspaceSize.width + 160), height: initialSize.height))
        window.contentView?.layoutSubtreeIfNeeded()
        try drag(by: 180 - workspace.sidebarHost.bounds.width)
        try require(abs(workspace.sidebarHost.bounds.width - 180) <= 1, "Preview-enabled sidebar escaped its lower bound")
        try verifyPreviewGeometry("Preview and sidebar at lower bound")
        try drag(by: 1000)
        try require(abs(workspace.sidebarHost.bounds.width - 340) <= 1, "Preview-enabled sidebar escaped its upper bound")
        try verifyPreviewGeometry("Preview and sidebar at upper bound")
        window.setContentSize(workspace.minimumWorkspaceSize)
        window.contentView?.layoutSubtreeIfNeeded()
        let minimumWidth = workspace.sidebarHost.bounds.width
        try drag(by: 1000)
        try require(workspace.sidebarHost.bounds.width <= minimumWidth + 1,
            "Exact-minimum Preview layout allowed sidebar to consume pane minimum space")
        try verifyPreviewGeometry("Preview and sidebar at exact workspace minimum")
        // Restore enough allocation before returning the sidebar to its initial
        // width, then restore the original Preview state through the real toggle.
        window.setContentSize(NSSize(width: max(initialSize.width, workspace.minimumWorkspaceSize.width + 160), height: initialSize.height))
        window.contentView?.layoutSubtreeIfNeeded()
        try drag(by: initialWidth - workspace.sidebarHost.bounds.width)
        if workspace.preview.isEnabled != initialPreview { workspace.togglePreview(nil) }

        // Exercise the actual View command, native divider and shared footer;
        // presentation must not recreate the outline or change its tree model.
        let menu = BrowserMenus.menu(.view, target: workspace.activeBrowser)
        let action = #selector(BrowserViewController.toggleSidebar(_:))
        guard let command = menu.items.first(where: { $0.action == action }) else {
            throw Failure(message: "View menu omitted the sidebar command")
        }
        let browser = workspace.activeBrowser
        browser.focusBrowserContent()
        let focused = window.firstResponder
        try require(browser.validateMenuItem(command) && command.title == "Hide Sidebar"
            && NSApp.sendAction(action, to: browser, from: command), "View menu refused sidebar collapse")
        try require(window.firstResponder === focused && workspace.isSidebarCollapsed,
            "Sidebar collapse stole file-list focus")
        let snapshot = try workspace.captureSessionSnapshot(syncViewState: false)
        try require(snapshot.sidebar?.isCollapsed == true
            && snapshot.sidebar?.expandedWidth == Double(initialWidth), "Workspace snapshot lost collapsed width")
        for peer in workspace.browsers.values {
            workspace.activate(peer, focus: false)
            try require(peer.outline.isDescendant(of: workspace.sidebarHost) && workspace.sidebarHost.isHidden
                && workspace.sidebarRestoreButton.isDescendant(of: workspace.footerHost)
                && !workspace.sidebarRestoreButton.isHidden, "Pane activation lost the shared collapsed sidebar/footer")
        }
        workspace.sidebarRestoreButton.performClick(nil)
        try require(!workspace.isSidebarCollapsed && workspace.sidebarRestoreButton.isHidden,
            "Collapsed footer button did not restore sidebar")
        workspace.activate(browser, focus: false)
        window.makeFirstResponder(browser.outline)
        guard let nativeSplit = workspace.sidebarHost.superview as? NSSplitView else {
            throw Failure(message: "Sidebar lost its native split owner")
        }
        let boundary = workspace.sidebarHost.convert(NSPoint(x: workspace.sidebarHost.bounds.maxX + 0.5,
            y: workspace.sidebarHost.bounds.midY), to: nil)
        nativeSplit.mouseDown(with: chromeMouse(.leftMouseDown, window: window, at: boundary, count: 2))
        try require(workspace.isSidebarCollapsed && window.firstResponder !== browser.outline,
            "Native divider double-click did not collapse or evacuate sidebar focus")
        try require(browser.validateMenuItem(command) && command.title == "Show Sidebar",
            "View command did not reflect the collapsed state")
        for mode in [BrowserMotionMode.full, .reduced, .off] {
            workspace.applyMotionPreferences(.init(mode: mode))
            workspace.setSidebarCollapsed(false)
            try await waitUntil("Sidebar expansion settles") { !workspace.hasSidebarAnimationForVerification }
            try require(abs(workspace.sidebarHost.bounds.width - initialWidth) <= 1,
                "Sidebar motion mode lost expanded width")
            workspace.setSidebarCollapsed(true)
            workspace.setSidebarCollapsed(false)
            workspace.setSidebarCollapsed(true)
            window.setContentSize(NSSize(width: initialSize.width + 2, height: initialSize.height))
            window.contentView?.layoutSubtreeIfNeeded()
            try await waitUntil("Interrupted sidebar transition settles") { !workspace.hasSidebarAnimationForVerification }
            try require(workspace.isSidebarCollapsed && workspace.sidebarHost.frame.width == 0
                && workspace.sidebarHost.isHidden, "Resize/reversal left an intermediate sidebar")
            for host in workspace.paneHosts.values {
                try require(host.bounds.width >= 399 && host.bounds.height >= 219,
                    "Sidebar transition interrupted pane minimum geometry")
            }
        }
        workspace.setSidebarCollapsed(false, animated: false)
        try require(active.sidebarLayoutOwner.preferences == initialBranches,
            "Sidebar visibility changed expanded branches or item order")
    }

    @discardableResult
    private static func chromeClick(_ target: NSView, window: NSWindow, at point: NSPoint, count: Int) -> Bool {
        let canDispatch = window.isVisible && window.isKeyWindow && NSApp.isActive
        // A visible window losing focus is an interrupted foreground check,
        // never authority to substitute a hidden-window action simulation.
        if window.isVisible && !canDispatch { return false }
        if let button = target as? NSButton {
            // Constructed event dispatch is not physical cursor delivery and
            // did not reliably complete native button tracking in foreground
            // qualification. Keep this an explicit native action/hit check;
            // actual pointer interaction is checked separately through the UI.
            button.performClick(nil)
            return false
        }
        let down = chromeMouse(.leftMouseDown, window: window, at: point, count: count)
        let up = chromeMouse(.leftMouseUp, window: window, at: point, count: count)
        NSApp.postEvent(up, atStart: true)
        if canDispatch {
            NSApp.sendEvent(down)
        } else {
            // Native path control tracking can be exercised directly while
            // hidden, including first-click navigation before the second click.
            target.mouseDown(with: down)
        }
        // Custom breadcrumb edit/menu routes can return without native mouse
        // tracking. Deliver only this call's still-queued synthetic release;
        // leaving it there can cancel the following button's tracking loop.
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                         inMode: .default, dequeue: false),
           pending.windowNumber == up.windowNumber && pending.timestamp == up.timestamp
            && pending.eventNumber == up.eventNumber && pending.locationInWindow == up.locationInWindow {
            if let release = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                             inMode: .default, dequeue: true) { NSApp.sendEvent(release) }
        }
        return canDispatch
    }

    private static func chromeDrag(_ target: NSView, window: NSWindow, from start: NSPoint, to end: NSPoint) throws {
        // NSSplitView owns its native tracking loop; queued events let that
        // actual loop process the drag and terminate without a physical mouse.
        NSApp.postEvent(chromeMouse(.leftMouseUp, window: window, at: end), atStart: true)
        NSApp.postEvent(chromeMouse(.leftMouseDragged, window: window, at: end), atStart: true)
        target.mouseDown(with: chromeMouse(.leftMouseDown, window: window, at: start))
    }

    private static func chromeMouse(_ type: NSEvent.EventType, window: NSWindow, at point: NSPoint, count: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: count, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private static func chromePaint(_ view: NSView, draw: () -> Void) throws -> NSBitmapImageRep {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(view.bounds.width)),
                  pixelsHigh: Int(ceil(view.bounds.height)), bitsPerSample: 8, samplesPerPixel: 4,
                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Failure(message: "Cannot create chrome paint probe") }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(origin: .zero, size: view.bounds.size))
        view.effectiveAppearance.performAsCurrentDrawingAppearance(draw)
        context.flushGraphics()
        return bitmap
    }

    private static func chromeAlpha(_ bitmap: NSBitmapImageRep, at point: NSPoint) throws -> Double {
        guard let color = bitmap.colorAt(x: Int(point.x), y: Int(point.y)) else { throw Failure(message: "Chrome sample outside bounds") }
        return Double(color.alphaComponent)
    }

    private static func chromeInkBounds(_ bitmap: NSBitmapImageRep) -> NSRect? {
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15 {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return NSRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }
}
#endif
