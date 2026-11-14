import ExplorerCore
import Foundation
import XCTest

final class DirectoryPathInputTests: XCTestCase {
    func testTildeUsesSuppliedAccountHomeRatherThanProcessContainer() throws {
        let account = URL(fileURLWithPath: "/Volumes/Generated Home/Zoë", isDirectory: true)
        XCTAssertEqual(try DirectoryPathInput.resolve("~", home: account), account)
        XCTAssertEqual(try DirectoryPathInput.resolve("~/Documents", home: account).path, account.path + "/Documents")
        XCTAssertThrowsError(try DirectoryPathInput.resolve("~/Documents", home: nil))
        XCTAssertEqual(try DirectoryPathInput.resolve("/Volumes/Generated/Folder", home: nil).path, "/Volumes/Generated/Folder")
    }
    func testExplicitLocalURLsAndLiteralPathsKeepTheirInputContract() throws {
        XCTAssertEqual(try DirectoryPathInput.resolve("file:///Volumes/Generated%20Drive/Folder", home: nil).path, "/Volumes/Generated Drive/Folder")
        XCTAssertEqual(try DirectoryPathInput.resolve("/Generated/$HOME/`literal`", home: nil).path, "/Generated/$HOME/`literal`")
        for text in ["relative", "~another/Documents", "https://example.invalid/folder", "file://otherhost/Folder", "file://user:password@localhost/Folder",
            "file:///Folder?query", "file:///Folder#fragment", "file:///Bad%00Name", "/Bad\nName", "/Bad\0Name"] {
            XCTAssertThrowsError(try DirectoryPathInput.resolve(text, home: nil), text)
        }
    }
}
