import AppKit

/// Finite role/capability combinations only. Neither names nor paths become
/// image-cache keys. Selection colors remain owned by the surrounding list.
@MainActor
enum FileOpeningSymbol {
    private struct Key: Hashable { let role: FileIconRole; let cue: FileNativeOpeningCue }
    private static var badges: [Key: NSImage] = [:]
    static func image(role: FileIconRole, appearance: FileOpeningAppearance) -> NSImage? {
        guard appearance.badge != .none else { return BrowserCellSymbols.image(role) }
        let key = Key(role: role, cue: appearance.badge)
        if let image = badges[key] { return image }
        let symbol: String
        switch appearance.badge {
        case .editor: symbol = "pencil.circle.fill"
        case .viewer: symbol = "eye.circle.fill"
        case .none, .archive: symbol = "folder.circle.fill"
        }
        guard let base = BrowserCellSymbols.image(role),
              let mark = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            return BrowserCellSymbols.image(role)
        }
        let result = NSImage(size: .init(width: 24, height: 24), flipped: false) { _ in
            base.draw(in: .init(x: 0, y: 3, width: 21, height: 21))
            mark.draw(in: .init(x: 13, y: 0, width: 11, height: 11))
            return true
        }
        result.isTemplate = true
        badges[key] = result
        return result
    }
    static func tint(_ appearance: FileOpeningAppearance, directory: Bool) -> NSColor {
        if directory { return .systemYellow }
        return appearance.isEmphasized ? .labelColor : .secondaryLabelColor
    }
}
