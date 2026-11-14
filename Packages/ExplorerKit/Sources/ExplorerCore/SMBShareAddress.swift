import Darwin
import Foundation

public enum SMBAddressFailure: Error, Equatable, Sendable {
    case invalidAddress, unsupportedScheme, credentialsNotAllowed, requiresOneShare, unsupportedPort
    public var userMessage: String {
        switch self {
        case .invalidAddress: "Enter an SMB address such as smb://server/share."
        case .unsupportedScheme: "Use an address beginning with smb://."
        case .credentialsNotAllowed: "Leave account details out of the address. macOS will handle authentication."
        case .requiresOneShare: "Enter one share name after the server. Subfolders can be browsed after connecting."
        case .unsupportedPort: "This connection preview supports the standard SMB port, 445."
        }
    }
}

/// Session-only address, never credentials, access or remembered-location proof.
/// Parsing is lexical and deliberately performs no DNS, probing or file reads.
public struct SMBShareAddress: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumInputBytes = 2_048
    public let host: String
    public let share: String
    public let url: URL
    public var displayAddress: String { url.absoluteString }
    public var description: String { "SMB share address" }
    public var debugDescription: String { description }

    public init(_ input: String) throws {
        guard !input.isEmpty, input.utf8.count <= Self.maximumInputBytes else { throw SMBAddressFailure.invalidAddress }
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.unicodeScalars.contains(where: Self.forbidden), !text.contains("\\"),
              let parts = URLComponents(string: text) else { throw SMBAddressFailure.invalidAddress }
        guard parts.scheme?.lowercased() == "smb", text.lowercased().hasPrefix("smb://") else { throw SMBAddressFailure.unsupportedScheme }
        guard parts.user == nil, parts.password == nil else { throw SMBAddressFailure.credentialsNotAllowed }
        guard parts.query == nil, parts.fragment == nil, let rawHost = parts.host, !rawHost.isEmpty,
              !rawHost.contains("%"), Self.validHost(rawHost) else { throw SMBAddressFailure.invalidAddress }
        if let port = parts.port, port != 445 { throw SMBAddressFailure.unsupportedPort }
        let authority = text.dropFirst(6).prefix { $0 != "/" }.lowercased()
        guard authority == rawHost.lowercased() || authority == rawHost.lowercased() + ":445" else { throw SMBAddressFailure.invalidAddress }
        let encoded = parts.percentEncodedPath
        guard encoded.hasPrefix("/"), encoded.count > 1,
              let decoded = encoded.removingPercentEncoding else { throw SMBAddressFailure.requiresOneShare }
        var path = String(decoded.dropFirst())
        if path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty, path.utf8.count <= 255, path != ".", path != "..", !path.contains("/"),
              !path.contains("\\"), !path.contains("%"), !path.unicodeScalars.contains(where: Self.forbidden),
              path != " ", !path.hasPrefix(" "), !path.hasSuffix(" ") else { throw SMBAddressFailure.requiresOneShare }
        // An encoded slash must not be mistaken for the optional trailing slash.
        let loweredPath = encoded.lowercased()
        guard !loweredPath.contains("%2f"), !loweredPath.contains("%5c") else { throw SMBAddressFailure.requiresOneShare }
        host = rawHost.lowercased(); share = path
        var canonical = URLComponents(); canonical.scheme = "smb"; canonical.host = host; canonical.path = "/" + share
        guard let address = canonical.url else { throw SMBAddressFailure.invalidAddress }; url = address
    }
    private static func forbidden(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar) || [0x061c, 0x200e, 0x200f].contains(scalar.value)
            || (0x202a...0x202e).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }
    private static func validHost(_ host: String) -> Bool {
        if host.hasPrefix("[") && host.hasSuffix("]") {
            var value = in6_addr()
            return String(host.dropFirst().dropLast()).withCString { inet_pton(AF_INET6, $0, &value) } == 1
        }
        guard host.utf8.count <= 253, host.unicodeScalars.allSatisfy({ $0.isASCII }) else { return false }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            let octets = host.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, octets.allSatisfy({ part in
                guard let value = Int(part), (0...255).contains(value) else { return false }
                return String(value) == part
            }) else { return false }
            var value = in_addr(); return host.withCString { inet_pton(AF_INET, $0, &value) } == 1
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.url.absoluteString.utf8.elementsEqual(rhs.url.absoluteString.utf8) }
    public func hash(into hasher: inout Hasher) { hasher.combine(Data(url.absoluteString.utf8)) }
}
