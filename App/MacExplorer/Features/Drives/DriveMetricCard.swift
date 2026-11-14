import SwiftUI

struct DriveMetricCard: View {
    let title: String
    let value: String
    let symbol: String
    let progress: Double?
    @ObservedObject var settings: BrowserSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).interfaceFont(.caption).foregroundStyle(.secondary)
            Text(value).interfaceFont(.title2.weight(.semibold)).monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion || !settings.motion.allows(.pages) ? nil : .easeOut(duration: 0.16), value: value)
            // Reserve the track before the first reading, so delayed hardware
            // values cannot move the task canvas or change the card height.
            ProgressView(value: progress ?? 0).tint(.accentColor).frame(height: 6)
                .opacity(progress == nil ? 0 : 1).accessibilityHidden(progress == nil)
                .accessibilityLabel(title)
                .animation(reduceMotion || !settings.motion.allows(.pages) ? nil
                    : .easeInOut(duration: 0.18 * settings.motion.mode.durationScale), value: progress)
        }.frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}
