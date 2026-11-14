import CryptoKit
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SFTPJumpProtocolTests: XCTestCase, @unchecked Sendable {
    private struct Wire {
        let session = UUID(), outer = UUID()
        let key: SFTPHostKey
        init() throws {
            var bytes = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &bytes)
            try SFTPWire.field(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, into: &bytes); key = try .init(bytes)
        }
        func decoder(mode: SFTPWireMode = .jumpCatalog, previous: SFTPHostKey? = nil) throws -> SFTPWorkerDecoder {
            try .init(session: session, canonicalHost: "private.internal.test", port: 2222, previous: previous, mode: mode,
                jump: .init(nonce: outer, host: "jump.example.test", port: 2200, previous: previous))
        }
        func event(_ kind: UInt8, _ sequence: UInt64, _ payload: Data = Data(), mode: SFTPWireMode = .jumpCatalog) throws -> Data {
            try SFTPWire.body(session: session, sequence: sequence, kind: kind, mode: mode) + payload
        }
        func challenge(jump: Bool, previous: SFTPHostKey? = nil) throws -> Data {
            var data = jump ? SFTPWire.token(outer) : Data(); data.append(previous == nil ? 1 : previous == key ? 2 : 3)
            try SFTPWire.field(Data((jump ? "jump.example.test" : "private.internal.test").utf8), into: &data)
            SFTPWire.number(jump ? 2200 : 2222, bytes: 2, into: &data); try SFTPWire.field(key.bytes, into: &data)
            try SFTPWire.field(previous?.bytes ?? Data(), into: &data); return data
        }
        func verified() throws -> SFTPWorkerDecoder {
            var decoder = try decoder()
            guard case .jumpChallenge(let review) = try decoder.consume(event(142,0,challenge(jump:true))) else { throw SFTPProtocolFailure.phase }
            try decoder.noteJumpApproval(.connectOnce, challenge: review); _ = try decoder.consume(event(143,1,SFTPWire.token(outer)))
            return decoder
        }
        func prompt() throws -> Data {
            var data = SFTPWire.token(outer); data.append(1); SFTPWire.number(120,bytes:2,into:&data)
            try SFTPWire.field(Data(),into:&data); try SFTPWire.field(Data("Generated instructions".utf8),into:&data)
            data.append(contentsOf:[1,0]); try SFTPWire.field(Data("Code".utf8),into:&data); return data
        }
    }
    func testOuterAndInnerReviewsHaveSeparateImmutableIdentityAndApproval() throws {
        let wire = try Wire(); var decoder = try wire.verified()
        try decoder.noteJumpAuthentication(key:false,interactive:false)
        _ = try decoder.consume(wire.event(145,2,SFTPWire.token(wire.outer)))
        guard case .challenge(let destination) = try decoder.consume(wire.event(100,3,wire.challenge(jump:false))) else { return XCTFail("Missing destination") }
        XCTAssertEqual(destination.session,wire.session); XCTAssertEqual(destination.host,"private.internal.test")
        try decoder.noteApproval(.connectOnce,challenge:destination)
        guard case .verified(let proof) = try decoder.consume(wire.event(101,4)) else { return XCTFail("Missing destination evidence") }
        XCTAssertEqual(proof.session,wire.session); XCTAssertEqual(proof.port,2222)
        _ = try decoder.consume(wire.event(102,5)); _ = try decoder.consume(wire.event(109,6))
        XCTAssertFalse(SFTPWireMode.jumpCatalog.allowsDownloads); XCTAssertFalse(SFTPWireMode.jumpCatalog.allowsUploads)
    }
    func testDestinationCannotSkipOuterAuthenticationOrReuseItsApproval() throws {
        let wire = try Wire(); var premature = try wire.decoder()
        XCTAssertThrowsError(try premature.consume(wire.event(100,0,wire.challenge(jump:false))))
        var unstarted = try wire.verified(); XCTAssertThrowsError(try unstarted.consume(wire.event(145,2,SFTPWire.token(wire.outer))))
        var key = try wire.verified(); try key.noteJumpAuthentication(key:true,interactive:false)
        XCTAssertThrowsError(try key.consume(wire.event(145,2,SFTPWire.token(wire.outer))))
        var approved = try wire.decoder()
        guard case .jumpChallenge(let review) = try approved.consume(wire.event(142,0,wire.challenge(jump:true))) else { return XCTFail() }
        XCTAssertThrowsError(try approved.noteJumpApproval(.remember,challenge:review))
        XCTAssertThrowsError(try approved.noteApproval(.connectOnce,challenge:review))
    }
    func testPromptAndAnswerCannotCrossRoleEvenWhenBothUseRoundOne() throws {
        let wire = try Wire(); var decoder = try wire.verified(); try decoder.noteJumpAuthentication(key:true,interactive:true)
        guard case .jumpInteractiveChallenge(let challenge) = try decoder.consume(wire.event(146,2,wire.prompt())) else { return XCTFail() }
        XCTAssertEqual(challenge.session,wire.outer); XCTAssertEqual(challenge.host,"jump.example.test")
        let wrong = try SFTPInteractiveChallenge(session:wire.session,round:1,host:"private.internal.test",port:2222,name:challenge.name,
            instructions:challenge.instructions,prompts:challenge.prompts,responseSeconds:120)
        XCTAssertThrowsError(try decoder.noteJumpAnswers(wrong,answers:.init(["generated"])))
        XCTAssertThrowsError(try decoder.noteInteractiveAnswers(challenge,answers:.init(["generated"])))
        try decoder.noteJumpAnswers(challenge,answers:.init(["generated"]))
        var identity = SFTPWire.token(wire.outer); try SFTPWire.field(wire.key.bytes,into:&identity)
        _ = try decoder.consume(wire.event(144,3,identity)); _ = try decoder.consume(wire.event(145,4,SFTPWire.token(wire.outer)))
        XCTAssertThrowsError(try decoder.consume(wire.event(146,5,wire.prompt())))
    }
    func testOuterFramesAreExactAndPoisonTruncatedStaleOrRepeatedOutput() throws {
        let wire = try Wire(), frame = try wire.event(142,0,wire.challenge(jump:true))
        for length in 0..<frame.count {
            var decoder = try wire.decoder(); XCTAssertThrowsError(try decoder.consume(Data(frame.prefix(length))))
            XCTAssertThrowsError(try decoder.consume(frame))
        }
        var wrong = try wire.challenge(jump:true); wrong.replaceSubrange(0..<16,with:SFTPWire.token(wire.session))
        var decoder = try wire.decoder(); XCTAssertThrowsError(try decoder.consume(wire.event(142,0,wrong)))
        var repeated = try wire.decoder(); _ = try repeated.consume(frame)
        XCTAssertThrowsError(try repeated.consume(wire.event(142,1,wire.challenge(jump:true))))
        XCTAssertThrowsError(try SFTPWorkerDecoder(session:wire.session,canonicalHost:"private.internal.test",port:2222,mode:.jumpCatalog))
        XCTAssertThrowsError(try SFTPWorkerDecoder(session:wire.session,canonicalHost:"private.internal.test",port:2222,mode:.interactiveCatalog,jump:.init(nonce:wire.outer,host:"jump.example.test",port:2200)))
    }
    func testRouteTerminalRetainsBothTaskFactsWithoutClaimingEitherEndedEarly() throws {
        let wire = try Wire(); var decoder = try wire.decoder()
        var payload = Data([15,0,0]); SFTPWire.number(2,bytes:8,into:&payload); SFTPWire.number(0,bytes:8,into:&payload); payload.append(contentsOf:[1,0])
        guard case .closed(let terminal) = try decoder.consume(wire.event(107,0,payload)) else { return XCTFail() }
        XCTAssertEqual(terminal.outcome,15); XCTAssertFalse(terminal.sshTaskEndedBeforeRuntimeDrop)
        XCTAssertEqual(terminal.jumpTaskEndedBeforeRuntimeDrop,false); XCTAssertTrue(terminal.runtimeDisposed)
        XCTAssertEqual(terminal.catalogWriterEnd,.closed)
    }
    func testSessionOnlyRouteRefusesDirectSavedAuthorityBeforeBookmarkResolution() async throws {
        let wire = try Wire(), request = try SFTPConnectionRequest(address:.init("sftp://private.internal.test:2222"),account:"generated")
        let reference = try SFTPKeyAccessReference(bookmark:Data("deliberately-not-a-bookmark".utf8),request:request,host:wire.key,identity:wire.key)
        let selection = try SFTPSelectedPrivateKey(reference:reference)
        let context = SFTPVerifiedSessionContext(host:request.address.host,port:request.address.port,requestedScopeID:0,account:request.account,
            key:wire.key,previous:nil,permitsRememberingHost:false,permitsSavedAuthentication:false)
        XCTAssertFalse(context.matches(request)); XCTAssertThrowsError(try context.request())
        let refused = await Task.detached { () -> Bool in
            do { _ = try selection.readAfterHostReview(context,check:{}); return false }
            catch SFTPSessionFailure.input { return true }
            catch { return false }
        }.value
        XCTAssertTrue(refused,"Must reject direct authority before asking macOS to resolve the bookmark")
    }
    func testRememberedRouteReviewsCompareBothFreshKeysAndRequireTheirOwnMatchingActions() throws {
        let wire = try Wire(), mode = SFTPWireMode.rememberedJumpCatalog
        var decoder = try wire.decoder(mode: mode, previous: wire.key)
        guard case .jumpChallenge(let outer) = try decoder.consume(wire.event(142,0,wire.challenge(jump:true,previous:wire.key),mode:mode)) else { return XCTFail() }
        XCTAssertEqual(outer.kind,.matching)
        XCTAssertThrowsError(try decoder.noteJumpApproval(.connectOnce,challenge:outer))
        try decoder.noteJumpApproval(.useMatching,challenge:outer)
        _ = try decoder.consume(wire.event(143,1,SFTPWire.token(wire.outer),mode:mode))
        try decoder.noteJumpAuthentication(key:false,interactive:false)
        _ = try decoder.consume(wire.event(145,2,SFTPWire.token(wire.outer),mode:mode))
        guard case .challenge(let inner) = try decoder.consume(wire.event(100,3,wire.challenge(jump:false,previous:wire.key),mode:mode)) else { return XCTFail() }
        XCTAssertEqual(inner.kind,.matching); try decoder.noteApproval(.useMatching,challenge:inner)
        _ = try decoder.consume(wire.event(101,4,mode:mode))
        XCTAssertFalse(mode.allowsDownloads); XCTAssertFalse(mode.allowsUploads)
        XCTAssertThrowsError(try wire.decoder(mode:.jumpCatalog,previous:wire.key))
    }
    func testRememberedRouteRefusesUnexpectedPriorKeyAndWrongAuthenticatedKeyIdentity() throws {
        let wire = try Wire(), other = try Wire(), mode = SFTPWireMode.rememberedJumpCatalog
        var wrong = try wire.decoder(mode:mode,previous:wire.key)
        XCTAssertThrowsError(try wrong.consume(wire.event(142,0,wire.challenge(jump:true,previous:other.key),mode:mode)))
        var decoder = try wire.decoder(mode:mode)
        guard case .jumpChallenge(let review) = try decoder.consume(wire.event(142,0,wire.challenge(jump:true),mode:mode)) else { return XCTFail() }
        try decoder.noteJumpApproval(.connectOnce,challenge:review)
        _ = try decoder.consume(wire.event(143,1,SFTPWire.token(wire.outer),mode:mode))
        try decoder.noteJumpAuthentication(key:true,interactive:false,expected:wire.key)
        var identity=SFTPWire.token(wire.outer); try SFTPWire.field(other.key.bytes,into:&identity)
        XCTAssertThrowsError(try decoder.consume(wire.event(144,2,identity,mode:mode)))
    }
}
