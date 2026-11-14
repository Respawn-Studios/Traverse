import Foundation

@_spi(Qualification) public enum SMBWorkerSecurityPolicy: String, Sendable, Codable {
    case encrypted
    case signedCompatibility = "signed"
}
@_spi(Qualification) public enum SMBWorkerSecurity: String, Sendable { case encrypted, signed }
@_spi(Qualification) public enum SMBGeneratedShare: String, Sendable {
    case standard = "ExplorerQA", requiresEncryption = "EncryptedQA", denied = "DeniedQA"
}
enum SMBWorkerWireProfile: Sendable {
    case guestQualification, authenticated(SMBWorkerSecurityPolicy)
    var prefix: String {
        switch self { case .guestQualification: "MEXSMB1"; case .authenticated: "MEXSMB2" }
    }
    var authenticated: Bool { if case .authenticated = self { true } else { false } }
}

/// Observations only. No local URL, descriptor or mutation authority is exposed.
@_spi(Qualification) public struct SMBWorkerEntry: Sendable, Equatable {
    public let name: String
    public let wireName: Data
    public let attributes: UInt32
    public let logicalBytes: UInt64
    public var isDirectory: Bool { attributes & 0x10 != 0 }
}

@_spi(Qualification) public struct SMBWorkerPage: Sendable {
    public let readID: UUID
    public let index: Int
    public let entries: [SMBWorkerEntry]
}

@_spi(Qualification) public enum SMBWorkerFailure: String, Error, Sendable {
    case busy, unavailable, invalidOutput, stopped, remote, deadline, workerExited, containment
    case authentication, denied, security
}

struct SMBWorkerTerminal: Sendable {
    let outcome: String
    let joined: Int
    let pending: Int
    let tasks: Int
    let observed: Int
    let drainMicroseconds: UInt64
    let commands: [UInt64]
    let beforeOwnerAdmission: Bool
    var provesDrain: Bool {
        (joined == 4 || beforeOwnerAdmission && joined == 0 && observed == 0 && commands.allSatisfy { $0 == 0 })
            && pending == 0 && tasks == 0 && drainMicroseconds <= 2_000_000
    }
}

enum SMBWorkerEvent: Sendable {
    case connected, page(SMBWorkerPage), readEnd(UUID, Int), closed(SMBWorkerTerminal)
}

/// Pure versioned decoder. A page is published only after its exact commit.
struct SMBWorkerDecoder {
    let session: UUID
    let profile: SMBWorkerWireProfile
    private(set) var connected = false
    private(set) var security: SMBWorkerSecurity?
    private(set) var terminal: SMBWorkerTerminal?
    private(set) var activeRead: UUID?
    private var sequence: UInt64 = 0
    private var nextPage = 0
    private var pending: [SMBWorkerEntry] = []
    private var names = Set<Data>()
    private var retained = 0

    init(session: UUID, profile: SMBWorkerWireProfile = .guestQualification) { self.session = session; self.profile = profile }
    mutating func beginRead(_ id: UUID) throws {
        guard connected, terminal == nil, activeRead == nil else { throw SMBWorkerFailure.busy }
        activeRead = id; nextPage = 0; pending = []; names = []; retained = 0
    }
    mutating func consume(_ data: Data) throws -> SMBWorkerEvent? {
        guard terminal == nil, !data.isEmpty, data.count <= 16_512,
              data.allSatisfy({ (32...126).contains($0) }), let text = String(data: data, encoding: .ascii) else {
            throw SMBWorkerFailure.invalidOutput
        }
        let fields = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 5, fields[0] == profile.prefix, fields[1] == session.uuidString,
              try number(fields[3], UInt64.self) == sequence, sequence <= 1_000_000 else { throw SMBWorkerFailure.invalidOutput }
        sequence += 1
        let read = fields[2] == "-" ? nil : UUID(uuidString: fields[2])
        guard fields[2] == "-" || read?.uuidString == fields[2] else { throw SMBWorkerFailure.invalidOutput }
        switch fields[4] {
        case "connected":
            guard !connected, read == nil, activeRead == nil else { throw SMBWorkerFailure.invalidOutput }
            switch profile {
            case .guestQualification: guard fields.count == 5 else { throw SMBWorkerFailure.invalidOutput }
            case .authenticated(let policy):
                guard fields.count == 6, let actual = SMBWorkerSecurity(rawValue: fields[5]),
                      policy != .encrypted || actual == .encrypted else { throw SMBWorkerFailure.security }
                security = actual
            }
            connected = true; return .connected
        case "row":
            guard connected, let id = activeRead, read == id, fields.count == 8, pending.count < 256 else { throw SMBWorkerFailure.invalidOutput }
            let attributes = try number(fields[5], UInt32.self), size = try number(fields[6], UInt64.self)
            guard size <= UInt64(Int64.max) else { throw SMBWorkerFailure.invalidOutput }
            let (name, wire) = try Self.name(fields[7])
            retained += wire.count + name.utf8.count + 128
            guard names.insert(wire).inserted, names.count <= 4096, retained <= 8 << 20 else { throw SMBWorkerFailure.invalidOutput }
            pending.append(SMBWorkerEntry(name: name, wireName: wire, attributes: attributes, logicalBytes: size))
            return nil
        case "page":
            guard connected, let id = activeRead, read == id, fields.count == 7,
                  try number(fields[5], Int.self) == nextPage,
                  try number(fields[6], Int.self) == pending.count, !pending.isEmpty, nextPage < 64 else { throw SMBWorkerFailure.invalidOutput }
            let page = SMBWorkerPage(readID: id, index: nextPage, entries: pending)
            nextPage += 1; pending.removeAll(keepingCapacity: true); return .page(page)
        case "readEnd":
            guard connected, let id = activeRead, read == id, fields.count == 6, pending.isEmpty,
                  try number(fields[5], Int.self) == names.count else { throw SMBWorkerFailure.invalidOutput }
            activeRead = nil; return .readEnd(id, names.count)
        case "closed":
            guard fields.count == 12, read == activeRead,
                  (["stopped", "remote-error", "request-deadline", "ipc-closed", "invalid-result"]
                    + (profile.authenticated ? ["authentication", "denied", "security"] : [])).contains(fields[5]) else { throw SMBWorkerFailure.invalidOutput }
            let commands = try fields[11].split(separator: ",", omittingEmptySubsequences: false).map { try number(String($0), UInt64.self) }
            guard commands.count == 19, [7,8,9,10,11,15,16,17,18].allSatisfy({ commands[$0] == 0 }) else { throw SMBWorkerFailure.invalidOutput }
            let value = SMBWorkerTerminal(outcome: fields[5], joined: try number(fields[6], Int.self),
                pending: try number(fields[7], Int.self), tasks: try number(fields[8], Int.self),
                observed: try number(fields[9], Int.self), drainMicroseconds: try number(fields[10], UInt64.self), commands: commands,
                beforeOwnerAdmission: !connected && activeRead == nil)
            guard value.observed <= 64 * 4096,
                  value.joined != 0 || value.beforeOwnerAdmission && commands.allSatisfy({ $0 == 0 }) && value.observed == 0 else { throw SMBWorkerFailure.invalidOutput }
            terminal = value; return .closed(value)
        default: throw SMBWorkerFailure.invalidOutput
        }
    }
    private func number<T: FixedWidthInteger>(_ text: String, _ type: T.Type) throws -> T {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = T(text), String(number) == text else { throw SMBWorkerFailure.invalidOutput }
        return number
    }
    private static func name(_ hex: String) throws -> (String, Data) {
        let bytes = Array(hex.utf8)
        guard !bytes.isEmpty, bytes.count <= 8192, bytes.count % 4 == 0,
              bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw SMBWorkerFailure.invalidOutput }
        var wire = Data(), units: [UInt16] = []
        for start in stride(from: 0, to: bytes.count, by: 4) {
            guard let unit = UInt16(String(decoding: bytes[start..<start+4], as: UTF8.self), radix: 16) else { throw SMBWorkerFailure.invalidOutput }
            units.append(unit); wire.append(UInt8(unit & 255)); wire.append(UInt8(unit >> 8))
        }
        var index = 0
        while index < units.count {
            let value = units[index]
            if (0xd800...0xdbff).contains(value) {
                guard index + 1 < units.count, (0xdc00...0xdfff).contains(units[index+1]) else { throw SMBWorkerFailure.invalidOutput }
                index += 2
            } else {
                guard !(0xdc00...0xdfff).contains(value) else { throw SMBWorkerFailure.invalidOutput }; index += 1
            }
        }
        let name = String(decoding: units, as: UTF16.self)
        guard name != ".", name != "..", name.utf8.count <= 4096,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "/" || $0 == "\\" }) else { throw SMBWorkerFailure.invalidOutput }
        return (name, wire)
    }
}
