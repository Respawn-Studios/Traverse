import AppKit

/// Dynamic system colors resolve in the editor's effective appearance. These
/// attributes are temporary presentation; never document content or typing Undo.
@MainActor
enum EditorSyntaxColors {
    static func color(for kind: TextSyntaxToken.Kind, palette: EditorSyntaxPalette) -> NSColor {
        if palette == .monochrome { return kind == .comment ? .secondaryLabelColor : .labelColor }
        switch kind {
        case .keyword: return .systemPink
        case .property: return palette == .vivid ? .systemCyan : .systemBlue
        case .string: return palette == .vivid ? .systemGreen : .systemRed
        case .number: return .systemOrange
        case .literal: return .systemPurple
        case .punctuation: return palette == .vivid ? .labelColor : .secondaryLabelColor
        case .type: return .systemTeal
        case .function: return .systemIndigo
        case .comment: return .secondaryLabelColor
        }
    }
}
