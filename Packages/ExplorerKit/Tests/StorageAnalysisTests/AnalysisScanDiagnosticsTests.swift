import Foundation
import Testing
@testable import StorageAnalysis

struct AnalysisScanDiagnosticsTests {
    private func frame(_ rows: [[String: Any]] = [], other: String = "0") -> [String: Any] {
        var value: [String: Any] = ["timings_enabled": false, "notice_buckets": rows, "other_notices": other]
        for stage in AnalysisScanDiagnostics.Stage.allCases { value[stage.rawValue] = "0" }
        return value
    }
    private func row(_ code: String = "directory_open", count: String = "400", source: Int = 1, error: Int = 13) -> [String: Any] {
        ["source": source, "code": code, "errno": error, "count": count]
    }
    @Test func terminalCountersReplaceSampledReasonsAndRetainDetailLimit() throws {
        let value = try AnalysisScanDiagnostics.decode(frame([row(), row("policy_excluded", count: "44", error: 0)]), errors: 444)
        var coverage = AnalysisScanCoverage()
        for _ in 0..<100 { coverage.record(code: "directory_open", error: 13) }
        try coverage.finish(reason: "directory_open", errors: 444, diagnostics: value)
        #expect(coverage[.accessDenied] == 400 && coverage[.policyExclusion] == 44)
        #expect(coverage.reasonCountsAreComplete && coverage.omittedDetails == 344 && coverage.reportedNotices == 100)
        coverage.record(code: "topology_changed", error: 0)
        #expect(coverage[.changed] == 1 && coverage.reasonCountsAreComplete)
    }
    @Test func boundedOverflowBucketRemainsExplicitlyUnclassified() throws {
        let value = try AnalysisScanDiagnostics.decode(frame([row(count: "4")], other: "9"), errors: 13)
        var coverage = AnalysisScanCoverage(); try coverage.finish(reason: "policy_excluded", errors: 13, diagnostics: value)
        #expect(coverage[.accessDenied] == 4 && !coverage.reasonCountsAreComplete && coverage.uncategorizedNotices == 9)
    }
    @Test func malformedCountsProvenanceAndDuplicateBucketsRefuse() {
        let good = row()
        for value in [frame([good, good]), frame([row(source: 3)]), frame([row(error: -2)]), frame([row(count: "0400")]),
                      frame([row(count: "0")]), frame([row("/personal/name")]), frame([row(count: String(UInt64.max))], other: "1"),
                      frame(Array(repeating: good, count: 65))] {
            #expect(throws: StorageScanFailure.self) { try AnalysisScanDiagnostics.decode(value, errors: 400) }
        }
        #expect(throws: StorageScanFailure.self) { try AnalysisScanDiagnostics.decode(frame([good]), errors: 401) }
        var unknown = frame(); unknown["path"] = "/not-allowed"
        #expect(throws: StorageScanFailure.self) { try AnalysisScanDiagnostics.decode(unknown, errors: 0) }
        var booleanSource = good; booleanSource["source"] = true
        #expect(throws: StorageScanFailure.self) { try AnalysisScanDiagnostics.decode(frame([booleanSource]), errors: 400) }
    }
    @Test func terminalCountsCannotContradictObservedIssues() throws {
        let value = try AnalysisScanDiagnostics.decode(frame([row("policy_excluded", count: "400", error: 0)]), errors: 400)
        var coverage = AnalysisScanCoverage(); coverage.record(code: "directory_open", error: 13)
        #expect(throws: StorageScanFailure.self) { try coverage.finish(reason: "policy_excluded", errors: 400, diagnostics: value) }
    }
    @Test func inclusiveTimingFieldsAreBoundAndNeverAddedTogether() throws {
        var measured = frame(); measured["timings_enabled"] = true; measured["commit_ns"] = "100"; measured["sqlite_commit_ns"] = "90"
        let value = try AnalysisScanDiagnostics.decode(measured, errors: 0)
        #expect(value.timingsEnabled && value[.commit] == 100 && value[.sqliteCommit] == 90)
        measured["timings_enabled"] = 1
        #expect(throws: StorageScanFailure.self) { try AnalysisScanDiagnostics.decode(measured, errors: 0) }
        measured["timings_enabled"] = false
        #expect(throws: StorageScanFailure.self) { try AnalysisScanDiagnostics.decode(measured, errors: 0) }
    }
}
