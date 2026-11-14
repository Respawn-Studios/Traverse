import Darwin
import ExplorerCore
import Foundation
import Testing
@testable import LocalStorage

private func smbFacts(path: String = "/Volumes/Generated SMB", source: String = "//fixture@server/share",
                      type: String = "smbfs", flags: UInt32 = UInt32(MNT_RDONLY), device: Int64 = 51,
                      inode: UInt64 = 2, generation: UInt32 = 1, birth: Int64 = 4,
                      kind: UInt16 = UInt16(S_IFDIR), fsid: Int32 = 41, extra: Int32 = 42) -> SMBMountObservation {
    .init(object: .init(device: device, inode: inode, generation: generation, kind: kind, birthSeconds: birth),
          fileSystemID: fsid, fileSystemIDExtra: extra, flags: flags,
          fileSystem: Data(type.utf8), root: Data(path.utf8), source: Data(source.utf8))
}

struct SMBMountObservationTests {
    @Test func lexicalAdmissionDoesNotRepairRemoteOrAmbiguousPaths() throws {
        let path = try SMBMountPath(URL(fileURLWithPath: "/Volumes/Generated SMB", isDirectory: true))
        #expect(path.path == "/Volumes/Generated SMB" && path.bytes == Data(path.path.utf8))
        // Foundation's filesystem standardizer can rewrite /private/tmp to
        // /tmp. Lexical admission must retain the native mount's exact spelling
        // without resolving ancestors or doing filesystem work on the caller.
        let privatePath = "/private/tmp/macexplorer-generated/mount"
        let privateRoot = try SMBMountPath(URL(fileURLWithPath: privatePath, isDirectory: true))
        #expect(privateRoot.path == privatePath && privateRoot.bytes == Data(privatePath.utf8))
        let existingPrivateRoot = try SMBMountPath(URL(fileURLWithPath: "/private/tmp", isDirectory: true))
        #expect(existingPrivateRoot.path == "/private/tmp")
        #expect(String(describing: path) == "SMB mount path")
        #expect(String(reflecting: path) == "SMB mount path")
        let rejected = ["smb://server/share", "file://server/share", "file://localhost/Volumes/share", "file://user@localhost/Volumes/share",
            "file:///Volumes/share?query=1", "file:///Volumes/share#fragment", "file:///Volumes/../share", "file:///Volumes/./share",
            "file:///Volumes//share", "file:///", "file:///.file/id=1", "file:///Volumes/share%00", "file:///Volumes/share%0A"]
        for (index, text) in rejected.enumerated() {
            let url = try #require(URL(string: text))
            #expect(throws: SMBConnectionProblem.invalidResult, "Generated lexical case \(index)") { try SMBMountPath(url) }
        }
        #expect(throws: SMBConnectionProblem.invalidResult) { try SMBMountPath(URL(fileURLWithPath: "/" + String(repeating: "x", count: 4095))) }
        let relative = try #require(URL(string: "child", relativeTo: URL(fileURLWithPath: "/Volumes/share")))
        #expect(throws: SMBConnectionProblem.invalidResult) { try SMBMountPath(relative) }
    }
    @Test func onlyExactReadOnlyNetworkMountRootIsAccepted() throws {
        let path = try SMBMountPath(URL(fileURLWithPath: "/Volumes/Generated SMB")), value = smbFacts()
        #expect(try SMBMountObservation.admitted(root: path, first: value, reopened: value, last: value) == value)
        #expect(String(describing: value) == "SMB mount observation")
        #expect(String(reflecting: value) == "SMB mount observation")
        #expect(throws: SMBConnectionProblem.writableMount) { try smbFacts(flags: 0).validate(root: path) }
        for value in [smbFacts(type: "apfs"), smbFacts(type: "SMBFS"), smbFacts(type: "nfs"),
                      smbFacts(flags: UInt32(MNT_RDONLY | MNT_LOCAL))] {
            #expect(throws: SMBConnectionProblem.notSMB) { try value.validate(root: path) }
        }
    }
    @Test func subdirectoriesMissingFactsAndUnboundedSourcesRefuse() throws {
        let path = try SMBMountPath(URL(fileURLWithPath: "/Volumes/Generated SMB"))
        for value in [smbFacts(path: "/Volumes"), smbFacts(path: "/Volumes/Generated SMB/child"),
                      smbFacts(inode: 0), smbFacts(kind: UInt16(S_IFREG)), smbFacts(source: ""),
                      smbFacts(source: "server/share"), smbFacts(source: "//"), smbFacts(source: "//x\0tail"),
                      smbFacts(source: "//" + String(repeating: "x", count: 4094))] {
            #expect(throws: SMBConnectionProblem.invalidResult) { try value.validate(root: path) }
        }
        let decomposed = "/Volumes/Cafe\u{301}"
        let composed = "/Volumes/Caf\u{e9}"
        #expect(decomposed == composed)
        let exact = try SMBMountPath(URL(fileURLWithPath: decomposed))
        #expect(throws: SMBConnectionProblem.invalidResult) { try smbFacts(path: composed).validate(root: exact) }
    }
    @Test func everyIdentityAndFilesystemChangeRejectsTheSnapshot() throws {
        let path = try SMBMountPath(URL(fileURLWithPath: "/Volumes/Generated SMB")), first = smbFacts()
        for changed in [smbFacts(device: 52), smbFacts(inode: 3), smbFacts(generation: 2), smbFacts(birth: 5),
                        smbFacts(fsid: 51), smbFacts(extra: 52), smbFacts(flags: UInt32(MNT_RDONLY | MNT_NOSUID)),
                        smbFacts(source: "//fixture@server/other")] {
            #expect(throws: SMBConnectionProblem.changed) { try SMBMountObservation.admitted(root: path, first: first, reopened: changed, last: first) }
            #expect(throws: SMBConnectionProblem.changed) { try SMBMountObservation.admitted(root: path, first: first, reopened: first, last: changed) }
        }
        let a = smbFacts(source: "//fixture@server/Caf\u{e9}"), b = smbFacts(source: "//fixture@server/Cafe\u{301}")
        #expect(a != b)
        #expect(throws: SMBConnectionProblem.changed) { try SMBMountObservation.admitted(root: path, first: a, reopened: b, last: a) }
    }
    @Test func cancellationRetainsActualWorkerLeaseAndBoundedAdmission() async throws {
        let hold = SMBProbeHold(), activity = FileActivityGate()
        let observer = SMBMountObserver(activity: activity, probe: { path in
            hold.enter(); return smbFacts(path: path.path)
        })
        let url = URL(fileURLWithPath: "/Volumes/Generated SMB")
        var lifetime: SMBProbeLifetime? = SMBProbeLifetime()
        let weakLifetime = SMBWeakLifetime(lifetime!)
        let first = Task { [retained = lifetime] in try await observer.observe(url, retaining: retained) }
        lifetime = nil
        defer { for _ in 0..<4 { hold.release.signal() } }
        try await smbWait { hold.calls == 1 }
        let queued = (0..<3).map { _ in Task { try await observer.observe(url) } }
        try await smbWait { observer.outstandingCount == 4 }
        await #expect(throws: SMBConnectionProblem.busy) { try await observer.observe(url) }
        first.cancel(); queued.forEach { $0.cancel() }
        let token = try #require(activity.closeAdmission())
        #expect(observer.outstandingCount == 4 && activity.activeCount == 1 && !activity.ownsDrainedAdmission(token))
        #expect(weakLifetime.value != nil)
        hold.release.signal()
        await #expect(throws: CancellationError.self) { try await first.value }
        for task in queued { await #expect(throws: CancellationError.self) { try await task.value } }
        #expect(await activity.waitUntilDrained(token))
        #expect(observer.outstandingCount == 0 && activity.activeCount == 0 && hold.calls == 1)
        try await smbWait { weakLifetime.value == nil }
        #expect(activity.reopen(token))
    }
    @Test func closedGateAndInvalidURLsNeverReachTheNativeProbe() async throws {
        let activity = FileActivityGate(), hold = SMBProbeHold()
        let observer = SMBMountObserver(activity: activity, probe: { _ in hold.count(); return smbFacts() })
        let token = try #require(activity.closeAdmission())
        await #expect(throws: FileActivityError.admissionClosed) { try await observer.observe(URL(fileURLWithPath: "/Volumes/Generated SMB")) }
        await #expect(throws: SMBConnectionProblem.invalidResult) { try await observer.observe(URL(string: "smb://server/share")!) }
        #expect(hold.calls == 0 && observer.outstandingCount == 0 && activity.activeCount == 0 && activity.reopen(token))
    }
    @Test func workerFailureReleasesAdmissionAndDoesNotPublishAnObservation() async throws {
        let activity = FileActivityGate(), hold = SMBProbeHold()
        let observer = SMBMountObserver(activity: activity, probe: { _ in hold.count(); throw SMBConnectionProblem.unavailable })
        for _ in 0..<6 { await #expect(throws: SMBConnectionProblem.unavailable) { try await observer.observe(URL(fileURLWithPath: "/Volumes/Generated SMB")) } }
        #expect(observer.outstandingCount == 0 && activity.activeCount == 0 && hold.calls == 6)
    }
    @Test func realGeneratedLocalDirectoryAndSymlinkCannotBecomeSMBProof() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let leaf = root.appendingPathComponent("Generated folder")
        try FileManager().createDirectory(at: leaf, withIntermediateDirectories: true)
        try Data("MacExplorer B10 mount-admission fixture v1".utf8).write(to: root.appendingPathComponent("marker"), options: .withoutOverwriting)
        let link = root.appendingPathComponent("Link")
        try FileManager().createSymbolicLink(at: link, withDestinationURL: leaf)
        let observer = SMBMountObserver()
        await #expect(throws: SMBConnectionProblem.invalidResult) { try await observer.observe(leaf) }
        await #expect(throws: SMBConnectionProblem.unavailable) { try await observer.observe(link) }
        #expect(observer.outstandingCount == 0 && FileManager().fileExists(atPath: leaf.path))
    }
}

private final class SMBProbeHold: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    let release = DispatchSemaphore(value: 0)
    var calls: Int { lock.withLock { value } }
    func count() { lock.withLock { value += 1 } }
    func enter() { count(); release.wait() }
}
private final class SMBProbeLifetime: Sendable {}
private final class SMBWeakLifetime: @unchecked Sendable {
    weak var value: SMBProbeLifetime?
    init(_ value: SMBProbeLifetime) { self.value = value }
}
private func smbWait(_ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !condition() {
        if ProcessInfo.processInfo.systemUptime > deadline { throw SMBConnectionProblem.unavailable }
        try await Task.sleep(for: .milliseconds(5))
    }
}
