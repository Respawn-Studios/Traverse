#if DEBUG
import AppKit
import Darwin
import SwiftUI

@MainActor
enum StorageDimensionalChartProbe {
    static var enabled = false
    static weak var latest: StorageDimensionalChartView?
    static var creations = 0
    static var clickCount = 0
    static var hoverCount = 0
    static func created(_ view: StorageDimensionalChartView) { if enabled { latest = view; creations += 1 } }
}

@MainActor
private final class ChartQualificationButton: NSButton {
    var actionBody: () -> Void = {}
    init(_ title: String, _ body: @escaping () -> Void) {
        super.init(frame: .zero); self.title = title; actionBody = body; bezelStyle = .rounded; target = self; action = #selector(run)
    }
    required init?(coder: NSCoder) { fatalError("Generated review only") }
    @objc private func run() { actionBody() }
}

@MainActor
final class StorageDimensionalReviewWindow: NSWindowController {
    let chart = StorageDimensionalChartView()
    let samples = StorageDimensionalChartVerification.sampleFrames()
    var deck: [StorageChartFrame]
    private let pathLabel = NSStackView()
    private let legend = NSStackView()
    private var style = StorageChartStyle.tilted
    private let motionMode: BrowserMotionMode
    private let reduceMotion: Bool
    private let reduceTransparency: Bool
    init(motionMode: BrowserMotionMode = .full, reduceMotion: Bool = false, reduceTransparency: Bool = false) {
        self.motionMode = motionMode; self.reduceMotion = reduceMotion; self.reduceTransparency = reduceTransparency
        deck = [samples[0]]
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 510), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Mac Explorer · Native dimensional chart qualification"
        super.init(window: window)
        window.isReleasedWhenClosed = false; window.center()
        let content = window.contentView!
        let title = NSTextField(labelWithString: "Storage · generated sample")
        title.font = .systemFont(ofSize: 18, weight: .semibold); title.frame = .init(x: 22, y: 462, width: 500, height: 28)
        pathLabel.orientation = .horizontal; pathLabel.spacing = 4; pathLabel.frame = .init(x: 70, y: 418, width: 660, height: 28)
        let back = ChartQualificationButton("Back") { [weak self] in guard let self, self.deck.count > 1 else { return }; self.goBack(self.deck.count - 2) }
        back.frame = .init(x: 20, y: 418, width: 48, height: 28)
        chart.frame = .init(x: 20, y: 55, width: 430, height: 350)
        legend.orientation = .vertical; legend.alignment = .leading; legend.spacing = 8
        legend.frame = .init(x: 466, y: 140, width: 270, height: 250)
        let note = NSTextField(wrappingLabelWithString: "Loaded generated totals only · no scan or file access. Right-click or hold the chart for its three styles. The center never activates older layers.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; note.frame = .init(x: 22, y: 15, width: 710, height: 36)
        for view in [title, pathLabel, back, chart, legend, note] { content.addSubview(view) }
        chart.onOpen = { [weak self] in self?.open($0) }
        chart.onReturn = { [weak self] in self?.goBack($0) }
        chart.onStyle = { [weak self] value in self?.style = value; self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Generated review only") }
    func open(_ index: Int) {
        guard !chart.isTransitioning, let frame = deck.last, frame.slices.indices.contains(index),
              let child = samples.first(where: { $0.id == frame.slices[index].id }) else { return }
        deck.append(StorageChartPalette.color(child, inheriting: frame.slices[index].tint, previous: deck)); refresh()
    }
    func goBack(_ index: Int) { guard !chart.isTransitioning, index >= 0, index < deck.count - 1 else { return }; deck = Array(deck.prefix(index + 1)); refresh() }
    func choose(_ value: StorageChartStyle) { style = value; refresh() }
    private func refresh() {
        for old in pathLabel.arrangedSubviews { pathLabel.removeArrangedSubview(old); old.removeFromSuperview() }
        for (index, frame) in deck.enumerated() {
            let button = ChartQualificationButton(frame.title) { [weak self] in self?.goBack(index) }
            button.isEnabled = index != deck.count - 1; pathLabel.addArrangedSubview(button)
        }
        for old in legend.arrangedSubviews { legend.removeArrangedSubview(old); old.removeFromSuperview() }
        for (index, slice) in (deck.last?.slices ?? []).enumerated() {
            let button = ChartQualificationButton(slice.title + " · " + slice.amount + (slice.canOpen ? "  ›" : "")) { [weak self] in self?.open(index) }
            button.contentTintColor = slice.tint.nsColor; legend.addArrangedSubview(button)
        }
        chart.update(deck, style: style, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency, motionMode: motionMode)
    }
}

@MainActor
enum StorageDimensionalChartVerification {
    static var review: StorageDimensionalReviewWindow?
    static func sampleFrames() -> [StorageChartFrame] {
        func frame(_ id: String, _ title: String, _ values: [(String, String, Double, Bool)]) -> StorageChartFrame {
            .init(id: id, title: title, slices: values.enumerated().map { index, row in
                .init(id: row.0, title: row.1, amount: String(format: "%.1f GB", row.2), bytes: UInt64(row.2 * 1_000_000_000), canOpen: row.3, tint: .hex([0x32aaff, 0xa384ff, 0x4bd5bb, 0xf0789c, 0xe9b758, 0x6fcc7d, 0xb894e6][index % 7]))
            })
        }
        return [frame("root", "Workspace", [("steam", "Steam & games", 94, true), ("build", "Build outputs", 46, true), ("models", "Models & datasets", 38, true), ("apps", "Applications", 32, false), ("docs", "Documents", 20, false), ("media", "Photos & media", 18, false), ("other", "Other observed", 10, false)]),
                frame("steam", "Steam & games", [("games", "Games", 72, true), ("tools", "Tools", 4, false), ("workshop", "Workshop items", 11, false), ("downloads", "Download cache", 7, false)]),
                frame("games", "Games", [("dota", "Dota 2", 32, true), ("cs", "Counter-Strike 2", 24, false), ("games-other", "Other games", 16, false)]),
                frame("dota", "Dota 2", [("files", "Game files", 30, false), ("shaders", "Shader cache", 1.5, false), ("config", "Configuration", 0.5, false)]),
                frame("build", "Build outputs", [("flutter", "Flutter builds", 24, false), ("xcode", "Xcode derived data", 14, false), ("build-other", "Other builds", 8, false)]),
                frame("models", "Models & datasets", [("local-models", "Local models", 28, false), ("datasets", "Datasets", 10, false)])]
    }
    private static func require(_ value: Bool, _ message: String) throws { try UIVerification.require(value, message) }
    private static func wait(_ message: String, _ condition: @escaping () -> Bool) async throws {
        let limit = CACurrentMediaTime() + 4
        while !condition(), CACurrentMediaTime() < limit { try await Task.sleep(for: .milliseconds(15)) }
        try require(condition(), message)
    }
    private static func rss() -> UInt64 {
        var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage); return UInt64(max(0, usage.ru_maxrss))
    }
    /// One loaded-data flow through the ordinary native view and existing recorder.
    /// Events are programmatic; no physical-input or scan qualification follows.
    static func motionReview(root: URL, settings: BrowserSettings) async throws -> (checks: [String: Any], clips: [[String: Any]]) {
        let paintChecks = try sidewallPaintChecks()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !settings.motion.allows(.charts)
        let controller = StorageDimensionalReviewWindow(motionMode: settings.motion.mode,
            reduceMotion: reduceMotion,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        let chart = controller.chart
        guard let window = controller.window else { throw UIVerification.Failure(message: "Generated chart window is unavailable") }
        defer { chart.stopPresentation(); controller.close() }
        ToolWindowChrome.install(in: window, settings: settings)
        window.title = "Storage chart · generated review"
        window.acceptsMouseMovedEvents = true
        controller.deck = StorageChartIntegration.colored(controller.deck)
        controller.choose(.tilted)
        controller.showWindow(nil); window.center(); window.makeKeyAndOrderFront(nil); NSApplication.shared.activate()
        func visible() -> Bool {
            window.isVisible && window.occlusionState.contains(.visible)
                && window.screen?.visibleFrame.contains(window.frame) == true
        }
        try await wait("Generated chart did not become visible") { visible() && window.isKeyWindow }
        var events: [[String: Any]] = [], clips: [[String: Any]] = []
        let measured = NativeMotionRecorder.Sampling.diagnostic(for: window)
        let sampling = NativeMotionRecorder.Sampling(width: measured.width, height: measured.height,
            fps: 60, maximumFrames: 90, preRollMilliseconds: 120, afterMilliseconds: 900, diagnostic: true)
        func key(_ code: UInt16) {
            events.append(["kind": "keyDown", "keyCode": code, "uptimeSeconds": CACurrentMediaTime()])
            window.sendEvent(UIVerification.key("", code: code, flags: [], window: window))
        }
        func point(_ index: Int) throws -> CGPoint {
            let scene = chart.sceneForQualification()
            guard let top = scene.faces.first(where: { $0.hit == .slice(index) && $0.surface == .top }) else {
                throw UIVerification.Failure(message: "Generated chart segment is unavailable")
            }
            for y in [0.2, 0.35, 0.5, 0.65, 0.8] {
                for x in [0.2, 0.35, 0.5, 0.65, 0.8] {
                    let value = CGPoint(x: top.bounds.minX + top.bounds.width * x, y: top.bounds.minY + top.bounds.height * y)
                    if top.path.contains(value), scene.hit(value) == .slice(index) { return value }
                }
            }
            throw UIVerification.Failure(message: "No seated generated chart target was found")
        }
        func mouse(_ type: NSEvent.EventType, _ index: Int) throws {
            let local = try point(index)
            guard let event = NSEvent.mouseEvent(with: type, location: chart.convert(local, to: nil), modifierFlags: [],
                timestamp: CACurrentMediaTime(), windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: 0) else {
                throw UIVerification.Failure(message: "Generated chart event is unavailable")
            }
            events.append(["kind": String(describing: type), "segment": index, "localX": local.x, "localY": local.y,
                "uptimeSeconds": CACurrentMediaTime()])
            switch type {
            case .mouseMoved: chart.mouseMoved(with: event)
            case .leftMouseDown: chart.mouseDown(with: event)
            case .leftMouseUp: chart.mouseUp(with: event)
            default: break
            }
        }
        func record(_ label: String, action: @MainActor () throws -> Void) async throws {
            try require(visible(), "Generated chart lost visible ownership before recording")
            let movie = try await NativeMotionRecorder.record(window: window, root: root, label: label, sampling: sampling, action: action)
            try JSONEncoder().encode(movie).write(to: root.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
            var clip = DevelopmentMotionVerification.clip(label, report: movie, field: nil, window: window)
            clip["interaction"] = "programmatic native events or control action"
            clip["physicalInputExercised"] = false
            clips.append(clip)
            try await wait("Generated chart motion did not settle") { !chart.isAnimating }
        }
        func capture(_ label: String) async throws {
            try require(visible(), "Generated chart lost visible ownership before capture")
            window.contentView?.layoutSubtreeIfNeeded(); window.contentView?.displayIfNeeded()
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/\(label).png"))
        }
        try require(controller.deck.last?.slices.count == 7 && window.makeFirstResponder(chart), "Generated chart root or native focus is unavailable")
        try await capture("chart-root")
        key(124); try await wait("Generated chart focus did not settle") { !chart.isAnimating }
        try require(chart.keyboardSelectionForQualification == 0, "Generated chart did not select its first segment")
        try await capture("chart-focus-a")
        try await record("chart-keyboard-transfer") {
            let outgoing = chart.presentedHoverForQualification, lift = chart.hoverEmphasisForQualification
            key(124)
            if !reduceMotion {
                try require(chart.presentedHoverForQualification == outgoing && chart.hoverEmphasisForQualification == lift,
                    "Keyboard handoff reset its outgoing pose before lowering")
            }
        }
        try require(chart.keyboardSelectionForQualification == 1, "Generated chart did not transfer keyboard focus")
        try await capture("chart-focus-b")
        try mouse(.mouseMoved, 0); try await wait("Generated chart pointer did not settle") { !chart.isAnimating }
        try await record("chart-pointer-transfer") {
            let outgoing = chart.presentedHoverForQualification, lift = chart.hoverEmphasisForQualification
            try mouse(.mouseMoved, 1)
            if !reduceMotion {
                try require(chart.presentedHoverForQualification == outgoing && chart.hoverEmphasisForQualification == lift,
                    "Pointer handoff reset its outgoing pose before lowering")
            }
        }
        let beforeSameSegment = chart.draws
        for _ in 0..<8 { try mouse(.mouseMoved, 1); try await Task.sleep(for: .milliseconds(20)) }
        let sameSegmentDraws = chart.draws - beforeSameSegment
        try require(sameSegmentDraws == 0, "Pointer movement inside one settled segment redrew its geometry")
        try mouse(.mouseMoved, 0); try await wait("Generated chart drill hover did not settle") { !chart.isAnimating }
        try await record("chart-open-steam") { try mouse(.leftMouseDown, 0); try mouse(.leftMouseUp, 0) }
        try require(controller.deck.last?.id == "steam", "Generated chart opened the wrong first level")
        try await record("chart-open-games") { try mouse(.leftMouseDown, 0); try mouse(.leftMouseUp, 0) }
        try require(controller.deck.last?.id == "games", "Generated chart opened the wrong second level")
        try await capture("chart-descendant")
        let stacks = chart.superview?.subviews.compactMap { $0 as? NSStackView } ?? []
        guard let breadcrumb = stacks.flatMap(\.arrangedSubviews).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Workspace" }) else {
            throw UIVerification.Failure(message: "Generated chart ancestor control is unavailable")
        }
        try await record("chart-return-root") {
            events.append(["kind": "breadcrumb performClick", "target": "root", "uptimeSeconds": CACurrentMediaTime()])
            breadcrumb.performClick(nil)
        }
        try require(controller.deck.count == 1, "Generated chart ancestor return did not restore its root")
        for style in [StorageChartStyle.orbitable, .flat] {
            controller.choose(style); window.contentView?.displayIfNeeded()
            try await capture("chart-\(style.rawValue)")
        }
        controller.choose(.tilted); window.contentView?.displayIfNeeded()
        let idleTicks = chart.ticks
        try await Task.sleep(for: .milliseconds(180))
        try require(!chart.isAnimating && chart.ticks == idleTicks, "Generated chart retained an idle animation driver")
        // After the matching visual flow, replace an in-flight request and
        // cancel its successor. Neither may briefly raise the stale target.
        if !reduceMotion {
            chart.hoverForQualification(.slice(0)); try await wait("Retargeting setup did not settle") { !chart.isAnimating }
            let lift = chart.hoverEmphasisForQualification
            chart.hoverForQualification(.slice(1)); chart.hoverForQualification(.slice(2))
            try require(chart.presentedHoverForQualification == .slice(0) && chart.hoverEmphasisForQualification == lift,
                "Rapid retargeting reset the outgoing pose")
            try await wait("Latest hover request did not settle") { !chart.isAnimating }
            try require(chart.presentedHoverForQualification == .slice(2) && chart.hoverEmphasisForQualification == 1,
                "A superseded hover request replaced the latest target")
            chart.hoverForQualification(.slice(0)); chart.hoverForQualification(nil)
            try await wait("Cancelled hover handoff did not settle") { !chart.isAnimating }
            try require(chart.presentedHoverForQualification == nil && chart.hoverEmphasisForQualification == 0,
                "Cancelled hover handoff retained a stale target")
            chart.hoverForQualification(.slice(0)); try await wait("Hover deadline setup did not settle") { !chart.isAnimating }
            chart.pauseDisplayClockForQualification()
            chart.hoverForQualification(.slice(1)); chart.hoverForQualification(.slice(2))
            try await wait("Paused-clock hover handoff missed its finite deadline") { !chart.isAnimating }
            try require(chart.presentedHoverForQualification == .slice(2) && chart.hoverEmphasisForQualification == 1,
                "Paused-clock hover deadline selected a superseded target")
            chart.hoverForQualification(nil); try await wait("Paused-clock hover exit missed its finite deadline") { !chart.isAnimating }
            try require(chart.presentedHoverForQualification == nil, "Paused-clock hover exit retained its target")
        } else {
            chart.hoverForQualification(.slice(0)); chart.hoverForQualification(.slice(2))
            try require(!chart.isAnimating && chart.presentedHoverForQualification == .slice(2) && chart.hoverEmphasisForQualification == 1,
                "Disabled chart motion delayed the requested target")
            chart.hoverForQualification(nil)
            try require(!chart.isAnimating && chart.presentedHoverForQualification == nil && chart.hoverEmphasisForQualification == 0,
                "Disabled chart motion retained its exited target")
        }
        try JSONSerialization.data(withJSONObject: ["interaction": "programmatic native events or control action",
            "physicalInputExercised": false, "events": events], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("evidence/chart-events.json"), options: .withoutOverwriting)
        return (["passed": true, "loadedGeneratedTotalsOnly": true, "rootSlices": 7, "paintOwnershipChecks": paintChecks,
            "interaction": "programmatic native events or control action", "physicalInputExercised": false,
            "sameSegmentMovementDraws": sameSegmentDraws, "idleDriverStopped": true,
            "outgoingPosePreserved": reduceMotion ? "NOT EXERCISED (motion disabled)" : "passed",
            "latestHoverAndCancellation": true,
            "pausedHoverDeadline": reduceMotion ? "NOT EXERCISED (motion disabled)" : "passed",
            "scannerRequested": false, "analysisOwnerInstantiated": false, "rendererSize": ["width": chart.bounds.width, "height": chart.bounds.height]], clips)
    }
    /// The same focused real-renderer raster contract runs in the geometry
    /// check and ordinary storage-chart motion flow; no duplicate renderer.
    private static func sidewallPaintChecks() throws -> [String] {
        let raster = StorageDimensionalChartView(frame: .init(x: 0, y: 0, width: 320, height: 300))
        defer { raster.stopPresentation() }
        // The actual sidewall mesh has shared polygon edges. A half-pixel
        // boundary must not multiply alpha and reveal a darker stripe.
        let sidewalls = [CGRect(x: 10.5, y: 10, width: 20, height: 40), CGRect(x: 30.5, y: 10, width: 20, height: 40)].enumerated().map { index, rect in
            var face = StorageChartFace(path: CGPath(rect: rect, transform: nil), tint: .hex(0x32aaff), shade: 0.72,
                alpha: 1, hit: .slice(0), surface: .outer, depth: 0)
            if index > 0 {
                let seam = CGMutablePath(); seam.move(to: .init(x: rect.minX, y: rect.minY))
                seam.addLine(to: .init(x: rect.minX, y: rect.maxY)); face.internalSideSeams = seam
            }
            return face
        }
        let wallPixels = raster.rasterForQualification(.init(faces: sidewalls))
        // CGBitmapContext row storage runs opposite the Quartz y coordinate.
        let bitmapRow: Int = 269
        let seamIndex: Int = (bitmapRow * 320 + 30) * 4 + 3
        let seamAlpha = wallPixels[seamIndex]
        let interiorIndex = (bitmapRow * 320 + 20) * 4
        let interiorAlpha = wallPixels[interiorIndex + 3]
        let channelsMatch = (0..<4).allSatisfy { abs(Int(wallPixels[seamIndex - 3 + $0]) - Int(wallPixels[interiorIndex + $0])) <= 2 }
        try require(interiorAlpha >= 200 && abs(Int(seamAlpha) - Int(interiorAlpha)) <= 2 && channelsMatch,
            "Adjacent sidewall polygons disagree with the continuous interior: \(seamAlpha)/\(interiorAlpha)")
        // Separate logical slices own distinct colors and a true one-pixel
        // gap. A full-polygon seam stroke used to paint both colors into that
        // empty gap, regardless of their painter order. Internal joins may
        // overlap; these logical boundaries have no internal seam path.
        let distinct = [
            StorageChartFace(path: CGPath(rect: CGRect(x: 10, y: 10, width: 20, height: 40), transform: nil),
                tint: .hex(0x0033ff), shade: 0.72, alpha: 1, hit: .slice(0), surface: .outer, depth: 0),
            StorageChartFace(path: CGPath(rect: CGRect(x: 31, y: 10, width: 20, height: 40), transform: nil),
                tint: .hex(0xff3300), shade: 0.72, alpha: 1, hit: .slice(1), surface: .end, depth: 1)
        ]
        for faces in [distinct, Array(distinct.reversed())] {
            let pixels = raster.rasterForQualification(.init(faces: faces))
            let gap = (bitmapRow * 320 + 30) * 4
            let left = (bitmapRow * 320 + 20) * 4, right = (bitmapRow * 320 + 40) * 4
            try require(pixels[left + 3] >= 200 && pixels[right + 3] >= 200
                && Array(pixels[left..<(left + 3)]) != Array(pixels[right..<(right + 3)]),
                "Distinct-color ownership regression did not paint both logical faces")
            try require(pixels[gap + 3] == 0,
                "A sidewall seam stroke escaped its logical slice into the neighboring gap: alpha \(pixels[gap + 3])")
        }
        return ["adjacent sidewall alpha has no tessellation seam",
            "distinct-color side/end boundaries preserve their gap in either painter order"]
    }
    static func run(keepReview: Bool = false, captureEvidence: Bool = true, geometryOnly: Bool = false) async throws -> [String: Any] {
        let began = CACurrentMediaTime(), before = rss()
        let raw = sampleFrames(); var deck = [raw[0]]
        for next in raw[1...3] {
            let chosen = deck.last!.slices.first { $0.id == next.id }!
            let colored = StorageChartPalette.color(next, inheriting: chosen.tint, previous: deck)
            let largest = colored.slices.max { ($0.bytes ?? 0) < ($1.bytes ?? 0) }!
            try require(largest.tint == chosen.tint, "Dominant child lost the chosen color")
            let old = Set(deck.suffix(2).flatMap { $0.slices.map(\.tint) })
            try require(colored.slices.filter { $0.id != largest.id }.allSatisfy { !old.contains($0.tint) }
                        && Set(colored.slices.map(\.tint)).count == colored.slices.count, "Colors repeated across two layers")
            deck.append(colored)
        }
        var dense: [StorageChartFrame] = []
        for level in 0..<5 {
            let value = StorageChartFrame(id: "dense-\(level)", title: "Dense", slices: (0..<15).map {
                .init(id: "d\(level)-\($0)", title: "Slice \($0)", amount: "observed", bytes: $0 == 0 ? .max : UInt64($0), canOpen: true, tint: .hex(0x32aaff))
            })
            let selected = dense.last?.slices[0].tint
            let colored = StorageChartPalette.color(value, inheriting: selected, previous: dense)
            try require(Set(colored.slices.map(\.tint)).count == 15, "Dense palette exhausted")
            let old = Set(dense.suffix(2).flatMap { $0.slices.map(\.tint) })
            if selected != nil { try require(colored.slices.dropFirst().allSatisfy { !old.contains($0.tint) }, "Dense palettes repeated") }
            dense.append(colored)
        }
        for style in StorageChartStyle.allCases {
            var empty = raw[0]
            empty.slices = [StorageChartSlice(id: "zero", title: "Zero", amount: "0", bytes: 0, canOpen: false, tint: .hex(0x32aaff)),
                            StorageChartSlice(id: "unknown", title: "Unknown", amount: "Unknown", bytes: nil, canOpen: false, tint: .hex(0xa384ff))]
            let compact = StorageChartGeometry(size: .init(width: 160, height: 160), style: style, camera: .init(pitch: .nan, yaw: .infinity))
            try require(compact.settled([empty]).faces.isEmpty && compact.settled([empty]).hit(.init(x: 80, y: 59)) == nil,
                        "Zero/unknown values created selectable bytes")
            try require(StorageChartGeometry(size: .zero, style: style).settled(deck).faces.isEmpty, "Empty viewport created geometry")
            try require(!compact.settled(deck).faces.isEmpty, "Bounded camera or compact layout lost known values")
        }
        var checks = ["selected color becomes dominant child", "two ancestor palettes avoided", "five dense fifteen-slice palettes", "compact zero/unknown/invalid-camera geometry"]
        let raster = StorageDimensionalChartView(frame: .init(x: 0, y: 0, width: 320, height: 300))
        checks += try sidewallPaintChecks()
        var blocked = 0, surfaces = Set<String>(), maxFaces = 0, maximumEndpointError = 0.0
        for style in StorageChartStyle.allCases {
            let geometry = StorageChartGeometry(size: .init(width: 320, height: 300), style: style)
            let scene = geometry.settled(deck)
            try require(scene.hit(.init(x: 160, y: 111)) == nil && scene.hit(.init(x: CGFloat.nan, y: 0)) == nil, "Chart center or invalid point activated a layer")
            for face in scene.faces {
                maxFaces = max(maxFaces, scene.faces.count)
                try require([face.bounds.minX, face.bounds.minY, face.bounds.width, face.bounds.height, face.alpha].allSatisfy(\.isFinite), "Nonfinite chart geometry")
                let point = CGPoint(x: face.bounds.midX, y: face.bounds.midY)
                if face.surface == .outer, scene.hit(point) == face.hit { surfaces.insert("outer") }
                if face.surface == .end, scene.hit(point) == face.hit { surfaces.insert("end") }
            }
            for x in stride(from: 120.0, through: 200, by: 4) {
                for y in stride(from: 90.0, through: 132, by: 4) {
                    let point = CGPoint(x: x, y: y)
                    let current = scene.faces.contains { if case .slice = $0.hit { return $0.path.contains(point) }; return false }
                    let ancestor = scene.faces.contains { if case .ancestor = $0.hit { return $0.path.contains(point) }; return false }
                    if !current, ancestor, scene.activeEnvelope?.contains(point) == true { blocked += 1; try require(scene.hit(point) == nil, "Ancestor was clickable through the current opening") }
                }
            }
            for route in 0..<3 {
                let direction: StorageChartTransition.Direction = route == 0 ? .forward : .back
                let old = direction == .forward ? Array(deck.dropLast()) : deck
                let new = route == 2 ? Array(deck.prefix(1)) : direction == .forward ? deck : Array(deck.dropLast())
                for initialHover: StorageChartHit? in [nil, direction == .forward ? .slice(0) : .ancestor(new.count - 1)] {
                var transition = StorageChartTransition(direction: direction, from: old, to: new, selected: 0, start: 0, duration: 1, initialHover: initialHover)
                let endpoints = [0.0, 1.0]
                for p in endpoints {
                    transition.progress = p
                    let exact = raster.rasterForQualification(geometry.transition(transition))
                    let stable = raster.rasterForQualification(geometry.settled(p == 0 ? old : new, hover: p == 0 ? initialHover : nil, emphasis: p == 0 ? 1 : 0))
                    try require(exact == stable, "A transition endpoint cut to a different image")
                    transition.progress = p == 0 ? 0.001 : 0.999
                    let near = raster.rasterForQualification(geometry.transition(transition))
                    let error = zip(exact, near).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(exact.count)
                    maximumEndpointError = max(maximumEndpointError, error)
                    try require(error < 0.35, "Visible discontinuity at a transition endpoint: \(style.rawValue), \(direction), endpoint \(p), mean byte error \(error)")
                }
                transition.progress = 0.5; maxFaces = max(maxFaces, geometry.transition(transition).faces.count)
                }
            }
        }
        try require(blocked > 5 && surfaces == ["outer", "end"] && maxFaces < 1500, "Projected-surface or bounded-geometry controls were not exercised")
        checks += ["center opening blocks visible ancestors", "projected outer/end hits", "finite bounded geometry", "pixel-identical settled endpoints", "continuous near-endpoint raster"]
        if geometryOnly {
            raster.stopPresentation()
            return ["passed": true, "checks": checks, "maximum_endpoint_byte_error": maximumEndpointError,
                "maximum_faces": maxFaces, "display_cadence_exercised": false, "scope": "geometry and raster only",
                "elapsed_seconds": CACurrentMediaTime() - began]
        }
        // Measure the actual native surface with a view-bound display link.
        let controller = StorageDimensionalReviewWindow()
        guard let window = controller.window else { throw UIVerification.Failure(message: "No native chart window") }
        controller.showWindow(nil); window.makeKeyAndOrderFront(nil); NSApplication.shared.activate()
        defer { if !keepReview { controller.close() }; raster.stopPresentation() }
        try await Task.sleep(for: .milliseconds(100))
        for style in [StorageChartStyle.tilted, .orbitable] {
            controller.choose(style)
            for _ in 0..<2 {
                controller.open(0); try await wait("Native forward animation did not settle") { !controller.chart.isAnimating }
                controller.goBack(0); try await wait("Native Back animation did not settle") { !controller.chart.isAnimating }
            }
        }
        let surface = controller.chart, count = surface.ticks
        try await Task.sleep(for: .milliseconds(200))
        try require(count > 20 && surface.ticks == count && !surface.isAnimating, "Native chart ran an idle animation loop")
        surface.hoverForQualification(.slice(0)); try await wait("Native hover did not settle") { !surface.isAnimating }
        surface.hoverForQualification(nil); try await wait("Native hover exit did not settle") { !surface.isAnimating }
        let p95 = surface.intervals.sorted()[max(0, Int(Double(surface.intervals.count - 1) * 0.95))]
        let maximum = surface.intervals.max() ?? 0
        try require(p95 <= 0.025 && maximum <= 0.050, "Native animation frame gate failed")
        checks += ["actual forward and Back display scheduling", "idle driver stops", "hover settles and stops"]
        // Exercise the SwiftUI bridge and its stable native view identity.
        StorageDimensionalChartProbe.enabled = true; defer { StorageDimensionalChartProbe.enabled = false }
        let bridge = NSHostingView(rootView: StorageDimensionalChart(frames: [deck[0]], reduceMotion: true))
        let bridgeWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        bridgeWindow.isReleasedWhenClosed = false; bridgeWindow.contentView = bridge; bridgeWindow.orderFront(nil)
        try await wait("SwiftUI chart bridge was not created") { StorageDimensionalChartProbe.latest != nil }
        let original = StorageDimensionalChartProbe.latest!, creations = StorageDimensionalChartProbe.creations
        bridge.rootView = StorageDimensionalChart(frames: deck, reduceMotion: true, reduceTransparency: true)
        try await wait("Reduced-motion bridge did not update") { original.frames.count == 4 }
        try require(StorageDimensionalChartProbe.latest === original && StorageDimensionalChartProbe.creations == creations && !original.isAnimating, "Native bridge recreated its renderer or animated reduced motion")
        bridgeWindow.close(); try await wait("Bridge close retained animation work") { !original.isAnimating }
        controller.choose(.tilted); controller.open(0)
        try require(controller.chart.isAnimating, "Close-during-transition control did not start")
        controller.close(); try require(!surface.isAnimating, "Close retained the chart driver")
        checks += ["stable SwiftUI native surface", "reduced motion/transparency update", "close during transition stops driver"]
        let added = rss() > before ? rss() - before : 0
        try require(added <= 16 << 20 && ApplicationFileActivity.gate.activeCount == 0, "Chart qualification exceeded memory or retained activity")
        // Evidence rendering follows the measured chart exercise; capture
        // bitmap allocations are not counted as renderer working memory.
        if captureEvidence {
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        let capture = StorageDimensionalReviewWindow(); capture.showWindow(nil)
        capture.open(0); try await wait("Evidence chart settled") { !capture.chart.isAnimating }
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            capture.window?.appearance = NSAppearance(named: appearance)
            if let window = capture.window { try await UIVerification.snapshot(window, to: repository.appendingPathComponent(".build/b06-analyzer/evidence-extension-20261018/dimensional-native-" + name + "-" + UUID().uuidString + ".png")) }
        }
        capture.close()
        }
        if keepReview { let live = StorageDimensionalReviewWindow(); live.showWindow(nil); live.window?.makeKeyAndOrderFront(nil); review = live }
        return ["passed": true, "checks": checks, "blocked_center_samples": blocked, "maximum_faces": maxFaces,
                "maximum_endpoint_byte_error": maximumEndpointError, "frame_p95_seconds": p95, "frame_max_seconds": maximum,
                "draw_max_seconds": surface.drawTimes.max() ?? 0, "native_ticks": surface.ticks,
                "additional_parent_peak_bytes": added, "gate_active": ApplicationFileActivity.gate.activeCount,
                "elapsed_seconds": CACurrentMediaTime() - began]
    }
}
#endif
