import Foundation

private enum ControlFailure: Error { case failed(String), expected }
private actor HeldReader {
    private var holds = [Int: CheckedContinuation<Void, Never>]()
    private(set) var entered = [Int]()
    private(set) var cancelledAtReturn = [Int]()
    private(set) var active = 0
    private(set) var maximum = 0
    func read(_ id: Int, fail: Bool = false) async throws -> Int {
        active += 1; maximum = max(maximum, active); entered.append(id)
        // Deliberately ignore cancellation until the real work is released.
        // This distinguishes retirement from merely cancelling a Task handle.
        await withCheckedContinuation { holds[id] = $0 }
        if Task.isCancelled { cancelledAtReturn.append(id) }
        active -= 1
        if fail { throw ControlFailure.expected }
        return id
    }
    func finish(_ id: Int) { holds.removeValue(forKey: id)?.resume() }
}
private actor StartBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    func wait() async { await withCheckedContinuation { waiting = true; continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@main private struct AdmissionControls {
    static func until(_ label: String, _ predicate: @Sendable () async -> Bool) async throws {
        for _ in 0..<2_000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ControlFailure.failed("deadline-" + label)
    }
    static func main() async throws {
        let gate = ArchiveMetadataAdmission(), reader = HeldReader()
        var checks = [String]()
        func require(_ value: Bool, _ label: String) throws {
            guard value else { throw ControlFailure.failed(label) }; checks.append(label)
        }
        func submit(_ id: Int, fail: Bool = false) -> Task<Int, Error> {
            Task { try await gate.withAdmission { try await reader.read(id, fail: fail) } }
        }
        let first = submit(0)
        try await until("first-entered") { await reader.entered == [0] }
        var waiters = [Int: Task<Int, Error>]()
        for id in 1...8 {
            waiters[id] = submit(id)
            try await until("queued-\(id)") { await gate.activity.pending == id }
        }
        try require(await gate.activity == .init(active: 1, pending: 8), "one-active-eight-pending")
        do { _ = try await submit(9).value; throw ControlFailure.failed("overflow-admitted") }
        catch ArchiveMetadataAdmission.Failure.busy { checks.append("ninth-waiter-refused") }
        for id in [2, 8] {
            waiters[id]!.cancel()
            do { _ = try await waiters[id]!.value; throw ControlFailure.failed("cancelled-waiter-returned") }
            catch is CancellationError { checks.append("waiting-\(id)-cancelled") }
            waiters[id] = nil
        }
        try require(await gate.activity.pending == 6, "cancelled-waiters-remove-capacity")
        for id in [10, 11] {
            waiters[id] = submit(id)
            try await until("replacement-\(id)") { await gate.activity.pending == (id == 10 ? 7 : 8) }
        }
        waiters[10]!.cancel()
        do { _ = try await waiters[10]!.value; throw ControlFailure.failed("old-desired-returned") }
        catch is CancellationError { checks.append("superseded-desired-cancelled") }
        waiters[10] = nil; waiters[12] = submit(12)
        try await until("latest-queued") { await gate.activity.pending == 8 }
        first.cancel()
        for _ in 0..<100 { await Task.yield() }
        try require(await gate.activity == .init(active: 1, pending: 8), "admitted-cancellation-retains-slot")
        try require(await reader.entered == [0], "cancel-does-not-start-another-reader")
        try require(await reader.active == 1, "cancel-does-not-report-actual-drain")
        await reader.finish(0)
        try require(try await first.value == 0, "actual-cancelled-reader-return-awaited")
        try require(await reader.cancelledAtReturn == [0], "actual-reader-observed-cancellation")
        var expected = [0]
        for id in [1, 3, 4, 5, 6, 7, 11, 12] {
            expected.append(id); let snapshot = expected
            try await until("fifo-\(id)") { await reader.entered == snapshot }
            try require(await reader.active == 1, "fifo-\(id)-single-actual-reader")
            await reader.finish(id)
            try require(try await waiters[id]!.value == id, "fifo-\(id)-actual-return")
        }
        try require(await gate.activity == .init(active: 0, pending: 0), "all-actual-work-drained")
        try require(await reader.maximum == 1, "actual-reader-overlap-never-exceeds-one")
        try require(await reader.active == 0, "reader-actual-drain-zero")

        let failed = submit(20, fail: true)
        try await until("throwing-reader") { await reader.entered.last == 20 }
        let afterFailure = submit(21)
        try await until("failure-successor") { await gate.activity.pending == 1 }
        await reader.finish(20)
        do { _ = try await failed.value; throw ControlFailure.failed("expected-error-missing") }
        catch ControlFailure.expected { checks.append("actual-error-propagates") }
        try await until("after-error") { await reader.entered.last == 21 }
        await reader.finish(21)
        try require(try await afterFailure.value == 21, "slot-released-after-actual-error")

        let barrier = StartBarrier()
        let preCancelled = Task {
            await barrier.wait()
            return try await gate.withAdmission { try await reader.read(30) }
        }
        try await until("pre-cancel-barrier") { await barrier.waiting }
        preCancelled.cancel(); await barrier.release()
        do { _ = try await preCancelled.value; throw ControlFailure.failed("pre-cancelled-started") }
        catch is CancellationError { checks.append("pre-cancelled-admission-refused") }
        try require(await reader.entered == expected + [20, 21], "cancelled-readers-never-entered")
        try require(await gate.activity == .init(active: 0, pending: 0), "final-gate-drain")
        try require(await reader.active == 0, "final-actual-reader-drain")
        let result: [String: Any] = ["passed": true, "checks": checks, "maximumActualReaders": await reader.maximum,
            "appLaunches": 0, "archiveBodyReads": 0, "networkRequests": 0]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
