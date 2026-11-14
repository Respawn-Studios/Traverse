import Foundation
@testable import LocalStorage
import XCTest

final class StoreHelperIdentityTests: XCTestCase {
    func testPreviewHasAnExactSealedParentAndCanonicalProfileWithoutDistributionFallback() {
        let tag = "580E1F8D-6805-40B1-8173-8F8D7A4EA80F"
        XCTAssertTrue(SMBBundledHelperIdentity.permitsDevelopmentParent("local.macexplorer.preview",
            channel: "development-preview", reviewCase: tag))
        XCTAssertTrue(SMBBundledHelperIdentity.permitsDevelopmentParent("local.macexplorer.development",
            channel: nil, reviewCase: nil))
        for parent in ["com.respawnstudios.traverse", "local.macexplorer.preview.other", "local.macexplorer.development"] {
            XCTAssertFalse(SMBBundledHelperIdentity.permitsDevelopmentParent(parent, channel: "development-preview", reviewCase: tag))
        }
        for channel: Any? in [nil, true, "app-store", "developer-id", "development", "qualification"] {
            XCTAssertFalse(SMBBundledHelperIdentity.permitsDevelopmentParent("local.macexplorer.preview", channel: channel, reviewCase: tag))
        }
        for value: Any? in [nil, true, tag.lowercased(), "../runtime", ""] {
            XCTAssertFalse(SMBBundledHelperIdentity.permitsDevelopmentParent("local.macexplorer.preview", channel: "development-preview", reviewCase: value))
        }
    }
    private func fields(_ sftp: Bool = false) -> [String: Any] {
        let names: [SMBBundledHelperIdentity.Role] = sftp ? [.sftp] : [.browser, .resolver]
        return ["version": 3, "channel": "app-store", "accessPolicy": "sandbox-selected-v1", "parentIdentifier": "com.respawnstudios.traverse", "teamIdentifier": "CDLNJRG82U",
            "roles": Dictionary(uniqueKeysWithValues: names.map { ($0.rawValue, ["identifier": $0.storeIdentifier]) })]
    }
    func testSealedRoleMapsAreSeparateFromDevelopmentHashLanes() throws {
        for role in [SMBBundledHelperIdentity.Role.browser, .resolver, .sftp] {
            let value = fields(role.isSFTP)
            _ = try SMBBundledHelperIdentity.StoreManifest(value, role: role)
            XCTAssertThrowsError(try SMBBundledHelperIdentity.Manifest(value, role: role, qualificationAllowed: true))
        }
    }
    func testWrongTeamParentChannelVersionAndExtraFieldsRefuse() {
        for (key, value): (String, Any) in [("version", true), ("version", 1), ("version", 2), ("version", 3.1), ("version", "3"),
            ("channel", "development"), ("parentIdentifier", "local.macexplorer.development"),
            ("teamIdentifier", "adhoc"), ("teamIdentifier", "AAAAAAAAAA"), ("password", "not-admitted"), ("case", UUID().uuidString)] {
            var candidate = fields(); candidate[key] = value
            XCTAssertThrowsError(try SMBBundledHelperIdentity.StoreManifest(candidate, role: .browser))
        }
    }
    func testRolesCannotBeMixedSubstitutedOrPointOutsideBundle() {
        var candidate = fields(); candidate["roles"] = ["browser": ["identifier": "com.respawnstudios.traverse.smb.resolver"]]
        XCTAssertThrowsError(try SMBBundledHelperIdentity.StoreManifest(candidate, role: .browser))
        candidate["roles"] = ["browser": ["identifier": SMBBundledHelperIdentity.Role.browser.storeIdentifier, "path": "/tmp/other"]]
        XCTAssertThrowsError(try SMBBundledHelperIdentity.StoreManifest(candidate, role: .browser))
        XCTAssertThrowsError(try SMBBundledHelperIdentity.StoreManifest(fields(true), role: .resolver))
        XCTAssertThrowsError(try SMBBundledHelperIdentity.StoreManifest(fields(), role: .sftp))
    }
    func testDirectDownloadRequiresItsExactSealedChannelWithoutDevelopmentFallback() throws {
        var direct = fields(true); direct["channel"] = "developer-id"
        _ = try SMBBundledHelperIdentity.StoreManifest(direct, role: .sftp, channel: "developer-id")
        XCTAssertThrowsError(try SMBBundledHelperIdentity.StoreManifest(direct, role: .sftp, channel: "app-store"))
        XCTAssertThrowsError(try SMBBundledHelperIdentity.StoreManifest(fields(true), role: .sftp, channel: "developer-id"))
        XCTAssertThrowsError(try SMBBundledHelperIdentity.StoreManifest(direct, role: .sftp, channel: "development"))
        XCTAssertFalse(SMBBundledHelperIdentity.permitsLocalChannel("developer-id", qualificationAllowed: true))
    }
    private var parent: [String: Any] { ["com.apple.security.app-sandbox": true, "com.apple.security.files.user-selected.read-write": true,
        "com.apple.security.files.bookmarks.app-scope": true, "com.apple.security.network.client": true] }
    func testExactSandboxAndIdentityRights() {
        XCTAssertTrue(SMBBundledHelperIdentity.storeRightsAdmitted(parent, helper: false))
        var fields = parent; fields["com.apple.application-identifier"] = "CDLNJRG82U.com.respawnstudios.traverse"
        fields["com.apple.developer.team-identifier"] = "CDLNJRG82U"; fields["beta-reports-active"] = true
        fields["keychain-access-groups"] = ["CDLNJRG82U.com.respawnstudios.traverse"]
        XCTAssertTrue(SMBBundledHelperIdentity.storeRightsAdmitted(fields, helper: false))
        fields["com.apple.application-identifier"] = "CDLNJRG82U.com.respawnstudios.other"
        XCTAssertFalse(SMBBundledHelperIdentity.storeRightsAdmitted(fields, helper: false))
        XCTAssertTrue(SMBBundledHelperIdentity.storeRightsAdmitted(["com.apple.security.app-sandbox": true, "com.apple.security.inherit": true], helper: true))
        XCTAssertFalse(SMBBundledHelperIdentity.storeRightsAdmitted(parent, helper: true))
    }
    func testKnownDirectUpdaterParentMachNamesAreAdmitted() {
        let right = "com.apple.security.temporary-exception.mach-lookup.global-name"
        let exact = ["com.respawnstudios.traverse-spks", "com.respawnstudios.traverse-spki"]
        var signedParent = parent
        signedParent[right] = exact
        XCTAssertTrue(SMBBundledHelperIdentity.storeRightsAdmitted(signedParent, helper: false,
            channel: "developer-id", updaterSelected: true))
        XCTAssertFalse(SMBBundledHelperIdentity.storeRightsAdmitted(signedParent, helper: false))
        XCTAssertFalse(SMBBundledHelperIdentity.storeRightsAdmitted(signedParent, helper: false,
            channel: "developer-id"))
        XCTAssertFalse(SMBBundledHelperIdentity.storeRightsAdmitted(signedParent, helper: false,
            channel: "app-store", updaterSelected: true))
        XCTAssertFalse(SMBBundledHelperIdentity.storeRightsAdmitted(signedParent, helper: false,
            policy: .localUser, channel: "developer-id", updaterSelected: true))
        XCTAssertFalse(SMBBundledHelperIdentity.storeRightsAdmitted(signedParent, helper: true,
            channel: "developer-id", updaterSelected: true))
        XCTAssertFalse(SMBBundledHelperIdentity.storeRightsAdmitted(parent, helper: false,
            channel: "developer-id", updaterSelected: true))
        for names in [[], ["*"], [exact[1], exact[0]], [exact[0]],
                      [exact[0], "com.respawnstudios.other-spki"], exact + ["extra"]] {
            var changed = signedParent; changed[right] = names
            XCTAssertFalse(SMBBundledHelperIdentity.storeRightsAdmitted(changed, helper: false,
                channel: "developer-id", updaterSelected: true), String(describing: names))
        }
        var altered = signedParent; altered[right] = true
        XCTAssertFalse(SMBBundledHelperIdentity.storeRightsAdmitted(altered, helper: false,
            channel: "developer-id", updaterSelected: true))
        altered = signedParent; altered["com.apple.security.network.server"] = true
        XCTAssertFalse(SMBBundledHelperIdentity.storeRightsAdmitted(altered, helper: false,
            channel: "developer-id", updaterSelected: true))
        let helperRights: [String: Any] = ["com.apple.security.app-sandbox": true, "com.apple.security.inherit": true]
        XCTAssertTrue(SMBBundledHelperIdentity.storeRightsAdmitted(helperRights, helper: true,
            channel: "developer-id"))
        altered = helperRights; altered[right] = exact
        XCTAssertFalse(SMBBundledHelperIdentity.storeRightsAdmitted(altered, helper: true,
            channel: "developer-id"))
    }
    func testDirectUpdaterMarkersAreExclusiveAndVersioned() {
        XCTAssertEqual(DirectUpdaterMarker.resolve(info: [:]), .absent)
        XCTAssertEqual(DirectUpdaterMarker.resolve(info: ["TraversePrivateUpdaterVersion": "2.10.0"]), .privateBeta)
        XCTAssertEqual(DirectUpdaterMarker.resolve(info: ["TraversePublicUpdaterVersion": "2.10.0"]), .publicRelease)
        XCTAssertEqual(DirectUpdaterMarker.resolve(info: ["TraverseDirectPublicUpdaterVersion": "2.10.0"]), .directPublic)
        XCTAssertFalse(DirectUpdaterMarker.resolve(info: ["TraverseDirectPublicUpdaterVersion": "2.10.0"])!
            .requiresInstallerRights)
        XCTAssertEqual(DirectUpdaterMarker.resolve(info: ["TraversePublicUpdaterVersion": "2.10.0"])?
            .requiresInstallerRights, true)
        let invalid: [[String: Any]] = [
            ["TraversePrivateUpdaterVersion": "2.10.0", "TraversePublicUpdaterVersion": "2.10.0"],
            ["TraversePrivateUpdaterVersion": "2.10.0", "TraversePublicUpdaterVersion": NSNull()],
            ["TraverseDirectPublicUpdaterVersion": "2.10.0", "TraversePublicUpdaterVersion": NSNull()],
            ["TraverseDirectPublicUpdaterVersion": "2.10.0", "TraversePrivateUpdaterVersion": "2.10.0"],
            ["TraverseDirectPublicUpdaterVersion": "wrong"],
            ["TraversePublicUpdaterVersion": "wrong"],
            ["TraversePrivateUpdaterVersion": true]
        ]
        for fields in invalid {
            XCTAssertNil(DirectUpdaterMarker.resolve(info: fields))
        }
    }
    func testDebugBroadAccessCredentialsAndNumericBooleansAreRefused() {
        for (key, value): (String, Any) in [("com.apple.security.get-task-allow", true), ("com.apple.security.network.server", true),
            ("com.apple.security.temporary-exception.files.absolute-path.read-write", ["/"]), ("keychain-access-groups", ["CDLNJRG82U.*"]),
            ("com.apple.developer.team-identifier", "AAAAAAAAAA"), ("com.apple.security.network.client", 1), ("beta-reports-active", 1)] {
            var candidate = parent; candidate[key] = value
            XCTAssertFalse(SMBBundledHelperIdentity.storeRightsAdmitted(candidate, helper: false), key)
        }
    }
    func testLocalUserPolicyCannotLeakIntoAppStoreOrMixedHelperFamilies() throws {
        for role in [SMBBundledHelperIdentity.Role.browser, .resolver, .sftp] {
            var value = fields(role.isSFTP)
            value["channel"] = "developer-id"; value["accessPolicy"] = FileAccessPolicy.localUser.rawValue
            _ = try SMBBundledHelperIdentity.StoreManifest(value, role: role, channel: "developer-id", policy: .localUser)
            XCTAssertThrowsError(try SMBBundledHelperIdentity.StoreManifest(value, role: role, channel: "developer-id"))
            XCTAssertThrowsError(try SMBBundledHelperIdentity.StoreManifest(value, role: role, policy: .localUser))
            value.removeValue(forKey: "accessPolicy")
            XCTAssertThrowsError(try SMBBundledHelperIdentity.StoreManifest(value, role: role, channel: "developer-id", policy: .localUser))
        }
        XCTAssertTrue(SMBBundledHelperIdentity.storeRightsAdmitted([:], helper: true, policy: .localUser))
        XCTAssertTrue(SMBBundledHelperIdentity.storeRightsAdmitted([:], helper: false, policy: .localUser))
        XCTAssertFalse(SMBBundledHelperIdentity.storeRightsAdmitted(parent, helper: false, policy: .localUser))
        XCTAssertFalse(SMBBundledHelperIdentity.storeRightsAdmitted([:], helper: false))
        for key in ["com.apple.security.app-sandbox", "com.apple.security.inherit", "com.apple.security.get-task-allow",
            "com.apple.security.cs.disable-library-validation", "com.apple.security.network.server"] {
            XCTAssertFalse(SMBBundledHelperIdentity.storeRightsAdmitted([key: true], helper: true, policy: .localUser))
            XCTAssertFalse(SMBBundledHelperIdentity.storeRightsAdmitted([key: true], helper: false, policy: .localUser))
        }
    }
}
