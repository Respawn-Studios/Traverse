import Darwin
import ExplorerCore
import Foundation

public enum FolderComparisonFailure: Error, Equatable, Sendable {
    public enum Side: Equatable, Sendable { case left, right }
    case unavailable(Side)
    case unsupported(Side)
    case sameFolder
    case changed
    case limitExceeded
}

/// A read-only observation of two folder trees. Matching file metadata does not
/// establish that the bytes or other filesystem attributes match.
public struct FolderComparisonReport: Sendable {
    public enum Difference: Equatable, Sendable {
        case onlyOnLeft, onlyOnRight, differentKind, differentSize, differentModificationTime, differentContents
        case contentsNotChecked, notCompared
    }
    public enum Omission: Equatable, Sendable {
        case unreadable, symbolicLink, specialFile, otherVolume, datalessFolder, protectedLocation, hidden
    }
    public enum Contents: Equatable, Sendable { case matched, different, unchecked }
    public struct Item: Sendable {
        public let kind: FileKind
        public let byteCount: Int64?
        public let modifiedAt: Date?
        let observation: EntrySnapshot
    }
    public struct Row: Identifiable, Sendable {
        public let id: Int
        public let relativePath: String
        public let difference: Difference
        public let left: Item?
        public let right: Item?
        public let omission: Omission?
        public let contents: Contents?
        public var matchedContents: Bool { contents == .matched }
        let copyParents: ComparedParents?
    }
    public let rows: [Row]
    public let matchingFiles: Int
    public let comparedDirectories: Int
    public let omissions: Int
    public let contentReview: ContentReview?
    public var differenceCount: Int {
        rows.count { $0.difference != .notCompared && $0.difference != .contentsNotChecked }
    }

    public struct ContentReview: Sendable {
        public internal(set) var matches = 0
        public internal(set) var differences = 0
        public internal(set) var unchecked = 0
    }

    let leftRoot: ComparedRoot
    let rightRoot: ComparedRoot

    struct ComparedRoot: Sendable {
        let url: URL
        let observation: EntrySnapshot
    }

    final class ComparedParents: Sendable {
        let left: EntrySnapshot
        let right: EntrySnapshot

        init(_ left: EntrySnapshot, _ right: EntrySnapshot) {
            self.left = left
            self.right = right
        }
    }

    /// A selection from one report, with the original file identities and the
    /// observed absence of a file on either side. It has no write authority.
    public struct TextSelection: Sendable {
        public let relativePath: String
        public var hasLeftFile: Bool { left != nil }
        public var hasRightFile: Bool { right != nil }
        let leftRoot: ComparedRoot
        let rightRoot: ComparedRoot
        let left: EntrySnapshot?
        let right: EntrySnapshot?
    }

    public func textSelection(for rowID: Int) -> TextSelection? {
        guard rows.indices.contains(rowID) else { return nil }
        let row = rows[rowID]
        guard row.id == rowID, row.omission == nil, row.difference != .contentsNotChecked, row.left != nil || row.right != nil,
              row.left == nil || row.left?.kind == .file, row.right == nil || row.right?.kind == .file else { return nil }
        return .init(relativePath: row.relativePath, leftRoot: leftRoot, rightRoot: rightRoot,
            left: row.left?.observation, right: row.right?.observation)
    }

    /// A regular file on one side of the report. The editor still qualifies
    /// this observation and makes its own Save token when it opens the file.
    public struct EditorSelection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public var url: URL { root.url.appendingPathComponent(relativePath) }
        let root: ComparedRoot
        let relativePath: String
        let observation: EntrySnapshot

        public var description: String { "<folder comparison file>" }
        public var debugDescription: String { description }
    }

    public func editorSelection(for rowID: Int, on side: FolderComparisonFailure.Side) -> EditorSelection? {
        guard rows.indices.contains(rowID) else { return nil }
        let row = rows[rowID]
        let item = side == .left ? row.left : row.right
        guard row.id == rowID, row.omission == nil, let item, item.kind == .file,
              let length = item.byteCount, (0...Int64(TextDocumentValue.maximumBytes)).contains(length) else { return nil }
        return .init(root: side == .left ? leftRoot : rightRoot, relativePath: row.relativePath,
            observation: item.observation)
    }

    /// Missing regular files whose two parent folders were compared together.
    /// The transfer still requires access, unchanged objects and vacant names.
    public struct MissingFileCopy: Sendable {
        public let sources: [URL]
        public let destinationDirectory: URL
        public let destinationSide: FolderComparisonFailure.Side
        public let observation: FileOperationSelection
    }

    public func missingFileCopy(for rowIDs: Set<Int>) -> MissingFileCopy? {
        guard !rowIDs.isEmpty, rowIDs.count <= OperationJournal.maximumInputs,
              rowIDs.allSatisfy({ rows.indices.contains($0) && rows[$0].id == $0 }),
              let firstID = rowIDs.min(), let parents = rows[firstID].copyParents else { return nil }
        let first = rows[firstID]
        let onLeft = first.difference == .onlyOnLeft
        let sourceRoot = onLeft ? leftRoot : rightRoot
        let destinationRoot = onLeft ? rightRoot : leftRoot
        let sourceParent = sourceRoot.url.appendingPathComponent(first.relativePath).deletingLastPathComponent()
        let destination = destinationRoot.url.appendingPathComponent(first.relativePath).deletingLastPathComponent()
        var sources: [URL] = [], snapshots: [EntrySnapshot] = []
        for id in rowIDs.sorted() {
            let row = rows[id]
            guard row.copyParents === parents, row.difference == first.difference,
                  let file = (onLeft ? row.left : row.right)?.observation else { return nil }
            sources.append(sourceRoot.url.appendingPathComponent(row.relativePath))
            snapshots.append(file)
        }
        return .init(sources: sources, destinationDirectory: destination, destinationSide: onLeft ? .right : .left,
            observation: .init(urls: sources + [sourceParent, destination],
                identities: snapshots + [onLeft ? parents.left : parents.right, onLeft ? parents.right : parents.left]))
    }
}

/// The caller owns access to both roots and schedules this synchronous read on
/// an existing filesystem worker. A directory listed on only one side accounts
/// for that entire branch. Shared branches are walked relative to open folders.
package enum FolderMetadataComparison {
    package static func read(left: URL, right: URL, includingHidden: Bool,
                             checkingContents: Bool = false,
                             checkCancellation: () throws -> Void) throws -> FolderComparisonReport {
        try read(left: left, right: right, includingHidden: includingHidden, limits: .init(), checkingContents: checkingContents,
                 checkCancellation: checkCancellation)
    }

    struct Limits {
        var entries = 50_000
        var pathBytes = 12 << 20
        var depth = 32
    }

    static func read(left: URL, right: URL, includingHidden: Bool, limits: Limits, checkingContents: Bool = false,
                     checkCancellation: () throws -> Void) throws -> FolderComparisonReport {
        try checkCancellation()
        return try withoutMaterialization {
            let leftRoot = try Root(url: left, side: .left)
            let rightRoot = try Root(url: right, side: .right)
            guard !leftRoot.identity.sameObject(as: rightRoot.identity) else { throw FolderComparisonFailure.sameFolder }
            let leftFD = try leftRoot.openForListing()
            defer { close(leftFD) }
            let rightFD = try rightRoot.openForListing()
            defer { close(rightFD) }
            let leftObservation = FolderComparisonReport.ComparedRoot(url: leftRoot.anchor.url, observation: leftRoot.identity)
            let rightObservation = FolderComparisonReport.ComparedRoot(url: rightRoot.anchor.url, observation: rightRoot.identity)
            var comparison = Walk(includingHidden: includingHidden, limits: limits, roots: (leftObservation, rightObservation),
                                  checkingContents: checkingContents)
            try comparison.compare(left: leftFD, right: rightFD, leftBefore: leftRoot.identity,
                rightBefore: rightRoot.identity, prefix: "", depth: 0, checkCancellation: checkCancellation)
            try checkCancellation()
            try leftRoot.validate()
            try rightRoot.validate()
            return .init(rows: comparison.rows, matchingFiles: comparison.matchingFiles,
                comparedDirectories: comparison.comparedDirectories, omissions: comparison.omissions,
                contentReview: comparison.contentReview, leftRoot: leftObservation, rightRoot: rightObservation)
        }
    }

    private struct Root {
        let url: URL
        let anchor: DirectoryAnchor
        let identity: EntrySnapshot
        let side: FolderComparisonFailure.Side

        init(url: URL, side: FolderComparisonFailure.Side) throws {
            guard url.isFileURL, url.path.hasPrefix("/"),
                  url.host == nil || url.host == "" || url.host == "localhost",
                  Self.canCompare(url) else { throw FolderComparisonFailure.unsupported(side) }
            var observed = stat()
            guard lstat(url.path, &observed) == 0 else { throw FolderComparisonFailure.unavailable(side) }
            guard observed.st_mode & S_IFMT == S_IFDIR,
                  observed.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0 else {
                throw FolderComparisonFailure.unsupported(side)
            }
            let anchor: DirectoryAnchor
            do { anchor = try DirectoryAnchor(url) }
            catch { throw FolderComparisonFailure.unavailable(side) }
            let identity = EntrySnapshot(observed)
            guard anchor.identity == identity else { throw FolderComparisonFailure.changed }
            var filesystem = statfs()
            guard Self.canCompare(anchor.url), fstatfs(anchor.fd, &filesystem) == 0,
                  filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw FolderComparisonFailure.unsupported(side) }
            self.url = url
            self.anchor = anchor
            self.identity = identity
            self.side = side
        }

        private static func canCompare(_ url: URL) -> Bool {
            !AutomaticMetadataPolicy.excludes(url)
                && !url.pathComponents.contains { recoveryAreaID(for: $0) != nil }
        }

        func openForListing() throws -> Int32 {
            let fd = openat(anchor.fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw FolderComparisonFailure.unavailable(side) }
            return fd
        }

        func validate() throws {
            var named = stat()
            guard lstat(url.path, &named) == 0, EntrySnapshot(named) == identity,
                  named.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0 else {
                throw FolderComparisonFailure.changed
            }
        }
    }

    private struct Observation {
        let name: String
        let snapshot: EntrySnapshot?
        let flags: UInt32
        let omission: FolderComparisonReport.Omission?

        var isHidden: Bool { flags & UInt32(UF_HIDDEN) != 0 }

        var item: FolderComparisonReport.Item? {
            guard let snapshot else { return nil }
            let kind: FileKind
            switch snapshot.type {
            case S_IFREG: kind = .file
            case S_IFDIR: kind = .directory
            case S_IFLNK: kind = .symbolicLink
            default: kind = .other
            }
            return .init(kind: kind, byteCount: kind == .file ? snapshot.size : nil,
                modifiedAt: kind == .file ? Date(timeIntervalSince1970: Double(snapshot.modifiedSeconds)
                    + Double(snapshot.modifiedNanos) / 1_000_000_000) : nil, observation: snapshot)
        }
    }

    private struct Walk {
        private enum ListingFailure: Error { case unreadable(FolderComparisonFailure.Side) }

        let includingHidden: Bool
        let limits: Limits
        let roots: (FolderComparisonReport.ComparedRoot, FolderComparisonReport.ComparedRoot)
        private var budget = FileContentsReviewBudget()
        private var visited = 0
        private var pathBytes = 0
        var rows: [FolderComparisonReport.Row] = []
        var matchingFiles = 0
        var comparedDirectories = 0
        var omissions = 0
        var contentReview: FolderComparisonReport.ContentReview?

        init(includingHidden: Bool, limits: Limits, roots: (FolderComparisonReport.ComparedRoot, FolderComparisonReport.ComparedRoot),
             checkingContents: Bool) {
            self.includingHidden = includingHidden
            self.limits = limits
            self.roots = roots
            contentReview = checkingContents ? .init() : nil
        }

        mutating func compare(left: Int32, right: Int32, leftBefore: EntrySnapshot, rightBefore: EntrySnapshot,
                              prefix: String, depth: Int, checkCancellation: () throws -> Void) throws {
            try checkCancellation()
            guard depth <= limits.depth else { throw FolderComparisonFailure.limitExceeded }
            try Self.validate(left, expected: leftBefore)
            try Self.validate(right, expected: rightBefore)
            let leftItems: [Data: Observation]
            let rightItems: [Data: Observation]
            do {
                leftItems = try observations(left, side: .left, prefix: prefix, checkCancellation: checkCancellation)
                rightItems = try observations(right, side: .right, prefix: prefix, checkCancellation: checkCancellation)
            } catch ListingFailure.unreadable(let side) {
                throw FolderComparisonFailure.unavailable(side)
            }
            let names = Set(leftItems.keys).union(rightItems.keys).sorted(by: { $0.lexicographicallyPrecedes($1) })
            let parents = FolderComparisonReport.ComparedParents(leftBefore, rightBefore)
            for name in names {
                try checkCancellation()
                let first = leftItems[name], second = rightItems[name]
                guard let leaf = first?.name ?? second?.name else { continue }
                let path = prefix + leaf
                if !includingHidden, first?.isHidden == true || second?.isHidden == true {
                    if first.map({ !$0.isHidden }) == true || second.map({ !$0.isHidden }) == true {
                        append(path, .notCompared, first, second, .hidden)
                    }
                } else if let omission = first?.omission ?? second?.omission {
                    append(path, .notCompared, first, second, omission)
                } else if let first, let second, let a = first.snapshot, let b = second.snapshot {
                    if a.type != b.type {
                        append(path, .differentKind, first, second)
                    } else if a.isDirectory {
                        try compareChildren(first, second, from: left, right, parents: (leftBefore, rightBefore),
                            path: path, depth: depth, checkCancellation: checkCancellation)
                    } else if a.type == S_IFREG {
                        if a.size != b.size { append(path, .differentSize, first, second); continue }
                        let timesMatch = a.modifiedSeconds == b.modifiedSeconds && a.modifiedNanos == b.modifiedNanos
                        let contents = try checkContents(path, left: first, right: second,
                            observations: (a, b), checkCancellation: checkCancellation)
                        if contents == .different { append(path, .differentContents, first, second, contents: contents) }
                        else if !timesMatch { append(path, .differentModificationTime, first, second, contents: contents) }
                        else {
                            matchingFiles += 1
                            if contents == .unchecked { append(path, .contentsNotChecked, first, second, contents: contents) }
                        }
                    } else {
                        append(path, .notCompared, first, second, a.type == S_IFLNK ? .symbolicLink : .specialFile)
                    }
                } else {
                    let existing = first ?? second
                    let sourceParent = first == nil ? rightBefore : leftBefore
                    let copyParents: FolderComparisonReport.ComparedParents? = if let existing, let file = existing.snapshot,
                        file.type == S_IFREG, file.device == sourceParent.device,
                        existing.flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0,
                        (try? validateName(existing.name)) != nil { parents } else { nil }
                    append(path, first == nil ? .onlyOnRight : .onlyOnLeft, first, second, copyParents: copyParents)
                }
            }
            try Self.validate(left, expected: leftBefore)
            try Self.validate(right, expected: rightBefore)
            comparedDirectories += 1
        }

        private mutating func checkContents(_ path: String, left: Observation, right: Observation,
                                            observations: (EntrySnapshot, EntrySnapshot),
                                            checkCancellation: () throws -> Void) throws -> FolderComparisonReport.Contents? {
            guard contentReview != nil else { return nil }
            let (a, b) = observations
            guard (left.flags | right.flags) & UInt32(SF_DATALESS | SF_FIRMLINK) == 0,
                  !path.split(separator: "/").contains(where: { $0.lowercased() == ".git" }),
                  case .accepted(let bytes) = budget.admit(size: a.size, copies: 2) else {
                contentReview?.unchecked += 1
                return .unchecked
            }
            let selection = FolderComparisonReport.TextSelection(relativePath: path, leftRoot: roots.0, rightRoot: roots.1,
                left: a, right: b)
            do {
                let equal = try LocalTextComparisonRead.contentsMatch(selection, maximumBytes: bytes,
                    checkCancellation: checkCancellation)
                if equal { contentReview?.matches += 1 } else { contentReview?.differences += 1 }
                return equal ? .matched : .different
            } catch is CancellationError { throw CancellationError() }
            catch {
                // An unavailable pair remains unchecked. The enclosing
                // listing still revalidates both folder observations.
                contentReview?.unchecked += 1
                return .unchecked
            }
        }

        private mutating func compareChildren(_ first: Observation, _ second: Observation,
                                              from left: Int32, _ right: Int32, parents: (EntrySnapshot, EntrySnapshot),
                                              path: String, depth: Int, checkCancellation: () throws -> Void) throws {
            guard let a = first.snapshot, let b = second.snapshot else { throw FolderComparisonFailure.changed }
            if (first.flags | second.flags) & UInt32(SF_DATALESS) != 0 {
                append(path, .notCompared, first, second, .datalessFolder); return
            }
            if (first.flags | second.flags) & UInt32(SF_FIRMLINK) != 0
                || a.device != parents.0.device || b.device != parents.1.device {
                append(path, .notCompared, first, second, .otherVolume); return
            }
            guard depth < limits.depth else { throw FolderComparisonFailure.limitExceeded }
            guard let leftFD = try Self.openChild(first.name, at: left) else {
                append(path, .notCompared, first, second, .unreadable); return
            }
            defer { close(leftFD) }
            guard let rightFD = try Self.openChild(second.name, at: right) else {
                append(path, .notCompared, first, second, .unreadable); return
            }
            defer { close(rightFD) }
            do {
                try compare(left: leftFD, right: rightFD, leftBefore: a, rightBefore: b,
                            prefix: path + "/", depth: depth + 1, checkCancellation: checkCancellation)
            } catch FolderComparisonFailure.unavailable {
                append(path, .notCompared, first, second, .unreadable)
            }
        }

        private static func openChild(_ name: String, at parent: Int32) throws -> Int32? {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 {
                if [ENOENT, ENOTDIR, ELOOP].contains(errno) { throw FolderComparisonFailure.changed }
                return nil
            }
            return fd
        }

        private static func validate(_ fd: Int32, expected: EntrySnapshot) throws {
            var value = stat()
            guard fstat(fd, &value) == 0, EntrySnapshot(value) == expected,
                  value.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0 else {
                throw FolderComparisonFailure.changed
            }
        }

        private mutating func observations(_ fd: Int32, side: FolderComparisonFailure.Side, prefix: String,
                                           checkCancellation: () throws -> Void) throws -> [Data: Observation] {
            let duplicate = dup(fd)
            guard duplicate >= 0 else { throw ListingFailure.unreadable(side) }
            guard let directory = fdopendir(duplicate) else {
                close(duplicate); throw ListingFailure.unreadable(side)
            }
            defer { closedir(directory) }
            var observations: [Data: Observation] = [:]
            let prefixBytes = prefix.utf8.count
            while true {
                try checkCancellation()
                errno = 0
                guard let item = readdir(directory) else {
                    guard errno == 0 else { throw ListingFailure.unreadable(side) }
                    return observations
                }
                let nameBytes = withUnsafeBytes(of: &item.pointee.d_name) { buffer in
                    Data(buffer.prefix(Int(item.pointee.d_namlen)))
                }
                guard !(nameBytes.count <= 2 && nameBytes.allSatisfy({ $0 == 46 })) else { continue }
                guard visited < limits.entries else { throw FolderComparisonFailure.limitExceeded }
                visited += 1
                guard includingHidden || nameBytes.first != 46 else { continue }
                pathBytes += prefixBytes + nameBytes.count
                guard pathBytes <= limits.pathBytes else { throw FolderComparisonFailure.limitExceeded }
                guard observations[nameBytes] == nil else { throw FolderComparisonFailure.changed }
                guard let name = String(data: nameBytes, encoding: .utf8), Data(name.utf8) == nameBytes else {
                    // Preserve the undecodable name's exact raw identity in the
                    // map. Never pass a lossy display name back to the filesystem.
                    observations[nameBytes] = .init(name: "Unreadable name", snapshot: nil, flags: 0, omission: .unreadable)
                    continue
                }
                // Recovery payloads belong to their operation record. They
                // must not be offered as missing user files or read here.
                if recoveryAreaID(for: name) != nil { continue }
                if AutomaticMetadataPolicy.excludesComponent(name) {
                    observations[nameBytes] = .init(name: name, snapshot: nil, flags: 0, omission: .protectedLocation)
                    continue
                }
                var value = stat()
                guard fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if [ENOENT, ENOTDIR].contains(errno) { throw FolderComparisonFailure.changed }
                    observations[nameBytes] = .init(name: name, snapshot: nil, flags: 0, omission: .unreadable)
                    continue
                }
                observations[nameBytes] = .init(name: name, snapshot: EntrySnapshot(value), flags: value.st_flags, omission: nil)
            }
        }

        private mutating func append(_ path: String, _ difference: FolderComparisonReport.Difference,
                                     _ left: Observation?, _ right: Observation?, _ omission: FolderComparisonReport.Omission? = nil,
                                     copyParents: FolderComparisonReport.ComparedParents? = nil,
                                     contents: FolderComparisonReport.Contents? = nil) {
            rows.append(.init(id: rows.count, relativePath: path, difference: difference,
                              left: left?.item, right: right?.item, omission: omission,
                              contents: contents, copyParents: copyParents))
            if omission != nil { omissions += 1 }
        }
    }
}
