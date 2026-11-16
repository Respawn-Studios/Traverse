import ExplorerCore
import Foundation

/// One inert, immutable composition value. No directory is created/resolved on
/// disk here, and no development data is migrated into a portable namespace.
enum AppStorageLocations {
    static let layout: ApplicationStorageLayout? = {
        let info = Bundle.main.infoDictionary ?? [:]
        let reviewRequested = Bundle.main.bundleIdentifier == DevelopmentReviewProfile.identifier
            || info["MacExplorerDistributionChannel"] as? String == DevelopmentReviewProfile.channel
            || info["MacExplorerReviewCase"] != nil
        if reviewRequested {
            #if MAC_EXPLORER_DISTRIBUTION
            return nil
            #else
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            let storage: DevelopmentReviewProfile.Storage
            if info["MacExplorerReviewStorage"] == nil { storage = .repository }
            else if let raw = info["MacExplorerReviewStorage"] as? String,
                    let selected = DevelopmentReviewProfile.Storage(rawValue: raw) { storage = selected }
            else { return nil }
            return try? DevelopmentReviewProfile(identifier: Bundle.main.bundleIdentifier,
                channel: info["MacExplorerDistributionChannel"] as? String,
                caseID: info["MacExplorerReviewCase"] as? String, checkout: repo, storage: storage,
                applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                caches: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first).layout
            #endif
        }
        #if MAC_EXPLORER_DISTRIBUTION && TRAVERSE_LOCAL_USER_DIRECT
        guard DirectPublicEditionIdentity.matches(identifier: Bundle.main.bundleIdentifier, info: info) else {
            return nil
        }
        return try? ApplicationStorageLayout.directUserDomain(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        #else
        var mode = info["MacExplorerStorageMode"] as? String ?? ""
        #if MAC_EXPLORER_DISTRIBUTION
            let forcePortable = true
        #else
            let forcePortable = false
        #endif
        var support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        var caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        #if TRAVERSE_ARCHIVE_DRIVE_QA
        // The exact signed review uses a portable namespace inside its
        // generated case; it never reads or creates an OS user profile.
        guard let selection = GeneratedArchiveDriveReview.selection else { return nil }
        let library = selection.caseRoot.appendingPathComponent("source/Library", isDirectory: true)
        support = library.appendingPathComponent("Application Support", isDirectory: true)
        caches = library.appendingPathComponent("Caches", isDirectory: true)
        mode = "portable"
        #endif
        #if TRAVERSE_DRIVE_IMAGE_QA
        guard let selection = GeneratedDriveImageReview.selection else { return nil }
        let library = selection.caseRoot.appendingPathComponent("source/Library", isDirectory: true)
        support = library.appendingPathComponent("Application Support", isDirectory: true)
        caches = library.appendingPathComponent("Caches", isDirectory: true)
        mode = "portable"
        #endif
        #if DEBUG
            // A dedicated generated adapter may replace only these bases. Ordinary
            // launches and distribution builds ignore environment storage overrides.
            if ProcessInfo.processInfo.arguments.contains("--check-portable-storage"),
                let text = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"]
            {
                let root = URL(fileURLWithPath: text)
                let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()
                if root.deletingLastPathComponent() == repo.appendingPathComponent(".build/overnight-foundation"),
                    UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
                {
                    support = root.appendingPathComponent("source/Library/Application Support", isDirectory: true)
                    caches = root.appendingPathComponent("source/Library/Caches", isDirectory: true)
                    mode = "portable"
                } else {
                    return nil
                }
            }
        #endif
        let developmentCachePath: String?
        #if MAC_EXPLORER_DISTRIBUTION
        developmentCachePath = nil
        #else
        if mode != "portable", let supplied = info["MacExplorerDevelopmentCacheRoot"] {
            guard let value = supplied as? String else { return nil }
            developmentCachePath = value
        } else {
            developmentCachePath = nil
        }
        #endif
        return try? ApplicationStorageConfiguration.resolve(
            mode: mode,
            forcePortable: forcePortable, bundleIdentifier: Bundle.main.bundleIdentifier,
            developmentPath: info["MacExplorerDevelopmentStateRoot"] as? String,
            applicationSupport: support, caches: caches,
            developmentCachePath: developmentCachePath)
        #endif
    }()
    static var stateDirectory: URL? { layout?.stateDirectory }
    static var folderDefaultRestoreDirectory: URL? {
        stateDirectory?.appendingPathComponent("folder-opening", isDirectory: true)
    }
    static var isPortable: Bool { layout?.channel == .portable }
    static var protectedDirectories: [URL] {
        guard let layout else { return [] }
        return [layout.stateDirectory, layout.cacheDirectory]
    }
}
