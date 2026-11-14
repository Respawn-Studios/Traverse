import Foundation

/// A finite set of file-browser choices. Native text editing is always prior to
/// this policy; these choices never install global shortcuts or change physical modifiers.
public enum BrowserKeyboardPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case explorer = "Explorer", mac = "Mac", custom = "Custom"
    public var id: Self { self }
}

public enum BrowserReturnAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case open = "Open selection", rename = "Rename selected item"
    public var id: Self { self }
}

public struct BrowserBehaviorPreferences: Codable, Equatable, Sendable {
    public var returnAction: BrowserReturnAction
    public var backspaceGoesBack: Bool
    public var controlAliasesEnabled: Bool
    public var explorerFunctionKeysEnabled: Bool

    public init(returnAction: BrowserReturnAction = .open, backspaceGoesBack: Bool = true,
                controlAliasesEnabled: Bool = true, explorerFunctionKeysEnabled: Bool = true) {
        self.returnAction = returnAction
        self.backspaceGoesBack = backspaceGoesBack
        self.controlAliasesEnabled = controlAliasesEnabled
        self.explorerFunctionKeysEnabled = explorerFunctionKeysEnabled
    }

    /// Explorer's existing Control-alias choice includes primary-pointer
    /// selection. Native Command toggling and secondary-click menus stay native.
    /// Custom uses the same finite alias choice; no new persisted field/schema.
    public var controlClickTogglesSelection: Bool { controlAliasesEnabled }

    public static let explorer = Self()
    public static let mac = Self(returnAction: .rename, backspaceGoesBack: false,
                                 controlAliasesEnabled: false, explorerFunctionKeysEnabled: false)

    public static func effective(preset: BrowserKeyboardPreset, custom: Self) -> Self {
        switch preset {
        case .explorer: .explorer
        case .mac: .mac
        case .custom: custom
        }
    }

    public enum FileKey: Sendable { case returnKey, backspace, function2, forwardDelete, space }
    public enum FileAction: Sendable { case open, rename, back, trash, quickLook }
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Self(rawValue: 1)
        public static let control = Self(rawValue: 2)
        public static let option = Self(rawValue: 4)
        public static let shift = Self(rawValue: 8)
    }

    /// Call only for the file surface. In an editor/IME the native responder
    /// keeps every key, including Return, Space, Backspace and Command-Delete.
    public func action(for key: FileKey, modifiers: Modifiers = [], isEditingText: Bool = false) -> FileAction? {
        guard !isEditingText else { return nil }
        if key == .backspace, modifiers == .command { return .trash }
        guard modifiers.isEmpty else { return nil }
        switch key {
        case .returnKey: return returnAction == .open ? .open : .rename
        case .backspace: return backspaceGoesBack ? .back : nil
        case .function2: return explorerFunctionKeysEnabled ? .rename : nil
        case .forwardDelete: return explorerFunctionKeysEnabled ? .trash : nil
        case .space: return .quickLook
        }
    }
}
