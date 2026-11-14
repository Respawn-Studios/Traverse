import SwiftUI

/// Finite presentation geometry, independent of animation and catalog state.
/// Scaling before summing also handles several UInt64.max observations.
struct StorageRingLayout {
    struct Segment {
        let index: Int
        let start: Double
        let end: Double
        var middle: Double { (start + end) / 2 }
        var fraction: Double { end - start }
    }
    let segments: [Segment]
    init(bytes: [UInt64?]) {
        let maximum = bytes.compactMap { $0 }.max() ?? 0
        guard maximum > 0 else { segments = []; return }
        let weights = bytes.map { Double($0 ?? 0) / Double(maximum) }
        let sum = weights.reduce(0, +)
        guard sum.isFinite, sum > 0 else { segments = []; return }
        var cursor = 0.0, result: [Segment] = []
        for (index, weight) in weights.enumerated() where weight > 0 {
            let next = min(1, cursor + weight / sum)
            result.append(.init(index: index, start: cursor, end: next)); cursor = next
        }
        if let last = result.popLast() { result.append(.init(index: last.index, start: last.start, end: 1)) }
        segments = result
    }
    func hit(x: Double, y: Double, innerRadius: Double = 0.64) -> Int? {
        guard x.isFinite, y.isFinite else { return nil }
        let radius = hypot(x, y)
        guard radius >= innerRadius, radius <= 1 else { return nil }
        var turn = (atan2(y, x) + .pi / 2) / (2 * .pi)
        if turn < 0 { turn += 1 }
        return segments.first { turn >= $0.start && turn < $0.end }?.index
    }
}

struct StorageRingItem {
    let title: String
    let amount: String
    let bytes: UInt64?
    let canOpen: Bool
    let color: Color
}

private struct StorageRingSector: Shape {
    let start: Double
    let end: Double
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY), outer = min(rect.width, rect.height) / 2
        guard outer.isFinite, outer > 0, start.isFinite, end.isFinite, end > start else { return Path() }
        let inset = min(0.009, (end - start) * .pi * 0.12)
        let a = start * 2 * .pi - .pi / 2 + inset, b = end * 2 * .pi - .pi / 2 - inset
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .radians(a), endAngle: .radians(b), clockwise: false)
        path.addArc(center: center, radius: outer * 0.64, startAngle: .radians(b), endAngle: .radians(a), clockwise: true)
        path.closeSubpath(); return path
    }
}

/// Hover never navigates. A click resolves against immutable, unshifted geometry
/// once; lifting a segment cannot produce a hover/selection feedback cycle.
struct StorageRingChart: View {
    @ObservedObject private var appearance = StorageChartIntegration.appearance
    let items: [StorageRingItem]
    var interactive = true
    var onOpen: (Int) -> Void = { _ in }
    @State private var hovered: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var layout: StorageRingLayout { .init(bytes: items.map(\.bytes)) }
    var body: some View {
        GeometryReader { geometry in
            let diameter = max(0, min(geometry.size.width, geometry.size.height) - 16)
            let shapeRect = CGRect(x: (geometry.size.width - diameter) / 2, y: (geometry.size.height - diameter) / 2, width: diameter, height: diameter)
            ZStack {
                Circle().stroke(.quaternary, lineWidth: max(1, diameter * 0.18))
                    .frame(width: diameter * 0.82, height: diameter * 0.82)
                if !reduceTransparency {
                    Circle().fill(.thinMaterial).frame(width: diameter * 0.58, height: diameter * 0.58).allowsHitTesting(false)
                }
                ForEach(layout.segments, id: \.index) { segment in
                    let item = items[segment.index], highlighted = hovered == segment.index && interactive
                    let lift = highlighted && item.canOpen && !reduceMotion && appearance.motion.allows(.charts) ? 4.0 * appearance.motion.mode.distanceScale : 0
                    let angle = segment.middle * 2 * .pi - .pi / 2
                    StorageRingSector(start: segment.start, end: segment.end)
                        .fill(item.color.gradient)
                        .overlay(StorageRingSector(start: segment.start, end: segment.end).stroke(.white.opacity(highlighted ? 0.52 : 0.12), lineWidth: highlighted ? 1.2 : 0.6))
                        .brightness(highlighted ? 0.12 : 0)
                        .shadow(color: item.color.opacity(highlighted && !reduceTransparency ? 0.32 : 0), radius: 7, y: 3)
                        .frame(width: diameter, height: diameter)
                        .offset(x: cos(angle) * lift, y: sin(angle) * lift)
                        .accessibilityHidden(true)
                }
                if let hovered, items.indices.contains(hovered), let segment = layout.segments.first(where: { $0.index == hovered }) {
                    VStack(spacing: 3) {
                        Text(segment.fraction.formatted(.percent.precision(.fractionLength(1))))
                            .interfaceFont(.system(.callout, design: .rounded, weight: .semibold)).monospacedDigit()
                        Text(items[hovered].title).interfaceFont(.system(size: 9)).lineLimit(2).multilineTextAlignment(.center)
                        Text(items[hovered].amount).interfaceFont(.system(size: 9)).monospacedDigit().lineLimit(1)
                        if items[hovered].canOpen { Image(systemName: "arrow.up.forward").interfaceFont(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
                    }.frame(width: max(0, diameter * 0.56)).allowsHitTesting(false)
                }
                // One stationary interaction plane. The center remains empty.
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover { phase in
                        let next: Int?
                        switch phase {
                        case .active(let location): next = layout.hit(x: Double((location.x - shapeRect.midX) / (diameter / 2)), y: Double((location.y - shapeRect.midY) / (diameter / 2)))
                        case .ended: next = nil
                        }
                        if hovered != next { hovered = next }
                        #if DEBUG
                        StorageRingPointerProbe.hover(next)
                        #endif
                    }
                    .gesture(SpatialTapGesture().onEnded { value in
                        guard interactive, let index = layout.hit(x: Double((value.location.x - shapeRect.midX) / (diameter / 2)), y: Double((value.location.y - shapeRect.midY) / (diameter / 2))),
                              items[index].canOpen else { return }
                        #if DEBUG
                        StorageRingPointerProbe.clicked()
                        #endif
                        onOpen(index)
                    })
                    .help(hovered.flatMap { items.indices.contains($0) ? items[$0].title + " · " + items[$0].amount + (items[$0].canOpen ? " · Click to explore" : "") : nil } ?? "Hover a segment for details. Use the adjacent labels to explore with the keyboard.")
            }
            .animation(reduceMotion || !appearance.motion.allows(.charts) ? nil : .easeOut(duration: 0.16 * appearance.motion.mode.durationScale), value: hovered)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Storage breakdown")
            .accessibilityValue("\(layout.segments.count) observed segments. Statistics and navigation are available in the adjacent list.")
        }
    }
}

#if DEBUG
@MainActor
enum StorageRingPointerProbe {
    static var enabled = false
    static var hoverCount = 0
    static var clickCount = 0
    static func hover(_ index: Int?) { if enabled && index != nil { hoverCount += 1 } }
    static func clicked() { if enabled { clickCount += 1 } }
}
extension StorageRingLayout {
    @MainActor
    static func verify() throws -> [String] {
        let thirds = Self(bytes: [10, nil, 0, 20])
        try UIVerification.require(thirds.segments.count == 2 && thirds.hit(x: 0, y: -0.9) == 0 && thirds.hit(x: -0.9, y: 0) == 3, "Ring hit regions lost their source indices")
        try UIVerification.require(thirds.hit(x: 0, y: 0) == nil && thirds.hit(x: 2, y: 0) == nil && thirds.hit(x: .nan, y: 0) == nil && thirds.hit(x: .infinity, y: 0) == nil, "Invalid/outside ring point was selectable")
        for count in [1, 2, 5, 15] {
            let layout = Self(bytes: Array(repeating: UInt64.max, count: count))
            try UIVerification.require(layout.segments.count == count && layout.segments.last?.end == 1 && layout.segments.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.fraction > 0 }, "Ring overflow produced invalid geometry")
            for segment in layout.segments {
                let a = segment.middle * 2 * Double.pi - Double.pi / 2
                try UIVerification.require(layout.hit(x: cos(a) * 0.8, y: sin(a) * 0.8) == segment.index, "Ring midpoint selected another slice")
            }
        }
        try UIVerification.require(Self(bytes: []).segments.isEmpty && Self(bytes: [0, nil]).segments.isEmpty, "Empty observations created chart bytes")
        return ["finite ring geometry", "stable hit regions", "zero/unknown/overflow ring controls"]
    }
}
#endif
