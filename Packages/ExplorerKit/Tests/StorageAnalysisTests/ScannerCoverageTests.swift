import Foundation
import Testing
@testable import StorageAnalysis

struct ScannerCoverageTests {
    @Test func startupBoundaryAndQueueLimitRemainDistinctFromAccessDenial() {
        var coverage = AnalysisScanCoverage()
        for _ in 0..<25 { coverage.record(code: "boundary_excluded", error: 0) }
        coverage.record(code: "queue_limit", error: 13) // errno can be stale for non-syscall gaps.
        coverage.record(code: "directory_open", error: 13)
        coverage.record(code: "policy_excluded", error: 0)
        coverage.finish(reason: "boundary_excluded", errors: 28)
        #expect(coverage[.scopeBoundary] == 25)
        #expect(coverage[.directoryQueueLimit] == 1)
        #expect(coverage[.accessDenied] == 1)
        #expect(coverage[.policyExclusion] == 1)
        #expect(coverage.omittedDetails == 0)
        #expect(AnalysisScanCoverage.gap(code: "boundary_excluded", error: 0) == .boundaryExcluded)
        #expect(AnalysisScanCoverage.gap(code: "directory_open", error: 13) == .enumerationFailed(code: 13))
        #expect(AnalysisScanCoverage.gap(code: "queue_limit", error: 13) == .truncated)
    }

    @Test func noticesBeyondTheDetailLimitStayExplicitlyUnclassified() {
        var coverage = AnalysisScanCoverage()
        for _ in 0..<100 { coverage.record(code: "policy_excluded", error: 0) }
        coverage.finish(reason: "policy_excluded", errors: 4_500)
        #expect(coverage.reportedNotices == 100)
        #expect(coverage.workerNotices == 4_500)
        #expect(coverage.omittedDetails == 4_400)
        #expect(coverage[.scopeBoundary] == 0)
        #expect(coverage[.directoryQueueLimit] == 0)
        #expect(coverage[.policyExclusion] == 100)
    }

    @Test func completionMissingFieldsAndStoppedInputDoNotInventNoticeCounts() {
        var complete = AnalysisScanCoverage()
        #expect(complete.omittedDetails == nil)
        complete.finish(reason: "complete", errors: 0)
        #expect(!complete.hasExplanation)
        var missing = AnalysisScanCoverage()
        missing.finish(reason: "missing_fields", errors: 0)
        #expect(missing.terminalReason == .missingMetadata)
        #expect(missing.reportedNotices == 0)
        var stopped = AnalysisScanCoverage()
        stopped.finish(reason: "cancelled", errors: 0)
        #expect(stopped.terminalReason == nil)
    }

    @Test func changingCloudAndUnrecognizedFailureCodesKeepConservativeCoverage() {
        #expect(AnalysisScanCoverage.gap(code: "object_changed", error: 0) == .changing)
        #expect(AnalysisScanCoverage.reason(code: "materialization_denied", error: 11) == .materializationDeferred)
        #expect(AnalysisScanCoverage.reason(code: "bulk_error", error: 1) == .accessDenied)
        #expect(AnalysisScanCoverage.gap(code: "future_fixed_code", error: 0) == .unavailable)
    }
}
