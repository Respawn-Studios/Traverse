import Foundation
import Testing
@testable import StorageAnalysis

@Suite struct DeepTraversalContractTests {
    private func header(startup: Bool = false) -> [String: Any] {
        ["schema": startup ? 14 : 13, "policy_revision": "local-metadata-v1", "classification_revision": 3,
         "profile": startup ? "startup-result-depth128-v1" : "full-result-depth128-v1",
         "traversal_revision": "bounded-depth-v1", "maximum_depth": 128]
    }
    private func binding(_ frame: [String: Any], startup: Bool = false) throws -> AnalysisPolicyBinding {
        try .init(header: frame, startup: startup, policy: .standard, classificationRevision: .v3)
    }
    @Test func versionBoundIsExactAndOlderContractsKeepTheirOwnLimit() throws {
        for startup in [false,true] {
            #expect(try binding(header(startup: startup), startup: startup).maximumPathComponents == 128)
            #expect(try binding(header(startup: startup), startup: startup).maximumStoredHierarchyDepth == (startup ? 129 : 128))
            var old = header(startup: startup)
            old["schema"] = startup ? 12 : 11
            old["profile"] = startup ? "startup-result-classification-v3" : "full-result-classification-v3"
            #expect(throws: StorageScanFailure.self) { try binding(old, startup: startup) }
            old.removeValue(forKey: "maximum_depth"); old.removeValue(forKey: "traversal_revision")
            #expect(try binding(old, startup: startup).maximumPathComponents == 64)
            #expect(try binding(old, startup: startup).maximumStoredHierarchyDepth == (startup ? 65 : 64))
            for invalid: Any in [0,64,127,129,256,true,"128"] {
                var bad = header(startup: startup); bad["maximum_depth"] = invalid
                #expect(throws: StorageScanFailure.self) { try binding(bad, startup: startup) }
            }
            for key in ["maximum_depth","traversal_revision","profile"] {
                var bad = header(startup: startup); bad.removeValue(forKey: key)
                #expect(throws: StorageScanFailure.self) { try binding(bad, startup: startup) }
            }
        }
        #expect(AnalysisPolicyBinding.standard.maximumPathComponents == 64)
        #expect(AnalysisPolicyBinding.standard.maximumStoredHierarchyDepth == 64)
        #expect(AnalysisLimits.standard.maximumDepth == 64)
        #expect(throws: StorageScanFailure.self) { try binding(header(startup: true)) }
    }
    @Test func readPreludeCannotSilentlyChangeTraversalContract() throws {
        let bound = try binding(header()), session = UUID()
        let prelude: [String: Any] = ["kind":"policy","revision":"local-metadata-v1","session":session.uuidString,
            "classification_revision":3,"maximum_depth":128]
        try bound.validateQueryPrelude(prelude, session: session)
        for invalid: Any in [64,129,true,"128"] {
            var bad = prelude; bad["maximum_depth"] = invalid
            #expect(throws: StorageScanFailure.self) { try bound.validateQueryPrelude(bad, session: session) }
        }
        var missing = prelude; missing.removeValue(forKey: "maximum_depth")
        #expect(throws: StorageScanFailure.self) { try bound.validateQueryPrelude(missing, session: session) }
    }
    private func location(_ count: Int) -> [String: Any] {
        ["kind":"location","location_revision":1,"classification_revision":3,"node":String(count),"source":0,
         "chain":(1...count).map { index in ["id":String(index),"parent":String(index-1),
            "name":Data("p".utf8).base64EncodedString(),"type":index == count ? 0 : 1,
            "device":"1","inode":String(index+100),"flags":"0"] as [String:Any] }]
    }
    @Test func longerLocationChainsRequireTheVerifiedBoundAndStillCheckEachParent() throws {
        let frames = [location(128)]
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisLocationReference.decode(frames, node: 128) }
        let decoded = try StoredAnalysisLocationReference.decode(frames, node: 128, maximumPathComponents: 128)
        #expect(decoded.chain.count == 128 && decoded.maximumPathComponents == 128)
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisLocationReference.decode([location(129)], node: 129, maximumPathComponents: 128) }
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisLocationReference.decode(frames, node: 128, maximumPathComponents: 256) }
        var broken = location(128), rows = broken["chain"] as! [[String:Any]]
        rows[70]["parent"] = "69"; broken["chain"] = rows
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisLocationReference.decode([broken], node: 128, maximumPathComponents: 128) }
        rows = location(128)["chain"] as! [[String:Any]]
        rows[70]["type"] = 0; broken["chain"] = rows
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisLocationReference.decode([broken], node: 128, maximumPathComponents: 128) }
    }
    @Test func largestFilePathsUseTheSameVerifiedLimit() throws {
        var payload = Data(repeating: 0,count: 52)
        for metric in 0..<4 { payload[metric*13] = 1; payload[metric*13+8] = 16 }
        let name = Data("Leaf".utf8), path = Data((Array(repeating:"p",count:127)+["Leaf"]).joined(separator:"/").utf8)
        let row: [String:Any] = ["id":"128","name":name.base64EncodedString(),"payload":payload.base64EncodedString(),"source":0,"path":path.base64EncodedString()]
        let frames: [[String:Any]] = [["kind":"largest_rows","rows":[row]],
            ["kind":"largest_end","largest_files_revision":1,"metric":0,"count":1,"rankable":"1","unknown":"0","startup":false]]
        #expect(throws: StorageScanFailure.self) { try StoredLargestFiles.decode(frames,metric:.logical,startup:false) }
        #expect(try StoredLargestFiles.decode(frames,metric:.logical,startup:false,maximumPathComponents:128).files.first?.rawRelativePath == path)
        #expect(throws: StorageScanFailure.self) { try StoredLargestFiles.decode(frames,metric:.logical,startup:false,maximumPathComponents:129) }
    }
}
