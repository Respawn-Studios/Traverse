import CoreFoundation
import Foundation

public enum StoredAnalysisSortOrder: Int, CaseIterable, Sendable {
    case nameAscending, nameDescending, logicalDescending, logicalAscending, allocatedDescending, allocatedAscending
    public var title: String {
        switch self {
        case .nameAscending: "Name · ascending"
        case .nameDescending: "Name · descending"
        case .logicalDescending: "Largest logical size"
        case .logicalAscending: "Smallest logical size"
        case .allocatedDescending: "Largest allocation"
        case .allocatedAscending: "Smallest allocation"
        }
    }
    var wireName: String { ["name_ascending", "name_descending", "logical_descending", "logical_ascending", "allocated_descending", "allocated_ascending"][rawValue] }
    var metric: AnalysisByteMetric? { rawValue < 2 ? nil : rawValue < 4 ? .dataLogical : .allForkAllocated }
    var ascending: Bool { self == .nameAscending || self == .logicalAscending || self == .allocatedAscending }
    func amount(_ row: StoredAnalysisRow) -> UInt64? {
        guard let metric, row.kind == .regularFile || row.kind == .directory else { return nil }
        let value = row.value.bytes[metric], files = row.value.counts.regularFiles
        guard !value.overflowed, files == 0 || value.notReturnedCount + value.failedCount < files else { return nil }
        return value.knownBytes
    }
    func precedes(_ a: Key, _ b: Key) -> Bool {
        if metric != nil {
            if let left = a.amount, let right = b.amount {
                if left != right { return ascending ? left < right : left > right }
            } else if a.amount != b.amount { return a.amount != nil }
        }
        if a.name != b.name {
            return self == .nameDescending ? b.name.lexicographicallyPrecedes(a.name) : a.name.lexicographicallyPrecedes(b.name)
        }
        return a.id < b.id
    }
    struct Key { let id: UInt64, name: Data, amount: UInt64? }
    func key(_ row: StoredAnalysisRow) -> Key { .init(id: row.id, name: row.rawName, amount: amount(row)) }
}

public struct StoredAnalysisSortedPage: Sendable {
    public let rows: [StoredAnalysisRow]
    public let hasMore: Bool

    static func decode(_ frames: [[String: Any]], parent: UInt64, cursor: UInt64,
                       order: StoredAnalysisSortOrder) throws -> Self {
        func boolean(_ value: Any?) throws -> Bool {
            guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw StorageScanFailure.invalidOutput }
            return value.boolValue
        }
        guard let end = frames.last, end["kind"] as? String == "end", strictInteger(end["sorted_page_revision"]) == 1,
              end["order"] as? String == order.wireName, try storedNumber(end["parent"]) == parent,
              try storedNumber(end["after"]) == cursor else { throw StorageScanFailure.invalidOutput }
        let previousName = try storedBlob(end["after_name"]), previousUnknown = try boolean(end["after_unknown"])
        let more = try boolean(end["has_more"])
        let previousAmount: UInt64?
        if end["after_bytes"] is NSNull { previousAmount = nil }
        else { previousAmount = try storedNumber(end["after_bytes"]) }
        if cursor == 0 {
            guard previousName.isEmpty, previousAmount == nil, !previousUnknown else { throw StorageScanFailure.invalidOutput }
        } else {
            guard StoredAnalysisPage.validName(previousName),
                  order.metric == nil ? previousAmount == nil && !previousUnknown : previousUnknown == (previousAmount == nil) else { throw StorageScanFailure.invalidOutput }
        }
        // Reuse exact raw-name/kind/payload/aggregate/cardinality validation.
        // The sorted-specific ordering and cursor proof follows immediately.
        let normalized = Array(frames.dropLast()) + [["kind": "end", "count": end["count"] as Any]]
        let rows = try StoredAnalysisPage.decode(normalized, parent: parent, cursor: cursor, order: .independentlyValidated)
        guard !more || rows.count == 256, Set(rows.map(\.rawName)).count == rows.count else { throw StorageScanFailure.invalidOutput }
        for index in rows.indices.dropFirst() {
            guard order.precedes(order.key(rows[index - 1]), order.key(rows[index])) else { throw StorageScanFailure.invalidOutput }
        }
        if cursor != 0, let first = rows.first {
            let after = StoredAnalysisSortOrder.Key(id: cursor, name: previousName, amount: previousAmount)
            guard order.precedes(after, order.key(first)) else { throw StorageScanFailure.invalidOutput }
        }
        return .init(rows: rows, hasMore: more)
    }
}

extension StorageAnalysisResult {
    public func sortedPage(parent: UInt64 = 0, after cursor: UInt64 = 0,
                           order: StoredAnalysisSortOrder = .logicalDescending) async throws -> StoredAnalysisSortedPage {
        guard supportsSortedPages else { throw StorageScanFailure.invalidOutput }
        return try await .decode(query("sorted-page", parent: parent, cursor: cursor, facet: order.rawValue),
            parent: parent, cursor: cursor, order: order)
    }
}
