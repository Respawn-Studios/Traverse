import Foundation

/// The two concrete setup owners expose only the operations needed while a
/// human answers a verified peer. Browsing and credential lookup stay separate.
@_spi(Qualification) public protocol SFTPAuthenticationReviewControl: Sendable {
    var review: SFTPHostChallenge { get }
    func approve(_ action: SFTPTrustAction) async throws
    func checkInteractiveChallenge(_ challenge: SFTPInteractiveChallenge) async throws
    func close() async -> SFTPWorkerClose
}

@_spi(Qualification) public struct SFTPInteractivePrompt: Sendable, Equatable {
    public let text: String
    public let echo: Bool
    public init(text: String, echo: Bool) throws {
        guard text.utf8.count <= 1024 else { throw SFTPSessionFailure.output }
        self.text = text; self.echo = echo
    }
}

/// Presentation data, never host-trust evidence or permission to run a command.
/// Responses must be bound to the owner's exact pending session/round object.
@_spi(Qualification) public struct SFTPInteractiveChallenge: Sendable, Equatable, Identifiable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let session: UUID
    public let round: UInt8
    public let host: String
    public let port: UInt16
    public let name: String
    public let instructions: String
    public let prompts: [SFTPInteractivePrompt]
    public let responseSeconds: UInt16
    public var id: String { session.uuidString + ":" + String(round) }
    public var description: String { "<SSH server challenge>" }
    public var debugDescription: String { description }
    public init(session: UUID, round: UInt8, host: String, port: UInt16, name: String,
                instructions: String, prompts: [SFTPInteractivePrompt], responseSeconds: UInt16) throws {
        guard SFTPWire.validToken(session), (1...8).contains(round), !host.isEmpty, host.utf8.count <= 253,
              port > 0, name.utf8.count <= 256, instructions.utf8.count <= 4096, prompts.count <= 8,
              prompts.allSatisfy({ $0.text.utf8.count <= 1024 }), (1...120).contains(responseSeconds) else { throw SFTPSessionFailure.output }
        self.session = session; self.round = round; self.host = host; self.port = port
        self.name = name; self.instructions = instructions; self.prompts = prompts; self.responseSeconds = responseSeconds
    }
    /// Render literal remote text without interpreting markup, links, terminal
    /// escapes or direction overrides. Newlines/tabs remain useful instructions.
    public static func displayText(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            if scalar.value == 10 || scalar.value == 9 { return String(scalar) }
            if CharacterSet.controlCharacters.contains(scalar) || [0x061c,0x200e,0x200f].contains(scalar.value)
                || (0x202a...0x202e).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) {
                return "\\u{\(String(scalar.value,radix:16))}"
            }
            return String(scalar)
        }.joined()
    }
}

@_spi(Qualification) public struct SFTPInteractiveAnswers: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let values: [Data]
    public init(_ answers: [String]) throws {
        guard answers.count <= 8, answers.allSatisfy({ $0.utf8.count <= 4096 && !$0.utf8.contains(0) }),
              answers.reduce(0, { $0 + $1.utf8.count }) <= 8192 else { throw SFTPSessionFailure.input }
        let values = answers.map { Data($0.utf8) }
        guard values.count <= 8, values.allSatisfy({ $0.count <= 4096 && !$0.contains(0) }),
              values.reduce(0, { $0 + $1.count }) <= 8192 else { throw SFTPSessionFailure.input }
        self.values = values
    }
    public var description: String { "<SSH challenge answers>" }
    public var debugDescription: String { description }
}

@_spi(Qualification) public enum SFTPInteractiveStep: Sendable {
    case challenge(SFTPInteractiveChallenge)
    case complete
}
