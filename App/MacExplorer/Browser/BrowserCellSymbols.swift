import AppKit

/// A finite set of application-owned template images; callers must not mutate
/// cached images. User names and extensions never become cache keys.
@MainActor enum BrowserCellSymbols {
    typealias Role = FileIconRole

    private static let images: [Role: NSImage] = {
        var result: [Role: NSImage] = [:]
        for role in Role.allCases {
            if let image = make(role) { result[role] = image }
        }
        return result
    }()

    static func image(_ role: Role) -> NSImage? {
        image(role, from: images)
    }

    static func image(_ role: Role, from available: [Role: NSImage]) -> NSImage? {
        available[role] ?? available[.file]
    }

    private static func make(_ role: Role) -> NSImage? {
        let name: String
        switch role {
        case .directory: name = "folder.fill"
        case .package: name = "shippingbox"
        case .symbolicLink: name = "link"
        case .file, .other: name = "doc"
        case .cut: name = "scissors"
        case .code: name = "chevron.left.forwardslash.chevron.right"
        case .configuration: name = "slider.horizontal.3"
        case .database: name = "externaldrive"
        case .document: name = "doc.text"
        case .image: name = "photo"
        case .audio: name = "music.note"
        case .video: name = "film"
        case .archive: name = "archivebox"
        case .application: name = "app"
        case .diskImage: name = "opticaldiscdrive"
        case .font: name = "textformat"
        case .pdf: name = "doc.richtext"
        case .spreadsheet: name = "tablecells"
        case .presentation: name = "rectangle.on.rectangle"
        case .model3D: name = "cube"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: role.title)
    }
}
