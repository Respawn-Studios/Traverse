import Foundation

public enum BrowserLocation: Hashable, Sendable {
    case computer
    case directory(URL)
    case smb(SMBBrowserLocation)
    case sftp(SFTPBrowserLocation)
    case archive(ArchiveLocation)
    public var isRemote: Bool { switch self { case .smb, .sftp: true; default: false } }
    public var isArchive: Bool { if case .archive = self { true } else { false } }

    private static func directoryIdentity(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        let normalized = standardized.absoluteString
        // Foundation distinguishes a directory hint's trailing slash even when
        // both URLs name the same location. Keep exact case and symlink paths.
        return normalized.hasSuffix("/") && standardized.path != "/" ? String(normalized.dropLast()) : normalized
    }

    public static func == (left: BrowserLocation, right: BrowserLocation) -> Bool {
        switch (left, right) {
        case (.computer, .computer): true
        case (.directory(let lhs), .directory(let rhs)): directoryIdentity(lhs) == directoryIdentity(rhs)
        case (.smb(let lhs), .smb(let rhs)): lhs == rhs
        case (.sftp(let lhs), .sftp(let rhs)): lhs == rhs
        case (.archive(let lhs), .archive(let rhs)): lhs == rhs
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .computer: hasher.combine(0)
        case .directory(let url): hasher.combine(1); hasher.combine(Self.directoryIdentity(url))
        case .smb(let value): hasher.combine(2); hasher.combine(value)
        case .sftp(let value): hasher.combine(3); hasher.combine(value)
        case .archive(let value): hasher.combine(4); hasher.combine(value)
        }
    }

    public var displayName: String {
        switch self {
        case .computer: "This Mac"
        case .directory(let url): url.path == "/" ? "/" : url.lastPathComponent
        case .smb(let value): value.displayHint
        case .sftp(let value): value.displayHint
        case .archive(let value): value.displayName
        }
    }

    public var directoryURL: URL? {
        guard case .directory(let url) = self else { return nil }
        return url
    }

    public var parent: BrowserLocation? {
        switch self {
        case .computer, .smb, .sftp: return nil
        case .archive(let value):
            return value.parent.map(BrowserLocation.archive) ?? .directory(value.source.deletingLastPathComponent())
        case .directory(let url):
            // Navigation is lexical: never resolve symlinks or make filesystem reads here.
            let normalized = url.standardizedFileURL
            if normalized.path == "/" { return .computer }
            // Public mounted-volume layout on macOS. Other mount points remain navigable to '/'.
            if normalized.deletingLastPathComponent().path == "/Volumes" { return .computer }
            return .directory(normalized.deletingLastPathComponent())
        }
    }
}

public enum FileKind: String, Sendable {
    case directory, package, symbolicLink, file, other
}

public struct FileEntry: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let kind: FileKind
    public let byteCount: Int64?
    public let modifiedAt: Date?
    public let createdAt: Date?
    public let accessedAt: Date?

    /// Lexical filename suffix for display/sorting. Directory names have no file extension.
    public var filenameExtension: String? {
        guard kind != .directory else { return nil }
        let suffix = (name as NSString).pathExtension
        return suffix.isEmpty ? nil : suffix
    }

    public init(url: URL, name: String, kind: FileKind, byteCount: Int64? = nil, modifiedAt: Date? = nil,
                createdAt: Date? = nil, accessedAt: Date? = nil) {
        self.url = url
        self.name = name
        self.kind = kind
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.accessedAt = accessedAt
    }
}

public enum SortField: String, CaseIterable, Codable, Sendable {
    case name, modified, kind, size, created, accessed, `extension`
}

public struct DirectorySort: Equatable, Codable, Sendable {
    public var field: SortField
    public var ascending: Bool
    public var foldersFirst: Bool

    public init(field: SortField = .name, ascending: Bool = true, foldersFirst: Bool = true) {
        self.field = field
        self.ascending = ascending
        self.foldersFirst = foldersFirst
    }
}

/// Filters names only, never file bodies. Missing metadata sorts last in either direction.
public func orderedEntries(_ entries: [FileEntry], sort: DirectorySort, filter: String = "") -> [FileEntry] {
    orderedEntries(entries, sort: sort, filter: filter, checkCancellation: {})
}

/// Checks cooperatively between bounded groups of filter items and comparisons.
public func orderedEntries(_ entries: [FileEntry], sort: DirectorySort, filter: String = "",
                           checkCancellation: () throws -> Void) rethrows -> [FileEntry] {
    try checkCancellation()
    let locale = Locale(identifier: "en_US_POSIX")
    func nameOrder(_ lhs: FileEntry, _ rhs: FileEntry) -> ComparisonResult {
        let natural = lhs.name.compare(rhs.name, options: [.numeric, .caseInsensitive], locale: locale)
        if natural != .orderedSame { return natural }
        if !lhs.name.utf8.elementsEqual(rhs.name.utf8) {
            return lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8) ? .orderedAscending : .orderedDescending
        }
        let left = lhs.url.absoluteString.utf8
        let right = rhs.url.absoluteString.utf8
        if left.elementsEqual(right) { return .orderedSame }
        return left.lexicographicallyPrecedes(right) ? .orderedAscending : .orderedDescending
    }
    func compare<T: Comparable>(_ left: T, _ right: T) -> ComparisonResult {
        left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
    }
    var filterItems = 0
    let filtered = try entries.filter { entry in
        filterItems += 1
        if filterItems == 256 { try checkCancellation(); filterItems = 0 }
        return filter.isEmpty || entry.name.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
    }
    try checkCancellation()
    var comparisons = 0
    let ordered = try filtered.sorted { left, right in
        comparisons += 1
        if comparisons == 256 { try checkCancellation(); comparisons = 0 }
        if sort.foldersFirst, (left.kind == .directory) != (right.kind == .directory) {
            return left.kind == .directory
        }
        var result: ComparisonResult
        switch sort.field {
        case .name: result = nameOrder(left, right)
        case .kind:
            result = compare(left.kind.rawValue, right.kind.rawValue)
            if result == .orderedSame && left.kind == .file {
                // Match the details table's extension-based kind without reading file bodies.
                let leftExtension = (left.name as NSString).pathExtension.lowercased(with: locale)
                let rightExtension = (right.name as NSString).pathExtension.lowercased(with: locale)
                result = compare(leftExtension, rightExtension)
            }
        case .size:
            if (left.byteCount == nil) != (right.byteCount == nil) { return left.byteCount != nil }
            result = compare(left.byteCount ?? 0, right.byteCount ?? 0)
        case .modified, .created, .accessed:
            let leftDate = sort.field == .created ? left.createdAt : sort.field == .accessed ? left.accessedAt : left.modifiedAt
            let rightDate = sort.field == .created ? right.createdAt : sort.field == .accessed ? right.accessedAt : right.modifiedAt
            if (leftDate == nil) != (rightDate == nil) { return leftDate != nil }
            result = compare(leftDate ?? .distantPast, rightDate ?? .distantPast)
        case .extension:
            let leftExtension = left.filenameExtension
            let rightExtension = right.filenameExtension
            if (leftExtension == nil) != (rightExtension == nil) { return leftExtension != nil }
            // Normalize once per operand, then use a lexical total order as Kind sorting does.
            // Mixed-case locale collation must not make the comparator depend on input order.
            result = compare(leftExtension?.lowercased(with: locale) ?? "",
                             rightExtension?.lowercased(with: locale) ?? "")
        }
        if result == .orderedSame { result = nameOrder(left, right) }
        return sort.ascending ? result == .orderedAscending : result == .orderedDescending
    }
    try checkCancellation()
    return ordered
}

public struct NavigationState: Equatable, Sendable {
    public var selection: Set<URL>
    public var scrollOffset: Double

    public init(selection: Set<URL> = [], scrollOffset: Double = 0) {
        self.selection = selection
        self.scrollOffset = scrollOffset
    }
}

public struct BrowserTab: Identifiable, Sendable {
    private struct Visit: Sendable {
        var location: BrowserLocation
        var state = NavigationState()
        var sort = DirectorySort()
        var filter = ""
        var presentationMode: DirectoryViewMode?
        var folderViewResolved = false
        var connectionBookmark: WorkspaceConnectionBookmark?
        var archiveState: ArchiveBrowseState?
    }

    public let id: UUID
    private var visits: [Visit]
    private var index = 0

    public init(location: BrowserLocation = .computer) {
        id = UUID()
        visits = [Visit(location: location, archiveState: location.isArchive ? .init() : nil)]
    }

    public var location: BrowserLocation { visits[index].location }
    public var archiveState: ArchiveBrowseState? {
        get { visits[index].archiveState }
        set { visits[index].archiveState = location.isArchive ? newValue : nil }
    }
    /// Only the current visit's saved description. No session or body authority.
    public var connectionBookmark: WorkspaceConnectionBookmark? {
        get { visits[index].connectionBookmark }
        set { visits[index].connectionBookmark = newValue }
    }
    public mutating func replaceDisconnectedConnection(with location: BrowserLocation, bookmark: WorkspaceConnectionBookmark?) throws {
        guard let current = connectionBookmark, current.matches(self.location),
              current.matches(location), bookmark?.matches(location) != false else {
            throw WorkspaceConnectionBookmark.Failure.invalidReference
        }
        visits = [Visit(location: location, connectionBookmark: bookmark)]; index = 0
    }
    public var state: NavigationState {
        get { visits[index].state }
        set { visits[index].state = newValue }
    }
    public var sort: DirectorySort {
        get { visits[index].sort }
        set { visits[index].sort = newValue }
    }
    public var filter: String {
        get { visits[index].filter }
        set { visits[index].filter = newValue }
    }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < visits.count - 1 }
    public var presentationMode: DirectoryViewMode? { visits[index].presentationMode }
    public var folderViewResolved: Bool { visits[index].folderViewResolved }
    /// A fresh visit can use saved defaults once; returning to an existing visit
    /// keeps its choice. Saved paths remain outside this navigation value.
    public mutating func resolveFolderView(mode: DirectoryViewMode? = nil, sort: DirectorySort? = nil) {
        if let mode { visits[index].presentationMode = mode }
        if let sort { visits[index].sort = sort }
        visits[index].folderViewResolved = true
    }

    public mutating func navigate(to location: BrowserLocation) {
        guard location != self.location else { return }
        let inheritedSort = sort
        visits.removeSubrange((index + 1)..<visits.count)
        visits.append(Visit(location: location, sort: inheritedSort, archiveState: location.isArchive ? .init() : nil))
        index = visits.count - 1
    }

    public mutating func goBack() { if canGoBack { index -= 1 } }
    public mutating func goForward() { if canGoForward { index += 1 } }
    public mutating func goUp() { if let parent = location.parent { navigate(to: parent) } }
}
