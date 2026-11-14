import ExplorerCore
import Foundation

public enum ZIPArchiveFailure: Error, Equatable, Sendable {
    case malformed, unsupported, unsafeName, ambiguousNames, unsupportedEncoding
    case limited, unavailable, changed, stopped, busy, closed, invalidFolder, invalidFilter
}

public enum ZIPMemberKind: String, Sendable { case file, directory, symbolicLink, special }

/// Virtual identity only. Never a local URL, access grant or extraction token.
public struct ZIPFolderID: Hashable, Sendable {
    internal let owner: UUID
    internal let node: Int
}
public struct ZIPItemID: Hashable, Sendable {
    internal let owner: UUID
    internal let node: Int
}
public struct ZIPArchiveItem: Sendable, Identifiable {
    public let id: ZIPItemID
    public let name: String
    public let path: String
    public let kind: ZIPMemberKind
    public let logicalBytes: UInt64
    public let packedBytes: UInt64
    public let method: UInt16?
    public let modification: ArchiveMemberModification?
    public let isEncrypted: Bool
    public let folder: ZIPFolderID?
    public var methodName: String {
        switch method { case 0: "Stored"; case 8: "Deflate"; case .none: "Folder"; case let value?: "Method \(value)" }
    }
}
public struct ZIPBreadcrumb: Sendable {
    public let folder: ZIPFolderID
    public let name: String
}
public struct ZIPDirectoryPage: Sendable {
    public let folder: ZIPFolderID
    public let breadcrumbs: [ZIPBreadcrumb]
    public let items: [ZIPArchiveItem]
    public let offset: Int
    public let total: Int
    public var hasNext: Bool { offset + items.count < total }
}
/// A name-only view across one immutable archive snapshot. This is not a local
/// folder, a file-content index or a grant to perform an operation.
public struct ZIPNameSearchPage: Sendable {
    public let items: [ZIPArchiveItem]
    public let offset: Int
    public let total: Int
    public var hasNext: Bool { offset + items.count < total }
}
public struct ZIPItemLocation: Sendable {
    public let folder: ZIPFolderID
    public let offset: Int
}
public struct ZIPArchiveSummary: Sendable {
    public let records: Int
    public let files: Int
    public let folders: Int
    public let logicalBytes: UInt64
    public let packedBytes: UInt64
    public let centralBytes: Int
    public let nameBytes: Int
    public let encryptedMembers: Int
    public let symbolicLinks: Int
    public let specialMembers: Int
    public let caseConflicts: Int
    public let isZIP64: Bool
}

internal struct ZIPReadLimits: Sendable {
    var members = 100_000
    var nodes = 128_000
    var centralBytes = 32 * 1_024 * 1_024
    var nameBytes = 8 * 1_024 * 1_024
    var searchBytes = 16 * 1_024 * 1_024
    var pathBytes = 4_096
    var depth = 64
}
internal struct ZIPCatalogNode: Sendable {
    let name: String
    let parent: Int?
    var kind: ZIPMemberKind
    var literalKey = ""
    var symbolKey = ""
    var explicit = false
    var children: [Int] = []
    var logical: UInt64 = 0
    var packed: UInt64 = 0
    var method: UInt16?
    var modification: ArchiveMemberModification?
    var encrypted = false
    var centralEntryOffset: UInt64?
}
internal struct ZIPCatalogStorage: Sendable {
    let nodes: [ZIPCatalogNode]
    let summary: ZIPArchiveSummary
    let centralOffset: UInt64?
    let directoryWitness: ZIPDirectoryWitness?
    init(nodes: [ZIPCatalogNode], summary: ZIPArchiveSummary, centralOffset: UInt64? = nil,
         directoryWitness: ZIPDirectoryWitness? = nil) {
        self.nodes = nodes; self.summary = summary; self.centralOffset = centralOffset
        self.directoryWitness = directoryWitness
    }
}

/// Holds names and declared facts in session memory. All hierarchy work stays
/// off the main actor; only256 visible rows cross into native presentation.
public actor ZIPArchiveSession {
    public nonisolated let root: ZIPFolderID
    public nonisolated let summary: ZIPArchiveSummary
    private var storage: ZIPCatalogStorage?
    private var cached: (folder: Int, filter: String, symbols: Bool, order: ZIPArchiveOrder?, ids: [Int])?
    private var searched: (query: String, symbols: Bool, order: ZIPArchiveOrder?, ids: [Int])?
    private let binding: ZIPSourceBinding?
    internal init(_ storage: ZIPCatalogStorage, binding: ZIPSourceBinding? = nil) {
        root = ZIPFolderID(owner: UUID(), node: 0); summary = storage.summary; self.storage = storage
        self.binding = binding
    }
    /// A retained catalog can be borrowed again only while its exact source
    /// observation matches. The bounded filesystem probe runs off the caller.
    public func matchesCurrentSourceObservation() async -> Bool {
        guard storage != nil, let binding else { return false }
        guard await PinnedLocalFileSource.isCurrentObservation(at: binding.source, observed: binding.stamp) else { return false }
        return storage != nil && !Task.isCancelled
    }
    internal func contentCheckBinding() throws -> ZIPSourceBinding {
        try Task.checkCancellation()
        guard storage != nil else { throw ZIPArchiveFailure.closed }
        guard let binding else { throw ZIPArchiveFailure.unavailable }
        return binding
    }
    public func selectionForExtraction(_ ids: Set<ZIPItemID>) throws -> ZIPExtractionSelection {
        guard let storage else { throw ZIPArchiveFailure.closed }
        guard let binding, !ids.isEmpty, ids.count <= 1_024 else { throw ZIPArchiveFailure.invalidFolder }
        var selected = Set<Int>()
        for id in ids {
            try Task.checkCancellation()
            guard id.owner == root.owner, id.node > 0, storage.nodes.indices.contains(id.node),
                  [.file, .directory].contains(storage.nodes[id.node].kind) else { throw ZIPArchiveFailure.invalidFolder }
            selected.insert(id.node)
        }
        var roots: [ZIPExtractionSelection.Root] = []
        for index in selected.sorted() {
            try Task.checkCancellation()
            var cursor = storage.nodes[index].parent, covered = false
            while let ancestor = cursor, ancestor != 0 {
                if selected.contains(ancestor) { covered = true; break }; cursor = storage.nodes[ancestor].parent
            }
            if !covered { roots.append(.init(path: path(index, nodes: storage.nodes), kind: storage.nodes[index].kind)) }
        }
        return .init(source: binding.source, stamp: binding.stamp, roots: roots)
    }
    /// A destination folder from this live catalog, including the root.
    public func selectionForMemberAddition(_ id: ZIPFolderID) throws -> ZIPMemberAdditionSelection {
        guard let storage, let binding, id.owner == root.owner,
              storage.nodes.indices.contains(id.node), storage.nodes[id.node].kind == .directory else {
            throw ZIPMemberAdditionFailure.invalidSelection
        }
        try Task.checkCancellation()
        return .init(virtualFolder: id.node == 0 ? "" : path(id.node, nodes: storage.nodes), binding: binding)
    }
    /// One file or folder from this live catalog. A folder binds every
    /// explicit record in its subtree, even when the folder itself is implied.
    public func selectionForMemberRename(_ id: ZIPItemID) throws -> ZIPMemberRenameSelection {
        guard let storage, let binding, id.owner == root.owner, id.node > 0,
              storage.nodes.indices.contains(id.node) else { throw ZIPMemberRenameFailure.invalidMember }
        let node = storage.nodes[id.node]
        let target: ZIPMemberRenameSelection.Target
        switch node.kind {
        case .file:
            guard let position = node.centralEntryOffset else { throw ZIPMemberRenameFailure.invalidMember }
            target = .regular(centralPosition: position)
        case .directory:
            guard storage.nodes.count <= 20_000, storage.summary.records <= 20_000 else {
                throw ZIPMemberRenameFailure.limitReached
            }
            var records: [ZIPCopyBoundRecord] = [], stack = [id.node]
            while let index = stack.popLast() {
                try Task.checkCancellation()
                let descendant = storage.nodes[index]
                guard descendant.kind == .file || descendant.kind == .directory else {
                    throw ZIPMemberRenameFailure.unsupportedArchive
                }
                if descendant.explicit {
                    guard let position = descendant.centralEntryOffset else {
                        throw ZIPMemberRenameFailure.invalidMember
                    }
                    let suffix = descendant.kind == .directory ? "/" : ""
                    records.append(.init(archivePath: path(index, nodes: storage.nodes) + suffix,
                                         centralPosition: position))
                }
                stack.append(contentsOf: descendant.children)
            }
            records.sort { $0.centralPosition < $1.centralPosition }
            guard !records.isEmpty, Set(records.map(\.centralPosition)).count == records.count else {
                throw ZIPMemberRenameFailure.invalidMember
            }
            target = .directory(records: records)
        default: throw ZIPMemberRenameFailure.invalidMember
        }
        let archivePath = path(id.node, nodes: storage.nodes)
        let virtualParent = archivePath.split(separator: "/").dropLast().joined(separator: "/")
        return .init(archivePath: archivePath, currentName: node.name,
                     virtualParent: virtualParent, binding: binding, target: target)
    }
    /// Effective file and folder roots from one live catalog. Selected
    /// descendants of selected folders collapse to that folder. The token
    /// binds every explicit record affected by a group edit.
    public func selectionForMemberChanges(_ ids: Set<ZIPItemID>) throws -> ZIPMemberSetSelection {
        guard let storage, let binding, (1...128).contains(ids.count) else {
            throw ZIPMemberRemovalFailure.invalidSelection
        }
        guard storage.nodes.count <= 20_000, storage.summary.records <= 20_000 else {
            throw ZIPMemberRemovalFailure.limitReached
        }
        var selected = Set<Int>()
        for id in ids {
            try Task.checkCancellation()
            guard id.owner == root.owner, id.node > 0, storage.nodes.indices.contains(id.node) else {
                throw ZIPMemberRemovalFailure.invalidSelection
            }
            let node = storage.nodes[id.node]
            guard node.kind == .directory || node.kind == .file && node.explicit && node.centralEntryOffset != nil else {
                throw ZIPMemberRemovalFailure.invalidSelection
            }
            selected.insert(id.node)
        }
        var effective: [Int] = []
        for index in selected.sorted() {
            try Task.checkCancellation()
            var parent = storage.nodes[index].parent, covered = false
            while let ancestor = parent, ancestor != 0 {
                if selected.contains(ancestor) { covered = true; break }
                parent = storage.nodes[ancestor].parent
            }
            if !covered { effective.append(index) }
        }
        var roots: [ZIPMemberSetSelection.Root] = []
        var byPosition: [UInt64: ZIPCopyBoundRecord] = [:]
        for rootIndex in effective {
            try Task.checkCancellation()
            let rootNode = storage.nodes[rootIndex]
            var firstPosition = UInt64.max, stack = [rootIndex]
            while let index = stack.popLast() {
                try Task.checkCancellation()
                let node = storage.nodes[index]
                guard node.kind == .file || node.kind == .directory else {
                    throw ZIPMemberRemovalFailure.unsupportedArchive
                }
                if node.explicit {
                    guard let position = node.centralEntryOffset else {
                        throw ZIPMemberRemovalFailure.invalidSelection
                    }
                    let suffix = node.kind == .directory ? "/" : ""
                    let member = ZIPCopyBoundRecord(archivePath: path(index, nodes: storage.nodes) + suffix,
                                                    centralPosition: position)
                    guard byPosition.updateValue(member, forKey: position) == nil else {
                        throw ZIPMemberRemovalFailure.invalidSelection
                    }
                    firstPosition = min(firstPosition, position)
                }
                if node.kind == .directory { stack.append(contentsOf: node.children) }
            }
            guard firstPosition != .max else { throw ZIPMemberRemovalFailure.invalidSelection }
            roots.append(.init(archivePath: path(rootIndex, nodes: storage.nodes),
                               isDirectory: rootNode.kind == .directory, firstPosition: firstPosition))
        }
        guard !byPosition.isEmpty, byPosition.count <= 20_000 else {
            throw ZIPMemberRemovalFailure.limitReached
        }
        roots.sort { lhs, rhs in
            lhs.firstPosition == rhs.firstPosition
                ? lhs.archivePath.utf8.lexicographicallyPrecedes(rhs.archivePath.utf8)
                : lhs.firstPosition < rhs.firstPosition
        }
        let members = byPosition.values.sorted { $0.centralPosition < $1.centralPosition }
        guard Set(members.map(\.centralPosition)).count == members.count else {
            throw ZIPMemberRemovalFailure.invalidSelection
        }
        return .init(archivePaths: roots.map(\.archivePath),
                     folderPaths: roots.filter(\.isDirectory).map(\.archivePath),
                     coveredSelectionCount: ids.count - roots.count,
                     binding: binding, roots: roots, members: members)
    }
    public func selectionForTextPreview(_ id: ZIPItemID) throws -> ZIPTextPreviewSelection {
        try selectionForPreview(id, limits: .init(), image: false)
    }
    public func selectionForImagePreview(_ id: ZIPItemID) throws -> ZIPTextPreviewSelection {
        try selectionForPreview(id, limits: .image, image: true)
    }
    private func selectionForPreview(_ id: ZIPItemID, limits: ZIPTextPreviewLimits, image: Bool) throws -> ZIPTextPreviewSelection {
        guard let storage else { throw ZIPArchiveFailure.closed }
        guard let binding, id.owner == root.owner, id.node > 0, storage.nodes.indices.contains(id.node) else {
            throw ZIPArchiveFailure.invalidFolder
        }
        try Task.checkCancellation()
        let member = storage.nodes[id.node]
        guard member.kind == .file, !member.encrypted, member.method == 0 || member.method == 8,
              !image || ArchiveImagePreview.supportsFilename(member.name) else {
            throw ZIPTextPreviewFailure.unsupported
        }
        guard member.logical <= limits.maximumBytes, member.packed <= limits.maximumPackedBytes else {
            throw ZIPTextPreviewFailure.tooLarge
        }
        guard let position = member.centralEntryOffset, let centralOffset = storage.centralOffset,
            let witness = storage.directoryWitness else {
            throw ZIPArchiveFailure.unavailable
        }
        return .init(binding: binding, path: path(id.node, nodes: storage.nodes), recordOffset: position,
            centralOffset: centralOffset, centralEnd: centralOffset + UInt64(storage.summary.centralBytes),
            directoryWitness: witness)
    }
    /// Resolve exact declared components only inside this session's catalog.
    public func folder(at components: [String]) throws -> ZIPFolderID {
        guard let storage else { throw ZIPArchiveFailure.closed }
        do { try ArchiveLocation.validateFolderPath(components) }
        catch { throw ZIPArchiveFailure.invalidFolder }
        var cursor = 0
        for component in components {
            try Task.checkCancellation()
            guard let next = try storage.nodes[cursor].children.first(where: { index in
                try Task.checkCancellation()
                return storage.nodes[index].name.utf8.elementsEqual(component.utf8)
            }), storage.nodes[next].kind == .directory else { throw ZIPArchiveFailure.invalidFolder }
            cursor = next
        }
        try Task.checkCancellation()
        return .init(owner: root.owner, node: cursor)
    }
    public func folderPath(of folder: ZIPFolderID) throws -> [String] {
        guard let storage else { throw ZIPArchiveFailure.closed }
        guard folder.owner == root.owner, storage.nodes.indices.contains(folder.node),
              storage.nodes[folder.node].kind == .directory else { throw ZIPArchiveFailure.invalidFolder }
        try Task.checkCancellation()
        var components = [String](), cursor = folder.node
        while cursor != 0 {
            try Task.checkCancellation()
            guard components.count < 64, let parent = storage.nodes[cursor].parent else { throw ZIPArchiveFailure.invalidFolder }
            components.append(storage.nodes[cursor].name); cursor = parent
        }
        try Task.checkCancellation()
        return Array(components.reversed())
    }

    public func page(in folder: ZIPFolderID, offset: Int = 0, filter: String = "", symbolTolerant: Bool = true,
        sorting order: ZIPArchiveOrder? = nil) throws -> ZIPDirectoryPage {
        guard let storage else { throw ZIPArchiveFailure.closed }
        guard folder.owner == root.owner, storage.nodes.indices.contains(folder.node),
              storage.nodes[folder.node].kind == .directory else { throw ZIPArchiveFailure.invalidFolder }
        guard offset >= 0 else { throw ZIPArchiveFailure.limited }
        guard filter.utf8.count <= 128 else { throw ZIPArchiveFailure.invalidFilter }
        try Task.checkCancellation()
        let ids = try directoryIDs(folder.node,filter:filter,symbols:symbolTolerant,order:order,nodes:storage.nodes)
        let start = min(offset, ids.count), end = min(start + 256, ids.count)
        let rows = items(ids[start..<end], nodes: storage.nodes)
        var breadcrumbs: [ZIPBreadcrumb] = [], cursor: Int? = folder.node
        while let index = cursor {
            breadcrumbs.append(.init(folder: .init(owner: root.owner, node: index), name: storage.nodes[index].name))
            cursor = storage.nodes[index].parent
        }
        try Task.checkCancellation()
        return .init(folder: folder, breadcrumbs: breadcrumbs.reversed(), items: rows, offset: start, total: ids.count)
    }
    public func searchNames(_ query: String, offset: Int = 0, symbolTolerant: Bool = true,
        sorting order: ZIPArchiveOrder? = nil) throws -> ZIPNameSearchPage {
        guard let storage else { throw ZIPArchiveFailure.closed }
        guard offset >= 0 else { throw ZIPArchiveFailure.limited }
        guard query.utf8.count <= 128 else { throw ZIPArchiveFailure.invalidFilter }
        try Task.checkCancellation()
        let key = FilenameMatching.folded(query, symbolTolerant: symbolTolerant)
        let ids: [Int]
        if let searched, searched.query == key, searched.symbols == symbolTolerant, searched.order == order { ids = searched.ids }
        else {
            // The parser already caps nodes/keys. Cache only IDs for one query;
            // construct paths and presentation values for the visible page only.
            let naturallyOrdered = order == ZIPArchiveOrder(.name) && storage.nodes.count == storage.nodes[0].children.count+1
            let candidates = naturallyOrdered ? storage.nodes[0].children : Array(storage.nodes.indices.dropFirst())
            let matching = key.allSatisfy(\.isWhitespace) ? [] : try candidates.filter { index in
                try Task.checkCancellation()
                return (symbolTolerant ? storage.nodes[index].symbolKey : storage.nodes[index].literalKey).contains(key)
            }
            ids = naturallyOrdered ? matching : try ZIPCatalogOrdering.ids(matching,nodes:storage.nodes,order:order)
            try Task.checkCancellation()
            searched = (key, symbolTolerant, order, ids)
        }
        let start = min(offset, ids.count), end = min(start + 256, ids.count)
        let rows = items(ids[start..<end], nodes: storage.nodes)
        try Task.checkCancellation()
        return .init(items: rows, offset: start, total: ids.count)
    }
    public func location(of item: ZIPItemID, sorting order: ZIPArchiveOrder? = nil) throws -> ZIPItemLocation {
        guard let storage else { throw ZIPArchiveFailure.closed }
        try Task.checkCancellation()
        guard item.owner == root.owner, item.node > 0, storage.nodes.indices.contains(item.node),
              let parent = storage.nodes[item.node].parent else { throw ZIPArchiveFailure.invalidFolder }
        let ids = try directoryIDs(parent,filter:"",symbols:true,order:order,nodes:storage.nodes)
        guard let position = ids.firstIndex(of:item.node) else { throw ZIPArchiveFailure.invalidFolder }
        try Task.checkCancellation()
        return .init(folder: .init(owner: root.owner, node: parent), offset: (position / 256) * 256)
    }
    public func close() { cached = nil; searched = nil; storage = nil }
    private func directoryIDs(_ folder: Int,filter: String,symbols: Bool,order: ZIPArchiveOrder?,nodes: [ZIPCatalogNode]) throws -> [Int] {
        if let cached, cached.folder == folder, cached.filter == filter, cached.symbols == symbols, cached.order == order { return cached.ids }
        let query = FilenameMatching.folded(filter,symbolTolerant:symbols)
        let matching = try nodes[folder].children.filter { index in
            try Task.checkCancellation()
            return query.isEmpty || (symbols ? nodes[index].symbolKey : nodes[index].literalKey).contains(query)
        }
        // Builder children already use the same folders-first natural-name
        // order. Filtering preserves that order; do not sort it a second time.
        let ids = order == ZIPArchiveOrder(.name) ? matching : try ZIPCatalogOrdering.ids(matching,nodes:nodes,order:order)
        try Task.checkCancellation()
        cached = (folder,filter,symbols,order,ids)
        return ids
    }
    private func items(_ ids: ArraySlice<Int>, nodes: [ZIPCatalogNode]) -> [ZIPArchiveItem] {
        ids.map { index in
            let value = nodes[index]
            return ZIPArchiveItem(id: .init(owner: root.owner, node: index), name: value.name,
                path: path(index, nodes: nodes), kind: value.kind, logicalBytes: value.logical,
                packedBytes: value.packed, method: value.method, modification: value.modification, isEncrypted: value.encrypted,
                folder: value.kind == .directory ? .init(owner: root.owner, node: index) : nil)
        }
    }
    private func path(_ index: Int, nodes: [ZIPCatalogNode]) -> String {
        var values: [String] = [], cursor: Int? = index
        while let current = cursor, current != 0 { values.append(nodes[current].name); cursor = nodes[current].parent }
        return values.reversed().joined(separator: "/")
    }
}
