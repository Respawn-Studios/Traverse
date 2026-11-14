import Foundation
import XCTest
@testable import ExplorerCore

final class WorkspaceNetworkLocationsTests: XCTestCase {
    private func bookmark(_ kind: WorkspaceConnectionBookmark.Kind = .sftpServer,
                          components: [Data] = [Data("Ame\u{301}lie".utf8)]) throws -> WorkspaceConnectionBookmark {
        try .init(kind: kind, serverID: UUID(), binding: Data(repeating: 7, count: 32), title: "Generated server",
                  components: components, relativeToHome: kind != .smbServer)
    }
    private func snapshot(_ tabs: [BrowserTab], active: UUID) throws -> PaneWorkspaceSnapshot {
        let pane = UUID()
        return .init(layout: .init(paneID: pane), activePane: pane,
            panes: [.init(id: pane, tabs: try .captureLaunchTemplate(tabs, activeID: active), viewMode: "Details")])
    }
    func testExactNetworkRoundTripCreatesFreshDisconnectedIdentitiesWithoutCredentials() throws {
        let saved = try bookmark(), tab = try saved.disconnectedTab(), local = BrowserTab(location: .computer)
        let captured = try WorkspaceSession.capture([local, tab], activeID: tab.id)
        XCTAssertEqual(captured.version, 2); XCTAssertEqual(captured.activeTab, 1)
        let bytes = try JSONEncoder().encode(captured)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("connectionID"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("password"))
        let read = try JSONDecoder().decode(WorkspaceSession.self, from: bytes)
        let restored = try read.restoredTabs(), again = try read.restoredTabs()
        XCTAssertEqual(restored.tabs[1].connectionBookmark, saved)
        XCTAssertNotEqual(restored.tabs[1].location, again.tabs[1].location)
        XCTAssertNotEqual(restored.tabs[1].id, tab.id)
        XCTAssertTrue(restored.tabs[1].location.isRemote); XCTAssertNil(restored.tabs[1].location.directoryURL)
        XCTAssertEqual(restored.activeID, restored.tabs[1].id)
        XCTAssertEqual(saved.components[0], Data("Ame\u{301}lie".utf8))
        XCTAssertNotEqual(saved.components[0], Data("Amélie".utf8))
        XCTAssertEqual(String(describing: saved), "<saved workspace connection>")
    }
    func testRemoteFiltersSelectionAndScrollNeverPersist() throws {
        var tab = try bookmark().disconnectedTab()
        tab.filter = "private query"; tab.state = .init(selection: [URL(fileURLWithPath: "/generated/secret")], scrollOffset: 99)
        let captured = try WorkspaceSession.capture([tab], activeID: tab.id)
        XCTAssertEqual(captured.tabs[0].filter, ""); XCTAssertTrue(captured.tabs[0].selection.isEmpty)
        XCTAssertEqual(captured.tabs[0].scrollOffset, 0)
        var invalid = captured; invalid.tabs[0].filter = "query"
        XCTAssertThrowsError(try invalid.validate())
        invalid = captured; invalid.tabs[0].selection = [URL(fileURLWithPath: "/generated")]
        XCTAssertThrowsError(try invalid.validate())
        invalid = captured; invalid.tabs[0].scrollOffset = 1
        XCTAssertThrowsError(try invalid.validate())
    }
    func testLocalV1RemainsByteCompatibleAndNestedNetworkNeedsNewVersion() throws {
        let local = BrowserTab(location: .directory(URL(fileURLWithPath: "/generated")))
        let session = try WorkspaceSession.capture([local], activeID: local.id)
        XCTAssertEqual(session.version, 1)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(session)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        let tabs = try XCTUnwrap(document["tabs"] as? [[String: Any]])
        let location = try XCTUnwrap(tabs.first?["location"] as? [String: Any])
        XCTAssertNil(location["connection"])
        let decoded = try JSONDecoder().decode(WorkspaceSession.self, from: before); try decoded.validate()
        XCTAssertEqual(try encoder.encode(decoded), before)
    }
    func testVersionDowngradeAndUnexpectedFieldsAreRefused() throws {
        let saved = try bookmark(), tab = try saved.disconnectedTab()
        let value = try WorkspaceSession.capture([tab], activeID: tab.id)
        var bad = value; bad.version = 1; XCTAssertThrowsError(try bad.validate())
        bad = value; bad.version = 4; XCTAssertThrowsError(try bad.validate())
        bad = value; bad.tabs[0].location.url = URL(fileURLWithPath: "/generated"); XCTAssertThrowsError(try bad.validate())
        bad = .init(tabs: [.init(location: .init(kind: .computer, connection: saved))]); XCTAssertThrowsError(try bad.validate())
        bad = .init(tabs: [.init(location: .init(kind: .directory, url: URL(fileURLWithPath: "/generated"), connection: saved))]); XCTAssertThrowsError(try bad.validate())
        let pane = UUID(), oldContainer = PaneWorkspaceSnapshot(layout: .init(paneID: pane), activePane: pane,
            panes: [.init(id: pane, tabs: value, viewMode: "Details")], version: 1)
        XCTAssertThrowsError(try oldContainer.validate())
    }
    func testUnsavedLiveTabsAreOmittedPassivelyButExplicitTemplateRefusesThem() throws {
        let local = BrowserTab(location: .computer), saved = try bookmark().disconnectedTab()
        let live = BrowserTab(location: .sftp(.init(connectionID: UUID(), directoryID: UUID(), displayHint: "Unsaved")))
        let value = try WorkspaceSession.capture([local, saved, live], activeID: saved.id)
        XCTAssertEqual(value.tabs.count, 2); XCTAssertEqual(value.activeTab, 1)
        let fallback = try WorkspaceSession.capture([live], activeID: live.id)
        XCTAssertEqual(fallback.tabs.first?.location.kind, .computer)
        XCTAssertThrowsError(try WorkspaceSession.captureLaunchTemplate([saved, live], activeID: saved.id))
    }
    func testBookmarkBelongsToVisitAndCannotBecomeLocalAuthorityOrOtherProtocol() throws {
        let saved = try bookmark(); var tab = try saved.disconnectedTab()
        tab.navigate(to: .computer); XCTAssertNil(tab.connectionBookmark)
        tab.goBack(); XCTAssertEqual(tab.connectionBookmark, saved)
        tab.connectionBookmark = try bookmark(.smbServer, components: [])
        XCTAssertThrowsError(try WorkspaceSession.capture([tab], activeID: tab.id))
        tab.connectionBookmark = saved
        XCTAssertThrowsError(try tab.replaceDisconnectedConnection(with: .directory(URL(fileURLWithPath: "/generated")), bookmark: nil))
        XCTAssertThrowsError(try tab.replaceDisconnectedConnection(with: .smb(.init(connectionID: UUID(), directoryID: UUID(), displayHint: "Wrong")), bookmark: nil))
    }
    func testLayoutProfileAndWorkingMemoryUpgradeOnlyOnExplicitNetworkSaveAndKeepVersionAfterForget() throws {
        let local = BrowserTab(location: .computer), network = try bookmark().disconnectedTab()
        let old = try snapshot([local], active: local.id), new = try snapshot([local, network], active: network.id)
        var library = WorkspaceLaunchProfiles()
        let id = try library.add(name: "Generated", snapshot: old)
        XCTAssertEqual(library.version, 1)
        try library.update(id, snapshot: new, includeFilters: true); XCTAssertEqual(library.version, 2)
        let decoded = try JSONDecoder().decode(WorkspaceLaunchProfiles.self, from: JSONEncoder().encode(library)); try decoded.validate()
        XCTAssertEqual(decoded.profiles.first?.snapshot, new)
        var memory = WorkspaceProfileMemory()
        let record = try memory.enable(id, templateKey: String(repeating: "a", count: 64), includesFilters: false, snapshot: new)
        XCTAssertEqual(memory.version, 2); try memory.validate()
        try memory.disable(id, consent: record.consent); XCTAssertEqual(memory.version, 2)
        try library.remove(id); XCTAssertEqual(library.version, 2)
    }
    func testStrictExactComponentBoundsAndMalformedReferences() throws {
        for parts in [[Data()], [Data(".".utf8)], [Data("..".utf8)], [Data("a/b".utf8)], [Data([0])], [Data([0xff])], Array(repeating: Data([97]), count: 129), [Data(repeating: 97, count: 8192)]] {
            XCTAssertThrowsError(try bookmark(components: parts))
        }
        let valid = try bookmark(components: [Data("back\\slash\nname".utf8)])
        XCTAssertEqual(valid.components[0], Data("back\\slash\nname".utf8))
        for data in [Data([0]), Data([0,0xd8]), Data([46,0,46,0]), Data([47,0]), Data([92,0]), Data([0,0])] {
            XCTAssertThrowsError(try bookmark(.smbServer, components: [data]))
        }
        XCTAssertThrowsError(try WorkspaceConnectionBookmark(kind: .sftpServer, serverID: UUID(), binding: Data(), title: "Name"))
        XCTAssertThrowsError(try WorkspaceConnectionBookmark(kind: .sftpServer, serverID: UUID(), binding: Data(repeating: 1, count: 32), title: "Bad\nName"))
        XCTAssertThrowsError(try WorkspaceConnectionBookmark(kind: .smbServer, serverID: UUID(), binding: Data(repeating: 1, count: 32), title: "Name", relativeToHome: true))
    }
}
