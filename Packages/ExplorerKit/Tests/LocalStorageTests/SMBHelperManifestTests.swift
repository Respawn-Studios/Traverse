import Foundation
@testable import LocalStorage
import XCTest

final class SMBHelperManifestTests: XCTestCase {
    func testCandidateRuntimeCannotUseLocalIdentityEvenWithoutCompilerFlag() {
        for allowed in [false, true] {
            for value: Any in ["candidate", "app-store", "direct-beta", "", "Development", true, 1] {
                XCTAssertFalse(SMBBundledHelperIdentity.permitsLocalChannel(value, qualificationAllowed: allowed))
            }
            XCTAssertTrue(SMBBundledHelperIdentity.permitsLocalChannel(nil, qualificationAllowed: allowed))
            XCTAssertTrue(SMBBundledHelperIdentity.permitsLocalChannel("development", qualificationAllowed: allowed))
        }
        XCTAssertFalse(SMBBundledHelperIdentity.permitsLocalChannel("qualification", qualificationAllowed: false))
        XCTAssertTrue(SMBBundledHelperIdentity.permitsLocalChannel("qualification", qualificationAllowed: true))
    }
    private func fields(_ qualification: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["version": 1, "channel": qualification ? "qualification" : "development",
            "parentIdentifier": "local.macexplorer.development", "teamIdentifier": "adhoc",
            "roles": ["browser": ["identifier": "local.macexplorer.smb.browser", "sha256": String(repeating: "a", count: 64)]]]
        if qualification { result["case"] = "97307A11-6130-4E73-BBDE-D240B89A2A4A" }
        return result
    }
    func testExplicitLocalLanesAndExactRole() throws {
        let local = try SMBBundledHelperIdentity.Manifest(fields(), role: .browser, qualificationAllowed: false)
        XCTAssertFalse(local.qualification); XCTAssertEqual(local.team, "adhoc")
        XCTAssertTrue(try SMBBundledHelperIdentity.Manifest(fields(true), role: .browser, qualificationAllowed: true).qualification)
        XCTAssertThrowsError(try SMBBundledHelperIdentity.Manifest(fields(), role: .resolver, qualificationAllowed: true))
    }
    func testDistributionCannotFallBackToLocalPolicy() {
        for channel in ["distribution", "provisioned", "", "development-v2"] {
            var value = fields(); value["channel"] = channel
            XCTAssertThrowsError(try SMBBundledHelperIdentity.Manifest(value, role: .browser, qualificationAllowed: true))
        }
        XCTAssertThrowsError(try SMBBundledHelperIdentity.Manifest(fields(true), role: .browser, qualificationAllowed: false))
    }
    func testSignerAndDigestInputsAreBounded() {
        for team in ["", "unknown", "AAAAAAAAAAA", "a123456789", "AAAAAAAAA\n"] {
            var value = fields(); value["teamIdentifier"] = team
            XCTAssertThrowsError(try SMBBundledHelperIdentity.Manifest(value, role: .browser, qualificationAllowed: false))
        }
        for digest in ["", String(repeating: "A", count: 64), String(repeating: "a", count: 65), String(repeating: "g", count: 64)] {
            var value = fields(); value["roles"] = ["browser": ["identifier": "local.macexplorer.smb.browser", "sha256": digest]]
            XCTAssertThrowsError(try SMBBundledHelperIdentity.Manifest(value, role: .browser, qualificationAllowed: false))
        }
    }
    func testVersionSchemaAndQualificationIdentityRefuseAmbiguity() {
        for version: Any in [true, 1.5, "1", 2] {
            var value = fields(); value["version"] = version
            XCTAssertThrowsError(try SMBBundledHelperIdentity.Manifest(value, role: .browser, qualificationAllowed: false))
        }
        var value = fields(); value["password"] = "never-admit-this-field"
        XCTAssertThrowsError(try SMBBundledHelperIdentity.Manifest(value, role: .browser, qualificationAllowed: false))
        value = fields(true); value["case"] = "not-an-owned-case"
        XCTAssertThrowsError(try SMBBundledHelperIdentity.Manifest(value, role: .browser, qualificationAllowed: true))
    }
    func testHelperRolesCannotBeInterchanged() {
        var value = fields()
        value["roles"] = ["browser": ["identifier": "local.macexplorer.smb.resolver", "sha256": String(repeating: "a", count: 64)]]
        XCTAssertThrowsError(try SMBBundledHelperIdentity.Manifest(value, role: .browser, qualificationAllowed: false))
        value["roles"] = ["browser": ["identifier": "local.macexplorer.smb.browser", "sha256": String(repeating: "a", count: 64), "path": "../other"]]
        XCTAssertThrowsError(try SMBBundledHelperIdentity.Manifest(value, role: .browser, qualificationAllowed: false))
    }
}
