import Darwin
import Foundation
import XCTest
import SSHConfiguration
@testable import LocalStorage

final class SSHConfigurationImportTests: XCTestCase, @unchecked Sendable {
    private func fixture(_ label: String) throws -> URL {
        let path = try LocalStorageTestFixtures.directory()
            .appendingPathComponent(label + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return path
    }
    private func write(_ text: String, _ url: URL) throws {
        try Data(text.utf8).write(to: url, options: [.withoutOverwriting]); XCTAssertEqual(chmod(url.path, 0o600), 0)
    }
    func testExplicitDirectoryIncludesAndFreshReplacementDetection() async throws {
        let base = try fixture("includes"), ssh = base.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let config = ssh.appendingPathComponent("config"), include = ssh.appendingPathComponent("work.conf")
        try write("Host studio\n Include *.conf\n User fixture\n", config)
        try write("Host *\n HostName generated.example\n Port 2222\n", include)
        let reader = SSHConfigurationReader()
        let snapshot = try await reader.load(selected: config, authorizedDirectory: ssh, userSSHDirectory: ssh)
        let profile = try snapshot.configuration.resolve("studio")
        XCTAssertEqual(profile.host, "generated.example"); XCTAssertEqual(profile.port, 2222)
        XCTAssertTrue(profile.requirements.isEmpty)
        try await reader.revalidate(snapshot)
        // Atomic editor replacement with equal size remains a changed source.
        let replacement = ssh.appendingPathComponent("replacement")
        try write("Host *\n HostName different.example\n Port 2222\n", replacement)
        XCTAssertEqual(rename(replacement.path, include.path), 0)
        do { try await reader.revalidate(snapshot); XCTFail("Replaced input accepted") }
        catch { XCTAssertEqual(error as? SSHSelectedFileFailure, .changed) }
    }
    func testSelectedFileDoesNotAcquireItsParentAndOutsideIncludeCannotEscape() async throws {
        let base = try fixture("authority"), config = base.appendingPathComponent("config")
        try write("Host studio\n Include secret.conf\n HostName generated.example\n", config)
        try write("User fixture\n", base.appendingPathComponent("secret.conf"))
        let reader = SSHConfigurationReader()
        let fileOnly = try await reader.load(selected: config, authorizedDirectory: nil, userSSHDirectory: base)
        XCTAssertTrue(try fileOnly.configuration.resolve("studio").requirements.contains(.includedConfiguration))
        let escaped = base.appendingPathComponent("escape")
        try write("Host studio\n Include ../config\n HostName generated.example\n", escaped)
        let result = try await reader.load(selected: escaped, authorizedDirectory: base, userSSHDirectory: base)
        XCTAssertTrue(try result.configuration.resolve("studio").requirements.contains(.includedConfiguration))
    }
    func testSymlinkHardlinkFIFOAndUnsafePermissionsAreRefused() async throws {
        let base = try fixture("kinds"), config = base.appendingPathComponent("config")
        try write("Host studio\n HostName generated.example\n", config)
        let reader = SSHConfigurationReader()
        let symlinkURL = base.appendingPathComponent("link"), fifo = base.appendingPathComponent("fifo")
        XCTAssertEqual(symlink(config.path, symlinkURL.path), 0); XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        for url in [symlinkURL, fifo] {
            do { _ = try await reader.load(selected: url, authorizedDirectory: base, userSSHDirectory: base); XCTFail("Nonregular selection accepted") }
            catch { XCTAssertTrue(error is SSHSelectedFileFailure) }
        }
        XCTAssertEqual(chmod(config.path, 0o666), 0)
        do { _ = try await reader.load(selected: config, authorizedDirectory: base, userSSHDirectory: base); XCTFail("Writable foreign input accepted") }
        catch { XCTAssertEqual(error as? SSHSelectedFileFailure, .permissions) }
        XCTAssertEqual(chmod(config.path, 0o600), 0)
        XCTAssertEqual(link(config.path, base.appendingPathComponent("hardlink").path), 0)
        do { _ = try await reader.load(selected: config, authorizedDirectory: base, userSSHDirectory: base); XCTFail("Hard-linked input accepted") }
        catch { XCTAssertEqual(error as? SSHSelectedFileFailure, .unsupported) }
    }
    func testAuthorizedEmptyGlobDiffersFromMissingAndAddedIncludeInvalidatesSnapshot() async throws {
        let base = try fixture("empty"), config = base.appendingPathComponent("config")
        try write("Host studio\n Include *.conf\n HostName generated.example\n", config)
        let reader = SSHConfigurationReader()
        let first = try await reader.load(selected: config, authorizedDirectory: base, userSSHDirectory: base)
        XCTAssertTrue(try first.configuration.resolve("studio").requirements.isEmpty)
        try write("User fixture\n", base.appendingPathComponent("new.conf"))
        do { try await reader.revalidate(first); XCTFail("Added applicable input accepted") }
        catch { XCTAssertEqual(error as? SSHSelectedFileFailure, .changed) }
    }
    func testByteLimitAndCyclesAreBounded() async throws {
        let base = try fixture("limits"), config = base.appendingPathComponent("config")
        try write(String(repeating: "#", count: (256 << 10) + 1), config)
        let reader = SSHConfigurationReader()
        do { _ = try await reader.load(selected: config, authorizedDirectory: base, userSSHDirectory: base); XCTFail("Oversized config accepted") }
        catch { XCTAssertEqual(error as? SSHSelectedFileFailure, .capacity) }
        let cycle = base.appendingPathComponent("cycle")
        try write("Host studio\n Include cycle\n", cycle)
        let snapshot = try await reader.load(selected: cycle, authorizedDirectory: base, userSSHDirectory: base)
        XCTAssertEqual(snapshot.profiles.first?.failure, .includeCycle)
    }
    func testCancellationWaitsForActualReadScopeAndRefusesConcurrentAdmission() async throws {
        final class Counts: @unchecked Sendable {
            let lock = NSLock(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            var starts = 0, stops = 0
            func start() -> Bool { lock.withLock { starts += 1 }; entered.signal(); _ = release.wait(timeout: .now() + 5); return true }
            func stop() { lock.withLock { stops += 1 } }
            func awaitEntry() -> Bool { entered.wait(timeout: .now() + 3) == .success }
        }
        let base = try fixture("cancel"), config = base.appendingPathComponent("config")
        try write("Host studio\n HostName generated.example\n", config)
        let counts = Counts(), reader = SSHConfigurationReader(hooks: .init(start: { _ in counts.start() }, stop: { _ in counts.stop() }))
        let task = Task { try await reader.load(selected: config, authorizedDirectory: base, userSSHDirectory: base) }
        let entered = await Task.detached { counts.awaitEntry() }.value
        XCTAssertTrue(entered)
        do { _ = try await reader.load(selected: config, authorizedDirectory: base, userSSHDirectory: base); XCTFail("Concurrent import admitted") }
        catch { XCTAssertEqual(error as? SSHSelectedFileFailure, .busy) }
        task.cancel(); XCTAssertEqual(counts.lock.withLock { counts.stops }, 0)
        counts.release.signal()
        do { _ = try await task.value; XCTFail("Cancelled import published") }
        catch { XCTAssertEqual(error as? SSHSelectedFileFailure, .stopped) }
        XCTAssertEqual(counts.lock.withLock { counts.starts }, 1); XCTAssertEqual(counts.lock.withLock { counts.stops }, 1)
    }
}
