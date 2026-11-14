import Foundation

/// Formats explicit filename metadata. This never resolves a path, grants
/// access, opens a file or emits shell quoting/executable commands.
public enum FilenameClipboardText {
    public enum Kind: Sendable { case names, relativePaths }
    public enum Failure: Error, Equatable { case empty, tooMany, tooLarge, unsupported, unsafeLine, outsideFolder }
    public static let maximumItems = 4096
    public static let maximumUTF8Bytes = 1 << 20

    public static func make(_ urls: [URL], kind: Kind, relativeTo base: URL? = nil) throws -> String {
        guard !urls.isEmpty else { throw Failure.empty }
        guard urls.count <= maximumItems else { throw Failure.tooMany }
        let baseParts: [String]?
        if case .relativePaths = kind {
            guard let base else { throw Failure.unsupported }
            baseParts = try components(base)
        } else { baseParts = nil }
        var lines: [String] = []; lines.reserveCapacity(urls.count)
        var size = 0
        for url in urls {
            let parts = try components(url)
            let line: String
            if let baseParts {
                // UTF-8 spelling, not case/Unicode-equivalent identity. Do not
                // infer a filesystem relationship or follow an alias/symlink.
                guard parts.count >= baseParts.count,
                      zip(parts, baseParts).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) else { throw Failure.outsideFolder }
                line = parts.count == baseParts.count ? "." : parts.dropFirst(baseParts.count).joined(separator: "/")
            } else {
                guard let last = parts.last, !last.isEmpty else { throw Failure.unsupported }
                line = last
            }
            let addition = line.utf8.count + (lines.isEmpty ? 0 : 1)
            guard addition <= maximumUTF8Bytes - size else { throw Failure.tooLarge }
            size += addition; lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func components(_ url: URL) throws -> [String] {
        let spelling = url.absoluteString
        guard spelling.utf8.count <= 16_384 else { throw Failure.tooLarge }
        // Inspect one decoded spelling before Foundation can truncate a NUL.
        guard let decoded = spelling.removingPercentEncoding else { throw Failure.unsupported }
        guard !decoded.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { throw Failure.unsafeLine }
        guard url.isFileURL, url.host == nil || url.host?.lowercased() == "localhost" || url.host == "",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !spelling.lowercased().contains("%2f") else { throw Failure.unsupported }
        // NSURL's filesystem-component projection may normalize Unicode. Keep
        // the received URI's decoded spelling and standardize dots ourselves;
        // no filesystem representation or alias resolution is needed here.
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/") else { throw Failure.unsupported }
        var parts = ["/"]
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                guard parts.count > 1 else { throw Failure.unsupported }
                parts.removeLast()
            } else { parts.append(String(component)) }
        }
        return parts
    }
}
