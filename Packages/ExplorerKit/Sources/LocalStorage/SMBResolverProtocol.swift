import Foundation

@_spi(Qualification) public struct SMBResolvedAddress: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Family: Int, Sendable { case ipv4 = 4, ipv6 = 6 }
    public let family: Family
    public let addressBytes: Data
    public let scopeID: UInt32
    public let interfaceIndex: UInt32
    public var description: String { "Resolved network address" }
    public var debugDescription: String { description }
}

@_spi(Qualification) public enum SMBResolutionFailure: String, Error, Sendable {
    case busy, invalidInput, unavailable, invalidOutput, stopped, deadline, containment, workerExited
}

struct SMBResolverTerminal: Sendable {
    let outcome: String
    let addresses: [SMBResolvedAddress]
    let callbackCount: Int
    let submitted: Bool
    let deallocated: Bool
}

/// A finite address observation is publishable only after its exact terminal.
/// No endpoint is sent to SMB, and no credential is acquired, by this decoder.
struct SMBResolverDecoder {
    let generation: UUID
    private(set) var terminal: SMBResolverTerminal?
    private(set) var started = false
    private var sequence = 0
    private var addresses: [SMBResolvedAddress] = []
    private var seen = Set<SMBResolvedAddress>()

    init(generation: UUID) { self.generation = generation }

    mutating func consume(_ line: Data) throws -> SMBResolverTerminal? {
        guard terminal == nil, !line.isEmpty, line.count <= 1024,
              line.allSatisfy({ (32...126).contains($0) }), let text = String(data: line, encoding: .ascii) else {
            throw SMBResolutionFailure.invalidOutput
        }
        let fields = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4, fields[0] == "MEXDNS1", fields[1] == generation.uuidString,
              try number(fields[2], Int.self) == sequence, sequence <= 17 else { throw SMBResolutionFailure.invalidOutput }
        sequence += 1
        switch fields[3] {
        case "started":
            guard fields.count == 4, !started, addresses.isEmpty else { throw SMBResolutionFailure.invalidOutput }
            started = true; return nil
        case "address":
            guard started, fields.count == 8, addresses.count < 16,
                  let family = SMBResolvedAddress.Family(rawValue: try number(fields[4], Int.self)) else { throw SMBResolutionFailure.invalidOutput }
            let bytes = try addressBytes(fields[5], count: family == .ipv4 ? 4 : 16)
            let scope = try number(fields[6], UInt32.self), interface = try number(fields[7], UInt32.self)
            if family == .ipv4 {
                guard scope == 0, bytes[0] != 0, bytes[0] < 224, bytes != Data(repeating: 255, count: 4) else { throw SMBResolutionFailure.invalidOutput }
            } else {
                guard bytes.contains(where: { $0 != 0 }), bytes[0] != 255 else { throw SMBResolutionFailure.invalidOutput }
                if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 {
                    guard scope > 0, scope < 0xffff_fff0 else { throw SMBResolutionFailure.invalidOutput }
                }
            }
            let value = SMBResolvedAddress(family: family, addressBytes: bytes, scopeID: scope, interfaceIndex: interface)
            guard seen.insert(value).inserted else { throw SMBResolutionFailure.invalidOutput }
            addresses.append(value); return nil
        case "done":
            guard fields.count == 9, ["resolved", "failed", "stopped", "deadline", "limit", "invalid-input", "daemon-error", "invalid-address"].contains(fields[4]),
                  try number(fields[5], Int.self) == addresses.count,
                  try number(fields[6], Int.self) <= 256, ["0", "1"].contains(fields[7]), ["0", "1"].contains(fields[8]),
                  (fields[4] == "resolved" ? !addresses.isEmpty : addresses.isEmpty),
                  (started || addresses.isEmpty && fields[5...8] == ["0", "0", "0", "0"]),
                  fields[4] != "resolved" || fields[7] != "1" || fields[8] == "1" else { throw SMBResolutionFailure.invalidOutput }
            let result = SMBResolverTerminal(outcome: fields[4], addresses: addresses,
                callbackCount: try number(fields[6], Int.self), submitted: fields[7] == "1", deallocated: fields[8] == "1")
            terminal = result; return result
        default: throw SMBResolutionFailure.invalidOutput
        }
    }
    private func number<T: FixedWidthInteger>(_ text: String, _ type: T.Type) throws -> T {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = T(text), String(value) == text else { throw SMBResolutionFailure.invalidOutput }
        return value
    }
    private func addressBytes(_ hex: String, count: Int) throws -> Data {
        let raw = Array(hex.utf8)
        guard raw.count == count * 2, raw.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SMBResolutionFailure.invalidOutput
        }
        var value = Data()
        for index in stride(from: 0, to: raw.count, by: 2) {
            guard let byte = UInt8(String(decoding: raw[index..<index+2], as: UTF8.self), radix: 16) else { throw SMBResolutionFailure.invalidOutput }
            value.append(byte)
        }
        return value
    }
}
