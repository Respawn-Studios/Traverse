import Foundation
import Testing
@testable import ExplorerCore

struct DeferredEjectTests {
    @Test func knownCohortDrainsAndDoesNotGrow() {
        let first = UUID(), second = UUID(), unrelated = UUID()
        var intent = DeferredEject(cohort: [first, second], policy: .requireCancel)
        intent.update(outstanding: [second, unrelated], needsAttention: false)
        #expect(intent.remaining == [second])
        let result1 = intent.admitNewWork(affected: true)
        #expect(!result1)
        let result2 = intent.admitNewWork(affected: false)
        #expect(result2)
        let result3 = intent.submit(afterVerifiedDrain: true)
        #expect(!result3)
        intent.update(outstanding: [unrelated], needsAttention: false)
        #expect(intent.phase == .draining)
        let result4 = intent.submit(afterVerifiedDrain: false)
        #expect(!result4)
        let result5 = intent.submit(afterVerifiedDrain: true)
        #expect(result5)
        let result6 = intent.cancel()
        #expect(!result6)
        let result7 = intent.complete(request: UUID())
        #expect(!result7)
        let result8 = intent.complete(request: intent.id)
        #expect(result8)
        let result9 = intent.complete(request: intent.id)
        #expect(!result9)
    }

    @Test func problemCannotDisappearWithoutExplicitReview() {
        let job = UUID()
        var intent = DeferredEject(cohort: [job], policy: .requireCancel)
        intent.update(outstanding: [job], needsAttention: true)
        intent.update(outstanding: [], needsAttention: false)
        #expect(intent.phase == .needsAttention)
        let result10 = intent.submit(afterVerifiedDrain: true)
        #expect(!result10)
        let result11 = intent.resumeAfterReview()
        #expect(result11)
        #expect(intent.phase == .draining)
    }

    @Test func alternatePreferenceCancelsOnlyBeforeSubmission() {
        var intent = DeferredEject(cohort: [UUID()], policy: .cancelEject)
        let result12 = intent.admitNewWork(affected: true)
        #expect(result12)
        #expect(intent.phase == .cancelled)
        let result13 = intent.submit(afterVerifiedDrain: true)
        #expect(!result13)
        var submitted = DeferredEject(cohort: [], policy: .cancelEject)
        let result14 = submitted.submit(afterVerifiedDrain: true)
        #expect(result14)
        let result15 = submitted.admitNewWork(affected: true)
        #expect(!result15)
        let result16 = submitted.cancel()
        #expect(!result16)
    }

    @Test func cancellationPreservesCapturedJobs() {
        let job = UUID()
        var intent = DeferredEject(cohort: [job], policy: .requireCancel)
        let result17 = intent.cancel()
        #expect(result17)
        #expect(intent.remaining == [job])
        intent.update(outstanding: [], needsAttention: true)
        #expect(intent.phase == .cancelled)
    }
}
