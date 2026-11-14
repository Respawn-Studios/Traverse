import LocalStorage
import XCTest

final class FileAccessPolicyTests: XCTestCase {
    func testSigningChannelDoesNotImplyAnAccessPolicy() throws {
        for channel in ["app-store", "developer-id"] {
            XCTAssertEqual(try FileAccessPolicy.distribution(channel: channel, identifier: "com.respawnstudios.traverse",
                value: "sandbox-selected-v1"), .selectedFolders)
            for value in [nil, "", "local-user", "$(MAC_EXPLORER_ACCESS_POLICY)", "development"] as [String?] {
                XCTAssertThrowsError(try FileAccessPolicy.distribution(channel: channel, identifier: "com.respawnstudios.traverse", value: value))
            }
        }
        XCTAssertEqual(try FileAccessPolicy.distribution(channel: "developer-id", identifier: "com.respawnstudios.traverse",
            value: "local-user-v1"), .localUser)
        XCTAssertThrowsError(try FileAccessPolicy.distribution(channel: "app-store", identifier: "com.respawnstudios.traverse", value: "local-user-v1"))
        for channel in ["development", "qualification", "unknown"] {
            XCTAssertThrowsError(try FileAccessPolicy.distribution(channel: channel, identifier: "com.respawnstudios.traverse", value: "local-user-v1"))
        }
        XCTAssertThrowsError(try FileAccessPolicy.distribution(channel: "developer-id", identifier: "local.macexplorer.development", value: "local-user-v1"))
        XCTAssertTrue(FileAccessPolicy.selectedFolders.requiresFolderSelection)
        XCTAssertFalse(FileAccessPolicy.localUser.requiresFolderSelection)
    }
}
