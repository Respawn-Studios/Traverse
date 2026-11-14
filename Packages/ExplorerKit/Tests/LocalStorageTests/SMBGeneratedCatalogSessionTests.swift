import Foundation
import ExplorerCore
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SMBGeneratedCatalogSessionTests: XCTestCase, @unchecked Sendable {
    func testPrecancelAndClosedActivityReleaseAdmissionBeforeReturningFailure() async throws {
        let activity = FileActivityGate(maximumActivities: 1)
        let missing = URL(fileURLWithPath: "/not-a-generated-catalog")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SMBGeneratedCatalogSession.start(bundleURL: missing, generatedCase: missing, activity: activity)
        }
        do { _ = try await cancelled.value; XCTFail() }
        catch { XCTAssertEqual(error as? SMBDirectoryFailure, .stopped) }
        XCTAssertEqual(activity.activeCount, 0)
        let token = try XCTUnwrap(activity.closeAdmission())
        do { _ = try await SMBGeneratedCatalogSession.start(bundleURL: missing, generatedCase: missing, activity: activity); XCTFail() }
        catch { XCTAssertEqual(error as? SMBDirectoryFailure, .unavailable) }
        XCTAssertEqual(activity.activeCount, 0); XCTAssertTrue(activity.reopen(token))
        do { _ = try await SMBGeneratedCatalogSession.start(bundleURL: missing, generatedCase: missing, activity: activity); XCTFail() }
        catch { XCTAssertEqual(error as? SMBDirectoryFailure, .invalidInput) }
        XCTAssertEqual(activity.activeCount, 0)
    }
}
