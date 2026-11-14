#if DEBUG
import Darwin
import Foundation

extension RecoverableFileOperations {
    /// DEBUG-only original marked 1,024 x 256-byte performance fixture. The
    /// inherited exact case-marker lease is duplicated and retained by engine
    /// worker lifetime. No hooks, group-size override, or owner opt-in escapes.
    public static func generatedCopyResponsivenessVerificationSession(in fixtureRoot: URL,
        inheritingFixtureLeaseDescriptor descriptor: Int32) async throws -> RecoverableFileOperations {
        let journal = fixtureRoot.appendingPathComponent("journal", isDirectory: true)
        let validator = RecoverableFileOperations(journalDirectory: journal)
        return try await validator.worker { cancellation in
            let capability = try GeneratedCopyResponsivenessCapability.admit(fixtureRoot,
                inheritedDescriptor: descriptor, cancellation: cancellation)
            var hooks = RecoveryHooks()
            hooks.groupedCopy.qualification = capability.qualification
            let engine = RecoverableFileOperations(journalDirectory: journal, hooks: hooks,
                                                  copyExecutionAuthorization: .generatedFixture)
            try engine.installGeneratedResponsivenessCapability(capability)
            try cancellation.check()
            return engine
        }
    }
}

/// Cooperative qualification authority for exactly one fresh full Copy. All
/// filesystem work occurs inside existing bounded serial operation workers.
internal final class GeneratedCopyResponsivenessCapability: @unchecked Sendable {
    private struct Manifest: Codable {
        let workload: String
        let sizes: [Int]
        let source: VerifiedTree
    }
    private struct Pin: Sendable { let url: URL; let identity: EntrySnapshot; let privateMode: Bool }
    private struct Marker: Sendable {
        let parent: URL
        let name: String
        let bytes: Data
        let identity: EntrySnapshot
    }
    private static let ownerName = ".owned-grouped-production-fixture"
    private static let rootChildren: Set<String> = [ownerName, GroupedCopyQualification.markerName,
        "performance.json", "source", "destination", "history"]
    private let descriptor: Int32
    private let directories: [Pin]
    private let markers: [Marker]
    private let sourceEntries: [EntrySnapshot]
    private let source: URL
    private let destination: URL
    private let history: URL
    internal let journal: URL
    internal let qualification: GroupedCopyQualification

    private init(descriptor: Int32, directories: [Pin], markers: [Marker], sourceEntries: [EntrySnapshot],
                 source: URL, destination: URL, history: URL, journal: URL, qualification: GroupedCopyQualification) {
        self.descriptor = descriptor; self.directories = directories; self.markers = markers
        self.sourceEntries = sourceEntries; self.source = source; self.destination = destination
        self.history = history; self.journal = journal; self.qualification = qualification
    }
    deinit { close(descriptor) } // Close only; LOCK_UN would unlock parent/child duplicates too.

    private static var repository: URL {
        var value = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { value.deleteLastPathComponent() }
        return value
    }
    private static func canonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
    private static func directory(_ url: URL, privateMode: Bool = true) throws -> DirectoryAnchor {
        guard url.isFileURL, url.path == url.standardizedFileURL.path else { throw FileOperationFailure.invalidRequest }
        let anchor = try DirectoryAnchor(url, resolve: false)
        var info = stat()
        guard fstat(anchor.fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & (privateMode ? 0o7777 : 0o022) == (privateMode ? 0o700 : 0) else {
            throw FileOperationFailure.invalidRequest
        }
        return anchor
    }
    private static func checkedFile(_ fd: Int32, maximum: Int) throws -> EntrySnapshot {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o7777 == 0o600, info.st_nlink == 1, info.st_size >= 0,
              info.st_size <= maximum else { throw FileOperationFailure.invalidRequest }
        return try EntrySnapshot(fd: fd)
    }
    private static func read(_ name: String, in parent: DirectoryAnchor, maximum: Int,
                             cancellation: OperationCancellation) throws -> (Data, EntrySnapshot) {
        try cancellation.check()
        let fd = openat(parent.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FileOperationFailure.invalidRequest }; defer { close(fd) }
        let before = try checkedFile(fd, maximum: maximum)
        var data = Data(), buffer = [UInt8](repeating: 0, count: min(maximum + 1, 4096))
        while true {
            try cancellation.check()
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0, data.count + count <= maximum else { throw FileOperationFailure.invalidRequest }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard before == (try checkedFile(fd, maximum: maximum)),
              before == (try EntrySnapshot(parent: parent.fd, name: name)) else { throw FileOperationFailure.sourceChanged }
        try parent.validate(); try cancellation.check()
        return (data, before)
    }
    private static func exactChildren(_ anchor: DirectoryAnchor, _ expected: Set<String>,
                                      cancellation: OperationCancellation) throws {
        let actual = try GroupedCopyFilesystemEvidence.children(in: anchor, cancellation: cancellation, limit: expected.count)
        guard actual.count == expected.count, Set(actual) == expected else { throw FileOperationFailure.invalidRequest }
    }
    private static func validateLease(_ fd: Int32, root: DirectoryAnchor, expected: EntrySnapshot) throws {
        guard try checkedFile(fd, maximum: 256) == expected,
              try EntrySnapshot(parent: root.fd, name: ownerName) == expected else { throw FileOperationFailure.invalidRequest }
        let probe = openat(root.fd, ownerName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard probe >= 0 else { throw FileOperationFailure.invalidRequest }; defer { close(probe) }
        guard try checkedFile(probe, maximum: 256) == expected else { throw FileOperationFailure.invalidRequest }
        // Probe first: a successful independent lock means no inherited lease.
        // Never silently acquire authority by flocking the supplied FD first.
        let result = flock(probe, LOCK_EX | LOCK_NB), code = errno
        guard result != 0, code == EWOULDBLOCK else { throw FileOperationFailure.invalidRequest }
        // Then prove our duplicate shares the locked open-file description;
        // a different same-inode open would still fail nonblocking flock here.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw FileOperationFailure.invalidRequest
        }
    }

    internal static func admit(_ root: URL, inheritedDescriptor: Int32,
                               cancellation: OperationCancellation) throws -> GeneratedCopyResponsivenessCapability {
        try cancellation.check()
        // Exact trusted compile-checkout layout, never an environment override
        // or a caller's arbitrary .build path. The parent owns build provenance;
        // this is not a defense against someone compiling cloned/modified code.
        guard URL(fileURLWithPath: #filePath).path == repository.appendingPathComponent(
            "Packages/ExplorerKit/Sources/FileOperations/GeneratedCopyResponsivenessVerification.swift").path else {
            throw FileOperationFailure.invalidRequest
        }
        let repositoryAnchor = try directory(repository, privateMode: false)
        let buildAnchor = try directory(repository.appendingPathComponent(".build", isDirectory: true), privateMode: false)
        let base = repository.appendingPathComponent(".build/grouped-copy-production", isDirectory: true)
        let baseAnchor = try directory(base)
        let fixtures = root.deletingLastPathComponent(), run = fixtures.deletingLastPathComponent()
        guard root.path == root.standardizedFileURL.path, run.deletingLastPathComponent().path == base.path,
              canonicalUUID(run.lastPathComponent), fixtures.lastPathComponent == "fixtures",
              root.lastPathComponent.hasPrefix("copy-"), canonicalUUID(String(root.lastPathComponent.dropFirst(5))) else {
            throw FileOperationFailure.invalidRequest
        }
        let runAnchor = try directory(run), fixturesAnchor = try directory(fixtures), rootAnchor = try directory(root)
        let fd = fcntl(inheritedDescriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw FileOperationFailure.invalidRequest }
        var installed = false
        defer { if !installed { close(fd) } }
        let expectedMarkers: [(DirectoryAnchor, String, Data?)] = [
            (runAnchor, ".qualification-owner", Data("MacExplorer grouped production qualification v1\n\(run.lastPathComponent)\n".utf8)),
            (rootAnchor, ownerName, Data("MacExplorer generated grouped production fixture v1\n\(root.lastPathComponent)\n".utf8)),
            (rootAnchor, GroupedCopyQualification.markerName, GroupedCopyQualification.marker),
            (rootAnchor, "performance.json", nil)]
        var markers: [Marker] = []
        for (parent, name, expected) in expectedMarkers {
            let (bytes, identity) = try read(name, in: parent, maximum: name == "performance.json" ? 32_768 : 256, cancellation: cancellation)
            guard expected == nil || bytes == expected else { throw FileOperationFailure.invalidRequest }
            markers.append(Marker(parent: parent.url, name: name, bytes: bytes, identity: identity))
        }
        try validateLease(fd, root: rootAnchor, expected: markers[1].identity)
        try exactChildren(rootAnchor, rootChildren, cancellation: cancellation)
        let source = try directory(root.appendingPathComponent("source", isDirectory: true))
        let destination = try directory(root.appendingPathComponent("destination", isDirectory: true))
        let history = try directory(root.appendingPathComponent("history", isDirectory: true))
        try exactChildren(destination, [], cancellation: cancellation)
        try exactChildren(history, [], cancellation: cancellation)
        let bytes = markers[3].bytes
        let seed = try JSONDecoder().decode(Manifest.self, from: bytes)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(seed) == bytes, seed.workload == "1024x256B", seed.sizes.count == 1024,
              seed.sizes.allSatisfy({ $0 == 256 }) else { throw FileOperationFailure.invalidRequest }
        let names = (0..<1024).map { "generated-\($0).dat" }
        try exactChildren(source, Set(names), cancellation: cancellation)
        var sourceEntries: [EntrySnapshot] = []
        for name in names {
            try cancellation.check()
            let payload = openat(source.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard payload >= 0 else { throw FileOperationFailure.invalidRequest }
            do {
                let identity = try checkedFile(payload, maximum: 256)
                guard identity.size == 256, identity == (try EntrySnapshot(parent: source.fd, name: name)) else {
                    throw FileOperationFailure.invalidRequest
                }
                sourceEntries.append(identity); close(payload)
            } catch { close(payload); throw error }
        }
        let budget = TraversalBudget(maximumObservedNodes: 1025, maximumObservedLogicalBytes: 262_144)
        guard seed.source.matches(try verifiedTree(source.url, cancellation: cancellation, budget: budget)),
              budget.nodes == 1025, budget.bytes == 262_144 else {
            throw FileOperationFailure.sourceChanged
        }
        let qualification = try GroupedCopyQualification(root: root)
        let capability = GeneratedCopyResponsivenessCapability(descriptor: fd,
            directories: [repositoryAnchor, buildAnchor].map { Pin(url: $0.url, identity: $0.identity, privateMode: false) }
                + [baseAnchor, runAnchor, fixturesAnchor, rootAnchor, source, destination, history].map { Pin(url: $0.url, identity: $0.identity, privateMode: true) },
            markers: markers, sourceEntries: sourceEntries, source: source.url, destination: destination.url,
            history: history.url, journal: root.appendingPathComponent("journal", isDirectory: true), qualification: qualification)
        // Transfer ownership before revalidation so a thrown check closes exactly once.
        installed = true
        try capability.validateCopy(sources: names.map { source.url.appendingPathComponent($0) }, destination: destination.url,
                                    move: false, metadataPolicy: .strict, cancellation: cancellation)
        return capability
    }

    internal func validateCopy(sources: [URL], destination: URL, move: Bool,
                               metadataPolicy: TransferMetadataPolicy, cancellation: OperationCancellation) throws {
        try cancellation.check()
        guard !move, metadataPolicy == .strict, destination == self.destination, sources.count == 1024,
              Set(sources) == Set((0..<1024).map { source.appendingPathComponent("generated-\($0).dat") }) else {
            throw FileOperationFailure.invalidRequest
        }
        for pin in directories {
            try cancellation.check()
            guard try Self.directory(pin.url, privateMode: pin.privateMode).identity.sameObject(as: pin.identity) else { throw FileOperationFailure.sourceChanged }
        }
        let root = try Self.directory(qualification.root)
        try Self.validateLease(descriptor, root: root, expected: markers[1].identity)
        try Self.exactChildren(root, Self.rootChildren, cancellation: cancellation) // Journal remains absent before the one Copy.
        for marker in markers {
            let parent = try Self.directory(marker.parent)
            let (bytes, identity) = try Self.read(marker.name, in: parent,
                maximum: marker.name == "performance.json" ? 32_768 : 256, cancellation: cancellation)
            guard identity == marker.identity, bytes == marker.bytes else { throw FileOperationFailure.sourceChanged }
        }
        let sourceAnchor = try Self.directory(source)
        try Self.exactChildren(sourceAnchor, Set((0..<1024).map { "generated-\($0).dat" }), cancellation: cancellation)
        for ordinal in 0..<1024 {
            try cancellation.check()
            let fd = openat(sourceAnchor.fd, "generated-\(ordinal).dat", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw FileOperationFailure.sourceChanged }
            do {
                guard try Self.checkedFile(fd, maximum: 256) == sourceEntries[ordinal],
                      try EntrySnapshot(parent: sourceAnchor.fd, name: "generated-\(ordinal).dat") == sourceEntries[ordinal] else {
                    throw FileOperationFailure.sourceChanged
                }
                close(fd)
            } catch { close(fd); throw error }
        }
        try Self.exactChildren(Self.directory(destination), [], cancellation: cancellation)
        try Self.exactChildren(Self.directory(history), [], cancellation: cancellation)
        try Self.validateLease(descriptor, root: root, expected: markers[1].identity)
        for pin in directories {
            try cancellation.check()
            guard try Self.directory(pin.url, privateMode: pin.privateMode).identity.sameObject(as: pin.identity) else { throw FileOperationFailure.sourceChanged }
        }
    }
}
#endif
