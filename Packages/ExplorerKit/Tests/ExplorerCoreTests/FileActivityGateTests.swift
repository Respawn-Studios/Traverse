import Foundation
import Testing
@testable import ExplorerCore

struct FileActivityGateTests {
    @Test func multipleLeasesAndClosedAdmission() async throws {
        let gate = FileActivityGate(maximumActivities: 2)
        var first: FileActivityGate.Lease? = try gate.begin()
        var second: FileActivityGate.Lease? = try gate.begin()
        #expect(gate.activeCount == 2)
        #expect(throws: FileActivityError.capacity) { try gate.begin() }
        let token = try #require(gate.closeAdmission())
        #expect(throws: FileActivityError.admissionClosed) { try gate.begin() }
        #expect(gate.closeAdmission() == nil)
        // Losing UI/task references cannot force a worker's remaining lease out.
        let keeper = first
        first = nil; second = nil
        #expect(gate.activeCount == 1)
        withExtendedLifetime(keeper) {}
        _ = first; _ = second
        let reopened = gate.reopen(token)
        #expect(reopened)
        let wrongWait = await gate.waitUntilDrained(token)
        #expect(!wrongWait)
    }

    @Test func drainWaitsForActualWorkerAndRejectsOldOwner() async throws {
        let gate = FileActivityGate()
        var lease: FileActivityGate.Lease? = try gate.begin()
        let token = try #require(gate.closeAdmission())
        let waiter = Task { await gate.waitUntilDrained(token) }
        waiter.cancel() // Must not be interpreted as worker completion.
        #expect(gate.activeCount == 1)
        withExtendedLifetime(lease) {}
        lease = nil
        let drained = await waiter.value
        #expect(drained && gate.activeCount == 0)
        let reopened = gate.reopen(token)
        #expect(reopened)
        let next = try #require(gate.closeAdmission())
        let stale = gate.reopen(token)
        #expect(!stale && gate.isClosed)
        let final = gate.reopen(next)
        #expect(final)
    }

    @Test func concurrentWorkersStayConcurrent() async throws {
        let gate = FileActivityGate()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    let lease = try gate.begin()
                    defer { withExtendedLifetime(lease) {} }
                    await Task.yield()
                }
            }
            try await group.waitForAll()
        }
        #expect(gate.activeCount == 0)
        let token = try #require(gate.closeAdmission())
        let drained = await gate.waitUntilDrained(token)
        #expect(drained)
    }
}
