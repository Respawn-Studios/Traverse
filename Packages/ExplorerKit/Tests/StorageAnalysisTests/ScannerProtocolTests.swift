import Foundation
import Testing
@testable import StorageAnalysis

struct ScannerProtocolTests {
    private let session = UUID(uuidString: "930824D4-103A-416B-94CC-686D21CB068D")!
    private let root = AnalysisObjectIdentity(device: 1, inode: 2)

    private func decoder() -> ScannerProtocolDecoder { .init(session: session, root: root) }
    private func frame(_ kind: String, seq: Int, _ fields: [String: Any] = [:]) throws -> Data {
        var value = fields
        value["schema"] = 2; value["kind"] = kind
        value["session"] = session.uuidString; value["seq"] = String(seq)
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    private func header() throws -> Data {
        try frame("header", seq: 0, ["lane": "rust", "profile": "core-v1", "policy_revision": StorageAnalysisPolicy.revision, "materialization_policy": "off",
            "worker_qos": "utility", "workers": 1, "scope_contract": "descriptor-anchored",
            "expected_dev": "1", "expected_ino": "2", "common_mask": "2718171147",
            "directory_mask": "5", "file_mask": "1543"])
    }
    private func row(path: Data = Data("zero.bin".utf8), value: String = "0") -> [String: Any] {
        let returned: [String: Any] = ["state": "returned", "value": value]
        return ["relative_b64": path.base64EncodedString(), "parent_b64": "", "name_b64": path.base64EncodedString(),
            "type": "regular", "dev": "1", "ino": "3", "nlink": "1", "flags": "0", "errno": 0,
            "returned": ["common": "2718171147", "volume": "0", "directory": "0", "file": "1543", "fork": "0"],
            "data_logical": returned, "all_logical": returned, "data_allocated": returned, "all_allocated": returned]
    }
    private func summary(seq: Int = 2, entries: String = "1") throws -> Data {
        try frame("summary", seq: seq, ["complete": true, "reason": "complete", "entries": entries, "errors": "0",
            "regular_entries": entries, "directory_entries": "0", "symlink_entries": "0", "other_entries": "0",
            "elapsed_ns": "45", "peak_rss": "10000", "objects": entries,
            "entry_totals": ["data_logical": "0", "all_logical": "0", "data_allocated": "0", "all_allocated": "0"],
            "object_totals": ["data_logical": "0", "all_logical": "0", "data_allocated": "0", "all_allocated": "0"]])
    }

    @Test func validZeroAndRawNamesRemainMetadata() throws {
        let decoder = decoder()
        _ = try decoder.consume(header())
        let raw = Data([255, 97])
        guard case .records(let records) = try decoder.consume(frame("batch", seq: 1, ["rows": [row(path: raw)]])) else {
            Issue.record("Missing records"); return
        }
        #expect(records.count == 1)
        #expect(records[0].relativePath == raw)
        #expect(records[0].bytes.dataLogical == .returned(0))
        guard case .terminal(let terminal) = try decoder.consume(summary()) else { Issue.record("Missing terminal"); return }
        #expect(terminal.complete && terminal.entries == 1)
        try decoder.finish()
        #expect(throws: (any Error).self) { try decoder.consume(summary(seq: 3)) }
    }

    @Test func requiresHeaderIdentityAndPolicyBeforeRecords() throws {
        let decoder = decoder()
        #expect(throws: (any Error).self) { try decoder.consume(frame("batch", seq: 0, ["rows": [row()]])) }
        var header = try #require(try JSONSerialization.jsonObject(with: self.header()) as? [String: Any])
        for (key, value) in [("expected_ino", "4"), ("materialization_policy", "on"), ("scope_contract", "unrestricted")] {
            var changed = header; changed[key] = value
            #expect(throws: (any Error).self) { try self.decoder().consume(JSONSerialization.data(withJSONObject: changed)) }
        }
        header["workers"] = true
        #expect(throws: (any Error).self) { try self.decoder().consume(JSONSerialization.data(withJSONObject: header)) }
    }

    @Test func rejectsWrongSessionSequenceAndUnknownFrames() throws {
        for change in ["session", "seq", "kind"] {
            let decoder = decoder(); _ = try decoder.consume(header())
            var value = try #require(try JSONSerialization.jsonObject(with: frame("batch", seq: 1, ["rows": [row()]])) as? [String: Any])
            value[change] = change == "session" ? UUID().uuidString : change == "seq" ? "02" : "other"
            #expect(throws: (any Error).self) { try decoder.consume(JSONSerialization.data(withJSONObject: value)) }
        }
    }

    @Test func boundedFramingRowsAndTruncatedEnd() throws {
        #expect(throws: (any Error).self) { try decoder().consume(Data(repeating: 32, count: 64 << 10)) }
        let decoder = decoder(); _ = try decoder.consume(header())
        #expect(throws: (any Error).self) { try decoder.finish() }
        #expect(throws: (any Error).self) { try decoder.consume(frame("batch", seq: 1, ["rows": Array(repeating: row(), count: 129)])) }
        #expect(throws: (any Error).self) { try self.decoder().consume(header() + Data([10])) }
    }

    @Test func unknownOrNoncanonicalMetricsDoNotBecomeZero() throws {
        for text in ["00", "+1", "-1", "18446744073709551616", "1.0"] {
            let decoder = decoder(); _ = try decoder.consume(header())
            #expect(throws: (any Error).self) { try decoder.consume(frame("batch", seq: 1, ["rows": [row(value: text)]])) }
        }
        let decoder = decoder(); _ = try decoder.consume(header())
        var row = row(); row["data_logical"] = ["state": "not_returned"]
        var masks = try #require(row["returned"] as? [String: String])
        masks["file"] = "1031" // The data-logical bit was not returned.
        row["returned"] = masks
        guard case .records(let records) = try decoder.consume(frame("batch", seq: 1, ["rows": [row]])) else { return }
        #expect(records[0].bytes.dataLogical == .notReturned)
    }

    @Test func brokenPathReconstructionAndUnsupportedMasksFail() throws {
        for key in ["parent_b64", "returned"] {
            let decoder = decoder(); _ = try decoder.consume(header())
            var row = row()
            row[key] = key == "parent_b64" ? Data("wrong".utf8).base64EncodedString() as Any
                : ["common": "4294967295", "volume": "0", "directory": "0", "file": "1543", "fork": "0"] as Any
            #expect(throws: (any Error).self) { try decoder.consume(frame("batch", seq: 1, ["rows": [row]])) }
        }
    }

    @Test func returnedMasksMustSupportEveryClaimedField() throws {
        for (group, bit): (String, UInt64) in [("common", 0x8000_0000), ("common", 1),
            ("common", 2), ("common", 8), ("common", 0x40000), ("common", 0x0200_0000),
            ("file", 1), ("file", 2), ("file", 4), ("file", 0x200), ("file", 0x400)] {
            let decoder = decoder(); _ = try decoder.consume(header())
            var value = row()
            var masks = try #require(value["returned"] as? [String: String])
            let originalText = try #require(masks[group])
            let original = try #require(UInt64(originalText))
            masks[group] = String(original & ~bit)
            value["returned"] = masks
            #expect(throws: (any Error).self) { try decoder.consume(frame("batch", seq: 1, ["rows": [value]])) }
        }
    }

    @Test func missingSupportedFieldsRemainUnknownRatherThanClaimingZero() throws {
        let decoder = decoder(); _ = try decoder.consume(header())
        var value = row()
        value["returned"] = ["common": "2684354561", "volume": "0", "directory": "0", "file": "0", "fork": "0"]
        value["type"] = "unknown"
        for key in ["dev", "ino", "flags", "nlink"] { value[key] = NSNull() }
        for key in ["data_logical", "all_logical", "data_allocated", "all_allocated"] { value[key] = ["state": "not_returned"] }
        guard case .records(let values) = try decoder.consume(frame("batch", seq: 1, ["rows": [value]])),
              let entry = values.first else { Issue.record("Missing unknown observation"); return }
        #expect(entry.identity == .notReturned && entry.flags == .notReturned && entry.linkCount == .notReturned)
        #expect(entry.kind == .unknown && entry.bytes.dataLogical == .notReturned)
    }

    @Test func entryErrorSupportIsCheckedWithoutRequiringItForSuccess() throws {
        var value = row()
        var masks = try #require(value["returned"] as? [String: String])
        masks["common"] = String(UInt64(2_718_171_147) & ~UInt64(0x2000_0000))
        value["returned"] = masks
        let success = decoder(); _ = try success.consume(header())
        guard case .records(let known) = try success.consume(frame("batch", seq: 1, ["rows": [value]])) else {
            Issue.record("Success without a returned error field was refused"); return
        }
        #expect(known.first?.bytes.dataLogical == .returned(0))
        value["errno"] = 13
        for key in ["data_logical", "all_logical", "data_allocated", "all_allocated"] { value[key] = ["state": "error"] }
        let unsupported = decoder(); _ = try unsupported.consume(header())
        #expect(throws: (any Error).self) { try unsupported.consume(frame("batch", seq: 1, ["rows": [value]])) }
        masks["common"] = "2718171147"; value["returned"] = masks
        let failed = decoder(); _ = try failed.consume(header())
        guard case .records(let observations) = try failed.consume(frame("batch", seq: 1, ["rows": [value]])) else {
            Issue.record("Supported failed field was refused"); return
        }
        #expect(observations.first?.identity == .failed(code: 13))
        #expect(observations.first?.bytes.dataLogical == .failed(code: 13))
    }

    @Test func terminalMustAccountForEveryReceivedEntry() throws {
        let decoder = decoder(); _ = try decoder.consume(header())
        _ = try decoder.consume(frame("batch", seq: 1, ["rows": [row()]]))
        #expect(throws: (any Error).self) { try decoder.consume(summary(entries: "0")) }
    }

    @Test func terminalCannotClaimRegularObjectsForOnlyDirectories() throws {
        let decoder = decoder(); _ = try decoder.consume(header())
        var folder = row()
        folder["type"] = "directory"
        folder["returned"] = ["common": "2718171147", "volume": "0", "directory": "5", "file": "0", "fork": "0"]
        for key in ["data_logical", "all_logical", "data_allocated", "all_allocated"] { folder[key] = ["state": "not_returned"] }
        _ = try decoder.consume(frame("batch", seq: 1, ["rows": [folder]]))
        var terminal = try #require(try JSONSerialization.jsonObject(with: summary()) as? [String: Any])
        terminal["regular_entries"] = "0"; terminal["directory_entries"] = "1"
        #expect(throws: (any Error).self) { try decoder.consume(JSONSerialization.data(withJSONObject: terminal)) }
    }

    @Test func terminalRetainsTotalNoticesBeyondTheEmittedSample() throws {
        let decoder = decoder(); _ = try decoder.consume(header())
        _ = try decoder.consume(frame("batch", seq: 1, ["rows": [row()]]))
        _ = try decoder.consume(frame("issue", seq: 2, ["code": "policy_excluded", "errno": 0]))
        var value = try #require(try JSONSerialization.jsonObject(with: summary(seq: 3)) as? [String: Any])
        value["complete"] = false; value["reason"] = "policy_excluded"; value["errors"] = "4500"
        guard case .terminal(let terminal) = try decoder.consume(JSONSerialization.data(withJSONObject: value)) else {
            Issue.record("Missing terminal coverage"); return
        }
        #expect(!terminal.complete && terminal.errors == 4_500)
        try decoder.finish()
    }
}
