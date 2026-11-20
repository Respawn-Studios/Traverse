import CryptoKit
import FileOperations
import Foundation

public enum GitRevisionSelection: Hashable, Sendable {
    case head
    case object(GitObjectID)
    case abbreviated(String)
}

public struct GitCommitSummary: Identifiable, Hashable, Sendable {
    public var id: GitObjectID { object }
    public let object: GitObjectID
    public let date: Date
    public let subject: String

    public func matchesFilter(_ term: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return term.isEmpty || subject.range(of: term, options: options) != nil
            || object.hex.range(of: term, options: options) != nil
    }
}

public struct GitRevisionCatalog: Sendable {
    public let head: GitObjectID?
    public let headName: String?
    public let references: [GitRevisionReference]
    public let recentCommits: [GitCommitSummary]
    public let isShallow: Bool
    public let pairedCheckouts: GitCheckoutRevisionPair?
}

public struct GitCheckoutRevisionPair: Sendable {
    public struct Revision: Sendable {
        public let head: GitWorktree.Head
        public let commit: GitObjectID
    }

    public let left: Revision
    public let right: Revision
}

extension GitReadView {
    func catalog(pairedWith pairedLocation: GitRepositoryLocation? = nil,
                 check: () throws -> Void) throws -> GitRevisionCatalog {
        let pair: GitCheckoutRevisionPair?
        if let pairedLocation {
            let other = try GitRepositoryFiles(location: pairedLocation, check: check)
            guard try GitDirectoryIdentity(files.objects.fd) == GitDirectoryIdentity(other.objects.fd),
                  files.hashLength == other.hashLength else { throw GitInspectionFailure.changed }
            pair = .init(left: try Self.checkout(files, check: check), right: try Self.checkout(other, check: check))
        } else { pair = nil }
        let commits: [GitCommitSummary]
        if let head = files.head {
            let data = try run(["log", "-z", "--max-count=96", "--format=%H%x00%at%x00%s",
                                "--no-show-signature", "--encoding=UTF-8", head.hex, "--"], maximumBytes: 1 << 20)
            let fields = data.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.last?.isEmpty == true, (fields.count - 1).isMultiple(of: 3),
                  fields.count <= 96 * 3 + 1 else { throw GitInspectionFailure.invalidOutput }
            commits = try stride(from: 0, to: fields.count - 1, by: 3).map { start in
                try check()
                return try commitSummary(object: fields[start], date: fields[start + 1], subject: fields[start + 2])
            }
        } else { commits = [] }
        return .init(head: files.head, headName: files.headName, references: files.references,
                     recentCommits: commits, isShallow: files.shallow != nil, pairedCheckouts: pair)
    }

    private static func checkout(_ snapshot: GitRepositoryFiles, check: () throws -> Void) throws -> GitCheckoutRevisionPair.Revision {
        guard let commit = snapshot.head, !commit.isNull else { throw GitInspectionFailure.checkoutHasNoCommit }
        let head = try GitWorktree.readHead(snapshot.metadata, check: check)
        let same: Bool = switch head {
        case .branch(let name): snapshot.headName?.utf8.elementsEqual(name.utf8) == true
        case .detached(let object): snapshot.headName == nil && commit == object
        }
        guard same else { throw GitInspectionFailure.changed }
        try snapshot.anchors.validate(check: check)
        return .init(head: head, commit: commit)
    }

    func resolve(_ selection: GitRevisionSelection) throws -> GitObjectID {
        let operand: String
        switch selection {
        case .head:
            guard let head = files.head else { throw GitInspectionFailure.revisionUnavailable }
            operand = head.hex
        case .object(let id):
            guard !id.isNull, id.hex.utf8.count == files.hashLength else { throw GitInspectionFailure.revisionUnavailable }
            operand = id.hex
        case .abbreviated(let text):
            let lowered = text.lowercased()
            guard (4...files.hashLength).contains(lowered.utf8.count), GitObjectID.isHex(lowered.utf8) else {
                throw GitInspectionFailure.revisionUnavailable
            }
            operand = lowered
        }
        let data = try run(["rev-parse", "--verify", "--end-of-options", operand + "^{commit}"], maximumBytes: 128)
        guard let text = String(data: data, encoding: .utf8),
              let id = GitObjectID(text.trimmingCharacters(in: .newlines)),
              id.hex.utf8.count == files.hashLength, !id.isNull else { throw GitInspectionFailure.invalidOutput }
        return id
    }

    func compare(left: GitRevisionSelection, right: GitRevisionSelection, basis: GitTreeComparison.Basis, relativeFolder: String,
                 check: () throws -> Void) throws -> GitTreeComparison {
        let selectedLeft = try resolve(left)
        let second = try resolve(right)
        let first = basis == .commonAncestor && selectedLeft != second ? try commonAncestor(selectedLeft, second) : selectedLeft
        let pathspec = try comparisonPaths(in: relativeFolder)
        let result = first == second ? Data() : try run(["diff-tree", "--no-commit-id", "-r"] + comparisonOptions +
            [first.hex, second.hex, "--"] + pathspec)
        let summary = try GitTreeComparisonParser.read(result, hashLength: files.hashLength, relativeFolder: relativeFolder, check: check)
        return .init(basis: basis, selectedLeft: selectedLeft, left: first, right: second, summary: summary)
    }

    var comparisonOptions: [String] {
        ["-z", "--raw", "--numstat", "--no-abbrev", "--no-ext-diff", "--no-textconv",
         "--ignore-submodules=dirty", "--find-renames=50%", "-l200"]
    }

    func comparisonPaths(in relativeFolder: String) throws -> [String] {
        if relativeFolder.isEmpty { return [] }
        guard GitSnapshotPath(relativeFolder) != nil else { throw GitInspectionFailure.unsupportedRepository }
        return [relativeFolder + "/"]
    }

    private func commonAncestor(_ first: GitObjectID, _ second: GitObjectID) throws -> GitObjectID {
        let output = try run(["merge-base", "--all", first.hex, second.hex], maximumBytes: 8_192, acceptsNoMatch: true)
        guard !output.isEmpty else { throw GitInspectionFailure.noCommonAncestor }
        let lines = output.split(separator: 10, omittingEmptySubsequences: false)
        guard lines.last?.isEmpty == true, lines.dropLast().allSatisfy({
            $0.count == files.hashLength && GitObjectID.isHex($0) && $0.contains { $0 != 48 }
        }) else { throw GitInspectionFailure.invalidOutput }
        guard lines.count == 2 else { throw GitInspectionFailure.multipleCommonAncestors }
        guard let ancestor = GitObjectID(String(decoding: lines[0], as: UTF8.self)) else { throw GitInspectionFailure.invalidOutput }
        return ancestor
    }

    func text(_ member: GitSnapshotMember?) throws -> TextDocumentValue {
        guard let member else { return try TextDocumentValue.original(Data()) }
        guard member.isTextCandidate, member.object.hex.utf8.count == files.hashLength else {
            throw GitInspectionFailure.revisionUnavailable
        }
        let blob = try run(["cat-file", "blob", member.object.hex], maximumBytes: TextDocumentValue.maximumBytes)
        // Bind the text displayed to the selected Git object, including the
        // exact byte count and object type. The child never checks out a path.
        guard member.object.matchesBlob(blob) else { throw GitInspectionFailure.changed }
        return try TextDocumentValue.original(blob)
    }

    func commitSummary(object: Data, date: Data, subject: Data) throws -> GitCommitSummary {
        guard let id = GitObjectID(String(decoding: object, as: UTF8.self)), !id.isNull,
              id.hex.utf8.count == files.hashLength,
              let time = Self.timestamp(date) else { throw GitInspectionFailure.invalidOutput }
        return .init(object: id, date: time, subject: String(decoding: subject.prefix(512), as: UTF8.self))
    }

    private static func timestamp(_ bytes: Data) -> Date? {
        guard let seconds = Int64(String(decoding: bytes, as: UTF8.self)),
              (-62_135_596_800...253_402_300_799).contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

extension GitObjectID {
    func matchesBlob(_ blob: Data) -> Bool {
        self == Self.hashingBlob(blob, hashLength: hex.utf8.count)
    }

    static func hashingBlob(_ blob: Data, hashLength: Int) -> Self {
        let header = Data("blob \(blob.count)\u{0}".utf8)
        if hashLength == 64 {
            var hash = SHA256()
            hash.update(data: header)
            hash.update(data: blob)
            return Self(digest: hash.finalize())
        }
        var hash = Insecure.SHA1()
        hash.update(data: header)
        hash.update(data: blob)
        return Self(digest: hash.finalize())
    }
}
