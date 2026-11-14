import Foundation
import Testing
@testable import StorageAnalysis

@Suite struct ClassificationRevisionTests {
    private let session = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private func value(_ files: UInt64, _ amount: UInt64) -> String {
        var data = Data(repeating: 0, count: 140)
        func put(_ n: UInt64, _ at: Int) { for i in 0..<8 { data[at+i] = UInt8(truncatingIfNeeded: n >> ((7-i)*8)) } }
        put(files, 0)
        for metric in 0..<4 { put(amount * UInt64(metric + 1), 40 + metric * 25) }
        return data.base64EncodedString()
    }
    private func source() throws -> String {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        return try String(contentsOf: repository.appendingPathComponent("Workers/StorageScanner/classification-v3-vectors.tsv"), encoding: .utf8)
    }
    @Test func bothRevisionsMatchSharedFilenameAndLayoutOracle() throws {
        let rows = try source().split(separator: "\n").filter { !$0.hasPrefix("#") }
        #expect(rows.count == 33)
        for row in rows {
            let columns = row.split(separator: "\t", omittingEmptySubsequences: false)
            #expect(columns.count == 4)
            for revision in [AnalysisClassificationRevision.v2, .v3] {
                let expected = try #require(Int(columns[revision.rawValue - 1]))
                if columns[0] == "f" {
                    #expect(AnalysisFileType.match(Data(columns[3].utf8), revision: revision).rawValue == expected, "\(row)")
                } else {
                    #expect(AnalysisAttributionReport.classify(columns[3].split(separator: "/").map(String.init),
                        inherited: .other, hasProject: false, revision: revision).rawValue == expected, "\(row)")
                }
            }
        }
        #expect(AnalysisFileType.match(Data([255, 46, 67, 65, 82]), revision: .v3) == .applicationResources)
        #expect(AnalysisFileType.match(Data([255, 46, 67, 65, 82])) == .other)
        for role in [AnalysisCategory.dependencies, .toolCache, .modelStore, .versionControl, .pythonCache,
                     .flutterState, .steamLibrary, .developerCache, .applicationBundle, .systemFiles] {
            #expect(AnalysisAttributionReport.classify(["Library", "Developer", "Xcode", "DerivedData"],
                inherited: role, hasProject: false, revision: .v3) == role)
        }
        #expect(StorageAnalysisPolicy.excludes(URL(fileURLWithPath: "/Users/sample/Library/Containers")))
    }
    @Test func headersAndReaderPreludeRequireExactRevisionInBothDirections() throws {
        for startup in [false, true] {
            let header: [String: Any] = ["schema": startup ? 12 : 11,
                "profile": startup ? "startup-result-classification-v3" : "full-result-classification-v3",
                "policy_revision": AnalysisMetadataPolicy.standard.rawValue, "classification_revision": 3]
            let binding = try AnalysisPolicyBinding(header: header, startup: startup, policy: .standard, classificationRevision: .v3)
            #expect(binding.classificationRevision == .v3 && binding.policyAware)
            #expect(throws: StorageScanFailure.self) { try AnalysisPolicyBinding(header: header, startup: startup, policy: .standard) }
            var old = header; old["schema"] = startup ? 10 : 9
            old["profile"] = startup ? "startup-result-policy-v1" : "full-result-policy-v1"; old.removeValue(forKey: "classification_revision")
            #expect(throws: StorageScanFailure.self) { try AnalysisPolicyBinding(header: old, startup: startup, policy: .standard, classificationRevision: .v3) }
            let prelude: [String: Any] = ["kind": "policy", "session": session.uuidString,
                "revision": AnalysisMetadataPolicy.standard.rawValue, "classification_revision": 3]
            try binding.validateQueryPrelude(prelude, session: session)
            for wrong in [true as Any, 2 as Any, "3" as Any] {
                var bad = prelude; bad["classification_revision"] = wrong
                #expect(throws: StorageScanFailure.self) { try binding.validateQueryPrelude(bad, session: session) }
            }
        }
    }
    @Test func sixteenTypesRequireNewPrefixAndSchemaWithoutReinterpretingOldPrefix() throws {
        let zero = value(0, 0), total = value(4096, 100)
        var row: [String: Any] = ["kind": "committed_totals", "schema": 11, "prefix_revision": 3,
            "session": session.uuidString, "policy_revision": AnalysisMetadataPolicy.standard.rawValue,
            "seq": "3", "committed": "4096", "elapsed_ns": "300000000", "value": total,
            "types": (0..<16).map { ["id": $0, "value": $0 == 15 ? total : zero] as [String: Any] }]
        func decode(_ frame: [String: Any], revision: AnalysisClassificationRevision = .v3) throws -> CommittedAnalysisPrefix {
            try .decode(frame, session: session, policy: .standard, wireSchema: 11, committed: 4096,
                previous: nil, checkpointRows: 4096, classificationRevision: revision)
        }
        let prefix = try decode(row)
        #expect(prefix.fileTypes.count == 16 && prefix.classificationRevision == .v3)
        #expect(prefix.attributionReport().fileTypes[15].title == "Application resources")
        #expect(throws: StorageScanFailure.self) { try decode(row, revision: .v2) }
        row["types"] = Array((row["types"] as! [[String: Any]]).prefix(15))
        #expect(throws: StorageScanFailure.self) { try decode(row) }
    }
    @Test func otherExplanationHasTwoExactFixedPartitionsAndRejectsContradictions() throws {
        let zero = value(0, 0), total = value(3, 60)
        var frame: [String: Any] = ["kind": "other_explanation", "classification_revision": 3, "parent": "7", "value": total,
            "roles": (0..<13).map { ["id": $0, "value": $0 == 11 ? total : zero] as [String: Any] },
            "name_patterns": (0..<5).map { ["id": $0, "value": $0 == 0 ? total : zero] as [String: Any] }]
        let explanation = try StoredAnalysisOtherExplanation.decode([frame], folder: 7)
        #expect(explanation.storageRoles.count == 13 && explanation.namePatterns.count == 5)
        #expect(explanation.applicationLayouts == nil)
        #expect(explanation.value.bytes.allForkAllocated.knownBytes == 240)
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisOtherExplanation.decode([frame], folder: 0) }
        for key in ["roles", "name_patterns"] {
            let original = frame[key] as! [[String: Any]]
            var bad = original; bad[0]["value"] = value(1, 1); frame[key] = bad
            #expect(throws: StorageScanFailure.self) { try StoredAnalysisOtherExplanation.decode([frame], folder: 7) }
            frame[key] = Array(original.dropLast())
            #expect(throws: StorageScanFailure.self) { try StoredAnalysisOtherExplanation.decode([frame], folder: 7) }
            frame[key] = original
        }
        frame["layout_revision"] = 1
        frame["layouts"] = (0..<19).map { ["id": $0, "value": $0 == 10 ? total : zero] as [String: Any] }
        let layouts = try StoredAnalysisOtherExplanation.decode([frame], folder: 7)
        #expect(layouts.applicationLayouts?.count == 19 && layouts.applicationLayouts?[10].counts.regularFiles == 3)
        frame["layout_revision"] = 99
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisOtherExplanation.decode([frame], folder: 7) }
        frame["layout_revision"] = 1
        var bad = frame["layouts"] as! [[String: Any]]; bad[0]["value"] = total; frame["layouts"] = bad
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisOtherExplanation.decode([frame], folder: 7) }
        frame["layouts"] = Array(bad.dropLast())
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisOtherExplanation.decode([frame], folder: 7) }
        frame.removeValue(forKey: "layout_revision")
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisOtherExplanation.decode([frame], folder: 7) }
    }
}
