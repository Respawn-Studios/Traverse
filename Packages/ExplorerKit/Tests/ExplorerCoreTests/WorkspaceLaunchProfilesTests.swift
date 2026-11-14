import Foundation
import Testing
@testable import ExplorerCore

@Suite struct WorkspaceLaunchProfilesTests {
    private func sample() -> PaneWorkspaceSnapshot {
        let id = UUID(), url = URL(fileURLWithPath: "/not-a-grant/Folder")
        let tab = WorkspaceSession.Tab(location: .init(kind: .directory, url: url), filter: "explicit filter", sortField: "size",
            ascending: false, selection: [url.appendingPathComponent("Selected.txt")], scrollOffset: 42)
        return .init(layout: PaneLayout(paneID: id), activePane: id,
            panes: [.init(id: id, tabs: .init(tabs: [tab, .init(location: .init(kind: .computer))], activeTab: 1), viewMode: "Icons")])
    }
    @Test func templatesClearTransientStateAndPreserveOptionalFilters() throws {
        let source = sample(), normal = try source.forLaunchProfile(), filtered = try source.forLaunchProfile(includeFilters: true)
        #expect(normal.layout == source.layout && normal.activePane == source.activePane)
        #expect(normal.panes[0].tabs.activeTab == 1 && normal.panes[0].viewMode == "Icons")
        #expect(normal.panes[0].tabs.tabs[0].filter.isEmpty && filtered.panes[0].tabs.tabs[0].filter == "explicit filter")
        #expect(filtered.panes[0].tabs.tabs[0].selection.isEmpty && filtered.panes[0].tabs.tabs[0].scrollOffset == 0)
        #expect(filtered.panes[0].tabs.tabs[0].sortField == "size" && !filtered.panes[0].tabs.tabs[0].ascending)
        #expect(try !filtered.panes[0].tabs.restoredTabs().tabs[0].canGoBack)
    }
    @Test func namesLimitsAndRoundTrip() throws {
        var library = WorkspaceLaunchProfiles()
        let first = try library.add(name: "Work", snapshot: sample()), revision = library.revision
        #expect(throws: WorkspaceLaunchProfiles.Failure.duplicateName) { try library.add(name: "work", snapshot: sample()) }
        for bad in ["", " leading", "line\nbreak", String(repeating: "x", count: 161)] {
            #expect(throws: WorkspaceLaunchProfiles.Failure.invalidName) { try library.rename(first, to: bad) }
        }
        try library.rename(first, to: "Studio")
        #expect(library.revision != revision && library.profiles[0].id == first)
        try library.update(first, snapshot: sample(), includeFilters: true)
        #expect(library.profiles[0].id == first && library.profiles[0].name == "Studio")
        #expect(library.profiles[0].snapshot.panes[0].tabs.tabs[0].filter == "explicit filter")
        #expect(library.profiles[0].snapshot.panes[0].tabs.tabs[0].selection.isEmpty)
        for index in 1..<20 { try library.add(name: "Profile \(index)", snapshot: sample()) }
        #expect(throws: WorkspaceLaunchProfiles.Failure.limitReached) { try library.add(name: "Too many", snapshot: sample()) }
        let decoded = try JSONDecoder().decode(WorkspaceLaunchProfiles.self, from: JSONEncoder().encode(library))
        try decoded.validate(); #expect(decoded == library)
        try library.remove(first); #expect(library.profiles.count == 19)
        #expect(throws: WorkspaceLaunchProfiles.Failure.missingProfile) { try library.remove(first) }
    }
    @Test func liveCaptureDoesNotPersistSelectionOrHistory() throws {
        var tab = BrowserTab(location: .computer)
        tab.navigate(to: .directory(URL(fileURLWithPath: "/not-a-grant/Folder")))
        tab.state = NavigationState(selection: Set((0..<10_000).map { URL(fileURLWithPath: "/not-a-grant/Folder/\($0)") }), scrollOffset: 300)
        tab.filter = "deliberate filter"; tab.sort = DirectorySort(field: .size, ascending: false)
        let saved = try WorkspaceSession.captureLaunchTemplate([tab], activeID: tab.id)
        #expect(saved.tabs[0].selection.isEmpty && saved.tabs[0].scrollOffset == 0 && saved.tabs[0].filter.isEmpty)
        #expect(saved.tabs[0].sortField == "size" && !saved.tabs[0].ascending)
        #expect(try !saved.restoredTabs().tabs[0].canGoBack)
        #expect(try WorkspaceSession.captureLaunchTemplate([tab], activeID: tab.id, includeFilters: true).tabs[0].filter == "deliberate filter")
    }
    @Test func decodedTemplatesRefuseRetainedSelectionsAndNewVersions() throws {
        var library = WorkspaceLaunchProfiles(); try library.add(name: "Clean", snapshot: sample())
        let data = try JSONEncoder().encode(library)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 99
        let newer = try JSONDecoder().decode(WorkspaceLaunchProfiles.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: WorkspaceLaunchProfiles.Failure.invalidDocument) { try newer.validate() }
        object["version"] = 1
        var profiles = try #require(object["profiles"] as? [[String: Any]])
        var profile = profiles[0], snapshot = try #require(profile["snapshot"] as? [String: Any])
        var panes = try #require(snapshot["panes"] as? [[String: Any]])
        var pane = panes[0], tabs = try #require(pane["tabs"] as? [String: Any])
        var visits = try #require(tabs["tabs"] as? [[String: Any]])
        visits[0]["scrollOffset"] = 30; tabs["tabs"] = visits; pane["tabs"] = tabs; panes[0] = pane
        snapshot["panes"] = panes; profile["snapshot"] = snapshot; profiles[0] = profile; object["profiles"] = profiles
        let polluted = try JSONDecoder().decode(WorkspaceLaunchProfiles.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: WorkspaceLaunchProfiles.Failure.invalidDocument) { try polluted.validate() }
    }
}
