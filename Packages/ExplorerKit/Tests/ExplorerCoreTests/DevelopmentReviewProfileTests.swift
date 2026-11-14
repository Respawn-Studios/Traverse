import Foundation
@testable import ExplorerCore
import XCTest

final class DevelopmentReviewProfileTests: XCTestCase {
    private let tag = "580E1F8D-6805-40B1-8173-8F8D7A4EA80F"
    private let checkout = URL(fileURLWithPath: "/generated/Traverse", isDirectory: true)
    func testSeparateStateAndCacheStayWithinTheSealedGeneratedCase() throws {
        let profile = try DevelopmentReviewProfile(identifier: DevelopmentReviewProfile.identifier,
            channel: DevelopmentReviewProfile.channel, caseID: tag, checkout: checkout)
        let root = checkout.appendingPathComponent(".build/traverse-development/" + tag)
        XCTAssertEqual(profile.layout.stateDirectory.path, root.appendingPathComponent("state").path)
        XCTAssertEqual(profile.layout.cacheDirectory.path, root.appendingPathComponent("cache").path)
        XCTAssertNotEqual(profile.layout.stateDirectory, profile.layout.cacheDirectory)
        XCTAssertEqual(profile.layout.analysisDirectory.path, root.appendingPathComponent("cache/storage-analysis").path)
        XCTAssertNotEqual(profile.layout.analysisDirectory, profile.layout.cacheDirectory)
        XCTAssertEqual(profile.layout.channel, .development)
        XCTAssertFalse(profile.layout.stateDirectory.path.contains("Application Support"))
    }
    func testProductionOldDevelopmentAndIncompleteIdentityNeverReuseThisProfile() {
        for identifier in [nil, "com.respawnstudios.traverse", "local.macexplorer.development", "local.macexplorer.preview.other"] {
            XCTAssertThrowsError(try DevelopmentReviewProfile(identifier: identifier,
                channel: DevelopmentReviewProfile.channel, caseID: tag, checkout: checkout))
        }
        for channel in [nil, "app-store", "developer-id", "development", "qualification"] {
            XCTAssertThrowsError(try DevelopmentReviewProfile(identifier: DevelopmentReviewProfile.identifier,
                channel: channel, caseID: tag, checkout: checkout))
        }
    }
    func testUnboundAndNoncanonicalProfilesCannotEscapeIntoOtherState() {
        for value in [nil, "", tag.lowercased(), "../runtime", tag + "/../runtime", "/tmp", "A"] {
            XCTAssertThrowsError(try DevelopmentReviewProfile(identifier: DevelopmentReviewProfile.identifier,
                channel: DevelopmentReviewProfile.channel, caseID: value, checkout: checkout))
        }
        for value in [URL(string: "https://example.invalid/Traverse")!, URL(fileURLWithPath: "/"),
                      URL(string: "file:///generated/Traverse?other")!] {
            XCTAssertThrowsError(try DevelopmentReviewProfile(identifier: DevelopmentReviewProfile.identifier,
                channel: DevelopmentReviewProfile.channel, caseID: tag, checkout: value))
        }
    }
    func testExplicitPrivateUserProfileSharesNoBetaOrOtherCaseNamespace() throws {
        let support = URL(fileURLWithPath: "/generated/Library/Application Support", isDirectory: true)
        let caches = URL(fileURLWithPath: "/generated/Library/Caches", isDirectory: true)
        let value = try DevelopmentReviewProfile(identifier: DevelopmentReviewProfile.identifier,
            channel: DevelopmentReviewProfile.channel, caseID: tag, checkout: checkout,
            storage: .privateUser, applicationSupport: support, caches: caches)
        let namespace = "local.macexplorer.preview." + tag.lowercased()
        XCTAssertEqual(value.layout.stateDirectory.path, support.appendingPathComponent(namespace).path)
        XCTAssertEqual(value.layout.cacheDirectory.path, caches.appendingPathComponent(namespace).path)
        XCTAssertEqual(value.layout.channel, .portable)
        XCTAssertNotEqual(value.layout.stateDirectory.lastPathComponent, "com.respawnstudios.traverse")
        XCTAssertThrowsError(try DevelopmentReviewProfile(identifier: DevelopmentReviewProfile.identifier,
            channel: DevelopmentReviewProfile.channel, caseID: tag, checkout: checkout, storage: .privateUser))
    }
}
