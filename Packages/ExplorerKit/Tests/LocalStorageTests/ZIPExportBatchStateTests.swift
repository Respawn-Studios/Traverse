import XCTest
@testable import LocalStorage

final class ZIPExportBatchStateTests: XCTestCase {
    func testInvalidCountAndUnrequestedRetirement() throws {
        XCTAssertThrowsError(try ZIPExportBatchState(count: 0))
        XCTAssertThrowsError(try ZIPExportBatchState(count: 129))
        var state = try ZIPExportBatchState(count: 128)
        state.retireUnrequested()
        XCTAssertTrue(state.isDrained); XCTAssertTrue(state.isTerminal)
        XCTAssertFalse(state.request(0)); XCTAssertFalse(state.request(-1)); XCTAssertFalse(state.request(128))
    }
    func testOutOfOrderRequestsStaySerialAndReplaysCannotReplaceTheOriginal() throws {
        var state = try ZIPExportBatchState(count: 3)
        XCTAssertTrue(state.request(2)); XCTAssertTrue(state.request(0)); XCTAssertTrue(state.request(1))
        XCTAssertFalse(state.request(2)); XCTAssertEqual(state.next(), 2)
        XCTAssertNil(state.next()); XCTAssertFalse(state.request(2))
        XCTAssertThrowsError(try state.finish(0, succeeded: true))
        XCTAssertEqual(state.entry(2), .running)
        XCTAssertEqual(try state.finish(2, succeeded: true), [])
        XCTAssertEqual(state.next(), 0); XCTAssertEqual(try state.finish(0, succeeded: true), [])
        XCTAssertEqual(state.next(), 1); XCTAssertEqual(try state.finish(1, succeeded: true), [])
        XCTAssertTrue(state.isTerminal); XCTAssertEqual(state.completedCount, 3)
        XCTAssertFalse(state.request(0)); XCTAssertThrowsError(try state.finish(1, succeeded: true))
    }
    func testFailureKeepsVerifiedPrefixAndRetiresQueuedAndUntouchedTail() throws {
        var state = try ZIPExportBatchState(count: 4)
        XCTAssertTrue(state.request(0)); XCTAssertEqual(state.next(), 0)
        _ = try state.finish(0, succeeded: true)
        XCTAssertTrue(state.request(2)); XCTAssertTrue(state.request(1)); XCTAssertEqual(state.next(), 2)
        XCTAssertEqual(try state.finish(2, succeeded: false), [1])
        XCTAssertEqual(state.entry(0), .succeeded); XCTAssertEqual(state.entry(2), .failed)
        XCTAssertEqual(state.entry(1), .retired); XCTAssertEqual(state.entry(3), .retired)
        XCTAssertTrue(state.stopped); XCTAssertTrue(state.isTerminal); XCTAssertEqual(state.completedCount, 1)
    }
    func testStopDoesNotPretendTheRunningWorkerHasDrained() throws {
        var state = try ZIPExportBatchState(count: 3)
        XCTAssertTrue(state.request(1)); XCTAssertTrue(state.request(2)); XCTAssertEqual(state.next(), 1)
        XCTAssertEqual(state.stop(), [2]); XCTAssertFalse(state.isDrained); XCTAssertFalse(state.isTerminal)
        XCTAssertEqual(state.entry(1), .running); XCTAssertNil(state.next()); XCTAssertFalse(state.request(0))
        _ = try state.finish(1, succeeded: true)
        XCTAssertTrue(state.isTerminal); XCTAssertEqual(state.completedCount, 1)
    }
    func testClosingAnOfferRetiresOnlyUnrequestedRootsAndAllowsAcceptedDrain() throws {
        var state = try ZIPExportBatchState(count: 3)
        XCTAssertTrue(state.request(1)); XCTAssertTrue(state.request(2)); XCTAssertEqual(state.next(), 1)
        state.retireUnrequested()
        XCTAssertEqual(state.entry(0), .retired); XCTAssertEqual(state.entry(2), .queued)
        _ = try state.finish(1, succeeded: true); XCTAssertEqual(state.next(), 2)
        _ = try state.finish(2, succeeded: true); XCTAssertTrue(state.isTerminal)
    }
    func testDelayedUncalledRootCanBeAdmittedAfterTheFirstWriterDrains() throws {
        var state = try ZIPExportBatchState(count: 2)
        XCTAssertTrue(state.request(0)); XCTAssertEqual(state.next(), 0); _ = try state.finish(0, succeeded: true)
        XCTAssertTrue(state.isDrained); XCTAssertFalse(state.isTerminal)
        XCTAssertTrue(state.request(1)); XCTAssertEqual(state.next(), 1); _ = try state.finish(1, succeeded: true)
        XCTAssertTrue(state.isTerminal)
    }
}
