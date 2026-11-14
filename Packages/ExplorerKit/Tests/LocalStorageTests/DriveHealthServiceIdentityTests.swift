import Foundation
import Testing
@testable import LocalStorage

struct DriveHealthServiceIdentityTests {
    private let tag = "9309F6A1-E7A3-45C2-A864-0CBF02880D63"
    private let parent = "local.macexplorer.sandbox.remote-editor.9309f6a1e7a345c2a8640cbf02880d63"

    private var selectedInfo: [String: Any] {
        ["CFBundleIdentifier": parent,
         "MacExplorerDistributionChannel": "qualification",
         "MacExplorerSandboxQualificationCase": tag,
         "MacExplorerStorageMode": "portable",
         "MacExplorerAccessPolicy": "sandbox-selected-v1",
         "TraverseDriveHealthServiceVersion": 1]
    }

    private var directInfo: [String: Any] {
        ["CFBundleIdentifier": "com.respawnstudios.traverse",
         "MacExplorerDistributionChannel": "developer-id",
         "MacExplorerStorageMode": "portable",
         "MacExplorerAccessPolicy": "local-user-v1",
         "TraverseDirectPublicUpdaterVersion": "2.10.0",
         "TraverseDirectStorageNamespace": "com.respawnstudios.traverse.direct",
         "MacExplorerFolderServices": "public-folders-service-v1",
         "SUFeedURL": "https://respawn-studios.com/products/traverse/direct-updates/appcast.xml",
         "SUPublicEDKey": "MG4sBFr76ad6D4nGo+i2VuZ4hxVMEQZToBUjYyui3IA=",
         "SUVerifyUpdateBeforeExtraction": true,
         "SURequireSignedFeed": true,
         "SUSignedFeedFailureExpirationInterval": 0,
         "SUScheduledCheckInterval": 21_600,
         "SUEnableAutomaticChecks": false,
         "SUAutomaticallyUpdate": false,
         "SUAllowsAutomaticUpdates": false,
         "SUEnableSystemProfiling": false,
         "SUEnableJavaScript": false,
         "TraverseDriveHealthServiceVersion": 1]
    }

    @Test func onlyExactHeldQARoleSelectsIndependentService() throws {
        let selected = selectedInfo
        let profile = try DriveHealthServiceIdentity.Profile.resolve(identifier: parent, info: selected)
        #expect(profile.serviceIdentifier == parent + ".drive.health.xpc")
        #expect(profile.parentRequirement.contains("certificate leaf[subject.OU] = \"CDLNJRG82U\""))
        #expect(profile.serviceRequirement.contains("identifier \"" + profile.serviceIdentifier + "\""))
        #expect(!profile.parentRequirement.contains("cdhash"))
        #expect(throws: (any Error).self) {
            _ = try DriveHealthHelperIdentity.Profile.resolve(identifier: parent, info: [
                "MacExplorerDistributionChannel": "qualification", "MacExplorerStorageMode": "portable",
                "MacExplorerAccessPolicy": "sandbox-selected-v1", "MacExplorerSandboxQualificationCase": tag,
                "TraverseDriveHealthHelperVersion": 2, "TraverseDriveHealthServiceVersion": 1])
        }
        let changes: [[String: Any]] = [
            ["TraverseDriveHealthServiceVersion": 2],
            ["TraverseDriveHealthServiceVersion": true],
            ["TraverseDriveHealthHelperVersion": 2],
            ["MacExplorerDistributionChannel": "developer-id"],
            ["MacExplorerSandboxQualificationCase": "345C4751-4E71-437A-BE8B-6CF18527F77D"],
            ["MacExplorerAccessPolicy": "local-user-v1"],
            ["TraversePrivateUpdaterVersion": "2.10.0"],
            ["TraversePublicUpdaterVersion": "2.10.0"],
            ["MacExplorerReviewCase": tag]
        ]
        for change in changes {
            var wrong = selected
            wrong.merge(change) { _, replacement in replacement }
            #expect(throws: (any Error).self) {
                _ = try DriveHealthServiceIdentity.Profile.resolve(identifier: parent, info: wrong)
            }
        }
        #expect(throws: (any Error).self) {
            _ = try DriveHealthServiceIdentity.Profile.resolve(identifier: "com.respawnstudios.traverse", info: selected)
        }
    }

    @Test func fixedServiceBundleAndManifestRejectExtraOrChangedFields() throws {
        let profile = try DriveHealthServiceIdentity.Profile.resolve(identifier: parent, info: selectedInfo)
        let serviceInfo: [String: Any] = [
            "CFBundleIdentifier": profile.serviceIdentifier,
            "CFBundleExecutable": "drive-health-service",
            "CFBundlePackageType": "XPC!",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "15.0",
            "XPCService": ["ServiceType": "Application", "RunLoopType": "dispatch_main"]]
        #expect(profile.acceptsServiceInfo(serviceInfo))
        var changed = serviceInfo; changed["CFBundlePackageType"] = "APPL"
        #expect(!profile.acceptsServiceInfo(changed))
        changed = serviceInfo; changed["Extra"] = true
        #expect(!profile.acceptsServiceInfo(changed))
        let manifest: [String: Any] = [
            "format": "drive-health-xpc-qa-v1",
            "parentIdentifier": parent,
            "serviceIdentifier": profile.serviceIdentifier,
            "teamIdentifier": "CDLNJRG82U",
            "channel": "qualification",
            "accessPolicy": "sandbox-selected-v1",
            "reviewCase": tag,
            "parentRequirement": profile.parentRequirement,
            "sha256": String(repeating: "a", count: 64),
            "serviceCDHash": String(repeating: "b", count: 40)]
        #expect(profile.acceptsManifest(manifest))
        let changes: [[String: Any]] = [
            ["parentRequirement": "anchor apple generic"],
            ["serviceIdentifier": "another.role"],
            ["serviceCDHash": String(repeating: "G", count: 40)],
            ["sha256": String(repeating: "a", count: 63)],
            ["extra": true]]
        for change in changes {
            var wrong = manifest
            wrong.merge(change) { _, replacement in replacement }
            #expect(!profile.acceptsManifest(wrong))
        }
    }

    @Test func developerIDProductHasItsOwnClosedServiceProfile() throws {
        let product = "com.respawnstudios.traverse"
        let info: [String: Any] = [
            "CFBundleIdentifier": product,
            "MacExplorerDistributionChannel": "developer-id",
            "MacExplorerStorageMode": "portable",
            "MacExplorerAccessPolicy": "sandbox-selected-v1",
            "TraversePrivateUpdaterVersion": "2.10.0",
            "TraverseDriveHealthServiceVersion": 1]
        let profile = try DriveHealthServiceIdentity.Profile.resolve(identifier: product, info: info)
        #expect(profile.serviceIdentifier == product + ".drive.health.xpc")
        #expect(profile.reviewCase == nil && profile.channel == "developer-id" && profile.updaterSelected)
        #expect(profile.serviceRequirement.contains("certificate leaf[subject.OU] = \"CDLNJRG82U\""))
        let manifest: [String: Any] = [
            "format": "drive-health-xpc-developer-id-v1",
            "parentIdentifier": product,
            "serviceIdentifier": profile.serviceIdentifier,
            "teamIdentifier": "CDLNJRG82U",
            "channel": "developer-id",
            "accessPolicy": "sandbox-selected-v1",
            "parentRequirement": profile.parentRequirement,
            "sha256": String(repeating: "a", count: 64),
            "serviceCDHash": String(repeating: "b", count: 40)]
        #expect(profile.acceptsManifest(manifest))
        var wrongManifest = manifest
        wrongManifest["reviewCase"] = tag
        #expect(!profile.acceptsManifest(wrongManifest))
        wrongManifest = manifest
        wrongManifest["format"] = "drive-health-xpc-qa-v1"
        #expect(!profile.acceptsManifest(wrongManifest))
        var withoutUpdater = info; withoutUpdater.removeValue(forKey: "TraversePrivateUpdaterVersion")
        let noUpdater = try DriveHealthServiceIdentity.Profile.resolve(identifier: product, info: withoutUpdater)
        #expect(!noUpdater.updaterSelected)
        var publicInfo = withoutUpdater; publicInfo["TraversePublicUpdaterVersion"] = "2.10.0"
        let publicUpdater = try DriveHealthServiceIdentity.Profile.resolve(identifier: product, info: publicInfo)
        #expect(publicUpdater.updaterSelected)
        #expect(publicUpdater.acceptsManifest(manifest))
        let changes: [[String: Any]] = [
            ["MacExplorerDistributionChannel": "app-store"],
            ["MacExplorerSandboxQualificationCase": tag],
            ["MacExplorerReviewCase": tag],
            ["MacExplorerAccessPolicy": "local-user-v1"],
            ["TraverseDriveHealthHelperVersion": 2],
            ["TraversePrivateUpdaterVersion": "wrong"],
            ["TraversePublicUpdaterVersion": "2.10.0"],
            ["TraversePublicUpdaterVersion": NSNull()]]
        for change in changes {
            var wrong = info; wrong.merge(change) { _, replacement in replacement }
            #expect(throws: (any Error).self) {
                _ = try DriveHealthServiceIdentity.Profile.resolve(identifier: product, info: wrong)
            }
        }
    }

    @Test func directPublicServiceUsesExactLocalUserProfileAndManifest() throws {
        let product = "com.respawnstudios.traverse"
        let info = directInfo
        let profile = try DriveHealthServiceIdentity.Profile.resolve(identifier: product, info: info)
        #expect(profile.accessPolicy == .localUser)
        #expect(!profile.updaterSelected && profile.reviewCase == nil)
        #expect(profile.serviceIdentifier == product + ".drive.health.xpc")
        let manifest: [String: Any] = [
            "format": "drive-health-xpc-developer-id-v1",
            "parentIdentifier": product,
            "serviceIdentifier": profile.serviceIdentifier,
            "teamIdentifier": "CDLNJRG82U",
            "channel": "developer-id",
            "accessPolicy": "local-user-v1",
            "parentRequirement": profile.parentRequirement,
            "sha256": String(repeating: "a", count: 64),
            "serviceCDHash": String(repeating: "b", count: 40)]
        #expect(profile.acceptsManifest(manifest))
        var wrongManifest = manifest
        wrongManifest["accessPolicy"] = "sandbox-selected-v1"
        #expect(!profile.acceptsManifest(wrongManifest))
        let changes: [[String: Any]] = [
            ["TraverseDriveHealthServiceVersion": true],
            ["TraverseDriveHealthServiceVersion": 2],
            ["TraverseDriveHealthHelperVersion": 2],
            ["TraversePrivateUpdaterVersion": "2.10.0"],
            ["TraverseDirectStorageNamespace": "com.respawnstudios.traverse"],
            ["MacExplorerAccessPolicy": "sandbox-selected-v1"],
            ["MacExplorerSandboxQualificationCase": tag],
            ["SUFeedURL": "https://respawn-studios.com/products/traverse/public-updates/appcast.xml"]]
        for change in changes {
            var wrong = info
            wrong.merge(change) { _, replacement in replacement }
            #expect(throws: (any Error).self) {
                _ = try DriveHealthServiceIdentity.Profile.resolve(identifier: product, info: wrong)
            }
        }
    }
}
