import ExplorerCore
import Foundation
import XCTest

final class SupportReminderPreferencesTests: XCTestCase {
    func testOnceAtLaunchAndOnceForEachUpdateSurvivesRestartAndRollback() throws {
        var state = SupportReminderPreferences()
        state.recordLaunch()
        XCTAssertFalse(state.shouldPresent(version: "1.0", build: "100"))
        state = try JSONDecoder().decode(SupportReminderPreferences.self, from: JSONEncoder().encode(state))
        state.recordLaunch()
        XCTAssertTrue(state.shouldPresent(version: "1.0", build: "100"))
        state.recordPresentation(version: "1.0", build: "100")
        var reopened = try JSONDecoder().decode(SupportReminderPreferences.self, from: JSONEncoder().encode(state))
        XCTAssertFalse(reopened.shouldPresent(version: "1.0", build: "100"))
        XCTAssertTrue(reopened.shouldPresent(version: "1.0", build: "101"))
        reopened.recordPresentation(version: "1.0", build: "101")
        XCTAssertFalse(reopened.shouldPresent(version: "1.0", build: "100"))
        reopened.enabled = false
        XCTAssertFalse(reopened.shouldPresent(version: "1.1", build: "102"))
    }

    func testOldPreferencesAndInvalidReleaseMetadata() throws {
        var state = try JSONDecoder().decode(SupportReminderPreferences.self, from: Data("{}".utf8))
        XCTAssertTrue(state.enabled)
        for value in ["", "1..0", "/Users/Private", "1.0\n", "１.0"] {
            XCTAssertFalse(state.shouldPresent(version: value, build: "100"))
            state.recordPresentation(version: value, build: "100")
        }
        XCTAssertTrue(state.presentedReleases.isEmpty)
        XCTAssertFalse(state.shouldPresent(version: "1.0", build: "beta"))
        XCTAssertThrowsError(try JSONDecoder().decode(SupportReminderPreferences.self,
            from: Data(#"{"presentedReleases":["private-path"]}"#.utf8)))
    }

    func testHistoryIsBoundedAndDuplicatePresentationDoesNotGrowIt() {
        var state = SupportReminderPreferences()
        for build in 1...70 { state.recordPresentation(version: "1.0", build: String(build)) }
        state.recordPresentation(version: "1.0", build: "70")
        XCTAssertEqual(state.presentedReleases.count, 64)
        XCTAssertEqual(state.presentedReleases.first, "1.0 (7)")
        XCTAssertFalse(state.shouldPresent(version: "1.0", build: "70"))
    }
}
