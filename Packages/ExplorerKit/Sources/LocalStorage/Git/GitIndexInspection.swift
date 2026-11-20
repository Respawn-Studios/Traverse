import Darwin
import FileOperations
import Foundation

public struct GitFileStatus: Hashable, Sendable {
    public enum WorkingCopy: Hashable, Sendable { case notChecked, matchesIndex, differentBytes, unavailable }

    public let path: GitSnapshotPath
    public let indexed: GitSnapshotMember?
    public let hasStagedChange: Bool
    public let isConflicted: Bool
    public let isIgnored: Bool
    public let workingCopy: WorkingCopy
    public var isUntracked: Bool { indexed == nil && !isConflicted && !isIgnored }
}

public struct GitIndexConflict: Identifiable, Sendable {
    public let path: GitSnapshotPath
    public let base: GitSnapshotMember?
    public let ours: GitSnapshotMember?
    public let theirs: GitSnapshotMember?

    public var id: GitSnapshotPath { path }
}

extension GitReadView {
    private enum IndexStage: UInt8 { case staged = 48, base, ours, theirs }

    func stagedComparison(relativeFolder: String, against revision: GitRevisionSelection?,
                          check: () throws -> Void) throws -> GitStagedComparison {
        let base = try revision.map(resolve) ?? files.head
        let pathspec = try comparisonPaths(in: relativeFolder)
        let index = try installIndex(check: check)
        let arguments = (base.map { [$0.hex] } ?? []) + ["--"] + pathspec
        let output = try run(["diff", "--cached", "--ita-invisible-in-index", "--diff-filter=ACDMRT"] +
            comparisonOptions + arguments)
        let summary = try GitTreeComparisonParser.read(output, hashLength: files.hashLength,
            relativeFolder: relativeFolder, check: check)
        let prefix = relativeFolder.isEmpty ? Data() : Data((relativeFolder + "/").utf8)
        let entries = try readIndexEntries(["--unmerged", "-z", "--"] + pathspec, check: check) { _ in true }
        let conflicts = try entries.map { path, stages in
            try check()
            guard path.bytes.starts(with: prefix), stages[.staged] == nil else {
                throw GitInspectionFailure.invalidOutput
            }
            return GitIndexConflict(path: path, base: stages[.base], ours: stages[.ours], theirs: stages[.theirs])
        }.sorted { $0.path.bytes.lexicographicallyPrecedes($1.path.bytes) }
        try validateIndex(index)
        return .init(base: base, comparesHead: base != nil && base == files.head, summary: summary, conflicts: conflicts)
    }

    func fileStatus(paths: [GitSnapshotPath], inspectWorkingBytes: Bool,
                    check: () throws -> Void) throws -> [GitFileStatus] {
        guard (1...512).contains(paths.count), Set(paths).count == paths.count,
              paths.reduce(0, { $0 + $1.bytes.count + 1 }) <= 64 << 10 else {
            throw GitInspectionFailure.limitExceeded
        }
        let pathArguments = paths.compactMap(\.literalArgument)
        guard pathArguments.count == paths.count else { throw GitInspectionFailure.unsupportedRepository }
        let available = Set(paths)
        let index = try installIndex(check: check)
        let (members, conflicts) = try indexedMembers(available, arguments: pathArguments, check: check)

        let base = files.head.map { [$0.hex] } ?? []
        let changes = try run(["diff", "--cached", "--name-status", "-z", "--ita-invisible-in-index", "--no-renames",
            "--no-ext-diff", "--no-textconv", "--diff-filter=AMDT", "--ignore-submodules=all"] + base + ["--"] + pathArguments,
            maximumBytes: 4 << 20)
        let fields = try records(changes)
        guard fields.count.isMultiple(of: 2) else { throw GitInspectionFailure.invalidOutput }
        var staged = Set<GitSnapshotPath>()
        for offset in stride(from: 0, to: fields.count, by: 2) {
            try check()
            guard fields[offset].count == 1, let change = fields[offset].first, [65, 77, 68, 84].contains(change),
                  let path = GitSnapshotPath(fields[offset + 1]) else { throw GitInspectionFailure.invalidOutput }
            if available.contains(path), !staged.insert(path).inserted { throw GitInspectionFailure.invalidOutput }
        }

        let candidates = paths.filter { members[$0] == nil && !conflicts.contains($0) }
        let ignored = try ignoredPaths(candidates, check: check)
        var workingBudget = 4 << 20
        let result: [GitFileStatus] = try paths.map { path in
            try check()
            let member = members[path]
            let state = inspectWorkingBytes ? try workingState(member, budget: &workingBudget, check: check) : .notChecked
            return .init(path: path, indexed: member, hasStagedChange: staged.contains(path),
                isConflicted: conflicts.contains(path), isIgnored: ignored.contains(path), workingCopy: state)
        }
        try validateIndex(index)
        return result
    }

    func indexText(_ path: GitSnapshotPath, check: () throws -> Void) throws -> TextDocumentValue {
        guard let argument = path.literalArgument else { throw GitInspectionFailure.unsupportedRepository }
        let index = try installIndex(check: check)
        let (members, conflicts) = try indexedMembers([path], arguments: [argument], check: check)
        if conflicts.contains(path) { throw GitInspectionFailure.indexConflict }
        guard let member = members[path] else { throw GitInspectionFailure.noIndexedVersion }
        let result = try text(member)
        try validateIndex(index)
        return result
    }

    /// An index has paths rather than folder objects. An indexed descendant
    /// proves its parent exists here, without inventing a tree object for it.
    func indexFolder(at path: GitSnapshotPath?, check: () throws -> Void) throws -> GitWorkingFolder.ReferenceDirectory {
        let arguments: [String]
        if let path {
            guard let argument = path.literalArgument else { throw GitInspectionFailure.unsupportedRepository }
            arguments = [argument]
        } else { arguments = [] }
        let indexed = try readIndexEntries(["--stage", "-z", "--"] + arguments, check: check) { _ in true }
        let prefix = path.map { $0.bytes + Data([47]) } ?? Data()
        let exact = path.flatMap { indexed[$0] }
        if let exact, indexed.count == 1 {
            return .init(state: exact[.staged] == nil ? .unavailable : .differentType, entries: [:])
        }
        guard exact?[.staged] == nil else { throw GitInspectionFailure.invalidOutput }

        var entries: [GitSnapshotPath: GitWorkingFolder.ReferenceEntry] = [:]
        for (candidate, stages) in indexed where candidate != path {
            try check()
            guard candidate.bytes.starts(with: prefix) else { throw GitInspectionFailure.invalidOutput }
            let relative = candidate.bytes.dropFirst(prefix.count)
            if let separator = relative.firstIndex(of: 47) {
                guard let folder = GitSnapshotPath(prefix + relative[..<separator]) else { throw GitInspectionFailure.invalidOutput }
                switch entries[folder] {
                case nil: entries[folder] = .impliedFolder
                case .conflict?: entries[folder] = .conflict(hasFolder: true)
                case .impliedFolder?: break
                case .member?: throw GitInspectionFailure.invalidOutput
                }
            } else if let member = stages[.staged] {
                guard entries[candidate] == nil else { throw GitInspectionFailure.invalidOutput }
                entries[candidate] = .member(member)
            } else {
                entries[candidate] = .conflict(hasFolder: entries[candidate]?.kind == .directory)
            }
            guard entries.count <= 4_096 else { throw GitInspectionFailure.limitExceeded }
        }
        return .init(state: path == nil || !entries.isEmpty ? .available : .absent, entries: entries)
    }

    private func workingState(_ member: GitSnapshotMember?, budget: inout Int, check: () throws -> Void) throws -> GitFileStatus.WorkingCopy {
        guard let member, member.isTextCandidate, let path = member.path.literalArgument, budget > 0 else { return .unavailable }
        do {
            let url = files.root.url.appendingPathComponent(path)
            let bytes = try LocalTextComparisonRead.fileBytes(at: url, within: files.root,
                maximumBytes: min(budget, TextDocumentValue.maximumBytes), checkCancellation: check)
            budget -= bytes.count
            return member.object.matchesBlob(bytes) ? .matchesIndex : .differentBytes
        } catch is CancellationError { throw CancellationError() }
        catch { return .unavailable }
    }

    private func indexedMembers(_ paths: Set<GitSnapshotPath>, arguments: [String], check: () throws -> Void)
        throws -> ([GitSnapshotPath: GitSnapshotMember], Set<GitSnapshotPath>) {
        let entries = try readIndexEntries(["--stage", "-z", "--"] + arguments, check: check, including: paths.contains)
        var members: [GitSnapshotPath: GitSnapshotMember] = [:]
        var conflicts = Set<GitSnapshotPath>()
        for (path, stages) in entries {
            if let member = stages[.staged] { members[path] = member }
            else { conflicts.insert(path) }
        }
        return (members, conflicts)
    }

    private func readIndexEntries(_ arguments: [String], check: () throws -> Void,
                                  including: (GitSnapshotPath) -> Bool) throws -> [GitSnapshotPath: [IndexStage: GitSnapshotMember]] {
        let rows = try records(run(["ls-files"] + arguments, maximumBytes: 4 << 20))
        var entries: [GitSnapshotPath: [IndexStage: GitSnapshotMember]] = [:]
        for row in rows {
            try check()
            let columns = row.split(separator: 9, maxSplits: 1)
            guard columns.count == 2, let path = GitSnapshotPath(columns[1]) else { throw GitInspectionFailure.invalidOutput }
            guard including(path) else { continue }
            let details = columns[0].split(separator: 32)
            guard details.count == 3, details[2].count == 1, let byte = details[2].first, let stage = IndexStage(rawValue: byte),
                  let oid = GitObjectID(String(decoding: details[1], as: UTF8.self)), !oid.isNull, oid.hex.count == files.hashLength,
                  let member = try GitSnapshotMember.read(mode: details[0], path: path, id: oid),
                  entries[path, default: [:]].updateValue(member, forKey: stage) == nil else {
                throw GitInspectionFailure.invalidOutput
            }
        }
        guard entries.values.allSatisfy({ $0[.staged] == nil || $0.count == 1 }) else { throw GitInspectionFailure.invalidOutput }
        return entries
    }

    /// Only the private Git directory sees an index. Git lock paths and
    /// index extensions cannot reach the original index or the checkout.
    func installIndex(check: () throws -> Void) throws -> EntrySnapshot? {
        let observed = try files.metadata.gitEntry("index").map(EntrySnapshot.init)
        if let bytes = try files.metadata.gitReadOptional("index", maximum: 16 << 20, check: check) {
            guard bytes.count >= 32, bytes.starts(with: [68, 73, 82, 67]) else { throw GitInspectionFailure.invalidOutput }
            try bytes.write(to: directory.url.appendingPathComponent("index"), options: .withoutOverwriting)
        }
        try validateIndex(observed)
        return observed
    }

    func validateIndex(_ observed: EntrySnapshot?) throws {
        guard try files.metadata.gitEntry("index").map(EntrySnapshot.init) == observed else {
            throw GitInspectionFailure.changed
        }
    }

    func records(_ bytes: Data) throws -> [Data] {
        if bytes.isEmpty { return [] }
        let tokens = bytes.split(separator: 0, omittingEmptySubsequences: false)
        guard tokens.last?.isEmpty == true, tokens.count <= 16_385 else { throw GitInspectionFailure.invalidOutput }
        return Array(tokens.dropLast())
    }
}
