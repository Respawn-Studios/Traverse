import ExplorerCore
import Foundation

/// Bounded session memory only. These references select an exact path for a
/// fresh remote read; they never constitute access or filesystem authority.
@_spi(Qualification) public struct SMBDirectoryReferences: Sendable {
    private struct Item: Sendable { let location: SMBBrowserLocation; let path: [SMBRemoteName]; let cost: Int }
    private let connection: UUID, share: SMBRemoteName
    private var items: [UUID: Item] = [:], paths: [[SMBRemoteName]: UUID] = [:], order: [UUID] = []
    private var bytes = 0, closed = false
    public let root: SMBBrowserLocation
    public init(connectionID: UUID, share: SMBRemoteName) {
        connection = connectionID; self.share = share
        root = .init(connectionID: connectionID, directoryID: UUID(), displayHint: share.displayName)
        let item = Item(location: root, path: [], cost: 256)
        items[root.directoryID] = item; paths[[]] = root.directoryID; order = [root.directoryID]; bytes = item.cost
    }
    public mutating func location(for path: [SMBRemoteName]) throws -> SMBBrowserLocation {
        guard !closed, path.count <= 128 else { throw SMBBrowserFailure.invalidInput }
        let cost = path.reduce(256) { $0 + $1.wireUTF16.count + 16 }
        guard path.reduce(0, { $0 + $1.wireUTF16.count / 2 }) + max(0, path.count - 1) <= 4096 else { throw SMBBrowserFailure.invalidInput }
        if let id = paths[path], let item = items[id] { return item.location }
        while items.count >= 1024 || bytes + cost > 4 << 20 {
            guard let id = order.first(where: { $0 != root.directoryID }), let old = items.removeValue(forKey: id) else { throw SMBBrowserFailure.busy }
            paths.removeValue(forKey: old.path); order.removeAll { $0 == id }; bytes -= old.cost
        }
        let location = SMBBrowserLocation(connectionID: connection, directoryID: UUID(), displayHint: path.last?.displayName ?? share.displayName)
        items[location.directoryID] = Item(location: location, path: path, cost: cost)
        paths[path] = location.directoryID; order.append(location.directoryID); bytes += cost
        return location
    }
    public func resolve(_ value: SMBBrowserLocation) -> [SMBRemoteName]? {
        guard !closed, value.connectionID == connection else { return nil }
        return items[value.directoryID]?.path
    }
    public mutating func parent(of value: SMBBrowserLocation) throws -> SMBBrowserLocation? {
        guard let path = resolve(value), !path.isEmpty else { return nil }
        return try location(for: Array(path.dropLast()))
    }
    /// Session-local path suggestions, never a destination access grant.
    public func recentPaths(limit: Int = 8) -> [[SMBRemoteName]] {
        guard !closed, (1...16).contains(limit) else { return [] }
        return Array(order.reversed().compactMap { items[$0]?.path }.prefix(limit))
    }
    /// A successful server Move invalidates old descendant location tokens.
    /// Current and historical visits cannot silently follow a replacement at
    /// the old spelling; a new navigation must obtain a fresh reference.
    public mutating func invalidateDescendants(of path: [SMBRemoteName]) {
        guard !closed, !path.isEmpty else { return }
        let stale = order.filter { id in
            id != root.directoryID && items[id]?.path.starts(with: path) == true
        }
        for id in stale {
            if let item = items.removeValue(forKey: id) {
                paths.removeValue(forKey: item.path); bytes -= item.cost
            }
        }
        let removed = Set(stale); order.removeAll { removed.contains($0) }
    }
    public mutating func close() { closed = true; items = [:]; paths = [:]; order = []; bytes = 0 }
}
