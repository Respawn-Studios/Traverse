import Foundation
import XCTest
@testable import LocalStorage

final class SFTPHelperManifestTests: XCTestCase {
    private func fields() -> [String: Any] {
        ["version": 1, "channel": "development", "parentIdentifier": "local.macexplorer.development", "teamIdentifier": "adhoc",
         "roles": ["sftp": ["identifier": "local.macexplorer.sftp.metadata", "sha256": String(repeating: "a", count: 64)]]]
    }
    func testSFTPRoleHasDistinctIdentityManifestAndBoundedArtifact() throws {
        XCTAssertEqual(SMBBundledHelperIdentity.Role.sftp.basename, "sftp-metadata-worker")
        XCTAssertEqual(SMBBundledHelperIdentity.Role.sftp.manifestResource, "SFTPHelperManifest.plist")
        XCTAssertEqual(SMBBundledHelperIdentity.Role.sftp.maximumBytes, 8 << 20)
        let value = try SMBBundledHelperIdentity.Manifest(fields(), role: .sftp, qualificationAllowed: false)
        XCTAssertFalse(value.qualification); XCTAssertEqual(value.parent, "local.macexplorer.development")
    }
    func testSMBAndSFTPManifestsCannotAdmitEachOthersRoles() {
        XCTAssertThrowsError(try SMBBundledHelperIdentity.Manifest(fields(), role: .browser, qualificationAllowed: true))
        var mixed = fields(); mixed["roles"] = ["sftp": ["identifier": "local.macexplorer.sftp.metadata", "sha256": String(repeating: "a", count: 64)],
            "browser": ["identifier": "local.macexplorer.smb.browser", "sha256": String(repeating: "a", count: 64)]]
        for role in [SMBBundledHelperIdentity.Role.sftp, .browser] {
            XCTAssertThrowsError(try SMBBundledHelperIdentity.Manifest(mixed, role: role, qualificationAllowed: true))
        }
    }
    func testSFTPRefusesWrongIdentifierAndUnsupportedDistributionLane() {
        var wrong = fields(); wrong["roles"] = ["sftp": ["identifier": "local.macexplorer.smb.browser", "sha256": String(repeating: "a", count: 64)]]
        XCTAssertThrowsError(try SMBBundledHelperIdentity.Manifest(wrong, role: .sftp, qualificationAllowed: true))
        for channel in ["candidate", "app-store", "distribution", ""] {
            var wrong = fields(); wrong["channel"] = channel
            XCTAssertThrowsError(try SMBBundledHelperIdentity.Manifest(wrong, role: .sftp, qualificationAllowed: true))
        }
    }
    func testQualificationRequiresExplicitCaseAndNoSecretOrPathFields() throws {
        var value = fields(); value["channel"] = "qualification"; value["case"] = UUID().uuidString
        XCTAssertTrue(try SMBBundledHelperIdentity.Manifest(value, role: .sftp, qualificationAllowed: true).qualification)
        XCTAssertThrowsError(try SMBBundledHelperIdentity.Manifest(value, role: .sftp, qualificationAllowed: false))
        value["password"] = "generated forbidden field"
        XCTAssertThrowsError(try SMBBundledHelperIdentity.Manifest(value, role: .sftp, qualificationAllowed: true))
    }
}
