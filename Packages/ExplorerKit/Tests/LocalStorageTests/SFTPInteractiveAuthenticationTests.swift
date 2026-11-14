import CryptoKit
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SFTPInteractiveAuthenticationTests: XCTestCase, @unchecked Sendable {
    private struct Wire {
        let session = UUID(), mode: SFTPWireMode = .interactiveCatalog
        let key: SFTPHostKey
        init() throws {
            var bytes = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &bytes)
            try SFTPWire.field(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, into: &bytes); key = try SFTPHostKey(bytes)
        }
        func event(_ kind: UInt8, _ sequence: UInt64, _ payload: Data = Data()) throws -> Data {
            var bytes = try SFTPWire.body(session: session, sequence: sequence, kind: kind, mode: mode); bytes.append(payload); return bytes
        }
        func decoder(keyAuthentication: Bool = false) throws -> SFTPWorkerDecoder {
            var decoder = try SFTPWorkerDecoder(session: session, canonicalHost: "generated.example", port: 22, previous: nil, mode: mode)
            var payload = Data([1]); try SFTPWire.field(Data("generated.example".utf8), into: &payload)
            SFTPWire.number(22, bytes: 2, into: &payload); try SFTPWire.field(key.bytes, into: &payload); try SFTPWire.field(Data(), into: &payload)
            guard case .challenge(let challenge) = try decoder.consume(event(100,0,payload)) else { throw SFTPProtocolFailure.phase }
            try decoder.noteApproval(.connectOnce, challenge: challenge); _ = try decoder.consume(event(101,1))
            try decoder.noteInteractiveAuthentication(expected: keyAuthentication ? key : nil, usingKey: keyAuthentication); return decoder
        }
        func prompt(round: UInt8 = 1, seconds: UInt16 = 120, count: UInt8 = 1, echo: UInt8 = 0) throws -> Data {
            var payload = Data([round]); SFTPWire.number(UInt64(seconds), bytes: 2, into: &payload)
            try SFTPWire.field(Data(), into: &payload); try SFTPWire.field(Data("Literal\nserver instructions".utf8), into: &payload); payload.append(count)
            for _ in 0..<count { payload.append(echo); try SFTPWire.field(Data("Code".utf8), into: &payload) }; return payload
        }
    }
    func testChallengeRequiresExactRoundAnswersAndAuthenticatedIdentityOrdering() throws {
        let wire = try Wire(); var decoder = try wire.decoder(keyAuthentication: true)
        guard case .interactiveChallenge(let challenge) = try decoder.consume(wire.event(136,2,wire.prompt())) else { return XCTFail("Missing challenge") }
        XCTAssertEqual(challenge.host,"generated.example"); XCTAssertEqual(challenge.port,22); XCTAssertEqual(challenge.prompts.count,1)
        try decoder.noteInteractiveAnswers(challenge, answers: .init(["private-generated-response"]))
        var identity = Data(); try SFTPWire.field(wire.key.bytes, into: &identity)
        guard case .authenticatedIdentity = try decoder.consume(wire.event(135,3,identity)),
              case .authenticated = try decoder.consume(wire.event(102,4)), case .ready = try decoder.consume(wire.event(109,5)) else { return XCTFail("Incomplete sign-in") }
    }
    func testPendingChallengePreventsPrematureAuthenticationAndWrongRound() throws {
        let wire = try Wire(); var decoder = try wire.decoder()
        _ = try decoder.consume(wire.event(136,2,wire.prompt()))
        XCTAssertThrowsError(try decoder.consume(wire.event(102,3)))
        var stale = try wire.decoder(); XCTAssertThrowsError(try stale.consume(wire.event(136,2,wire.prompt(round:2))))
        var repeated = try wire.decoder(); _ = try repeated.consume(wire.event(136,2,wire.prompt()))
        XCTAssertThrowsError(try repeated.consume(wire.event(136,3,wire.prompt())))
    }
    func testEmptyPromptStillNeedsExplicitResponseAndPromptBoundsAreValidated() throws {
        let wire = try Wire(); var decoder = try wire.decoder()
        guard case .interactiveChallenge(let challenge) = try decoder.consume(wire.event(136,2,wire.prompt(count:0))) else { return XCTFail("Missing explicit empty challenge") }
        try decoder.noteInteractiveAnswers(challenge, answers: .init([])); _ = try decoder.consume(wire.event(102,3)); _ = try decoder.consume(wire.event(109,4))
        for payload in [try wire.prompt(seconds:0), try wire.prompt(seconds:121), try wire.prompt(count:9), try wire.prompt(echo:2)] {
            var decoder = try wire.decoder(); XCTAssertThrowsError(try decoder.consume(wire.event(136,2,payload)))
        }
        let bytes = try wire.prompt()
        for length in 0..<bytes.count { var decoder = try wire.decoder(); XCTAssertThrowsError(try decoder.consume(wire.event(136,2,Data(bytes.prefix(length))))) }
    }
    func testAnswersStayRedactedAndUntrustedTextRemainsLiteral() throws {
        let value = try SFTPInteractiveAnswers(["private-generated", ""])
        XCTAssertFalse(String(reflecting:value).contains("private-generated"))
        XCTAssertThrowsError(try SFTPInteractiveAnswers([String(repeating:"x",count:4097)]))
        XCTAssertThrowsError(try SFTPInteractiveAnswers(["a\0b"]))
        XCTAssertThrowsError(try SFTPInteractiveAnswers([String(repeating:"x",count:4096),String(repeating:"x",count:4096),"x"]))
        XCTAssertEqual(SFTPInteractiveChallenge.displayText("<b>literal</b>\n\u{202e}\0"),"<b>literal</b>\n\\u{202e}\\u{0}")
    }
    func testVersionThreeMethodsPersistWithoutDowngradeOrSecretClaims() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let store = SFTPSettingsStore(directory:root.appendingPathComponent("settings"))
        let opened = try await store.openForExplicitWrite(); XCTAssertEqual(opened.snapshot.format,1)
        let draft = try SFTPServerDraft(name:"Generated",address:.init("generated.example"),account:"generated")
        let first = try await store.apply(.saveServer(draft,id:nil,credentialID:nil,serverPrompts:true),revision:opened.snapshot.revision)
        XCTAssertEqual(first.snapshot.format,3); XCTAssertEqual(first.snapshot.servers.first?.usesServerPrompts,true)
        let second = try await store.apply(.saveServer(draft,id:nil,credentialID:nil,keyAuthentication:.init(requiresServerPrompts:true)),revision:first.snapshot.revision)
        XCTAssertEqual(second.snapshot.servers.last?.keyAuthentication?.requiresServerPrompts,true)
        let third = try await store.apply(.saveServer(draft,id:first.serverID,credentialID:nil,keyAuthentication:.init()),revision:second.snapshot.revision)
        XCTAssertEqual(third.snapshot.format,3); XCTAssertEqual(third.snapshot.servers.first?.usesServerPrompts,false)
        XCTAssertTrue(third.snapshot.credentials.isEmpty)
        var wrongVersion = second.snapshot; wrongVersion.format = 2; XCTAssertThrowsError(try wrongVersion.validate())
        let current = try await store.inspect(); XCTAssertEqual(current?.format,3)
        await store.close()
        let fresh = SFTPSettingsStore(directory:root.appendingPathComponent("settings"))
        let reopened = try await fresh.inspect(); XCTAssertEqual(reopened?.format,3); XCTAssertTrue(reopened?.credentials.isEmpty == true)
    }
}
