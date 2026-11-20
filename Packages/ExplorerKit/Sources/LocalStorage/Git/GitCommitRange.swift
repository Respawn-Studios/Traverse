import Foundation

public struct GitRangeCommit: Identifiable, Sendable {
    public var id: GitObjectID { commit.object }
    public let commit: GitCommitSummary
    public let parents: [GitObjectID]
    /// A shallow boundary with missing parents cannot be compared as a root.
    public let canReviewChanges: Bool
}

public struct GitCommitRange: Sendable {
    public struct Side: Sendable {
        public let revision: GitObjectID
        public let commits: [GitRangeCommit]
        public let hasMore: Bool
    }

    public let left: Side
    public let right: Side
    public let isShallow: Bool
}

public struct GitCommitChanges: Sendable {
    public let entry: GitRangeCommit
    public let parent: GitObjectID?
    public let summary: GitChangeSummary
}

public struct GitFolderHistory: Sendable {
    public let start: GitObjectID
    public let commits: [GitRangeCommit]
    public let older: GitObjectID?
    public let isShallow: Bool
}

extension GitReadView {
    func folderHistory(from revision: GitRevisionSelection, relativeFolder: String,
                       check: () throws -> Void) throws -> GitFolderHistory {
        let start = try resolve(revision)
        let paths = try comparisonPaths(in: relativeFolder)
        let limit = 96
        let rows = try commitRows(operands: [start.hex], options: ["--first-parent", "--topo-order"], paths: paths,
                                  maximum: limit + 1, check: check)
        return .init(start: start, commits: Array(rows.prefix(limit)), older: rows.dropFirst(limit).first?.id,
                     isShallow: files.shallow != nil)
    }

    func commitRange(left: GitObjectID, right: GitObjectID, check: () throws -> Void) throws -> GitCommitRange {
        guard try resolve(.object(left)) == left, try resolve(.object(right)) == right else {
            throw GitInspectionFailure.changed
        }
        let shallow = files.shallow != nil
        let limit = 64
        let operand = left.hex + "..." + right.hex
        func side(_ revision: GitObjectID, _ selection: String) throws -> GitCommitRange.Side {
            let rows = left == right ? [] : try commitRows(operands: [operand], options: [selection, "--topo-order"],
                maximum: limit + 1, check: check)
            return .init(revision: revision, commits: Array(rows.prefix(limit)), hasMore: rows.count > limit)
        }
        let leftSide = try side(left, "--left-only"), rightSide = try side(right, "--right-only")
        guard Set(leftSide.commits.map(\.id)).isDisjoint(with: rightSide.commits.map(\.id)) else {
            throw GitInspectionFailure.invalidOutput
        }
        return .init(left: leftSide, right: rightSide, isShallow: shallow)
    }

    func commitChanges(_ entry: GitRangeCommit, against parent: GitObjectID?, relativeFolder: String,
                       check: () throws -> Void) throws -> GitCommitChanges {
        let commit = entry.id
        guard try resolve(.object(commit)) == commit,
              let current = try commitRows(operands: [commit.hex], options: ["--no-walk"], maximum: 1, check: check).first,
              current.id == commit, current.parents == entry.parents, current.canReviewChanges else {
            throw GitInspectionFailure.revisionUnavailable
        }
        let base: [String]
        if let parent {
            guard current.parents.contains(parent), try resolve(.object(parent)) == parent else {
                throw GitInspectionFailure.revisionUnavailable
            }
            base = [parent.hex, commit.hex]
        } else {
            guard current.parents.isEmpty else { throw GitInspectionFailure.revisionUnavailable }
            base = ["--root", commit.hex]
        }
        let paths = try comparisonPaths(in: relativeFolder)
        let bytes = try run(["diff-tree", "--no-commit-id", "-r"] + comparisonOptions + base + ["--"] + paths)
        let summary = try GitTreeComparisonParser.read(bytes, hashLength: files.hashLength,
            relativeFolder: relativeFolder, check: check)
        return .init(entry: current, parent: parent, summary: summary)
    }

    private func commitRows(operands: [String], options: [String], paths: [String] = [], maximum: Int,
                            check: () throws -> Void) throws -> [GitRangeCommit] {
        let data = try run(["log", "-z", "--no-show-signature", "--encoding=UTF-8",
            "--format=%H%x00%at%x00%s%x00%P", "--max-count=\(maximum)"] + options + operands + ["--"] + paths,
            maximumBytes: 1 << 20)
        guard !data.isEmpty else { return [] }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.last?.isEmpty == true, (fields.count - 1).isMultiple(of: 4),
              fields.count <= 4 * maximum + 1 else { throw GitInspectionFailure.invalidOutput }
        let boundaries = Set(files.shallow?.split(separator: 10).compactMap {
            GitObjectID(String(decoding: $0, as: UTF8.self))
        } ?? [])
        var seen: Set<GitObjectID> = []
        return try stride(from: 0, to: fields.count - 1, by: 4).map { index in
            try check()
            let summary = try commitSummary(object: fields[index], date: fields[index + 1], subject: fields[index + 2])
            guard seen.insert(summary.object).inserted else { throw GitInspectionFailure.invalidOutput }
            let parentFields = fields[index + 3].split(separator: 32)
            guard parentFields.count <= 64 else { throw GitInspectionFailure.limitExceeded }
            let parents = try parentFields.map { field in
                guard field.count == files.hashLength, let parent = GitObjectID(String(decoding: field, as: UTF8.self)),
                      !parent.isNull else { throw GitInspectionFailure.invalidOutput }
                return parent
            }
            return .init(commit: summary, parents: parents, canReviewChanges: !boundaries.contains(summary.object))
        }
    }
}
