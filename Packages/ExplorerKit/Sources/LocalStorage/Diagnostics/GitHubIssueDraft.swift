import Foundation

/// An explicitly opened browser draft. This value performs no network or
/// clipboard operation and never includes retained native capture bytes.
public struct GitHubIssueDraft: Equatable, Sendable {
    public static let maximumURLBytes = 8 << 10
    public static let abbreviatedHeading = "## Abbreviated report"
    public let url: URL
    public let includesFullReport: Bool

    public init(report: String, title: String = "Bug report: Traverse") throws {
        guard !report.isEmpty else { throw CrashReportFailure.invalid }
        guard report.utf8.count <= CrashReportRedaction.maximumBytes else { throw CrashReportFailure.capacity }
        guard !title.isEmpty, title.utf8.count <= 160, title.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || " ._:-()".utf8.contains(byte)
        }) else { throw CrashReportFailure.invalid }

        // Encoding cannot shorten UTF-8. Avoid encoding a 512 KiB document
        // merely to discover that it exceeds the browser URL budget.
        if report.utf8.count <= Self.maximumURLBytes {
            let complete = try Self.makeURL(title: title, body: report)
            if complete.absoluteString.utf8.count <= Self.maximumURLBytes {
                url = complete; includesFullReport = true
                return
            }
        }
        var prefix = Array(report.utf8.prefix(1024))
        // A bounded byte prefix may end within a multi-byte scalar. Remove
        // only that incomplete suffix, preserving the user's Unicode text.
        while String(bytes: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        let excerpt = String(decoding: prefix, as: UTF8.self)
        let body = """
            \(Self.abbreviatedHeading)

            The full reviewed report exceeds Traverse's browser URL limit. This draft contains only an excerpt. Use Copy Report or Save Report in Traverse to share the full reviewed text after checking it.

            ## Report excerpt

            \(excerpt)

            [Remaining report omitted from this draft.]
            """
        let abbreviated = try Self.makeURL(title: title, body: body)
        guard abbreviated.absoluteString.utf8.count <= Self.maximumURLBytes else { throw CrashReportFailure.capacity }
        url = abbreviated; includesFullReport = false
    }

    private static func makeURL(title: String, body: String) throws -> URL {
        // Only RFC 3986 unreserved characters remain literal. In particular,
        // '+' must be %2B so form-style query decoders preserve C++ and comments.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let title = title.addingPercentEncoding(withAllowedCharacters: allowed),
              let body = body.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://github.com/Respawn-Studios/Traverse/issues/new?title=\(title)&body=\(body)") else {
            throw CrashReportFailure.invalid
        }
        return url
    }
}
