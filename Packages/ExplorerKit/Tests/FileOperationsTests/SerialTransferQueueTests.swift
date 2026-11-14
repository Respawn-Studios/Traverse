import Foundation
import FileOperations
import Testing

struct SerialTransferQueueTests {
    @Test func admissionOrderSurvivesSlowPreparationAndOnlyOneJobStarts() {
        var queue = SerialTransferQueue(maximumOutstandingJobs: 2)
        let first = UUID(), second = UUID(), overflow = UUID()
        #expect(queue.reserve(first) == true)
        #expect(queue.reserve(second) == true)
        #expect(queue.reserve(overflow) == false)
        #expect(!queue.snapshot.canReserve)
        #expect(queue.snapshot.outstandingCount == 2)
        #expect(queue.markReady(second) == true)
        #expect(queue.startNext() == nil)
        #expect(queue.markReady(first) == true)
        #expect(queue.startNext() == first)
        #expect(queue.snapshot.active?.id == first)
        #expect(queue.startNext() == nil)
        #expect(!queue.snapshot.canReserve)
        #expect(queue.finish(first, disposition: .succeeded) == true)
        #expect(queue.snapshot.canReserve)
        #expect(queue.startNext() == second)
        #expect(queue.finish(second, disposition: .succeeded) == true)
        #expect(queue.snapshot.outstandingCount == 0)
        #expect(queue.snapshot.waiting.isEmpty)
        #expect(queue.snapshot.active == nil)
    }

    @Test func cancellationRemovesOnlyWaitingIntentAndRejectsLatePreparation() {
        var queue = SerialTransferQueue()
        let first = UUID(), middle = UUID(), last = UUID()
        #expect(queue.reserve(first) == true)
        #expect(queue.reserve(middle) == true)
        #expect(queue.reserve(last) == true)
        #expect(queue.snapshot.waiting.map(\.phase) == [.preparing, .preparing, .preparing])
        #expect(queue.markReady(last) == true)
        #expect(queue.cancelWaiting(middle) == true)
        #expect(queue.snapshot.waiting.map(\.id) == [first, last])
        #expect(queue.markReady(middle) == false)
        #expect(queue.cancelWaiting(middle) == false)
        #expect(queue.startNext() == nil)
        #expect(queue.cancelWaiting(first) == true)
        #expect(queue.markReady(first) == false)
        #expect(queue.startNext() == last)
        #expect(queue.cancelWaiting(last) == false)
        #expect(queue.snapshot.active?.id == last)
        #expect(!queue.snapshot.isPaused)
    }

    @Test func staleIDsAndDuplicateAdmissionsCannotChangeCurrentWork() {
        var queue = SerialTransferQueue()
        let active = UUID(), waiting = UUID(), stale = UUID()
        #expect(queue.reserve(active) == true)
        #expect(queue.reserve(active) == false)
        #expect(queue.markReady(active) == true)
        #expect(queue.startNext() == active)
        #expect(queue.reserve(waiting) == true)
        let before = queue.snapshot
        #expect(queue.reserve(active) == false)
        #expect(queue.reserve(waiting) == false)
        #expect(queue.markReady(active) == false)
        #expect(queue.markReady(stale) == false)
        #expect(queue.cancelWaiting(active) == false)
        #expect(queue.requestStop(stale) == false)
        #expect(queue.finish(stale, disposition: .needsReview) == false)
        #expect(queue.snapshot == before)
    }

    @Test func stopPausesBeforeDrainAndCleanSafeStepDoesNotAdvance() {
        var queue = SerialTransferQueue()
        let active = UUID(), next = UUID()
        #expect(queue.reserve(active) == true)
        #expect(queue.markReady(active) == true)
        #expect(queue.startNext() == active)
        #expect(queue.reserve(next) == true)
        #expect(queue.markReady(next) == true)
        #expect(queue.requestStop(active) == true)
        #expect(queue.snapshot.isPaused)
        #expect(queue.snapshot.active?.stopRequested == true)
        #expect(queue.resume() == false)
        #expect(queue.startNext() == nil)
        #expect(queue.snapshot.outstandingCount == 2)
        #expect(queue.finish(active, disposition: .succeeded) == true)
        #expect(queue.snapshot.isPaused)
        #expect(queue.snapshot.active == nil)
        #expect(queue.startNext() == nil)
        #expect(queue.resume() == true)
        #expect(queue.startNext() == next)
        #expect(queue.snapshot.active?.stopRequested == false)
        // A terminal update from the prior job cannot stop or release this one.
        let before = queue.snapshot
        #expect(queue.requestStop(active) == false)
        #expect(queue.finish(active, disposition: .cancelled) == false)
        #expect(queue.snapshot == before)
    }

    @Test(arguments: [SerialTransferQueue.Disposition.cancelled, .needsReview])
    func unresolvedCompletionRequiresExplicitResume(disposition: SerialTransferQueue.Disposition) {
        var queue = SerialTransferQueue()
        let active = UUID(), next = UUID(), later = UUID()
        #expect(queue.reserve(active) == true)
        #expect(queue.markReady(active) == true)
        #expect(queue.startNext() == active)
        #expect(queue.reserve(next) == true)
        #expect(queue.markReady(next) == true)
        #expect(queue.finish(active, disposition: disposition) == true)
        #expect(queue.snapshot.isPaused)
        #expect(queue.startNext() == nil)
        #expect(queue.reserve(later) == true)
        #expect(queue.markReady(later) == true)
        #expect(queue.startNext() == nil)
        #expect(queue.snapshot.waiting.map(\.id) == [next, later])
        #expect(queue.resume() == true)
        #expect(queue.startNext() == next)
    }

    @Test func manualPauseDoesNotCancelActiveWorkOrDisappearOnSuccess() {
        var queue = SerialTransferQueue()
        let first = UUID(), second = UUID()
        queue.pause()
        #expect(queue.reserve(first) == true)
        #expect(queue.markReady(first) == true)
        #expect(queue.startNext() == nil)
        #expect(queue.resume() == true)
        #expect(queue.startNext() == first)
        queue.pause()
        #expect(queue.snapshot.active?.id == first)
        #expect(queue.snapshot.active?.stopRequested == false)
        #expect(queue.reserve(second) == true)
        #expect(queue.markReady(second) == true)
        #expect(queue.finish(first, disposition: .succeeded) == true)
        #expect(queue.startNext() == nil)
        #expect(queue.resume() == true)
        #expect(queue.startNext() == second)
    }

    @Test func defaultBoundIncludesActiveAndPreparingJobs() {
        var queue = SerialTransferQueue()
        let ids = (0..<16).map { _ in UUID() }
        for id in ids { #expect(queue.reserve(id) == true) }
        #expect(queue.maximumOutstandingJobs == 16)
        #expect(queue.snapshot.outstandingCount == 16)
        #expect(queue.reserve(UUID()) == false)
        #expect(queue.markReady(ids[0]) == true)
        #expect(queue.startNext() == ids[0])
        #expect(queue.snapshot.outstandingCount == 16)
        #expect(queue.reserve(UUID()) == false)
        #expect(queue.cancelWaiting(ids[1]) == true)
        #expect(queue.snapshot.outstandingCount == 15)
        #expect(queue.reserve(UUID()) == true)
        #expect(queue.snapshot.outstandingCount == 16)
    }

    @Test func completedJobsLeaveOnlyBoundedOutstandingState() {
        var queue = SerialTransferQueue(maximumOutstandingJobs: 1)
        for _ in 0..<1000 {
            let id = UUID()
            #expect(queue.reserve(id) == true)
            #expect(queue.markReady(id) == true)
            #expect(queue.startNext() == id)
            #expect(queue.finish(id, disposition: .succeeded) == true)
            #expect(queue.snapshot.outstandingCount == 0)
            #expect(queue.snapshot.waiting.isEmpty)
            #expect(queue.snapshot.active == nil)
            #expect(queue.snapshot.canReserve)
        }
    }

    @Test func explicitPriorityMovesOnlyWaitingIntentAndKeepsItsPreparation() {
        var queue = SerialTransferQueue()
        let active = UUID(), first = UUID(), second = UUID(), third = UUID()
        #expect(queue.reserve(active) == true); #expect(queue.markReady(active) == true); #expect(queue.startNext() == active)
        for id in [first, second, third] { #expect(queue.reserve(id) == true) }
        #expect(queue.markReady(second) == true); queue.pause()
        let before = queue.snapshot
        #expect(queue.moveWaiting(second, offset: -1, expectedOrder: [first, second, third]) == true)
        #expect(queue.snapshot.waiting.map(\.id) == [second, first, third])
        #expect(queue.snapshot.waiting.map(\.phase) == [.ready, .preparing, .preparing])
        #expect(queue.snapshot.active == before.active && queue.snapshot.isPaused)
        #expect(queue.snapshot.outstandingCount == before.outstandingCount)
        #expect(queue.finish(active, disposition: .succeeded) == true)
        #expect(queue.startNext() == nil)
        #expect(queue.resume() == true); #expect(queue.startNext() == second)
        #expect(queue.snapshot.waiting.map(\.id) == [first, third])
    }

    @Test func stalePriorityOrInvalidOffsetsNeverMoveAnotherJob() {
        var queue = SerialTransferQueue()
        let first = UUID(), second = UUID(), later = UUID()
        #expect(queue.reserve(first) == true); #expect(queue.reserve(second) == true)
        let order = [first, second], before = queue.snapshot
        #expect(queue.moveWaiting(UUID(), offset: -1, expectedOrder: order) == false)
        for offset in [Int.min, -2, 0, 2, Int.max] {
            #expect(queue.moveWaiting(first, offset: offset, expectedOrder: order) == false)
        }
        #expect(queue.moveWaiting(first, offset: -1, expectedOrder: order) == false)
        #expect(queue.moveWaiting(second, offset: 1, expectedOrder: order) == false)
        #expect(queue.moveWaiting(second, offset: -1, expectedOrder: [second, first]) == false)
        #expect(queue.moveWaiting(second, offset: -1, expectedOrder: [first]) == false)
        #expect(queue.snapshot == before)
        #expect(queue.reserve(later) == true); let afterArrival = queue.snapshot
        #expect(queue.moveWaiting(second, offset: -1, expectedOrder: order) == false)
        #expect(queue.snapshot == afterArrival)
        #expect(queue.cancelWaiting(first) == true); #expect(queue.markReady(second) == true); #expect(queue.startNext() == second)
        let afterStart = queue.snapshot
        #expect(queue.moveWaiting(second, offset: 1, expectedOrder: [later]) == false)
        #expect(queue.snapshot == afterStart)
    }
}
