import Darwin
import ExplorerCore
import Foundation

public struct TextComparisonDocuments: Sendable {
    public let left: TextDocumentValue
    public let right: TextDocumentValue

    public init(left: TextDocumentValue, right: TextDocumentValue) {
        self.left = left
        self.right = right
    }
}

public enum TextComparisonReadFailure: Error, Equatable, Sendable {
    case leftUnavailable, rightUnavailable, leftUnsupportedText, rightUnsupportedText, changed

    public var userMessage: String {
        switch self {
        case .leftUnavailable: "The left file could not be read."
        case .rightUnavailable: "The right file could not be read."
        case .leftUnsupportedText: "The left file is outside Traverse’s supported UTF-8 text limits."
        case .rightUnsupportedText: "The right file is outside Traverse’s supported UTF-8 text limits."
        case .changed: "A file changed during the comparison. Refresh to read the current files."
        }
    }
}

/// Both comparison types share a small read budget. A plain pair
/// charges both endpoints. A Git blob identity needs only the on-disk side.
package struct FileContentsReviewBudget {
    package enum Admission: Equatable { case accepted(Int), fileTooLarge, exhaustedBytes, exhaustedPairs }
    private var pairs = 0
    private var remainingBytes = 4 << 20

    package init() {}

    package mutating func admit(size: Int64, copies: Int) -> Admission {
        guard pairs < 64 else { return .exhaustedPairs }
        pairs += 1
        guard size >= 0, size <= 1 << 20 else { return .fileTooLarge }
        let bytes = Int(size)
        guard (1...2).contains(copies), bytes * copies <= remainingBytes else { return .exhaustedBytes }
        remainingBytes -= bytes * copies
        return .accepted(bytes)
    }
}

/// Explicit local review only. Unlike an editor Save token, this does not need
/// persistent volume identity or metadata authority for replacement.
package enum LocalTextComparisonRead {
    /// Call within a non-materializing synchronous worker. Exact path and
    /// descriptor identity matter even when the caller only needs a hash.
    package static func fileBytes(at url: URL, within root: DirectoryAnchor? = nil, maximumBytes: Int,
                                  expecting observation: EntrySnapshot? = nil,
                                  checkCancellation: () throws -> Void) throws -> Data {
        try checkCancellation()
        let file = try Pin(url, within: root)
        if let observation, file.observation != observation { throw TextComparisonReadFailure.changed }
        let bytes = try boundedRegularFileBytes(file.fd, maximumBytes: maximumBytes, checkCancellation: checkCancellation)
        try file.validate()
        try root?.validate()
        try checkCancellation()
        return bytes
    }

    package static func read(left: URL, right: URL, checkCancellation: () throws -> Void) throws -> TextComparisonDocuments {
        try withoutMaterialization {
            let first = try open(left, failure: .leftUnavailable, checkCancellation: checkCancellation)
            let second = try open(right, failure: .rightUnavailable, checkCancellation: checkCancellation)
            let before = try read(first, failure: .leftUnsupportedText, checkCancellation: checkCancellation)
            let after = try read(second, failure: .rightUnsupportedText, checkCancellation: checkCancellation)
            try checkCancellation()
            try first.validate()
            try second.validate()
            return .init(left: before, right: after)
        }
    }

    package static func read(_ selection: FolderComparisonReport.TextSelection,
                             checkCancellation: () throws -> Void) throws -> TextComparisonDocuments {
        try withoutMaterialization {
            try checkCancellation()
            let first = try selectedEndpoint(selection.leftRoot, path: selection.relativePath, expecting: selection.left)
            let second = try selectedEndpoint(selection.rightRoot, path: selection.relativePath, expecting: selection.right)
            let before = try first.file.map { try read($0, failure: .leftUnsupportedText, checkCancellation: checkCancellation) }
            let after = try second.file.map { try read($0, failure: .rightUnsupportedText, checkCancellation: checkCancellation) }
            try checkCancellation()
            try first.validate()
            try second.validate()
            let empty = try TextDocumentValue.original(Data())
            return .init(left: before ?? empty, right: after ?? empty)
        }
    }

    package static func editorSelection(_ selection: FolderComparisonReport.EditorSelection,
                                        checkCancellation: () throws -> Void) throws -> LocalTextOpenSelection {
        try withoutMaterialization {
            try checkCancellation()
            let endpoint = try selectedEndpoint(selection.root, path: selection.relativePath, expecting: selection.observation)
            try endpoint.validate()
            try checkCancellation()
            return .init(url: selection.url, parent: endpoint.parent.identity, file: selection.observation)
        }
    }

    /// The folder metadata worker already suppresses materialization. Retain
    /// both exact file observations until the raw-byte comparison has settled.
    static func contentsMatch(_ selection: FolderComparisonReport.TextSelection, maximumBytes: Int,
                              checkCancellation: () throws -> Void) throws -> Bool {
        try checkCancellation()
        let left = try selectedEndpoint(selection.leftRoot, path: selection.relativePath, expecting: selection.left)
        let right = try selectedEndpoint(selection.rightRoot, path: selection.relativePath, expecting: selection.right)
        guard let first = left.file, let second = right.file else { throw TextComparisonReadFailure.changed }
        let a = try boundedRegularFileBytes(first.fd, maximumBytes: maximumBytes, checkCancellation: checkCancellation)
        let b = try boundedRegularFileBytes(second.fd, maximumBytes: maximumBytes, checkCancellation: checkCancellation)
        try left.validate()
        try right.validate()
        try checkCancellation()
        return a == b
    }

    private struct ComparedEndpoint {
        let root: DirectoryAnchor
        let parent: DirectoryAnchor
        let name: String
        let file: Pin?

        func validate() throws {
            do {
                try root.validate()
                if let file { try file.validate(); return }
                try parent.validate()
                var item = stat()
                guard fstatat(parent.fd, name, &item, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                    throw TextComparisonReadFailure.changed
                }
            } catch { throw TextComparisonReadFailure.changed }
        }
    }

    private static func selectedEndpoint(_ fact: FolderComparisonReport.ComparedRoot, path: String,
                                         expecting expected: EntrySnapshot?) throws -> ComparedEndpoint {
        do {
            let root = try DirectoryAnchor(fact.url, resolve: false)
            guard root.isOnLocalVolume, root.identity.sameObject(as: fact.observation) else {
                throw TextComparisonReadFailure.changed
            }
            let url = root.url.appendingPathComponent(path)
            if let expected {
                let file = try Pin(url, within: root)
                guard file.observation == expected else { throw TextComparisonReadFailure.changed }
                return .init(root: root, parent: file.parent, name: file.name, file: file)
            }
            let parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
            guard root.contains(parent), !AutomaticMetadataPolicy.excludes(parent.url) else { throw TextComparisonReadFailure.changed }
            try validateName(url.lastPathComponent)
            let endpoint = ComparedEndpoint(root: root, parent: parent, name: url.lastPathComponent, file: nil)
            try endpoint.validate()
            return endpoint
        } catch { throw TextComparisonReadFailure.changed }
    }

    private static func open(_ url: URL, failure: TextComparisonReadFailure,
                             checkCancellation: () throws -> Void) throws -> Pin {
        try checkCancellation()
        do { return try Pin(url) }
        catch TextComparisonReadFailure.changed { throw TextComparisonReadFailure.changed }
        catch { throw failure }
    }

    private static func read(_ pin: Pin, failure: TextComparisonReadFailure,
                             checkCancellation: () throws -> Void) throws -> TextDocumentValue {
        do {
            let bytes = try boundedRegularFileBytes(pin.fd, maximumBytes: TextDocumentValue.maximumBytes,
                                                    checkCancellation: checkCancellation)
            return try TextDocumentValue.original(bytes)
        } catch FileOperationFailure.sourceChanged {
            throw TextComparisonReadFailure.changed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw failure
        }
    }

    private final class Pin {
        let parent: DirectoryAnchor
        let name: String
        let observation: EntrySnapshot
        let fd: Int32

        init(_ url: URL, within root: DirectoryAnchor? = nil) throws {
            guard url.isFileURL, url.path.hasPrefix("/"), url.host == nil || url.host == "" || url.host == "localhost",
                  !AutomaticMetadataPolicy.excludes(url) else { throw FileOperationFailure.unsupported }
            let parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: root == nil)
            let name = url.lastPathComponent
            try validateName(name)
            guard !AutomaticMetadataPolicy.excludes(parent.url), parent.isOnLocalVolume,
                  root?.contains(parent) != false else { throw FileOperationFailure.unsupported }
            var item = stat()
            guard fstatat(parent.fd, name, &item, AT_SYMLINK_NOFOLLOW) == 0, item.st_mode & S_IFMT == S_IFREG,
                  item.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0,
                  root == nil || item.st_dev == parent.device else { throw FileOperationFailure.unsupported }
            let fd = openat(parent.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw posixFailure() }
            do {
                let observation = EntrySnapshot(item)
                guard try EntrySnapshot(fd: fd) == observation else { throw TextComparisonReadFailure.changed }
                self.parent = parent
                self.name = name
                self.observation = observation
                self.fd = fd
            } catch {
                close(fd)
                throw error
            }
        }

        deinit { close(fd) }

        func validate() throws {
            do {
                try parent.validate()
                guard try EntrySnapshot(parent: parent.fd, name: name) == observation,
                      try EntrySnapshot(fd: fd) == observation else { throw TextComparisonReadFailure.changed }
            } catch {
                throw TextComparisonReadFailure.changed
            }
        }
    }
}
