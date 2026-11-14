import Foundation

/// Optional local working layouts; explicit launch templates remain separate.
/// A token is continuity/consent evidence, never filesystem or network access.
public struct WorkspaceProfileMemory: Codable, Equatable, Sendable {
    public enum Failure: Error, Equatable, Sendable { case invalidDocument, missing, stale, alreadyEnabled, limitReached }
    public struct Record: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let consent: UUID
        public let revision: UUID
        public let templateKey: String
        public let includesFilters: Bool
        public let snapshot: PaneWorkspaceSnapshot
    }
    public let owner: String
    public private(set) var version: Int
    public private(set) var revision: UUID
    public private(set) var records: [Record]
    public init() { owner = "traverse-profile-workspaces"; version = 1; revision = UUID(); records = [] }
    public func validate() throws {
        guard owner == "traverse-profile-workspaces", (1...3).contains(version),
              records.count <= WorkspaceLaunchProfiles.maximumProfiles,
              Set(records.map(\.id)).count == records.count,
              Set(records.map(\.consent)).count == records.count,
              Set(records.map(\.revision)).count == records.count else { throw Failure.invalidDocument }
        for record in records {
            guard record.snapshot.version <= version else { throw Failure.invalidDocument }
            guard record.templateKey.utf8.count == 64,
                  record.templateKey.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  try record.snapshot.forLaunchProfile(includeFilters: record.includesFilters) == record.snapshot else {
                throw Failure.invalidDocument
            }
        }
    }
    public func record(for id: UUID) -> Record? { records.first { $0.id == id } }
    @discardableResult public mutating func enable(_ id: UUID, templateKey: String, includesFilters: Bool,
                                                  snapshot: PaneWorkspaceSnapshot) throws -> Record {
        try validate()
        guard record(for: id) == nil else { throw Failure.alreadyEnabled }
        guard records.count < WorkspaceLaunchProfiles.maximumProfiles else { throw Failure.limitReached }
        let value = Record(id: id, consent: UUID(), revision: UUID(), templateKey: templateKey,
            includesFilters: includesFilters, snapshot: try snapshot.forLaunchProfile(includeFilters: includesFilters))
        var candidate = self; candidate.records.append(value); candidate.version = max(candidate.version, value.snapshot.version)
        candidate.revision = UUID(); try candidate.validate()
        self = candidate; return value
    }
    @discardableResult public mutating func save(_ id: UUID, consent: UUID, expected: UUID, templateKey: String,
                                                snapshot: PaneWorkspaceSnapshot) throws -> Record {
        try validate()
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw Failure.missing }
        let before = records[index]
        guard before.consent == consent, before.revision == expected, before.templateKey == templateKey else { throw Failure.stale }
        let value = Record(id: id, consent: before.consent, revision: UUID(), templateKey: before.templateKey,
            includesFilters: before.includesFilters, snapshot: try snapshot.forLaunchProfile(includeFilters: before.includesFilters))
        var candidate = self; candidate.records[index] = value; candidate.version = max(candidate.version, value.snapshot.version)
        candidate.revision = UUID(); try candidate.validate()
        self = candidate; return value
    }
    public mutating func disable(_ id: UUID, consent: UUID) throws {
        try validate()
        guard let value = record(for: id) else { throw Failure.missing }
        guard value.consent == consent else { throw Failure.stale }
        records.removeAll { $0.id == id }; revision = UUID()
    }
}
