import AppKit

/// Presentation-only values. No source paths, catalog readers or scan ownership.
struct StorageChartTint: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    static func hex(_ value: UInt32) -> Self {
        .init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    fileprivate func distance(_ other: Self) -> Double {
        pow(red - other.red, 2) + pow(green - other.green, 2) + pow(blue - other.blue, 2)
    }
}

struct StorageChartSlice: Sendable, Equatable {
    let id: String
    let title: String
    let amount: String
    let bytes: UInt64?
    let canOpen: Bool
    var tint: StorageChartTint
}

struct StorageChartFrame: Sendable, Equatable {
    let id: String
    let title: String
    var slices: [StorageChartSlice]
    var isValid: Bool {
        !slices.isEmpty && slices.count <= 15 && Set(slices.map(\.id)).count == slices.count
            && slices.allSatisfy { [$0.tint.red, $0.tint.green, $0.tint.blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    }
}

enum StorageChartStyle: String, CaseIterable, Codable, Sendable {
    case tilted, orbitable, flat
    var title: String {
        switch self { case .tilted: "Tilted glass"; case .orbitable: "Orbitable glass"; case .flat: "Flat" }
    }
}

/// Deterministic colors for one loaded frame. The dominant child inherits its
/// selected parent's tint; other children avoid both previous layer palettes.
/// Ninety-six candidates exceed 15 + 15 ancestor colors and 15 current colors.
struct StorageChartPalette {
    static let candidates: [StorageChartTint] = (0..<96).map { index in
        let hue = Double((index * 37) % 96) / 96, saturation = index % 2 == 0 ? 0.74 : 0.62
        let brightness = index % 3 == 0 ? 0.86 : 0.78
        // Explicit sRGB values avoid calibrated-space middle-tone lifting
        // before the surface reflection is applied.
        let h = hue * 6, sector = Int(h), fraction = h - Double(sector)
        let p = brightness * (1 - saturation), q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        let rgb: (Double, Double, Double)
        switch sector % 6 {
        case 0: rgb = (brightness, t, p)
        case 1: rgb = (q, brightness, p)
        case 2: rgb = (p, brightness, t)
        case 3: rgb = (p, q, brightness)
        case 4: rgb = (t, p, brightness)
        default: rgb = (brightness, p, q)
        }
        return .init(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
    static func color(_ frame: StorageChartFrame, inheriting selected: StorageChartTint?, previous: [StorageChartFrame]) -> StorageChartFrame {
        guard frame.isValid else { return frame }
        var result = frame
        let largest = frame.slices.indices.max { (frame.slices[$0].bytes ?? 0) < (frame.slices[$1].bytes ?? 0) }!
        var used = Set(previous.suffix(2).flatMap { $0.slices.map(\.tint) })
        // A quiet violet anchors each overview. Descendants retain the chosen
        // parent's exact tint and the existing two-layer avoidance contract.
        let anchor = selected ?? (previous.isEmpty ? .hex(0x8E5CE8) : nil)
        if let anchor { result.slices[largest].tint = anchor; used.insert(anchor) }
        var assigned: [StorageChartTint] = anchor.map { [$0] } ?? []
        for index in result.slices.indices where anchor == nil || index != largest {
            let available = candidates.enumerated().filter { !used.contains($0.element) }
            // A fixed ID salt breaks equal-distance ties without random changes.
            let salt = result.slices[index].id.utf8.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1) }
            let best = available.max { a, b in
                let left = assigned.map { a.element.distance($0) }.min() ?? 4
                let right = assigned.map { b.element.distance($0) }.min() ?? 4
                return left == right ? (UInt64(a.offset) &+ salt) % 97 < (UInt64(b.offset) &+ salt) % 97 : left < right
            }!.element
            result.slices[index].tint = best; assigned.append(best); used.insert(best)
        }
        return result
    }
}

struct StorageChartCamera: Sendable {
    var pitch = 46.0
    var yaw = -14.0
    var bounded: Self { .init(pitch: pitch.isFinite ? min(76, max(0, pitch)) : 46, yaw: yaw.isFinite ? yaw.truncatingRemainder(dividingBy: 360) : -14) }
}

enum StorageChartHit: Hashable, Sendable {
    case slice(Int)
    case ancestor(Int)
}

struct StorageChartFace {
    enum Surface { case top, outer, inner, end }
    let path: CGPath
    let tint: StorageChartTint
    let shade: Double
    let alpha: Double
    let hit: StorageChartHit
    let surface: Surface
    let depth: Double
    // Projected coverage retains original paint and seated hit paths.
    var projectedVertices: [ChartProjectedVertex] = []
    var visibleCoverage: CGPath? = nil
    /// Only internal tessellation joins may overlap their own slice's paint.
    /// Logical slice edges and radial end panels are true boundaries.
    var internalSideSeams: CGPath? = nil
    var occlusionMetrics: ChartRingOcclusionMetrics? = nil
    var bounds: CGRect { path.boundingBoxOfPath }
}

struct StorageChartScene {
    var faces: [StorageChartFace] = []
    var activeEnvelope: CGPath?
    /// Current surfaces win. The whole current opening blocks ancestor hits.
    /// Hit scenes are seated geometry; visual hover movement cannot oscillate it.
    func hit(_ point: CGPoint) -> StorageChartHit? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        if let face = faces.reversed().first(where: { if case .slice = $0.hit { return $0.path.contains(point) }; return false }) { return face.hit }
        if activeEnvelope?.contains(point) == true { return nil }
        return faces.reversed().first { $0.path.contains(point) }?.hit
    }
}

struct StorageChartTransition {
    enum Direction { case forward, back }
    let direction: Direction
    let from: [StorageChartFrame]
    let to: [StorageChartFrame]
    let selected: Int
    let start: TimeInterval
    let duration: TimeInterval
    let initialHover: StorageChartHit?
    var progress: Double = 0
}

/// Bounded projected polygons, shared by drawing and pointer qualification.
/// At most 15 slices, three visible parents and one transient morph ring.
struct StorageChartGeometry {
    let size: CGSize
    let style: StorageChartStyle
    var camera = StorageChartCamera()
    var reduceMotion = false
    var reduceTransparency = false
    var motionScale = 1.0
    private var radius: Double { max(0, min(size.width * 0.41, size.height * 0.30)) }
    private var center: CGPoint { .init(x: size.width * 0.5, y: size.height * 0.37) }
    private var pitch: Double { style == .flat ? 0 : camera.bounded.pitch * .pi / 180 }
    private var yaw: Double { style == .flat ? 0 : camera.bounded.yaw * .pi / 180 }
    private var step: Double { min(42, radius * 0.32) }
    private func projected(_ angle: Double, _ r: Double, _ z: Double, scale: Double, shift: Double) -> CGPoint {
        let x = cos(angle) * r, y = sin(angle) * r
        return .init(x: center.x + (x * cos(yaw) - y * sin(yaw)) * scale + shift,
                     y: center.y + ((x * sin(yaw) + y * cos(yaw)) * cos(pitch) - z * sin(pitch)) * scale)
    }
    private func arc(_ a: Double, _ b: Double, r: Double, z: Double, scale: Double, shift: Double) -> [CGPoint] {
        let count = max(2, Int(ceil(abs(b - a) * 15)))
        return (0...count).map { projected(a + (b - a) * Double($0) / Double(count), r, z, scale: scale, shift: shift) }
    }
    private func path(_ points: [CGPoint]) -> CGPath {
        let result = CGMutablePath()
        if let first = points.first { result.move(to: first); for p in points.dropFirst() { result.addLine(to: p) }; result.closeSubpath() }
        return result
    }
    private var valid: Bool { size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 && radius > 0 }
    private func alpha(_ depth: Double) -> Double { reduceTransparency || depth > 3 ? 0 : max(0.035, 0.135 - depth * 0.032) }
    private func interpolate(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private func smooth(_ a: Double, _ b: Double, _ p: Double) -> Double { let t = min(1, max(0, (p - a) / (b - a))); return t * t * (3 - 2 * t) }
    private func ease(_ p: Double) -> Double { let t = min(1, max(0, p)); return t * t * t * (t * (t * 6 - 15) + 10) }

    private func chart(_ frame: StorageChartFrame, level: Int?, base: Double = 0, scale: Double = 1,
                       opacity: Double = 1, shift: Double = 0, hover: StorageChartHit? = nil, emphasis: Double = 0,
                       lift: Double = 0, single: (index: Int, start: Double, end: Double)? = nil) -> [StorageChartFace] {
        guard valid, frame.isValid, opacity > 0.00001 else { return [] }
        let layout = StorageRingLayout(bytes: frame.slices.map(\.bytes))
        let thickness = style == .flat ? 0 : min(20, radius * 0.14)
        var sides: [StorageChartFace] = [], tops: [StorageChartFace] = []
        let occlusionDemand = thickness > 0 && level == nil && !reduceMotion
            && abs(emphasis * 10 * motionScale) > 1e-8
            && layout.segments.contains { hover == .slice($0.index) && frame.slices[$0.index].canOpen }
        var raisedHit: StorageChartHit?
        for segment in layout.segments {
            if let single, segment.index != single.index { continue }
            let slice = frame.slices[segment.index]
            var a = segment.start * 2 * .pi - .pi / 2, b = segment.end * 2 * .pi - .pi / 2
            if let single { a = single.start; b = single.end }
            let gap = min(0.014, (b - a) * 0.07); a += gap; b -= gap
            let hit = level.map { StorageChartHit.ancestor($0) } ?? .slice(segment.index)
            let hoverLift = hover == hit && slice.canOpen && !reduceMotion && level == nil ? emphasis * 10 * motionScale : 0
            let z = base + lift + hoverLift
            if occlusionDemand && abs(hoverLift) > 1e-8 { raisedHit = hit }
            func face(_ points: [CGPoint], _ shade: Double, _ surface: StorageChartFace.Surface, _ depth: Double) -> StorageChartFace {
                let vertices: [ChartProjectedVertex] = occlusionDemand ? points.enumerated().map { index, point in
                    let height = surface == .top || index < points.count / 2 ? z : z - thickness
                    // Exact projected camera depth, with actual ring base/scale.
                    return .init(point: point, depth: Double(point.y - center.y) * tan(pitch) + scale * height / cos(pitch))
                } : []
                return .init(path: path(points), tint: slice.tint, shade: shade, alpha: opacity, hit: hit, surface: surface, depth: depth,
                             projectedVertices: vertices)
            }
            if thickness > 0 {
                let pieces = max(1, Int(ceil((b - a) * 15)))
                for i in 0..<pieces {
                    let start = a + (b - a) * Double(i) / Double(pieces), end = a + (b - a) * Double(i + 1) / Double(pieces)
                    for (r, shade, surface) in [(radius, 0.72, StorageChartFace.Surface.outer), (radius * 0.57, 0.50, .inner)] {
                        var side = face(arc(start, end, r: r, z: z, scale: scale, shift: shift) + arc(end, start, r: r, z: z - thickness, scale: scale, shift: shift), shade, surface, sin((start + end) / 2 + yaw) * r)
                        if i > 0 {
                            let seam = CGMutablePath()
                            seam.move(to: projected(start, r, z, scale: scale, shift: shift))
                            seam.addLine(to: projected(start, r, z - thickness, scale: scale, shift: shift))
                            side.internalSideSeams = seam
                        }
                        sides.append(side)
                    }
                }
                for edge in [a, b] {
                    sides.append(face([projected(edge, radius, z, scale: scale, shift: shift), projected(edge, radius * 0.57, z, scale: scale, shift: shift), projected(edge, radius * 0.57, z - thickness, scale: scale, shift: shift), projected(edge, radius, z - thickness, scale: scale, shift: shift)], 0.60, .end, sin(edge + yaw) * radius * 0.8))
                }
            }
            tops.append(face(arc(a, b, r: radius, z: z, scale: scale, shift: shift) + arc(b, a, r: radius * 0.57, z: z, scale: scale, shift: shift), 1, .top, 0))
        }
        let ordered = sides.sorted { $0.depth < $1.depth } + tops
        guard let raisedHit else { return ordered }
        let corrected = ChartRingOcclusion.resolve(ordered, raised: raisedHit)
        guard corrected.first?.occlusionMetrics?.status == "resolved" else {
            // Keep a seated ring when the visibility-work budget is exceeded.
            // Statistics and seated hit paths still work; retain the refusal
            // so qualification never mistakes this for a resolved lifted ring.
            var seated = chart(frame, level: level, base: base, scale: scale,
                opacity: opacity, shift: shift, hover: hover, emphasis: 0,
                lift: lift, single: single)
            if !seated.isEmpty { seated[0].occlusionMetrics = corrected.first?.occlusionMetrics }
            return seated
        }
        return corrected
    }
    private func ancestors(_ deck: [StorageChartFrame], shift: Double = 0, hover: StorageChartHit?, emphasis: Double) -> [StorageChartFace] {
        guard style != .flat else { return [] }
        var result: [StorageChartFace] = []
        for index in max(0, deck.count - 4)..<max(0, deck.count - 1) {
            let depth = Double(deck.count - 1 - index) + shift
            let e = hover == .ancestor(index) ? emphasis : 0
            result += chart(deck[index], level: index, base: -depth * step, scale: 1 + depth * 0.024,
                            opacity: interpolate(alpha(depth), 0.32, e), shift: reduceMotion ? 0 : e * 5 * motionScale)
        }
        return result
    }
    func settled(_ deck: [StorageChartFrame], hover: StorageChartHit? = nil, emphasis: Double = 0) -> StorageChartScene {
        guard valid, let current = deck.last, current.isValid, deck.count <= 17 else { return .init() }
        var scene = StorageChartScene(faces: ancestors(deck, hover: hover, emphasis: emphasis))
        scene.faces += chart(current, level: nil, hover: hover, emphasis: emphasis)
        scene.activeEnvelope = path(arc(0, 2 * .pi, r: radius, z: 0, scale: 1, shift: 0))
        return scene
    }
    func transition(_ state: StorageChartTransition) -> StorageChartScene {
        let p = min(1, max(0, state.progress)), t = ease(p)
        if p == 0 { return settled(state.from, hover: state.initialHover, emphasis: 1) }
        if p == 1 { return settled(state.to) }
        guard valid, let old = state.from.last, let next = state.to.last,
              state.from.allSatisfy(\.isValid), state.to.allSatisfy(\.isValid), state.from.count <= 17, state.to.count <= 17 else { return .init() }
        let parent = state.direction == .forward ? old : next
        let segments = StorageRingLayout(bytes: parent.slices.map(\.bytes)).segments
        guard let selected = segments.first(where: { $0.index == state.selected }) else { return settled(state.to) }
        let a = selected.start * 2 * .pi - .pi / 2, b = selected.end * 2 * .pi - .pi / 2, mid = (a + b) / 2
        var scene = StorageChartScene()
        if state.direction == .forward {
            scene.faces += ancestors(state.from, shift: t, hover: state.initialHover, emphasis: 1 - t)
            scene.faces += chart(old, level: nil, base: -step * t, scale: 1 + t * 0.024, opacity: interpolate(1, style == .flat ? 0 : alpha(1), t), hover: state.initialHover, emphasis: 1 - t)
            let span = interpolate(b - a, 2 * .pi, smooth(0.06, 0.80, p)), lift = sin(.pi * smooth(0, 1, p)) * 20
            scene.faces += chart(old, level: nil, opacity: smooth(0, 0.20, p) * (1 - smooth(0.50, 0.98, p)), lift: lift, single: (state.selected, mid - span / 2, mid + span / 2))
            let reveal = smooth(0.52, 1, p)
            scene.faces += chart(next, level: nil, opacity: reveal, lift: lift * (1 - reveal))
        } else {
            let target = state.to.count - 1, distance = state.from.count - state.to.count
            if style != .flat {
                for index in max(0, target - 3)..<state.from.count - 1 where index != target {
                    let oldDepth = Double(state.from.count - 1 - index), newDepth = Double(target - index)
                    let hovered = state.initialHover == .ancestor(index)
                    let initialOpacity = hovered ? 0.32 : alpha(oldDepth), shift = hovered && !reduceMotion ? 5 * (1 - t) * motionScale : 0
                    if index < target {
                        let depth = interpolate(min(4, oldDepth), newDepth, t)
                        scene.faces += chart(state.from[index], level: index, base: -depth * step, scale: 1 + depth * 0.024, opacity: interpolate(initialOpacity, alpha(newDepth), t), shift: shift)
                    } else { scene.faces += chart(state.from[index], level: index, base: -oldDepth * step + 20 * t, scale: 1 + oldDepth * 0.024, opacity: initialOpacity * (1 - t), shift: shift) }
                }
            }
            let d = Double(min(3, distance)), selectedParent = state.initialHover == .ancestor(target)
            let initialAlpha = style == .flat ? 0 : selectedParent ? 0.32 : alpha(Double(distance))
            scene.faces += chart(next, level: nil, base: -step * d * (1 - t), scale: interpolate(1 + d * 0.024, 1, t), opacity: interpolate(initialAlpha, 1, t), shift: selectedParent && !reduceMotion ? 5 * (1 - t) * motionScale : 0)
            let span = interpolate(2 * .pi, b - a, t)
            scene.faces += chart(next, level: nil, opacity: sin(.pi * t) * 0.88, lift: sin(.pi * t) * 16, single: (state.selected, mid - span / 2, mid + span / 2))
            scene.faces += chart(old, level: nil, scale: interpolate(1, 0.97, t), opacity: 1 - smooth(0.12, 0.98, p), hover: state.initialHover, emphasis: 1 - t, lift: sin(.pi * t) * 16)
        }
        return scene
    }
}
