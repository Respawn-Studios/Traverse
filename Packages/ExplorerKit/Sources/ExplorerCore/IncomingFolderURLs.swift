import Foundation

/// Lexical admission only. Kept separate from OS access and a fresh native
/// directory probe; an admitted URL is never mutation or saved-access authority.
public enum IncomingFolderURLs {
    public enum Failure: Error, Equatable, Sendable { case batchLimit, unsupportedURL }
    public static let maximumBatch = 16
    public static func admit(_ urls: [URL]) throws -> [URL] {
        guard !urls.isEmpty, urls.count <= maximumBatch else { throw Failure.batchLimit }
        var paths: Set<String> = []
        var result: [URL] = []
        for url in urls {
            let path = url.path
            // Foundation's file-system path representation may truncate a
            // decoded NUL. Inspect the URL spelling before using that path.
            let decodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
                .removingPercentEncoding
            guard url.isFileURL, [nil, "", "localhost"].contains(url.host?.lowercased()),
                url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                let decodedPath, decodedPath.hasPrefix("/"), decodedPath.utf8.count <= 4096,
                path.hasPrefix("/"), url.absoluteString.utf8.count <= 16_384,
                !decodedPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else {
                throw Failure.unsupportedURL
            }
            if paths.insert(url.standardizedFileURL.path).inserted {
                result.append(url)  // Preserve the original scope-bearing URL.
            }
        }
        return result
    }
}
