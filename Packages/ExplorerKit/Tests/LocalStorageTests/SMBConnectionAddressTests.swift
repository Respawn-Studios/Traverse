import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SMBConnectionAddressTests: XCTestCase {
    func testTypedLogicalAddressIsBoundedAndContainsNoPassword() throws {
        let address = try SMBConnectionAddress("Studio.Example.invalid:1445/Shared%20Files/目录/Report%20two")
        XCTAssertEqual(address.host, "studio.example.invalid"); XCTAssertEqual(address.port, 1445)
        XCTAssertEqual(address.hostKind, .dns); XCTAssertEqual(address.share.displayName, "Shared Files")
        XCTAssertEqual(address.components.map(\.displayName), ["目录", "Report two"])
        let saved = try JSONEncoder().encode(address)
        XCTAssertEqual(try JSONDecoder().decode(SMBConnectionAddress.self, from: saved), address)
        XCTAssertEqual(address.description, "<SMB address>")
        XCTAssertEqual(String(reflecting: address), "<SMB address>")
        XCTAssertEqual(try SMBConnectionAddress("smb://127.0.0.1/QA/").displayAddress, "smb://127.0.0.1/QA")
    }
    func testScopeIsPreservedAndInvalidOrAmbiguousAddressesNeverAdmit() throws {
        let address = try SMBConnectionAddress("smb://[fe80:0:0:0:0:0:0:1%253]:1445/QA")
        XCTAssertEqual(address.host, "fe80::1"); XCTAssertEqual(address.hostKind, .ipv6); XCTAssertEqual(address.scopeID, 3)
        XCTAssertEqual(try SMBConnectionAddress(address.displayAddress), address)
        XCTAssertEqual(try SMBConnectionAddress("smb://[::1]/QA").scopeID, 0)
        for (index, text) in ["", "smb://server", "smb://server/", "smb://user:password@server/QA", "https://server/QA",
            "smb://server/QA?password=secret", "smb://server/QA#part", "smb://server//QA", "smb://server/QA/../Other",
            "smb://server/QA/%2e", "smb://server/QA/a%2fb", "smb://server/QA/a%5cb", "smb://server/QA/%00", "smb://server/QA/%ff",
            "smb://server/QA/%xx", "smb://server:0/QA", "smb://server:0445/QA", "smb://server:65536/QA", "smb://0.0.0.0/QA",
            "smb://224.0.0.1/QA", "smb://127.00.0.1/QA", "smb://-server/QA", "smb://server./QA", "smb://server_.local/QA",
            "smb://[fe80::1]/QA", "smb://[fe80::1%25en0]/QA", "smb://[fe80::1%250]/QA", "smb://[::]/QA", "smb://[ff02::1]/QA"].enumerated() {
            XCTAssertThrowsError(try SMBConnectionAddress(text), "Invalid generated address case \(index) admitted")
        }
    }
    func testOpaqueNamesPreserveCompositionAndRejectLossyDecodedInput() throws {
        let composed = try SMBRemoteName("Café.txt"), decomposed = try SMBRemoteName("Cafe\u{301}.txt")
        XCTAssertNotEqual(composed, decomposed); XCTAssertEqual(Set([composed, decomposed]).count, 2)
        XCTAssertEqual(try JSONDecoder().decode(SMBRemoteName.self, from: JSONEncoder().encode(decomposed)), decomposed)
        for data in [Data([0]), Data([0, 0xd8]), Data([0, 0]), Data(repeating: 1, count: 4098)] {
            XCTAssertThrowsError(try JSONDecoder().decode(SMBRemoteName.self, from: JSONEncoder().encode(data)))
        }
        let deep = "smb://server/QA/" + Array(repeating: String(repeating: "界", count: 300), count: 10).joined(separator: "/")
        let address = try SMBConnectionAddress(deep)
        XCTAssertEqual(try JSONDecoder().decode(SMBConnectionAddress.self, from: JSONEncoder().encode(address)), address)
    }
    func testCredentialBindingAlsoDistinguishesIPv6InterfaceAndRawShareSpelling() throws {
        let a = try SMBCredentialBinding(host: "fe80::1", port: 445, share: "QA", account: "generated", domain: "", interfaceScope: 3)
        let b = try SMBCredentialBinding(host: "fe80::1", port: 445, share: "QA", account: "generated", domain: "", interfaceScope: 4)
        XCTAssertNotEqual(a.digest, b.digest)
        let c = try SMBCredentialBinding(host: "example.invalid", port: 445, share: "Café", account: "generated", domain: "")
        let d = try SMBCredentialBinding(host: "example.invalid", port: 445, share: "Cafe\u{301}", account: "generated", domain: "")
        XCTAssertNotEqual(c.digest, d.digest)
    }
}
