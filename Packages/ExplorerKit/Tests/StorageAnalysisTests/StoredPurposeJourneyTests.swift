import Foundation
import XCTest
@testable import StorageAnalysis

final class StoredPurposeJourneyTests: XCTestCase {
    private func value(_ numbers: [UInt64], files: UInt64 = 1, directories: UInt64 = 0, links: UInt64 = 0) -> Data {
        var data = Data(repeating: 0, count: 140)
        func put(_ number: UInt64, _ offset: Int) { for i in 0..<8 { data[offset + i] = UInt8(truncatingIfNeeded: number >> ((7 - i) * 8)) } }
        put(files, 0); put(directories, 8); put(links, 16)
        for i in 0..<4 { put(numbers[i], 40 + i * 25) }
        return data
    }
    private func frame(locations: Bool = false, metric: Int = 0, rows: [[String: Any]]? = nil, total: Data? = nil) -> [String: Any] {
        var result: [String: Any] = ["kind": locations ? "purpose-locations" : "purpose-projects", "revision": 1,
            "basis": "project-namespace-v1", "classification_revision": 4, "role": 3, "metric": metric,
            "value": (total ?? value([30, 40, 13, 70], files: 2)).base64EncodedString(), "remainder": value([0, 0, 0, 0], files: 0).base64EncodedString(), "total_groups": "2",
            "rows": rows ?? [row(9, [20, 10, 8, 30], locations: locations), row(7, [10, 30, 5, 40], locations: locations)]]
        if locations { result["project"] = "5" }
        return result
    }
    private func row(_ id: UInt64, _ numbers: [UInt64], locations: Bool = false) -> [String: Any] {
        var row: [String: Any] = ["key": String(id), "name": Data("Item-\(id)".utf8).base64EncodedString(), "value": value(numbers).base64EncodedString()]
        if locations { row["whole_value"] = value(numbers, directories: 2).base64EncodedString(); row["whole_recorded_match"] = true
            row["display_source"] = 0; row["display_path"] = [Data("Item-\(id)".utf8).base64EncodedString()]; row["display_truncated"] = false }
        return row
    }
    private func projects(_ frame: [String: Any], metric: AnalysisByteMetric = .dataLogical) throws -> StoredPurposeProjects {
        try .decode([frame], role: .toolCache, metric: metric)
    }
    private func locations(_ frame: [String: Any]) throws -> StoredPurposeLocations {
        try .decode([frame], role: .toolCache, project: 5, metric: .dataLogical)
    }
    func testAllFourMetricsKeepTheirExactPartitionAndRanking() throws {
        for metric in AnalysisByteMetric.allCases {
            let a = row(7, [10, 30, 5, 40]), b = row(9, [20, 10, 8, 30])
            let rows = [1, 3].contains(metric.rawValue) ? [a, b] : [b, a]
            let result = try projects(frame(metric: metric.rawValue, rows: rows), metric: metric)
            XCTAssertEqual(result.value.counts.regularFiles, 2)
            XCTAssertEqual(result.projects.map(\.id), [1, 3].contains(metric.rawValue) ? [7, 9] : [9, 7])
        }
    }
    func testProjectSlicesCarryOnlyExactSemanticTargetsAndRemainderHasNone() throws {
        var f = frame(); f["remainder"] = value([1, 1, 1, 1]).base64EncodedString(); f["value"] = value([31, 41, 14, 71], files: 3).base64EncodedString(); f["total_groups"] = "3"
        let result = try projects(f), slices = result.slices(scopeName: "Generated")
        XCTAssertEqual(slices[0].purposeTarget, .locations(role: .toolCache, project: 9))
        XCTAssertTrue(slices.allSatisfy { $0.storedTarget == nil && $0.folder == nil })
        XCTAssertNil(slices.last?.purposeTarget)
    }
    func testSharedAndSourceRootNamesRemainDifferentAndLiteral() throws {
        var shared = row(0, [20, 10, 8, 30]); shared["name"] = ""
        var root = row(1, [10, 30, 5, 40]); root["name"] = ""
        let slices = try projects(frame(rows: [shared, root])).slices(scopeName: "Chosen folder")
        XCTAssertEqual(slices.map(\.title), ["Shared or outside projects", "Chosen folder"])
        XCTAssertEqual(slices[0].purposeTarget, .locations(role: .toolCache, project: 0))
        var invalid = root; invalid["key"] = "2"
        XCTAssertThrowsError(try projects(frame(rows: [shared, invalid])))
    }
    func testMixedLocationsRetainBothWholeAndMatchingValuesWithoutDeleteAuthority() throws {
        var mixed = row(9, [20, 10, 8, 30], locations: true)
        mixed["whole_value"] = value([120, 110, 108, 130], files: 2, directories: 3).base64EncodedString(); mixed["whole_recorded_match"] = false
        let result = try locations(frame(locations: true, rows: [mixed, row(7, [10, 30, 5, 40], locations: true)]))
        XCTAssertFalse(result.locations[0].matchesWholeRecordedLocation)
        XCTAssertEqual(result.locations[0].wholeRecordedValue.counts.regularFiles, 2)
        XCTAssertEqual(result.locations[0].matchingValue.counts.regularFiles, 1)
        XCTAssertTrue(result.locations[1].matchesWholeRecordedLocation)
        mixed["whole_recorded_match"] = true
        XCTAssertThrowsError(try locations(frame(locations: true, rows: [mixed, row(7, [10, 30, 5, 40], locations: true)])))
    }
    func testNonregularEntriesKeepAnOtherwiseEqualLocationMixed() throws {
        var a = row(9, [20, 10, 8, 30], locations: true)
        a["whole_value"] = value([20, 10, 8, 30], links: 1).base64EncodedString(); a["whole_recorded_match"] = false
        XCTAssertFalse(try locations(frame(locations: true, rows: [a, row(7, [10, 30, 5, 40], locations: true)])).locations[0].matchesWholeRecordedLocation)
        a["whole_recorded_match"] = true
        XCTAssertThrowsError(try locations(frame(locations: true, rows: [a, row(7, [10, 30, 5, 40], locations: true)])))
    }
    func testTypedRevisionsRoleMetricAndProjectCannotBeSubstituted() {
        for (key, bad) in [("revision", 2 as Any), ("revision", true), ("classification_revision", 3), ("role", 4), ("metric", 3), ("basis", "attributed-project-v1"), ("extra", "unknown")] {
            var f = frame(); f[key] = bad; XCTAssertThrowsError(try projects(f), key)
        }
        var f = frame(locations: true); f["project"] = "6"; XCTAssertThrowsError(try locations(f))
        f["project"] = 5; XCTAssertThrowsError(try locations(f))
        XCTAssertThrowsError(try StoredPurposeProjects.decode([frame(), frame()], role: .toolCache, metric: .dataLogical))
    }
    func testCanonicalIDsNamesDuplicatesAndOrderingAreRequired() {
        for key in ["09", "-1", String(UInt64.max)] {
            var a = row(9, [20, 10, 8, 30]); a["key"] = key
            XCTAssertThrowsError(try projects(frame(rows: [a, row(7, [10, 30, 5, 40])])), key)
        }
        XCTAssertThrowsError(try projects(frame(rows: [row(7, [10, 30, 5, 40]), row(9, [20, 10, 8, 30])])))
        var a = row(9, [20, 10, 8, 30]); a["key"] = "7"
        XCTAssertThrowsError(try projects(frame(rows: [a, row(7, [10, 30, 5, 40])])))
        for name in [Data([0]), Data("..".utf8), Data("a/b".utf8), Data(repeating: 65, count: 256)] {
            var a = row(9, [20, 10, 8, 30]); a["name"] = name.base64EncodedString(); XCTAssertThrowsError(try projects(frame(rows: [a, row(7, [10, 30, 5, 40])])))
        }
    }
    func testCountsAllMetricsRemainderAndWholeBooleanMustBeExact() {
        var f = frame(); f["value"] = value([31, 40, 13, 70], files: 2).base64EncodedString(); XCTAssertThrowsError(try projects(f))
        f = frame(); f["value"] = value([30, 40, 13, 70], files: 3).base64EncodedString(); XCTAssertThrowsError(try projects(f))
        f = frame(); f["total_groups"] = "3"; XCTAssertThrowsError(try projects(f))
        f = frame(); f["remainder"] = value([1, 1, 1, 1]).base64EncodedString(); XCTAssertThrowsError(try projects(f))
        var a = row(9, [20, 10, 8, 30], locations: true); a["whole_recorded_match"] = 1
        XCTAssertThrowsError(try locations(frame(locations: true, rows: [a, row(7, [10, 30, 5, 40], locations: true)])))
    }
    func testZeroAndUnknownMetricsStillRepresentObservedFiles() throws {
        var unknown = value([0, 0, 0, 0]); unknown[55] = 1 // metric0 not returned
        let a: [String: Any] = ["key": "7", "name": Data("Cache".utf8).base64EncodedString(), "value": unknown.base64EncodedString()]
        var f = frame(rows: [a], total: unknown); f["total_groups"] = "1"
        let result = try projects(f); XCTAssertEqual(result.projects.count, 1); XCTAssertEqual(result.value.bytes.dataLogical.notReturnedCount, 1)
    }
    private func header() -> [String: Any] {
        ["schema": 17, "policy_revision": "local-metadata-v1", "classification_revision": 4, "profile": "full-result-data-v4",
         "checkpoint_revision": 1, "checkpoint_rows": 16384, "progress_revision": "committed-totals-data-v4", "traversal_revision": "bounded-depth-v1", "maximum_depth": 128]
    }
    func testPurposeCapabilityIsExplicitOptionalAndV4Only() throws {
        var h = header()
        XCTAssertNil(try AnalysisPolicyBinding(header: h, startup: false, policy: .standard, classificationRevision: .v4).purposeJourneyRevision)
        h["purpose_journey_revision"] = 1
        XCTAssertEqual(try AnalysisPolicyBinding(header: h, startup: false, policy: .standard, classificationRevision: .v4).purposeJourneyRevision, 1)
        h["purpose_journey_revision"] = true
        XCTAssertThrowsError(try AnalysisPolicyBinding(header: h, startup: false, policy: .standard, classificationRevision: .v4))
        h["purpose_journey_revision"] = 2
        XCTAssertThrowsError(try AnalysisPolicyBinding(header: h, startup: false, policy: .standard, classificationRevision: .v4))
        h["purpose_journey_revision"] = 1
        XCTAssertThrowsError(try AnalysisPolicyBinding(header: h, startup: false, policy: .standard, classificationRevision: .v3))
    }
    func testDisplayTailIsBoundedLiteralAndCannotMasqueradeAsAWholePath() throws {
        var a = row(9, [20, 10, 8, 30], locations: true)
        a["display_path"] = ["Part-1", "Part-2", "Part-3", "Part-4", "Part-5", "Item-9"].map { Data($0.utf8).base64EncodedString() }; a["display_truncated"] = true
        let result = try locations(frame(locations: true, rows: [a, row(7, [10, 30, 5, 40], locations: true)]))
        XCTAssertEqual(result.locations[0].recordedPath(scopeName: "Generated"), "Generated / … / Part-1 / Part-2 / Part-3 / Part-4 / Part-5 / Item-9")
        a["display_path"] = [Data("wrong leaf".utf8).base64EncodedString()]
        XCTAssertThrowsError(try locations(frame(locations: true, rows: [a, row(7, [10, 30, 5, 40], locations: true)])))
        a = row(9, [20, 10, 8, 30], locations: true); a["display_source"] = 1
        XCTAssertThrowsError(try locations(frame(locations: true, rows: [a, row(7, [10, 30, 5, 40], locations: true)])))
    }
    func testSourceRootIsProtectedEvenWhenAllRecordedFilesMatch() throws {
        var a = row(0, [20, 10, 8, 30], locations: true); a["name"] = ""; a["display_path"] = [String]()
        let result = try locations(frame(locations: true, rows: [a, row(7, [10, 30, 5, 40], locations: true)]))
        XCTAssertTrue(result.locations[0].isSourceRoot); XCTAssertTrue(result.locations[0].matchesWholeRecordedLocation)
        XCTAssertEqual(result.locations[0].recordedPath(scopeName: "Chosen folder"), "Chosen folder")
    }
}
