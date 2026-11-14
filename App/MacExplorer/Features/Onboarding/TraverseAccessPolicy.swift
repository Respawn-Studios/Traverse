import LocalStorage
import Foundation

enum TraverseAccessPolicy {
    /// Presentation policy only. No environment override, disk probe or TCC
    /// status inference. Distribution helpers separately verify actual signed
    /// rights before accepting work. Unknown editions retain the scoped flow.
    static let current: FileAccessPolicy? = {
        #if MAC_EXPLORER_DISTRIBUTION
        let info = Bundle.main.infoDictionary ?? [:]
        return try? .distribution(channel: info["MacExplorerDistributionChannel"] as? String ?? "",
            identifier: Bundle.main.bundleIdentifier ?? "", value: info["MacExplorerAccessPolicy"] as? String)
        #else
        return .localUser
        #endif
    }()
    static var requiresFolderSelection: Bool { current?.requiresFolderSelection ?? true }
}
