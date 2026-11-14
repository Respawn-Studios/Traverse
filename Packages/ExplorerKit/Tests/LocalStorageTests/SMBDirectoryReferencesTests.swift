import Foundation
import ExplorerCore
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SMBDirectoryReferencesTests: XCTestCase {
    func testExactComponentsKeepUnicodeIdentityAndOpaqueParents() throws {
        let connection = UUID()
        var references = SMBDirectoryReferences(connectionID: connection, share: try SMBRemoteName("Shared"))
        let path = try [SMBRemoteName("Café"), SMBRemoteName("Folder")]
        let value = try references.location(for: path)
        XCTAssertEqual(references.resolve(value), path); XCTAssertEqual(try references.location(for: path), value)
        let parent = try XCTUnwrap(references.parent(of: value))
        XCTAssertEqual(references.resolve(parent), Array(path.prefix(1)))
        XCTAssertNotEqual(try references.location(for: [SMBRemoteName("Cafe\u{301}")]), parent)
        XCTAssertNil(references.resolve(.init(connectionID: UUID(), directoryID: value.directoryID, displayHint: "Shared")))
        XCTAssertNil(BrowserLocation.smb(value).directoryURL)
    }
    func testBoundedMapRetiresOldIDsAndClosingCannotResolveOrRecreateThem() throws {
        var references = SMBDirectoryReferences(connectionID: UUID(), share: try SMBRemoteName("Shared"))
        let old = try references.location(for: [SMBRemoteName("Old")])
        for n in 0..<1024 { _ = try references.location(for: [SMBRemoteName("Generated \(n)")]) }
        XCTAssertNil(references.resolve(old)); XCTAssertEqual(references.resolve(references.root), [])
        references.close(); XCTAssertNil(references.resolve(references.root))
        XCTAssertThrowsError(try references.location(for: []))
    }
}
