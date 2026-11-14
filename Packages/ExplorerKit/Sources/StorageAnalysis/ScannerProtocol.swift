import CoreFoundation
import Foundation

/// A private worker protocol, separate from the preserved benchmark protocol.
/// Names remain process-local metadata; no frame is a diagnostic log record.
enum ScannerProtocolFailure: Error, Equatable {
    case frame, envelope, sequence, header, record, summary, bounds, prematureEnd
}

struct ScannerTerminal: Sendable {
    let complete: Bool
    let reason: String
    let entries: UInt64
    let peakResidentBytes: UInt64?
    let elapsedNanoseconds: UInt64
    let kindCounts: [UInt64]
    let namespaceTotals: [UInt64]
    let objectTotals: [UInt64]
    let objectCount: UInt64
    let errors: UInt64
}

enum ScannerMessage {
    case header
    case records([AnalysisEntryObservation])
    case issue(code: String, error: Int32)
    case terminal(ScannerTerminal)
}

/// Used serially on the scan worker. Bounds apply before JSON allocation and
/// before materializing row arrays. Publication/session ownership is external.
final class ScannerProtocolDecoder {
    static let maximumFrameBytes = 64 << 10
    private let session: String
    private let root: AnalysisObjectIdentity
    private var nextSequence: UInt64 = 0
    private var receivedHeader = false
    private(set) var receivedTerminal = false
    private(set) var receivedEntries: UInt64 = 0
    private var detailedIssues = 0

    init(session: UUID, root: AnalysisObjectIdentity) {
        self.session = session.uuidString
        self.root = root
    }

    func consume(_ line: Data) throws -> ScannerMessage {
        guard !line.isEmpty, line.count < Self.maximumFrameBytes,
              !line.contains(10), !line.contains(0), !receivedTerminal else { throw ScannerProtocolFailure.frame }
        guard let frame = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              integer(frame["schema"]) == 2,
              frame["session"] as? String == session,
              let sequence = unsigned(frame["seq"]), sequence == nextSequence,
              let kind = frame["kind"] as? String else { throw ScannerProtocolFailure.envelope }
        guard nextSequence < UInt64.max else { throw ScannerProtocolFailure.sequence }
        nextSequence += 1
        if !receivedHeader && kind != "header" { throw ScannerProtocolFailure.header }
        switch kind {
        case "header":
            guard !receivedHeader, sequence == 0, frame["lane"] as? String == "rust",
                  frame["profile"] as? String == "core-v1",
                  frame["policy_revision"] as? String == StorageAnalysisPolicy.revision,
                  frame["materialization_policy"] as? String == "off",
                  frame["worker_qos"] as? String == "utility", integer(frame["workers"]) == 1,
                  frame["scope_contract"] as? String == "descriptor-anchored",
                  unsigned(frame["expected_dev"]) == root.device, unsigned(frame["expected_ino"]) == root.inode,
                  unsigned(frame["common_mask"]) == 2_718_171_147,
                  unsigned(frame["directory_mask"]) == 5, unsigned(frame["file_mask"]) == 1543 else {
                throw ScannerProtocolFailure.header
            }
            receivedHeader = true
            return .header
        case "batch":
            guard let rows = frame["rows"] as? [[String: Any]], !rows.isEmpty, rows.count <= 128,
                  receivedEntries + UInt64(rows.count) <= 220_000 else { throw ScannerProtocolFailure.bounds }
            let records = try rows.map(record)
            receivedEntries += UInt64(records.count)
            return .records(records)
        case "issue":
            guard detailedIssues < 100, let code = frame["code"] as? String, fixedCode(code),
                  let error = integer(frame["errno"]), error >= 0, let errno = Int32(exactly: error) else {
                throw ScannerProtocolFailure.record
            }
            detailedIssues += 1
            return .issue(code: code, error: errno)
        case "summary":
            guard let complete = boolean(frame["complete"]), let reason = frame["reason"] as? String, fixedCode(reason),
                  let entries = unsigned(frame["entries"]), entries == receivedEntries,
                  let errors = unsigned(frame["errors"]), errors >= UInt64(detailedIssues),
                  let elapsed = unsigned(frame["elapsed_ns"]),
                  !complete || (reason == "complete" && errors == 0) else { throw ScannerProtocolFailure.summary }
            let kinds = ["regular_entries", "directory_entries", "symlink_entries", "other_entries"]
            var sum: UInt64 = 0
            var kindCounts: [UInt64] = []
            for key in kinds {
                guard let count = unsigned(frame[key]) else { throw ScannerProtocolFailure.summary }
                let (value, overflow) = sum.addingReportingOverflow(count)
                guard !overflow else { throw ScannerProtocolFailure.summary }
                sum = value
                kindCounts.append(count)
            }
            guard sum == entries, let objects = unsigned(frame["objects"]), objects <= kindCounts[0] else { throw ScannerProtocolFailure.summary }
            let fields = ["data_logical", "all_logical", "data_allocated", "all_allocated"]
            func totals(_ key: String) throws -> [UInt64] {
                guard let values = frame[key] as? [String: Any], values.count == fields.count else { throw ScannerProtocolFailure.summary }
                return try fields.map {
                    guard let value = unsigned(values[$0]) else { throw ScannerProtocolFailure.summary }
                    return value
                }
            }
            let namespace = try totals("entry_totals"), object = try totals("object_totals")
            receivedTerminal = true
            return .terminal(ScannerTerminal(complete: complete, reason: reason, entries: entries,
                peakResidentBytes: unsigned(frame["peak_rss"]), elapsedNanoseconds: elapsed,
                kindCounts: kindCounts, namespaceTotals: namespace, objectTotals: object, objectCount: objects,
                errors: errors))
        default: throw ScannerProtocolFailure.envelope
        }
    }

    func finish() throws {
        guard receivedHeader, receivedTerminal else { throw ScannerProtocolFailure.prematureEnd }
    }

    private func record(_ row: [String: Any]) throws -> AnalysisEntryObservation {
        guard let encoded = row["relative_b64"] as? String, let path = Data(base64Encoded: encoded),
              path.count <= 8192, path.base64EncodedString() == encoded,
              let parentText = row["parent_b64"] as? String, let parent = Data(base64Encoded: parentText),
              parent.base64EncodedString() == parentText,
              let nameText = row["name_b64"] as? String, let name = Data(base64Encoded: nameText),
              name.base64EncodedString() == nameText, !name.isEmpty, !name.contains(0), !name.contains(47),
              let kindText = row["type"] as? String, let error = integer(row["errno"]),
              error >= 0, let errno = Int32(exactly: error),
              let returned = row["returned"] as? [String: Any],
              returned.count == 5 else { throw ScannerProtocolFailure.record }
        var reconstructed = parent
        if !parent.isEmpty { reconstructed.append(47) }
        reconstructed.append(name)
        guard reconstructed == path else { throw ScannerProtocolFailure.record }
        guard let common = unsigned(returned["common"]), common & ~UInt64(2_718_171_147) == 0,
              common & 0x8000_0001 == 0x8000_0001,
              unsigned(returned["volume"]) == 0,
              let directory = unsigned(returned["directory"]), directory & ~UInt64(5) == 0,
              let file = unsigned(returned["file"]), file & ~UInt64(1543) == 0,
              unsigned(returned["fork"]) == 0,
              errno == 0 || common & 0x2000_0000 != 0 else { throw ScannerProtocolFailure.record }
        let kind: AnalysisEntryKind
        switch kindText {
        case "regular": kind = .regularFile
        case "directory": kind = .directory
        case "symlink": kind = .symbolicLink
        case "other": kind = .other
        case "unknown": kind = .unknown
        default: throw ScannerProtocolFailure.record
        }
        guard common & 8 != 0 || kind == .unknown else { throw ScannerProtocolFailure.record }
        let dev = try optionalUnsigned(row["dev"])
        let ino = try optionalUnsigned(row["ino"])
        let identity: AnalysisMetadata<AnalysisObjectIdentity>
        if errno != 0 { identity = .failed(code: errno) }
        else if let dev, let ino { identity = .returned(.init(device: dev, inode: ino)) }
        else { identity = .notReturned }
        let links = try optionalUnsigned(row["nlink"])
        let flagsValue = try optionalUnsigned(row["flags"])
        // A requested field is not necessarily returned. Keep the producer's
        // masks authoritative at this boundary too, so an unsupported/default
        // value cannot be promoted into a known zero by a malformed stream.
        guard (common & 2 != 0) == (dev != nil), (common & 0x0200_0000 != 0) == (ino != nil),
              (common & 0x40000 != 0) == (flagsValue != nil),
              (directory & 1 != 0 || file & 1 != 0) == (links != nil),
              flagsValue == nil || UInt32(exactly: flagsValue!) != nil else { throw ScannerProtocolFailure.record }
        let flags: AnalysisMetadata<UInt32> = errno != 0 ? .failed(code: errno)
            : flagsValue.map { .returned(UInt32($0)) } ?? .notReturned
        return AnalysisEntryObservation(relativePath: path, kind: kind, identity: identity,
            linkCount: errno != 0 ? .failed(code: errno) : links.map { .returned($0) } ?? .notReturned,
            flags: flags, bytes: AnalysisByteObservation(
                dataLogical: try metric(row["data_logical"], errno: errno, wasReturned: file & 0x200 != 0),
                allForkLogical: try metric(row["all_logical"], errno: errno, wasReturned: file & 2 != 0),
                dataAllocated: try metric(row["data_allocated"], errno: errno, wasReturned: file & 0x400 != 0),
                allForkAllocated: try metric(row["all_allocated"], errno: errno, wasReturned: file & 4 != 0)))
    }

    private func metric(_ object: Any?, errno: Int32, wasReturned: Bool) throws -> AnalysisMetadata<UInt64> {
        guard let value = object as? [String: Any], let state = value["state"] as? String else { throw ScannerProtocolFailure.record }
        switch state {
        case "returned":
            guard errno == 0, wasReturned, value.count == 2, let bytes = unsigned(value["value"]) else { throw ScannerProtocolFailure.record }
            return .returned(bytes)
        case "not_returned":
            guard errno == 0, !wasReturned, value.count == 1 else { throw ScannerProtocolFailure.record }
            return .notReturned
        case "error":
            guard errno != 0, value.count == 1 else { throw ScannerProtocolFailure.record }
            return .failed(code: errno)
        default: throw ScannerProtocolFailure.record
        }
    }

    private func optionalUnsigned(_ object: Any?) throws -> UInt64? {
        if object is NSNull { return nil }
        guard let result = unsigned(object) else { throw ScannerProtocolFailure.record }
        return result
    }
    private func unsigned(_ object: Any?) -> UInt64? {
        guard let text = object as? String, !text.isEmpty, text.utf8.count <= 20,
              text == "0" || text.first != "0", text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt64(text)
    }
    private func integer(_ object: Any?) -> Int? {
        guard let number = object as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              String(cString: number.objCType) != "d", String(cString: number.objCType) != "f" else { return nil }
        return Int(number.stringValue)
    }
    private func boolean(_ object: Any?) -> Bool? {
        guard let number = object as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private func fixedCode(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 64 && text.utf8.allSatisfy { $0 == 95 || (97...122).contains($0) || (48...57).contains($0) }
    }
}
