import Foundation

/// One lexical contract for entered local paths. Does not consult process HOME,
/// expand shell variables or look up another account. The caller supplies its
/// separately resolved browsing home; grants are acquired by the normal reader.
public enum DirectoryPathInput {
    public enum Failure: Error { case invalidPath, homeUnavailable }
    public static func resolve(_ text: String, home: URL?) throws -> URL {
        guard !text.isEmpty, text.utf8.count <= 8192,
            !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalidPath }
        let result: URL
        if text == "~" || text.hasPrefix("~/") {
            guard let home, home.isFileURL else { throw Failure.homeUnavailable }
            result = text == "~" ? home : home.appendingPathComponent(String(text.dropFirst(2)), isDirectory: true)
        } else if text.hasPrefix("/") {
            result = URL(fileURLWithPath: text, isDirectory: true)
        } else if let url = URL(string: text), url.isFileURL,
            url.host == nil || url.host == "" || url.host == "localhost",
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil {
            result = url
        } else { throw Failure.invalidPath }
        // URL.path may normalize a decoded NUL away. Validate the encoded input
        // before asking Foundation for a filesystem path, as storage layout does.
        let decoded = URLComponents(url: result, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding
        guard let decoded, decoded.hasPrefix("/"), decoded.utf8.count <= 8192,
            !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            result.path.hasPrefix("/") else {
            throw Failure.invalidPath
        }
        return result.standardizedFileURL
    }
}
