import Darwin
import Foundation

/// Concrete shared host/port parser for SMB and SFTP. No DNS, credentials,
/// saved identity, protocol fallback or local-file interpretation.
struct RemoteNetworkAuthority: Sendable {
    enum Kind: Int, Sendable { case dns, ipv4, ipv6 }
    enum Failure: Error { case invalid }
    let host: String
    let kind: Kind
    let port: UInt16
    let scopeID: UInt32
    /// Host and port fields are separate: accept a bare IPv6 literal, but never
    /// silently choose between two ports or accept credentials/a URI as a host.
    static func fieldAuthority(server: String, port: UInt16) throws -> String {
        guard port > 0, !server.contains("/"), !server.contains("\\"), !server.contains("?"), !server.contains("#") else { throw Failure.invalid }
        let authority: String
        if server.hasPrefix("[") {
            guard server.hasSuffix("]") else { throw Failure.invalid }
            authority = server
        } else if server.filter({ $0 == ":" }).count >= 2 { authority = "[" + server + "]" }
        else {
            guard !server.contains(":") else { throw Failure.invalid }
            authority = server
        }
        _ = try Self(authority, defaultPort: port)
        return authority + ":" + String(port)
    }
    init(_ authority: String, defaultPort: UInt16) throws {
        guard defaultPort > 0, !authority.isEmpty, authority.utf8.count <= 320,
              authority.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0)
                  && !CharacterSet.controlCharacters.contains($0) }), !authority.contains("@") else { throw Failure.invalid }
        let name: String, portText: String?, scope: UInt32
        if authority.hasPrefix("[") {
            guard let end = authority.firstIndex(of: "]") else { throw Failure.invalid }
            let tail = authority[authority.index(after: end)...]
            guard tail.isEmpty || tail.first == ":" else { throw Failure.invalid }
            portText = tail.isEmpty ? nil : String(tail.dropFirst())
            let literal = String(authority[authority.index(after: authority.startIndex)..<end])
            if let percent = literal.range(of: "%25") {
                let zone = String(literal[percent.upperBound...])
                guard let numeric = UInt32(zone), numeric > 0, numeric < 0xffff_fff0, String(numeric) == zone else { throw Failure.invalid }
                scope = numeric; name = String(literal[..<percent.lowerBound])
            } else { scope = 0; name = literal }
            guard let canonical = Self.numeric(name, family: AF_INET6) else { throw Failure.invalid }
            host = canonical; kind = .ipv6
            var raw = in6_addr(); guard inet_pton(AF_INET6, host, &raw) == 1 else { throw Failure.invalid }
            let bytes = withUnsafeBytes(of: raw) { Array($0) }
            guard bytes.contains(where: { $0 != 0 }), bytes[0] != 255,
                  !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) || scope > 0 else { throw Failure.invalid }
        } else {
            let pieces = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { throw Failure.invalid }
            name = String(pieces[0]); portText = pieces.count == 2 ? String(pieces[1]) : nil; scope = 0
            if let numeric = Self.numeric(name, family: AF_INET) {
                let bytes = numeric.split(separator: ".").compactMap { UInt8($0) }
                guard name == numeric, bytes.count == 4, bytes[0] > 0, bytes[0] < 224 else { throw Failure.invalid }
                host = numeric; kind = .ipv4
            } else {
                guard !name.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }), Self.validDNS(name) else { throw Failure.invalid }
                host = name.lowercased(); kind = .dns
            }
        }
        if let portText {
            guard let number = UInt16(portText), number > 0, String(number) == portText else { throw Failure.invalid }
            port = number
        } else { port = defaultPort }
        scopeID = scope
    }
    private static func validDNS(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 253, !text.hasSuffix(".") else { return false }
        return text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
    private static func numeric(_ text: String, family: Int32) -> String? {
        var bytes = [UInt8](repeating: 0, count: 16), result = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_pton(family, text, &bytes) == 1,
              inet_ntop(family, &bytes, &result, socklen_t(result.count)) != nil else { return nil }
        let end = result.firstIndex(of: 0) ?? result.count
        return String(decoding: result.prefix(end).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
