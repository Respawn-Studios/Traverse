import Foundation

/// Git path equality uses the repository's bytes, including distinct Unicode
/// spellings. Display strings are never used to look up a selected blob.
public struct GitSnapshotPath: Hashable, Sendable {
    let bytes: Data

    init?(_ bytes: Data) {
        let components = bytes.split(separator: 47, omittingEmptySubsequences: false)
        guard !bytes.isEmpty, bytes.count <= 4_096, !bytes.contains(0), components.count <= 64,
              components.allSatisfy({ !$0.isEmpty && $0 != Data([46]) && $0 != Data([46, 46]) }) else { return nil }
        self.bytes = bytes
    }

    public init?(_ path: String) { self.init(Data(path.utf8)) }

    public var display: String {
        String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\r", with: "␍")
            .replacingOccurrences(of: "\n", with: "␊")
            .replacingOccurrences(of: "\t", with: "⇥")
    }

    var literalArgument: String? { String(data: bytes, encoding: .utf8) }

    public var parent: Self? {
        guard let slash = bytes.lastIndex(of: 47) else { return nil }
        return Self(bytes[..<slash])
    }

    public var name: String { display.split(separator: "/").last.map(String.init) ?? display }
}

public struct GitSnapshotMember: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case directory, file, executable, symbolicLink, submodule
    }

    public let path: GitSnapshotPath
    public let object: GitObjectID
    public let kind: Kind
    public var id: GitSnapshotPath { path }
    public var isTextCandidate: Bool { kind == .file || kind == .executable }

    static func read(mode: Data, path: GitSnapshotPath, id: GitObjectID) throws -> Self? {
        let kind: Kind
        switch String(decoding: mode, as: UTF8.self) {
        case "000000" where id.isNull: return nil
        case "040000": kind = .directory
        case "100644": kind = .file
        case "100755": kind = .executable
        case "120000": kind = .symbolicLink
        case "160000": kind = .submodule
        default: throw GitInspectionFailure.invalidOutput
        }
        guard !id.isNull else { throw GitInspectionFailure.invalidOutput }
        return .init(path: path, object: id, kind: kind)
    }
}

public struct GitTreeComparison: Sendable {
    public enum Basis: CaseIterable, Hashable, Sendable { case selectedRevisions, commonAncestor }

    public struct Lines: Equatable, Sendable {
        public let added: Int
        public let removed: Int
    }

    public struct Change: Identifiable, Sendable {
        public enum Kind: String, CaseIterable, Sendable { case added, removed, modified, renamed, copied, typeChanged }

        public let id: Int
        public let kind: Kind
        public let left: GitSnapshotMember?
        public let right: GitSnapshotMember?
        public let lines: Lines?

        public var canCompareText: Bool {
            (left?.isTextCandidate ?? true) && (right?.isTextCandidate ?? true) && lines != nil
        }
    }

    public let basis: Basis
    public let selectedLeft: GitObjectID
    public let left: GitObjectID
    public let right: GitObjectID
    public let summary: GitChangeSummary
    public var changes: [Change] { summary.changes }
    public var affectedSubfolders: Int { summary.affectedSubfolders }
    public var lines: Lines { summary.lines }
    public var rowsWithoutLineCounts: Int { summary.rowsWithoutLineCounts }
}

public struct GitChangeSummary: Sendable {
    public let changes: [GitTreeComparison.Change]
    public let affectedSubfolders: Int
    public let lines: GitTreeComparison.Lines
    public let rowsWithoutLineCounts: Int
}

/// A frozen view of the staged blob identities against a captured source.
public struct GitStagedComparison: Sendable {
    public let base: GitObjectID?
    public let comparesHead: Bool
    public let summary: GitChangeSummary
    public let conflicts: [GitIndexConflict]
    public var unmerged: [GitSnapshotPath] { conflicts.map(\.path) }
}

/// Raw Git entries feed both tree comparisons and a file's rename history.
/// Keep path tokens separate from the header and from any display spelling.
struct GitRawChange {
    let oldPath: GitSnapshotPath
    let newPath: GitSnapshotPath
    let kind: GitTreeComparison.Change.Kind
    let left: GitSnapshotMember?
    let right: GitSnapshotMember?

    static func read(_ header: Data, hashLength: Int, nextPath: () throws -> GitSnapshotPath) throws -> Self {
        guard header.first == 58 else { throw GitInspectionFailure.invalidOutput }
        let fields = header.dropFirst().split(separator: 32)
        guard fields.count == 5, let status = fields[4].first,
              let a = GitObjectID(String(decoding: fields[2], as: UTF8.self)),
              let b = GitObjectID(String(decoding: fields[3], as: UTF8.self)),
              a.hex.utf8.count == hashLength, b.hex.utf8.count == hashLength else {
            throw GitInspectionFailure.invalidOutput
        }
        let kind: GitTreeComparison.Change.Kind
        switch status {
        case 65 where fields[4].count == 1: kind = .added
        case 68 where fields[4].count == 1: kind = .removed
        case 77 where fields[4].count == 1: kind = .modified
        case 82, 67:
            let score = fields[4].dropFirst()
            guard (1...3).contains(score.count), score.allSatisfy({ (48...57).contains($0) }),
                  let percent = Int(String(decoding: score, as: UTF8.self)), (0...100).contains(percent) else {
                throw GitInspectionFailure.invalidOutput
            }
            kind = status == 82 ? .renamed : .copied
        case 84 where fields[4].count == 1: kind = .typeChanged
        default: throw GitInspectionFailure.invalidOutput
        }
        let first = try nextPath()
        let second = try kind == .renamed || kind == .copied ? nextPath() : first
        let old = try GitSnapshotMember.read(mode: fields[0], path: first, id: a)
        let new = try GitSnapshotMember.read(mode: fields[1], path: second, id: b)
        guard (old == nil) == (kind == .added), (new == nil) == (kind == .removed) else {
            throw GitInspectionFailure.invalidOutput
        }
        return .init(oldPath: first, newPath: second, kind: kind, left: old, right: new)
    }
}

enum GitTreeComparisonParser {
    private struct PathPair: Hashable {
        let old: GitSnapshotPath
        let new: GitSnapshotPath
    }

    static func read(_ data: Data, hashLength: Int, relativeFolder: String,
                     check: () throws -> Void) throws -> GitChangeSummary {
        let split = data.split(separator: 0, omittingEmptySubsequences: false)
        guard split.last?.isEmpty == true || data.isEmpty else { throw GitInspectionFailure.invalidOutput }
        let tokens = split.dropLast()
        var offset = tokens.startIndex
        func next() throws -> Data {
            guard offset < tokens.endIndex else { throw GitInspectionFailure.invalidOutput }
            defer { offset += 1 }
            return tokens[offset]
        }
        func path(_ bytes: Data) throws -> GitSnapshotPath {
            guard let value = GitSnapshotPath(bytes) else { throw GitInspectionFailure.invalidOutput }
            return value
        }

        var raw: [GitRawChange] = []
        while offset < tokens.endIndex, tokens[offset].first == 58 {
            try check()
            guard raw.count < 50_000 else { throw GitInspectionFailure.limitExceeded }
            let header = try next()
            raw.append(try GitRawChange.read(header, hashLength: hashLength) {
                try path(next())
            })
        }

        var byPath: [PathPair: GitTreeComparison.Lines?] = [:]
        while offset < tokens.endIndex {
            try check()
            guard byPath.count < raw.count else { throw GitInspectionFailure.invalidOutput }
            let value = try next().split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
            guard value.count == 3 else { throw GitInspectionFailure.invalidOutput }
            let first = try path(value[2].isEmpty ? next() : value[2])
            let second = try value[2].isEmpty ? path(next()) : first
            let pair = PathPair(old: first, new: second)
            guard byPath.index(forKey: pair) == nil else { throw GitInspectionFailure.invalidOutput }
            let lines: GitTreeComparison.Lines?
            if value[0] == Data([45]), value[1] == Data([45]) { lines = nil }
            else {
                guard let added = Int(String(decoding: value[0], as: UTF8.self)),
                      let removed = Int(String(decoding: value[1], as: UTF8.self)),
                      (0...8_388_608).contains(added), (0...8_388_608).contains(removed) else {
                    throw GitInspectionFailure.invalidOutput
                }
                lines = .init(added: added, removed: removed)
            }
            byPath.updateValue(lines, forKey: pair)
        }
        guard raw.count == byPath.count else { throw GitInspectionFailure.invalidOutput }

        var folders = Set<Data>()
        var added = 0, removed = 0, withoutCounts = 0
        let prefix = relativeFolder.isEmpty ? Data() : Data((relativeFolder + "/").utf8)
        var changes: [GitTreeComparison.Change] = []
        changes.reserveCapacity(raw.count)
        for item in raw {
            try check()
            let paths = PathPair(old: item.oldPath, new: item.newPath)
            guard let stats = byPath.removeValue(forKey: paths) else { throw GitInspectionFailure.invalidOutput }
            let lines = (item.left?.isTextCandidate ?? true) && (item.right?.isTextCandidate ?? true) ? stats : nil
            if let lines {
                added += lines.added
                removed += lines.removed
            } else { withoutCounts += 1 }
            for member in [item.left, item.right].compactMap({ $0 }) {
                let bytes = member.path.bytes
                guard bytes.starts(with: prefix) else { throw GitInspectionFailure.invalidOutput }
                for separator in bytes.indices.dropFirst(prefix.count) where bytes[separator] == 47 {
                    guard folders.count < 50_000 else { throw GitInspectionFailure.limitExceeded }
                    folders.insert(Data(bytes[..<separator]))
                }
            }
            changes.append(.init(id: changes.count, kind: item.kind, left: item.left, right: item.right, lines: lines))
        }
        return .init(changes: changes, affectedSubfolders: folders.count,
                     lines: .init(added: added, removed: removed), rowsWithoutLineCounts: withoutCounts)
    }

}
