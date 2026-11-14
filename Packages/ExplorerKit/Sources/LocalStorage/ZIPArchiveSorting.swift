import Foundation

/// Recorded ZIP metadata only. This order conveys no file or operation authority.
public struct ZIPArchiveOrder: Equatable, Sendable {
    public enum Field: String, CaseIterable, Sendable { case name, logical, modified, packed, method }
    public let field: Field
    public let descending: Bool
    public init(_ field: Field = .name, descending: Bool = false) {
        self.field = field; self.descending = descending
    }
}

internal enum ZIPCatalogOrdering {
    private static let locale = Locale(identifier: "en_US_POSIX")
    static func ids(_ ids: [Int], nodes: [ZIPCatalogNode], order: ZIPArchiveOrder?,
        check: () throws -> Void = { try Task.checkCancellation() }) throws -> [Int] {
        try check()
        guard let order else { return ids }
        return try ids.sorted { a,b in
            try check()
            let lhs = nodes[a], rhs = nodes[b]
            if (lhs.kind == .directory) != (rhs.kind == .directory) { return lhs.kind == .directory }
            if order.field == .modified, let dateOrder = ArchiveMemberModification.order(lhs.modification,
                rhs.modification, descending: order.descending) { return dateOrder }
            // NSString comparison creates temporary native objects. Bound their
            // lifetime for large metadata-only catalogs as well as UI pages.
            return autoreleasepool {
                let primary: ComparisonResult
                switch order.field {
                case .name: primary = compareNames(lhs.name,rhs.name)
                case .logical: primary = compare(lhs.logical,rhs.logical)
                case .modified: primary = .orderedSame
                case .packed: primary = compare(lhs.packed,rhs.packed)
                case .method: primary = compareNames(methodName(lhs.method),methodName(rhs.method))
                }
                if primary != .orderedSame { return primary == (order.descending ? .orderedDescending : .orderedAscending) }
                let name = order.field == .name ? ComparisonResult.orderedSame : compareNames(lhs.name,rhs.name)
                if name != .orderedSame { return name == .orderedAscending }
                if !lhs.name.utf8.elementsEqual(rhs.name.utf8) { return lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8) }
                // Equal basenames from different parents retain a deterministic
                // immutable-node tie, without constructing every full path.
                return a < b
            }
        }
    }
    private static func compare<T: Comparable>(_ a: T,_ b: T) -> ComparisonResult {
        a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
    }
    private static func compareNames(_ a: String,_ b: String) -> ComparisonResult {
        a.compare(b,options:[.caseInsensitive,.numeric],locale:locale)
    }
    private static func methodName(_ method: UInt16?) -> String {
        switch method { case 0: "Stored"; case 8: "Deflate"; case .none: "Folder"; case let n?: "Method \(n)" }
    }
}
