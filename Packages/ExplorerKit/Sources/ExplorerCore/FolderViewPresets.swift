import Foundation

/// Raw values retain compatibility with the native app's existing settings and
/// workspace templates. This value model imports no native UI framework.
public enum DirectoryViewMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case details = "Details", list = "List", icons = "Icons"
    public var id: Self { self }
}

public struct FolderViewChoice: Codable, Equatable, Sendable {
    public let mode: DirectoryViewMode
    public let sort: DirectorySort
    public init(mode: DirectoryViewMode, sort: DirectorySort) { self.mode = mode; self.sort = sort }
}

public struct SavedFolderView: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let path: String
    public var choice: FolderViewChoice
    public init(id: UUID = UUID(), path: String, choice: FolderViewChoice) { self.id = id; self.path = path; self.choice = choice }
}

/// Deliberately exact path associations. These values neither resolve locations
/// nor carry access, native identity, file entries or observation authority.
public struct FolderViewPresets: Codable, Equatable, Sendable {
    public static let maximumRecords = 512
    public private(set) var version = 1
    public private(set) var revision = UUID()
    public private(set) var records: [SavedFolderView] = []
    public enum Failure: Error { case invalidDocument, invalidLocation, limit, missing }
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, revision, records }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        revision = try values.decode(UUID.self, forKey: .revision)
        records = try values.decode([SavedFolderView].self, forKey: .records)
        try validate()
    }
    public static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(0),
              path == "/" || (!path.hasSuffix("/") && !path.contains("//")),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw Failure.invalidLocation }
    }
    public func validate() throws {
        guard version == 1, records.count <= Self.maximumRecords,
              Set(records.map(\.id)).count == records.count,
              Set(records.map { Data($0.path.utf8) }).count == records.count else { throw Failure.invalidDocument }
        for record in records { try Self.validatePath(record.path) }
    }
    public func record(for path: String) -> SavedFolderView? { records.first { $0.path.utf8.elementsEqual(path.utf8) } }
    public mutating func save(path: String, choice: FolderViewChoice) throws {
        try Self.validatePath(path)
        if let index = records.firstIndex(where: { $0.path.utf8.elementsEqual(path.utf8) }) { records[index].choice = choice }
        else {
            guard records.count < Self.maximumRecords else { throw Failure.limit }
            let id = UUID()
            guard !records.contains(where: { $0.id == id }) else { throw Failure.invalidDocument }
            records.append(.init(id: id, path: path, choice: choice))
        }
        // Empty construction and decoding establish all collection invariants;
        // private setters and these checked mutations preserve them. Rechecking
        // every earlier path for each insertion would make a batch quadratic.
        revision = UUID()
    }
    public mutating func forget(_ id: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw Failure.missing }
        records.remove(at: index); revision = UUID()
    }
    public mutating func forgetAll() { records.removeAll(); revision = UUID() }
}
