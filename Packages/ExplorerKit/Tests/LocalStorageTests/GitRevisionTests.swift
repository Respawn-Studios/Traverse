import Darwin
import FileOperations
import Foundation
@testable import LocalStorage
import Testing

@Suite struct GitRevisionTests {
    private struct Fixture {
        let root: URL
        let worktree: URL
        let scratch: URL

        init(objectFormat: String = "sha1") throws {
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let base = package.appendingPathComponent(".build/test-fixtures", isDirectory: true)
            guard base.resolvingSymlinksInPath().path == base.path else { throw GitInspectionFailure.unavailable }
            try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
            root = base.appendingPathComponent("git-revisions-" + UUID().uuidString, isDirectory: true)
            worktree = root.appendingPathComponent("Generated Repository", isDirectory: true)
            scratch = root.appendingPathComponent("Review Scratch", isDirectory: true)
            guard mkdir(root.path, 0o700) == 0 else { throw GitInspectionFailure.unavailable }
            do {
                try FileManager().createDirectory(at: worktree, withIntermediateDirectories: false)
                _ = try git("init", "--template=", "--initial-branch=main", "--object-format=\(objectFormat)")
            } catch {
                try? FileManager().removeItem(at: root)
                throw error
            }
        }

        func git(_ arguments: String..., expectedStatus: Int32 = 0) throws -> Data {
            let child = Process()
            let output = Pipe()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            child.arguments = [
                "-c", "user.name=Generated", "-c", "user.email=fixture@example.invalid",
                "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false", "-c", "gc.auto=0"
            ] + arguments
            child.currentDirectoryURL = worktree
            child.environment = [
                "PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_ALLOW_PROTOCOL": "", "GIT_TERMINAL_PROMPT": "0"
            ]
            child.standardInput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            child.standardOutput = output
            let control = ReadOnlyToolChildControl()
            try child.run()
            control.attach(child)
            let reply = NativeToolPipes.collect(child, output: output, outputLimit: 64 << 10,
                query: .init(control: control, timeout: 10))
            control.detachAfterReap()
            guard reply.status == expectedStatus, !reply.stopped, reply.complete else { throw GitInspectionFailure.unavailable }
            return reply.stdout
        }

        func write(_ path: String, _ bytes: Data) throws {
            let file = worktree.appendingPathComponent(path)
            try FileManager().createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
        }

        func head() throws -> GitObjectID {
            try #require(GitObjectID(String(decoding: git("rev-parse", "HEAD"), as: UTF8.self)
                .trimmingCharacters(in: .newlines)))
        }

        func remove() { try? FileManager().removeItem(at: root) }
    }

    @Test(arguments: ["sha1", "sha256"])
    func guardedIndexEditStagesSavedBytesAndUnstagesOnePath(format: String) async throws {
        let fixture = try Fixture(objectFormat: format)
        defer { fixture.remove() }
        let relative = "Scope [a]/Tracked [1].txt"
        let committed = Data("committed line\n".utf8)
        let saved = Data("saved line\n".utf8)
        try fixture.write(relative, committed)
        try fixture.write("Keep.txt", Data("base\n".utf8))
        try fixture.write("Untouched.txt", Data("original\n".utf8))
        try fixture.write("Removed.txt", Data("restore index only\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Generated starting commit")
        _ = try fixture.git("update-index", "--index-version", format == "sha256" ? "4" : "2")
        let originalHead = try fixture.head()
        try fixture.write("Keep.txt", Data("unrelated staged change\n".utf8))
        _ = try fixture.git("add", "--", "Keep.txt")
        _ = try fixture.git("update-index", "--assume-unchanged", "Keep.txt")
        _ = try fixture.git("update-index", "--skip-worktree", "Untouched.txt")
        try fixture.write(relative, saved)
        let indexURL = fixture.worktree.appendingPathComponent(".git/index")
        let originalIndex = try Data(contentsOf: indexURL)
        let originalConfig = try Data(contentsOf: fixture.worktree.appendingPathComponent(".git/config"))
        let originalEntries = try GitIndexFormat(originalIndex, hashLength: originalHead.hex.count, check: {}).entries
        let storage = LocalFileSystem()
        let located = try await storage.locateGitRepository(at: fixture.worktree)
        let repository = try #require(located)
        let path = try #require(GitSnapshotPath(relative))
        let stage = try await storage.prepareGitIndexEdit(.stageSavedFile, path: path, in: repository, scratch: fixture.scratch)
        #expect(stage.before?.object.matchesBlob(committed) == true && stage.after?.object.matchesBlob(saved) == true)
        #expect(try Data(contentsOf: indexURL) == originalIndex)
        try await storage.applyGitIndexEdit(stage, scratch: fixture.scratch)
        #expect(try fixture.git("show", ":" + relative) == saved)
        let staged = try Data(contentsOf: indexURL)
        let stagedEntries = try GitIndexFormat(staged, hashLength: originalHead.hex.count, check: {}).entries
        for (key, value) in originalEntries where key.path != path { #expect(stagedEntries[key] == value) }
        let same = try await storage.prepareGitIndexEdit(.stageSavedFile, path: path, in: repository, scratch: fixture.scratch)
        #expect(!same.hasChange)
        try await storage.applyGitIndexEdit(same, scratch: fixture.scratch)
        #expect(try Data(contentsOf: indexURL) == staged)
        let unstage = try await storage.prepareGitIndexEdit(.unstage, path: path, in: repository, scratch: fixture.scratch)
        #expect(unstage.before == stage.after && unstage.after == stage.before)
        try await storage.applyGitIndexEdit(unstage, scratch: fixture.scratch)
        #expect(try fixture.git("show", ":" + relative) == committed)
        #expect(try Data(contentsOf: fixture.worktree.appendingPathComponent(relative)) == saved)

        let newName = "New.txt"
        let newPath = try #require(GitSnapshotPath(newName))
        try fixture.write(newName, saved)
        let add = try await storage.prepareGitIndexEdit(.stageSavedFile, path: newPath, in: repository, scratch: fixture.scratch)
        #expect(add.before == nil)
        try await storage.applyGitIndexEdit(add, scratch: fixture.scratch)
        #expect(try fixture.git("show", ":" + newName) == saved)
        let remove = try await storage.prepareGitIndexEdit(.unstage, path: newPath, in: repository, scratch: fixture.scratch)
        #expect(remove.after == nil)
        try await storage.applyGitIndexEdit(remove, scratch: fixture.scratch)
        #expect(try fixture.git("ls-files", "--", newName).isEmpty)
        #expect(try Data(contentsOf: fixture.worktree.appendingPathComponent(newName)) == saved)

        let missingName = "Removed.txt"
        let missingPath = try #require(GitSnapshotPath(missingName))
        let missingURL = fixture.worktree.appendingPathComponent(missingName)
        try FileManager().removeItem(at: missingURL)
        _ = try fixture.git("add", "-u", "--", missingName)
        let restore = try await storage.prepareGitIndexEdit(.unstage, path: missingPath, in: repository, scratch: fixture.scratch)
        #expect(restore.before == nil && restore.after != nil)
        try await storage.applyGitIndexEdit(restore, scratch: fixture.scratch)
        #expect(try fixture.git("show", ":" + missingName) == Data("restore index only\n".utf8))
        #expect(!FileManager().fileExists(atPath: missingURL.path))
        #expect(try fixture.head() == originalHead)
        #expect(try Data(contentsOf: fixture.worktree.appendingPathComponent(".git/config")) == originalConfig)
    }

    @Test func guardedIndexEditRefusesStaleFileIndexHeadAndForeignLock() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let name = "Current.txt"
        try fixture.write(name, Data("starting line\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Generated starting commit")
        try fixture.write(name, Data("saved edit\n".utf8))
        let storage = LocalFileSystem()
        let location = try await storage.locateGitRepository(at: fixture.worktree)
        let repo = try #require(location)
        let path = try #require(GitSnapshotPath(name))
        let index = fixture.worktree.appendingPathComponent(".git/index")
        let lock = fixture.worktree.appendingPathComponent(".git/index.lock")
        let before = try Data(contentsOf: index)
        let plan = try await storage.prepareGitIndexEdit(.stageSavedFile, path: path, in: repo, scratch: fixture.scratch)
        let foreign = Data("another writer’s exact lock\n".utf8)
        try foreign.write(to: lock)
        await #expect(throws: GitIndexEditFailure.indexLocked) { try await storage.applyGitIndexEdit(plan, scratch: fixture.scratch) }
        #expect(try Data(contentsOf: lock) == foreign)
        #expect(try Data(contentsOf: index) == before)
        try FileManager().removeItem(at: lock)

        let view = try GitReadView(location: repo, scratch: fixture.scratch, check: {})
        #expect(throws: CancellationError.self) {
            try view.applyIndexEdit(plan, check: {
                if FileManager().fileExists(atPath: lock.path) { throw CancellationError() }
            })
        }
        #expect(!FileManager().fileExists(atPath: lock.path))
        #expect(try Data(contentsOf: index) == before)
        try fixture.write(".git/HEAD", Data((try fixture.head().hex + "\n").utf8))
        await #expect(throws: GitInspectionFailure.changed) { try await storage.applyGitIndexEdit(plan, scratch: fixture.scratch) }
        try fixture.write(".git/HEAD", Data("ref: refs/heads/main\n".utf8))
        let file = fixture.worktree.appendingPathComponent(name)
        let replacement = fixture.worktree.appendingPathComponent("replacement")
        try Data(contentsOf: file).write(to: replacement)
        _ = try FileManager().replaceItemAt(file, withItemAt: replacement)
        await #expect(throws: GitInspectionFailure.changed) { try await storage.applyGitIndexEdit(plan, scratch: fixture.scratch) }
        let newer = try await storage.prepareGitIndexEdit(.stageSavedFile, path: path, in: repo, scratch: fixture.scratch)
        try before.write(to: replacement)
        _ = try FileManager().replaceItemAt(index, withItemAt: replacement)
        await #expect(throws: GitInspectionFailure.changed) { try await storage.applyGitIndexEdit(newer, scratch: fixture.scratch) }
        #expect(!FileManager().fileExists(atPath: lock.path))
        #expect(try Data(contentsOf: index) == before)
        #expect(try Data(contentsOf: file) == Data("saved edit\n".utf8))
    }

    @Test func guardedIndexEditsOnlyTheSelectedChange() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let name = "Draft.txt"
        let before = Data("start\nfirst old\nbetween\nlast old".utf8)
        let disk = Data("start\nfirst new\nbetween\nlast new\n".utf8)
        let partial = Data("start\nfirst new\nbetween\nlast old".utf8)
        let unrelated = Data("staged separately\n".utf8)
        try fixture.write(name, before)
        try fixture.write("Keep.txt", Data("starting\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Generated baseline")
        try fixture.write("Keep.txt", unrelated)
        _ = try fixture.git("add", "--", "Keep.txt")
        try fixture.write(name, disk)

        let storage = LocalFileSystem()
        let repo = try #require(try await storage.locateGitRepository(at: fixture.worktree))
        let path = try #require(GitSnapshotPath(name))
        let report = try await storage.readGitWorkingFolder(in: repo, at: nil, baseline: .index, showHidden: false, scratch: fixture.scratch)
        let row = try #require(report.stagingSelection(for: path))
        let working = try TextDocumentValue.original(disk)
        let index = try TextDocumentValue.original(before)
        let wide = try GitIndexTextChange(before: index, after: working, beforeLines: 1..<4, afterLines: 1..<5)
        await #expect(throws: GitIndexEditFailure.unsupportedTextChange) {
            _ = try await storage.prepareGitIndexEdit(.stageReviewedChange(row, wide), path: path, in: repo, scratch: fixture.scratch)
        }
        let first = try GitIndexTextChange(before: index, after: working, beforeLines: 1..<2, afterLines: 1..<2)
        let plan = try await storage.prepareGitIndexEdit(.stageReviewedChange(row, first), path: path, in: repo, scratch: fixture.scratch)
        #expect(plan.after?.object.matchesBlob(partial) == true)
        try await storage.applyGitIndexEdit(plan, scratch: fixture.scratch)
        #expect(try fixture.git("show", ":" + name) == partial)
        #expect(try fixture.git("show", ":Keep.txt") == unrelated)
        #expect(try Data(contentsOf: fixture.worktree.appendingPathComponent(name)) == disk)
        await #expect(throws: GitInspectionFailure.changed) { try await storage.applyGitIndexEdit(plan, scratch: fixture.scratch) }

        let refreshed = try await storage.readGitWorkingFolder(in: repo, at: nil, baseline: .index, showHidden: false, scratch: fixture.scratch)
        let current = try #require(refreshed.stagingSelection(for: path))
        let last = try GitIndexTextChange(before: .original(partial), after: working, beforeLines: 3..<4, afterLines: 3..<5)
        let final = try await storage.prepareGitIndexEdit(.stageReviewedChange(current, last), path: path, in: repo, scratch: fixture.scratch)
        try fixture.write(name, Data("changed after review\n".utf8))
        await #expect(throws: GitInspectionFailure.changed) { try await storage.applyGitIndexEdit(final, scratch: fixture.scratch) }
        #expect(try fixture.git("show", ":" + name) == partial)
        #expect(final.after?.object.matchesBlob(disk) == true)

        try fixture.write(name, disk)
        _ = try fixture.git("add", "--", name)
        let currentWork = Data("a different unstaged edit\n".utf8)
        try fixture.write(name, currentWork)
        let head = try fixture.head()
        let wrongBase = try #require(final.after?.object)
        await #expect(throws: GitInspectionFailure.changed) {
            _ = try await storage.prepareGitIndexEdit(.unstageReviewedChange(head: wrongBase, first), path: path, in: repo, scratch: fixture.scratch)
        }
        let reverse = try await storage.prepareGitIndexEdit(.unstageReviewedChange(head: head, first), path: path, in: repo, scratch: fixture.scratch)
        let remaining = Data("start\nfirst old\nbetween\nlast new\n".utf8)
        #expect(reverse.after?.object.matchesBlob(remaining) == true)
        try await storage.applyGitIndexEdit(reverse, scratch: fixture.scratch)
        #expect(try fixture.git("show", ":" + name) == remaining)
        #expect(try fixture.git("show", ":Keep.txt") == unrelated)
        #expect(try Data(contentsOf: fixture.worktree.appendingPathComponent(name)) == currentWork)
        await #expect(throws: GitInspectionFailure.changed) { try await storage.applyGitIndexEdit(reverse, scratch: fixture.scratch) }
    }

    @Test func guardedIndexRemovalRequiresTheReviewedMissingFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let name = "Scope/Removed.txt"
        let file = fixture.worktree.appendingPathComponent(name)
        let parent = file.deletingLastPathComponent()
        try fixture.write(name, Data("tracked\n".utf8))
        try fixture.write("Keep.txt", Data("starting\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Generated baseline")
        let head = try fixture.head()
        let kept = Data("unrelated staged text\n".utf8)
        try fixture.write("Keep.txt", kept)
        _ = try fixture.git("add", "--", "Keep.txt")
        try FileManager().removeItem(at: file)

        let storage = LocalFileSystem()
        let repo = try #require(try await storage.locateGitRepository(at: parent))
        let path = try #require(GitSnapshotPath(name))
        let folder = try #require(GitSnapshotPath("Scope"))
        let committed = try await storage.readGitWorkingFolder(in: repo, at: folder,
            revision: .head, showHidden: false, scratch: fixture.scratch)
        #expect(committed.stagingSelection(for: path) == nil)
        let report = try await storage.readGitWorkingFolder(in: repo, at: folder,
            baseline: .index, showHidden: false, scratch: fixture.scratch)
        let selection = try #require(report.stagingSelection(for: path))
        #expect(selection.isRemoval)
        let plan = try await storage.prepareGitIndexEdit(.stageReviewedPath(selection), path: path, in: repo, scratch: fixture.scratch)
        #expect(plan.before?.object.matchesBlob(Data("tracked\n".utf8)) == true && plan.after == nil)
        let index = fixture.worktree.appendingPathComponent(".git/index")
        let lock = fixture.worktree.appendingPathComponent(".git/index.lock")
        let baseline = try Data(contentsOf: index)

        let retained = fixture.worktree.appendingPathComponent("Original Scope")
        try FileManager().moveItem(at: parent, to: retained)
        try FileManager().createDirectory(at: parent, withIntermediateDirectories: false)
        await #expect(throws: GitInspectionFailure.changed) { try await storage.applyGitIndexEdit(plan, scratch: fixture.scratch) }
        #expect(try Data(contentsOf: index) == baseline)
        try FileManager().removeItem(at: parent)
        try FileManager().moveItem(at: retained, to: parent)

        let view = try GitReadView(location: repo, scratch: fixture.scratch, check: {})
        let appeared = Data("reappeared while locked\n".utf8)
        var didReappear = false
        #expect(throws: GitInspectionFailure.changed) {
            try view.applyIndexEdit(plan, check: {
                if !didReappear && FileManager().fileExists(atPath: lock.path) {
                    try appeared.write(to: file, options: .withoutOverwriting)
                    didReappear = true
                }
            })
        }
        #expect(didReappear && !FileManager().fileExists(atPath: lock.path))
        #expect(try Data(contentsOf: file) == appeared && Data(contentsOf: index) == baseline)
        try FileManager().removeItem(at: file)
        try await storage.applyGitIndexEdit(plan, scratch: fixture.scratch)
        #expect(!FileManager().fileExists(atPath: file.path) && !FileManager().fileExists(atPath: lock.path))
        #expect(try fixture.git("ls-files", "--", name).isEmpty)
        #expect(try fixture.git("show", ":Keep.txt") == kept && fixture.head() == head)

        let unstage = try await storage.prepareGitIndexEdit(.unstage, path: path, in: repo, scratch: fixture.scratch)
        try await storage.applyGitIndexEdit(unstage, scratch: fixture.scratch)
        #expect(try fixture.git("show", ":" + name) == Data("tracked\n".utf8))
        #expect(!FileManager().fileExists(atPath: file.path))
    }

    enum LockChange: CaseIterable { case editAfterWrite, editAfterBlob, replaceAfterBlob }

    @Test(arguments: LockChange.allCases) func guardedIndexPublicationRequiresThePreparedLock(change: LockChange) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let name = "Review.txt", saved = Data("saved\n".utf8)
        try fixture.write(name, Data("committed\n".utf8))
        _ = try fixture.git("add", "--", name)
        _ = try fixture.git("commit", "-m", "Generated baseline")
        try fixture.write(name, saved)
        let storage = LocalFileSystem()
        let repository = try #require(try await storage.locateGitRepository(at: fixture.worktree))
        let path = try #require(GitSnapshotPath(name))
        let index = fixture.worktree.appendingPathComponent(".git/index")
        let lock = fixture.worktree.appendingPathComponent(".git/index.lock")
        let expected = try Data(contentsOf: index)
        let plan = try await storage.prepareGitIndexEdit(.stageSavedFile, path: path, in: repository, scratch: fixture.scratch)
        let object = try #require(plan.after?.object.hex)
        let blob = fixture.worktree.appendingPathComponent(".git/objects/\(object.prefix(2))/\(object.dropFirst(2))")
        let view = try GitReadView(location: repository, scratch: fixture.scratch, check: {})
        let foreign = Data("different index bytes\n".utf8)
        var altered = false
        #expect(throws: GitIndexEditFailure.uncertain) {
            try view.applyIndexEdit(plan, check: {
                var info = stat()
                guard !altered, lstat(lock.path, &info) == 0, info.st_size > foreign.count else { return }
                guard change == .editAfterWrite || FileManager().fileExists(atPath: blob.path) else { return }
                if change != .replaceAfterBlob {
                    let file = try FileHandle(forWritingTo: lock)
                    defer { try? file.close() }
                    try file.write(contentsOf: foreign)
                } else {
                    let replacement = fixture.worktree.appendingPathComponent("Generated competing lock")
                    try foreign.write(to: replacement, options: .withoutOverwriting)
                    guard rename(replacement.path, lock.path) == 0 else { throw GitInspectionFailure.unavailable }
                }
                altered = true
            })
        }
        #expect(altered)
        #expect(try Data(contentsOf: index) == expected)
        #expect(try Data(contentsOf: fixture.worktree.appendingPathComponent(name)) == saved)
        if change != .replaceAfterBlob { #expect(!FileManager().fileExists(atPath: lock.path)) }
        else { #expect(try Data(contentsOf: lock) == foreign) }
    }

    @Test(arguments: [true, false]) func guardedIndexPublicationPreservesAnUnexpectedDestination(existing: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let metadata = try DirectoryAnchor(fixture.worktree.appendingPathComponent(".git"))
        let index = metadata.url.appendingPathComponent("index")
        let other = Data("another generated index".utf8)
        if existing { try Data("original generated index".utf8).write(to: index, options: .withoutOverwriting) }
        let observation = try GitIndexSnapshot(metadata, check: {})
        do {
            let publication = try GitIndexPublication(in: metadata)
            try publication.write(Data("reviewed generated index".utf8), permissions: observation.permissions, check: {})
            #expect(throws: GitInspectionFailure.changed) {
                try publication.publish(replacing: observation.entry) {
                    try other.write(to: index, options: .atomic)
                }
            }
        }
        #expect(try Data(contentsOf: index) == other)
        #expect(try metadata.gitEntry("index.lock") == nil)
    }

    @Test func guardedStageRefusesAnAlteredTemporaryObjectBeforePublication() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let name = "Review.txt", saved = Data("reviewed edit\n".utf8)
        try fixture.write(name, Data("committed\n".utf8))
        _ = try fixture.git("add", "--", name)
        _ = try fixture.git("commit", "-m", "Generated baseline")
        try fixture.write(name, saved)
        let storage = LocalFileSystem()
        let repository = try #require(try await storage.locateGitRepository(at: fixture.worktree))
        let path = try #require(GitSnapshotPath(name))
        let index = fixture.worktree.appendingPathComponent(".git/index")
        let lock = fixture.worktree.appendingPathComponent(".git/index.lock")
        let original = try Data(contentsOf: index)
        let plan = try await storage.prepareGitIndexEdit(.stageSavedFile, path: path, in: repository, scratch: fixture.scratch)
        let object = try #require(plan.after?.object.hex)
        let fan = fixture.worktree.appendingPathComponent(".git/objects/\(object.prefix(2))")
        let named = fan.appendingPathComponent(String(object.dropFirst(2)))
        let view = try GitReadView(location: repository, scratch: fixture.scratch, check: {})
        var changed = false
        #expect(throws: GitIndexEditFailure.objectChanged) {
            try view.applyIndexEdit(plan, check: {
                guard !changed, FileManager().fileExists(atPath: fan.path),
                      let item = try FileManager().contentsOfDirectory(at: fan, includingPropertiesForKeys: nil)
                          .first(where: { $0.lastPathComponent.hasPrefix(".traverse-object-") }) else { return }
                var facts = stat()
                guard lstat(item.path, &facts) == 0, facts.st_size > 0 else { return }
                guard chmod(item.path, 0o600) == 0 else { throw GitInspectionFailure.unavailable }
                let file = try FileHandle(forWritingTo: item)
                defer { try? file.close() }
                try file.write(contentsOf: Data([0]))
                guard chmod(item.path, facts.st_mode & 0o777) == 0 else { throw GitInspectionFailure.unavailable }
                changed = true
            })
        }
        #expect(changed)
        #expect(!FileManager().fileExists(atPath: named.path))
        #expect(!FileManager().fileExists(atPath: lock.path))
        #expect(try Data(contentsOf: index) == original)
        #expect(try Data(contentsOf: fixture.worktree.appendingPathComponent(name)) == saved)
    }

    @Test func guardedStageRequiresTheExactParentSpellingAtPublication() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let name = "Scope/Review.txt", saved = Data("saved\n".utf8)
        try fixture.write(name, Data("committed\n".utf8))
        _ = try fixture.git("add", "--", name)
        _ = try fixture.git("commit", "-m", "Generated baseline")
        try fixture.write(name, saved)
        let storage = LocalFileSystem()
        let repository = try #require(try await storage.locateGitRepository(at: fixture.worktree))
        let path = try #require(GitSnapshotPath(name))
        let index = fixture.worktree.appendingPathComponent(".git/index")
        let lock = fixture.worktree.appendingPathComponent(".git/index.lock")
        let expected = try Data(contentsOf: index)
        let plan = try await storage.prepareGitIndexEdit(.stageSavedFile, path: path, in: repository, scratch: fixture.scratch)
        let view = try GitReadView(location: repository, scratch: fixture.scratch, check: {})
        let original = fixture.worktree.appendingPathComponent("Scope")
        let temporary = fixture.worktree.appendingPathComponent("Generated moved scope")
        let renamed = fixture.worktree.appendingPathComponent("scope")
        var didRename = false
        #expect(throws: GitInspectionFailure.changed) {
            try view.applyIndexEdit(plan, check: {
                guard !didRename, FileManager().fileExists(atPath: lock.path) else { return }
                try FileManager().moveItem(at: original, to: temporary)
                try FileManager().moveItem(at: temporary, to: renamed)
                didRename = true
            })
        }
        #expect(didRename && !FileManager().fileExists(atPath: lock.path))
        #expect(try Data(contentsOf: index) == expected)
        #expect(try Data(contentsOf: renamed.appendingPathComponent("Review.txt")) == saved)
    }

    @Test func viewportGitMetadataDoesNotReserveTheExplicitComparisonSlot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let name = "Review.txt", file = fixture.worktree.appendingPathComponent(name)
        try fixture.write(name, Data("committed\n".utf8))
        _ = try fixture.git("add", "--", name)
        _ = try fixture.git("commit", "-m", "Generated baseline")
        try fixture.write(name, Data("staged\n".utf8))
        _ = try fixture.git("add", "--", name)
        let storage = LocalFileSystem(maximumConcurrentReads: 2)
        let repository = try #require(try await storage.locateGitRepository(at: fixture.worktree))
        let path = try #require(GitSnapshotPath(name)), scratch = fixture.scratch
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let comparison = Task {
            try await storage.gitHEADLineOrigin(in: repository, path: path, scratch: scratch) { _, _ in
                entered.signal()
                guard release.wait(timeout: .now() + .seconds(10)) == .success else { throw GitInspectionFailure.unavailable }
                return 1
            }
        }
        let ready: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + .seconds(5)) == .success)
            }
        }
        let statuses: Result<[GitFileStatus], Error>
        do {
            try #require(ready)
            let metadata = try await storage.gitFileStatuses(in: repository, urls: [file], scratch: scratch)
            do {
                _ = try await storage.gitFileStatuses(in: repository, urls: [file], inspectWorkingBytes: true, scratch: scratch)
                Issue.record("Working-file content should still require the comparison slot")
            } catch LocalStorageError.busy {
                // The explicit comparison still owns this slot.
            }
            statuses = .success(metadata)
        } catch { statuses = .failure(error) }
        release.signal()
        #expect(try await comparison.value?.line == 1)
        let status = try #require(try statuses.get().first)
        #expect(status.path == path && status.hasStagedChange && status.workingCopy == .notChecked)
    }

    @Test func guardedWorkingReviewStagesOnlyTheObservedSavedFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let name = "Scope/Review.txt", original = Data("committed\n".utf8), saved = Data("to stage\n".utf8)
        try fixture.write(name, original)
        try fixture.write("Keep.txt", original)
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Generated base")
        let head = try fixture.head()
        try fixture.write(name, saved)
        try fixture.write("Keep.txt", Data("separate staged change\n".utf8))
        _ = try fixture.git("add", "--", "Keep.txt")
        let kept = try fixture.git("show", ":Keep.txt")
        let file = fixture.worktree.appendingPathComponent(name), index = fixture.worktree.appendingPathComponent(".git/index")
        let initial = try Data(contentsOf: index)
        let folder = try #require(GitSnapshotPath("Scope")), path = try #require(GitSnapshotPath(name))
        let storage = LocalFileSystem(), repo = try #require(try await storage.locateGitRepository(at: file.deletingLastPathComponent()))

        let report = try await storage.readGitWorkingFolder(in: repo, at: folder, baseline: .index, showHidden: false, scratch: fixture.scratch)
        let previous = try #require(report.stagingSelection(for: path))
        #expect(!previous.isRemoval)
        let replacement = fixture.worktree.appendingPathComponent("Replacement.txt")
        try saved.write(to: replacement, options: .withoutOverwriting)
        _ = try FileManager().replaceItemAt(file, withItemAt: replacement)
        await #expect(throws: GitInspectionFailure.changed) {
            try await storage.prepareGitIndexEdit(.stageReviewedPath(previous), path: path, in: repo, scratch: fixture.scratch)
        }
        #expect(try Data(contentsOf: index) == initial && Data(contentsOf: file) == saved)

        let updated = try await storage.readGitWorkingFolder(in: repo, at: folder, baseline: .index, showHidden: false, scratch: fixture.scratch)
        let current = try #require(updated.stagingSelection(for: path))
        let plan = try await storage.prepareGitIndexEdit(.stageReviewedPath(current), path: path, in: repo, scratch: fixture.scratch)
        #expect(plan.before?.object.matchesBlob(original) == true && plan.after?.object.matchesBlob(saved) == true)
        try await storage.applyGitIndexEdit(plan, scratch: fixture.scratch)
        #expect(try fixture.git("show", ":" + name) == saved && Data(contentsOf: file) == saved)
        #expect(try fixture.git("show", ":Keep.txt") == kept && fixture.head() == head)
    }

    @Test func guardedStageDeclinesIgnoredTransformedAndSpecialIndexes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Keep.txt", Data("base\n".utf8))
        try fixture.write(".gitignore", Data("Ignored.txt\n".utf8))
        try fixture.write(".gitattributes", Data("""
            Filtered.txt filter=example
            LiteralUnset.txt filter=unset
            LiteralUnspecified.txt working-tree-encoding=unspecified
            AmbiguousText.txt text=unset

            """.utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Generated starting commit")
        let storage = LocalFileSystem()
        let location = try await storage.locateGitRepository(at: fixture.worktree)
        let repo = try #require(location)
        let index = fixture.worktree.appendingPathComponent(".git/index")
        let baseline = try Data(contentsOf: index)
        let cases: [(String, Data, GitIndexEditFailure)] = [
            ("Ignored.txt", Data("generated\n".utf8), .ignoredPath),
            ("Filtered.txt", Data("generated\n".utf8), .contentRules),
            ("LiteralUnset.txt", Data("generated\n".utf8), .contentRules),
            ("LiteralUnspecified.txt", Data("generated\n".utf8), .contentRules),
            ("AmbiguousText.txt", Data("generated\r\n".utf8), .contentRules),
            ("Crlf.txt", Data("generated\r\n".utf8), .contentRules),
            ("keep.txt", Data("modified\n".utf8), .unsupportedPath)
        ]
        for (name, bytes, refusal) in cases {
            // APFS may be case-sensitive. The final row instead verifies the
            // case alias only when that alias resolves to the observed file.
            let url = fixture.worktree.appendingPathComponent(name)
            if name == "keep.txt" {
                guard FileManager().fileExists(atPath: url.path) else { continue }
            } else { try fixture.write(name, bytes) }
            let path = try #require(GitSnapshotPath(name))
            await #expect(throws: refusal) {
                try await storage.prepareGitIndexEdit(.stageSavedFile, path: path, in: repo, scratch: fixture.scratch)
            }
        }
        try FileManager().removeItem(at: fixture.worktree.appendingPathComponent(".gitattributes"))
        let filtered = try #require(GitSnapshotPath("Filtered.txt"))
        await #expect(throws: GitIndexEditFailure.contentRules) {
            try await storage.prepareGitIndexEdit(.stageSavedFile, path: filtered, in: repo, scratch: fixture.scratch)
        }
        #expect(try Data(contentsOf: index) == baseline)
        _ = try fixture.git("update-index", "--split-index")
        let split = try Data(contentsOf: index)
        let keep = try #require(GitSnapshotPath("Keep.txt"))
        await #expect(throws: GitIndexEditFailure.unsupportedIndex) {
            try await storage.prepareGitIndexEdit(.stageSavedFile, path: keep, in: repo, scratch: fixture.scratch)
        }
        #expect(try Data(contentsOf: index) == split)
    }

    @Test func readsExactObjectsAndCountsWithoutSourceConfigurationOrWrites() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Scope/Notes.txt", Data("old\n".utf8))
        try fixture.write("Scope/Nested/Original.txt", Data("unchanged content\n".utf8))
        try fixture.write("Outside.txt", Data("outside\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Initial")
        let left = try fixture.head()
        _ = try fixture.git("checkout", "-b", "generated/feature")
        _ = try fixture.git("mv", "--", "Scope/Nested/Original.txt", "Scope/Nested/Renamed.txt")
        try fixture.write("Scope/Notes.txt", Data("new\r\n".utf8))
        try fixture.write("Scope/New/Line\nBreak.txt", Data("one\ntwo\n".utf8))
        try fixture.write("Scope/Binary.dat", Data([0, 2, 3]))
        try fixture.write("Outside.txt", Data("other contents\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Feature")
        let right = try fixture.head()
        _ = try fixture.git("tag", "-a", "generated-version", "-m", "Generated tag")
        _ = try fixture.git("pack-refs", "--all", "--prune")
        _ = try fixture.git("repack", "-ad")
        _ = try fixture.git("prune-packed")
        // The source config is intentionally invalid. The read-only view
        // should not load it, and the original bytes must stay unchanged.
        try fixture.write(".git/config", Data("this is not a usable Git config [[[\n".utf8))
        let observed = [".git/HEAD", ".git/index", ".git/config", ".git/packed-refs", "Scope/Notes.txt", "Outside.txt"]
        let before = try observed.map { try Data(contentsOf: fixture.worktree.appendingPathComponent($0)) }
        let reader = LocalFileSystem()
        let location = try #require(try await reader.locateGitRepository(at: fixture.worktree.appendingPathComponent("Scope",
            isDirectory: true)))
        #expect(location.relativeFolder == "Scope")
        let catalog = try await reader.gitRevisionCatalog(in: location, scratch: fixture.scratch)
        #expect(catalog.head == right)
        #expect(catalog.headName == "generated/feature")
        #expect(catalog.recentCommits.map(\.object) == [right, left])
        #expect(Set(catalog.references.map(\.name)) == ["main", "generated/feature", "generated-version"])
        let tag = try #require(catalog.references.first { $0.kind == .tag })
        let report = try await reader.compareGitRevisions(in: location, left: .abbreviated(left.short),
            right: .object(tag.object), scratch: fixture.scratch)
        #expect(report.left == left)
        #expect(report.right == right)
        #expect(report.changes.count == 4)
        #expect(report.affectedSubfolders == 2)
        #expect(report.lines == .init(added: 3, removed: 1))
        #expect(report.rowsWithoutLineCounts == 1)
        #expect(report.changes.contains { $0.kind == .renamed && $0.right?.path.display == "Scope/Nested/Renamed.txt" })
        #expect(report.changes.contains { $0.right?.path.display == "Scope/New/Line␊Break.txt" })
        let changed = try #require(report.changes.first { $0.left?.path.display == "Scope/Notes.txt" })
        let comparison = try await reader.readGitTextComparison(in: location, left: changed.left, right: changed.right,
                                                                scratch: fixture.scratch)
        #expect(comparison.left.encoded == Data("old\n".utf8))
        #expect(comparison.right.encoded == Data("new\r\n".utf8))
        let whole = try await reader.compareGitRevisions(in: location, left: .object(left), right: .object(right),
                                                        wholeRepository: true, scratch: fixture.scratch)
        #expect(whole.changes.count == 5)
        #expect(try observed.map { try Data(contentsOf: fixture.worktree.appendingPathComponent($0)) } == before)
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.scratch.path).isEmpty)
    }

    @Test func refusesAnOldObjectLayoutAfterOrdinaryRepack() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Generated.txt", Data("one generated file\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Generated file before repack")
        let head = try fixture.head(), reader = LocalFileSystem()
        let location = try #require(try await reader.locateGitRepository(at: fixture.worktree))
        let existing = try GitReadView(location: location, scratch: fixture.scratch, check: {})
        #expect(try existing.resolve(.head) == head)
        _ = try fixture.git("repack", "-ad")
        _ = try fixture.git("prune-packed")
        #expect(throws: GitInspectionFailure.changed) { try existing.resolve(.head) }
        let refreshed = try await reader.gitRevisionCatalog(in: location, scratch: fixture.scratch)
        #expect(refreshed.head == head && refreshed.recentCommits.map(\.object) == [head])
    }

    @Test(arguments: ["sha1", "sha256"])
    func describesOneCommittedLineAcrossAnExactRename(objectFormat: String) async throws {
        let fixture = try Fixture(objectFormat: objectFormat)
        defer { fixture.remove() }
        let original = "Scope/Café\t\"before\".txt", latest = "Scope/Current.txt"
        try fixture.write(original, Data("One\r\nStable line\r\nOld last line\r\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "First note")
        let first = try fixture.head()
        _ = try fixture.git("mv", "--", original, latest)
        _ = try fixture.git("commit", "-m", "Move note")
        let moved = try fixture.head()
        try fixture.write(latest, Data("One\r\nStable line\r\nRevised last line\r\n".utf8))
        try fixture.write(".mailmap", Data("Wrong Author <other@example.invalid> Generated <fixture@example.invalid>\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Revise note")
        let revised = try fixture.head()
        try fixture.write(latest, Data("Unstaged disk contents\n".utf8))
        let observed = [".git/HEAD", ".git/index", ".git/config", latest, ".mailmap"]
        let before = try observed.map { try Data(contentsOf: fixture.worktree.appendingPathComponent($0)) }
        let reader = LocalFileSystem()
        let location = try #require(try await reader.locateGitRepository(at: fixture.worktree))
        let path = try #require(GitSnapshotPath(latest))
        let version = try await reader.gitFileVersion(in: location, path: path, at: .object(revised), scratch: fixture.scratch)
        guard case .member(let member) = version.state else { Issue.record("Expected a committed file"); return }
        let origin = try await reader.gitLineOrigin(in: location, member: member, at: revised, line: 2, scratch: fixture.scratch)
        #expect(origin.commit.object == first && origin.commit.subject == "First note" && origin.author == "Generated")
        #expect(origin.path == GitSnapshotPath(original) && origin.line == 2 && origin.isBoundary)
        let mapped = try await reader.gitHEADLineOrigin(in: location, path: path, scratch: fixture.scratch) { text, cancelled in
            guard !cancelled(), text.encoded == Data("One\r\nStable line\r\nRevised last line\r\n".utf8) else {
                throw GitInspectionFailure.changed
            }
            return 2
        }
        #expect(mapped?.version == version && mapped?.line == 2)
        #expect(mapped?.origin.commit.object == first && mapped?.origin.path == GitSnapshotPath(original))
        let changed = try await reader.gitLineOrigin(in: location, member: member, at: revised, line: 3, scratch: fixture.scratch)
        #expect(changed.commit.object == revised && changed.path == path && changed.line == 3 && !changed.isBoundary)
        await #expect(throws: GitInspectionFailure.lineUnavailable) {
            _ = try await reader.gitLineOrigin(in: location, member: member, at: revised, line: 4, scratch: fixture.scratch)
        }
        await #expect(throws: GitInspectionFailure.changed) {
            _ = try await reader.gitLineOrigin(in: location, member: member, at: moved, line: 2, scratch: fixture.scratch)
        }
        #expect(try observed.map { try Data(contentsOf: fixture.worktree.appendingPathComponent($0)) } == before)
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.scratch.path).isEmpty)
    }

    @Test func stagedReviewUsesCapturedIndexInsteadOfLiveDiskAndCanChooseAnOlderBase() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Scope/Notes.txt", Data("first\n".utf8))
        try fixture.write("Scope/Subfolder/Source.txt", Data("unchanged bytes\n".utf8))
        try fixture.write("Outside.txt", Data("outside\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "First")
        let first = try fixture.head()
        try fixture.write("Scope/Notes.txt", Data("second\n".utf8))
        try fixture.write("Scope/Deleted.txt", Data("old leaf\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Second")
        let head = try fixture.head()
        _ = try fixture.git("mv", "--", "Scope/Subfolder/Source.txt", "Scope/Subfolder/Renamed.txt")
        _ = try fixture.git("rm", "--", "Scope/Deleted.txt")
        try fixture.write("Scope/Notes.txt", Data("staged\r\n".utf8))
        try fixture.write("Outside.txt", Data("staged outside\n".utf8))
        _ = try fixture.git("add", "--", "Scope/Notes.txt", "Outside.txt")
        try fixture.write("Scope/Notes.txt", Data("working text\n".utf8))
        try fixture.write("Scope/Intent.txt", Data("pending\n".utf8))
        _ = try fixture.git("add", "-N", "--", "Scope/Intent.txt")
        try fixture.write("Scope/Untracked.txt", Data("untracked\n".utf8))
        let observed = [".git/HEAD", ".git/index", "Scope/Notes.txt", "Scope/Intent.txt", "Outside.txt"]
        let before = try observed.map { try Data(contentsOf: fixture.worktree.appendingPathComponent($0)) }
        let fs = LocalFileSystem()
        let location = try #require(try await fs.locateGitRepository(at: fixture.worktree.appendingPathComponent("Scope")))
        let staged = try await fs.compareGitIndex(in: location, scratch: fixture.scratch)
        #expect(staged.base == head)
        #expect(staged.unmerged.isEmpty)
        #expect(staged.summary.affectedSubfolders == 1)
        #expect(staged.summary.lines == .init(added: 1, removed: 2))
        #expect(Set(staged.summary.changes.map(\.kind.rawValue)) == ["modified", "removed", "renamed"])
        let row = try #require(staged.summary.changes.first { $0.right?.path.display == "Scope/Notes.txt" })
        let contents = try await fs.readGitTextComparison(in: location, left: row.left, right: row.right, scratch: fixture.scratch)
        #expect(contents.left.encoded == Data("second\n".utf8))
        #expect(contents.right.encoded == Data("staged\r\n".utf8))
        let prior = try await fs.compareGitIndex(in: location, against: .object(first),
            wholeRepository: true, scratch: fixture.scratch)
        #expect(prior.base == first)
        #expect(prior.summary.changes.contains { $0.right?.path.display == "Outside.txt" })
        #expect(prior.summary.changes.count == 3)
        #expect(try observed.map { try Data(contentsOf: fixture.worktree.appendingPathComponent($0)) } == before)
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.scratch.path).isEmpty)
    }

    @Test func stagedReviewHandlesFirstCommitAndCapturesExactConflictStages() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Conflict.txt", Data("initial\n".utf8))
        let deleted = "Scope/Deleted?.txt"
        try fixture.write(deleted, Data("old copy\n".utf8))
        let fs = LocalFileSystem()
        let location = try #require(try await fs.locateGitRepository(at: fixture.worktree))
        let unborn = try await fs.readGitWorkingFolder(in: location, at: nil, baseline: .index,
            showHidden: false, scratch: fixture.scratch)
        let newFile = try #require(unborn.rows.first { $0.path.name == "Conflict.txt" })
        let newText = try #require(unborn.textSelection(for: newFile.path))
        #expect(unborn.onlyInRevision == 0 && newFile.difference == .onlyOnDisk)
        #expect(try await fs.readGitWorkingFolderText(newText, scratch: fixture.scratch).left.text.isEmpty)
        _ = try fixture.git("add", "-A")
        await #expect(throws: GitInspectionFailure.changed) { try await fs.readGitWorkingFolderText(newText, scratch: fixture.scratch) }
        let initial = try await fs.compareGitIndex(in: location, scratch: fixture.scratch)
        #expect(initial.base == nil)
        #expect(initial.summary.lines == .init(added: 2, removed: 0))
        _ = try fixture.git("commit", "-m", "Initial")
        _ = try fixture.git("checkout", "-b", "feature")
        try fixture.write("Conflict.txt", Data("feature\n".utf8))
        _ = try fixture.git("rm", "--", deleted)
        _ = try fixture.git("commit", "-am", "Feature")
        _ = try fixture.git("checkout", "main")
        try fixture.write("Conflict.txt", Data("main\n".utf8))
        try fixture.write(deleted, Data("retained on main\n".utf8))
        _ = try fixture.git("commit", "-am", "Main change")
        _ = try fixture.git("merge", "--no-edit", "feature", expectedStatus: 1)
        try fixture.write("Ready.txt", Data("ready\n".utf8))
        _ = try fixture.git("add", "--", "Ready.txt")
        let checked = [".git/index", ".git/HEAD", "Conflict.txt", deleted]
        let before = try checked.map { try Data(contentsOf: fixture.worktree.appendingPathComponent($0)) }
        let staged = try await fs.compareGitIndex(in: location, scratch: fixture.scratch)
        #expect(staged.base == (try fixture.head()))
        #expect(staged.unmerged.map(\.display) == ["Conflict.txt", deleted])
        #expect(staged.summary.changes.compactMap { $0.right?.path.display } == ["Ready.txt"])
        let conflict = try #require(staged.conflicts.first)
        let branches = try await fs.readGitTextComparison(in: location, left: conflict.ours, right: conflict.theirs, scratch: fixture.scratch)
        #expect(branches.left.text == "main\n" && branches.right.text == "feature\n")
        let ancestor = try #require(conflict.base)
        #expect(try await fs.readGitText(in: location, member: ancestor, scratch: fixture.scratch).text == "initial\n")
        let scopedLocation = try #require(try await fs.locateGitRepository(at: fixture.worktree.appendingPathComponent("Scope", isDirectory: true)))
        let scoped = try await fs.compareGitIndex(in: scopedLocation, scratch: fixture.scratch)
        #expect(scoped.summary.changes.isEmpty && scoped.unmerged.map(\.display) == [deleted])
        let working = try await fs.readGitWorkingFolder(in: scopedLocation, at: GitSnapshotPath("Scope"),
            baseline: .index, showHidden: false, scratch: fixture.scratch)
        let conflicted = try #require(working.rows.first { $0.path.display == deleted })
        #expect(working.comparesIndex && conflicted.difference == .indexConflict
            && conflicted.referenceMember == nil && working.textSelection(for: conflicted.path) == nil)
        let absent = try #require(scoped.conflicts.first)
        #expect(absent.theirs == nil)
        let oneSided = try await fs.readGitTextComparison(in: location, left: absent.base, right: absent.theirs, scratch: fixture.scratch)
        #expect(oneSided.left.text == "old copy\n" && oneSided.right.text.isEmpty)
        #expect(try checked.map { try Data(contentsOf: fixture.worktree.appendingPathComponent($0)) } == before)
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.scratch.path).isEmpty)
    }

    @Test(arguments: ["sha1", "sha256"]) func workingFolderUsesExactIndexAndRefusesAStaleSnapshot(format: String) async throws {
        let fixture = try Fixture(objectFormat: format)
        defer { fixture.remove() }
        let scope = fixture.worktree.appendingPathComponent("Scope", isDirectory: true)
        let changed = "Scope/Notes.txt", protected = "Scope/.npmrc"
        try fixture.write(changed, Data("committed text\n".utf8))
        try fixture.write("Outside/Excluded.txt", Data("outside scope\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Generated base")
        let head = try fixture.head()
        let indexBytes = Data("staged text\r\n".utf8), diskBytes = Data("working text\n".utf8)
        try fixture.write(changed, indexBytes)
        try fixture.write("Scope/Staged Folder/Member.txt", Data("indexed only\n".utf8))
        try fixture.write(protected, Data("generated protected test data\n".utf8))
        _ = try fixture.git("add", "--", "Scope")
        try fixture.write(changed, diskBytes)
        try fixture.write("Scope/Untracked.txt", Data("working only\n".utf8))
        try FileManager().removeItem(at: scope.appendingPathComponent("Staged Folder", isDirectory: true))
        try FileManager().removeItem(at: fixture.worktree.appendingPathComponent(protected))
        let indexURL = fixture.worktree.appendingPathComponent(".git/index")
        let observedIndex = try Data(contentsOf: indexURL)
        let fs = LocalFileSystem()
        let location = try #require(try await fs.locateGitRepository(at: scope))
        let scopePath = try #require(GitSnapshotPath("Scope"))
        func read() async throws -> GitWorkingFolder {
            try await fs.readGitWorkingFolder(in: location, at: scopePath, baseline: .index, showHidden: true, scratch: fixture.scratch)
        }
        let folder = try await read()
        #expect(folder.revision == nil && folder.comparesIndex && folder.onlyOnDisk == 1 && folder.onlyInRevision == 2)
        let chosenPath = try #require(GitSnapshotPath(changed))
        let selection = try #require(folder.textSelection(for: chosenPath))
        let pair = try await fs.readGitWorkingFolderText(selection, scratch: fixture.scratch)
        #expect(pair.left.encoded == indexBytes && pair.right.encoded == diskBytes)
        #expect(try await fs.readGitWorkingFolderReference(selection, scratch: fixture.scratch).encoded == indexBytes)
        #expect(folder.textSelection(for: try #require(GitSnapshotPath(protected))) == nil)
        let contents = try await fs.checkGitWorkingFolderContents(folder)
        #expect(contents.results[chosenPath] == .differs && contents.matching == 0 && contents.unchecked == 0)
        let child = try #require(folder.rows.first { $0.path.name == "Staged Folder" })
        #expect(child.isFolder && child.referenceMember == nil && child.difference == .onlyInRevision)
        let nested = try await fs.readGitWorkingFolder(in: location, at: child.path,
            baseline: .index, showHidden: true, scratch: fixture.scratch)
        let nestedSelection = try #require(nested.rows.first.flatMap { nested.textSelection(for: $0.path) })
        let nestedPair = try await fs.readGitWorkingFolderText(nestedSelection, scratch: fixture.scratch)
        #expect(nested.workingState == .absent && nestedPair.left.text == "indexed only\n" && nestedPair.right.text.isEmpty)
        #expect(try Data(contentsOf: indexURL) == observedIndex)
        _ = try fixture.git("add", "--", changed)
        await #expect(throws: GitInspectionFailure.changed) { try await fs.checkGitWorkingFolderContents(folder) }
        await #expect(throws: GitInspectionFailure.changed) { try await fs.readGitWorkingFolderText(selection, scratch: fixture.scratch) }
        await #expect(throws: GitInspectionFailure.changed) { try await fs.readGitWorkingFolderReference(selection, scratch: fixture.scratch) }
        let refreshed = try await read()
        #expect(try await fs.checkGitWorkingFolderContents(refreshed).results[chosenPath] == .matchesRevision)
        #expect(try fixture.head() == head)
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.scratch.path).isEmpty)
    }

    @Test func workingFolderKeepsCommitDiskAndUnobservedContentsDistinct() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let names = ["Scope/Common.txt", "Scope/Equal.txt", "Scope/Larger.bin", "Scope/Upper.txt", "Scope/Old/Note.txt", "Scope/Separate/Member.txt", "Scope/.hidden"]
        for name in names { try fixture.write(name, Data("committed text\n".utf8)) }
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Original")
        let head = try fixture.head()
        let disk = fixture.worktree.appendingPathComponent("Scope", isDirectory: true)
        let upper = disk.appendingPathComponent("Upper.txt")
        let temporary = disk.appendingPathComponent("Intermediate.txt")
        try FileManager().moveItem(at: upper, to: temporary)
        try FileManager().moveItem(at: temporary, to: disk.appendingPathComponent("upper.txt"))
        try FileManager().removeItem(at: disk.appendingPathComponent("Old", isDirectory: true))
        try fixture.write("Scope/Common.txt", Data("current disk text\n".utf8))
        try fixture.write("Scope/Larger.bin", Data(repeating: 0x41, count: (1 << 20) + 1))
        try fixture.write("Scope/Local.txt", Data("new disk file\n".utf8))
        try fixture.write("Scope/Separate/.git", Data("gitdir: intentionally unavailable\n".utf8))
        try FileManager().createSymbolicLink(at: disk.appendingPathComponent("Link.txt"),
            withDestinationURL: disk.appendingPathComponent("Common.txt"))
        let fs = LocalFileSystem()
        let location = try #require(try await fs.locateGitRepository(at: disk))
        let review = try await fs.readGitWorkingFolder(in: location, at: GitSnapshotPath("Scope"),
            revision: .object(head), showHidden: false, scratch: fixture.scratch)
        func row(_ name: String) throws -> GitWorkingFolder.Row { try #require(review.rows.first { $0.path.name == name }) }
        #expect(review.revision == head && review.workingState == .available && review.committedState == .available)
        #expect(!review.rows.contains { $0.path.name == ".hidden" || $0.path.name == ".git" })
        #expect(try row("Common.txt").difference == .contentsUnchecked)
        #expect(try row("Upper.txt").difference == .onlyInRevision && row("upper.txt").difference == .onlyOnDisk)
        #expect(try row("Local.txt").difference == .onlyOnDisk)
        #expect(try row("Link.txt").working == .symbolicLink && review.textSelection(for: row("Link.txt").path) == nil)
        let contents = try await fs.checkGitWorkingFolderContents(review)
        #expect(contents.matching == 1 && contents.differing == 1 && contents.unchecked == 1 && contents.unreadable == 0)
        #expect(try contents.results[row("Common.txt").path] == .differs)
        #expect(try contents.results[row("Equal.txt").path] == .matchesRevision)
        #expect(try contents.results[row("Larger.bin").path] == .aboveLimit)
        let common = try #require(review.textSelection(for: row("Common.txt").path))
        let visible = try Set([row("Local.txt").path, common.path])
        #expect(review.textSelections(visiblePaths: visible).map(\.path) == review.rows.map(\.path).filter(visible.contains))
        #expect(review.textSelections(visiblePaths: [], limit: 1).isEmpty)
        #expect(review.textSelections(limit: 1).map(\.path) == Array(review.textSelections().map(\.path).prefix(1)))
        let text = try await fs.readGitWorkingFolderText(common, scratch: fixture.scratch)
        #expect(text.left.text == "committed text\n" && text.right.text == "current disk text\n")
        let open = try #require(review.openSelection(for: row("Common.txt").path))
        let history = fixture.root.appendingPathComponent("History", isDirectory: true)
        let editor = RecoverableFileOperations(journalDirectory: history)
        #expect(try await editor.readLocalTextDocument(at: open.url, matching: open).bytes == Data("current disk text\n".utf8))
        #expect(try review.openSelection(for: row("Upper.txt").path) == nil)
        #expect(try review.openSelection(for: row("Link.txt").path) == nil)
        #expect(try review.openSelection(for: row("Larger.bin").path) == nil)
        #expect(!FileManager().fileExists(atPath: history.path))
        let caseChange = try #require(review.textSelection(for: row("Upper.txt").path))
        #expect(try await fs.readGitWorkingFolderText(caseChange, scratch: fixture.scratch).right.text.isEmpty)
        try fixture.write("Scope/Common.txt", Data("changed after listing\n".utf8))
        await #expect(throws: GitInspectionFailure.changed) {
            try await fs.readGitWorkingFolderText(common, scratch: fixture.scratch)
        }
        let changed = try await fs.checkGitWorkingFolderContents(review)
        #expect(try changed.results[row("Common.txt").path] == .unavailable)
        let equal = try #require(review.openSelection(for: row("Equal.txt").path))
        let original = fixture.root.appendingPathComponent("Retained Comparison Source.txt")
        try FileManager().moveItem(at: equal.url, to: original)
        try fixture.write("Scope/Equal.txt", Data("committed text\n".utf8))
        await #expect(throws: FileOperationFailure.sourceChanged) {
            try await editor.readLocalTextDocument(at: equal.url, matching: equal)
        }
        #expect(try Data(contentsOf: original) == Data("committed text\n".utf8))
        let absent = try await fs.readGitWorkingFolder(in: location, at: GitSnapshotPath("Scope/Old"),
            revision: .object(head), showHidden: true, scratch: fixture.scratch)
        #expect(absent.workingState == .absent && absent.rows.count == 1)
        let missing = try #require(absent.rows.first.flatMap { absent.textSelection(for: $0.path) })
        #expect(try await fs.readGitWorkingFolderText(missing, scratch: fixture.scratch).right.text.isEmpty)
        try fixture.write("Scope/Old/Note.txt", Data("created after the report\n".utf8))
        await #expect(throws: GitInspectionFailure.changed) {
            try await fs.readGitWorkingFolderText(missing, scratch: fixture.scratch)
        }
        let separate = try await fs.readGitWorkingFolder(in: location, at: GitSnapshotPath("Scope/Separate"),
            revision: .object(head), showHidden: true, scratch: fixture.scratch)
        #expect(separate.workingState == .unavailable && separate.rows.count == 1)
        #expect(separate.rows.allSatisfy { separate.textSelection(for: $0.path) == nil })
        #expect(try fixture.head() == head)
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.scratch.path).isEmpty)
    }

    @Test func nestedMarkerDoesNotBorrowOuterProject() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Nested/.git", Data("gitdir: ignored\n".utf8))
        let location = try await LocalFileSystem().locateGitRepository(at: fixture.worktree.appendingPathComponent("Nested",
            isDirectory: true))
        #expect(location == nil)
        #expect(!FileManager().fileExists(atPath: fixture.scratch.path))
    }

    @Test func checkoutLabelUsesOnlyItsCurrentHead() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = LocalFileSystem()
        let initial = try #require(try await service.locateGitCheckout(at: fixture.worktree))
        #expect(initial.head == .branch("main"))
        _ = try fixture.git("symbolic-ref", "HEAD", "refs/heads/feature/new-branch")
        let switched = try #require(try await service.locateGitCheckout(at: fixture.worktree))
        #expect(initial.location == switched.location && switched.head == .branch("feature/new-branch"))
        _ = try fixture.git("commit", "--allow-empty", "-m", "Generated branch tip")
        let exact = try fixture.head()
        _ = try fixture.git("checkout", "--detach", exact.hex)
        let detached = try #require(try await service.locateGitCheckout(at: fixture.worktree))
        #expect(detached.head == .detached(exact) && detached.location == initial.location)
        try fixture.write(".git/HEAD", Data("invalid label\n".utf8))
        let malformed = try #require(try await service.locateGitCheckout(at: fixture.worktree))
        #expect(malformed.head == nil && malformed.location == initial.location)
        #expect(!FileManager().fileExists(atPath: fixture.scratch.path))
    }

    @Test func linkedWorktreeKeepsItsOwnHeadIndexAndWorkingFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Scope/Note.txt", Data("main baseline\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Generated common base")
        let mainHead = try fixture.head()
        let linked = fixture.root.appendingPathComponent("Linked Branch", isDirectory: true)
        _ = try fixture.git("worktree", "add", "-b", "linked", linked.path)
        let linkedFile = linked.appendingPathComponent("Scope/Note.txt")
        let mainFile = fixture.worktree.appendingPathComponent("Scope/Note.txt")
        try Data("linked baseline\n".utf8).write(to: linkedFile)
        _ = try fixture.git("-C", linked.path, "commit", "-am", "Generated linked baseline")
        let linkedHead = try #require(GitObjectID(String(decoding: fixture.git("-C", linked.path, "rev-parse", "HEAD"), as: UTF8.self)
            .trimmingCharacters(in: .newlines)))
        try Data("linked index\n".utf8).write(to: linkedFile)
        _ = try fixture.git("-C", linked.path, "add", "--", "Scope/Note.txt")
        try Data("linked disk\n".utf8).write(to: linkedFile)
        try Data("main index\n".utf8).write(to: mainFile)
        _ = try fixture.git("add", "--", "Scope/Note.txt")

        let service = LocalFileSystem()
        let inner = linkedFile.deletingLastPathComponent()
        let nested = try #require(try await service.locateGitRepository(at: inner, within: fixture.root))
        let main = try #require(try await service.locateGitRepository(at: fixture.worktree))
        #expect(nested.root.path == linked.path && nested.relativeFolder == "Scope" && nested.isLinkedWorktree)
        #expect(!main.isLinkedWorktree && !nested.isSameRepository(as: main))
        #expect(try await service.locateGitCheckout(at: inner, within: fixture.root)?.head == .branch("linked"))
        #expect(try await service.locateGitCheckout(at: fixture.worktree)?.head == .branch("main"))
        let mainScope = try #require(try await service.locateGitRepository(at: mainFile.deletingLastPathComponent()))
        #expect(nested.canCompareCheckedOutRevisions(with: mainScope))
        #expect(!nested.canCompareCheckedOutRevisions(with: main) && !mainScope.canCompareCheckedOutRevisions(with: mainScope))
        #expect(try await service.locateGitRepository(at: inner, within: linked) == nil)
        let detached = fixture.root.appendingPathComponent("Detached Checkout", isDirectory: true)
        _ = try fixture.git("worktree", "add", "--detach", detached.path, mainHead.hex)
        let worktrees = try await service.readGitWorktrees(in: main, allowedRoots: [fixture.root])
        #expect(!worktrees.isIncomplete)
        #expect(worktrees.worktrees.map(\.url.path) == [fixture.worktree.path, detached.path, linked.path])
        try #require(worktrees.worktrees.count == 3)
        #expect(worktrees.worktrees.first?.isCurrent == true && worktrees.worktrees.first?.isPrimary == true)
        #expect(worktrees.worktrees[1].head == .detached(mainHead) && worktrees.worktrees[2].head == .branch("linked"))
        let fromLinked = try await service.readGitWorktrees(in: nested, allowedRoots: [fixture.root])
        #expect(fromLinked.worktrees.map(\.url.path) == [linked.path, fixture.worktree.path, detached.path])
        let scoped = try await service.readGitWorktrees(in: main, allowedRoots: [fixture.worktree])
        #expect(scoped.isIncomplete && scoped.worktrees.map(\.url.path) == [fixture.worktree.path])
        let candidate = try #require(worktrees.worktrees.last)
        #expect(try await service.verifyGitWorktree(candidate, in: main, allowedRoots: [fixture.root]).path == linked.path)
        let matching = try #require(GitSnapshotPath("Scope"))
        #expect(try await service.verifyGitWorktree(candidate, in: main, matching: matching, allowedRoots: [fixture.root]).path == inner.path)
        let unavailable = try #require(GitSnapshotPath("Unavailable"))
        #expect(try await service.verifyGitWorktree(candidate, in: main, matching: unavailable, allowedRoots: [fixture.root]).path == linked.path)
        try FileManager().createSymbolicLink(at: linked.appendingPathComponent("Unavailable"), withDestinationURL: fixture.worktree)
        #expect(try await service.verifyGitWorktree(candidate, in: main, matching: unavailable, allowedRoots: [fixture.root]).path == linked.path)
        await #expect(throws: GitInspectionFailure.unavailable) {
            try await service.verifyGitWorktree(candidate, in: main, allowedRoots: [fixture.worktree])
        }
        let relativeFile = try #require(GitSnapshotPath("Scope/Note.txt"))
        let otherFile = try await service.inspectGitWorktreeFile(relativeFile, in: candidate, from: main, allowedRoots: [fixture.root])
        #expect(otherFile.url == linkedFile && otherFile.repository.isSameRepository(as: nested)
            && otherFile.head == .branch("linked") && otherFile.text == nil)
        let snapshot = try await service.inspectGitWorktreeFile(relativeFile, in: candidate, from: main,
            allowedRoots: [fixture.root], readingText: true)
        #expect(snapshot.text?.text == "linked disk\n")
        let linkPath = try #require(GitSnapshotPath("Scope/Link.txt"))
        try FileManager().createSymbolicLink(at: linked.appendingPathComponent("Scope/Link.txt"), withDestinationURL: mainFile)
        await #expect(throws: GitInspectionFailure.worktreeFileUnavailable) {
            try await service.inspectGitWorktreeFile(linkPath, in: candidate, from: main, allowedRoots: [fixture.root])
        }
        await #expect(throws: GitInspectionFailure.unavailable) {
            try await service.inspectGitWorktreeFile(relativeFile, in: candidate, from: main, allowedRoots: [fixture.worktree])
        }

        let marker = linked.appendingPathComponent(".git")
        let admin = try #require(nested.link?.metadata)
        let config = admin.appendingPathComponent("config.worktree")
        try Data("unsupported custom configuration\n".utf8).write(to: config)
        let observed = [linkedFile, mainFile, marker, admin.appendingPathComponent("HEAD"), admin.appendingPathComponent("index"),
                        admin.appendingPathComponent("commondir"), admin.appendingPathComponent("gitdir"), config,
                        fixture.worktree.appendingPathComponent(".git/HEAD"), fixture.worktree.appendingPathComponent(".git/index")]
        let before = try observed.map { try Data(contentsOf: $0) }
        let catalog = try await service.gitRevisionCatalog(in: nested, scratch: fixture.scratch)
        #expect(catalog.head == linkedHead && catalog.headName == "linked")
        #expect(Set(catalog.references.map(\.object)) == [mainHead, linkedHead])
        let checkedOut = try #require(try await service.gitRevisionCatalog(in: nested, pairedWith: mainScope,
            scratch: fixture.scratch).pairedCheckouts)
        #expect(checkedOut.left.head == .branch("linked") && checkedOut.left.commit == linkedHead)
        #expect(checkedOut.right.head == .branch("main") && checkedOut.right.commit == mainHead)
        await #expect(throws: GitInspectionFailure.changed) {
            try await service.gitRevisionCatalog(in: nested, pairedWith: main, scratch: fixture.scratch)
        }
        #expect(try await service.readGitIndexText(in: nested, url: linkedFile, scratch: fixture.scratch).text == "linked index\n")
        #expect(try await service.readGitIndexText(in: main, url: mainFile, scratch: fixture.scratch).text == "main index\n")
        let folder = try await service.readGitWorkingFolder(in: nested, at: GitSnapshotPath("Scope"),
            revision: .head, showHidden: false, scratch: fixture.scratch)
        let selecting = try #require(folder.textSelection(for: relativeFile))
        let pair = try await service.readGitWorkingFolderText(selecting, scratch: fixture.scratch)
        #expect(folder.revision == linkedHead && selecting.workingFileURL == linkedFile)
        #expect(pair.left.text == "linked baseline\n" && pair.right.text == "linked disk\n")
        let linkedIndex = try await service.readGitWorkingFolder(in: nested, at: GitSnapshotPath("Scope"),
            baseline: .index, showHidden: false, scratch: fixture.scratch)
        let indexedSelection = try #require(linkedIndex.textSelection(for: relativeFile))
        let indexedPair = try await service.readGitWorkingFolderText(indexedSelection, scratch: fixture.scratch)
        #expect(indexedPair.left.text == "linked index\n" && indexedPair.right.text == "linked disk\n")
        #expect(try observed.map { try Data(contentsOf: $0) } == before)

        let stage = try await service.prepareGitIndexEdit(.stageSavedFile, path: relativeFile, in: nested, scratch: fixture.scratch)
        try await service.applyGitIndexEdit(stage, scratch: fixture.scratch)
        #expect(try fixture.git("-C", linked.path, "show", ":Scope/Note.txt") == Data("linked disk\n".utf8))
        #expect(try fixture.git("show", ":Scope/Note.txt") == Data("main index\n".utf8))
        let unstage = try await service.prepareGitIndexEdit(.unstage, path: relativeFile, in: nested, scratch: fixture.scratch)
        #expect(unstage.head == linkedHead)
        try await service.applyGitIndexEdit(unstage, scratch: fixture.scratch)
        #expect(try fixture.git("-C", linked.path, "show", ":Scope/Note.txt") == Data("linked baseline\n".utf8))
        for (url, snapshot) in zip(observed, before) where url != admin.appendingPathComponent("index") {
            #expect(try Data(contentsOf: url) == snapshot)
        }
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.scratch.path).isEmpty)

        // A saved location must not silently reuse the common repository if
        // the reciprocal link changes while a browser or editor is open.
        try Data((fixture.worktree.appendingPathComponent(".git").path + "\n").utf8).write(to: admin.appendingPathComponent("gitdir"))
        #expect(try await service.locateGitRepository(at: inner, within: fixture.root) == nil)
        let changed = try await service.readGitWorktrees(in: main, allowedRoots: [fixture.root])
        #expect(changed.isIncomplete && changed.worktrees.map(\.url.path) == [fixture.worktree.path, detached.path])
        await #expect(throws: GitInspectionFailure.changed) {
            try await service.verifyGitWorktree(candidate, in: main, allowedRoots: [fixture.root])
        }
        await #expect(throws: GitInspectionFailure.changed) {
            try await service.inspectGitWorktreeFile(relativeFile, in: candidate, from: main, allowedRoots: [fixture.root])
        }
        await #expect(throws: GitInspectionFailure.changed) {
            try await service.gitRevisionCatalog(in: nested, scratch: fixture.scratch)
        }
        await #expect(throws: GitInspectionFailure.changed) {
            try await service.gitRevisionCatalog(in: mainScope, pairedWith: nested, scratch: fixture.scratch)
        }
    }

    @Test func sha256LooseObjectsAndAbsentRevisionAreHandled() async throws {
        let fixture = try Fixture(objectFormat: "sha256")
        defer { fixture.remove() }
        try fixture.write("Tracked.txt", Data("before\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Before")
        let left = try fixture.head()
        try fixture.write("Tracked.txt", Data("after\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "After")
        let reader = LocalFileSystem()
        let location = try #require(try await reader.locateGitRepository(at: fixture.worktree))
        let report = try await reader.compareGitRevisions(in: location, left: .object(left), right: .head, scratch: fixture.scratch)
        #expect(left.hex.count == 64)
        let changed = try #require(report.changes.first)
        let pair = try await reader.readGitTextComparison(in: location, left: changed.left, right: changed.right,
                                                          scratch: fixture.scratch)
        #expect(pair.right.text == "after\n")
        await #expect(throws: GitInspectionFailure.revisionUnavailable) {
            try await reader.compareGitRevisions(in: location, left: .abbreviated("--not-a-hash"), right: .head,
                                                 scratch: fixture.scratch)
        }
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.scratch.path).isEmpty)
    }

    @Test func followsAFileAcrossRenamesMergesAndOtherBranches() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let formerPath = "Scope/Old\nName.txt"
        let currentPath = "Scope/New\tName.txt"
        let former = try #require(GitSnapshotPath(formerPath)), current = try #require(GitSnapshotPath(currentPath))
        try fixture.write(formerPath, Data("Base\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Original")
        let original = try fixture.head()
        _ = try fixture.git("branch", "old-name")
        _ = try fixture.git("mv", "--", formerPath, currentPath)
        _ = try fixture.git("commit", "-m", "Rename")
        let rename = try fixture.head()
        _ = try fixture.git("switch", "-c", "feature")
        try fixture.write(currentPath, Data("Feature\r\n".utf8))
        _ = try fixture.git("commit", "-am", "Feature edit")
        let feature = try fixture.head()
        _ = try fixture.git("switch", "main")
        _ = try fixture.git("merge", "--no-ff", "feature", "-m", "Merge feature")
        let merge = try fixture.head()
        _ = try fixture.git("rm", "--", currentPath)
        _ = try fixture.git("commit", "-m", "Remove")
        let removed = try fixture.head()
        let untouched = [".git/index", ".git/HEAD", ".git/refs/heads/main", ".git/refs/heads/feature"]
        let before = try untouched.map { try Data(contentsOf: fixture.worktree.appendingPathComponent($0)) }

        let reader = LocalFileSystem()
        let location = try #require(try await reader.locateGitRepository(at: fixture.worktree))
        #expect(location.filePath(for: fixture.worktree.appendingPathComponent(currentPath)) == current)
        #expect(location.filePath(for: fixture.root.appendingPathComponent(currentPath)) == nil)
        #expect(location.filePath(for: fixture.worktree.appendingPathComponent(".git/config")) == nil)
        let (catalog, timeline) = try await reader.openGitFileHistory(in: location, path: current, scratch: fixture.scratch)
        #expect(catalog.head == removed && timeline.startingCommit == removed)
        #expect(timeline.entries.map(\.id) == [removed, merge, rename, original])
        #expect(timeline.entries.map(\.kind) == [.removed, .modified, .renamed, .added])
        #expect(timeline.entries[0].after == nil && timeline.entries[3].before == nil)
        #expect(timeline.entries[2].before?.path == former && timeline.entries[2].after?.path == current)
        let mergeEntry = timeline.entries[1]
        let diff = try await reader.readGitTextComparison(in: location, left: mergeEntry.before, right: mergeEntry.after, scratch: fixture.scratch)
        #expect(diff.left.encoded == Data("Base\n".utf8) && diff.right.encoded == Data("Feature\r\n".utf8))

        let alternate = try await reader.gitFileHistory(in: location, path: current, from: .object(feature), scratch: fixture.scratch)
        #expect(alternate.entries.map(\.id) == [feature, rename, original])
        let absent = try await reader.gitFileVersion(in: location, path: current, at: .object(original), scratch: fixture.scratch)
        #expect(absent.state == .absent)
        let older = try await reader.gitFileVersion(in: location, path: former, at: .object(original), scratch: fixture.scratch)
        guard case .member(let blob) = older.state else { Issue.record("Earlier path did not resolve"); return }
        #expect(try await reader.readGitText(in: location, member: blob, scratch: fixture.scratch).text == "Base\n")
        let directory = try await reader.gitFileVersion(in: location, path: try #require(GitSnapshotPath("Scope")),
                                                        at: .object(original), scratch: fixture.scratch)
        #expect(directory.state == .directory)
        #expect(try untouched.map { try Data(contentsOf: fixture.worktree.appendingPathComponent($0)) } == before)
        #expect(!FileManager().fileExists(atPath: fixture.worktree.appendingPathComponent(currentPath).path))
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.scratch.path).isEmpty)
    }

    @Test func indexStatusKeepsStagingAndIgnoreRulesSeparateFromTheWorkingFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reader = LocalFileSystem()
        let location = try #require(try await reader.locateGitRepository(at: fixture.worktree))
        try fixture.write("Clean.txt", Data("base\n".utf8))
        try fixture.write("Staged.txt", Data("base\n".utf8))
        try fixture.write("Removed.txt", Data("base\n".utf8))
        try fixture.write(".gitignore", Data("*.tmp\n!keep.tmp\n:literal\n".utf8))
        _ = try fixture.git("add", "-A")
        let unborn = try await reader.gitFileStatuses(in: location, urls: [fixture.worktree.appendingPathComponent("Staged.txt")],
                                                       scratch: fixture.scratch)
        #expect(unborn.first?.hasStagedChange == true)
        _ = try fixture.git("commit", "-m", "Base")
        try fixture.write("Staged.txt", Data("staged only\n".utf8))
        try fixture.write("Intent.txt", Data("intent\n".utf8))
        _ = try fixture.git("add", "Staged.txt")
        _ = try fixture.git("add", "-N", "Intent.txt")
        _ = try fixture.git("rm", "--cached", "--", "Removed.txt")
        try fixture.write("Staged.txt", Data("working only\n".utf8))
        try fixture.write(".git/info/exclude", Data("local-only.txt\n".utf8))
        try fixture.write("Nested/.gitignore", Data("local*\n".utf8))
        let requested = ["Clean.txt", "Staged.txt", "Intent.txt", "Removed.txt", "keep.tmp", "ignored\nname.tmp",
                         ":literal", "local-only.txt", "Nested/local file.txt", "New*Name.txt"]
        for name in requested.dropFirst(4) { try fixture.write(name, Data("working fixture\n".utf8)) }
        try fixture.write(".git/config", Data("invalid source config fixture\n".utf8))
        let inputs = [".git/HEAD", ".git/index", ".git/config", ".git/info/exclude", "Staged.txt", "Nested/.gitignore"]
        let before = try inputs.map { try Data(contentsOf: fixture.worktree.appendingPathComponent($0)) }
        let report = try await reader.gitFileStatuses(in: location, urls: requested.map { fixture.worktree.appendingPathComponent($0) },
                                                       scratch: fixture.scratch)
        try #require(report.count == requested.count)
        #expect(!report[0].hasStagedChange && report[0].indexed != nil)
        #expect(report[1].hasStagedChange && report[1].indexed != nil)
        #expect(!report[2].hasStagedChange && report[2].indexed != nil)
        #expect(report[3].hasStagedChange && report[3].isUntracked)
        #expect(report[4].isUntracked && report[9].isUntracked)
        #expect(report[5...8].map(\.isIgnored) == [true, true, true, true])
        let staged = try #require(report[1].indexed)
        #expect(try await reader.readGitText(in: location, member: staged, scratch: fixture.scratch).text == "staged only\n")
        #expect(report.allSatisfy { $0.workingCopy == .notChecked })
        let urls = requested.prefix(3).map { fixture.worktree.appendingPathComponent($0) }
        let exact = try await reader.gitFileStatuses(in: location, urls: urls, inspectWorkingBytes: true, scratch: fixture.scratch)
        #expect(exact.map(\.workingCopy) == [.matchesIndex, .differentBytes, .differentBytes])
        let indexValue = try await reader.readGitIndexText(in: location, url: urls[1], scratch: fixture.scratch)
        let workValue = try await reader.readGitWorkingText(in: location, url: urls[1])
        #expect(indexValue.text == "staged only\n" && workValue.text == "working only\n")
        await #expect(throws: GitInspectionFailure.noIndexedVersion) {
            try await reader.readGitIndexText(in: location, url: fixture.worktree.appendingPathComponent("keep.tmp"), scratch: fixture.scratch)
        }
        #expect(try inputs.map { try Data(contentsOf: fixture.worktree.appendingPathComponent($0)) } == before)
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.scratch.path).isEmpty)
    }

    @Test func unresolvedIndexStagesDoNotBecomeAReadOfTheCurrentFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.worktree.appendingPathComponent("Conflict.txt")
        try fixture.write("Conflict.txt", Data("base\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Base")
        _ = try fixture.git("switch", "-c", "other")
        try fixture.write("Conflict.txt", Data("branch\n".utf8))
        _ = try fixture.git("commit", "-am", "Other")
        _ = try fixture.git("switch", "main")
        try fixture.write("Conflict.txt", Data("main\n".utf8))
        _ = try fixture.git("commit", "-am", "Main")
        _ = try fixture.git("merge", "other", expectedStatus: 1)
        let index = fixture.worktree.appendingPathComponent(".git/index")
        let original = try Data(contentsOf: index)
        let service = LocalFileSystem()
        let location = try #require(try await service.locateGitRepository(at: fixture.worktree))
        let status = try await service.gitFileStatuses(in: location, urls: [file], scratch: fixture.scratch)
        let conflict = try #require(status.first)
        #expect(conflict.isConflicted && conflict.indexed == nil && !conflict.isUntracked)
        await #expect(throws: GitInspectionFailure.indexConflict) {
            try await service.readGitIndexText(in: location, url: file, scratch: fixture.scratch)
        }
        #expect(try Data(contentsOf: index) == original)
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.scratch.path).isEmpty)
    }

    @Test func listsTheSameFolderInBothPinnedTreesAndExplainsAbsence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Shared/Nested/Report.txt", Data("base\n".utf8))
        try fixture.write("Type Change", Data("ordinary file\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Base")
        let left = try fixture.head()
        try fixture.write("Shared/Nested/Report.txt", Data("after\n".utf8))
        try fixture.write("New/Name\tWith\nSpaces.txt", Data("new\n".utf8))
        try FileManager().removeItem(at: fixture.worktree.appendingPathComponent("Type Change"))
        try fixture.write("Type Change/Contained.txt", Data("different type\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Other")
        let right = try fixture.head()

        let service = LocalFileSystem()
        let location = try #require(try await service.locateGitRepository(at: fixture.worktree))
        let root = try await service.readGitFolders(in: location, left: left, right: right, at: nil, scratch: fixture.scratch)
        #expect(root.left.entries.map(\.path.name) == ["Shared", "Type Change"])
        #expect(root.right.entries.count == 3 && root.right.entries.allSatisfy { $0.kind == .directory })
        let shared = try #require(GitSnapshotPath("Shared/Nested"))
        let children = try await service.readGitFolders(in: location, left: left, right: right, at: shared, scratch: fixture.scratch)
        let old = try #require(children.left.entries.first), new = try #require(children.right.entries.first)
        #expect(old.path.parent == shared && new.path == old.path && old.object != new.object)
        let text = try await service.readGitTextComparison(in: location, left: old, right: new, scratch: fixture.scratch)
        #expect(text.left.text == "base\n" && text.right.text == "after\n")
        let newFolder = try #require(GitSnapshotPath("New"))
        let missing = try await service.readGitFolders(in: location, left: left, right: right, at: newFolder, scratch: fixture.scratch)
        guard case .absent = missing.left else { Issue.record("Missing branch path was presented as an empty folder"); return }
        #expect(missing.right.entries.first?.path == GitSnapshotPath("New/Name\tWith\nSpaces.txt"))
        let changedPath = try #require(GitSnapshotPath("Type Change"))
        let sharedRoot = try #require(GitSnapshotPath("Shared"))
        #expect(root.leftDifferences == [sharedRoot: .modified, changedPath: .typeChanged])
        #expect(root.rightDifferences == [sharedRoot: .modified, changedPath: .typeChanged, newFolder: .onlyHere])
        let type = try await service.readGitFolders(in: location, left: left, right: right, at: changedPath, scratch: fixture.scratch)
        guard case .differentType(.file) = type.left else { Issue.record("A committed file was mistaken for a folder"); return }
        #expect(type.right.entries.first?.path.name == "Contained.txt")
        #expect(try fixture.head() == right)
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.scratch.path).isEmpty)
    }

    @Test func continuesAtTheActualPredecessorPathAfterARenameOnThePageBoundary() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Original.txt", Data("original name and text\n".utf8))
        _ = try fixture.git("add", "--", "Original.txt")
        _ = try fixture.git("commit", "-m", "Original file")
        let original = try fixture.head()
        _ = try fixture.git("mv", "--", "Original.txt", "Current.txt")
        _ = try fixture.git("commit", "-m", "Move to current name")
        let renamed = try fixture.head()
        for index in 0..<95 {
            try fixture.write("Current.txt", Data("change \(index)\n".utf8))
            _ = try fixture.git("commit", "-am", "Update file \(index)")
        }
        let head = try fixture.head()
        let reader = LocalFileSystem()
        let location = try #require(try await reader.locateGitRepository(at: fixture.worktree))
        let path = try #require(GitSnapshotPath("Current.txt"))
        let first = try await reader.gitFileHistory(in: location, path: path, from: .head, scratch: fixture.scratch)
        let next = try #require(first.older)
        #expect(first.entries.count == 96 && first.entries.last?.id == renamed)
        #expect(first.entries.last?.kind == .renamed)
        #expect(next.commit == original && next.path == GitSnapshotPath("Original.txt"))
        let second = try await reader.gitFileHistory(in: location, path: next.path, from: .object(next.commit), scratch: fixture.scratch)
        #expect(second.start == next && second.entries.map(\.id) == [original] && second.older == nil)
        let member = try #require(second.entries.first?.after)
        let value = try await reader.readGitText(in: location, member: member, scratch: fixture.scratch)
        #expect(value.text == "original name and text\n")
        let firstPage = try await reader.readGitFolderHistory(in: location, from: .head, wholeRepository: true, scratch: fixture.scratch)
        let secondPage = try await reader.readGitFolderHistory(in: location, from: .object(try #require(firstPage.older)),
            wholeRepository: true, scratch: fixture.scratch)
        #expect(firstPage.start == head && firstPage.commits.count == 96 && firstPage.commits.last?.id == renamed)
        #expect(secondPage.start == original && secondPage.commits.map(\.id) == [original] && secondPage.older == nil)
        #expect(try fixture.head() == head)
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.scratch.path).isEmpty)
    }

    @Test func comparesFromAUniqueCommonAncestorAndRefusesAmbiguousOrDisconnectedHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Scope/Base.txt", Data("base\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Shared base")
        let base = try fixture.head()
        _ = try fixture.git("branch", "topic")
        try fixture.write("Scope/Left.txt", Data("from main\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Main only")
        let left = try fixture.head()
        _ = try fixture.git("checkout", "topic")
        try fixture.write("Scope/Nested/Right.txt", Data("from topic\n".utf8))
        _ = try fixture.git("add", "-A")
        _ = try fixture.git("commit", "-m", "Topic only")
        let right = try fixture.head()
        let tree = String(decoding: try fixture.git("rev-parse", "HEAD^{tree}"), as: UTF8.self).trimmingCharacters(in: .newlines)
        func object(_ output: Data) throws -> GitObjectID {
            try #require(GitObjectID(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines)))
        }
        let unrelated = try object(fixture.git("commit-tree", tree, "-m", "Independent history"))
        let mergeOne = try object(fixture.git("commit-tree", tree, "-p", left.hex, "-p", right.hex, "-m", "First merge"))
        let mergeTwo = try object(fixture.git("commit-tree", tree, "-p", right.hex, "-p", left.hex, "-m", "Second merge"))
        let reader = LocalFileSystem()
        let location = try #require(try await reader.locateGitRepository(at: fixture.worktree.appendingPathComponent("Scope")))
        func compare(_ a: GitObjectID, _ b: GitObjectID, basis: GitTreeComparison.Basis) async throws -> GitTreeComparison {
            try await reader.compareGitRevisions(in: location, left: .object(a), right: .object(b), basis: basis, scratch: fixture.scratch)
        }
        let tips = try await compare(left, right, basis: .selectedRevisions)
        let changes = try await compare(left, right, basis: .commonAncestor)
        #expect(tips.left == left && tips.right == right && tips.changes.count == 2)
        #expect(changes.selectedLeft == left && changes.left == base && changes.right == right)
        #expect(changes.changes.map { $0.right?.path.display } == ["Scope/Nested/Right.txt"])
        #expect(changes.affectedSubfolders == 1 && changes.lines.added == 1 && changes.lines.removed == 0)
        let same = try await compare(right, right, basis: .commonAncestor)
        #expect(same.left == right && same.changes.isEmpty)
        await #expect(throws: GitInspectionFailure.noCommonAncestor) { _ = try await compare(left, unrelated, basis: .commonAncestor) }
        await #expect(throws: GitInspectionFailure.multipleCommonAncestors) { _ = try await compare(mergeOne, mergeTwo, basis: .commonAncestor) }
        let earlierIndex = try Data(contentsOf: fixture.worktree.appendingPathComponent(".git/index"))
        let range = try await reader.readGitCommitRange(in: location, left: tips.selectedLeft, right: tips.right, scratch: fixture.scratch)
        #expect(range.left.commits.map(\.id) == [left] && range.right.commits.map(\.id) == [right])
        #expect(!range.isShallow && !range.left.hasMore && !range.right.hasMore)
        let mergeRange = try await reader.readGitCommitRange(in: location, left: mergeOne, right: left, scratch: fixture.scratch)
        let merge = try #require(mergeRange.left.commits.first)
        #expect(merge.id == mergeOne && merge.parents == [left, right] && mergeRange.right.commits.isEmpty)
        let folderHistory = try await reader.readGitFolderHistory(in: location, from: .object(mergeOne), wholeRepository: false,
            scratch: fixture.scratch)
        #expect(folderHistory.start == mergeOne && folderHistory.commits.map(\.id) == [mergeOne, left, base])
        #expect(folderHistory.commits.first?.parents == [left, right] && folderHistory.older == nil && !folderHistory.isShallow)
        let parentOne = try await reader.readGitCommitChanges(in: location, commit: merge, parent: left,
            wholeRepository: false, scratch: fixture.scratch)
        let parentTwo = try await reader.readGitCommitChanges(in: location, commit: merge, parent: right,
            wholeRepository: false, scratch: fixture.scratch)
        #expect(parentOne.parent == left && parentOne.summary.changes.count == 2)
        #expect(parentTwo.parent == right && parentTwo.summary.changes.isEmpty)
        await #expect(throws: GitInspectionFailure.revisionUnavailable) {
            try await reader.readGitCommitChanges(in: location, commit: merge, parent: base,
                wholeRepository: true, scratch: fixture.scratch)
        }
        let rootRange = try await reader.readGitCommitRange(in: location, left: unrelated, right: right, scratch: fixture.scratch)
        let root = try #require(rootRange.left.commits.first)
        #expect(root.id == unrelated && root.parents.isEmpty && root.canReviewChanges)
        let initial = try await reader.readGitCommitChanges(in: location, commit: root, parent: nil,
            wholeRepository: false, scratch: fixture.scratch)
        #expect(initial.parent == nil && initial.summary.changes.count == 2 && initial.summary.changes.allSatisfy { $0.kind == .added })
        try fixture.write(".git/shallow", Data((right.hex + "\n").utf8))
        let shallow = try await reader.readGitCommitRange(in: location, left: left, right: right, scratch: fixture.scratch)
        let boundary = try #require(shallow.right.commits.first)
        #expect(shallow.isShallow && boundary.id == right && !boundary.canReviewChanges)
        let shallowFolder = try await reader.readGitFolderHistory(in: location, from: .object(right), wholeRepository: false,
            scratch: fixture.scratch)
        #expect(shallowFolder.isShallow && shallowFolder.commits.map(\.id) == [right]
            && shallowFolder.commits.first?.canReviewChanges == false && shallowFolder.older == nil)
        await #expect(throws: GitInspectionFailure.revisionUnavailable) {
            try await reader.readGitCommitChanges(in: location, commit: boundary, parent: nil,
                wholeRepository: false, scratch: fixture.scratch)
        }
        #expect(try Data(contentsOf: fixture.worktree.appendingPathComponent(".git/index")) == earlierIndex)
        #expect(try fixture.head() == right)
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.scratch.path).isEmpty)
    }
}
