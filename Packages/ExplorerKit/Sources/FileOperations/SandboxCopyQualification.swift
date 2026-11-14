#if DEBUG
    import Darwin
    import Foundation

    /// Exact generated sandbox qualification only. No attribute bodies, names or
    /// paths leave this observer, and it never changes the inspected descriptors.
    public final class GeneratedSandboxCopyProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: (Int32, CopySecurity, CopySecurity)?
        private var observations: [[String: Bool]] = []

        public init() {}
        public func snapshot() -> [[String: Bool]] { lock.withLock { observations } }

        fileprivate func before(source: Int32, destination: Int32) throws {
            let original = try CopySecurity.read(source)
            let created = try CopySecurity.read(destination)
            try lock.withLock {
                guard pending == nil, observations.count < 16 else { throw FileOperationFailure.unsupported }
                pending = (destination, original, created)
            }
        }

        fileprivate func after(source: Int32, destination: Int32) throws {
            let original = try CopySecurity.read(source)
            let copied = try CopySecurity.read(destination)
            try lock.withLock {
                guard let before = pending, before.0 == destination else { throw FileOperationFailure.invalidRequest }
                observations.append([
                    "sourceHadQuarantineBefore": before.1.quarantine != nil,
                    "createdHadQuarantineBefore": before.2.quarantine != nil,
                    "copiedHasQuarantineAfter": copied.quarantine != nil,
                    "createdMarkUnchanged": before.2.quarantine == copied.quarantine,
                    "sourceSecurityUnchanged": before.1 == original,
                ])
                pending = nil
            }
        }
    }

    extension RecoverableFileOperations {
        public static func generatedSandboxCopySession(
            in root: URL, journal: URL, probe: GeneratedSandboxCopyProbe,
            protecting: [URL], activity: @escaping @Sendable () throws -> any Sendable
        ) throws -> RecoverableFileOperations {
            var repo = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { repo.deleteLastPathComponent() }
            let identifier = "local.macexplorer.sandbox.qualification"
            let state = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/" + identifier, isDirectory: true)
            guard
                root.deletingLastPathComponent().path
                    == repo.appendingPathComponent(".build/distribution-qualification").path,
                UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
                journal.deletingLastPathComponent().path == state.path,
                journal.lastPathComponent.hasPrefix("history-quarantine-"),
                UUID(uuidString: String(journal.lastPathComponent.dropFirst("history-quarantine-".count))) != nil,
                !FileManager().fileExists(atPath: journal.path)
            else { throw FileOperationFailure.invalidRequest }
            let anchor = try DirectoryAnchor(root, resolve: false)
            let fd = openat(anchor.fd, "reservation.json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw posixFailure() }
            defer { close(fd) }
            var entry = stat()
            var parent = stat()
            guard fstat(fd, &entry) == 0, fstat(anchor.fd, &parent) == 0,
                entry.st_mode & S_IFMT == S_IFREG, entry.st_nlink == 1,
                entry.st_size > 0, entry.st_size <= 1024, entry.st_uid == geteuid(), parent.st_uid == geteuid(),
                entry.st_mode & 0o022 == 0, parent.st_mode & 0o077 == 0
            else { throw FileOperationFailure.invalidRequest }
            var bytes = [UInt8](repeating: 0, count: Int(entry.st_size))
            let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
            guard count == bytes.count,
                let fields = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                fields["packet"] as? String == "sandbox-foundation-v1"
            else { throw FileOperationFailure.invalidRequest }
            return RecoverableFileOperations(
                journalDirectory: journal,
                hooks: .init(
                    copyFaults: .init(
                        beforeNativeCopy: { try probe.before(source: $0, destination: $1) },
                        afterNativeCopy: { try probe.after(source: $0, destination: $1) })),
                protecting: protecting, activity: activity)
        }
    }
#endif
