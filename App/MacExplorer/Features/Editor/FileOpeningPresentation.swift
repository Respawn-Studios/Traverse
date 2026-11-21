import Foundation
import ExplorerCore

enum FileNativeOpeningCue: String, Hashable, Sendable, CaseIterable {
    case none, editor, viewer, archive, onlineOnly
    var title: String? {
        switch self {
        case .none: nil
        case .editor: "Opens in Traverse Editor"
        case .viewer: "Opens read-only in Traverse"
        case .archive: "Browses in Traverse"
        case .onlineOnly: "Online only. Make this item available on your Mac to preview it."
        }
    }
}

/// Presentation inferred from existing filename/kind and the actual ordinary
/// Open policy. It never opens the item or promises its contents will qualify.
struct FileOpeningAppearance: Equatable, Sendable {
    let mode: EditorOpeningIndicator
    let cue: FileNativeOpeningCue
    static let ordinary = Self(mode: .off, cue: .none)
    static let onlineOnly = Self(mode: .badge, cue: .onlineOnly)
    var isEmphasized: Bool { mode != .off && cue != .none }
    var badge: FileNativeOpeningCue { mode == .badge ? cue : .none }
    var explanation: String? { mode == .off ? nil : cue.title }

    /// Shared filename/size cue for the two concrete remote text readers.
    /// These presentation facts never seal a selection or start a body read.
    static func remoteText(name: String, regular: Bool, bytes: UInt64?, maximumBytes: UInt64,
        preferences: EditorPreferences, allowsEditing: Bool, allowsViewing: Bool) -> Self {
        let appearance = resolve(name: name, kind: regular ? "file" : "other", preferences: preferences,
            editorAvailable: allowsEditing || allowsViewing,
            localEditorEligible: bytes.map { $0 <= maximumBytes } == true,
            opensArchives: false, zipAvailable: false, tarAvailable: false)
        if appearance.cue == .editor, !allowsEditing, allowsViewing {
            return .init(mode: appearance.mode, cue: .viewer)
        }
        return appearance
    }

    static func resolve(name: String, kind: String, preferences: EditorPreferences,
                        editorAvailable: Bool, localEditorEligible: Bool,
                        opensArchives: Bool, zipAvailable: Bool, tarAvailable: Bool) -> Self {
        guard kind == "file" else { return .init(mode: preferences.openingIndicator, cue: .none) }
        let target = preferences.route(forFilename: name, command: .ordinaryOpen, editorAvailable: editorAvailable)
        let cue: FileNativeOpeningCue
        switch target {
        case .traverse: cue = editorAvailable && localEditorEligible ? .editor : .none
        case .externalApplication: cue = .none
        case .systemDefault:
            let explicitSystem = preferences.explicitTarget(forFilename: name) == .systemDefault
            cue = !explicitSystem && opensArchives && archiveKind(name: name, zipAvailable: zipAvailable, tarAvailable: tarAvailable) != nil ? .archive : .none
        }
        return .init(mode: preferences.openingIndicator, cue: cue)
    }

    enum ArchiveKind: Sendable, Equatable { case zip, tar }
    static func archiveKind(name: String, zipAvailable: Bool, tarAvailable: Bool) -> ArchiveKind? {
        switch ArchiveFilename(name)?.kind {
        case .tar, .tarGzip, .tarBzip2: return tarAvailable ? .tar : nil
        case .zip: return zipAvailable ? .zip : nil
        default: return nil
        }
    }
}
