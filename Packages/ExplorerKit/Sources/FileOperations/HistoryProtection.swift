import Darwin
import Foundation

/// Serial, invocation-owned protection for the configured live history namespace.
/// Uses directory identities, never a lexical path prefix or link-target traversal.
internal final class HistoryProtection {
    // Absolute pathname ancestry is separate from relative copy-tree depth.
    private static let maximumAncestors = 1024
    private struct Object: Hashable {
        let device: dev_t
        let inode: ino_t
        let type: mode_t
        let birthSeconds: Int
        let birthNanos: Int
        init(_ value: EntrySnapshot) {
            device = value.device; inode = value.inode; type = value.type
            birthSeconds = value.birthSeconds; birthNanos = value.birthNanos
        }
    }
    private let directory: URL
    private let cancellation: OperationCancellation
    private var anchor: DirectoryAnchor
    private var missing: [String]
    private var ancestors: Set<Object> = []
    private var metadata: Set<Object> = []
    private var scannedMetadataLinks = false
    // Only cache a parent at its observed pathname. Moving the same directory
    // elsewhere cannot reuse its earlier relationship to history.
    private var parents: [String: (Object, Bool)] = [:]
    private let companions: [HistoryProtection]

    init(_ directory: URL, cancellation: OperationCancellation, protecting: [URL] = []) throws {
        guard protecting.count <= 16 else { throw FileOperationFailure.invalidRequest }
        companions = try protecting.filter { $0 != directory }.map { try HistoryProtection($0, cancellation: cancellation) }
        self.directory = directory; self.cancellation = cancellation
        var path = directory, tail: [String] = []
        while true {
            try cancellation.check()
            do { anchor = try DirectoryAnchor(path, resolve: false); break }
            catch FileOperationFailure.notFound {
                guard path.path != "/", tail.count < Self.maximumAncestors else { throw FileOperationFailure.unsupported }
                try validateName(path.lastPathComponent)
                tail.insert(path.lastPathComponent, at: 0); path.deleteLastPathComponent()
            }
        }
        missing = tail
        try rebuild()
    }

    /// The ordinary writer may create the previously absent store. Only that
    /// exact opened object can replace this invocation's missing-root observation.
    func historyOpened(_ opened: DirectoryAnchor) throws {
        try anchor.validate()
        guard opened.url == directory else { throw FileOperationFailure.invalidRequest }
        if missing.isEmpty {
            guard opened.identity.sameObject(as: anchor.identity) else { throw FileOperationFailure.destinationChanged }
        }
        anchor = opened; missing = []; parents = [:]
        try rebuild()
    }

    func requireEntry(_ url: URL) throws {
        let parent = try DirectoryAnchor(url.deletingLastPathComponent())
        try requireEntry(parent: parent, name: url.lastPathComponent)
    }
    func requireEntry(parent: DirectoryAnchor, name: String, snapshot: EntrySnapshot? = nil) throws {
        guard try !protectsHere(parent: parent, name: name, snapshot: snapshot) else { throw FileOperationFailure.operationHistoryProtected }
        for companion in companions {
            guard try !companion.protects(parent: parent, name: name, snapshot: snapshot) else { throw FileOperationFailure.protectedLocation }
        }
    }
    func requireDirectory(_ directory: DirectoryAnchor) throws {
        try anchor.validate(); try directory.validate()
        guard try !parentIsInside(directory) else { throw FileOperationFailure.operationHistoryProtected }
        for companion in companions {
            try companion.anchor.validate()
            guard try !companion.parentIsInside(directory) else { throw FileOperationFailure.protectedLocation }
        }
    }
    func protects(parent: DirectoryAnchor, name: String, snapshot supplied: EntrySnapshot? = nil) throws -> Bool {
        for companion in companions {
            if try companion.protects(parent: parent, name: name, snapshot: supplied) { return true }
        }
        return try protectsHere(parent: parent, name: name, snapshot: supplied)
    }
    private func protectsHere(parent: DirectoryAnchor, name: String, snapshot supplied: EntrySnapshot?) throws -> Bool {
        // Mutation callers may be draining a Replace segment after Stop. These
        // bounded checks must not consult the earlier cancellable planning token.
        try validateName(name)
        try anchor.validate(); try parent.validate()
        if try parentIsInside(parent) { return true }
        let snapshot: EntrySnapshot?
        if let supplied { snapshot = supplied }
        else {
            do { snapshot = try EntrySnapshot(parent: parent.fd, name: name) }
            catch FileOperationFailure.notFound { snapshot = nil }
        }
        if let snapshot {
            let object = Object(snapshot)
            if snapshot.isDirectory && ancestors.contains(object) { return true }
            // Also reject an alternate hard link to a history metadata object.
            if metadata.contains(object) { return true }
            if missing.isEmpty && snapshot.type != S_IFDIR {
                var attributes = stat()
                guard fstatat(parent.fd, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
                if attributes.st_nlink > 1 {
                    try scanMetadataLinks()
                    if metadata.contains(object) { return true }
                }
            }
        }
        if let first = missing.first, parent.identity.sameObject(as: anchor.identity) {
            let sensitive = fpathconf(parent.fd, _PC_CASE_SENSITIVE) == 1
            func key(_ value: String) -> String {
                let normalized = value.precomposedStringWithCanonicalMapping
                return sensitive ? normalized : normalized.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            }
            if key(first) == key(name) { return true }
        }
        return false
    }

    private func rebuild() throws {
        ancestors = []; metadata = []; scannedMetadataLinks = false
        var current = openat(anchor.fd, ".", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw posixFailure() }
        defer { close(current) }
        var reachedRoot = false
        for _ in 0...Self.maximumAncestors {
            try cancellation.check()
            let value = try EntrySnapshot(fd: current)
            guard ancestors.insert(Object(value)).inserted else { throw FileOperationFailure.sourceChanged }
            let next = openat(current, "..", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw posixFailure() }
            let parent: EntrySnapshot
            do { parent = try EntrySnapshot(fd: next) } catch { close(next); throw error }
            if parent.sameObject(as: value) { close(next); reachedRoot = true; break }
            close(current); current = next
        }
        guard reachedRoot else { throw FileOperationFailure.unsupported }
        if missing.isEmpty {
            // Ordinary single-link files need no history-directory enumeration.
            // Large preserved legacy archives cannot impose a new ordinary-job
            // admission limit. Only an alternate hard link needs the bounded scan.
            for name in [".mac-explorer-journal-v1", ".mac-explorer-sqlite-v2", ".mac-explorer-sqlite-ready-v2",
                         SQLiteJournalStore.name, SQLiteJournalStore.name + "-journal"] {
                do { metadata.insert(Object(try EntrySnapshot(parent: anchor.fd, name: name))) }
                catch FileOperationFailure.notFound { continue }
            }
        }
        try anchor.validate()
    }

    private func scanMetadataLinks() throws {
        guard !scannedMetadataLinks else { return }
        let fd = openat(anchor.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }
        defer { close(fd) }
        // Use a noncancellable bounded check: this may run inside a draining
        // mutation segment. It reads directory metadata only, never file bodies.
        for name in try childNames(in: fd, cancellation: cancellation.draining(), limit: 16_384) {
            metadata.insert(Object(try EntrySnapshot(parent: anchor.fd, name: name)))
        }
        try anchor.validate(); scannedMetadataLinks = true
    }

    private func parentIsInside(_ parent: DirectoryAnchor) throws -> Bool {
        let object = Object(parent.identity)
        if let (old, inside) = parents[parent.url.path], old == object { return inside }
        var current = openat(parent.fd, ".", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw posixFailure() }
        defer { close(current) }
        for _ in 0...Self.maximumAncestors {
            let value = try EntrySnapshot(fd: current), key = Object(value)
            if ancestors.contains(key) {
                let inside = missing.isEmpty && value.sameObject(as: anchor.identity)
                if parents.count < 16_384 { parents[parent.url.path] = (object, inside) }
                return inside
            }
            let next = openat(current, "..", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw posixFailure() }
            let nextValue: EntrySnapshot
            do { nextValue = try EntrySnapshot(fd: next) } catch { close(next); throw error }
            if nextValue.sameObject(as: value) {
                close(next)
                if parents.count < 16_384 { parents[parent.url.path] = (object, false) }
                return false
            }
            close(current); current = next
        }
        throw FileOperationFailure.unsupported
    }
}
