import Foundation
import XCTest
@testable import StorageAnalysis

final class ChartOverviewContractTests: XCTestCase {
    private func encoded(_ files: UInt64 = 2, missing: UInt64 = 0, failed: UInt64 = 0, overflow: Bool = false) -> Data {
        var value = Data(repeating: 0, count: 140)
        func put(_ number: UInt64, at offset: Int) {
            for i in 0..<8 { value[offset + i] = UInt8(truncatingIfNeeded: number >> (56 - i * 8)) }
        }
        put(files, at: 0)
        for i in 0..<4 {
            put(overflow ? 0 : (files - missing - failed) * 7, at: 40 + i * 25)
            put(missing, at: 48 + i * 25); put(failed, at: 56 + i * 25)
            value[64 + i * 25] = overflow ? 1 : 0
        }
        return value
    }
    private func header(_ startup: Bool = false) -> [String: Any] {
        ["schema":startup ? 18 : 17, "policy_revision":AnalysisMetadataPolicy.standard.rawValue,
         "checkpoint_revision":1, "checkpoint_rows":16384, "progress_revision":"committed-totals-data-v4",
         "traversal_revision":"bounded-depth-v1", "maximum_depth":128, "classification_revision":4,
         "profile":startup ? "startup-result-data-v4" : "full-result-data-v4"]
    }
    private func group(_ value: Data? = nil, key: String = "0", name: Data = Data()) -> [String: Any] {
        ["kind":"groups", "groups":[["key":key,"name":name.base64EncodedString(),"value":(value ?? encoded()).base64EncodedString()]],
         "remainder":encoded(0).base64EncodedString(),"total_groups":"1","project_count":"1"]
    }
    private func frame(projected: Bool = true, value: Data? = nil) -> [String: Any] {
        ["kind":"chart-overview","revision":1,"classification_revision":4,"projected":projected,
         "file_types":group(value),"storage_roles":projected ? group(value) as Any : NSNull(),
         "projects":projected ? group(value, key: "2", name: Data("Project".utf8)) as Any : NSNull()]
    }
    private func decode(_ input: [String: Any], projected: Bool = true, complete: Bool = true, value: Data? = nil) throws -> StoredChartOverview {
        try .decode([input], summary: .init(value: .init(encoded: value ?? encoded()), complete: complete, classificationReady: projected), classificationRevision: .v4)
    }
    func testCapabilityIsOptionalAndBothCurrentHeadersAcceptIt() throws {
        XCTAssertNil(AnalysisPolicyBinding.standard.chartOverviewRevision)
        for paired in [false,true] {
            var raw = header(paired)
            XCTAssertNil(try AnalysisPolicyBinding(header: raw, startup: paired, policy: .standard, classificationRevision: .v4).chartOverviewRevision)
            raw["chart_overview_revision"] = 1
            XCTAssertEqual(try AnalysisPolicyBinding(header: raw, startup: paired, policy: .standard, classificationRevision: .v4).chartOverviewRevision, 1)
        }
    }
    func testCapabilityRejectsBooleanFutureAndOlderClassification() {
        for invalid: Any in [true, false, 0, 2, "1", NSNull(), 1.5] {
            var raw = header(); raw["chart_overview_revision"] = invalid
            XCTAssertThrowsError(try AnalysisPolicyBinding(header: raw, startup: false, policy: .standard, classificationRevision: .v4))
        }
        var raw = header(); raw["chart_overview_revision"] = 1; raw["schema"] = 15
        raw["classification_revision"] = 3; raw["profile"] = "full-result-adaptive-v1"; raw["progress_revision"] = "committed-totals-adaptive-v1"
        XCTAssertThrowsError(try AnalysisPolicyBinding(header: raw, startup: false, policy: .standard, classificationRevision: .v3))
    }
    func testCompleteAndIncompleteProjectionPreserveAllFacetsAndDrillTargets() throws {
        for complete in [true,false] {
            let result = try decode(frame(), complete: complete)
            XCTAssertEqual(result.fileTypes.groups[0].value.counts.regularFiles, 2)
            XCTAssertEqual(result.projects?.groups[0].rawName, Data("Project".utf8))
            XCTAssertEqual(result.storageRoles?.groups.count, 1)
            XCTAssertNotNil(result.projects?.attributionSlices(scopeName: "Scope").first?.storedTarget)
        }
    }
    func testUnprojectedIsTypesOnlyAndRequiresExplicitNulls() throws {
        let result = try decode(frame(projected: false), projected: false, complete: false)
        XCTAssertNil(result.storageRoles); XCTAssertNil(result.projects)
        for key in ["storage_roles","projects"] {
            var bad = frame(projected: false); bad[key] = group()
            XCTAssertThrowsError(try decode(bad, projected: false))
            bad.removeValue(forKey: key); XCTAssertThrowsError(try decode(bad, projected: false))
        }
    }
    func testProjectionMustBeStrictBooleanAndAgreeWithSummary() {
        for invalid: Any in [0,1,"true",NSNull()] {
            var bad = frame(); bad["projected"] = invalid; XCTAssertThrowsError(try decode(bad))
        }
        XCTAssertThrowsError(try decode(frame(), projected: false))
        XCTAssertThrowsError(try decode(frame(projected: false)))
    }
    func testVersionAndForeignFieldsAreRefusedAtEveryLevel() {
        for key in ["revision","classification_revision"] {
            for invalid: Any in [true,0,9,"1"] {
                var bad = frame(); bad[key] = invalid; XCTAssertThrowsError(try decode(bad))
            }
        }
        var bad = frame(); bad["extra"] = 1; XCTAssertThrowsError(try decode(bad))
        var nested = group(); nested["extra"] = 1; bad = frame(); bad["file_types"] = nested; XCTAssertThrowsError(try decode(bad))
        var rows = nested["groups"] as! [[String: Any]]; rows[0]["extra"] = 1
        nested = group(); nested["groups"] = rows; bad["file_types"] = nested; XCTAssertThrowsError(try decode(bad))
    }
    func testDuplicateAndOutOfRangeTypeRoleKeysAreRefused() {
        for key in ["17","18446744073709551615"] {
            var bad = frame(); bad["file_types"] = group(key: key); XCTAssertThrowsError(try decode(bad))
        }
        var nested = group(); let rows = nested["groups"] as! [[String: Any]]
        nested["groups"] = rows + rows; nested["total_groups"] = "2"
        var bad = frame(); bad["file_types"] = nested; XCTAssertThrowsError(try decode(bad))
        bad = frame(); bad["storage_roles"] = group(key: "999"); XCTAssertThrowsError(try decode(bad))
    }
    func testEachFacetMustReconcileFilesAndEveryMetric() {
        for key in ["file_types","storage_roles","projects"] {
            var bad = frame(); bad[key] = group(encoded(1)); XCTAssertThrowsError(try decode(bad))
            var bytes = encoded(); bytes[47] = 15
            bad[key] = group(bytes); XCTAssertThrowsError(try decode(bad))
        }
    }
    func testUnavailableAndOverflowMeasurementsArePreserved() throws {
        for value in [encoded(missing: 1), encoded(failed: 1), encoded(overflow: true)] {
            let result = try decode(frame(value: value), value: value)
            XCTAssertEqual(result.fileTypes.groups[0].value, try .init(encoded: value))
        }
    }
    func testRemainderGroupCountAndCrossFacetProjectCountCannotDisagree() {
        for count in ["0","2","13","18446744073709551615"] {
            var nested = group(); nested["total_groups"] = count
            var bad = frame(); bad["file_types"] = nested; XCTAssertThrowsError(try decode(bad))
        }
        var nested = group(); nested["remainder"] = encoded(1).base64EncodedString()
        var bad = frame(); bad["file_types"] = nested; XCTAssertThrowsError(try decode(bad))
        nested = group(); nested["project_count"] = "2"; bad = frame(); bad["storage_roles"] = nested
        XCTAssertThrowsError(try decode(bad))
    }
    func testInvalidNamesAndTruncatedValuesAreRefused() {
        for name in [Data([0]),Data("A/B".utf8),Data(repeating: 65,count: 256)] {
            var bad = frame(); bad["projects"] = group(name: name); XCTAssertThrowsError(try decode(bad))
        }
        var bad = frame(); bad["file_types"] = group(Data(repeating: 0,count: 139)); XCTAssertThrowsError(try decode(bad))
    }
    func testWholeFrameMustBeSingularAndCurrent() throws {
        let summary = StoredAnalysisSummary(value: try .init(encoded: encoded()), complete: true, classificationReady: true)
        for frames: [[String: Any]] in [[],[frame(),frame()]] {
            XCTAssertThrowsError(try StoredChartOverview.decode(frames, summary: summary, classificationRevision: .v4))
        }
        XCTAssertThrowsError(try StoredChartOverview.decode([frame()], summary: summary, classificationRevision: .v3))
    }
}
