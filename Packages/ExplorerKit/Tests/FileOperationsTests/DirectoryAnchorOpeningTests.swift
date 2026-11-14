import Darwin
import Foundation
@testable import FileOperations
import Testing

private struct AnchorFixture {
    let root: URL
    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures", isDirectory: true)
        guard base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("anchor-opening-" + UUID().uuidString, isDirectory: true)
        guard mkdir(root.path, 0o700) == 0 else { throw posixFailure() }
    }
    func directory(_ name: String, in parent: URL? = nil) throws -> URL {
        let result = (parent ?? root).appendingPathComponent(name, isDirectory: true)
        guard mkdir(result.path, 0o700) == 0 else { throw posixFailure() }
        return result
    }
    func link(_ name: String, to target: URL) throws -> URL {
        let result = root.appendingPathComponent(name)
        guard symlink(target.path, result.path) == 0 else { throw posixFailure() }
        return result
    }
    func remove() throws { try FileManager().removeItem(at: root) }
}

@Suite(.serialized) struct DirectoryAnchorOpeningTests {
    @Test func nativeOpenKeepsIdentityAndCloseOnExec() throws {
        let fixture = try AnchorFixture(); defer { try? fixture.remove() }
        let native = Darwin.open(fixture.root.path, O_SEARCH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        try #require(native >= 0, "Native no-symlink open must succeed without fallback on this runtime.")
        defer { close(native) }
        let anchor = try DirectoryAnchor(fixture.root, resolve: false)
        #expect(try EntrySnapshot(fd: native).sameObject(as: anchor.identity))
        #expect(fcntl(anchor.fd, F_GETFD) & FD_CLOEXEC != 0)
        #expect(try EntrySnapshot(fd: anchor.fd).sameObject(as: anchor.identity))
        try anchor.validate()
    }

    @Test func ancestorAndFinalSymlinksAreRefused() throws {
        let fixture = try AnchorFixture(); defer { try? fixture.remove() }
        let target = try fixture.directory("target")
        _ = try fixture.directory("leaf", in: target)
        let link = try fixture.link("link", to: target)
        #expect(throws: FileOperationFailure.self) { _ = try DirectoryAnchor(link, resolve: false) }
        #expect(throws: FileOperationFailure.self) {
            _ = try DirectoryAnchor(link.appendingPathComponent("leaf"), resolve: false)
        }
        // Explicit canonicalization retains its existing, separate behavior.
        #expect(try DirectoryAnchor(link).identity.sameObject(as: DirectoryAnchor(target).identity))
    }

    @Test func unsupportedFlagAndLongPathErrorsRetainComponentWalk() throws {
        let fixture = try AnchorFixture(); defer { try? fixture.remove() }
        let expected = try DirectoryAnchor(fixture.root, resolve: false).identity
        for failure in [ENAMETOOLONG, EINVAL, ENOTSUP, EOPNOTSUPP] {
            var calls = 0
            let fd = try DirectoryAnchor.openDescriptor(fixture.root) { _, flags in
                calls += 1
                #expect(flags & O_NOFOLLOW_ANY != 0)
                #expect(flags & O_NOFOLLOW == 0)
                #expect(flags & O_SEARCH != 0)
                errno = failure
                return -1
            }
            defer { close(fd) }
            #expect(calls == 1)
            #expect(try EntrySnapshot(fd: fd).sameObject(as: expected))
            #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
        }
        let target = try fixture.directory("target")
        let link = try fixture.link("link", to: target)
        #expect(throws: FileOperationFailure.self) {
            _ = try DirectoryAnchor.openDescriptor(link) { _, _ in errno = EINVAL; return -1 }
        }
    }

    @Test func refusalsNeverFallBackToSuccessfulComponentWalk() throws {
        let fixture = try AnchorFixture(); defer { try? fixture.remove() }
        // The fixture is accessible, so a fallback would incorrectly turn each refusal into success.
        for failure in [ELOOP, EACCES, EPERM, ENOENT, ENOTDIR, EMFILE, EIO] {
            #expect(throws: posixFailure(failure)) {
                _ = try DirectoryAnchor.openDescriptor(fixture.root) { _, _ in errno = failure; return -1 }
            }
        }
    }

    @Test(.enabled(if: geteuid() != 0, "Root bypasses mode-bit denial; search/read permission parity needs a non-root worker."))
    func searchOnlyAncestorsAndFinalDirectoryRetainPermissionAdmission() throws {
        let fixture = try AnchorFixture(); defer { try? fixture.remove() }
        let parent = try fixture.directory("search-only")
        let leaf = try fixture.directory("leaf", in: parent)
        guard chmod(parent.path, 0o111) == 0, chmod(leaf.path, 0o111) == 0 else { throw posixFailure() }
        defer { _ = chmod(parent.path, 0o700); _ = chmod(leaf.path, 0o700) }
        let read = Darwin.open(leaf.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        let readError = errno
        if read >= 0 { close(read) }
        try #require(read < 0 && readError == EACCES, "Fixture must exercise actual read denial.")
        let anchor = try DirectoryAnchor(leaf, resolve: false)
        try anchor.validate()
        guard chmod(parent.path, 0o000) == 0 else { throw posixFailure() }
        #expect(throws: FileOperationFailure.accessDenied) { try anchor.validate() }
    }

    @Test func pathsBeyondNativeLimitRetainDescriptorTraversal() throws {
        let fixture = try AnchorFixture(); defer { try? fixture.remove() }
        let root = try DirectoryAnchor(fixture.root, resolve: false)
        var chain: [(parent: Int32, name: String, fd: Int32)] = []
        defer {
            for item in chain.reversed() {
                close(item.fd)
                _ = unlinkat(item.parent, item.name, AT_REMOVEDIR)
            }
        }
        var parent = root.fd, url = fixture.root
        for index in 0..<20 {
            if url.path.utf8.count > Int(PATH_MAX) + 80 { break }
            let name = "level-\(index)-" + String(repeating: "x", count: 80)
            guard mkdirat(parent, name, 0o700) == 0 else { throw posixFailure() }
            let opened = openat(parent, name, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard opened >= 0 else { throw posixFailure() }
            chain.append((parent, name, opened)); parent = opened
            url.appendPathComponent(name, isDirectory: true)
        }
        try #require(url.path.utf8.count > Int(PATH_MAX))
        let direct = Darwin.open(url.path, O_SEARCH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        let directError = errno
        if direct >= 0 { close(direct) }
        try #require(direct < 0 && directError == ENAMETOOLONG)
        print("ANCHOR_LONG_PATH_PROOF bytes=\(url.path.utf8.count) nativeLimit=\(PATH_MAX) components=\(chain.count) directErrno=\(directError)")
        let anchor = try DirectoryAnchor(url, resolve: false)
        #expect(try EntrySnapshot(fd: parent).sameObject(as: anchor.identity))
        try anchor.validate()
    }

    @Test func parentRenameReplacementAndSymlinkStayGuarded() throws {
        let fixture = try AnchorFixture(); defer { try? fixture.remove() }
        let parent = try fixture.directory("parent")
        let leaf = try fixture.directory("leaf", in: parent)
        let anchor = try DirectoryAnchor(leaf, resolve: false)
        let retired = fixture.root.appendingPathComponent("retired", isDirectory: true)
        guard rename(parent.path, retired.path) == 0 else { throw posixFailure() }
        #expect(throws: FileOperationFailure.notFound) { try anchor.validate() }
        _ = try fixture.directory("parent")
        _ = try fixture.directory("leaf", in: parent)
        #expect(throws: FileOperationFailure.destinationChanged) { try anchor.validate() }
        #expect(try EntrySnapshot(fd: anchor.fd).sameObject(as: anchor.identity))
        try FileManager().removeItem(at: parent)
        guard symlink(retired.path, parent.path) == 0 else { throw posixFailure() }
        #expect(throws: FileOperationFailure.self) { try anchor.validate() }
    }

    @Test func existingMountAndFirmlinkPathsRetainIdentity() throws {
        let fixture = try AnchorFixture(); defer { try? fixture.remove() }
        // Metadata-only checks of fixed system directories; no enumeration or shared mutations.
        for path in ["/", "/Volumes", "/System/Volumes/Data/Volumes", fixture.root.path] {
            let native = Darwin.open(path, O_SEARCH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            try #require(native >= 0, "Native lookup must handle the fixed mount/firmlink routes directly.")
            close(native)
        }
        let root = try DirectoryAnchor(URL(fileURLWithPath: "/", isDirectory: true), resolve: false)
        let mountedFixture = try DirectoryAnchor(fixture.root, resolve: false)
        try root.validate(); try mountedFixture.validate()
        let volumes = try DirectoryAnchor(URL(fileURLWithPath: "/Volumes", isDirectory: true), resolve: false)
        let dataVolumes = try DirectoryAnchor(URL(fileURLWithPath: "/System/Volumes/Data/Volumes", isDirectory: true), resolve: false)
        #expect(volumes.identity.sameObject(as: dataVolumes.identity))
        print("ANCHOR_MOUNT_PROOF nativePaths=4 firmlinkIdentityMatch=\(volumes.identity.sameObject(as: dataVolumes.identity)) fixtureCrossesRootDevice=\(root.identity.device != mountedFixture.identity.device)")
        try volumes.validate(); try dataVolumes.validate()
    }
}
