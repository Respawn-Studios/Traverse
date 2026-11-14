import Foundation

/// One product-owned origin and a closed resource layout. Invitation details
/// are never put in a URL, query string, feed or release-note body.
public struct PrivateUpdateEndpoint: Sendable, Equatable {
    public static let production = Self(origin: URL(string: "https://respawn-studios.com")!)
    public let origin: URL
    private init(origin: URL) { self.origin = origin }
    public var feed: URL { origin.appendingPathComponent("products/traverse/updates/appcast.xml") }
    public func permits(_ url: URL) -> Bool {
        guard let a = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              let b = URLComponents(url: url, resolvingAgainstBaseURL: false),
              b.scheme == a.scheme, b.host == a.host, b.port == a.port,
              b.user == nil, b.password == nil, b.query == nil, b.fragment == nil,
              !b.percentEncodedPath.contains("%"), url.path == b.percentEncodedPath else { return false }
        let prefix = "/products/traverse/updates/"
        guard b.path.hasPrefix(prefix) else { return false }
        let leaf = String(b.path.dropFirst(prefix.count))
        if leaf == "appcast.xml" { return true }
        if leaf.range(of: #"^notes/(?:[1-9][0-9]{0,9}|[a-f0-9]{64})\.html$"#, options: .regularExpression) != nil { return true }
        return leaf.range(of: #"^archives/[a-f0-9]{64}\.dmg$"#, options: .regularExpression) != nil
    }
    public func maximumBytes(for url: URL) -> Int {
        url.path.hasSuffix(".dmg") ? 128 << 20 : url.path.hasSuffix(".html") ? 1 << 20 : 2 << 20
    }
    // Internal test composition only; the application uses production.
    static func loopback(port: Int) throws -> Self {
        guard (1024...65535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)") else { throw PrivateUpdateFailure.invalidInput }
        return Self(origin: url)
    }
}

public enum PrivateUpdateFailure: Error, Sendable, Equatable {
    case invalidInput, authentication, unavailable, denied, cancelled, redirected, capacity, busy, changed, rateLimited
}

public struct PrivateUpdateInvitation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String
    public var description: String { "PrivateUpdateInvitation(<hidden>)" }
    public var debugDescription: String { description }
    public init(_ value: String) throws {
        guard (1...512).contains(value.utf8.count), !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PrivateUpdateFailure.invalidInput
        }
        self.value = value
    }
    public var authorization: String { "Basic " + Data(("traverse-beta:" + value).utf8).base64EncodedString() }
    var data: Data { Data(value.utf8) }
}
