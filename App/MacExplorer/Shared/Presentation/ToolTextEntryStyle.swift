import SwiftUI

/// Keep the editor native and its surrounding surface in SwiftUI. The rounded
/// native bezel renders a dark intermediate surface when an ancestor fades;
/// generated 120fps Help recordings exercise that exact compositing case.
struct ToolTextEntryStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).modifier(ToolTextEntrySurface())
    }
}

/// The same surround works for SwiftUI and explicitly owned native fields.
struct ToolTextEntrySurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.primary.opacity(contrast == .increased ? 0.10 : 0.06),
                in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.primary.opacity(contrast == .increased ? 0.45 : 0.12))
                .allowsHitTesting(false))
    }
}
