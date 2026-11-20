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

    #if DEBUG
    func testExpiredCloseCanObserveLateChildExitAndEOF() async throws {
        let activity = FileActivityGate()
        let (close, peer) = try makeExpiredCloseProbe(activity: activity)
        defer { SFTPWorkerSession.resumeAdmissions() }
        let first = await close()
        XCTAssertFalse(first.localResourcesEnded)
        XCTAssertFalse(first.contained)
        XCTAssertFalse(first.ipcEOF)
        XCTAssertEqual(activity.activeCount, 1)
        let quitBeforeEOF = await SFTPWorkerSession.pauseAndDrainOwned()
        XCTAssertFalse(quitBeforeEOF)
        SFTPWorkerSession.resumeAdmissions()
        Darwin.close(peer)

        let completed = await observeCompletedClose(close)
        XCTAssertTrue(completed.localResourcesEnded)
        XCTAssertEqual(completed.exitStatus, 0)
        XCTAssertFalse(completed.contained)
        XCTAssertEqual(activity.activeCount, 0)
        guard completed.localResourcesEnded else { return }

        let (nextClose, nextPeer) = try makeExpiredCloseProbe(activity: activity)
        Darwin.close(nextPeer)
        let next = await observeCompletedClose(nextClose)
        XCTAssertTrue(next.localResourcesEnded)
        let quitAfterDrain = await SFTPWorkerSession.pauseAndDrainOwned()
        XCTAssertTrue(quitAfterDrain)
        XCTAssertEqual(activity.activeCount, 0)
    }

    private func makeExpiredCloseProbe(activity: FileActivityGate) throws
        -> (@Sendable () async -> SFTPWorkerClose, Int32) {
        var pair: [Int32] = [-1, -1]
        try requireCall(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        var adopted = false
        defer { if !adopted { pair.forEach { Darwin.close($0) } } }
        for descriptor in pair { try requireCall(fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0) }
        try requireCall(fcntl(pair[0], F_SETFL, O_NONBLOCK) == 0)

        var child: pid_t = 0
        var arguments = [strdup("/bin/sleep"), strdup("1"), nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        defer { arguments.forEach { free($0) } }
        try requireCall(posix_spawn(&child, "/bin/sleep", nil, nil, &arguments, &environment) == 0)
        defer {
            if !adopted { var status: Int32 = 0; _ = waitpid(child, &status, 0) }
        }
        let close = try SFTPWorkerSession.generatedExpiredCloseProbe(child: child, descriptor: pair[0], activity: activity)
        adopted = true
        return (close, pair[1])
    }

    private func observeCompletedClose(_ close: @Sendable () async -> SFTPWorkerClose) async -> SFTPWorkerClose {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var result = await close()
        while !result.localResourcesEnded && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            result = await close()
        }
        return result
    }

    private func requireCall(_ succeeded: Bool) throws {
        if !succeeded { throw POSIXError(.EIO) }
    }
    #endif
}
