import LocalStorage
import Foundation

enum TraverseAccessPolicy {
    /// Presentation policy only. No environment override, disk probe or TCC
    /// status inference. Distribution helpers separately verify actual signed
    /// rights before accepting work. Unknown editions retain the scoped flow.
    static let current: FileAccessPolicy? = {
        #if TRAVERSE_DRIVE_IMAGE_QA
        return GeneratedDriveImageReview.admitted ? .localUser : nil
        #else
        #if TRAVERSE_ARCHIVE_DRIVE_QA
        // This generated Release role has an exact case, root and launch
        // phase. It uses the local user's normal file access for cold Undo,
        // while its archive engine confines inputs to the generated fixture.
        return GeneratedArchiveDriveReview.admitted ? .localUser : nil
        #else
        #if MAC_EXPLORER_DISTRIBUTION
        let info = Bundle.main.infoDictionary ?? [:]
        return try? .distribution(channel: info["MacExplorerDistributionChannel"] as? String ?? "",
            identifier: Bundle.main.bundleIdentifier ?? "", value: info["MacExplorerAccessPolicy"] as? String)
        #else
        return .localUser
        #endif
        #endif
        #endif
    }()
    static var requiresFolderSelection: Bool { current?.requiresFolderSelection ?? true }
}
