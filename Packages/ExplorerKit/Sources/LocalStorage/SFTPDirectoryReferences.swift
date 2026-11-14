import ExplorerCore
import Foundation

/// Bounded exact UTF-8 components. A reference only selects a fresh remote read;
/// it cannot supply access, a local URL or a value for a shell command.
@_spi(Qualification) public struct SFTPDirectoryReferences: Sendable {
    private struct Path: Hashable, Sendable { let home: Bool, components: [SFTPRemoteName] }
    private struct Item: Sendable { let location: SFTPBrowserLocation, path: Path, cost: Int }
    private let connection: UUID, home: Bool
    private var items: [UUID: Item] = [:], paths: [Path: UUID] = [:], order: [UUID] = []
    private var bytes = 0, closed = false
    public let root: SFTPBrowserLocation
    public let homeRoot: SFTPBrowserLocation
    public let serverRoot: SFTPBrowserLocation
    public init(connectionID: UUID, home: Bool, title: String) {
        connection = connectionID; self.home = home
        homeRoot = .init(connectionID: connectionID, directoryID: UUID(), displayHint: home ? title : title + " · Home")
        serverRoot = .init(connectionID: connectionID, directoryID: UUID(), displayHint: home ? title + " · /" : title)
        root = home ? homeRoot : serverRoot
        for (value,relative) in [(homeRoot,true),(serverRoot,false)] {
            let path = Path(home: relative, components: [])
            items[value.directoryID] = .init(location: value, path: path, cost: 256); paths[path] = value.directoryID; order.append(value.directoryID)
        }
        bytes = 512
    }
    public mutating func location(for path: [SFTPRemoteName], relativeToHome: Bool? = nil) throws -> SFTPBrowserLocation {
        guard !closed, path.count <= 128 else { throw SFTPBrowserFailure.invalidInput }
        let length = path.reduce(1) { $0 + 1 + $1.wireUTF8.count }, cost = length + 256 + path.count * 16
        guard length <= 8192 else { throw SFTPBrowserFailure.invalidInput }
        let key = Path(home: relativeToHome ?? home, components: path)
        if let id = paths[key], let item = items[id] { return item.location }
        while items.count >= 1024 || bytes + cost > 4 << 20 {
            guard let id = order.first(where: { $0 != homeRoot.directoryID && $0 != serverRoot.directoryID }), let old = items.removeValue(forKey: id) else { throw SFTPBrowserFailure.busy }
            paths.removeValue(forKey: old.path); order.removeAll { $0 == id }; bytes -= old.cost
        }
        let value = SFTPBrowserLocation(connectionID: connection, directoryID: UUID(), displayHint: path.last?.displayName ?? (key.home ? homeRoot : serverRoot).displayHint)
        items[value.directoryID] = .init(location: value, path: key, cost: cost); paths[key] = value.directoryID; order.append(value.directoryID); bytes += cost
        return value
    }
    public func resolve(_ value: SFTPBrowserLocation) -> [SFTPRemoteName]? {
        guard !closed, value.connectionID == connection else { return nil }; return items[value.directoryID]?.path.components
    }
    public func isHomeRelative(_ value: SFTPBrowserLocation) -> Bool? {
        guard !closed, value.connectionID == connection else { return nil }; return items[value.directoryID]?.path.home
    }
    public func baseRoot(for value: SFTPBrowserLocation) -> SFTPBrowserLocation? {
        isHomeRelative(value).map { $0 ? homeRoot : serverRoot }
    }
    public func pathUTF8(for value: SFTPBrowserLocation) -> Data? {
        guard let parts = resolve(value), let relative = isHomeRelative(value) else { return nil }
        var data = Data([relative ? 46 : 47]); for part in parts { if data.last != 47 { data.append(47) }; data.append(part.wireUTF8) }; return data
    }
    public mutating func parent(of value: SFTPBrowserLocation) throws -> SFTPBrowserLocation? {
        guard let path = resolve(value), !path.isEmpty, let relative = isHomeRelative(value) else { return nil }
        return try location(for: Array(path.dropLast()), relativeToHome: relative)
    }
    public mutating func close() { closed = true; items.removeAll(); paths.removeAll(); order.removeAll(); bytes = 0 }
}
