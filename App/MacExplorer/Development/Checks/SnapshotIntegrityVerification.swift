#if DEBUG
import Darwin
import Foundation

/// Standalone native storage checks. Only generated files below the explicit
/// ignored fixture root are read or changed; fixture artifacts remain inspectable.
enum SnapshotIntegrityVerification {
    struct Failure: Error { let message: String }

    static func run(in testRoot: URL) async throws -> [String] {
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              testRoot.standardizedFileURL == URL(fileURLWithPath: declared, isDirectory: true).standardizedFileURL,
              testRoot.standardizedFileURL == testRoot.resolvingSymlinksInPath().standardizedFileURL,
              testRoot.pathComponents.contains(".build") else {
            throw Failure(message: "Snapshot verification requires its explicit ignored fixture root.")
        }
        return try await Task.detached { try verify(in: testRoot) }.value
    }

    private static func verify(in root: URL) throws -> [String] {
        let fm = FileManager()
        let owned = root.appendingPathComponent("snapshot-integrity-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: owned, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("mac-explorer-snapshot-integrity-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
        let old = Data("owned-version-1".utf8), new = Data("owned-version-1-updated".utf8), other = Data("newer-or-foreign-version".utf8)
        func validate(_ data: Data) throws {
            guard data == old || data == new else { throw Failure(message: "Unrecognized snapshot") }
        }
        func fixture(_ label: String) throws -> (BrowserSnapshotFile, URL, URL) {
            let directory = owned.appendingPathComponent(label, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            let file = directory.appendingPathComponent("snapshot.json")
            return (BrowserSnapshotFile(directory: directory, name: "snapshot.json", maximumBytes: 1024), directory, file)
        }
        func require(_ result: Bool, _ message: String) throws { if !result { throw Failure(message: message) } }
        func refuses(_ operation: () throws -> Void, _ message: String) throws {
            var rejected = false
            do { try operation() } catch { rejected = true }
            try require(rejected, message)
        }
        var checks: [String] = []
        do {
            let (store, directory, file) = try fixture("normal")
            try require(try store.read() == nil, "Missing snapshot was not absent")
            try store.write(old, validating: validate)
            try store.write(new, validating: validate)
            try require(try store.read() == new, "Snapshot replacement did not persist")
            let mode = try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            try require(mode?.intValue == 0o600, "Snapshot file permissions were not private")
            try store.forget(validating: validate)
            try require(try store.read() == nil, "Snapshot forget did not remove document")
            try require(try fm.contentsOfDirectory(atPath: directory.path).isEmpty, "Temporary snapshot leaked")
            checks.append("Snapshot normal save, replacement, read, private permissions and forget")
        }
        do {
            let (store, _, file) = try fixture("foreign")
            try other.write(to: file, options: .withoutOverwriting)
            try refuses({ try store.write(new, validating: validate) }, "Foreign snapshot was overwritten")
            try refuses({ try store.forget(validating: validate) }, "Foreign snapshot was forgotten")
            try require(try Data(contentsOf: file) == other, "Foreign snapshot changed")
            checks.append("Invalid or newer snapshot bytes remain intact on save and forget")
        }
        do {
            let (store, directory, file) = try fixture("symlink")
            let sentinel = owned.appendingPathComponent("symlink-sentinel")
            try other.write(to: sentinel, options: .withoutOverwriting)
            try fm.createSymbolicLink(at: file, withDestinationURL: sentinel)
            try refuses({ _ = try store.read() }, "Final symlink was read")
            try refuses({ try store.write(new, validating: validate) }, "Final symlink was overwritten")
            try refuses({ try store.forget(validating: validate) }, "Final symlink was removed")
            let alias = owned.appendingPathComponent("directory-symlink")
            try fm.createSymbolicLink(at: alias, withDestinationURL: directory)
            let redirected = BrowserSnapshotFile(directory: alias, name: "snapshot.json", maximumBytes: 1024)
            try refuses({ try redirected.write(new, validating: validate) }, "Ancestor symlink was followed")
            try require(try Data(contentsOf: sentinel) == other, "Symlink sentinel changed")
            checks.append("Ancestor and final symlinks are refused without changing their targets")
        }
        do {
            let (store, _, file) = try fixture("fifo")
            try require(mkfifo(file.path, 0o600) == 0, "FIFO fixture failed")
            try refuses({ _ = try store.read() }, "FIFO was accepted")
            try refuses({ try store.write(new, validating: validate) }, "FIFO was overwritten")
            try refuses({ try store.forget(validating: validate) }, "FIFO was removed")
            var metadata = stat()
            try require(lstat(file.path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFIFO, "FIFO fixture changed")
            checks.append("FIFO snapshot is refused without blocking or replacement")
        }
        for forgetting in [false, true] {
            let (store, _, file) = try fixture(forgetting ? "forget-replacement" : "write-replacement")
            try old.write(to: file, options: .withoutOverwriting)
            var visits = 0
            let mutate: (Data) throws -> Void = { data in
                try validate(data)
                if data == old {
                    visits += 1
                    if visits == (forgetting ? 1 : 2) {
                        try fm.removeItem(at: file)
                        try other.write(to: file, options: .withoutOverwriting)
                    }
                }
            }
            try refuses({
                if forgetting { try store.forget(validating: mutate) }
                else { try store.write(new, validating: mutate) }
            }, "Replacement target was mutated")
            try require(try Data(contentsOf: file) == other, "Replacement target bytes changed")
            checks.append("\(forgetting ? "Forget" : "Save") rejects target replacement during validation")
        }
        for forgetting in [false, true] {
            let (store, directory, file) = try fixture(forgetting ? "forget-parent" : "write-parent")
            try old.write(to: file, options: .withoutOverwriting)
            let retired = owned.appendingPathComponent("retired-\(UUID().uuidString)", isDirectory: true)
            var visits = 0
            let mutate: (Data) throws -> Void = { data in
                try validate(data)
                if data == old {
                    visits += 1
                    if visits == (forgetting ? 1 : 2) {
                        try fm.moveItem(at: directory, to: retired)
                        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
                        try other.write(to: file, options: .withoutOverwriting)
                    }
                }
            }
            try refuses({
                if forgetting { try store.forget(validating: mutate) }
                else { try store.write(new, validating: mutate) }
            }, "Replaced parent was accepted")
            try require(try Data(contentsOf: file) == other, "Replacement parent data changed")
            try require(try Data(contentsOf: retired.appendingPathComponent("snapshot.json")) == old, "Detached original snapshot changed")
            try require(try fm.contentsOfDirectory(atPath: retired.path) == ["snapshot.json"], "Temporary cleanup missed original parent")
            checks.append("\(forgetting ? "Forget" : "Save") rejects parent replacement and cleans only its opened directory")
        }
        return checks
    }
}
#endif
