import Darwin
import ExplorerCore
import FileOperations
import Foundation

/// One directory in a Git revision or index and its spelling-matched local directory.
/// A folder visit examines names and types. File contents need a selected row.
public struct GitWorkingFolder: Sendable {
    public enum Baseline: Sendable { case revision(GitRevisionSelection), index }
    public enum DirectoryState: Sendable, Equatable { case available, absent, differentType, unavailable }
    public enum WorkingKind: Sendable, Equatable { case file, directory, symbolicLink, other, unavailable }
    public enum Difference: Sendable, Equatable { case onlyInRevision, onlyOnDisk, differentTypes, bothFolders, contentsUnchecked, indexConflict, unavailable }

    public struct ContentReview: Sendable {
        public enum Result: Equatable, Sendable { case matchesRevision, differs, aboveLimit, unavailable }
        public let results: [GitSnapshotPath: Result]
        public let matching: Int
        public let differing: Int
        public let unreadable: Int
        public let unchecked: Int
    }

    fileprivate struct WorkingFile: Sendable {
        let observation: EntrySnapshot
        let size: Int64
    }

    enum ReferenceEntry: Sendable {
        case member(GitSnapshotMember)
        case impliedFolder
        case conflict(hasFolder: Bool)

        var member: GitSnapshotMember? { if case .member(let value) = self { return value }; return nil }
        var kind: GitSnapshotMember.Kind? {
            switch self {
            case .member(let value): value.kind
            case .impliedFolder: .directory
            case .conflict(let hasFolder): hasFolder ? .directory : nil
            }
        }
    }

    struct ReferenceDirectory {
        let state: DirectoryState
        let entries: [GitSnapshotPath: ReferenceEntry]
    }

    public struct Row: Identifiable, Sendable {
        public var id: GitSnapshotPath { path }
        public let path: GitSnapshotPath
        let reference: ReferenceEntry?
        public let working: WorkingKind?
        public let difference: Difference
        fileprivate let file: WorkingFile?

        public var referenceKind: GitSnapshotMember.Kind? { reference?.kind }
        public var referenceMember: GitSnapshotMember? { reference?.member }
        public var isFolder: Bool { referenceKind == .directory || working == .directory }
    }

    public let revision: GitObjectID?
    public var comparesIndex: Bool { revision == nil }
    public let path: GitSnapshotPath?
    public let committedState: DirectoryState
    public let workingState: DirectoryState
    public let rows: [Row]
    public let onlyInRevision: Int
    public let onlyOnDisk: Int
    public let contentCandidates: Int
    fileprivate let location: GitRepositoryLocation
    fileprivate let workingDirectory: GitDirectoryIdentity?
    fileprivate let workingObservation: EntrySnapshot?
    fileprivate let indexObservation: EntrySnapshot?

    public struct TextSelection: Sendable {
        public let path: GitSnapshotPath
        public let referenceMember: GitSnapshotMember?
        public var existsOnDisk: Bool { working != nil }
        /// An exact path for matching a live editor. It carries no permission
        /// to open, replace, or save the working file.
        public var workingFileURL: URL? {
            guard working != nil, let relative = path.literalArgument else { return nil }
            let result = location.root.appendingPathComponent(relative, isDirectory: false)
            return location.filePath(for: result) == path ? result : nil
        }
        let location: GitRepositoryLocation
        fileprivate let folder: GitSnapshotPath?
        fileprivate let directory: GitDirectoryIdentity?
        fileprivate let working: EntrySnapshot?
        fileprivate let comparesIndex: Bool
        fileprivate let indexObservation: EntrySnapshot?
    }

    public func textSelection(for path: GitSnapshotPath) -> TextSelection? {
        rows.first(where: { $0.path == path }).flatMap(textSelection)
    }

    /// Keep the report order and use the same captured directory and member
    /// observations as opening an individual row.
    public func textSelections(visiblePaths: Set<GitSnapshotPath>? = nil, limit: Int = .max) -> [TextSelection] {
        Array(rows.lazy.filter { visiblePaths?.contains($0.path) ?? true }.compactMap(textSelection).prefix(max(0, limit)))
    }

    private func textSelection(_ row: Row) -> TextSelection? {
        let path = row.path
        guard let argument = path.literalArgument,
              !AutomaticMetadataPolicy.excludes(location.root.appendingPathComponent(argument)),
              !row.isFolder, row.difference != .indexConflict,
              row.referenceMember?.isTextCandidate != false, row.working == nil || row.working == .file,
              row.referenceMember != nil || row.working == .file,
              workingState == .available || workingState == .absent,
              committedState == .available || committedState == .absent else { return nil }
        return .init(path: path, referenceMember: row.referenceMember, location: location,
            folder: self.path, directory: workingDirectory, working: row.file?.observation,
            comparesIndex: comparesIndex, indexObservation: indexObservation)
    }

    public func openSelection(for path: GitSnapshotPath) -> LocalTextOpenSelection? {
        guard workingState == .available, let workingObservation,
              let row = rows.first(where: { $0.path == path }), let file = row.file,
              file.size >= 0, file.size <= TextDocumentValue.maximumBytes,
              let relative = path.literalArgument else { return nil }
        let result = location.root.appendingPathComponent(relative, isDirectory: false)
        guard location.filePath(for: result) == path, !AutomaticMetadataPolicy.excludes(result) else { return nil }
        return .init(url: result, parent: workingObservation, file: file.observation)
    }

    public struct StagingSelection: Equatable, Sendable, CustomStringConvertible {
        public let path: GitSnapshotPath
        public var isRemoval: Bool { workingEntry == nil }
        let member: GitSnapshotMember?
        var working: GitWorkingFile.Identity? { workingEntry.map { .init(parent: directory, entry: $0) } }
        fileprivate let location: GitRepositoryLocation
        fileprivate let folder: GitSnapshotPath?
        fileprivate let directory: GitDirectoryIdentity
        fileprivate let index: EntrySnapshot
        fileprivate let workingEntry: EntrySnapshot?
        public var description: String { "<Git index staging selection>" }
    }

    public func stagingSelection(for path: GitSnapshotPath) -> StagingSelection? {
        guard comparesIndex, workingState == .available, let workingDirectory, let indexObservation,
              let row = rows.first(where: { $0.path == path }), row.referenceMember?.isTextCandidate != false,
              let relative = path.literalArgument,
              location.filePath(for: location.root.appendingPathComponent(relative)) == path else { return nil }
        if let file = row.file {
            guard row.difference == .onlyOnDisk || row.difference == .contentsUnchecked,
                  (0...Int64(GitWorkingFile.maximumBytes)).contains(file.size) else { return nil }
        } else {
            guard row.difference == .onlyInRevision, row.referenceMember != nil else { return nil }
        }
        return .init(path: path, member: row.referenceMember, location: location, folder: self.path,
            directory: workingDirectory, index: indexObservation, workingEntry: row.file?.observation)
    }
}

extension GitReadView {
    func validateIndexSelection(_ selection: GitWorkingFolder.StagingSelection, in location: GitRepositoryLocation,
                              check: () throws -> Void) throws {
        try check()
        guard selection.location.isSameRepository(as: location),
              try files.metadata.gitEntry("index").map(EntrySnapshot.init) == selection.index,
              let name = selection.path.literalArgument?.split(separator: "/").last,
              case .available(let parent) = try GitWorkingDisk.directory(at: selection.folder, within: files.root, check: check),
              try GitDirectoryIdentity(parent.fd) == selection.directory,
              try parent.gitEntry(String(name)).map(EntrySnapshot.init) == selection.workingEntry else { throw GitInspectionFailure.changed }
        try parent.validate()
    }

    func workingFolder(location: GitRepositoryLocation, at path: GitSnapshotPath?, baseline: GitWorkingFolder.Baseline,
                       showHidden: Bool, check: () throws -> Void) throws -> GitWorkingFolder {
        let revision: GitObjectID?, index: EntrySnapshot?, reference: GitWorkingFolder.ReferenceDirectory
        switch baseline {
        case .revision(let selection):
            let id = try resolve(selection)
            revision = id; index = nil
            let snapshot = try folder(at: path, commit: id, check: check)
            switch snapshot {
            case .children(let entries):
                reference = .init(state: .available, entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.path, .member($0)) }))
            case .absent: reference = .init(state: .absent, entries: [:])
            case .differentType: reference = .init(state: .differentType, entries: [:])
            }
        case .index:
            revision = nil
            index = try installIndex(check: check)
            reference = try indexFolder(at: path, check: check)
        }
        let right = try GitWorkingDisk.directory(at: path, within: files.root, check: check)
        func visible(_ bytes: Data) -> Bool {
            guard !bytes.isEmpty, String(decoding: bytes, as: UTF8.self).lowercased() != ".git" else { return false }
            return showHidden || bytes.first != 46
        }
        let entries = reference.entries.filter { visible(Data($0.key.bytes.split(separator: 47).last ?? Data())) }
        var disk: [GitSnapshotPath: (kind: GitWorkingFolder.WorkingKind, file: GitWorkingFolder.WorkingFile?)] = [:]
        var workingIdentity: GitDirectoryIdentity?
        var workingObservation: EntrySnapshot?
        if case .available(let parent) = right {
            let before = try EntrySnapshot(fd: parent.fd)
            workingObservation = before
            workingIdentity = try GitDirectoryIdentity(parent.fd)
            var visited = 0
            try parent.gitNames(check: check) { name in
                visited += 1
                guard visited <= 4_096 else { throw GitInspectionFailure.limitExceeded }
                guard visible(Data(name.utf8)) else { return }
                let bytes = path.map { $0.bytes + Data([47]) + Data(name.utf8) } ?? Data(name.utf8)
                guard let item = GitSnapshotPath(bytes), disk[item] == nil else { throw GitInspectionFailure.invalidOutput }
                disk[item] = try GitWorkingDisk.entry(name, within: parent)
            }
            try parent.validate()
            guard try EntrySnapshot(fd: parent.fd) == before else { throw GitInspectionFailure.changed }
        }
        let rows: [GitWorkingFolder.Row] = try Set(entries.keys).union(disk.keys).map { item in
            try check()
            let from = entries[item], to = disk[item]
            let difference = Self.workingDifference(left: from, right: to?.kind,
                committedState: reference.state, workingState: right.state)
            return .init(path: item, reference: from, working: to?.kind, difference: difference, file: to?.file)
        }.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let order = a.path.name.localizedStandardCompare(b.path.name)
            return order == .orderedSame ? a.path.bytes.lexicographicallyPrecedes(b.path.bytes) : order == .orderedAscending
        }
        try files.anchors.validate(check: check)
        if revision == nil { try validateIndex(index) }
        return .init(revision: revision, path: path, committedState: reference.state, workingState: right.state,
            rows: rows, onlyInRevision: rows.count { $0.difference == .onlyInRevision },
            onlyOnDisk: rows.count { $0.difference == .onlyOnDisk }, contentCandidates: rows.count { $0.difference == .contentsUnchecked },
            location: location, workingDirectory: workingIdentity, workingObservation: workingObservation, indexObservation: index)
    }

    private static func workingDifference(left: GitWorkingFolder.ReferenceEntry?, right: GitWorkingFolder.WorkingKind?,
        committedState: GitWorkingFolder.DirectoryState, workingState: GitWorkingFolder.DirectoryState) -> GitWorkingFolder.Difference {
        if case .conflict? = left { return .indexConflict }
        if right == .unavailable || workingState == .unavailable || committedState == .unavailable { return .unavailable }
        if workingState == .differentType || committedState == .differentType { return .differentTypes }
        guard let left else { return .onlyOnDisk }
        guard let right else { return .onlyInRevision }
        if left.kind == .directory, right == .directory { return .bothFolders }
        if left.member?.isTextCandidate == true, right == .file { return .contentsUnchecked }
        if left.kind == .symbolicLink, right == .symbolicLink { return .unavailable }
        return .differentTypes
    }

    func workingComparison(_ selection: GitWorkingFolder.TextSelection, check: () throws -> Void) throws -> TextComparisonDocuments {
        let reference = try workingReference(selection)
        try check()
        guard let argument = selection.path.literalArgument else { throw GitInspectionFailure.unsupportedRepository }
        let name = String(argument.split(separator: "/").last ?? "")
        let current: TextDocumentValue
        switch (try GitWorkingDisk.directory(at: selection.folder, within: files.root, check: check), selection.directory, selection.working) {
        case (.absent, nil, nil):
            current = try .original(Data())
        case (.available(let parent), .some(let witness), let observation):
            guard try GitDirectoryIdentity(parent.fd) == witness else { throw GitInspectionFailure.changed }
            let exact = try GitWorkingDisk.exactEntry(name, in: parent, check: check)
            if let observation {
                guard exact.map(EntrySnapshot.init) == observation else { throw GitInspectionFailure.changed }
                let url = parent.url.appendingPathComponent(name)
                let bytes = try LocalTextComparisonRead.fileBytes(at: url, within: parent,
                    maximumBytes: TextDocumentValue.maximumBytes, expecting: observation, checkCancellation: check)
                guard try GitWorkingDisk.exactEntry(name, in: parent, check: check).map(EntrySnapshot.init) == observation else {
                    throw GitInspectionFailure.changed
                }
                current = try .original(bytes)
            } else {
                guard exact == nil else { throw GitInspectionFailure.changed }
                current = try .original(Data())
            }
            try parent.validate()
        default: throw GitInspectionFailure.changed
        }
        try files.anchors.validate(check: check)
        if selection.comparesIndex { try validateIndex(selection.indexObservation) }
        try check()
        return .init(left: reference, right: current)
    }

    func workingReference(_ selection: GitWorkingFolder.TextSelection) throws -> TextDocumentValue {
        if selection.comparesIndex { try validateIndex(selection.indexObservation) }
        let reference = try text(selection.referenceMember)
        if selection.comparesIndex { try validateIndex(selection.indexObservation) }
        return reference
    }
}

extension GitWorkingFolder {
    func checkContents(check: () throws -> Void) throws -> ContentReview {
        var budget = FileContentsReviewBudget()
        let anchors = try location.openAnchors(check: check)
        func checkIndex() throws {
            if comparesIndex, try anchors.metadata.gitEntry("index").map(EntrySnapshot.init) != indexObservation {
                throw GitInspectionFailure.changed
            }
        }
        try checkIndex()
        let root = anchors.root
        guard let expected = workingObservation,
              case .available(let parent) = try GitWorkingDisk.directory(at: path, within: root, check: check),
              try EntrySnapshot(fd: parent.fd) == expected else { throw GitInspectionFailure.changed }
        var results: [GitSnapshotPath: ContentReview.Result] = [:]
        candidates: for row in rows where row.difference == .contentsUnchecked {
            try check()
            guard let file = row.file, let member = row.referenceMember, let name = row.path.literalArgument?.split(separator: "/").last else {
                throw GitInspectionFailure.invalidOutput
            }
            // Charge the full observed size even when a read returns an error.
            let admitted: Int
            switch budget.admit(size: file.size, copies: 1) {
            case .accepted(let bytes): admitted = bytes
            case .fileTooLarge: results[row.path] = .aboveLimit; continue
            case .exhaustedBytes: continue
            case .exhaustedPairs: break candidates
            }
            do {
                let bytes = try LocalTextComparisonRead.fileBytes(at: parent.url.appendingPathComponent(String(name)), within: parent,
                    maximumBytes: admitted, expecting: file.observation, checkCancellation: check)
                results[row.path] = member.object.matchesBlob(bytes) ? .matchesRevision : .differs
            } catch is CancellationError { throw CancellationError() }
            catch { results[row.path] = .unavailable }
        }
        try parent.validate()
        guard try EntrySnapshot(fd: parent.fd) == expected else { throw GitInspectionFailure.changed }
        try anchors.validate(check: check)
        try checkIndex()
        try check()
        let matching = results.values.count { $0 == .matchesRevision }
        let differing = results.values.count { $0 == .differs }
        let unreadable = results.values.count { $0 == .unavailable }
        return .init(results: results, matching: matching, differing: differing, unreadable: unreadable,
            unchecked: contentCandidates - matching - differing - unreadable)
    }
}

private enum GitWorkingDisk {
    enum Directory {
        case available(DirectoryAnchor), absent, differentType, unavailable

        var state: GitWorkingFolder.DirectoryState {
            switch self {
            case .available: .available
            case .absent: .absent
            case .differentType: .differentType
            case .unavailable: .unavailable
            }
        }
    }

    static func directory(at path: GitSnapshotPath?, within root: DirectoryAnchor, check: () throws -> Void) throws -> Directory {
        guard let path else { return .available(root) }
        guard let argument = path.literalArgument else { return .unavailable }
        var parent = root
        for name in argument.split(separator: "/").map(String.init) {
            try check()
            let url = parent.url.appendingPathComponent(name, isDirectory: true)
            guard name.lowercased() != ".git", !AutomaticMetadataPolicy.excludes(url) else { return .unavailable }
            guard let found = try exactEntry(name, in: parent, check: check) else { return .absent }
            guard found.st_mode & S_IFMT == S_IFDIR else { return .differentType }
            guard found.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0, found.st_dev == root.device else { return .unavailable }
            do {
                let next = try parent.gitDirectory(name)
                guard try GitDirectoryIdentity(next.fd) == GitDirectoryIdentity(found), try next.gitEntry(".git") == nil else {
                    return .unavailable
                }
                parent = next
            } catch is CancellationError { throw CancellationError() }
            catch { return .unavailable }
        }
        return .available(parent)
    }

    /// APFS may resolve a different spelling through the same system call.
    /// Git path selection is byte-exact, including absence and case changes.
    static func exactEntry(_ name: String, in parent: DirectoryAnchor, check: () throws -> Void) throws -> stat? {
        let folder = try EntrySnapshot(fd: parent.fd)
        guard let observed = try parent.gitEntry(name) else {
            try parent.validate()
            guard try EntrySnapshot(fd: parent.fd) == folder else { throw GitInspectionFailure.changed }
            return nil
        }
        var exact = false, visited = 0
        try parent.gitNames(check: check) { item in
            visited += 1
            guard visited <= 4_096 else { throw GitInspectionFailure.limitExceeded }
            if item.utf8.elementsEqual(name.utf8) { exact = true }
        }
        try parent.validate()
        let current = try parent.gitEntry(name)
        guard current.map(EntrySnapshot.init) == EntrySnapshot(observed), try EntrySnapshot(fd: parent.fd) == folder else {
            throw GitInspectionFailure.changed
        }
        return exact ? current : nil
    }

    static func entry(_ name: String, within parent: DirectoryAnchor) throws -> (GitWorkingFolder.WorkingKind, GitWorkingFolder.WorkingFile?) {
        let url = parent.url.appendingPathComponent(name)
        guard !AutomaticMetadataPolicy.excludes(url), let item = try parent.gitEntry(name),
              item.st_dev == parent.device, item.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0 else { return (.unavailable, nil) }
        switch item.st_mode & S_IFMT {
        case S_IFREG: return (.file, .init(observation: EntrySnapshot(item), size: item.st_size))
        case S_IFDIR: return (.directory, nil)
        case S_IFLNK: return (.symbolicLink, nil)
        default: return (.other, nil)
        }
    }
}
