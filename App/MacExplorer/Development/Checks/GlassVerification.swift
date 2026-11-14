import AppKit

#if DEBUG
/// App-owned generated pixels only. The integrating runner owns launch and capture.
@MainActor
enum GlassVerification {
    struct Failure: Error { let message: String }

    /// Structural checks can go red independently of a WindowServer screenshot.
    /// They do not establish that the material visibly transmits background color.
    static func inspectBrowser(_ browser: BrowserViewController, output: URL) throws -> [String: Any] {
        browser.view.window?.contentView?.layoutSubtreeIfNeeded()
        let surface = browser.navigationSurface
        // A standard backdrop or an embedding view may precede the native glass.
        let material = surface.flatMap { nativeGlass(in: $0) ?? $0.subviews.last }
        let content = surface?.contentView
        let bounds = surface?.bounds ?? .zero
        let materialBounds = material.map { surface!.convert($0.bounds, from: $0) } ?? .zero
        let contentBounds = content.map { surface!.convert($0.bounds, from: $0) } ?? .zero
        func covers(_ rect: NSRect) -> Bool {
            bounds.width > 1 && bounds.height > 1 && abs(rect.minX - bounds.minX) < 1
                && abs(rect.minY - bounds.minY) < 1 && abs(rect.width - bounds.width) < 1
                && abs(rect.height - bounds.height) < 1
        }
        var nativeGlass = false
        var correctContent = false
        var style = "fallback"
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            nativeGlass = true
            correctContent = glass.contentView === content
            style = glass.style == .regular ? "regular" : "clear"
        }
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let expectsNativeGlass: Bool
        if #available(macOS 26.0, *) {
            expectsNativeGlass = browser.settings.navigationStyle == .glass && !reduceTransparency
        } else { expectsNativeGlass = false }
        var failures: [String] = []
        if surface == nil { failures.append("Missing navigation surface") }
        if !covers(materialBounds) { failures.append("Material does not cover navigation bounds") }
        if !covers(contentBounds) { failures.append("Content geometry does not cover navigation bounds") }
        if expectsNativeGlass && !nativeGlass { failures.append("Glass preference did not install NSGlassEffectView") }
        if expectsNativeGlass && !correctContent { failures.append("Native glass does not own the navigation content") }
        if expectsNativeGlass && (browser.tabStrip.drawsSolidBackground || browser.pathContainer.drawsSolidBackground) {
            failures.append("An opaque navigation row fill covers the material")
        }
        if material?.isHiddenOrHasHiddenAncestor == true { failures.append("Material has a hidden ancestor") }
        let report: [String: Any] = [
            "structuralPassed": failures.isEmpty, "failures": failures,
            "runtime": ProcessInfo.processInfo.operatingSystemVersionString,
            "reduceTransparency": reduceTransparency,
            "increaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "navigationPreference": browser.settings.navigationStyle.rawValue,
            "materialClass": material.map { String(describing: type(of: $0)) } ?? "missing",
            "nativeGlass": nativeGlass, "style": style, "correctContentOwner": correctContent,
            "surfaceBounds": NSStringFromRect(bounds), "materialBounds": NSStringFromRect(materialBounds),
            "contentBounds": NSStringFromRect(contentBounds),
            "tabStripSolidFill": browser.tabStrip.drawsSolidBackground,
            "addressRowSolidFill": browser.pathContainer.drawsSolidBackground,
            "windowIsOpaque": browser.view.window?.isOpaque ?? true,
            "windowIsKey": browser.view.window?.isKeyWindow ?? false,
            "usesWindowBackdrop": surface?.usesWindowBackdrop ?? false,
            "captureBoundary": "Structure only; visible transparency requires a capture of the exact app-owned probe window",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("glass-structure.json"), options: .atomic)
        return report
    }

    static func verifyBrowser(_ browser: BrowserViewController, output: URL) throws {
        let report = try inspectBrowser(browser, output: output)
        guard report["structuralPassed"] as? Bool == true else {
            throw Failure(message: (report["failures"] as? [String] ?? []).joined(separator: "; "))
        }
    }

    /// Keep this window retained until capture finishes. Its windowNumber is the
    /// sole permitted capture target; never replace it with a desktop capture.
    static func makeProbeWindow() -> NSWindow {
        let canvas = GlassProbeBackdrop(frame: NSRect(x: 0, y: 0, width: 900, height: 360))
        let regular = NavigationGlassSurface(contentView: probeContent("Regular — native material over generated in-window content"), cornerRadius: 16, usesWindowBackdrop: false)
        regular.frame = NSRect(x: 20, y: 250, width: 860, height: 80)
        regular.autoresizingMask = [.width]
        canvas.addSubview(regular)
        if #available(macOS 26.0, *) {
            let clear = NSGlassEffectView(frame: NSRect(x: 20, y: 140, width: 860, height: 80))
            clear.style = .clear
            clear.cornerRadius = 16
            clear.contentView = probeContent("Clear — diagnostic comparison, not the shipping navigation choice")
            clear.autoresizingMask = [.width]
            canvas.addSubview(clear)
        }
        let solid = GlassProbeOpaque(frame: NSRect(x: 20, y: 30, width: 860, height: 80))
        let solidContent = probeContent("Opaque control — colored bands must disappear here")
        pin(solidContent, inside: solid)
        solid.autoresizingMask = [.width]
        canvas.addSubview(solid)
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Mac Explorer — generated glass material probe"
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.center()
        window.makeKeyAndOrderFront(nil)
        canvas.layoutSubtreeIfNeeded()
        return window
    }

    /// Covers the complete browser frame with generated content behind it. Keep
    /// this retained and below the browser throughout an exact-browser capture.
    /// This makes a behind-window comparison factual without sampling a desktop
    /// or another app. Close it after the capture; do not capture this window as
    /// a substitute for the browser itself.
    static func makeBrowserBackdropWindow(behind browser: NSWindow) -> NSWindow {
        let frame = browser.frame.insetBy(dx: -40, dy: -40)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Mac Explorer — generated browser backdrop"
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.level = browser.level
        let canvas = GlassProbeBackdrop(frame: NSRect(origin: .zero, size: frame.size))
        canvas.autoresizingMask = [.width, .height]
        window.contentView = canvas
        window.order(.below, relativeTo: browser.windowNumber)
        browser.makeKeyAndOrderFront(nil)
        return window
    }

    /// Run only after the verification runner loads its validated listing fixture.
    /// Captures the actual browser twice with a generated window directly behind
    /// its complete frame. Foreground loss, changed geometry, denied capture and
    /// flat production navigation all fail; no desktop capture is attempted.
    static func verifyBrowserBackdrop(_ browser: BrowserViewController, fixture: URL, output: URL) async throws -> [String: Any] {
        guard browser.isVerificationSession,
              ProcessInfo.processInfo.arguments.contains("--qualify-glass"),
              fixture.isFileURL, fixture.standardizedFileURL == fixture.resolvingSymlinksInPath().standardizedFileURL,
              fixture.deletingLastPathComponent().lastPathComponent == "fixtures",
              fixture.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".build",
              browser.location.directoryURL?.standardizedFileURL == fixture.standardizedFileURL,
              browser.tabs.count == 1,
              let window = browser.view.window, NSApplication.shared.windows.contains(where: { $0 === window }),
              let surface = browser.navigationSurface,
              browser.settings.navigationStyle == .glass,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
              !browser.folderScroll.isHidden, browser.table.numberOfRows > 0 else {
            throw Failure(message: "Browser glass comparison requires foreground verification, Glass enabled, and a loaded owned listing fixture")
        }
        guard #available(macOS 26.0, *) else { throw Failure(message: "Native browser glass comparison requires macOS 26 or later") }
        let marker = fixture.appendingPathComponent(".mac-explorer-fixture.json")
        let markerData = try await Task.detached { try Data(contentsOf: marker) }.value
        let metadata = try JSONSerialization.jsonObject(with: markerData) as? [String: Any]
        let build = fixture.deletingLastPathComponent().deletingLastPathComponent()
        guard metadata?["generator"] as? String == "mac-explorer-dev", metadata?["complete"] as? Bool == true,
              output.standardizedFileURL == output.resolvingSymlinksInPath().standardizedFileURL,
              output.path.hasPrefix(build.appendingPathComponent("evidence").path + "/") else {
            throw Failure(message: "Refused unowned glass comparison input or output")
        }
        let originalBackdrop = surface.usesWindowBackdrop
        let originalWindowIsOpaque = window.isOpaque
        let originalWindowBackground: NSColor = window.backgroundColor ?? .windowBackgroundColor
        let selection = browser.table.selectedRowIndexes
        let frame = window.frame
        let backdrop = makeBrowserBackdropWindow(behind: window)
        defer {
            surface.usesWindowBackdrop = originalBackdrop
            window.isOpaque = originalWindowIsOpaque
            window.backgroundColor = originalWindowBackground
            browser.table.selectRowIndexes(selection, byExtendingSelection: false)
            backdrop.close()
            window.makeKeyAndOrderFront(nil)
        }
        browser.table.deselectAll(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let fractions: [CGFloat] = [0.35, 0.45, 0.55, 0.65, 0.78, 0.91]
        let navigationPoints = fractions.map {
            // With one tab these are unoccupied interior pixels in the tab row,
            // away from controls, separators, the glass edge and the address field.
            surface.convert(NSPoint(x: surface.bounds.width * $0, y: surface.bounds.maxY - 18), to: nil)
        }
        let visible = browser.table.rows(in: browser.table.visibleRect)
        let row = min(browser.table.numberOfRows - 1, visible.location + (visible.length > 1 ? 1 : 0))
        let rowRect = browser.table.rect(ofRow: row)
        let filePoints = fractions.map {
            browser.table.convert(NSPoint(x: browser.table.visibleRect.minX + browser.table.visibleRect.width * $0,
                                          y: rowRect.minY + 2), to: nil)
        }
        var readings: [[String: Any]] = []
        var colors: [[[Double]]] = []
        let phases: [(name: String, backdrop: Bool, transparentWindow: Bool)] = [
            ("backdrop-off", false, false), ("backdrop-on", true, false),
            ("transparent-window-experiment", true, true)
        ]
        for phase in phases {
            try Task.checkCancellation()
            surface.usesWindowBackdrop = phase.backdrop
            window.isOpaque = phase.transparentWindow ? false : originalWindowIsOpaque
            window.backgroundColor = phase.transparentWindow ? .clear : originalWindowBackground
            window.contentView?.layoutSubtreeIfNeeded()
            window.makeKeyAndOrderFront(nil)
            backdrop.order(.below, relativeTo: window.windowNumber)
            try await Task.sleep(for: .milliseconds(450))
            guard NSApplication.shared.isActive, NSApplication.shared.keyWindow === window,
                  window.frame == frame, backdrop.frame.contains(window.frame), window.isVisible,
                  browser.location.directoryURL?.standardizedFileURL == fixture.standardizedFileURL else {
                throw Failure(message: "Browser glass capture lost foreground ownership, fixture location or complete generated backdrop coverage")
            }
            let capture = output.appendingPathComponent("glass-browser-\(phase.name).png")
            try await captureExactWindow(window.windowNumber, to: capture)
            guard NSApplication.shared.isActive, NSApplication.shared.keyWindow === window, window.frame == frame else {
                throw Failure(message: "Browser foreground or geometry changed during exact-window capture")
            }
            let data = try await Task.detached { try Data(contentsOf: capture) }.value
            guard let bitmap = NSBitmapImageRep(data: data) else { throw Failure(message: "Invalid exact-browser PNG") }
            let navigation = try sample(bitmap, window: window, points: navigationPoints)
            let files = try sample(bitmap, window: window, points: filePoints)
            readings.append(["phase": phase.name, "usesWindowBackdrop": phase.backdrop,
                             "windowIsOpaque": window.isOpaque, "windowBackgroundAlpha": window.backgroundColor.alphaComponent,
                             "navigationChannelSpread": channelSpread(navigation), "fileRowChannelSpread": channelSpread(files),
                             "navigationRGBA": navigation, "fileRowRGBA": files])
            colors.append(navigation + files)
        }
        let baselineNavigation = channelSpread(Array(colors[0].prefix(fractions.count)))
        let enabledNavigation = channelSpread(Array(colors[1].prefix(fractions.count)))
        let baselineFiles = Array(colors[0].suffix(fractions.count))
        let enabledFiles = Array(colors[1].suffix(fractions.count))
        let fileDelta = zip(baselineFiles, enabledFiles).flatMap { pair in
            zip(pair.0, pair.1).map { abs($0.0 - $0.1) }
        }.max() ?? 1
        let fileSpread = channelSpread(enabledFiles)
        let enabledFileAlpha = enabledFiles.map { $0[3] }.min() ?? 0
        let passed = enabledNavigation > 0.06 && enabledNavigation > baselineNavigation + 0.035
            && fileSpread < 0.035 && fileDelta < 0.035 && enabledFileAlpha > 0.99
        let experimentNavigation = channelSpread(Array(colors[2].prefix(fractions.count)))
        let experimentFiles = Array(colors[2].suffix(fractions.count))
        let experimentFileSpread = channelSpread(experimentFiles)
        let experimentFileAlpha = experimentFiles.map { $0[3] }.min() ?? 0
        let experimentTransmits = experimentNavigation > 0.06 && experimentNavigation > enabledNavigation + 0.035
            && experimentFileSpread < 0.035 && experimentFileAlpha > 0.99
        let report: [String: Any] = [
            "passed": passed, "mode": "exact-browser-generated-backdrop-comparison",
            "windowNumber": window.windowNumber, "windowIsOpaque": originalWindowIsOpaque,
            "windowBackgroundAlpha": originalWindowBackground.alphaComponent,
            "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            "increaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            "baselineNavigationSpread": baselineNavigation, "enabledNavigationSpread": enabledNavigation,
            "enabledFileRowSpread": fileSpread, "fileRowMaximumRGBChange": fileDelta, "readings": readings,
            "enabledFileRowMinimumAlpha": enabledFileAlpha,
            "transparentWindowNavigationSpread": experimentNavigation,
            "transparentWindowFileRowSpread": experimentFileSpread, "transparentWindowFileRowMinimumAlpha": experimentFileAlpha,
            "windowBackingHypothesisSupported": experimentTransmits,
            "captureBoundary": "Only this app's exact browser window; generated app-owned bands cover its complete backdrop; no desktop or other-app capture. Exact-window capture may omit external backdrop composition; this does not alone settle live appearance.",
            "experimentBoundary": "Third phase changes only this window's opacity/background, restores both, and cannot turn a failing production phase into a pass",
            "notExercised": ["Actual system Trash", "Protected-folder consent or bookmark retention", "Changed system accessibility settings", "Older macOS fallback"],
        ]
        let reportURL = output.appendingPathComponent("glass-browser-comparison.json")
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try await Task.detached { try reportData.write(to: reportURL, options: .atomic) }.value
        guard passed else { throw Failure(message: "Actual browser navigation remains flat or file rows changed through the backdrop; inspect glass-browser-comparison.json") }
        return report
    }

    /// Debug qualification may capture only a known window owned by this process.
    static func captureOwnedWindow(_ window: NSWindow, to png: URL) async throws {
        guard NSApplication.shared.windows.contains(where: { $0 === window }), window.isVisible else {
            throw Failure(message: "Refused a window outside this application")
        }
        try await captureExactWindow(window.windowNumber, to: png)
    }

    private static func captureExactWindow(_ number: Int, to png: URL) async throws {
        guard number > 0 else { throw Failure(message: "Refused invalid browser capture target") }
        try await Task.detached { try captureExactWindowWorker(number, to: png) }.value
    }

    /// Synchronous by design; called only from the detached capture task.
    nonisolated private static func captureExactWindowWorker(_ number: Int, to png: URL) throws {
        let process = Process()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(number), png.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 10) == .success else {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            throw Failure(message: "Exact app-window capture timed out; no desktop capture or permission change attempted")
        }
        guard process.terminationStatus == 0 else {
            throw Failure(message: "Exact app-window capture unavailable; no desktop capture or permission change attempted")
        }
    }

    private static func sample(_ bitmap: NSBitmapImageRep, window: NSWindow, points: [NSPoint]) throws -> [[Double]] {
        let scaleX = CGFloat(bitmap.pixelsWide) / window.frame.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / window.frame.height
        guard abs(scaleX - scaleY) < 0.02 else { throw Failure(message: "Browser capture includes a crop or shadow") }
        return try points.map { point in
            let x = Int(point.x * scaleX)
            let y = Int((window.frame.height - point.y) * scaleY)
            guard x >= 0, x < bitmap.pixelsWide, y >= 0, y < bitmap.pixelsHigh,
                  let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                throw Failure(message: "Browser sample falls outside captured pixels")
            }
            return [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent), Double(color.alphaComponent)]
        }
    }

    private static func channelSpread(_ samples: [[Double]]) -> Double {
        let values: [Double] = (0..<3).map { channel -> Double in
            let components: [Double] = samples.map { $0[channel] }
            return (components.max() ?? 0) - (components.min() ?? 0)
        }
        return values.max() ?? 0
    }

    /// Only feed the PNG captured from this exact generated probe window, with
    /// screencapture's shadow excluded (-o). No capture is requested by this helper.
    /// A flat Regular row over six distinct bands goes red; the opaque row is the
    /// negative control. This measures transmitted color, not subjective styling.
    static func verifyCompositedProbeCapture(at png: URL, for window: NSWindow) throws -> [String: Any] {
        guard window.title == "Mac Explorer — generated glass material probe",
              let bitmap = NSBitmapImageRep(data: try Data(contentsOf: png)),
              window.frame.width > 0, window.frame.height > 0 else {
            throw Failure(message: "Missing exact generated probe capture")
        }
        let scaleX = CGFloat(bitmap.pixelsWide) / window.frame.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / window.frame.height
        guard abs(scaleX - scaleY) < 0.02 else {
            throw Failure(message: "Probe capture dimensions include a crop or shadow")
        }
        func spread(at contentY: CGFloat) throws -> Double {
            var samples: [[CGFloat]] = []
            for index in 0..<6 {
                let point = window.contentView!.convert(NSPoint(x: 75 + CGFloat(index) * 150, y: contentY), to: nil)
                let x = Int(point.x * scaleX)
                let y = Int((window.frame.height - point.y) * scaleY)
                guard x >= 0, x < bitmap.pixelsWide, y >= 0, y < bitmap.pixelsHigh,
                      let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    throw Failure(message: "Probe sample falls outside generated pixels")
                }
                samples.append([color.redComponent, color.greenComponent, color.blueComponent])
            }
            let channelSpreads: [CGFloat] = (0..<3).map { channel -> CGFloat in
                let values: [CGFloat] = samples.map { $0[channel] }
                return values.max()! - values.min()!
            }
            return Double(channelSpreads.max()!)
        }
        let regular = try spread(at: 270)
        let clear = try spread(at: 160)
        let solid = try spread(at: 50)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let expectsNative: Bool
        if #available(macOS 26.0, *) { expectsNative = !reduced } else { expectsNative = false }
        let passed = solid < 0.025 && (!expectsNative || regular > solid + 0.035)
        let report: [String: Any] = [
            "transmittedColorPassed": passed, "regularChannelSpread": regular,
            "clearChannelSpread": clear, "opaqueControlChannelSpread": solid,
            "reduceTransparency": reduced, "windowNumber": window.windowNumber,
            "measurementBoundary": "Exact app-window capture; six generated-band samples, below labels; no subjective appearance claim",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: png.deletingLastPathComponent().appendingPathComponent("glass-composited-probe.json"), options: .atomic)
        guard passed else { throw Failure(message: "Regular glass did not transmit generated background color above the opaque control; inspect glass-composited-probe.json") }
        return report
    }

    private static func probeContent(_ title: String) -> NSView {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(labelWithString: title)
        text.font = .systemFont(ofSize: 15, weight: .semibold)
        text.textColor = .labelColor
        text.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            text.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
        ])
        return content
    }

    private static func nativeGlass(in view: NSView) -> NSView? {
        if #available(macOS 26.0, *), view is NSGlassEffectView { return view }
        for child in view.subviews {
            if let glass = nativeGlass(in: child) { return glass }
        }
        return nil
    }
}

@MainActor
private final class GlassProbeBackdrop: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let colors: [NSColor] = [.systemBlue, .systemPink, .systemGreen, .systemOrange, .systemPurple, .systemYellow]
        let width = bounds.width / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            color.setFill()
            NSRect(x: CGFloat(index) * width, y: 0, width: width + 1, height: bounds.height).intersection(dirtyRect).fill()
        }
    }
}

@MainActor
private final class GlassProbeOpaque: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }
}
#endif
