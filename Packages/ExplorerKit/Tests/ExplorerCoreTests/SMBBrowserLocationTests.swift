import Foundation
import XCTest
@testable import ExplorerCore

final class SMBBrowserLocationTests: XCTestCase {
    func testOpaqueIdentityHasNoLocalURLOrInferredParent() {
        let connection = UUID(), directory = UUID()
        let a = SMBBrowserLocation(connectionID: connection, directoryID: directory, displayHint: "Shared")
        let b = SMBBrowserLocation(connectionID: connection, directoryID: directory, displayHint: "/Volumes/Workspace")
        XCTAssertEqual(a, b); XCTAssertEqual(Set([a, b]).count, 1)
        XCTAssertNil(BrowserLocation.smb(b).directoryURL); XCTAssertNil(BrowserLocation.smb(b).parent)
        XCTAssertNotEqual(BrowserLocation.smb(b), .directory(URL(fileURLWithPath: "/Volumes/Workspace")))
        XCTAssertNotEqual(a, SMBBrowserLocation(connectionID: UUID(), directoryID: directory, displayHint: "Shared"))
    }
    func testRemoteHistoryStaysInMemoryAndPassiveRestorationKeepsLocalTabsOnly() throws {
        let remote = BrowserTab(location: .smb(.init(connectionID: UUID(), directoryID: UUID(), displayHint: "Shared")))
        let local = BrowserTab(location: .directory(URL(fileURLWithPath: "/generated")))
        let saved = try WorkspaceSession.capture([remote, local], activeID: remote.id)
        XCTAssertEqual(saved.tabs.count, 1); XCTAssertEqual(saved.tabs[0].location.url?.path, "/generated")
        let onlyRemote = try WorkspaceSession.capture([remote], activeID: remote.id)
        XCTAssertEqual(onlyRemote.tabs[0].location.kind, .computer)
        XCTAssertThrowsError(try WorkspaceSession.captureLaunchTemplate([remote, local], activeID: local.id))
        var history = remote; history.navigate(to: local.location); XCTAssertTrue(history.canGoBack)
        history.goBack(); XCTAssertEqual(history.location, remote.location)
    }
}
