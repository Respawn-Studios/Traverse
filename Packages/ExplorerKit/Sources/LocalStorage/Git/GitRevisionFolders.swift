import Foundation

public struct GitRevisionFolders: Sendable {
    public enum Difference: Sendable, Equatable {
        case onlyHere, modified, typeChanged
    }

    public enum Directory: Sendable {
        case children([GitSnapshotMember])
        case absent
        case differentType(GitSnapshotMember.Kind)

        public var entries: [GitSnapshotMember] {
            if case .children(let entries) = self { return entries }
            return []
        }
    }

    public let path: GitSnapshotPath?
    public let left: Directory
    public let right: Directory
    public let leftDifferences: [GitSnapshotPath: Difference]
    public let rightDifferences: [GitSnapshotPath: Difference]

    init(path: GitSnapshotPath?, left: Directory, right: Directory) {
        self.path = path
        self.left = left
        self.right = right
        self.leftDifferences = Self.differences(from: left, to: right)
        self.rightDifferences = Self.differences(from: right, to: left)
    }

    private static func differences(from side: Directory, to otherSide: Directory) -> [GitSnapshotPath: Difference] {
        let other = Dictionary(uniqueKeysWithValues: otherSide.entries.map { ($0.path, $0) })
        var differences: [GitSnapshotPath: Difference] = [:]
        for entry in side.entries {
            guard let peer = other[entry.path] else {
                differences[entry.path] = .onlyHere
                continue
            }
            if entry.kind != peer.kind && !(entry.isTextCandidate && peer.isTextCandidate) {
                differences[entry.path] = .typeChanged
            } else if entry != peer {
                differences[entry.path] = .modified
            }
        }
        return differences
    }
}

extension GitReadView {
    func folders(left: GitObjectID, right: GitObjectID, at path: GitSnapshotPath?,
                 check: () throws -> Void) throws -> GitRevisionFolders {
        let first = try folder(at: path, commit: resolve(.object(left)), check: check)
        try check()
        let second = left == right ? first : try folder(at: path, commit: resolve(.object(right)), check: check)
        return .init(path: path, left: first, right: second)
    }

    func folder(at path: GitSnapshotPath?, commit: GitObjectID, check: () throws -> Void) throws -> GitRevisionFolders.Directory {
        let treeish: GitObjectID
        if let path {
            guard let member = try member(at: path, commit: commit) else { return .absent }
            guard member.kind == .directory else { return .differentType(member.kind) }
            treeish = member.object
        } else { treeish = commit }
        let data = try run(["ls-tree", "--full-tree", "-z", treeish.hex], maximumBytes: 4 << 20)
        if data.isEmpty { return .children([]) }
        let parts = data.split(separator: 0, omittingEmptySubsequences: false)
        guard parts.last?.isEmpty == true else { throw GitInspectionFailure.invalidOutput }
        guard parts.count <= 4_097 else { throw GitInspectionFailure.limitExceeded }
        var seen = Set<GitSnapshotPath>()
        let entries = try parts.dropLast().map { record in
            try check()
            let entry = try treeMember(record, within: path, listing: true)
            guard seen.insert(entry.path).inserted else { throw GitInspectionFailure.invalidOutput }
            return entry
        }.sorted { a, b in
            let aFolder = a.kind == .directory, bFolder = b.kind == .directory
            if aFolder != bFolder { return aFolder }
            let order = a.path.name.localizedStandardCompare(b.path.name)
            return order == .orderedSame ? a.path.bytes.lexicographicallyPrecedes(b.path.bytes) : order == .orderedAscending
        }
        return .children(entries)
    }

    func member(at path: GitSnapshotPath, commit: GitObjectID) throws -> GitSnapshotMember? {
        guard let argument = path.literalArgument else { throw GitInspectionFailure.revisionUnavailable }
        let stdout = try run(["ls-tree", "--full-tree", "-z", commit.hex, "--", argument], maximumBytes: 8_192)
        if stdout.isEmpty { return nil }
        let records = stdout.split(separator: 0, omittingEmptySubsequences: false)
        guard records.count == 2, records[1].isEmpty else { throw GitInspectionFailure.invalidOutput }
        let entry = try treeMember(records[0], within: nil, listing: false)
        guard entry.path == path else { throw GitInspectionFailure.invalidOutput }
        return entry
    }

    private func treeMember(_ record: Data, within folder: GitSnapshotPath?, listing: Bool) throws -> GitSnapshotMember {
        let fields = record.split(separator: 9, maxSplits: 1)
        guard fields.count == 2, !listing || !fields[1].contains(47) else { throw GitInspectionFailure.invalidOutput }
        let fullPath = folder.map { $0.bytes + Data([47]) + fields[1] } ?? fields[1]
        guard let path = GitSnapshotPath(fullPath) else { throw GitInspectionFailure.invalidOutput }
        let metadata = fields[0].split(separator: 32)
        guard metadata.count == 3, let object = GitObjectID(String(decoding: metadata[2], as: UTF8.self)),
              !object.isNull, object.hex.utf8.count == files.hashLength,
              let member = try GitSnapshotMember.read(mode: metadata[0], path: path, id: object) else {
            throw GitInspectionFailure.invalidOutput
        }
        let expectedType: String
        switch member.kind {
        case .directory: expectedType = "tree"
        case .submodule: expectedType = "commit"
        case .file, .executable, .symbolicLink: expectedType = "blob"
        }
        guard metadata[1] == Data(expectedType.utf8) else { throw GitInspectionFailure.invalidOutput }
        return member
    }
}
