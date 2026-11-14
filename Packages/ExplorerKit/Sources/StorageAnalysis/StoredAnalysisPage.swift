import Foundation

enum StoredAnalysisRowOrder: Sendable { case ordinal, rawName, independentlyValidated }

/// Pure bounded protocol validation. Filename order is byte-exact and does not
/// normalize names, infer UTF8 or require ordinal IDs. Source access stays in
/// the worker; the cursor is resolved in its sealed parent namespace.
enum StoredAnalysisPage {
    static func decode(_ frames: [[String: Any]], parent: UInt64, cursor: UInt64,
                       order: StoredAnalysisRowOrder) throws -> [StoredAnalysisRow] {
        guard parent < Int64.max, cursor < Int64.max, frames.count <= 5 else { throw StorageScanFailure.invalidOutput }
        var rows: [StoredAnalysisRow] = [], ids = Set<UInt64>(), ended = false
        for frame in frames {
            guard !ended else { throw StorageScanFailure.invalidOutput }
            if frame["kind"] as? String == "end" {
                guard let count = strictInteger(frame["count"]), count == rows.count else { throw StorageScanFailure.invalidOutput }
                if order == .rawName {
                    guard frame["order"] as? String == "raw_name",
                          try storedNumber(frame["parent"]) == parent,
                          try storedNumber(frame["after"]) == cursor else { throw StorageScanFailure.invalidOutput }
                    let previous = try storedBlob(frame["after_name"])
                    guard cursor == 0 ? previous.isEmpty : validName(previous),
                          rows.first.map({ previous.lexicographicallyPrecedes($0.rawName) }) ?? true else { throw StorageScanFailure.invalidOutput }
                } else if frame["order"] != nil { throw StorageScanFailure.invalidOutput }
                ended = true; continue
            }
            guard frame["kind"] as? String == "rows", let values = frame["rows"] as? [[String: Any]],
                  (1...64).contains(values.count), rows.count + values.count <= 256 else { throw StorageScanFailure.invalidOutput }
            for value in values {
                let id = try storedNumber(value["id"]), name = try storedBlob(value["name"])
                guard id > parent, id < Int64.max, id != cursor, ids.insert(id).inserted,
                      validName(name), let kind = strictInteger(value["type"]), (0..<5).contains(kind) else { throw StorageScanFailure.invalidOutput }
                if order == .ordinal {
                    guard id > (rows.last?.id ?? cursor) else { throw StorageScanFailure.invalidOutput }
                } else if order == .rawName, let previous = rows.last?.rawName, !previous.lexicographicallyPrecedes(name) {
                    throw StorageScanFailure.invalidOutput
                }
                let payload = try storedBlob(value["payload"], length: 52)
                let own = try StoredAnalysisValue(kind: kind, payload: payload)
                let aggregate: StoredAnalysisValue
                if value["value"] is NSNull { guard kind != 1 else { throw StorageScanFailure.invalidOutput }; aggregate = own }
                else { guard kind == 1 else { throw StorageScanFailure.invalidOutput }; aggregate = try .init(encoded: storedBlob(value["value"], length: 140)) }
                let kinds: [AnalysisEntryKind] = [.regularFile, .directory, .symbolicLink, .other, .unknown]
                rows.append(.init(id: id, rawName: name, kind: kinds[kind], value: aggregate))
            }
        }
        guard ended else { throw StorageScanFailure.invalidOutput }; return rows
    }
    static func validName(_ name: Data) -> Bool {
        (1...255).contains(name.count) && !name.contains(0) && !name.contains(47)
            && name != Data([46]) && name != Data([46, 46])
    }
}
