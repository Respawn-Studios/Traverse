import Foundation

public enum PaneSplitAxis: String, Codable, Sendable { case columns, rows }

public enum PaneDropEdge: String, CaseIterable, Sendable {
    case leading, trailing, top, bottom
    public var axis: PaneSplitAxis { self == .leading || self == .trailing ? .columns : .rows }
    public var insertsFirst: Bool { self == .leading || self == .top }
}

/// A bounded flat tree. Decoding never recursively allocates an attacker-sized
/// hierarchy. Pane identities survive rearrangement; splits have their own IDs.
public struct PaneLayout: Codable, Equatable, Sendable {
    public static let maximumPanes = 4
    public enum Failure: Error, Sendable { case invalidLayout, limitReached, missingPane, lastPane, invalidFraction }
    public struct Node: Codable, Equatable, Sendable, Identifiable {
        public enum Content: Codable, Equatable, Sendable {
            case pane(UUID)
            case split(axis: PaneSplitAxis, fraction: Double, first: UUID, second: UUID)
        }
        public let id: UUID
        public var content: Content
        public init(id: UUID, content: Content) { self.id = id; self.content = content }
    }
    public private(set) var version = 1
    public private(set) var rootID: UUID
    public private(set) var nodes: [Node]

    public init(paneID: UUID = UUID()) {
        rootID = paneID
        nodes = [Node(id: paneID, content: .pane(paneID))]
    }

    private enum CodingKeys: String, CodingKey { case version, rootID, nodes }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        rootID = try values.decode(UUID.self, forKey: .rootID)
        nodes = try values.decode([Node].self, forKey: .nodes)
        try validate()
    }

    public func node(_ id: UUID) -> Node? { nodes.first { $0.id == id } }
    public var paneIDs: [UUID] {
        var result: [UUID] = [], seen = Set<UUID>()
        func visit(_ id: UUID) {
            guard seen.count < 7, seen.insert(id).inserted, let node = node(id) else { return }
            switch node.content {
            case .pane(let pane): result.append(pane)
            case .split(_, _, let first, let second): visit(first); visit(second)
            }
        }
        visit(rootID)
        return result
    }

    public func validate() throws {
        guard version == 1, !nodes.isEmpty, nodes.count <= 7, nodes.count % 2 == 1,
              Set(nodes.map(\.id)).count == nodes.count, node(rootID) != nil else { throw Failure.invalidLayout }
        var seen = Set<UUID>(), panes = Set<UUID>()
        func visit(_ id: UUID) throws {
            guard seen.insert(id).inserted, let item = node(id) else { throw Failure.invalidLayout }
            switch item.content {
            case .pane(let pane):
                guard pane == id, panes.insert(pane).inserted else { throw Failure.invalidLayout }
            case .split(_, let fraction, let first, let second):
                guard fraction.isFinite, (0.1...0.9).contains(fraction), first != second else { throw Failure.invalidLayout }
                try visit(first); try visit(second)
            }
        }
        try visit(rootID)
        guard seen.count == nodes.count, (1...Self.maximumPanes).contains(panes.count) else { throw Failure.invalidLayout }
    }

    public mutating func split(_ pane: UUID, inserting newPane: UUID, at edge: PaneDropEdge) throws {
        try validate()
        guard paneIDs.contains(pane) else { throw Failure.missingPane }
        guard paneIDs.count < Self.maximumPanes else { throw Failure.limitReached }
        guard node(newPane) == nil else { throw Failure.invalidLayout }
        let branch = UUID()
        replaceReference(pane, with: branch)
        let first = edge.insertsFirst ? newPane : pane
        let second = edge.insertsFirst ? pane : newPane
        nodes.append(Node(id: newPane, content: .pane(newPane)))
        nodes.append(Node(id: branch, content: .split(axis: edge.axis, fraction: 0.5, first: first, second: second)))
        try validate()
    }

    public mutating func remove(_ pane: UUID) throws {
        try validate()
        guard paneIDs.contains(pane) else { throw Failure.missingPane }
        guard paneIDs.count > 1 else { throw Failure.lastPane }
        guard let parent = nodes.first(where: {
            if case .split(_, _, let first, let second) = $0.content { return first == pane || second == pane }
            return false
        }), case .split(_, _, let first, let second) = parent.content else { throw Failure.invalidLayout }
        let sibling = first == pane ? second : first
        replaceReference(parent.id, with: sibling)
        nodes.removeAll { $0.id == pane || $0.id == parent.id }
        try validate()
    }

    public mutating func relocate(_ pane: UUID, beside target: UUID, at edge: PaneDropEdge) throws {
        guard pane != target, paneIDs.contains(target) else { throw Failure.missingPane }
        var candidate = self
        try candidate.remove(pane)
        try candidate.split(target, inserting: pane, at: edge)
        self = candidate
    }

    public mutating func setFraction(_ value: Double, for split: UUID) throws {
        guard value.isFinite, (0.1...0.9).contains(value) else { throw Failure.invalidFraction }
        guard let index = nodes.firstIndex(where: { $0.id == split }),
              case .split(let axis, _, let first, let second) = nodes[index].content else { throw Failure.missingPane }
        nodes[index].content = .split(axis: axis, fraction: value, first: first, second: second)
    }

    private mutating func replaceReference(_ old: UUID, with replacement: UUID) {
        if rootID == old { rootID = replacement }
        for index in nodes.indices {
            if case .split(let axis, let fraction, let first, let second) = nodes[index].content {
                nodes[index].content = .split(axis: axis, fraction: fraction,
                    first: first == old ? replacement : first, second: second == old ? replacement : second)
            }
        }
    }
}

/// UI restoration only. It retains no access grants or preview-read consent.
public struct PaneWorkspaceSnapshot: Codable, Equatable, Sendable {
    public struct Sidebar: Codable, Equatable, Sendable {
        public let isCollapsed: Bool
        public let expandedWidth: Double
        public init(isCollapsed: Bool = false, expandedWidth: Double = 200) {
            self.isCollapsed = isCollapsed; self.expandedWidth = expandedWidth
        }
    }
    public struct Pane: Codable, Equatable, Sendable {
        public let id: UUID
        public let tabs: WorkspaceSession
        public let viewMode: String
        public init(id: UUID, tabs: WorkspaceSession, viewMode: String) {
            self.id = id; self.tabs = tabs; self.viewMode = viewMode
        }
    }
    public let version: Int
    public let layout: PaneLayout
    public let activePane: UUID
    public let panes: [Pane]
    /// Absent in older workspaces: restore the original expanded 200-point sidebar.
    public let sidebar: Sidebar?
    public init(layout: PaneLayout, activePane: UUID, panes: [Pane], version: Int? = nil, sidebar: Sidebar? = nil) {
        self.version = version ?? (panes.map(\.tabs.version).max() ?? 1)
        self.layout = layout; self.activePane = activePane; self.panes = panes
        self.sidebar = sidebar
    }
    public func validate() throws {
        try layout.validate()
        guard (1...3).contains(version), panes.count == layout.paneIDs.count,
              Set(panes.map(\.id)) == Set(layout.paneIDs), Set(panes.map(\.id)).count == panes.count,
              layout.paneIDs.contains(activePane) else { throw PaneLayout.Failure.invalidLayout }
        if let sidebar {
            guard sidebar.expandedWidth.isFinite, (180...340).contains(sidebar.expandedWidth) else {
                throw PaneLayout.Failure.invalidLayout
            }
        }
        for pane in panes {
            guard ["Details", "List", "Icons"].contains(pane.viewMode) else { throw PaneLayout.Failure.invalidLayout }
            guard pane.tabs.version <= version else { throw PaneLayout.Failure.invalidLayout }
            try pane.tabs.validate()
        }
    }
}
