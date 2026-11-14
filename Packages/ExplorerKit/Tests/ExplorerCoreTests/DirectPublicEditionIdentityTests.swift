import Foundation
import Testing
@testable import ExplorerCore

struct DirectPublicEditionIdentityTests {
    @Test func exactLocalUserPublicIdentityAdmitsOnlyIndependentHealthService() {
        let info: [String: Any] = [
            "MacExplorerDistributionChannel": "developer-id",
            "MacExplorerAccessPolicy": "local-user-v1",
            "MacExplorerStorageMode": "portable",
            "TraverseDirectStorageNamespace": DirectPublicEditionIdentity.storageNamespace,
            "TraverseDirectPublicUpdaterVersion": DirectPublicEditionIdentity.updaterVersion,
            "MacExplorerFolderServices": "public-folders-service-v1",
            "SUFeedURL": DirectPublicEditionIdentity.feedURL,
            "SUPublicEDKey": DirectPublicEditionIdentity.updatePublicKey,
            "SUVerifyUpdateBeforeExtraction": true,
            "SURequireSignedFeed": true,
            "SUSignedFeedFailureExpirationInterval": 0,
            "SUScheduledCheckInterval": 21_600,
            "SUEnableAutomaticChecks": false,
            "SUAutomaticallyUpdate": false,
            "SUAllowsAutomaticUpdates": false,
            "SUEnableSystemProfiling": false,
            "SUEnableJavaScript": false,
        ]
        #expect(DirectPublicEditionIdentity.matches(identifier: DirectPublicEditionIdentity.bundleIdentifier, info: info))
        #expect(!DirectPublicEditionIdentity.isShipping(identifier: DirectPublicEditionIdentity.bundleIdentifier, info: info))
        var shipping = info
        shipping["MacExplorerReleasePurpose"] = "direct-shipping-v1"
        #expect(DirectPublicEditionIdentity.isShipping(identifier: DirectPublicEditionIdentity.bundleIdentifier, info: shipping))
        #expect(!DirectPublicEditionIdentity.isShipping(identifier: "local.macexplorer.preview", info: shipping))
        for purpose in ["", "qualification", "direct-shipping-v2"] {
            var changed = shipping
            changed["MacExplorerReleasePurpose"] = purpose
            #expect(!DirectPublicEditionIdentity.isShipping(identifier: DirectPublicEditionIdentity.bundleIdentifier, info: changed))
        }
        var withService = info
        withService["TraverseDriveHealthServiceVersion"] = 1
        #expect(DirectPublicEditionIdentity.matches(identifier: DirectPublicEditionIdentity.bundleIdentifier,
                                                    info: withService))
        #expect(!DirectPublicEditionIdentity.matches(identifier: "local.macexplorer.preview", info: info))
        let changes: [(String, Any)] = [
            ("MacExplorerAccessPolicy", "sandbox-selected-v1"),
            ("MacExplorerDistributionChannel", "app-store"),
            ("MacExplorerStorageMode", "development"),
            ("TraverseDirectStorageNamespace", "com.respawnstudios.traverse"),
            ("TraverseDirectPublicUpdaterVersion", "wrong"),
            ("TraversePrivateUpdaterVersion", ""),
            ("TraversePublicUpdaterVersion", "2.10.0"),
            ("SUFeedURL", "https://respawn-studios.com/products/traverse/public-updates/appcast.xml"),
            ("SUPublicEDKey", "wrong"),
            ("SURequireSignedFeed", false),
            ("SUEnableAutomaticChecks", true),
            ("SUAutomaticallyUpdate", true),
            ("TraverseDriveHealthServiceVersion", 2),
            ("TraverseDriveHealthServiceVersion", true),
            ("TraverseDriveHealthServiceVersion", NSNumber(value: 1.0)),
            ("TraverseDriveHealthServiceVersion", "1"),
            ("TraverseDriveHealthHelperVersion", 2),
            ("MacExplorerReviewCase", "generated"),
            ("SUEnableInstallerLauncherService", false),
        ]
        for (key, value) in changes {
            var changed = info
            changed[key] = value
            #expect(!DirectPublicEditionIdentity.matches(identifier: DirectPublicEditionIdentity.bundleIdentifier,
                                                         info: changed), "\(key) must refuse")
            changed["MacExplorerReleasePurpose"] = "direct-shipping-v1"
            #expect(!DirectPublicEditionIdentity.isShipping(identifier: DirectPublicEditionIdentity.bundleIdentifier,
                                                            info: changed), "\(key) cannot select shipping presentation")
        }
    }
}
