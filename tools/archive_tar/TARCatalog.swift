import Foundation
#if !TAR_PARSER_STANDALONE
import ExplorerCore
#endif

public struct TARFolderID: Hashable, Sendable { internal let owner: UUID; internal let node: Int }
public struct TARItemID: Hashable, Sendable { internal let owner: UUID; internal let node: Int }
public struct TARArchiveItem: Identifiable, Sendable {
    public let id: TARItemID
    public let name: String, path: String
    public let kind: TARMemberKind
    public let logicalBytes: UInt64
    public let folder: TARFolderID?
}
public struct TARArchiveSummary: Sendable {
    public let records: Int, files: Int, folders: Int, blockedMembers: Int
    public let logicalBytes: UInt64
    public let metadataBytes: Int
}
public struct TARArchiveOrder: Equatable, Sendable {
    public enum Field: String, CaseIterable, Sendable { case name, size, kind }
    public let field: Field
    public let descending: Bool
    public init(_ field: Field = .name, descending: Bool = false) { self.field = field; self.descending = descending }
}
internal struct TARCatalogNode: Sendable {
    let name: String, parent: Int?
    let kind: TARMemberKind
    let literal: String, symbols: String
    var children = [Int]()
    var record: TARRecord?
    var logical: UInt64 = 0
}
internal struct TARCatalogStorage: Sendable {
    let nodes: [TARCatalogNode]
    let summary: TARArchiveSummary
    let witness: Data
}
internal enum TARCatalogBuilder {
    private struct Key: Hashable { let parent: Int; let folded: String }
    static func build(_ parsed: TARParsedDirectory, limits: TARReadLimits = .init(), check: () throws -> Void) throws -> TARCatalogStorage {
        guard limits.nodes > 0, limits.searchBytes >= 0 else { throw TARArchiveFailure.limited }
        var nodes = [TARCatalogNode(name: "Archive", parent: nil, kind: .directory, literal: "", symbols: "")]
        var lookup = [Key:Int](), searchBytes = 0
        let locale = Locale(identifier: "en_US_POSIX")
        for record in parsed.records {
            try check(); var parent = 0
            let parts = record.path.split(separator: "/").map(String.init)
            for (position,part) in parts.enumerated() {
                try check()
                let last = position == parts.count - 1, kind: TARMemberKind = last ? record.kind : .directory
                let key = Key(parent: parent, folded: part.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: locale))
                let index: Int
                if let old = lookup[key] {
                    guard nodes[old].name.utf8.elementsEqual(part.utf8), kind == .directory, nodes[old].kind == .directory,
                          !last || nodes[old].record == nil else { throw TARArchiveFailure.ambiguousNames }
                    index = old
                } else {
                    guard nodes.count < limits.nodes else { throw TARArchiveFailure.limited }
                    let literal = FilenameMatching.folded(part, symbolTolerant: false), symbols = FilenameMatching.folded(part, symbolTolerant: true)
                    guard literal.utf8.count + symbols.utf8.count <= limits.searchBytes - searchBytes else { throw TARArchiveFailure.limited }
                    searchBytes += literal.utf8.count + symbols.utf8.count
                    index = nodes.count; lookup[key] = index
                    nodes.append(.init(name: part, parent: parent, kind: kind, literal: literal, symbols: symbols)); nodes[parent].children.append(index)
                }
                if last { nodes[index].record = record; nodes[index].logical = record.bytes }
                parent = index
            }
        }
        for index in nodes.indices {
            try check()
            nodes[index].children = try TARCatalogOrdering.ids(nodes[index].children, nodes: nodes, order: .init(), check: check)
        }
        for index in nodes.indices.reversed() where index != 0 {
            try check()
            guard let parent = nodes[index].parent else { throw TARArchiveFailure.malformed }
            let (bytes,overflow) = nodes[parent].logical.addingReportingOverflow(nodes[index].logical)
            guard !overflow, bytes <= limits.logicalBytes else { throw TARArchiveFailure.limited }; nodes[parent].logical = bytes
        }
        let summary = TARArchiveSummary(records: parsed.records.count, files: nodes.filter { $0.kind == .file }.count,
            folders: nodes.filter { $0.kind == .directory }.count - 1,
            blockedMembers: nodes.filter { $0.kind != .file && $0.kind != .directory }.count,
            logicalBytes: nodes[0].logical, metadataBytes: parsed.metadataBytes)
        return .init(nodes: nodes, summary: summary, witness: parsed.witness)
    }
}
internal enum TARCatalogOrdering {
    static func ids(_ ids: [Int], nodes: [TARCatalogNode], order: TARArchiveOrder, check: () throws -> Void) throws -> [Int] {
        let locale = Locale(identifier: "en_US_POSIX")
        return try ids.sorted { a,b in
            try check()
            let lhs = nodes[a], rhs = nodes[b]
            if (lhs.kind == .directory) != (rhs.kind == .directory) { return lhs.kind == .directory }
            return autoreleasepool {
                let name = lhs.name.compare(rhs.name, options: [.caseInsensitive,.numeric], locale: locale)
                let primary: ComparisonResult
                switch order.field {
                case .name: primary = name
                case .size: primary = lhs.logical == rhs.logical ? .orderedSame : lhs.logical < rhs.logical ? .orderedAscending : .orderedDescending
                case .kind: primary = lhs.kind.rawValue.compare(rhs.kind.rawValue, locale: locale)
                }
                if primary != .orderedSame { return primary == (order.descending ? .orderedDescending : .orderedAscending) }
                if name != .orderedSame { return name == .orderedAscending }
                if !lhs.name.utf8.elementsEqual(rhs.name.utf8) { return lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8) }
                return a < b
            }
        }
    }
}
