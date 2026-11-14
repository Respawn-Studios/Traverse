import Foundation

/// An optional local UI snapshot, never an access grant or object annotation.
/// Current visits only: Back/Forward history deliberately does not persist.
public struct WorkspaceSession: Codable, Equatable, Sendable {
    public static let maximumTabs = 32
    public static let maximumSelectionsPerTab = 256
    public static let maximumFilterBytes = 2_048
    public static let maximumURLBytes = 8_192
    public static let maximumScrollOffset: Double = 1_000_000_000

    public enum ValidationFailure: Error, Sendable {
        case unsupportedVersion, invalidTabs, invalidLocation, invalidFilter, invalidSort, invalidSelection, invalidScroll
    }

    public struct Location: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case computer, directory, connection, archive }
        public var kind: Kind
        public var url: URL?
        public var connection: WorkspaceConnectionBookmark?
        public var archive: ArchiveLocation?
        public init(kind: Kind, url: URL? = nil, connection: WorkspaceConnectionBookmark? = nil, archive: ArchiveLocation? = nil) {
            self.kind = kind; self.url = url; self.connection = connection; self.archive = archive
        }
    }

    public struct Tab: Codable, Equatable, Sendable {
        public var location: Location
        public var filter: String
        public var sortField: String
        public var ascending: Bool
        public var foldersFirst: Bool
        public var selection: [URL]
        public var scrollOffset: Double
        public var archiveState: ArchiveBrowseState?

        public init(location: Location, filter: String = "", sortField: String = "name", ascending: Bool = true,
                    foldersFirst: Bool = true, selection: [URL] = [], scrollOffset: Double = 0, archiveState: ArchiveBrowseState? = nil) {
            self.location = location; self.filter = filter; self.sortField = sortField
            self.ascending = ascending; self.foldersFirst = foldersFirst
            self.selection = selection; self.scrollOffset = scrollOffset
            self.archiveState = archiveState
        }
    }

    public var version: Int
    public var tabs: [Tab]
    public var activeTab: Int

    public init(version: Int? = nil, tabs: [Tab], activeTab: Int = 0) {
        self.version = version ?? (tabs.contains { $0.location.kind == .archive } ? 3 : tabs.contains { $0.location.kind == .connection } ? 2 : 1)
        self.tabs = tabs; self.activeTab = activeTab
    }

    public func validate() throws {
        guard (1...3).contains(version) else { throw ValidationFailure.unsupportedVersion }
        guard !tabs.isEmpty, tabs.count <= Self.maximumTabs, tabs.indices.contains(activeTab) else {
            throw ValidationFailure.invalidTabs
        }
        for tab in tabs {
            if tab.location.kind != .archive {
                guard tab.location.archive == nil, tab.archiveState == nil else { throw ValidationFailure.invalidLocation }
            }
            switch tab.location.kind {
            case .computer:
                guard tab.location.url == nil, tab.location.connection == nil else { throw ValidationFailure.invalidLocation }
            case .directory:
                guard let url = tab.location.url, Self.isLocalURL(url), tab.location.connection == nil else { throw ValidationFailure.invalidLocation }
            case .connection:
                guard version >= 2, tab.location.url == nil, let connection = tab.location.connection,
                      tab.filter.isEmpty, tab.selection.isEmpty, tab.scrollOffset == 0 else { throw ValidationFailure.invalidLocation }
                try connection.validate()
            case .archive:
                guard version == 3, tab.location.url == nil, tab.location.connection == nil,
                      let archive = tab.location.archive, let state = tab.archiveState,
                      tab.filter.isEmpty, tab.selection.isEmpty, tab.scrollOffset == 0 else { throw ValidationFailure.invalidLocation }
                try archive.validate(); try state.validate(format: archive.format)
            }
            guard tab.filter.utf8.count <= Self.maximumFilterBytes, !tab.filter.utf8.contains(0) else { throw ValidationFailure.invalidFilter }
            guard SortField(rawValue: tab.sortField) != nil else { throw ValidationFailure.invalidSort }
            guard tab.scrollOffset.isFinite, (0...Self.maximumScrollOffset).contains(tab.scrollOffset) else {
                throw ValidationFailure.invalidScroll
            }
            guard tab.selection.count <= Self.maximumSelectionsPerTab, Set(tab.selection).count == tab.selection.count else {
                throw ValidationFailure.invalidSelection
            }
            for url in tab.selection {
                guard Self.isLocalURL(url) else { throw ValidationFailure.invalidSelection }
                if let directory = tab.location.url {
                    guard url.standardizedFileURL.deletingLastPathComponent().path == directory.standardizedFileURL.path else {
                        throw ValidationFailure.invalidSelection
                    }
                }
            }
        }
    }

    /// Snapshot memory only; URL checks are lexical and make no filesystem calls.
    /// Large live sessions retain their active tab and at most 31 other tabs.
    public static func capture(_ source: [BrowserTab], activeID: UUID) throws -> Self {
        guard source.contains(where: { $0.id == activeID }) else { throw ValidationFailure.invalidTabs }
        if source.contains(where: { $0.location.isRemote && $0.connectionBookmark == nil }) {
            let local = source.filter { !$0.location.isRemote || $0.connectionBookmark != nil }
            // Unsaved live sessions cannot be recreated. Valid saved descriptions
            // restore as disconnected tabs, never as sockets or credentials.
            guard let first = local.first else { return Self(tabs: [Tab(location: .init(kind: .computer))]) }
            return try capture(local, activeID: local.contains(where: { $0.id == activeID }) ? activeID : first.id)
        }
        guard let active = source.firstIndex(where: { $0.id == activeID }), !source.isEmpty else {
            throw ValidationFailure.invalidTabs
        }
        var indices = Array(source.indices.prefix(maximumTabs))
        if !indices.contains(active) { indices[indices.count - 1] = active }
        let tabs = try indices.map { index -> Tab in
            let source = source[index]
            let location: Location
            switch source.location {
            case .computer: location = Location(kind: .computer)
            case .directory(let url): location = Location(kind: .directory, url: url)
            case .archive(let archive):
                guard let state = source.archiveState else { throw ValidationFailure.invalidLocation }
                try archive.validate(); try state.validate(format: archive.format)
                return Tab(location: .init(kind: .archive, archive: archive), archiveState: state)
            case .smb, .sftp:
                guard let saved = source.connectionBookmark, saved.matches(source.location) else { throw ValidationFailure.invalidLocation }
                try saved.validate()
                return Tab(location: Location(kind: .connection, connection: saved))
            }
            // Selection may include items removed during a listing. Keep only
            // meaningful direct children; restoration never probes them here.
            let meaningful = source.state.selection.filter { url in
                guard isLocalURL(url) else { return false }
                return location.url.map { url.standardizedFileURL.deletingLastPathComponent().path == $0.standardizedFileURL.path } ?? true
            }.sorted { $0.absoluteString < $1.absoluteString }.prefix(maximumSelectionsPerTab)
            let filter = boundedFilter(source.filter)
            let offset = source.state.scrollOffset
            return Tab(location: location, filter: filter, sortField: source.sort.field.rawValue,
                       ascending: source.sort.ascending, foldersFirst: source.sort.foldersFirst,
                       selection: Array(meaningful), scrollOffset: offset.isFinite ? min(max(0, offset), maximumScrollOffset) : 0)
        }
        let result = Self(tabs: tabs, activeTab: indices.firstIndex(of: active)!)
        try result.validate()
        return result
    }

    /// Restores fresh tab identities. Stale/missing locations remain locations;
    /// the real browser listing supplies their honest unavailable/denied state.
    public func restoredTabs() throws -> (tabs: [BrowserTab], activeID: UUID) {
        try validate()
        let restored = try tabs.map { item -> BrowserTab in
            var tab: BrowserTab
            if let archive = item.location.archive { tab = BrowserTab(location: .archive(archive)); tab.archiveState = item.archiveState }
            else { tab = try item.location.connection?.disconnectedTab()
                ?? BrowserTab(location: item.location.url.map(BrowserLocation.directory) ?? .computer) }
            tab.filter = item.filter
            tab.sort = DirectorySort(field: SortField(rawValue: item.sortField)!, ascending: item.ascending, foldersFirst: item.foldersFirst)
            tab.state = NavigationState(selection: Set(item.selection), scrollOffset: item.scrollOffset)
            return tab
        }
        return (restored, restored[activeTab].id)
    }

    /// Explicit launch templates never inspect selection or scroll state. In
    /// particular, Select All in a huge folder adds no capture/sort work here.
    public static func captureLaunchTemplate(_ source: [BrowserTab], activeID: UUID, includeFilters: Bool = false) throws -> Self {
        guard !source.contains(where: { $0.location.isRemote && $0.connectionBookmark == nil }) else {
            throw ValidationFailure.invalidLocation
        }
        guard (1...maximumTabs).contains(source.count), let active = source.firstIndex(where: { $0.id == activeID }) else {
            throw ValidationFailure.invalidTabs
        }
        let tabs = try source.map { tab in
            if case .archive(let archive) = tab.location {
                var state = ArchiveBrowseState()
                if let current = tab.archiveState {
                    state.sortField = current.sortField; state.ascending = current.ascending
                    if includeFilters { state.query = current.query; state.scope = current.scope }
                }
                try archive.validate(); try state.validate(format: archive.format)
                return Tab(location: .init(kind: .archive, archive: archive), archiveState: state)
            }
            if tab.location.isRemote {
                guard let saved = tab.connectionBookmark, saved.matches(tab.location) else { throw ValidationFailure.invalidLocation }
                try saved.validate(); return Tab(location: .init(kind: .connection, connection: saved))
            }
            return Tab(location: tab.location.directoryURL.map { .init(kind: .directory, url: $0) } ?? .init(kind: .computer),
                filter: includeFilters ? boundedFilter(tab.filter) : "", sortField: tab.sort.field.rawValue,
                ascending: tab.sort.ascending, foldersFirst: tab.sort.foldersFirst)
        }
        let result = Self(tabs: tabs, activeTab: active); try result.validate(); return result
    }

    private static func isLocalURL(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && (url.host == nil || url.host == "" || url.host == "localhost")
            && url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil
            && !url.path.utf8.contains(0) && url.absoluteString.utf8.count <= maximumURLBytes
    }

    private static func boundedFilter(_ value: String) -> String {
        var result = ""
        var bytes = 0
        for character in value {
            let part = String(character)
            guard !part.utf8.contains(0), bytes + part.utf8.count <= maximumFilterBytes else { break }
            result.append(character); bytes += part.utf8.count
        }
        return result
    }
}
