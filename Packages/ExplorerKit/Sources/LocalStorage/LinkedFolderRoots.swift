import Darwin
import ExplorerCore
import FileOperations
import Foundation

public enum LinkedFolderFailure: Error, Equatable, Sendable {
    case rootsChanged
    case unavailable
}

/// Authority stays with each pane's existing access owner. This observation
/// pins directory identities without retaining handles or reading their files.
public struct LinkedFolderRoots: Sendable {
    private struct Root: Sendable {
        let url: URL
        let identity: EntrySnapshot

        func resolve() throws -> DirectoryAnchor {
            guard let folder = try? Self.open(url), identity.sameObject(as: folder.identity) else {
                throw LinkedFolderFailure.rootsChanged
            }
            return folder
        }

        static func open(_ url: URL) throws -> DirectoryAnchor {
            guard LinkedFolderRoots.permits(url),
                  let folder = try? DirectoryAnchor(url, resolve: false), folder.isOnLocalVolume else {
                throw LinkedFolderFailure.unavailable
            }
            let descriptor = openat(folder.fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw LinkedFolderFailure.unavailable }
            close(descriptor)
            return folder
        }
    }

    private let first: Root
    private let second: Root

    init(_ left: URL, _ right: URL, check: () throws -> Void) throws {
        try check()
        let firstFolder = try Root.open(left), secondFolder = try Root.open(right)
        guard !firstFolder.identity.sameObject(as: secondFolder.identity) else { throw LinkedFolderFailure.unavailable }
        try firstFolder.validate()
        try secondFolder.validate()
        try check()
        first = .init(url: firstFolder.url, identity: firstFolder.identity)
        second = .init(url: secondFolder.url, identity: secondFolder.identity)
    }

    public static func permits(_ url: URL) -> Bool {
        url.isFileURL && !AutomaticMetadataPolicy.excludes(url)
            && !url.pathComponents.contains { $0.caseInsensitiveCompare(".git") == .orderedSame }
    }

    public static func contains(_ visit: URL, under root: URL) -> Bool {
        permits(visit) && visit.pathComponents.starts(with: root.pathComponents) { $0.utf8.elementsEqual($1.utf8) }
    }

    func correspondingFolder(from root: URL, visited: URL, check: () throws -> Void) throws -> URL {
        let origin: Root, peer: Root
        if first.url.path.utf8.elementsEqual(root.path.utf8) { (origin, peer) = (first, second) }
        else if second.url.path.utf8.elementsEqual(root.path.utf8) { (origin, peer) = (second, first) }
        else { throw LinkedFolderFailure.rootsChanged }
        guard Self.contains(visited, under: origin.url) else { throw LinkedFolderFailure.unavailable }
        try check()
        let source = try origin.resolve(), destination = try peer.resolve()
        let components = visited.pathComponents.dropFirst(origin.url.pathComponents.count)
        let requested = components.reduce(destination.url) { $0.appendingPathComponent($1, isDirectory: true) }
        let current = try Root.open(visited), candidate = try Root.open(requested)
        guard source.contains(current), destination.contains(candidate) else { throw LinkedFolderFailure.unavailable }
        try current.validate()
        try candidate.validate()
        do { try source.validate(); try destination.validate() }
        catch { throw LinkedFolderFailure.rootsChanged }
        try check()
        return candidate.url
    }
}
