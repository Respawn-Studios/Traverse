import Foundation

public struct GitFileVersion: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case absent
        case directory
        case member(GitSnapshotMember)
    }

    public let commit: GitObjectID
    public let path: GitSnapshotPath
    public let state: State
}

public struct GitFileHistory: Sendable {
    public struct Page: Equatable, Sendable {
        public let commit: GitObjectID
        public let path: GitSnapshotPath
    }

    public struct Entry: Identifiable, Sendable {
        public var id: GitObjectID { commit.object }
        public let commit: GitCommitSummary
        public let kind: GitTreeComparison.Change.Kind
        public let before: GitSnapshotMember?
        public let after: GitSnapshotMember?
    }

    public let start: Page?
    public let entries: [Entry]
    public let older: Page?
    public let isShallow: Bool
    public var startingCommit: GitObjectID? { start?.commit }
}

extension GitReadView {
    func history(of path: GitSnapshotPath, from revision: GitRevisionSelection,
                 check: () throws -> Void) throws -> GitFileHistory {
        let shallow = files.shallow != nil
        if revision == .head, files.head == nil {
            return .init(start: nil, entries: [], older: nil, isShallow: shallow)
        }
        guard let argument = path.literalArgument else { throw GitInspectionFailure.revisionUnavailable }
        let start = try resolve(revision)
        let page = GitFileHistory.Page(commit: start, path: path)
        let maximumEntries = 96
        // First parent gives each row a single preimage, including a change
        // introduced by a merge. Git supplies rename paths as NUL fields.
        let data = try run(["log", "--follow", "--first-parent", "--diff-merges=first-parent", "--no-show-signature",
            "--no-ext-diff", "--no-textconv", "--find-renames=50%", "-l200", "--no-abbrev", "--raw", "-z",
            "--max-count=\(maximumEntries + 1)", "--encoding=UTF-8", "--format=format:%x00%H%x00%at%x00%s%x00",
            start.hex, "--", argument], maximumBytes: 2 << 20)
        if data.isEmpty { return .init(start: page, entries: [], older: nil, isShallow: shallow) }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.last?.isEmpty == true else { throw GitInspectionFailure.invalidOutput }
        let end = fields.count - 1
        var index = 0
        func next() throws -> Data {
            guard index < end else { throw GitInspectionFailure.invalidOutput }
            defer { index += 1 }
            return fields[index]
        }

        var entries: [GitFileHistory.Entry] = []
        var older: GitFileHistory.Page?
        var seen = Set<GitObjectID>()
        var trackedPath = path
        while index < end {
            try check()
            guard older == nil, try next().isEmpty else { throw GitInspectionFailure.invalidOutput }
            let commit = try commitSummary(object: next(), date: next(), subject: next())
            let raw = try next()
            guard raw.first == 10, seen.insert(commit.object).inserted else { throw GitInspectionFailure.invalidOutput }
            let change = try GitRawChange.read(raw.dropFirst(), hashLength: files.hashLength) {
                guard let member = GitSnapshotPath(try next()) else { throw GitInspectionFailure.invalidOutput }
                return member
            }
            guard change.newPath == trackedPath else { throw GitInspectionFailure.invalidOutput }
            if entries.count == maximumEntries {
                // Continue from the first omitted change and its actual path.
                // It may already have a different name earlier in history.
                older = .init(commit: commit.object, path: trackedPath)
            } else {
                entries.append(.init(commit: commit, kind: change.kind, before: change.left, after: change.right))
            }
            trackedPath = change.oldPath
            if index < end, try !next().isEmpty { throw GitInspectionFailure.invalidOutput }
        }
        return .init(start: page, entries: entries, older: older, isShallow: shallow)
    }

    func fileVersion(of path: GitSnapshotPath, at selection: GitRevisionSelection) throws -> GitFileVersion {
        let commit = try resolve(selection)
        guard let member = try member(at: path, commit: commit) else { return .init(commit: commit, path: path, state: .absent) }
        return .init(commit: commit, path: path, state: member.kind == .directory ? .directory : .member(member))
    }
}
