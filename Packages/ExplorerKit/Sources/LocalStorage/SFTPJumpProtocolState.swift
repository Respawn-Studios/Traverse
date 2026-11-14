import Foundation

/// Outer identity is independent of both the IPC session and the inner peer.
struct SFTPJumpIdentity: Sendable {
    let nonce: UUID
    let host: String
    let port: UInt16
    var previous: SFTPHostKey? = nil
}
enum SFTPJumpProtocolEvent: Sendable {
    case challenge(SFTPHostChallenge), verified(SFTPHostChallenge)
    case identity(SFTPHostKey), authenticated, prompts(SFTPInteractiveChallenge)
}
/// One outer authentication only. The enclosing decoder owns poisoning,
/// version/session/sequence and the transition into the destination decoder.
struct SFTPJumpProtocolState: Sendable {
    private enum Phase: Sendable { case review, approval, authentication, complete }
    let identity: SFTPJumpIdentity
    private let permitsRememberedRoute: Bool
    private var phase: Phase = .review
    private var challenge: SFTPHostChallenge?
    private var approved: SFTPTrustAction?
    private var started = false, usingKey = false, interactive = false, receivedIdentity = false
    private var round: UInt8 = 0
    private var pending: SFTPInteractiveChallenge?
    private var expectedIdentity: SFTPHostKey?
    var complete: Bool { phase == .complete }
    init(identity: SFTPJumpIdentity, permitsRememberedRoute: Bool = false) { self.identity = identity; self.permitsRememberedRoute = permitsRememberedRoute }
    mutating func approve(_ action: SFTPTrustAction, review: SFTPHostChallenge) throws {
        guard phase == .approval, review == challenge, approved == nil,
              review.permits(action), permitsRememberedRoute ? action != .remember : action == .reject || action == .connectOnce else { throw SFTPProtocolFailure.trust }
        approved = action
    }
    mutating func beginAuthentication(key: Bool, interactive: Bool, expected: SFTPHostKey? = nil) throws {
        guard phase == .authentication, !started else { throw SFTPProtocolFailure.phase }
        guard expected == nil || permitsRememberedRoute && key else { throw SFTPProtocolFailure.phase }
        expectedIdentity = expected
        started = true; usingKey = key; self.interactive = interactive
    }
    mutating func answer(_ challenge: SFTPInteractiveChallenge, answers: SFTPInteractiveAnswers) throws {
        guard phase == .authentication, started, interactive, pending == challenge,
              answers.values.count == challenge.prompts.count else { throw SFTPProtocolFailure.phase }
        pending = nil
    }
    mutating func consume(_ kind: UInt64, cursor: inout SFTPCursor) throws -> SFTPJumpProtocolEvent {
        guard try cursor.token() == identity.nonce else { throw SFTPProtocolFailure.stale }
        switch kind {
        case 142:
            guard phase == .review else { throw SFTPProtocolFailure.phase }
            let declared = try cursor.number(1), host = try cursor.text(cap: 253), port = try cursor.number(2)
            let key = try SFTPHostKey(cursor.field(cap: 16384)), previous = try cursor.field(cap: 16384)
            let old = try previous.isEmpty ? nil : SFTPHostKey(previous)
            guard host == identity.host, port == identity.port, old == identity.previous,
                  permitsRememberedRoute || old == nil else { throw SFTPProtocolFailure.trust }
            let review = SFTPHostChallenge(session: identity.nonce, host: host, port: UInt16(port), current: key, previous: old)
            guard declared == UInt64(review.kind.rawValue) else { throw SFTPProtocolFailure.trust }
            challenge = review; phase = .approval; return .challenge(review)
        case 143:
            guard phase == .approval, let approved, approved != .reject, let challenge,
                  challenge.permits(approved) else { throw SFTPProtocolFailure.trust }
            phase = .authentication; return .verified(challenge)
        case 144:
            guard phase == .authentication, started, usingKey, !receivedIdentity, pending == nil else { throw SFTPProtocolFailure.phase }
            let key = try SFTPHostKey(cursor.field(cap: 16384))
            guard expectedIdentity == nil || expectedIdentity == key else { throw SFTPProtocolFailure.trust }
            receivedIdentity = true; return .identity(key)
        case 145:
            guard phase == .authentication, started, usingKey == receivedIdentity, pending == nil else { throw SFTPProtocolFailure.phase }
            phase = .complete; return .authenticated
        case 146:
            guard phase == .authentication, started, interactive, !receivedIdentity, pending == nil, round < 8 else { throw SFTPProtocolFailure.phase }
            let next = try cursor.number(1), seconds = try cursor.number(2)
            let name = try cursor.serverText(cap: 256), instructions = try cursor.serverText(cap: 4096), count = try cursor.number(1)
            guard next == UInt64(round) + 1, count <= 8 else { throw SFTPProtocolFailure.phase }
            var prompts: [SFTPInteractivePrompt] = []
            for _ in 0..<count {
                let echo = try cursor.boolean(), text = try cursor.serverText(cap: 1024)
                prompts.append(try .init(text: text, echo: echo))
            }
            let challenge = try SFTPInteractiveChallenge(session: identity.nonce, round: UInt8(next), host: identity.host,
                port: identity.port, name: name, instructions: instructions, prompts: prompts, responseSeconds: UInt16(seconds))
            round = UInt8(next); pending = challenge; return .prompts(challenge)
        default: throw SFTPProtocolFailure.invalidOutput
        }
    }
}
