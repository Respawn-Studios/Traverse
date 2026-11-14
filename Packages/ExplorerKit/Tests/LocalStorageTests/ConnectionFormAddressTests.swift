import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class ConnectionFormAddressTests: XCTestCase {
    func testIPAndPortFieldsStartAtHomeWithoutAConnectionString() throws {
        let address = try SFTPConnectionAddress(server: "192.168.1.25", port: 2222)
        XCTAssertEqual(address.host, "192.168.1.25"); XCTAssertEqual(address.port, 2222)
        XCTAssertNil(address.components); XCTAssertEqual(address.initialPathUTF8, Data(".".utf8))
        XCTAssertEqual(try SFTPConnectionAddress(address.displayAddress), address)
    }
    func testBareAndBracketedIPv6AreTheSameEndpoint() throws {
        XCTAssertEqual(try SFTPConnectionAddress(server: "::1", port: 2222), try SFTPConnectionAddress("sftp://[::1]:2222"))
        XCTAssertEqual(try SMBConnectionAddress(server: "[::1]", port: 1445, share: "Shared"), try SMBConnectionAddress("smb://[::1]:1445/Shared"))
        let scoped = try SFTPConnectionAddress(server: "fe80::1%253", port: 2222)
        XCTAssertEqual(scoped.scopeID, 3); XCTAssertEqual(scoped.serverField, "[fe80::1%253]")
    }
    func testLiteralFolderSymbolsAndUnicodeAreNeverReinterpretedAsURISyntax() throws {
        for path in ["/Project #1/100% ready?", "/Café", "/Cafe\u{301}", "/a\\b", "/%2f"] {
            let value = try SFTPConnectionAddress(server: "server", startingFolder: path)
            XCTAssertEqual(value.startingFolderField.utf8.map { $0 }, path.utf8.map { $0 })
            XCTAssertEqual(try SFTPConnectionAddress(value.displayAddress), value)
        }
        XCTAssertNotEqual(try SFTPConnectionAddress(server: "server", startingFolder: "/Café"), try SFTPConnectionAddress(server: "server", startingFolder: "/Cafe\u{301}"))
    }
    func testSMBShareAndSubfolderAreLiteralAndRoundTrip() throws {
        let value = try SMBConnectionAddress(server: "Studio.Example.invalid", share: "Work #1", startingFolder: "/100% ready?/Café")
        XCTAssertEqual(value.host, "studio.example.invalid"); XCTAssertEqual(value.port, 445)
        XCTAssertEqual(value.share.displayName, "Work #1"); XCTAssertEqual(value.startingFolderField, "/100% ready?/Café")
        XCTAssertEqual(try SMBConnectionAddress(value.displayAddress), value)
        XCTAssertEqual(try SMBConnectionAddress(server: value.serverField, port: value.port, share: value.share.displayName, startingFolder: value.startingFolderField), value)
    }
    func testBlankAndExplicitRootKeepTheirDifferentSFTPMeaning() throws {
        let home = try SFTPConnectionAddress(server: "server"), root = try SFTPConnectionAddress(server: "server", startingFolder: "/")
        XCTAssertNil(home.components); XCTAssertEqual(root.components, []); XCTAssertNotEqual(home, root)
        XCTAssertEqual(root.startingFolderField, "/")
        XCTAssertEqual(try SMBConnectionAddress(server: "server", share: "Shared"), try SMBConnectionAddress(server: "server", share: "Shared", startingFolder: "/"))
    }
    func testConflictingPortsURIsCredentialsAndMalformedHostsAreRefused() {
        for server in ["server:2222", "[::1]:2222", "sftp://server", "server/path", "user@server", "server ", "", "0.0.0.0", "[fe80::1]", "[::1\u{0}]"] {
            XCTAssertThrowsError(try SFTPConnectionAddress(server: server, port: 22))
            XCTAssertThrowsError(try SMBConnectionAddress(server: server, port: 445, share: "Shared"))
        }
        XCTAssertThrowsError(try SFTPConnectionAddress(server: "server", port: 0))
        XCTAssertThrowsError(try SMBConnectionAddress(server: "server", port: 0, share: "Shared"))
    }
    func testRelativeAndTraversalPathsAreNotSilentlyTurnedIntoAbsoluteLocations() {
        for path in ["home", "~/work", "/../work", "/./work", "//work", "/work//child"] {
            XCTAssertThrowsError(try SFTPConnectionAddress(server: "server", startingFolder: path))
            XCTAssertThrowsError(try SMBConnectionAddress(server: "server", share: "Shared", startingFolder: path))
        }
        for share in ["", "a/b", "..", "a\\b"] { XCTAssertThrowsError(try SMBConnectionAddress(server: "server", share: share)) }
    }
    func testExistingPathBoundsRemainFinalAuthority() throws {
        XCTAssertNoThrow(try SFTPConnectionAddress(server: "server", startingFolder: "/" + String(repeating: "a", count: 8191)))
        XCTAssertThrowsError(try SFTPConnectionAddress(server: "server", startingFolder: "/" + String(repeating: "a", count: 8192)))
        XCTAssertThrowsError(try SMBConnectionAddress(server: "server", share: String(repeating: "a", count: 257)))
    }
}
