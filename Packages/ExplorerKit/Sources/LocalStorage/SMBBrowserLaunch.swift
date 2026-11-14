import Darwin
import Foundation

extension SMBBrowserOwner {
    func launch() throws {
        #if DEBUG
        SFTPGeneratedBackendObservation.shared.workerLaunchAttempt()
        #endif
        guard admissionIsOpen() else { throw SMBBrowserFailure.stopped }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if runtimeStorage == nil { guard [".build/b10-browser-qualification", ".build/b10-helper-identity"].contains(where: { root.deletingLastPathComponent() == repo.appendingPathComponent($0) }),
              root.resolvingSymlinksInPath() == root, UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent else {
            throw SMBBrowserFailure.invalidInput
        } }
        if let prepared, let request { try prepared.validate(for: request) }
        let identity = try prepared?.helperIdentity ?? SMBBundledHelperIdentity.prepare(.browser, bundle: bundle)
        try identity.validateInstallation()
        let helper = identity.helper
        guard admissionIsOpen(), let credentialInput else { throw SMBBrowserFailure.unavailable }
        let catalog: URL
        if let storage = runtimeStorage {
            do {
                let files = try SMBCatalogFiles(storage: storage, id: id); runtimeFiles = files
                directory = files.directory; database = files.database; leaseFD = files.lease; catalog = files.path
            } catch SMBTemporaryStorageFailure.capacity { throw SMBBrowserFailure.quota }
            catch SMBTemporaryStorageFailure.busy { throw SMBBrowserFailure.busy }
            catch { throw SMBBrowserFailure.storage }
        } else {
            let folder = root.appendingPathComponent("stores/\(id.uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            directory = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard directory >= 0 else { throw SMBBrowserFailure.storage }
            database = openat(directory, "catalog.sqlite", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            leaseFD = openat(directory, "owner.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard database >= 0, leaseFD >= 0, flock(leaseFD, LOCK_EX | LOCK_NB) == 0 else { throw SMBBrowserFailure.storage }
            catalog = folder.appendingPathComponent("catalog.sqlite")
        }
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw SMBBrowserFailure.unavailable }
        defer { for fd in pair where fd >= 0 { Darwin.close(fd) } }
        var copies: [Int32] = []
        defer { copies.forEach { Darwin.close($0) } }
        for fd in [pair[1], directory, database, leaseFD] {
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 32); guard copy >= 0 else { throw SMBBrowserFailure.unavailable }; copies.append(copy)
        }
        for fd in pair {
            var one: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else { throw SMBBrowserFailure.unavailable }
        }
        guard fcntl(pair[0], F_SETFL, O_NONBLOCK) == 0 else { throw SMBBrowserFailure.unavailable }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw SMBBrowserFailure.unavailable }; defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw SMBBrowserFailure.unavailable }; defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t(), defaults = sigset_t()
        guard sigemptyset(&mask) == 0, sigemptyset(&defaults) == 0, sigaddset(&defaults, SIGTERM) == 0, sigaddset(&defaults, SIGINT) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0, posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0 else { throw SMBBrowserFailure.unavailable }
        for (index, target) in [Int32(3), 4, 5, 6].enumerated() {
            guard posix_spawn_file_actions_adddup2(&actions, copies[index], target) == 0 else { throw SMBBrowserFailure.unavailable }
        }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0) == 0 else { throw SMBBrowserFailure.unavailable }
        }
        var argv = [strdup(helper.path), strdup(mode.argument), nil], env = [strdup("LANG=C"), strdup("LC_ALL=C"), nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        guard !argv.dropLast().contains(where: { $0 == nil }), !env.dropLast().contains(where: { $0 == nil }) else { throw SMBBrowserFailure.unavailable }
        let result = posix_spawn(&child, helper.path, &actions, &attributes, &argv, &env)
        guard result == 0 else { child = 0; throw SMBBrowserFailure.unavailable }
        installChannel(pair[0]); pair[0] = -1
        try identity.validateChild(child)
        guard admissionIsOpen() else { throw SMBBrowserFailure.stopped }
        let encoded = Data(catalog.path.utf8).map { String(format: "%02x", $0) }.joined()
        let share = share.displayName.utf16.map { String(format: "%04x", $0) }.joined()
        // Frozen qualification destination and account. No ordinary endpoint,
        // remembered credential or resolver result is admitted by this API.
        if let prepared, let storage = runtimeStorage {
            let command = prepared.command(session: id, catalog: catalog, quota: storage.sessionByteLimit, policy: policy)
            guard command.hasPrefix("MEXSMBB2 START ") else { throw SMBBrowserFailure.invalidInput }
            try write(mode == .metadata ? command : mode.magic + command.dropFirst(8))
        } else { try write("MEXSMBB2 START \(id.uuidString) \(policy.rawValue) 127.0.0.1 15445 0 3132372e302e302e31 \(share) \(encoded) 33554432\n") }
        try write(credentialInput); self.credentialInput = nil; markHelloSent()
    }
}
