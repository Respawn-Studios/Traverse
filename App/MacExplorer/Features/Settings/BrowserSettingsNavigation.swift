import AppKit
import SwiftUI

extension BrowserSettingsView.Page {
    static let ordered: [Self] = [.general, .appearance, .tools, .keyboard, .operations, .privacy, .permissions]
    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .tools: "Tools"
        case .keyboard: "Keyboard"
        case .operations: "Operations"
        case .privacy: "Privacy"
        case .permissions: "Permissions"
        }
    }
    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .tools: "chevron.left.forwardslash.chevron.right"
        case .keyboard: "keyboard"
        case .operations: "arrow.triangle.2.circlepath"
        case .privacy: "hand.raised"
        case .permissions: "lock.shield"
        }
    }
}

struct BrowserSettingsNavigation: View {
    @Binding var selection: BrowserSettingsView.Page
    let scale: CGFloat
    var body: some View {
        NativeToolPageNavigation(selection: $selection, scale: scale,
            items: BrowserSettingsView.Page.ordered.map { .init(id: $0, title: $0.title, symbolName: $0.symbolName) },
            identifier: "settings-navigation", accessibilityLabel: "Settings sections")
    }
}

