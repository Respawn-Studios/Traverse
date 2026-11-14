import AppKit
import SwiftUI

/// One stateful sample moves between columns and rows. Text is never reduced
/// merely to keep a side-by-side preview, and slider focus survives reflow.
struct InterfaceSizePicker: View {
    @ObservedObject var settings: BrowserSettings
    var onArrangementChanged: ((Bool) -> Void)? = nil
    @Environment(\.interfaceScale) private var scale
    @State private var initial: InterfaceSize?
    var body: some View {
        AdaptiveToolColumns(settings: settings, minimumWidth: 520, onArrangementChanged: onArrangementChanged) {
            controls
        } trailing: {
            sample
        }
        .onAppear { if initial == nil { initial = settings.interfaceSize } }
        .accessibilityIdentifier("interface-size-picker")
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Text and controls").interfaceFont(.headline)
                Spacer(minLength: 8)
                Text("\(settings.interfaceSize.percent)%").monospacedDigit().interfaceFont(.callout)
            }
            InterfaceSizeSlider(value: Binding(get: { settings.interfaceSize.percent }, set: {
                settings.interfaceSize = InterfaceSize($0)
            })).frame(height: 24 * scale)
            HStack(spacing: 6) {
                ForEach([100, 110, 125, 150], id: \.self) { value in
                    Button("\(value)%") { settings.interfaceSize = InterfaceSize(value) }
                        .buttonStyle(.bordered)
                        .accessibilityAddTraits(settings.interfaceSize.percent == value ? .isSelected : [])
                }
            }
            HStack {
                Button("Reset") { settings.interfaceSize = .standard }
                    .disabled(settings.interfaceSize == .standard)
                if let initial {
                    Button("Revert") { settings.interfaceSize = initial }
                        .disabled(settings.interfaceSize == initial)
                }
            }
            Text("Changes apply immediately to open windows. Larger text uses more room; resize a window or scroll when needed.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var sample: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text("Preview · Downloads").interfaceFont(.callout.weight(.medium))
                Spacer(minLength: 0)
            }.padding(10)
            Divider()
            HStack {
                Text("Name"); Spacer(); Text("Size")
            }.interfaceFont(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 7)
            previewRow("Project reference notes.txt", symbol: "doc.text", size: "24 KB", selected: true)
            previewRow("Design resources", symbol: "folder", size: "—", selected: false)
            Divider()
            HStack { Text("2 items"); Spacer(); Image(systemName: "tablecells") }
                .interfaceFont(.caption).foregroundStyle(.secondary).padding(10)
        }
        .background(Color.primary.opacity(settings.navigationStyle == .glass ? 0.035 : 0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.7))
        .accessibilityElement(children: .contain).accessibilityLabel("Interface size preview; generated items")
    }
    private func previewRow(_ name: String, symbol: String, size: String, selected: Bool) -> some View {
        HStack(spacing: 8 * scale) {
            Image(systemName: symbol).frame(width: 18 * scale)
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(size).foregroundStyle(.secondary).monospacedDigit()
        }
        .interfaceFont(.body).padding(.horizontal, 10).frame(minHeight: 29 * scale)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear)
        .help(name)
    }
}

/// Keep a native keyboard/accessibility control alive while the preview moves.
private struct InterfaceSizeSlider: NSViewRepresentable {
    @Binding var value: Int
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: Double(value), minValue: 100, maxValue: 150,
            target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.numberOfTickMarks = 11; slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below; slider.isContinuous = true
        slider.setAccessibilityLabel("Interface size")
        slider.setAccessibilityIdentifier("interface-size-slider")
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        if slider.integerValue != value { slider.integerValue = value }
        slider.setAccessibilityValueDescription("\(value) percent")
    }
    @MainActor final class Coordinator: NSObject {
        var parent: InterfaceSizeSlider
        init(_ parent: InterfaceSizeSlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.value = sender.integerValue }
    }
}
