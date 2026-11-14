import Darwin
import ExplorerCore
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SFTPWorkerOwnershipTests: XCTestCase {
    func testShutdownBlocksUnadoptedSetupBeforeAnyChildOrActivity() async {
        let drained = await SFTPWorkerSession.pauseAndDrainOwned(); XCTAssertTrue(drained)
        defer { SFTPWorkerSession.resumeAdmissions() }
        let activity = FileActivityGate()
        do { _ = try await SFTPWorkerSession.openGenerated(port: 1, activity: activity); XCTFail("Shutdown admitted setup") }
        catch { XCTAssertEqual(error as? SFTPSessionFailure, .busy) }
        XCTAssertEqual(activity.activeCount, 0)
    }
    func testOnlyAnExactReapedChildCanReportExit() {
        XCTAssertEqual(SFTPChildWait.observe(expected: 123, found: 0, status: 0, error: ECHILD), .pending)
        XCTAssertEqual(SFTPChildWait.observe(expected: 123, found: -1, status: 0, error: EINTR), .pending)
        XCTAssertEqual(SFTPChildWait.observe(expected: 123, found: -1, status: 0, error: ECHILD), .uncertain)
        XCTAssertEqual(SFTPChildWait.observe(expected: 123, found: 124, status: 0, error: 0), .uncertain)
        XCTAssertEqual(SFTPChildWait.observe(expected: 123, found: 123, status: 0x300, error: 0), .exited(3))
        XCTAssertEqual(SFTPChildWait.observe(expected: 123, found: 123, status: 15, error: 0), .exited(-15))
        XCTAssertEqual(SFTPChildWait.observe(expected: 123, found: 123, status: 0x137f, error: 0), .pending)
    }
    func testInvalidEndpointAndAlreadyCancelledTaskAdmitNoActivity() async {
        let activity = FileActivityGate()
        do { _ = try await SFTPWorkerSession.openGenerated(port: 0, activity: activity); XCTFail() }
        catch { XCTAssertEqual(error as? SFTPSessionFailure, .input) }
        XCTAssertEqual(activity.activeCount, 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SFTPWorkerSession.openGenerated(port: 1, activity: activity)
        }
        do { _ = try await task.value; XCTFail() }
        catch { XCTAssertEqual(error as? SFTPSessionFailure, .stopped) }
        XCTAssertEqual(activity.activeCount, 0)
    }
}
