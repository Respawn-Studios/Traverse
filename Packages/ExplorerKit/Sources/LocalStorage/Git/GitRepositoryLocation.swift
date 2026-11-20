import Darwin
import ExplorerCore
import FileOperations
import Foundation

public enum GitInspectionFailure: Error, Equatable, Sendable {
    case unsupportedRepository
    case toolsUnavailable
    case revisionUnavailable
    case changed
    case limitExceeded
    case repositoryTooLarge
    case invalidOutput
    case unavailable
    case noIndexedVersion
    case lineUnavailable
    case indexConflict
    case noCommonAncestor
    case multipleCommonAncestors
    case worktreeFileUnavailable
    case checkoutHasNoCommit

    public var userMessage: String {
        switch self {
        case .unsupportedRepository: "This Git repository layout is not supported yet."
        case .toolsUnavailable: "Install Apple’s Command Line Tools to compare Git revisions."
        case .revisionUnavailable: "This revision could not be read from the local repository."
        case .changed: "The repository changed during the read. Refresh the Git view to try again."
        case .limitExceeded: "This Git read exceeded its time or size limit. Compare a smaller folder or a newer range."
        case .repositoryTooLarge: "This repository exceeds Traverse’s local Git metadata limit."
        case .invalidOutput: "Git returned data Traverse could not display safely."
        case .unavailable: "The local Git data could not be opened. Check the repository and its folder access."
        case .noIndexedVersion: "There is no version of this path in the Git index yet."
        case .lineUnavailable: "Select a line that exists in this committed file."
        case .indexConflict: "Git has multiple index versions for this path. Choose a committed version while the conflict is unresolved."
        case .noCommonAncestor: "The available local histories share no common ancestor. Compare the selected revisions directly."
        case .multipleCommonAncestors: "These histories have more than one common base. Choose a base commit or compare the selected revisions directly."
        case .worktreeFileUnavailable: "This checkout has no available text file at the same path."
        case .checkoutHasNoCommit: "One of these checkouts has no committed revision yet."
        }
    }
}

/// Metadata from the currently visited directory. A probe never reads refs,
/// configuration or working-file bodies. A linked worktree proves both ends
/// of its administrative link before it can use the shared history.
public struct GitRepositoryLocation: Hashable, Sendable {
    struct Link: Hashable, Sendable {
        let common: URL
        let member: String
        let marker: GitDirectoryIdentity

        var metadata: URL { common.appendingPathComponent("worktrees", isDirectory: true).appendingPathComponent(member, isDirectory: true) }
    }

    public let root: URL
    public let relativeFolder: String
    let rootIdentity: GitDirectoryIdentity
    let metadataIdentity: GitDirectoryIdentity
    let commonIdentity: GitDirectoryIdentity
    let link: Link?

    public var isLinkedWorktree: Bool { link != nil }
    public var readAccessRoots: [URL] { link.map { [root, $0.common] } ?? [root] }

    fileprivate init(anchors: GitRepositoryAnchors, relativeFolder: String) throws {
        root = anchors.root.url
        self.relativeFolder = relativeFolder
        rootIdentity = try GitDirectoryIdentity(anchors.root.fd)
        metadataIdentity = try GitDirectoryIdentity(anchors.metadata.fd)
        commonIdentity = try GitDirectoryIdentity(anchors.common.fd)
        link = anchors.link
    }

    func openAnchors(check: () throws -> Void) throws -> GitRepositoryAnchors {
        try check()
        let root = try DirectoryAnchor(root, resolve: false)
        let common = try link.map {
            try DirectoryAnchor($0.common.deletingLastPathComponent(), resolve: false).gitDirectory(".git")
        } ?? root.gitDirectory(".git")
        let metadata = try link.map { try common.gitDirectory("worktrees").gitDirectory($0.member) } ?? common
        guard try GitDirectoryIdentity(root.fd) == rootIdentity,
              try GitDirectoryIdentity(metadata.fd) == metadataIdentity,
              try GitDirectoryIdentity(common.fd) == commonIdentity, common.isOnLocalVolume,
              metadata.device == root.device, common.device == root.device else {
            throw GitInspectionFailure.changed
        }
        let anchors = GitRepositoryAnchors(root: root, metadata: metadata, common: common, link: link)
        try anchors.validate(check: check)
        return anchors
    }

    public func isSameRepository(as other: Self) -> Bool {
        rootIdentity == other.rootIdentity && metadataIdentity == other.metadataIdentity && commonIdentity == other.commonIdentity
    }

    public func canCompareCheckedOutRevisions(with other: Self) -> Bool {
        commonIdentity == other.commonIdentity && !isSameRepository(as: other)
            && relativeFolder.utf8.elementsEqual(other.relativeFolder.utf8)
    }

    /// Keep user-selected paths inside this repository and preserve their
    /// on-disk spelling for Git's byte-exact path matching.
    public func filePath(for url: URL) -> GitSnapshotPath? {
        guard url.isFileURL, !AutomaticMetadataPolicy.excludes(url) else { return nil }
        let base = root.pathComponents.map { Data($0.utf8) }
        let names = url.standardizedFileURL.pathComponents
        guard names.map({ Data($0.utf8) }).starts(with: base) else { return nil }
        let relative = names.dropFirst(base.count)
        guard !relative.contains(where: { $0.lowercased() == ".git" }) else { return nil }
        return GitSnapshotPath(relative.joined(separator: "/"))
    }

    static func find(at url: URL, within scope: URL? = nil, check: () throws -> Void) throws -> Self? {
        try withoutMaterialization {
            guard !AutomaticMetadataPolicy.excludes(url) else { return nil }
            let current = try DirectoryAnchor(url)
            let original = current.url
            guard !AutomaticMetadataPolicy.excludes(original), current.isOnLocalVolume else { return nil }
            let boundary = try scope.map { try DirectoryAnchor($0).url }
            if let boundary, !original.pathComponents.starts(with: boundary.pathComponents) { return nil }
            let observed = try GitDirectoryIdentity(current.fd)
            var candidate = original
            for _ in 0..<64 {
                try check()
                let parent = try DirectoryAnchor(candidate, resolve: false)
                let sameVolume = try GitDirectoryIdentity(parent.fd)
                guard sameVolume.device == observed.device else { return nil }
                let marker = try statGitEntry(parent.fd, ".git")
                if let marker {
                    // An unadmitted marker still forms a repository boundary.
                    // Never substitute an enclosing project's history.
                    guard marker.st_uid == geteuid(), marker.st_dev == sameVolume.device,
                          marker.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0 else { return nil }
                    let names = original.pathComponents.dropFirst(candidate.pathComponents.count)
                    guard !names.contains(where: { $0.lowercased() == ".git" }) else { return nil }
                    let anchors: GitRepositoryAnchors
                    switch marker.st_mode & S_IFMT {
                    case S_IFDIR:
                        let metadata = try parent.gitDirectory(".git")
                        guard try GitDirectoryIdentity(metadata.fd) == GitDirectoryIdentity(marker) else { return nil }
                        anchors = .init(root: parent, metadata: metadata, common: metadata, link: nil)
                    case S_IFREG:
                        guard let linked = try GitRepositoryAnchors.linked(root: parent, marker: marker,
                            within: boundary, check: check) else { return nil }
                        anchors = linked
                    default: return nil
                    }
                    guard let head = try anchors.metadata.gitEntry("HEAD"), head.st_mode & S_IFMT == S_IFREG,
                          let objects = try anchors.common.gitEntry("objects"), objects.st_mode & S_IFMT == S_IFDIR else { return nil }
                    return try .init(anchors: anchors, relativeFolder: names.joined(separator: "/"))
                }
                if candidate.path == "/" || candidate.path == boundary?.path { return nil }
                candidate = candidate.deletingLastPathComponent()
            }
            return nil
        }
    }
}

/// A label from this checkout's own HEAD, separate from repository identity.
/// It names a branch even before its first commit and does not resolve refs.
public struct GitCheckoutObservation: Sendable {
    public let location: GitRepositoryLocation
    public let head: GitWorktree.Head?
}

struct GitRepositoryAnchors {
    let root: DirectoryAnchor
    let metadata: DirectoryAnchor
    let common: DirectoryAnchor
    let link: GitRepositoryLocation.Link?

    static func linked(root: DirectoryAnchor, marker: stat, within boundary: URL?,
                       check: () throws -> Void) throws -> Self? {
        guard let admin = try pointer(".git", in: root, prefix: "gitdir: ", directory: true, check: check) else { return nil }
        let worktrees = admin.deletingLastPathComponent()
        let commonURL = worktrees.deletingLastPathComponent()
        guard worktrees.lastPathComponent == "worktrees", commonURL.lastPathComponent == ".git",
              !AutomaticMetadataPolicy.excludes(commonURL) else { return nil }
        if let boundary,
           !commonURL.pathComponents.map({ Data($0.utf8) }).starts(with: boundary.pathComponents.map({ Data($0.utf8) })) {
            return nil
        }
        let common = try DirectoryAnchor(commonURL.deletingLastPathComponent(), resolve: false).gitDirectory(".git")
        guard common.device == root.device, common.isOnLocalVolume else { return nil }
        let metadata = try common.gitDirectory("worktrees").gitDirectory(admin.lastPathComponent)
        let link = GitRepositoryLocation.Link(common: commonURL, member: admin.lastPathComponent, marker: .init(marker))
        let value = Self(root: root, metadata: metadata, common: common, link: link)
        do { try value.validate(check: check) }
        catch GitInspectionFailure.changed { return nil }
        return value
    }

    func validate(check: () throws -> Void) throws {
        try check()
        try root.validate()
        try metadata.validate()
        guard let link else { return }
        try common.validate()
        let rootMarker = root.url.appendingPathComponent(".git", isDirectory: false)
        guard let marker = try root.gitEntry(".git"), GitDirectoryIdentity(marker) == link.marker,
              try Self.samePath(Self.pointer(".git", in: root, prefix: "gitdir: ", directory: true, check: check), link.metadata),
              try Self.samePath(Self.pointer("gitdir", in: metadata, directory: false, check: check), rootMarker),
              try Self.samePath(Self.pointer("commondir", in: metadata, directory: true, check: check), common.url) else {
            throw GitInspectionFailure.changed
        }
    }

    private static func samePath(_ observed: URL?, _ expected: URL) -> Bool {
        observed?.path.utf8.elementsEqual(expected.path.utf8) == true
    }

    fileprivate static func pointer(_ name: String, in parent: DirectoryAnchor, prefix: String = "",
                                directory: Bool, check: () throws -> Void) throws -> URL? {
        guard let bytes = try parent.gitReadOptional(name, maximum: 4_096, check: check),
              let raw = String(data: bytes, encoding: .utf8), raw.hasPrefix(prefix) else { return nil }
        let path = raw.dropLast(raw.last?.isNewline == true ? 1 : 0).dropFirst(prefix.count)
        guard !path.isEmpty, !path.contains(where: \.isNewline), !path.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: String(path), isDirectory: directory, relativeTo: parent.url).standardizedFileURL
    }
}

public struct GitWorktree: Identifiable, Sendable {
    public enum Head: Hashable, Sendable {
        case branch(String), detached(GitObjectID)
    }

    public var id: Data { Data(url.path.utf8) }
    public var url: URL { location.root }
    public var isPrimary: Bool { !location.isLinkedWorktree }
    public let isCurrent: Bool
    public let head: Head
    private let location: GitRepositoryLocation

    private init(_ anchors: GitRepositoryAnchors, from origin: GitRepositoryLocation, check: () throws -> Void) throws {
        let location = try GitRepositoryLocation(anchors: anchors, relativeFolder: "")
        self.location = location
        isCurrent = location.isSameRepository(as: origin)
        head = try Self.readHead(anchors.metadata, check: check)
        try anchors.validate(check: check)
    }

    static func readHead(_ metadata: DirectoryAnchor, check: () throws -> Void) throws -> Head {
        guard let bytes = try metadata.gitReadOptional("HEAD", maximum: 1_024, check: check),
              let text = String(data: bytes, encoding: .utf8) else { throw GitInspectionFailure.invalidOutput }
        let value = text.trimmingCharacters(in: .newlines)
        if value.hasPrefix("ref: "), let ref = GitRevisionReference.shortName(String(value.dropFirst(5))), ref.kind == .branch {
            return .branch(ref.name)
        }
        guard let id = GitObjectID(value), !id.isNull else { throw GitInspectionFailure.invalidOutput }
        return .detached(id)
    }

    private static func covers(_ root: URL, within allowedRoots: [URL]?) -> Bool {
        guard !AutomaticMetadataPolicy.excludes(root) else { return false }
        let components = root.pathComponents.map { Data($0.utf8) }
        return allowedRoots?.contains { components.starts(with: $0.pathComponents.map { Data($0.utf8) }) } ?? true
    }

    private static func member(_ metadata: DirectoryAnchor, common: DirectoryAnchor, allowedRoots: [URL]?,
                               check: () throws -> Void) throws -> GitRepositoryAnchors? {
        guard let markerURL = try GitRepositoryAnchors.pointer("gitdir", in: metadata, directory: false, check: check),
              markerURL.lastPathComponent == ".git" else { return nil }
        let url = markerURL.deletingLastPathComponent()
        guard covers(url, within: allowedRoots) else { return nil }
        let root = try DirectoryAnchor(url, resolve: false)
        guard root.device == common.device, root.isOnLocalVolume,
              let marker = try root.gitEntry(".git"), marker.st_mode & S_IFMT == S_IFREG, marker.st_dev == root.device else { return nil }
        let link = GitRepositoryLocation.Link(common: common.url, member: metadata.url.lastPathComponent, marker: .init(marker))
        return .init(root: root, metadata: metadata, common: common, link: link)
    }

    static func list(from origin: GitRepositoryLocation, allowedRoots: [URL]?,
                     check: () throws -> Void) throws -> GitWorktreeListing {
        try withoutMaterialization {
            guard origin.readAccessRoots.allSatisfy({ covers($0, within: allowedRoots) }) else { throw GitInspectionFailure.unavailable }
            let current = try origin.openAnchors(check: check)
            var worktrees = [try Self(current, from: origin, check: check)]
            var incomplete = false
            if origin.isLinkedWorktree {
                let primary = current.common.url.deletingLastPathComponent()
                if covers(primary, within: allowedRoots),
                   let root = try? DirectoryAnchor(primary, resolve: false), root.device == current.common.device,
                   let worktree = try? Self(.init(root: root, metadata: current.common, common: current.common, link: nil),
                                            from: origin, check: check) {
                    worktrees.append(worktree)
                } else { incomplete = true }
            }
            if try current.common.gitEntry("worktrees") != nil {
                let registry = try current.common.gitDirectory("worktrees")
                var remaining = 64
                do {
                    try registry.gitNames(check: check) { name in
                        guard remaining > 0 else { throw GitInspectionFailure.limitExceeded }
                        remaining -= 1
                        if name.utf8.elementsEqual(origin.link?.member.utf8 ?? "".utf8) { return }
                        do {
                            let metadata = try registry.gitDirectory(name)
                            if let candidate = try member(metadata, common: current.common, allowedRoots: allowedRoots, check: check) {
                                worktrees.append(try Self(candidate, from: origin, check: check))
                            } else { incomplete = true }
                        } catch is CancellationError { throw CancellationError() }
                        catch { incomplete = true }
                    }
                } catch GitInspectionFailure.limitExceeded { incomplete = true }
                try registry.validate()
            }
            try current.validate(check: check)
            var roots = Set<Data>()
            let ordered = worktrees.sorted {
                if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
                if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
                return $0.url.path.utf8.lexicographicallyPrecedes($1.url.path.utf8)
            }.filter { roots.insert($0.id).inserted }
            return .init(worktrees: ordered, isIncomplete: incomplete)
        }
    }

    func validate(from origin: GitRepositoryLocation, matching folder: GitSnapshotPath?, allowedRoots: [URL]?,
                  check: () throws -> Void) throws -> URL {
        try withValidatedTarget(from: origin, allowedRoots: allowedRoots, check: check) { target in
            guard let relative = folder?.literalArgument else { return target.root.url }
            let url = target.root.url.appendingPathComponent(relative, isDirectory: true)
            guard location.filePath(for: url) == folder,
                  let match = try? DirectoryAnchor(url, resolve: false), target.root.contains(match),
                  match.isOnLocalVolume else { return target.root.url }
            try check()
            try match.validate()
            return url
        }
    }

    func file(at path: GitSnapshotPath, from origin: GitRepositoryLocation, allowedRoots: [URL]?, readingText: Bool,
              check: () throws -> Void) throws -> GitWorktreeFile {
        try withValidatedTarget(from: origin, allowedRoots: allowedRoots, check: check) { target in
            guard let relative = path.literalArgument else { throw GitInspectionFailure.worktreeFileUnavailable }
            let url = target.root.url.appendingPathComponent(relative, isDirectory: false)
            let name = url.lastPathComponent
            guard location.filePath(for: url) == path,
                  let folder = try? DirectoryAnchor(url.deletingLastPathComponent(), resolve: false),
                  target.root.contains(folder),
                  let facts = try? folder.gitEntry(name), facts.st_mode & S_IFMT == S_IFREG,
                  facts.st_dev == folder.device, facts.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0,
                  facts.st_size >= 0, facts.st_size <= TextDocumentValue.maximumBytes else {
                throw GitInspectionFailure.worktreeFileUnavailable
            }
            let text = try readingText ? TextDocumentValue.original(LocalTextComparisonRead.fileBytes(at: url, within: target.root,
                maximumBytes: TextDocumentValue.maximumBytes, expecting: EntrySnapshot(facts), checkCancellation: check)) : nil
            try folder.validate()
            guard let final = try folder.gitEntry(name), EntrySnapshot(final) == EntrySnapshot(facts) else {
                throw GitInspectionFailure.changed
            }
            return .init(selection: .init(url: url, parent: folder.identity, file: EntrySnapshot(facts)),
                         repository: location, head: head, text: text)
        }
    }

    private func withValidatedTarget<Value>(from origin: GitRepositoryLocation, allowedRoots: [URL]?, check: () throws -> Void,
                                             read: (GitRepositoryAnchors) throws -> Value) throws -> Value {
        try withoutMaterialization {
            guard location.commonIdentity == origin.commonIdentity, !location.isSameRepository(as: origin),
                  origin.readAccessRoots.allSatisfy({ Self.covers($0, within: allowedRoots) }),
                  Self.covers(url, within: allowedRoots) else {
                throw GitInspectionFailure.unavailable
            }
            let current = try origin.openAnchors(check: check)
            let target = try location.openAnchors(check: check)
            let value = try read(target)
            guard try Self.readHead(target.metadata, check: check) == head else { throw GitInspectionFailure.changed }
            try current.validate(check: check)
            try target.validate(check: check)
            return value
        }
    }
}

public struct GitWorktreeFile: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let selection: LocalTextOpenSelection
    public var url: URL { selection.url }
    public let repository: GitRepositoryLocation
    public let head: GitWorktree.Head
    public let text: TextDocumentValue?
    public var description: String { "<Git worktree file>" }
    public var debugDescription: String { description }
}

public struct GitWorktreeListing: Sendable {
    public let worktrees: [GitWorktree]
    public let isIncomplete: Bool
}

struct GitDirectoryIdentity: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t
    let birth: Int
    let birthNanoseconds: Int

    init(_ item: stat) {
        device = item.st_dev
        inode = item.st_ino
        birth = item.st_birthtimespec.tv_sec
        birthNanoseconds = item.st_birthtimespec.tv_nsec
    }

    init(_ fd: Int32) throws {
        var item = stat()
        guard fstat(fd, &item) == 0 else { throw GitInspectionFailure.unavailable }
        self.init(item)
    }
}

func statGitEntry(_ parent: Int32, _ name: String) throws -> stat? {
    var value = stat()
    if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
    guard errno == ENOENT else { throw GitInspectionFailure.unavailable }
    return nil
}
