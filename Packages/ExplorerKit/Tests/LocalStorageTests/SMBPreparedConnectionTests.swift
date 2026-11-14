import ExplorerCore
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SMBPreparedConnectionTests: XCTestCase, @unchecked Sendable {
    private func request(_ address: SMBConnectionAddress) throws -> SMBServerDraft {
        try SMBServerDraft(name: "Generated", address: address, account: "generated-user", domain: "GENERATED", security: .encrypted)
    }
    func testNumericPreparationUsesNoResolverBundleAndPreservesScopedIPv6() async throws {
        let unused = URL(fileURLWithPath: "/unused-generated-resolver"), activity = FileActivityGate(maximumActivities: 1)
        for typed in ["smb://127.0.0.1:15445/Shared/Folder", "smb://[fe80::1%257]:1445/Shared"] {
            let address = try SMBConnectionAddress(typed)
            let endpoint = try await SMBPreparedConnection.prepare(address, bundleURL: unused, activity: activity)
            XCTAssertEqual(endpoint.address, address); XCTAssertEqual(endpoint.numericHost, address.host)
            XCTAssertEqual(endpoint.scopeID, address.scopeID); XCTAssertEqual(activity.activeCount, 0)
            XCTAssertNoThrow(try endpoint.validate(for: request(address)))
        }
    }
    func testDNSSelectionRetainsLogicalHostAndExactShareWhileFreezingNumericDestination() throws {
        let address = try SMBConnectionAddress("smb://studio.invalid:1445/Caf%C3%A9%20%E6%96%87%E4%BB%B6/Sub-Folder")
        let endpoint = try SMBPreparedConnection.select(address, candidates: [.init(family: .ipv4,
            addressBytes: Data([127, 0, 0, 1]), scopeID: 0, interfaceIndex: 0)], now: 100)
        XCTAssertEqual(endpoint.numericHost, "127.0.0.1"); XCTAssertEqual(endpoint.address.host, "studio.invalid")
        XCTAssertNoThrow(try endpoint.validate(for: request(address), now: 129.99))
        let line = endpoint.command(session: UUID(), catalog: URL(fileURLWithPath: "/generated/catalog.sqlite"), quota: 2 << 20, policy: .encrypted)
        let fields = line.trimmingCharacters(in: .newlines).split(separator: " ")
        XCTAssertEqual(fields.count, 11); XCTAssertEqual(fields[3], "encrypted"); XCTAssertEqual(fields[4], "127.0.0.1")
        XCTAssertEqual(fields[5], "1445"); XCTAssertEqual(fields[7], "73747564696f2e696e76616c6964")
        XCTAssertEqual(fields[8], "00430061006600e9002065874ef6")
        XCTAssertFalse(line.contains("studio.invalid")); XCTAssertFalse(line.contains("Sub-Folder"))
        XCTAssertEqual(String(reflecting: endpoint), "<Prepared SMB connection>")
    }
    func testPreparedAddressCannotBeReusedForChangedSharePathPortOrAfterExpiry() throws {
        let address = try SMBConnectionAddress("smb://127.0.0.1:1445/Shared/Folder")
        let endpoint = try SMBPreparedConnection.select(address, candidates: [.init(family: .ipv4,
            addressBytes: Data([127, 0, 0, 1]), scopeID: 0, interfaceIndex: 0)], now: 100)
        for typed in ["smb://127.0.0.1:1446/Shared/Folder", "smb://127.0.0.1:1445/Other/Folder", "smb://127.0.0.1:1445/Shared/Other"] {
            XCTAssertThrowsError(try endpoint.validate(for: request(SMBConnectionAddress(typed)), now: 110))
        }
        for time in [99, 130, Double.nan, Double.infinity] { XCTAssertThrowsError(try endpoint.validate(for: request(address), now: time)) }
    }
    func testResolvedInputRefusesUnspecifiedMulticastWrongLengthAndNumericRebinding() throws {
        let address = try SMBConnectionAddress("smb://127.0.0.1/Shared")
        let values: [SMBResolvedAddress] = [
            .init(family: .ipv4, addressBytes: Data([0, 0, 0, 0]), scopeID: 0, interfaceIndex: 0),
            .init(family: .ipv4, addressBytes: Data([224, 1, 2, 3]), scopeID: 0, interfaceIndex: 0),
            .init(family: .ipv4, addressBytes: Data([127, 0, 0]), scopeID: 0, interfaceIndex: 0),
            .init(family: .ipv4, addressBytes: Data([127, 0, 0, 2]), scopeID: 0, interfaceIndex: 0),
            .init(family: .ipv4, addressBytes: Data([127, 0, 0, 1]), scopeID: 1, interfaceIndex: 0),
            .init(family: .ipv6, addressBytes: Data(repeating: 0, count: 16), scopeID: 0, interfaceIndex: 0)
        ]
        for candidate in values { XCTAssertThrowsError(try SMBPreparedConnection.select(address, candidates: [candidate])) }
        XCTAssertThrowsError(try SMBPreparedConnection.select(address, candidates: []))
        XCTAssertThrowsError(try SMBPreparedConnection.select(address, candidates: Array(repeating: values[0], count: 17)))
    }
    func testPrivateCredentialFrameIsBoundedAndDoesNotUseRawFields() throws {
        let secret = try SMBPassword("generated password with spaces\n")
        let frame = SMBPreparedConnection.credentials(account: "generated-user", domain: "GENERATED", password: secret)
        let line = String(decoding: frame, as: UTF8.self)
        XCTAssertEqual(line.split(separator: " ").count, 4)
        XCTAssertFalse(line.contains("generated-user")); XCTAssertFalse(line.contains("generated password")); XCTAssertFalse(line.contains("GENERATED"))
        XCTAssertTrue(line.hasSuffix("\n")); XCTAssertEqual(frame.filter { $0 == 10 }.count, 1)
    }
    func testPrecancelledPreparationAdmitsNoResolverActivity() async throws {
        let activity = FileActivityGate(maximumActivities: 1), address = try SMBConnectionAddress("smb://127.0.0.1/Shared")
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SMBPreparedConnection.prepare(address, bundleURL: URL(fileURLWithPath: "/unused-generated-resolver"), activity: activity)
        }
        do { _ = try await work.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(activity.activeCount, 0)
    }
}
