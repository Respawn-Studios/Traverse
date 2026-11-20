import AppKit
import SwiftUI

struct EditorComparisonChangeMap: Equatable, Sendable {
    struct Mark: Equatable, Sendable {
        let before: ClosedRange<Double>
        let current: ClosedRange<Double>

        func span(on side: EditorComparisonPlan.Side) -> ClosedRange<Double> {
            side == .before ? before : current
        }
    }

    let marks: [Mark]

    init?(_ plan: EditorComparisonPlan) {
        guard !plan.grouped, plan.changes.count > 1 else { return nil }
        func span(_ lines: Range<Int>, total: Int) -> ClosedRange<Double> {
            Double(lines.lowerBound) / Double(total)...Double(lines.upperBound) / Double(total)
        }
        marks = plan.changes.map { change in
            .init(before: span(change.beforeLines, total: plan.beforeIndex.starts.count),
                  current: span(change.currentLines, total: plan.currentIndex.starts.count))
        }
    }

    func nearest(_ position: Double, on side: EditorComparisonPlan.Side) -> Int? {
        func distance(to index: Int) -> Double {
            let span = marks[index].span(on: side)
            return max(span.lowerBound - position, position - span.upperBound, 0)
        }
        return marks.indices.min { distance(to: $0) < distance(to: $1) }
    }
}

struct EditorComparisonMapView: NSViewRepresentable {
    let map: EditorComparisonChangeMap
    let selection: Int
    let enabled: Bool
    let choose: (Int) -> Bool

    func makeNSView(context: Context) -> NativeEditorComparisonMap { NativeEditorComparisonMap() }

    func updateNSView(_ view: NativeEditorComparisonMap, context: Context) {
        view.install(map, selection: selection, enabled: enabled, choose: choose)
    }
}

/// One native control for pointer, keyboard and accessibility navigation.
/// The comparison still owns the selected change and both text viewports.
final class NativeEditorComparisonMap: NSControl {
    private var map: EditorComparisonChangeMap?
    private var selected = 0
    private var choose: ((Int) -> Bool)?

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Change map")
        setAccessibilityHelp("Move to a change in the comparison.")
        toolTip = "Jump to a change. The upper track shows the first document and the lower track shows the second."
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }

    func install(_ map: EditorComparisonChangeMap, selection: Int, enabled: Bool, choose: @escaping (Int) -> Bool) {
        let valueChanged = selected != selection || self.map?.marks.count != map.marks.count
        let redraw = self.map != map || valueChanged || isEnabled != enabled
        if isEnabled != enabled {
            isEnabled = enabled
            window?.invalidateCursorRects(for: self)
        }
        self.map = map
        self.choose = choose
        selected = selection
        if redraw { needsDisplay = true }
        if valueChanged { NSAccessibility.post(element: self, notification: .valueChanged) }
    }

    private var trackWidth: CGFloat { max(0, bounds.width - 4) }

    override func draw(_ dirtyRect: NSRect) {
        guard let map, trackWidth > 4 else { return }
        let thickness = max(2, (bounds.height - 7) / 2)
        let sides: [(EditorComparisonPlan.Side, CGFloat, NSColor)] = [
            (.before, 2, EditorComparisonBackground.Accent.removed.color),
            (.current, bounds.height - thickness - 2, EditorComparisonBackground.Accent.inserted.color)
        ]
        for (side, y, color) in sides {
            let track = NSRect(x: 2, y: y, width: trackWidth, height: thickness)
            NSColor.separatorColor.setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            for (index, mark) in map.marks.enumerated() {
                let span = mark.span(on: side)
                let width = min(trackWidth, max(4, CGFloat(span.upperBound - span.lowerBound) * trackWidth))
                let midpoint = CGFloat(span.lowerBound + span.upperBound) * trackWidth / 2
                let x = track.minX + min(trackWidth - width, max(0, midpoint - width / 2))
                let rect = NSRect(x: x, y: y, width: width, height: thickness)
                color.withAlphaComponent(isEnabled ? (index == selected ? 1 : 0.7) : 0.35).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
                if index == selected {
                    NSColor.labelColor.setStroke()
                    NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2).stroke()
                }
            }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isEnabled, trackWidth > 4, bounds.contains(point), let map else { return }
        let fraction = min(1, max(0, (point.x - 2) / trackWidth))
        if let index = map.nearest(fraction, on: point.y < bounds.midY ? .before : .current) { _ = activate(index) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126: _ = changeSelection(by: -1)
        case 124, 125: _ = changeSelection(by: 1)
        default: super.keyDown(with: event)
        }
    }

    private func changeSelection(by offset: Int) -> Bool {
        guard isEnabled, let map, map.marks.indices.contains(selected + offset) else { return false }
        return activate(selected + offset)
    }

    private func activate(_ index: Int) -> Bool {
        guard choose?(index) == true else { return false }
        if selected != index {
            selected = index
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
        return true
    }

    override func accessibilityValue() -> Any? { map.map { "Change \(selected + 1) of \($0.marks.count)" } }
    override func accessibilityPerformDecrement() -> Bool { changeSelection(by: -1) }
    override func accessibilityPerformIncrement() -> Bool { changeSelection(by: 1) }
}
