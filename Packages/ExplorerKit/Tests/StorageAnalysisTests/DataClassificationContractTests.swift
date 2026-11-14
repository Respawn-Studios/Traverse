import Foundation
import XCTest
@testable import StorageAnalysis

final class DataClassificationContractTests: XCTestCase {
    private let suffixes = ["csv","tsv","parquet","arrow","arrows","feather","orc","avro","npy","npz","h5","hdf5","fits","netcdf","rds","rdata"]
    private func value(_ files: UInt64) -> String {
        var bytes = Data(repeating: 0, count: 140)
        func put(_ n: UInt64, _ offset: Int) { for i in 0..<8 { bytes[offset + i] = UInt8(truncatingIfNeeded: n >> (56 - i * 8)) } }
        put(files, 0); for metric in 0..<4 { put(files * 10, 40 + metric * 25) }
        return bytes.base64EncodedString()
    }
    private func header(startup: Bool = false) -> [String: Any] {
        ["schema": startup ? 18 : 17, "policy_revision": AnalysisMetadataPolicy.standard.rawValue,
         "checkpoint_revision": 1, "checkpoint_rows": 16384, "progress_revision": "committed-totals-data-v4",
         "traversal_revision": "bounded-depth-v1", "maximum_depth": 128, "classification_revision": 4,
         "profile": startup ? "startup-result-data-v4" : "full-result-data-v4", "application_layout_revision": 1,
         "stored_location_revision": 1, "sorted_page_revision": 1, "largest_files_revision": 1]
    }
    func testLiteralAllowlistPreservesV2V3AndRawPrefixes() {
        for suffix in suffixes {
            for name in ["Generated." + suffix, "GENERATED." + suffix.uppercased()] {
                XCTAssertEqual(AnalysisFileType.match(Data(name.utf8), revision: .v4), .dataFiles)
                for revision in [AnalysisClassificationRevision.v2,.v3] {
                    XCTAssertEqual(AnalysisFileType.match(Data(name.utf8), revision: revision), ["csv","tsv"].contains(suffix) ? .textAndSource : .other)
                }
            }
        }
        XCTAssertEqual(AnalysisFileType.match(Data([255,46,78,80,90]), revision: .v4), .dataFiles)
        XCTAssertEqual(AnalysisFileType.match(Data("folder.csv/file".utf8), revision: .v4), .other)
    }
    func testNearMissesAndExistingFamiliesStayDistinct() {
        for name in ["file.nc","file.cdf","file.fit","file.dat","file.bin","file.ipc","file.pq",".RData",".csv","file.parquet.","file.parquet-backup","file.párquet"] {
            XCTAssertEqual(AnalysisFileType.match(Data(name.utf8), revision: .v4), .other)
        }
        for (name, type) in [("table.csv.gz",AnalysisFileType.archives),("weights.safetensors",.models),("state.sqlite",.databases),
                             ("data.jsonl",.textAndSource),("Assets.car",.applicationResources),("Info.plist",.textAndSource)] {
            XCTAssertEqual(AnalysisFileType.match(Data(name.utf8), revision: .v4), type)
        }
        XCTAssertEqual(AnalysisClassificationRevision.v2.fileTypes.count, 15)
        XCTAssertEqual(AnalysisClassificationRevision.v3.fileTypes.count, 16)
        XCTAssertEqual(AnalysisClassificationRevision.v4.fileTypes.count, 17)
        XCTAssertEqual(AnalysisFileType.applicationResources.rawValue, 15)
        XCTAssertEqual(AnalysisFileType.dataFiles.rawValue, 16)
    }
    func testV4RequiresItsWholeAdaptiveContract() throws {
        for paired in [false,true] {
            let frame = header(startup: paired)
            let bound = try AnalysisPolicyBinding(header: frame, startup: paired, policy: .standard, classificationRevision: .v4)
            XCTAssertEqual(bound.classificationRevision, .v4); XCTAssertTrue(bound.adaptiveCheckpoints)
            XCTAssertEqual(bound.maximumPathComponents, 128)
            for key in ["checkpoint_revision","checkpoint_rows","progress_revision","classification_revision","traversal_revision","maximum_depth","profile"] {
                var bad = frame; bad.removeValue(forKey: key)
                XCTAssertThrowsError(try AnalysisPolicyBinding(header: bad, startup: paired, policy: .standard, classificationRevision: .v4), key)
            }
        }
        for rows: UInt64 in [1024,4096] { XCTAssertThrowsError(try AnalysisCheckpointContract(rows: rows, classification: .v4)) }
        let checkpoint = try AnalysisCheckpointContract(rows: 16384, classification: .v4)
        XCTAssertEqual(checkpoint.prefixRevision, 5); XCTAssertEqual(checkpoint.progressRevision, "committed-totals-data-v4")
        XCTAssertTrue(checkpoint.acceptsSchema(17) && checkpoint.acceptsSchema(18)); XCTAssertFalse(checkpoint.acceptsSchema(15))
    }
    func testV3CannotClaimNewSchemaEvenWithForgedOldLabels() {
        var frame = header(); frame["classification_revision"] = 3; frame["progress_revision"] = "committed-totals-adaptive-v1"
        frame["profile"] = "full-result-adaptive-v1"
        XCTAssertThrowsError(try AnalysisPolicyBinding(header: frame, startup: false, policy: .standard, classificationRevision: .v3))
        frame["schema"] = 15
        XCTAssertNoThrow(try AnalysisPolicyBinding(header: frame, startup: false, policy: .standard, classificationRevision: .v3))
        XCTAssertThrowsError(try AnalysisPolicyBinding(header: frame, startup: false, policy: .standard, classificationRevision: .v4))
    }
    func testEveryQueryPreludeIsBoundToTheRuleRevision() throws {
        let session = UUID(), bound = try AnalysisPolicyBinding(header: header(), startup: false, policy: .standard, classificationRevision: .v4)
        var prelude: [String: Any] = ["kind":"policy","revision":AnalysisMetadataPolicy.standard.rawValue,"session":session.uuidString,
            "classification_revision":4,"maximum_depth":128,"checkpoint_revision":1]
        XCTAssertNoThrow(try bound.validateQueryPrelude(prelude, session: session))
        prelude["classification_revision"] = 3; XCTAssertThrowsError(try bound.validateQueryPrelude(prelude, session: session))
        prelude["classification_revision"] = 4; prelude["unexpected"] = 1; XCTAssertThrowsError(try bound.validateQueryPrelude(prelude, session: session))
    }
    func testSeventeenWayPrefixAndAllMetricsMustReconcile() throws {
        let session = UUID()
        let rows: [[String: Any]] = (0..<17).map { ["id":$0,"value":value($0 == 16 ? 4096 : 0)] }
        let frame: [String: Any] = ["kind":"committed_totals","prefix_revision":5,"schema":17,"session":session.uuidString,
            "policy_revision":AnalysisMetadataPolicy.standard.rawValue,"committed":"4096","seq":"2","elapsed_ns":"250000000",
            "value":value(4096),"types":rows]
        func decode(_ input: [String: Any], _ revision: AnalysisClassificationRevision = .v4) throws -> CommittedAnalysisPrefix {
            try .decode(input, session: session, policy: .standard, wireSchema: 17, committed: 4096, previous: nil,
                checkpointRows: 16384, classificationRevision: revision)
        }
        let result = try decode(frame); XCTAssertEqual(result.fileTypes.count, 17)
        XCTAssertEqual(result.fileTypes[16].counts.regularFiles, 4096)
        XCTAssertThrowsError(try decode(frame, .v3))
        var bad = frame; bad["types"] = Array(rows.dropLast()); XCTAssertThrowsError(try decode(bad))
        bad = frame; bad["prefix_revision"] = 4; XCTAssertThrowsError(try decode(bad))
        var malformed = rows; malformed[16]["id"] = 15; bad = frame; bad["types"] = malformed; XCTAssertThrowsError(try decode(bad))
        malformed = rows; malformed[16]["value"] = value(4095); bad = frame; bad["types"] = malformed; XCTAssertThrowsError(try decode(bad))
    }
    func testLocationOtherAndLayoutRepliesCannotLoseProvenance() throws {
        let location: [[String: Any]] = [["kind":"location","location_revision":1,"classification_revision":4,"node":"0","source":0,"chain":[]]]
        XCTAssertNoThrow(try StoredAnalysisLocationReference.decode(location, node: 0, maximumPathComponents: 128, classificationRevision: .v4))
        XCTAssertThrowsError(try StoredAnalysisLocationReference.decode(location, node: 0))
        let roles = (0..<AnalysisCategory.allCases.count).map { ["id":$0,"value":value(0)] as [String: Any] }
        let patterns = (0..<AnalysisOtherNamePattern.allCases.count).map { ["id":$0,"value":value(0)] as [String: Any] }
        let other: [[String: Any]] = [["kind":"other_explanation","classification_revision":4,"parent":"0","value":value(0),"roles":roles,"name_patterns":patterns]]
        XCTAssertNoThrow(try StoredAnalysisOtherExplanation.decode(other, folder: 0, classificationRevision: .v4))
        XCTAssertThrowsError(try StoredAnalysisOtherExplanation.decode(other, folder: 0))
        let layouts: [[String: Any]] = [["kind":"application_layouts","layout_revision":1,"classification_revision":4,"groups":[],
            "value":value(0),"remainder":value(0),"total_groups":"0","project_count":"0"]]
        XCTAssertNoThrow(try StoredAnalysisGroups.decodeApplicationLayouts(layouts, classificationRevision: .v4))
        XCTAssertThrowsError(try StoredAnalysisGroups.decodeApplicationLayouts(layouts))
    }
    func testProjectCompositionPreservesTypeSixteenAndOldTypeBounds() throws {
        var frame: [String: Any] = ["kind":"project-composition","revision":1,"classification_revision":4,"metric":0,"parent":"0","project":"0",
            "value":value(1),"file_types":[["key":"16","value":value(1)]],"roles":[["key":"0","value":value(1)]]]
        let target = StoredAnalysisDrillTarget.filtered(folder: 0, facet: .projects, key: 0)
        XCTAssertNoThrow(try StoredProjectComposition.decode([frame], target: target, metric: .dataLogical, classificationRevision: .v4))
        XCTAssertThrowsError(try StoredProjectComposition.decode([frame], target: target, metric: .dataLogical))
        frame["classification_revision"] = 3
        XCTAssertThrowsError(try StoredProjectComposition.decode([frame], target: target, metric: .dataLogical))
    }
    func testFilteredChildrenRetainDataGroupAndRefuseOldCategoryRange() throws {
        let target = StoredAnalysisDrillTarget.filtered(folder: 0, facet: .fileTypes, key: 16)
        let frame: [String: Any] = ["kind":"breakdown","metric":0,"filter_facet":3,"filter_key":"16","parent":"0",
            "value":value(1),"remainder":value(0),"rows":[["folder":NSNull(),"name":"","hint":6,"value":value(1)]]]
        let result = try StoredAnalysisBreakdown.decode([frame], target: target, metric: .dataLogical, classificationRevision: .v4)
        XCTAssertEqual(result.target(for: 17), .filtered(folder: 17, facet: .fileTypes, key: 16))
        XCTAssertThrowsError(try StoredAnalysisBreakdown.decode([frame], target: target, metric: .dataLogical))
    }
}
