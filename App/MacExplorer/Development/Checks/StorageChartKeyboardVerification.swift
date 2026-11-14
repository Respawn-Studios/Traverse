#if DEBUG
import AppKit

/// Exercise the legacy nonisolated Objective-C accessibility entry points from
/// a background client. No NSView state is accessed by this test-only bridge.
private final class BackgroundChartAccessibilityClient: @unchecked Sendable {
    let element: NSAccessibilityElement
    init(_ element: NSAccessibilityElement) { self.element = element }
    func invoke() -> (NSRect, Bool, Bool) { (element.accessibilityFrame(), element.accessibilityPerformPress(), !Thread.isMainThread) }
}

@MainActor enum StorageChartKeyboardVerification {
    private static func require(_ condition: Bool, _ message: String) throws { try UIVerification.require(condition, message) }
    static func run() async throws -> [String: Any] {
        let root = StorageChartFrame(id: "root", title: "Generated storage", slices: [
            .init(id: "games", title: "Games", amount: "8 bytes", bytes: 8, canOpen: true, tint: .hex(0x198afe)),
            .init(id: "documents", title: "Documents", amount: "6 bytes", bytes: 6, canOpen: false, tint: .hex(0xfa9619)),
            .init(id: "build", title: "Builds", amount: "4 bytes", bytes: 4, canOpen: true, tint: .hex(0x17c980)),
            .init(id: "zero", title: "Zero", amount: "0 bytes", bytes: 0, canOpen: true, tint: .hex(0xaaaaff)),
            .init(id: "unknown", title: "Unknown", amount: "Unavailable", bytes: nil, canOpen: true, tint: .hex(0xeeaaff))])
        let child = StorageChartFrame(id: "build", title: "Builds", slices: [
            .init(id: "files", title: "Files", amount: "4 bytes", bytes: 4, canOpen: true, tint: .hex(0x17c980))])
        let window = NSWindow(contentRect: .init(x: 180, y: 160, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Generated chart keyboard and accessibility"
        let chart = StorageDimensionalChartView(frame: .init(x: 20, y: 60, width: 430, height: 350))
        let field = NSTextField(frame: .init(x: 20, y: 20, width: 220, height: 24))
        window.contentView?.addSubview(chart); window.contentView?.addSubview(field)
        defer { window.close(); chart.stopPresentation(); window.contentView = nil }
        var deck = [root], opens: [Int] = [], returns: [Int] = []
        chart.onOpen = { [weak chart] index in
            opens.append(index)
            if index == 2 { deck.append(child); chart?.update(deck, style: .tilted, reduceMotion: true, reduceTransparency: true) }
        }
        chart.onReturn = { [weak chart] index in
            returns.append(index); deck = Array(deck.prefix(index + 1))
            chart?.update(deck, style: .tilted, reduceMotion: true, reduceTransparency: true)
        }
        chart.update(deck, style: .tilted, reduceMotion: true, reduceTransparency: true)
        window.makeKeyAndOrderFront(nil)
        try require(window.makeFirstResponder(chart), "Native chart would not accept keyboard focus")
        func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) {
            chart.keyDown(with: UIVerification.key("", code: code, flags: flags, window: window))
        }
        func elements() throws -> [StorageChartAccessibilityElement] {
            guard let values = chart.accessibilityChildren() as? [StorageChartAccessibilityElement] else { throw UIVerification.Failure(message: "No native chart accessibility children") }
            return values
        }
        let original = try elements()
        try require(original.count == 3 && chart.accessibilityRole() == .group
            && original[0].accessibilityLabel() == "Games" && original[0].accessibilityRole() == .button && original[0].isAccessibilityEnabled()
            && (original[0].accessibilityValue() as? String)?.contains("44.4% of observed bytes") == true
            && original[1].accessibilityRole() == .staticText && !original[1].accessibilityPerformPress(),
            "Accessibility labels, exact stats or non-drillable semantics differ")
        key(124); try require(chart.keyboardSelectionForQualification == 0 && chart.presentedHoverForQualification == .slice(0), "Right did not inspect first positive segment")
        key(124); key(49)
        try require(chart.keyboardSelectionForQualification == 1 && opens.isEmpty, "Space opened a nondrillable segment")
        key(125); key(36)
        try require(opens == [2] && chart.frames.count == 2 && chart.keyboardSelectionForQualification == nil,
            "Return did not open the exact keyboard target/reset focus")
        try require(!original[0].accessibilityPerformPress() && original[0].accessibilityFrame() == .zero,
            "Retained accessibility element retargeted into a new layer")
        key(53); try require(returns == [0] && chart.frames.count == 1, "Escape did not return one loaded layer")
        key(123); try require(chart.keyboardSelectionForQualification == 2, "Left did not wrap past zero/unknown segments")
        key(115); try require(chart.keyboardSelectionForQualification == 0, "Home did not inspect first segment")
        key(119); try require(chart.keyboardSelectionForQualification == 2, "End did not inspect last positive segment")
        key(126); try require(chart.keyboardSelectionForQualification == 1, "Up did not cycle backwards")
        let count = opens.count
        key(124, flags: .command)
        try require(chart.keyboardSelectionForQualification == 1 && opens.count == count, "Modified shortcut was consumed as chart navigation")
        try require(window.makeFirstResponder(field) && chart.keyboardSelectionForQualification == nil,
            "Focus loss retained a keyboard highlight")
        for style in StorageChartStyle.allCases {
            chart.update(deck, style: style, reduceMotion: true, reduceTransparency: true)
            let visible = try elements()
            try require(visible.count == 3 && visible.allSatisfy { let frame = $0.accessibilityFrame(); return !frame.isEmpty && frame.minX.isFinite && frame.minY.isFinite && frame.width < 500 && frame.height < 400 },
                "Accessibility frame lost the actual \(style.rawValue) surfaces")
        }
        let beforeResize = try elements()[0].accessibilityFrame()
        chart.setFrameSize(.init(width: 470, height: 380))
        try require(try elements()[0].accessibilityFrame() != beforeResize, "Accessibility geometry did not follow resize")
        let active = try elements()[0]
        try require(active.accessibilityPerformPress() && opens.last == 0, "Accessible Press did not retain its exact segment")
        let client = BackgroundChartAccessibilityClient(active)
        let background = await Task.detached { client.invoke() }.value
        try require(!background.0.isEmpty && background.1 && background.2 && opens.last == 0,
            "A background native accessibility callback touched view state unsafely or lost its target")
        chart.interactive = false
        try require(try elements().allSatisfy { $0.accessibilityRole() == .staticText && !$0.accessibilityPerformPress() },
            "Interactive change retained actionable accessibility buttons")
        chart.interactive = true
        let stale = try elements()[0]
        var replacement = root; replacement.slices[0] = .init(id: "games", title: "New observation", amount: "9 bytes", bytes: 9, canOpen: true, tint: .hex(0x198afe))
        chart.update([replacement], style: .tilted, reduceMotion: true, reduceTransparency: true)
        try require(!stale.accessibilityPerformPress(), "An old accessibility reference inherited new same-ID data")
        chart.update([root], style: .flat, reduceMotion: true, reduceTransparency: true, scopeIdentity: UUID())
        let priorScope = try elements()[0]
        chart.update([root], style: .flat, reduceMotion: true, reduceTransparency: true, scopeIdentity: UUID())
        try require(!priorScope.accessibilityPerformPress() && priorScope.accessibilityFrame() == .zero,
            "Identical visible values let an old reference inherit a different result scope")
        window.makeFirstResponder(chart)
        chart.forceVisiblePresentationForQualification = true
        chart.update([root], style: .tilted, reduceMotion: false, reduceTransparency: false)
        let rootElements = try elements()
        chart.update([root, child], style: .tilted, reduceMotion: false, reduceTransparency: false)
        let moving = try elements()[0]
        try require(chart.isTransitioning && !moving.isAccessibilityEnabled() && !moving.accessibilityPerformPress() && !rootElements[0].accessibilityPerformPress(),
            "Animation accepted an obsolete or moving accessibility target")
        key(124); try require(chart.keyboardSelectionForQualification == nil, "Animation accepted queued keyboard selection")
        chart.stopPresentation()
        chart.update([root, child], style: .flat, reduceMotion: true, reduceTransparency: true)
        guard let action = chart.accessibilityCustomActions()?.first, let selector = action.selector else { throw UIVerification.Failure(message: "No semantic Back action") }
        try require(NSApp.sendAction(selector, to: action.target, from: action) && chart.frames.count == 1,
            "Accessibility Back lost its existing navigation owner")
        let final = try elements()[0]
        window.close()
        try require(!final.accessibilityPerformPress() && final.accessibilityFrame() == .zero && !chart.isAnimating,
            "Closed chart retained accessibility activation or presentation work")
        return ["passed": true, "checks": ["native labels/observed percentages", "nondrillable semantics", "arrow inspection without query", "zero/unknown excluded from slice focus",
            "Return/Space exact target", "Escape Back", "Home/End/wrap", "modifier routing", "focus-loss clearing", "style and resize geometry",
            "semantic Press", "background accessibility callback", "interactive role update", "same-ID data generation refusal", "identical-values different-scope refusal", "stale/transition refusal", "semantic Back", "close and idle drain"],
            "maximum_accessibility_elements": 3, "source_io": false, "voiceover_session_exercised": false,
            "physical_keyboard_exercised": false, "opening_callbacks": opens, "return_callbacks": returns]
    }
}
#endif
