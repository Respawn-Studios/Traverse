import AppKit
import ExplorerCore

/// The service payload is navigation intent, not an access grant or proof of
/// Finder selection. The existing incoming owner probes folders off-main and
/// retains only access actually supplied by macOS.
@MainActor final class IncomingFolderService: NSObject {
    private let open: ([URL]) -> Void

    init(open: @escaping ([URL]) -> Void) { self.open = open; super.init() }

    static var available: Bool {
        let bundle = Bundle.main
        let product: String, marker: String
        switch AppFeatureAvailability.policy.edition {
        case .preview:
            product = "Traverse Preview"; marker = "MacExplorerPreviewFolderServices"
        case let edition where edition.isDeveloperID && bundle.bundleIdentifier == "com.respawnstudios.traverse":
            product = "Traverse"; marker = "MacExplorerFolderServices"
        default: return false
        }
        guard bundle.object(forInfoDictionaryKey: marker) as? String == "public-folders-service-v1",
              let services = bundle.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]], services.count == 1,
              let service = services.first else { return false }
        let expected: [String: Any] = [
            "NSMenuItem": ["default": "Open in " + product],
            "NSMessage": "openFoldersInTraverse", "NSPortName": product,
            "NSSendFileTypes": ["public.folder"], "NSRequiredContext": [String: String](),
            "NSRestricted": true, "NSServiceDescription": "Browse selected folders in " + product + ".",
        ]
        return NSDictionary(dictionary: service) == NSDictionary(dictionary: expected)
    }

    @objc func openFoldersInTraverse(_ pasteboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let trace = UUID()
        ApplicationDiagnostics.shared.event(.open, .requested, trace: trace,
            context: .init(.incomingFolderService))
        error?.pointee = nil
        // Read only the explicitly supplied service pasteboard. Mixed/text-only
        // input cannot be interpreted as a path or silently reduced to a subset.
        guard let items = pasteboard.pasteboardItems, !items.isEmpty,
              items.count <= IncomingFolderURLs.maximumBatch,
              items.allSatisfy({ $0.types.contains(.fileURL) }),
              let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL], urls.count == items.count,
              let admitted = try? IncomingFolderURLs.admit(urls) else {
            ApplicationDiagnostics.shared.event(.open, .blocked, trace: trace,
                context: .init(.incomingFolderService))
            error?.pointee = "Choose up to 16 local folders to open in Traverse. Text paths and mixed selections are not supported." as NSString
            return
        }
        ApplicationDiagnostics.shared.event(.open, .admitted, trace: trace, count: UInt64(admitted.count),
            context: .init(.incomingFolderService))
        open(admitted)
    }
}
