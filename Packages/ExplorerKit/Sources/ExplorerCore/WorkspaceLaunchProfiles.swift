import Foundation

/// Explicit local UI templates. Paths never confer filesystem access.
public struct WorkspaceLaunchProfile: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let snapshot: PaneWorkspaceSnapshot
    public let includesFilters: Bool
    public init(id: UUID = UUID(), name: String, snapshot: PaneWorkspaceSnapshot, includesFilters: Bool = false) throws {
        try WorkspaceLaunchProfiles.validateName(name)
        self.id = id; self.name = name; self.includesFilters = includesFilters
        self.snapshot = try snapshot.forLaunchProfile(includeFilters: includesFilters)
    }
}

public struct WorkspaceLaunchProfiles: Codable, Equatable, Sendable {
    public static let maximumProfiles = 20
    public static let maximumNameBytes = 160
    public enum Failure: Error, Sendable { case invalidDocument, invalidName, duplicateName, limitReached, missingProfile, stale }
    public let owner: String
    public private(set) var version: Int
    public private(set) var revision: UUID
    public private(set) var profiles: [WorkspaceLaunchProfile]
    public init() { owner = "mac-explorer-launch-profiles"; version = 1; revision = UUID(); profiles = [] }

    public static func validateName(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= maximumNameBytes,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalidName }
    }
    private static func nameKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public func validate() throws {
        guard owner == "mac-explorer-launch-profiles", (1...3).contains(version),
              profiles.count <= Self.maximumProfiles, Set(profiles.map(\.id)).count == profiles.count,
              Set(profiles.map { Self.nameKey($0.name) }).count == profiles.count else { throw Failure.invalidDocument }
        for profile in profiles {
            try Self.validateName(profile.name); try profile.snapshot.validate()
            guard profile.snapshot.version <= version else { throw Failure.invalidDocument }
            guard try profile.snapshot.forLaunchProfile(includeFilters: profile.includesFilters) == profile.snapshot else { throw Failure.invalidDocument }
        }
    }
    @discardableResult public mutating func add(name: String, snapshot: PaneWorkspaceSnapshot, includeFilters: Bool = false) throws -> UUID {
        try validate(); try checkName(name)
        guard profiles.count < Self.maximumProfiles else { throw Failure.limitReached }
        let value = try WorkspaceLaunchProfile(name: name, snapshot: snapshot, includesFilters: includeFilters)
        profiles.append(value); version = max(version, value.snapshot.version); revision = UUID(); return value.id
    }
    public mutating func rename(_ id: UUID, to name: String) throws {
        try validate(); try checkName(name, except: id)
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw Failure.missingProfile }
        let old = profiles[index]
        profiles[index] = try WorkspaceLaunchProfile(id: old.id, name: name, snapshot: old.snapshot, includesFilters: old.includesFilters)
        revision = UUID()
    }
    public mutating func remove(_ id: UUID) throws {
        try validate()
        guard profiles.contains(where: { $0.id == id }) else { throw Failure.missingProfile }
        profiles.removeAll { $0.id == id }; revision = UUID()
    }
    public mutating func update(_ id: UUID, snapshot: PaneWorkspaceSnapshot, includeFilters: Bool) throws {
        try validate()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw Failure.missingProfile }
        let old = profiles[index]
        profiles[index] = try WorkspaceLaunchProfile(id: old.id, name: old.name, snapshot: snapshot, includesFilters: includeFilters)
        version = max(version, profiles[index].snapshot.version)
        revision = UUID()
    }
    private func checkName(_ value: String, except: UUID? = nil) throws {
        try Self.validateName(value)
        guard !profiles.contains(where: { $0.id != except && Self.nameKey($0.name) == Self.nameKey(value) }) else { throw Failure.duplicateName }
    }
}

extension PaneWorkspaceSnapshot {
    public func forLaunchProfile(includeFilters: Bool = false) throws -> Self {
        try validate()
        let values = panes.map { pane in
            let tabs = pane.tabs.tabs.map { tab in
                var archiveState = tab.archiveState
                if archiveState != nil {
                    archiveState?.selectedPaths = []; archiveState?.offset = 0; archiveState?.scrollOffset = 0
                    if !includeFilters { archiveState?.query = ""; archiveState?.scope = .folder }
                }
                return WorkspaceSession.Tab(location: tab.location, filter: includeFilters ? tab.filter : "", sortField: tab.sortField,
                    ascending: tab.ascending, foldersFirst: tab.foldersFirst, archiveState: archiveState)
            }
            return Pane(id: pane.id, tabs: WorkspaceSession(tabs: tabs, activeTab: pane.tabs.activeTab), viewMode: pane.viewMode)
        }
        let result = Self(layout: layout, activePane: activePane, panes: values)
        try result.validate(); return result
    }
}
