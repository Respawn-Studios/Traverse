import Foundation

/// Value-only navigation. These values never retain a descriptor, catalog,
/// access grant, extraction choice or local URL for a virtual member.
public enum ArchiveFormat: String, Codable, CaseIterable, Sendable { case zip, tar }
public enum ArchiveSearchScope: String, Codable, CaseIterable, Sendable { case folder, archive }
public enum ArchiveSortField: String, Codable, CaseIterable, Sendable { case name, size, modified, packedSize, method, kind }
public enum ArchiveNavigationFailure: Error, Equatable, Sendable {
    case invalidSource, invalidFolderPath, invalidQuery, invalidSort, invalidOffset, invalidSelection, invalidScroll
}

public struct ArchiveLocation: Hashable, Codable, Sendable {
    public let source: URL
    public let format: ArchiveFormat
    public let folderPath: [String]

    public init(source: URL, format: ArchiveFormat, folderPath: [String] = []) throws {
        self.source = source; self.format = format; self.folderPath = folderPath
        try validate()
    }

    public func validate() throws {
        let decodedPath = URLComponents(url: source, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding
        guard source.isFileURL, source.path.hasPrefix("/"),
              source.host == nil || source.host == "" || source.host == "localhost",
              source.user == nil, source.password == nil, source.port == nil,
              source.query == nil, source.fragment == nil,
              let decodedPath, decodedPath.hasPrefix("/"), !decodedPath.utf8.contains(0),
              !source.path.utf8.contains(0), source.absoluteString.utf8.count <= 8_192 else {
            throw ArchiveNavigationFailure.invalidSource
        }
        try Self.validateFolderPath(folderPath)
        guard format != .tar || (folderPath.count <= 63 && folderPath.allSatisfy { $0.utf8.count <= 255 }) else {
            throw ArchiveNavigationFailure.invalidFolderPath
        }
    }
    public var displayName: String { folderPath.last ?? source.lastPathComponent }
    /// Display/input only. A virtual descendant is never a filesystem URL.
    public var editablePath: String {
        source.path + (folderPath.isEmpty ? "" : "/" + folderPath.joined(separator: "/"))
    }
    /// Full paths under this exact archive, or paths relative to the current
    /// virtual folder. An unrelated absolute/Home path belongs to the normal
    /// local address route. Dot segments cannot escape the archive root.
    public func resolvingAddress(_ text: String) throws -> ArchiveLocation? {
        guard !text.isEmpty, text.utf8.count <= 65_536,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ArchiveNavigationFailure.invalidFolderPath
        }
        let suffix: Substring
        var parts: [String]
        if text == source.path { suffix = ""; parts = [] }
        else if text.hasPrefix(source.path + "/") { suffix = text.dropFirst(source.path.count + 1); parts = [] }
        else if text.hasPrefix("/") || text == "~" || text.hasPrefix("~/")
            || text.caseInsensitiveCompare("This Mac") == .orderedSame { return nil }
        else { suffix = text[...]; parts = folderPath }
        for part in suffix.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { throw ArchiveNavigationFailure.invalidFolderPath }
                parts.removeLast()
            } else { parts.append(String(part)) }
        }
        return try ArchiveLocation(source: source, format: format, folderPath: parts)
    }
    public var parent: ArchiveLocation? {
        guard !folderPath.isEmpty else { return nil }
        return try? ArchiveLocation(source: source, format: format, folderPath: Array(folderPath.dropLast()))
    }
    public static func validateFolderPath(_ components: [String]) throws {
        guard validComponents(components, allowRoot: true) else { throw ArchiveNavigationFailure.invalidFolderPath }
    }
    private enum CodingKeys: String, CodingKey { case source, format, folderPath }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(source: values.decode(URL.self, forKey: .source),
                      format: values.decode(ArchiveFormat.self, forKey: .format),
                      folderPath: values.decode([String].self, forKey: .folderPath))
    }
    internal static func validComponents(_ parts: [String], allowRoot: Bool) -> Bool {
        guard (allowRoot || !parts.isEmpty), parts.count <= 64,
              parts.reduce(0, { $0 + $1.utf8.count }) + max(0, parts.count - 1) <= 4_096 else { return false }
        guard parts.first.map({ $0.utf8.count >= 2 && $0.utf8.dropFirst().first == 58 }) != true else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.utf8.count <= 4_096
                && !part.contains("/") && !part.contains("\\")
                && !part.unicodeScalars.contains {
                    CharacterSet.controlCharacters.contains($0) || [0x061c, 0x200e, 0x200f].contains($0.value)
                        || (0x202a...0x202e).contains($0.value) || (0x2066...0x2069).contains($0.value)
                }
        }
    }
}

public struct ArchiveBrowseState: Equatable, Codable, Sendable {
    public var query: String
    public var scope: ArchiveSearchScope
    public var sortField: ArchiveSortField
    public var ascending: Bool
    public var offset: Int
    public var selectedPaths: Set<String>
    public var scrollOffset: Double
    public init(query: String = "", scope: ArchiveSearchScope = .folder, sortField: ArchiveSortField = .name,
                ascending: Bool = true, offset: Int = 0, selectedPaths: Set<String> = [], scrollOffset: Double = 0) {
        self.query = query; self.scope = scope; self.sortField = sortField; self.ascending = ascending
        self.offset = offset; self.selectedPaths = selectedPaths; self.scrollOffset = scrollOffset
    }
    public func validate(format: ArchiveFormat) throws {
        guard query.utf8.count <= 2_048, !query.utf8.contains(0) else { throw ArchiveNavigationFailure.invalidQuery }
        guard format != .tar || ![.packedSize, .method].contains(sortField),
              format != .zip || sortField != .kind else { throw ArchiveNavigationFailure.invalidSort }
        guard (0...(format == .zip ? 128_000 : 20_000)).contains(offset) else { throw ArchiveNavigationFailure.invalidOffset }
        guard selectedPaths.count <= 256, selectedPaths.reduce(0, { $0 + $1.utf8.count }) <= 65_536 else { throw ArchiveNavigationFailure.invalidSelection }
        for path in selectedPaths {
            guard !path.isEmpty else { throw ArchiveNavigationFailure.invalidSelection }
            let parts = path.components(separatedBy: "/")
            do {
                try ArchiveLocation.validateFolderPath(parts)
                guard format != .tar || (parts.count <= 63 && parts.allSatisfy { $0.utf8.count <= 255 }) else {
                    throw ArchiveNavigationFailure.invalidSelection
                }
            }
            catch { throw ArchiveNavigationFailure.invalidSelection }
        }
        guard scrollOffset.isFinite, (0...1_000_000_000).contains(scrollOffset) else { throw ArchiveNavigationFailure.invalidScroll }
    }
}
