import ExplorerCore
import Foundation
import Testing

@Test func workspaceSessionRoundTripsIndependentCurrentVisits() throws {
    let root = URL(fileURLWithPath: "/owned/Unicode Café", isDirectory: true)
    var first = BrowserTab(location: .directory(root))
    first.filter = "Résumé"
    first.sort = DirectorySort(field: .size, ascending: false, foldersFirst: false)
    first.state = NavigationState(selection: [root.appendingPathComponent("selected.txt")], scrollOffset: 193)
    var second = BrowserTab(location: .computer)
    second.navigate(to: .directory(URL(fileURLWithPath: "/missing-location")))
    let snapshot = try WorkspaceSession.capture([first, second], activeID: second.id)
    let decoded = try JSONDecoder().decode(WorkspaceSession.self, from: JSONEncoder().encode(snapshot))
    let restored = try decoded.restoredTabs()
    #expect(restored.tabs.count == 2)
    #expect(restored.activeID == restored.tabs[1].id)
    #expect(restored.tabs[0].state == first.state)
    #expect(restored.tabs[0].sort == first.sort)
    #expect(restored.tabs[0].filter == "Résumé")
    #expect(restored.tabs[1].location == second.location)
    #expect(!restored.tabs[1].canGoBack)
    #expect(restored.tabs[0].id != first.id)
}

@Test func workspaceSessionCaptureBoundsWithoutLosingActiveTab() throws {
    var tabs = (0..<80).map { BrowserTab(location: .directory(URL(fileURLWithPath: "/fixture/\($0)", isDirectory: true))) }
    let active = tabs[77].id
    let directory = tabs[77].location.directoryURL!
    tabs[77].filter = String(repeating: "é", count: 3_000)
    tabs[77].state = NavigationState(selection: Set((0..<600).map { directory.appendingPathComponent("\($0)") }), scrollOffset: .infinity)
    let snapshot = try WorkspaceSession.capture(tabs, activeID: active)
    #expect(snapshot.tabs.count == WorkspaceSession.maximumTabs)
    #expect(snapshot.tabs[snapshot.activeTab].location.url == directory)
    #expect(snapshot.tabs[snapshot.activeTab].selection.count == 256)
    #expect(snapshot.tabs[snapshot.activeTab].filter.utf8.count <= WorkspaceSession.maximumFilterBytes)
    #expect(snapshot.tabs[snapshot.activeTab].scrollOffset == 0)
}

@Test func workspaceSessionRefusesCredentialsRemoteAndMalformedLocalURLs() throws {
    let invalid = ["https://example.com/private", "file://user:password@localhost/private", "file://server/private", "file:///private?token=x", "file:///private#fragment"]
    for text in invalid {
        let snapshot = WorkspaceSession(tabs: [.init(location: .init(kind: .directory, url: URL(string: text)!))])
        #expect(throws: WorkspaceSession.ValidationFailure.self) { try snapshot.validate() }
    }
    let explicitMountedNetwork = WorkspaceSession(tabs: [.init(location: .init(kind: .directory, url: URL(fileURLWithPath: "/Volumes/Mounted share")))])
    try explicitMountedNetwork.validate()
}

@Test func workspaceSessionRejectsCorruptVersionCountsFieldsAndSelections() {
    let directory = URL(fileURLWithPath: "/fixture", isDirectory: true)
    let valid = WorkspaceSession.Tab(location: .init(kind: .directory, url: directory))
    var invalid: [WorkspaceSession] = [
        .init(version: 4, tabs: [valid]), .init(tabs: []), .init(tabs: [valid], activeTab: 1),
        .init(tabs: Array(repeating: valid, count: 33)),
        .init(tabs: [.init(location: .init(kind: .computer, url: directory))]),
        .init(tabs: [.init(location: .init(kind: .directory))]),
    ]
    var bad = valid; bad.sortField = "unknown"; invalid.append(.init(tabs: [bad]))
    bad = valid; bad.filter = String(repeating: "x", count: 2_049); invalid.append(.init(tabs: [bad]))
    bad = valid; bad.scrollOffset = -.infinity; invalid.append(.init(tabs: [bad]))
    bad = valid; bad.selection = [URL(fileURLWithPath: "/other/private")]; invalid.append(.init(tabs: [bad]))
    bad = valid; bad.selection = [directory.appendingPathComponent("a"), directory.appendingPathComponent("a")]; invalid.append(.init(tabs: [bad]))
    for snapshot in invalid {
        #expect(throws: WorkspaceSession.ValidationFailure.self) { try snapshot.validate() }
    }
}

@Test func workspaceSessionDoesNotRestoreUnrelatedSelectionOrProbeMissingPaths() throws {
    var tab = BrowserTab(location: .directory(URL(fileURLWithPath: "/does-not-exist", isDirectory: true)))
    tab.state = NavigationState(selection: [URL(fileURLWithPath: "/unrelated/private"), URL(fileURLWithPath: "/does-not-exist/kept")], scrollOffset: -10)
    let snapshot = try WorkspaceSession.capture([tab], activeID: tab.id)
    #expect(snapshot.tabs[0].selection == [URL(fileURLWithPath: "/does-not-exist/kept")])
    #expect(snapshot.tabs[0].scrollOffset == 0)
    #expect(try snapshot.restoredTabs().tabs[0].location == tab.location)
}
