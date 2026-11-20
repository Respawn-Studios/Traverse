import SwiftUI

private struct AdaptiveToolColumnMeasurement: Equatable, Sendable {
    let stacked: Bool
    let scale: CGFloat
}

/// Move the same two child trees between columns and rows. Native controls,
/// focus and chart state survive reflow, using the shared motion preference.
struct AdaptiveToolColumns<Leading: View, Trailing: View>: View {
    enum Sizing { case content, viewport }

    @ObservedObject var settings: BrowserSettings
    let minimumWidth: CGFloat
    let sizing: Sizing
    var onArrangementChanged: ((Bool) -> Void)?
    let leading: Leading
    let trailing: Trailing
    @Environment(\.interfaceScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stacked = true
    @State private var measuredScale: CGFloat?

    init(settings: BrowserSettings, minimumWidth: CGFloat, sizing: Sizing = .content,
         onArrangementChanged: ((Bool) -> Void)? = nil,
         @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.settings = settings; self.minimumWidth = minimumWidth
        self.sizing = sizing
        self.onArrangementChanged = onArrangementChanged
        self.leading = leading(); self.trailing = trailing()
    }

    private let spacing: CGFloat = 16
    private var breakpoint: CGFloat { minimumWidth * scale + spacing }

    var body: some View {
        switch sizing {
        case .content: intrinsicColumns
        case .viewport: viewportColumns
        }
    }

    private func arrangement(stacked: Bool) -> AnyLayout {
        stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
    }

    private var viewportColumns: some View {
        GeometryReader { geometry in
            // Compute both slots in this layout pass. Native scroll views must
            // receive the same dimensions that their arrangement reserves.
            let size = geometry.size
            let stacks = size.width < breakpoint
            let width = stacks ? size.width : max(0, (size.width - spacing) / 2)
            let height = stacks ? max(0, (size.height - spacing) / 2) : size.height
            let layout = arrangement(stacked: stacks)
            layout {
                leading.frame(width: width, height: height).clipped()
                trailing.frame(width: width, height: height).clipped()
            }
            .onChange(of: stacks, initial: true) { _, value in onArrangementChanged?(value) }
        }
    }

    private var intrinsicColumns: some View {
        let layout = arrangement(stacked: stacked)
        return layout {
            leading.frame(maxWidth: .infinity, alignment: .leading)
            trailing.frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(reduceMotion || !settings.motion.allows(.pages) ? nil
            : .easeInOut(duration: settings.motion.mode.toolReflowDuration), value: stacked)
        .onGeometryChange(for: AdaptiveToolColumnMeasurement.self) { [breakpoint, scale] in
            AdaptiveToolColumnMeasurement(stacked: $0.size.width < breakpoint, scale: scale)
        } action: { next in
            let arrangementChanged = measuredScale == nil || stacked != next.stacked
            if measuredScale == next.scale {
                stacked = next.stacked
                if arrangementChanged { onArrangementChanged?(next.stacked) }
            } else {
                // Interface sizing already owns one window-wide transition.
                // A second reflow would move labels through their neighbours.
                // Initial measurement likewise has no outgoing arrangement.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    stacked = next.stacked; measuredScale = next.scale
                    if arrangementChanged { onArrangementChanged?(next.stacked) }
                }
            }
        }
        .onAppear { onArrangementChanged?(stacked) }
    }
}
