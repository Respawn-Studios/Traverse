import CoreFoundation
import Foundation

/// A presentation/storage selector for the separate local-user Developer ID
/// composition. Signed parent and helper checks remain independent.
public enum DirectPublicEditionIdentity {
    public static let bundleIdentifier = "com.respawnstudios.traverse"
    public static let storageNamespace = "com.respawnstudios.traverse.direct"
    public static let updaterVersion = "2.10.0"
    public static let feedURL = "https://respawn-studios.com/products/traverse/direct-updates/appcast.xml"
    public static let updatePublicKey = "MG4sBFr76ad6D4nGo+i2VuZ4hxVMEQZToBUjYyui3IA="

    /// Product presentation can distinguish a shipping app from the otherwise
    /// matching local qualification edition. This grants no file permissions.
    public static func isShipping(identifier: String?, info: [String: Any]) -> Bool {
        matches(identifier: identifier, info: info)
            && info["MacExplorerReleasePurpose"] as? String == "direct-shipping-v1"
    }

    public static func matches(identifier: String?, info: [String: Any]) -> Bool {
        guard identifier == bundleIdentifier,
              info["MacExplorerDistributionChannel"] as? String == "developer-id",
              info["MacExplorerAccessPolicy"] as? String == "local-user-v1",
              info["MacExplorerStorageMode"] as? String == "portable",
              info["TraverseDirectStorageNamespace"] as? String == storageNamespace,
              info["TraverseDirectPublicUpdaterVersion"] as? String == updaterVersion,
              info["MacExplorerFolderServices"] as? String == "public-folders-service-v1",
              info["SUFeedURL"] as? String == feedURL,
              info["SUPublicEDKey"] as? String == updatePublicKey,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SURequireSignedFeed"] as? Bool == true,
              info["SUSignedFeedFailureExpirationInterval"] as? Int == 0,
              info["SUScheduledCheckInterval"] as? Int == 21_600,
              info["SUEnableAutomaticChecks"] as? Bool == false,
              info["SUAutomaticallyUpdate"] as? Bool == false,
              info["SUAllowsAutomaticUpdates"] as? Bool == false,
              info["SUEnableSystemProfiling"] as? Bool == false,
              info["SUEnableJavaScript"] as? Bool == false,
              serviceVersionAdmitted(info["TraverseDriveHealthServiceVersion"]) else {
            return false
        }
        return ["TraversePrivateUpdaterVersion", "TraversePublicUpdaterVersion",
                "TraverseDriveHealthHelperVersion",
                "MacExplorerReviewCase", "MacExplorerSandboxQualificationCase",
                "MacExplorerDevelopmentStateRoot", "MacExplorerDevelopmentCacheRoot",
                "SUEnableInstallerLauncherService", "SUEnableDownloaderService"].allSatisfy {
            info[$0] == nil
        }
    }

    private static func serviceVersionAdmitted(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let version = value as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID() else { return false }
        let type = String(cString: version.objCType)
        return type.count == 1 && "csiIlLqQCS".contains(type)
            && version.intValue == 1 && version.doubleValue == 1
    }
}
