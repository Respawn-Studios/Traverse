import Darwin
import FileOperations
import Foundation

/// A private Git directory with read links to checked object names. The live
/// config, alternates and checkout stay outside. Index edits use a copied
/// index and a separate, initially empty object directory.
final class GitReadView {
    let files: GitRepositoryFiles
    let directory: DirectoryAnchor
    private let objectsBefore: EntrySnapshot
    private var projectedDirectories: [String: EntrySnapshot] = [:]
    private let check: () throws -> Void
    private let git = URL(fileURLWithPath: "/usr/bin/git")

    init(location: GitRepositoryLocation, scratch: URL, check: @escaping () throws -> Void) throws {
        self.check = check
        try Self.requireInstalledTools(check: check)
        let files = try GitRepositoryFiles(location: location, check: check)
        self.files = files
        objectsBefore = try EntrySnapshot(fd: files.objects.fd)
        directory = try Self.makePrivateDirectory(in: scratch)
        do {
            try configure()
            try projectObjects(files.objects)
            try files.anchors.validate(check: check)
            try validateObjectLayout()
        } catch {
            Self.retire(directory)
            throw error
        }
    }

    deinit { Self.retire(directory) }

    private static func makePrivateDirectory(in scratch: URL) throws -> DirectoryAnchor {
        guard scratch.isFileURL, scratch.path == scratch.standardizedFileURL.path,
              scratch.path != "/", scratch.resolvingSymlinksInPath().path == scratch.path else {
            throw GitInspectionFailure.unavailable
        }
        if !FileManager().fileExists(atPath: scratch.path) {
            try FileManager().createDirectory(at: scratch, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        }
        let parent = try DirectoryAnchor(scratch, resolve: false)
        var facts = stat()
        guard fstat(parent.fd, &facts) == 0, facts.st_uid == geteuid(),
              facts.st_mode & 0o022 == 0, parent.isOnLocalVolume else { throw GitInspectionFailure.unavailable }
        let name = "git-read-" + UUID().uuidString
        guard mkdirat(parent.fd, name, 0o700) == 0 else { throw GitInspectionFailure.unavailable }
        do {
            return try parent.gitDirectory(name)
        } catch {
            _ = unlinkat(parent.fd, name, AT_REMOVEDIR)
            throw error
        }
    }

    private static func retire(_ view: DirectoryAnchor) {
        guard (try? view.validate()) != nil else { return }
        try? FileManager().removeItem(at: view.url)
    }

    private func configure() throws {
        try createFolder("refs", in: directory)
        try createFolder("objects", in: directory)
        let hasher = files.hashLength == 64 ? "[extensions]\n\tobjectFormat = sha256\n" : ""
        let config = "[core]\n\tbare = true\n\trepositoryFormatVersion = \(files.hashLength == 64 ? 1 : 0)\n" + hasher
        try Data(config.utf8).write(to: directory.url.appendingPathComponent("config"), options: .withoutOverwriting)
        let head = files.head.map { $0.hex + "\n" } ?? "ref: refs/heads/unborn\n"
        try Data(head.utf8).write(to: directory.url.appendingPathComponent("HEAD"), options: .withoutOverwriting)
        if let shallow = files.shallow {
            try shallow.write(to: directory.url.appendingPathComponent("shallow"), options: .withoutOverwriting)
        }
    }

    private func projectObjects(_ source: DirectoryAnchor) throws {
        let destination = try directory.gitDirectory("objects")
        var scanned = 0
        try source.gitNames(check: check) { prefix in
            scanned += 1
            guard scanned <= 32_768 else { throw GitInspectionFailure.repositoryTooLarge }
            if prefix == "pack" {
                let packs = try source.gitDirectory(prefix)
                try createFolder(prefix, in: destination)
                projectedDirectories[prefix] = try linkObjects(in: packs, to: destination.gitDirectory(prefix), scanned: &scanned) {
                    let fields = $0.split(separator: ".", omittingEmptySubsequences: false)
                    guard fields.count == 2, fields[0].hasPrefix("pack-"),
                          fields[0].utf8.count == files.hashLength + 5, ["pack", "idx"].contains(fields[1]) else { return false }
                    return GitObjectID.isHex(fields[0].utf8.dropFirst(5))
                }
            } else if prefix.utf8.count == 2 && GitObjectID.isHex(prefix.utf8) {
                let fanout = try source.gitDirectory(prefix)
                try createFolder(prefix, in: destination)
                projectedDirectories[prefix] = try linkObjects(in: fanout, to: destination.gitDirectory(prefix), scanned: &scanned) {
                    $0.utf8.count == files.hashLength - 2 && GitObjectID.isHex($0.utf8)
                }
            }
        }
    }

    private func linkObjects(in source: DirectoryAnchor, to destination: DirectoryAnchor,
                             scanned: inout Int, includes: (String) -> Bool) throws -> EntrySnapshot {
        let before = try EntrySnapshot(fd: source.fd)
        try source.gitNames(check: check) { name in
            scanned += 1
            guard scanned <= 32_768 else { throw GitInspectionFailure.repositoryTooLarge }
            guard includes(name) else { return }
            guard let item = try source.gitEntry(name), item.st_mode & S_IFMT == S_IFREG,
                  item.st_uid == geteuid(), item.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0 else {
                throw GitInspectionFailure.unsupportedRepository
            }
            let path = source.url.appendingPathComponent(name).path
            guard symlinkat(path, destination.fd, name) == 0 else { throw GitInspectionFailure.unavailable }
        }
        try source.validate()
        guard try EntrySnapshot(fd: source.fd) == before else { throw GitInspectionFailure.changed }
        return before
    }

    func validateObjectLayout() throws {
        try files.objects.validate()
        guard try EntrySnapshot(fd: files.objects.fd) == objectsBefore else { throw GitInspectionFailure.changed }
        // Pack/loose directory entries can change in an ordinary Git repack.
        // A projected view is usable only with the object layout it observed.
        for (name, before) in projectedDirectories {
            try check()
            guard let current = try files.objects.gitEntry(name), EntrySnapshot(current) == before,
                  current.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0 else { throw GitInspectionFailure.changed }
        }
    }

    func createFolder(_ name: String, in parent: DirectoryAnchor) throws {
        try check()
        guard mkdirat(parent.fd, name, 0o700) == 0 else { throw GitInspectionFailure.unavailable }
    }

    func run(_ arguments: [String], maximumBytes: Int = 12 << 20, timeout: TimeInterval = 12,
             rulesTree: DirectoryAnchor? = nil, input: FileHandle = .nullDevice, acceptsNoMatch: Bool = false,
             privateObjects: DirectoryAnchor? = nil) throws -> Data {
        try check()
        try directory.validate()
        try files.anchors.validate(check: check)
        try validateObjectLayout()
        let locationOptions: [String]
        if let rulesTree {
            guard rulesTree.url.deletingLastPathComponent().path == directory.url.path else {
                throw GitInspectionFailure.unavailable
            }
            try rulesTree.validate()
            locationOptions = ["--work-tree=" + rulesTree.url.path, "-c", "core.bare=false", "-c", "core.excludesFile=/dev/null"]
        } else { locationOptions = ["--bare", "--literal-pathspecs"] }
        if let privateObjects {
            guard privateObjects.url.deletingLastPathComponent().path == directory.url.path,
                  privateObjects.url.lastPathComponent != "objects" else { throw GitInspectionFailure.unavailable }
            try privateObjects.validate()
        }
        let data = try Self.readTool(git, directory: rulesTree?.url ?? directory.url,
            arguments: ["--git-dir=" + directory.url.path, "--no-pager", "--no-optional-locks"] + locationOptions + [
                        "-c", "core.hooksPath=/dev/null", "-c", "core.attributesFile=/dev/null",
                        "-c", "core.bigFileThreshold=8m", "-c", "core.deltaBaseCacheLimit=32m",
                        "-c", "gc.auto=0", "-c", "maintenance.auto=false"] + arguments,
            maximumBytes: maximumBytes, timeout: timeout, input: input, acceptsNoMatch: acceptsNoMatch,
            privateObjects: privateObjects?.url, check: check)
        try files.anchors.validate(check: check)
        try validateObjectLayout()
        return data
    }

    private static func requireInstalledTools(check: @escaping () throws -> Void) throws {
        let selected: Data
        do {
            selected = try readTool(URL(fileURLWithPath: "/usr/bin/xcode-select"), directory: nil, arguments: ["-p"],
                                    maximumBytes: 4_096, timeout: 2, check: check)
        } catch is CancellationError { throw CancellationError() }
        catch { throw GitInspectionFailure.toolsUnavailable }
        guard let path = String(data: selected, encoding: .utf8)?.trimmingCharacters(in: .newlines),
              path.hasPrefix("/"), !path.utf8.contains(0), !path.contains(where: \.isNewline),
              FileManager().isExecutableFile(atPath: URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("usr/bin/git").path) else {
            throw GitInspectionFailure.toolsUnavailable
        }
    }

    private static func readTool(_ executable: URL, directory: URL?, arguments: [String],
                                 maximumBytes: Int, timeout: TimeInterval, input: FileHandle = .nullDevice,
                                 acceptsNoMatch: Bool = false, privateObjects: URL? = nil,
                                 check: @escaping () throws -> Void) throws -> Data {
        try check()
        let child = Process()
        let output = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = directory
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1", "GIT_ATTR_NOSYSTEM": "1",
            "GIT_ALLOW_PROTOCOL": "", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"
        ]
        if let privateObjects { environment["GIT_OBJECT_DIRECTORY"] = privateObjects.path }
        child.environment = environment
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        let control = ReadOnlyToolChildControl()
        do { try child.run() }
        catch { throw GitInspectionFailure.toolsUnavailable }
        control.attach(child)
        let reply = NativeToolPipes.collect(child, output: output, outputLimit: maximumBytes,
            query: .init(control: control, timeout: timeout, shouldStop: { (try? check()) == nil }))
        control.detachAfterReap()
        try check()
        if reply.stopped || reply.stdoutTruncated { throw GitInspectionFailure.limitExceeded }
        guard reply.complete, reply.status == 0 || (acceptsNoMatch && reply.status == 1) else {
            throw GitInspectionFailure.revisionUnavailable
        }
        return reply.stdout
    }
}
