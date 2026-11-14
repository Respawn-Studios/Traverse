import Foundation

/// Exact public update resources. The public lane has no invitation or
/// authorization value to place in a URL, header, or persistent store.
public struct PublicUpdateEndpoint: Sendable, Equatable {
    public static let production = Self(origin: URL(string: "https://respawn-studios.com")!)
    public static let directProduction = Self(origin: URL(string: "https://respawn-studios.com")!,
                                              lane: "direct-updates")
    public let origin: URL
    private let lane: String

    private init(origin: URL, lane: String = "public-updates") {
        self.origin = origin
        self.lane = lane
    }

    public var feed: URL { origin.appendingPathComponent("products/traverse/\(lane)/appcast.xml") }

    public func permits(_ url: URL) -> Bool {
        guard let expected = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              let actual = URLComponents(url: url, resolvingAgainstBaseURL: false),
              actual.scheme == expected.scheme, actual.host == expected.host,
              actual.port == expected.port, actual.user == nil, actual.password == nil,
              actual.query == nil, actual.fragment == nil,
              !actual.percentEncodedPath.contains("%"), url.path == actual.percentEncodedPath else { return false }

        let prefix = "/products/traverse/\(lane)/"
        guard actual.path.hasPrefix(prefix) else { return false }
        let leaf = String(actual.path.dropFirst(prefix.count))
        if leaf == "appcast.xml" { return true }
        if leaf.range(of: #"^notes/[1-9][0-9]{0,9}\.html$"#, options: .regularExpression) != nil { return true }
        return leaf.range(of: #"^archives/[a-f0-9]{64}\.dmg$"#, options: .regularExpression) != nil
    }

    /// A zero bound makes a non-admitted resource unusable even if a caller
    /// asks for its size before checking `permits`.
    public func maximumBytes(for url: URL) -> Int {
        guard permits(url) else { return 0 }
        return url.path.hasSuffix(".dmg") ? 128 << 20 : url.path.hasSuffix(".html") ? 1 << 20 : 2 << 20
    }

    // Internal fixture only; production never permits loopback or HTTP.
    static func loopback(port: Int) throws -> Self {
        guard (1024...65535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)") else {
            throw PublicUpdateEndpointError.invalidPort
        }
        return Self(origin: url)
    }
}

enum PublicUpdateEndpointError: Error {
    case invalidPort
}
