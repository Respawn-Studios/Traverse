import ExplorerCore
import Foundation

internal struct ZIPCatalogBuilder {
    private struct Key: Hashable { let parent: Int; let name: String }
    let limits: ZIPReadLimits
    private var nodes: [ZIPCatalogNode] = [.init(name: "Archive", parent: nil, kind: .directory)]
    private var lookup: [Key: Int] = [:]
    private var names = 0, searchBytes = 0, encrypted = 0, links = 0, special = 0
    init(limits: ZIPReadLimits) { self.limits = limits }
    mutating func add(name: String, kind: ZIPMemberKind, logical: UInt64, packed: UInt64, method: UInt16, encrypted: Bool,
                      centralEntryOffset: UInt64? = nil, modification: ArchiveMemberModification? = nil) throws {
        guard !name.isEmpty, name.utf8.count <= limits.pathBytes, names <= limits.nameBytes - name.utf8.count else { throw ZIPArchiveFailure.limited }
        names += name.utf8.count
        guard !name.hasPrefix("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || [0x061c, 0x200e, 0x200f].contains($0.value)
                || (0x202a...0x202e).contains($0.value) || (0x2066...0x2069).contains($0.value)
        }) else { throw ZIPArchiveFailure.unsafeName }
        var parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if kind == .directory && parts.last == "" { parts.removeLast() }
        guard !parts.isEmpty, parts.count <= limits.depth else { throw ZIPArchiveFailure.limited }
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !(parts[0].utf8.count >= 2 && parts[0].utf8.dropFirst().first == 58) else { throw ZIPArchiveFailure.unsafeName }
        var parent = 0
        for (position, part) in parts.enumerated() {
            let last = position == parts.count - 1, expected: ZIPMemberKind = last ? kind : .directory
            let key = Key(parent: parent, name: part)
            let index: Int
            if let old = lookup[key] {
                guard nodes[old].name.utf8.elementsEqual(part.utf8), expected == .directory,
                      nodes[old].kind == .directory, !last || !nodes[old].explicit else { throw ZIPArchiveFailure.ambiguousNames }
                index = old
            } else {
                guard nodes.count < limits.nodes else { throw ZIPArchiveFailure.limited }
                let literal = FilenameMatching.folded(part, symbolTolerant: false), symbols = FilenameMatching.folded(part, symbolTolerant: true)
                guard searchBytes <= limits.searchBytes - literal.utf8.count - symbols.utf8.count else { throw ZIPArchiveFailure.limited }
                searchBytes += literal.utf8.count + symbols.utf8.count
                index = nodes.count; nodes.append(.init(name: part, parent: parent, kind: expected, literalKey: literal, symbolKey: symbols)); lookup[key] = index
                nodes[parent].children.append(index)
            }
            if last {
                nodes[index].explicit = true; nodes[index].logical = logical; nodes[index].packed = packed
                nodes[index].method = expected == .directory ? nil : method; nodes[index].encrypted = encrypted
                nodes[index].centralEntryOffset = centralEntryOffset
                nodes[index].modification = modification
            }
            parent = index
        }
        if encrypted { self.encrypted += 1 }; if kind == .symbolicLink { links += 1 }; if kind == .special { special += 1 }
    }
    mutating func finish(records: Int, centralBytes: Int, zip64: Bool, centralOffset: UInt64? = nil,
                         directoryWitness: ZIPDirectoryWitness? = nil, cancelled: () -> Bool) throws -> ZIPCatalogStorage {
        var caseConflicts = 0
        let locale = Locale(identifier: "en_US_POSIX")
        for index in nodes.indices {
            guard !cancelled() else { throw ZIPArchiveFailure.stopped }
            let children = nodes[index].children.sorted { a, b in
                let lhs = nodes[a], rhs = nodes[b]
                if (lhs.kind == .directory) != (rhs.kind == .directory) { return lhs.kind == .directory }
                let order = lhs.name.compare(rhs.name, options: [.caseInsensitive, .numeric], locale: locale)
                return order == .orderedSame ? lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8) : order == .orderedAscending
            }
            nodes[index].children = children
            var seen = Set<String>()
            for child in children {
                let folded = nodes[child].name.folding(options: [.caseInsensitive], locale: locale)
                if !seen.insert(folded).inserted { caseConflicts += 1 }
            }
        }
        for index in nodes.indices.reversed() where index != 0 {
            guard let parent = nodes[index].parent else { throw ZIPArchiveFailure.malformed }
            let (logical, a) = nodes[parent].logical.addingReportingOverflow(nodes[index].logical)
            let (packed, b) = nodes[parent].packed.addingReportingOverflow(nodes[index].packed)
            guard !a && !b else { throw ZIPArchiveFailure.malformed }
            nodes[parent].logical = logical; nodes[parent].packed = packed
        }
        let summary = ZIPArchiveSummary(records: records, files: nodes.filter { $0.kind != .directory }.count,
            folders: nodes.filter { $0.kind == .directory }.count - 1, logicalBytes: nodes[0].logical,
            packedBytes: nodes[0].packed, centralBytes: centralBytes, nameBytes: names,
            encryptedMembers: encrypted, symbolicLinks: links, specialMembers: special, caseConflicts: caseConflicts, isZIP64: zip64)
        return .init(nodes: nodes, summary: summary, centralOffset: centralOffset, directoryWitness: directoryWitness)
    }
}
