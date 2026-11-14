import CryptoKit
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

#if TRAVERSE_SFTP_EDITOR_QA
final class SFTPAgentProtocolTests: XCTestCase {
    private let session = UUID(uuidString: "B2D8203E-2545-4563-B02D-E950547BFDF1")!
    private let mode = SFTPWireMode.agentCatalog

    private func event(_ sequence: UInt64, _ kind: UInt8, _ payload: Data = Data()) throws -> Data {
        try SFTPWire.body(session: session, sequence: sequence, kind: kind, mode: mode) + payload
    }
    private func verified() throws -> SFTPWorkerDecoder {
        var decoder = try SFTPWorkerDecoder(session: session, canonicalHost: "generated.example", port: 22, mode: mode)
        var hostKey = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &hostKey)
        try SFTPWire.field(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, into: &hostKey)
        var challenge = Data([1]); try SFTPWire.field(Data("generated.example".utf8), into: &challenge)
        SFTPWire.number(22, bytes: 2, into: &challenge)
        try SFTPWire.field(hostKey, into: &challenge); try SFTPWire.field(Data(), into: &challenge)
        guard case .challenge(let review) = try decoder.consume(event(0, 100, challenge)) else {
            throw SFTPProtocolFailure.phase
        }
        try decoder.noteApproval(.connectOnce, challenge: review)
        _ = try decoder.consume(event(1, 101))
        return decoder
    }

    func testExactListedDigestMustBeSelectedBeforeAuthenticationAndReady() throws {
        XCTAssertTrue(mode.isCatalog)
        XCTAssertFalse(mode.allowsDownloads || mode.allowsUploads || mode.allowsInteractiveAuthentication)
        var early = try verified()
        XCTAssertThrowsError(try early.consume(event(2, 102)))
        var decoder = try verified()
        try decoder.noteAgentList()
        let digest = Data(repeating: 7, count: 32)
        var listing = Data([1]); listing.append(digest)
        try SFTPWire.field(Data("ssh-ed25519".utf8), into: &listing)
        guard case .agentIdentities(let identities) = try decoder.consume(event(2, 138, listing)),
              let identity = identities.first else { return XCTFail("Agent listing was not accepted") }
        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identity.digest, digest)
        XCTAssertEqual(String(describing: identity), "<SFTP agent identity>")
        XCTAssertThrowsError(try decoder.noteAgentList())
        try decoder.noteAgentSelection(identity)
        guard case .agentSelected(let selected) = try decoder.consume(event(3, 139, digest)) else {
            return XCTFail("Selected identity evidence was not accepted")
        }
        XCTAssertEqual(selected, digest)
        guard case .authenticated = try decoder.consume(event(4, 102)),
              case .ready = try decoder.consume(event(5, 109)) else {
            return XCTFail("Agent authentication did not reach metadata ready")
        }
    }

    func testAgentModeRefusesUnselectedIdentityAndKeyCredentialEvidence() throws {
        let digest = Data(repeating: 7, count: 32)
        var listing = Data([1]); listing.append(digest)
        try SFTPWire.field(Data("ssh-ed25519".utf8), into: &listing)
        var unrequested = try verified()
        XCTAssertThrowsError(try unrequested.consume(event(2, 138, listing)))
        var decoder = try verified(); try decoder.noteAgentList()
        guard case .agentIdentities(let identities) = try decoder.consume(event(2, 138, listing)),
              let identity = identities.first else { return XCTFail() }
        var beforeSelection = decoder
        XCTAssertThrowsError(try beforeSelection.consume(event(3, 139, digest)))
        try decoder.noteAgentSelection(identity)
        var wrong = decoder
        XCTAssertThrowsError(try wrong.consume(event(3, 139, Data(repeating: 8, count: 32))))
        var oldKeyEvidence = decoder
        var publicKey = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &publicKey)
        try SFTPWire.field(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, into: &publicKey)
        var evidence = Data(); try SFTPWire.field(publicKey, into: &evidence)
        XCTAssertThrowsError(try oldKeyEvidence.consume(event(3, 135, evidence)))
        XCTAssertThrowsError(try decoder.noteKeyAuthentication(expected: nil))
    }
}
#endif
