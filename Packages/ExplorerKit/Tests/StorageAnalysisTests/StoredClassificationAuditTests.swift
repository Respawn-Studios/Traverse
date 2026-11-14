#if DEBUG
import Foundation
import Testing
@testable import StorageAnalysis

@Suite struct StoredClassificationAuditTests {
    private func value(_ count: UInt64, bytes: UInt64) -> String {
        var data = Data(repeating: 0, count: 140)
        func put(_ value: UInt64, at offset: Int) {
            for index in 0..<8 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (56 - index * 8)) }
        }
        put(count, at: 0)
        for metric in 0..<4 { put(bytes, at: 40 + metric * 25) }
        return data.base64EncodedString()
    }
    private func frame() -> [String: Any] {
        let empty = value(0, bytes: 0), total = value(1, bytes: 10)
        var old = [String](repeating: empty, count: 16), new = old
        old[0] = total; new[15] = total
        return ["kind": "classification_audit", "revision": 1, "old": old, "new": new, "total": total, "changed": total]
    }
    @Test func exactPartitionsAreBoundedAndKeepTheChangedSubset() throws {
        let result = try StoredClassificationAudit.decode([frame()])
        #expect(result.old.count == 16 && result.new.count == 16)
        #expect(result.total.counts.regularFiles == 1)
        #expect(result.new[15] == result.changed && result.old[0] == result.total)
        #expect(result.changed.bytes.allForkAllocated.knownBytes == 10)
    }
    @Test func malformedNumericAuditsRefuseWithoutTrapping() {
        var cases = [[String: Any]]()
        var bad = frame(); bad["revision"] = true; cases.append(bad)
        bad = frame(); bad["filename"] = "unrequested"; cases.append(bad)
        bad = frame(); bad["old"] = [String](repeating: value(0, bytes: 0), count: 15); cases.append(bad)
        bad = frame(); bad["changed"] = value(1, bytes: 11); cases.append(bad)
        bad = frame(); bad["changed"] = value(2, bytes: 10); cases.append(bad)
        bad = frame(); bad["old"] = [String](repeating: value(UInt64(Int64.max) - 1, bytes: 0), count: 16); cases.append(bad)
        bad = frame(); bad["old"] = bad["new"]; cases.append(bad)
        for frame in cases { #expect(throws: StorageScanFailure.invalidOutput) { try StoredClassificationAudit.decode([frame]) } }
        #expect(throws: StorageScanFailure.invalidOutput) { try StoredClassificationAudit.decode([]) }
        #expect(throws: StorageScanFailure.invalidOutput) { try StoredClassificationAudit.decode([frame(), frame()]) }
    }
}
#endif
