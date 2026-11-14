#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum InterfaceSizingVerification {
    static func admit(_ root: URL) throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try UIVerification.require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
            "Interface qualification requires an owned generated case")
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any]
        try UIVerification.require(value?["action"] as? String == "traverse-tester-repair-qualification", "Incorrect generated interface authority")
    }
    static func run(browser: BrowserViewController, root: URL) async throws -> [String: Any] {
        let settings = browser.settings, original = settings.interfaceSize
        let selection = browser.selectedURLs, tab = browser.activeID
        defer { settings.interfaceSize = original }
        var roundTrips = 0
        for percent in stride(from: 100, through: 150, by: 5) {
            settings.interfaceSize = .init(percent)
            await Task.yield(); try await Task.sleep(for: .milliseconds(20))
            let reopened = BrowserSettings(persist: false, restoredData: try settings.encodedSnapshot())
            try UIVerification.require(reopened.interfaceSize.percent == percent
                && abs(browser.table.rowHeight - ceil(settings.rowDensity.rowHeight * CGFloat(percent) / 100)) < 0.01,
                "Interface size \(percent): restored \(reopened.interfaceSize.percent), native row \(browser.table.rowHeight), density \(settings.rowDensity.rowHeight)")
            roundTrips += 1
        }
        guard var malformed = try JSONSerialization.jsonObject(with: settings.encodedSnapshot()) as? [String: Any] else {
            throw UIVerification.Failure(message: "Missing sizing preferences")
        }
        for value: Any in [99, 151, 103, "oversized", NSNull()] {
            malformed["interfaceSize"] = value
            let read = BrowserSettings(persist: false, restoredData: try JSONSerialization.data(withJSONObject: malformed))
            try UIVerification.require(read.interfaceSize == .standard && read.newTabDestination == settings.newTabDestination,
                "An invalid text size discarded unrelated preferences")
        }
        malformed["version"] = 18; malformed.removeValue(forKey: "interfaceSize")
        let legacy = BrowserSettings(persist: false, restoredData: try JSONSerialization.data(withJSONObject: malformed))
        try UIVerification.require(legacy.interfaceSize == .standard, "Legacy preferences did not retain standard sizing")
        for _ in 0..<3 { settings.interfaceSize = .init(150); await Task.yield(); settings.interfaceSize = .standard; await Task.yield() }
        try await Task.sleep(for: .milliseconds(80))
        InterfacePresentation.shared.apply(in: browser.view)
        try UIVerification.require(browser.activeID == tab && browser.selectedURLs == selection
            && abs(browser.table.rowHeight - settings.rowDensity.rowHeight) < 0.01,
            "Changing interface size altered navigation/selection or accumulated geometry drift")
        let sample = label("Generated readability sample", size: 13)
        let native = NSView(); native.addSubview(sample)
        InterfacePresentation.shared.register(native)
        settings.interfaceSize = .init(150); await Task.yield()
        try UIVerification.require(abs((sample.font?.pointSize ?? 0) - 19.5) < 0.01,
            "Native typography was not enlarged from its original point size")
        settings.interfaceSize = .standard; await Task.yield()
        try UIVerification.require(abs((sample.font?.pointSize ?? 0) - 13) < 0.01,
            "Native typography did not return exactly to its original point size")
        let preview = try await preview(settings: settings, root: root)
        return ["passed": true, "persistedSteps": roundTrips, "invalidValues": 5,
            "legacyDefault": true, "actualNativeRowsAndFonts": true, "selectionRetained": true,
            "repeatedResetWithoutDrift": true, "bitmapZoom": false, "preview": preview]
    }
    private static func preview(settings: BrowserSettings, root: URL) async throws -> [String: Any] {
        var stacked = true
        let content = InterfaceSizePicker(settings: settings, onArrangementChanged: { stacked = $0 }).padding(22)
        let host = InterfaceHostingController(rootView: content)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 720, height: 570),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Traverse · generated review · interface sizing"
        window.isReleasedWhenClosed = false; window.contentViewController = host
        ToolWindowChrome.install(in: window, settings: settings)
        window.setContentSize(.init(width: 720, height: 570))
        window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        settings.interfaceSize = .standard
        try await Task.sleep(for: .milliseconds(350))
        try UIVerification.require(!stacked, "The wide standard preview did not use A: window \(window.frame.width), host \(host.view.bounds.width), scale \(InterfaceMetrics.scale)")
        func slider(in view: NSView) -> NSSlider? {
            if let value = view as? NSSlider { return value }
            return view.subviews.lazy.compactMap { slider(in: $0) }.first
        }
        let originalSlider = slider(in: host.view)
        var recordings: [String: NativeMotionRecorder.Report] = [:]
        for mode in BrowserMotionMode.allCases {
            settings.motion.mode = mode; settings.interfaceSize = .standard
            try await Task.sleep(for: .milliseconds(350))
            guard let control = slider(in: host.view) else {
                throw UIVerification.Failure(message: "The real preview slider has no accessible control")
            }
            var responder: NSResponder?
            let change: @MainActor () -> Void = {
                window.makeFirstResponder(control)
                // Public native key events exercise the actual bound control;
                // no model assignment substitutes for interacting with it.
                for _ in 0..<10 {
                    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}",
                        isARepeat: false, keyCode: 124) { control.keyDown(with: event) }
                }
                responder = window.firstResponder
            }
            if ProcessInfo.processInfo.arguments.contains("--record-motion") {
                let label = "readability-" + mode.rawValue
                recordings[label] = try await NativeMotionRecorder.record(window: window, root: root, label: label, action: change)
            } else { change(); try await Task.sleep(for: .milliseconds(400)) }
            try UIVerification.require(stacked && settings.interfaceSize.percent == 150,
                "A larger live preview did not stack or its native slider lost the binding")
            if let originalSlider {
                try UIVerification.require(slider(in: host.view) === originalSlider && window.firstResponder === originalSlider,
                    "Adaptive reflow recreated the slider or stole keyboard focus")
            }
            try UIVerification.require(slider(in: host.view)?.accessibilityIdentifier() == "interface-size-slider" && responder === window.firstResponder,
                "Adaptive reflow lost the accessible slider or its native responder")
        }
        try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/readability-150.png"))
        settings.interfaceSize = .standard
        try await Task.sleep(for: .milliseconds(350))
        try UIVerification.require(!stacked, "The preview did not return smoothly to columns")
        try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/readability-100.png"))
        if !recordings.isEmpty {
            try JSONEncoder().encode(recordings).write(to: root.appendingPathComponent("evidence/motion.json"), options: .withoutOverwriting)
        }
        return ["passed": true, "columnAndStacked": true, "nativeSliderExercised": true,
            "accessibleControlAndResponderRetained": true, "motionModes": 3, "recordedClips": recordings.count]
    }
}
#endif
