import SwiftUI

/// Move the same two child trees between columns and rows. Native controls,
/// focus and chart state survive reflow, using the shared motion preference.
struct AdaptiveToolColumns<Leading: View, Trailing: View>: View {
    @ObservedObject var settings: BrowserSettings
    let minimumWidth: CGFloat
    var onArrangementChanged: ((Bool) -> Void)?
    let leading: Leading
    let trailing: Trailing
    @Environment(\.interfaceScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stacked = true
    @State private var hasMeasured = false

    init(settings: BrowserSettings, minimumWidth: CGFloat, onArrangementChanged: ((Bool) -> Void)? = nil,
         @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.settings = settings; self.minimumWidth = minimumWidth
        self.onArrangementChanged = onArrangementChanged
        self.leading = leading(); self.trailing = trailing()
    }
    var body: some View {
        let breakpoint = minimumWidth * scale + 16
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            leading.frame(maxWidth: .infinity, alignment: .leading)
            trailing.frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(reduceMotion || !settings.motion.allows(.pages) ? nil
            : .easeInOut(duration: settings.motion.mode == .reduced ? 0.14 : 0.30), value: stacked)
        .onGeometryChange(for: Bool.self) { [breakpoint] in $0.size.width < breakpoint } action: { next in
            if hasMeasured {
                stacked = next
            } else {
                // The initial guess was never a user-selected arrangement.
                // Start at the measured width; animate only later reflows.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { stacked = next; hasMeasured = true }
            }
            onArrangementChanged?(next)
        }
        .onAppear { onArrangementChanged?(stacked) }
    }
}
