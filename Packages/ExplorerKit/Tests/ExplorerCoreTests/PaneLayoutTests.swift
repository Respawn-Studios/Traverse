import Foundation
import Testing
@testable import ExplorerCore

@Test func paneLayoutSupportsIndependentMixedSplitsAndCollapses() throws {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    var layout = PaneLayout(paneID: a)
    try layout.split(a, inserting: b, at: .trailing)
    try layout.split(a, inserting: c, at: .bottom)
    try layout.split(b, inserting: d, at: .bottom)
    #expect(layout.paneIDs == [a, c, b, d])
    #expect(throws: PaneLayout.Failure.self) { try layout.split(a, inserting: UUID(), at: .leading) }
    try layout.remove(c)
    #expect(layout.paneIDs == [a, b, d])
    try layout.relocate(d, beside: a, at: .leading)
    #expect(layout.paneIDs == [d, a, b])
    try layout.remove(a); try layout.remove(b)
    #expect(layout.paneIDs == [d])
    #expect(layout.nodes.count == 1)
    #expect(throws: PaneLayout.Failure.self) { try layout.remove(d) }
}

@Test func paneLayoutRoundTripPreservesStableIdentitiesAndRatios() throws {
    let a = UUID(), b = UUID()
    var layout = PaneLayout(paneID: a)
    try layout.split(a, inserting: b, at: .top)
    try layout.setFraction(0.35, for: layout.rootID)
    let result = try JSONDecoder().decode(PaneLayout.self, from: JSONEncoder().encode(layout))
    #expect(result == layout)
    #expect(result.paneIDs == [b, a])
    #expect(throws: PaneLayout.Failure.self) { try layout.setFraction(.nan, for: layout.rootID) }
}

@Test func swappingOneDividerKeepsTheDividerAndEachNestedSideIntact() throws {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    var layout = PaneLayout(paneID: a)
    try layout.split(a, inserting: b, at: .trailing)
    try layout.split(a, inserting: c, at: .bottom)
    try layout.split(b, inserting: d, at: .bottom)
    let root = layout.rootID
    try layout.setFraction(0.58, for: root)
    let original = layout
    let first = try #require(layout.parent(of: a))
    let second = try #require(layout.parent(of: b))
    try layout.swapSides(of: root)
    #expect(layout.node(root)?.content == .split(axis: .columns, fraction: 0.58, first: second.id, second: first.id))
    #expect(layout.nodes.filter { $0.id != root } == original.nodes.filter { $0.id != root })
    #expect(layout.paneIDs == [b, d, a, c])
    #expect(layout.paneIDs(in: first.id) == [a, c])
    try layout.validate()
    try layout.swapSides(of: root)
    #expect(layout == original)
    #expect(throws: PaneLayout.Failure.self) { try layout.swapSides(of: a) }
    #expect(layout == original)
}

@Test func rotatingOneDividerKeepsItsRatioAndBothNestedSides() throws {
    let a = UUID(), b = UUID(), c = UUID()
    var layout = PaneLayout(paneID: a)
    try layout.split(a, inserting: b, at: .trailing)
    try layout.split(b, inserting: c, at: .bottom)
    let root = layout.rootID
    let nested = try #require(layout.parent(of: c))
    try layout.setFraction(0.38, for: root)
    let original = layout
    try layout.rotateSplit(root)
    #expect(layout.node(root)?.content == .split(axis: .rows, fraction: 0.38, first: a, second: nested.id))
    #expect(layout.nodes.filter { $0.id != root } == original.nodes.filter { $0.id != root })
    #expect(layout.paneIDs == [a, b, c])
    #expect(try JSONDecoder().decode(PaneLayout.self, from: JSONEncoder().encode(layout)) == layout)
    try layout.rotateSplit(root)
    #expect(layout == original)
    #expect(throws: PaneLayout.Failure.self) { try layout.rotateSplit(a) }
    #expect(layout == original)
}

@Test func paneLayoutRejectsDisconnectedDuplicateAndCyclicEncodedGraphs() throws {
    let a = UUID(), b = UUID()
    let valid = PaneLayout(paneID: a)
    let data = try JSONEncoder().encode(valid)
    var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    document["version"] = 99
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(PaneLayout.self, from: JSONSerialization.data(withJSONObject: document))
    }
    document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var nodes = try #require(document["nodes"] as? [[String: Any]])
    nodes.append(nodes[0]); document["nodes"] = nodes
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(PaneLayout.self, from: JSONSerialization.data(withJSONObject: document))
    }
    var split = valid
    try split.split(a, inserting: b, at: .trailing)
    document = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(split)) as? [String: Any])
    nodes = try #require(document["nodes"] as? [[String: Any]])
    let root = split.rootID.uuidString
    for index in nodes.indices where nodes[index]["id"] as? String == root {
        nodes[index]["content"] = ["split": ["axis": "columns", "fraction": 0.5, "first": root, "second": b.uuidString]]
    }
    document["nodes"] = nodes
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(PaneLayout.self, from: JSONSerialization.data(withJSONObject: document))
    }
}

@Test func paneWorkspaceSnapshotRequiresEveryPaneAndNeverCreatesAccess() throws {
    let a = UUID(), b = UUID()
    var layout = PaneLayout(paneID: a)
    try layout.split(a, inserting: b, at: .trailing)
    let tabs = WorkspaceSession(tabs: [.init(location: .init(kind: .directory, url: URL(fileURLWithPath: "/missing", isDirectory: true)))])
    let complete = PaneWorkspaceSnapshot(layout: layout, activePane: b, panes: [
        .init(id: a, tabs: tabs, viewMode: "Details"), .init(id: b, tabs: tabs, viewMode: "Icons")])
    try complete.validate()
    let restored = try JSONDecoder().decode(PaneWorkspaceSnapshot.self, from: JSONEncoder().encode(complete))
    try restored.validate()
    #expect(restored == complete)
    #expect(throws: PaneLayout.Failure.self) {
        try PaneWorkspaceSnapshot(layout: layout, activePane: a, panes: [.init(id: a, tabs: tabs, viewMode: "Details")]).validate()
    }
}

@Test func paneWorkspaceSidebarRestoresCollapsedWidthAndReadsOlderSnapshots() throws {
    let id = UUID()
    let tabs = WorkspaceSession(tabs: [.init(location: .init(kind: .computer))])
    let snapshot = PaneWorkspaceSnapshot(layout: .init(paneID: id), activePane: id,
        panes: [.init(id: id, tabs: tabs, viewMode: "Details")],
        sidebar: .init(isCollapsed: true, expandedWidth: 263))
    try snapshot.validate()
    let bytes = try JSONEncoder().encode(snapshot)
    let restored = try JSONDecoder().decode(PaneWorkspaceSnapshot.self, from: bytes)
    try restored.validate()
    #expect(restored == snapshot)
    var legacy = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    legacy.removeValue(forKey: "sidebar")
    let previous = try JSONDecoder().decode(PaneWorkspaceSnapshot.self,
        from: JSONSerialization.data(withJSONObject: legacy))
    try previous.validate()
    #expect(previous.sidebar == nil)
    #expect(previous.panes == snapshot.panes)
    for width in [0, 179, 341, Double.infinity, Double.nan] {
        #expect(throws: PaneLayout.Failure.self) {
            try PaneWorkspaceSnapshot(layout: snapshot.layout, activePane: id, panes: snapshot.panes,
                sidebar: .init(isCollapsed: true, expandedWidth: width)).validate()
        }
    }
}
