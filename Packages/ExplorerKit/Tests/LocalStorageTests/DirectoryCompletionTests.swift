import Darwin
import ExplorerCore
import Foundation
import Testing
@testable import LocalStorage

private struct CompletionFixture {
    let root: URL
    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? package.appendingPathComponent(".build/test-fixtures")
        root = base.appendingPathComponent("completion-" + UUID().uuidString)
        guard root.pathComponents.contains(".build"), root == root.resolvingSymlinksInPath() else { throw AddressCompletionError.invalidPath }
        try FileManager().createDirectory(at: root, withIntermediateDirectories: true)
    }
    func folder(_ name: String) throws { try FileManager().createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false) }
    func remove() { try? FileManager().removeItem(at: root) }
    func request(_ suffix: String = "") throws -> AddressCompletionRequest {
        try AddressCompletionRequest(text: root.path + "/" + suffix, home: root)
    }
}
private func collect(_ session: DirectoryCompletionSession) async throws -> DirectoryCompletionResult {
    for try await result in session.results { return result }
    throw LocalStorageError.unavailable
}

@Test func familiarFolderHintsRequireFreshDirectoriesAndDoNotFollowLinksOrPackages() async throws {
    let fixture = try CompletionFixture(); defer { fixture.remove() }
    for name in ["Downloads", "Other", "Hidden.app", ".ssh"] { try fixture.folder(name) }
    try FileManager().createSymbolicLink(at: fixture.root.appendingPathComponent("Alias"), withDestinationURL: fixture.root.appendingPathComponent("Downloads"))
    try Data("BODY_SENTINEL".utf8).write(to: fixture.root.appendingPathComponent("Not a folder"))
    let locations = ["Downloads", "Alias", "Missing", "Hidden.app", ".ssh", "Not a folder"].map {
        FolderNameLocation(name: "Downloads", url: fixture.root.appendingPathComponent($0), source: .familiar)
    }
    let service = DirectoryCompletionService()
    let value = try await collect(service.startLocations(owner: UUID(), request: try FolderNameRequest(text: "Down"), locations: locations))
    #expect(value.suggestions.count == 1 && value.suggestions.first?.url.lastPathComponent == "Downloads")
    #expect(value.suggestions.first?.source == .familiar)
    try FileManager().removeItem(at: fixture.root.appendingPathComponent("Downloads"))
    let after = try await collect(service.startLocations(owner: UUID(), request: try FolderNameRequest(text: "Down"), locations: locations))
    #expect(after.suggestions.isEmpty)
}

@Test func completionObservesOneLevelWithoutBodiesPackagesOrLinks() async throws {
    let fixture = try CompletionFixture(); defer { fixture.remove() }
    for name in ["Documents", "Downloads", "Café 文件", ".hidden", "Example.app"] { try fixture.folder(name) }
    try fixture.folder("Nested")
    try FileManager().createDirectory(at: fixture.root.appendingPathComponent("Nested/Secret child"), withIntermediateDirectories: false)
    try FileManager().createSymbolicLink(at: fixture.root.appendingPathComponent("Folder link"), withDestinationURL: fixture.root.appendingPathComponent("Documents"))
    try Data("BODY_SENTINEL".utf8).write(to: fixture.root.appendingPathComponent("Ordinary.txt"))
    let service = DirectoryCompletionService()
    let result = try await collect(service.start(owner: UUID(), request: fixture.request()))
    #expect(Set(result.suggestions.map(\.name)) == ["Documents", "Downloads", "Café 文件", "Nested"])
    #expect(!result.isTruncated && result.observedEntries == 8)
    let hidden = try await collect(service.start(owner: UUID(), request: fixture.request(".")))
    #expect(hidden.suggestions.map(\.name) == [".hidden"])
    let typo = try await collect(service.start(owner: UUID(), request: fixture.request("Documnts")))
    #expect(typo.suggestions.first?.name == "Documents" && typo.suggestions.first?.match == .approximate)
}

@Test func completionReportsTruncationMissingAndSymlinkParentsHonestly() async throws {
    let fixture = try CompletionFixture(); defer { fixture.remove() }
    for i in 0..<20 { try fixture.folder("Folder \(i)") }
    let service = DirectoryCompletionService()
    let result = try await collect(service.start(owner: UUID(), request: fixture.request(), policy: .init(maximumEntries: 5)))
    #expect(result.isTruncated && result.observedEntries == 5 && result.suggestions.count <= 5)
    for parent in ["Missing", "Alias"] {
        if parent == "Alias" { try FileManager().createSymbolicLink(at: fixture.root.appendingPathComponent(parent), withDestinationURL: fixture.root) }
        await #expect(throws: (any Error).self) {
            _ = try await collect(service.start(owner: UUID(), request: fixture.request(parent + "/")))
        }
    }
}

private final class CompletionGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func hold() { entered.signal(); release.wait() }
    func waitForEntry() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: self.entered.wait(timeout: .now() + 2) == .success) }
        }
    }
}
private final class CompletionLifetime: @unchecked Sendable {}
private final class WeakCompletionLifetime: @unchecked Sendable { weak var value: CompletionLifetime?; init(_ value: CompletionLifetime) { self.value = value } }

@Test func completionCancellationCoalescesAndKeepsRealActivityUntilWorkerDrains() async throws {
    let fixture = try CompletionFixture(); defer { fixture.remove() }
    try fixture.folder("Newest")
    let gate = CompletionGate(), activity = FileActivityGate()
    let service = DirectoryCompletionService(activityGate: activity, beforeEnumeration: { gate.hold() })
    var lifetime: CompletionLifetime? = CompletionLifetime()
    let weakLifetime = WeakCompletionLifetime(lifetime!)
    let owner = UUID()
    let first = service.start(owner: owner, request: try fixture.request(), retaining: lifetime)
    lifetime = nil
    #expect(await gate.waitForEntry())
    first.cancel()
    #expect(activity.activeCount == 1 && weakLifetime.value != nil)
    let second = service.start(owner: owner, request: try fixture.request())
    #expect(await gate.waitForEntry())
    var latest: DirectoryCompletionSession?
    for _ in 0..<100 { latest?.cancel(); latest = service.start(owner: owner, request: try fixture.request("New")) }
    #expect(service.pendingCount == 1)
    let drain = try #require(activity.closeAdmission())
    #expect(!activity.ownsDrainedAdmission(drain))
    second.cancel(); latest?.cancel()
    gate.release.signal(); gate.release.signal()
    #expect(await activity.waitUntilDrained(drain))
    #expect(activity.activeCount == 0)
    #expect(activity.reopen(drain))
}

@Test func completionClosedActivityGatePerformsNoFilesystemWork() async throws {
    let fixture = try CompletionFixture(); defer { fixture.remove() }
    let activity = FileActivityGate(), service = DirectoryCompletionService(activityGate: activity)
    let token = try #require(activity.closeAdmission())
    await #expect(throws: FileActivityError.self) { _ = try await collect(service.start(owner: UUID(), request: fixture.request())) }
    #expect(activity.activeCount == 0 && activity.reopen(token))
}

@Test func completionDenialAndParentReplacementNeverPublishEmptySuccess() async throws {
    let fixture = try CompletionFixture(); defer { fixture.remove() }
    try fixture.folder("Denied"); try fixture.folder("Parent")
    let denied = fixture.root.appendingPathComponent("Denied")
    if geteuid() != 0 {
        try FileManager().setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager().setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        await #expect(throws: LocalStorageError.self) {
            _ = try await collect(DirectoryCompletionService().start(owner: UUID(), request: fixture.request("Denied/")))
        }
    }
    let parent = fixture.root.appendingPathComponent("Parent"), old = fixture.root.appendingPathComponent("Old Parent")
    let service = DirectoryCompletionService(activityGate: nil, beforeEnumeration: nil, afterDirectoryOpened: {
        try? FileManager().moveItem(at: parent, to: old)
        try? FileManager().createDirectory(at: parent, withIntermediateDirectories: false)
    })
    await #expect(throws: LocalStorageError.self) {
        _ = try await collect(service.start(owner: UUID(), request: fixture.request("Parent/")))
    }
    #expect(FileManager().fileExists(atPath: old.path) && FileManager().fileExists(atPath: parent.path))
}

@Test func completionDoesNotEnumerateCredentialScopes() async throws {
    let fixture = try CompletionFixture(); defer { fixture.remove() }
    try fixture.folder(".ssh"); try fixture.folder(".hidden")
    let service = DirectoryCompletionService()
    let result = try await collect(service.start(owner: UUID(), request: fixture.request(".")))
    #expect(result.suggestions.map(\.name) == [".hidden"])
    await #expect(throws: LocalStorageError.self) {
        _ = try await collect(service.start(owner: UUID(), request: fixture.request(".ssh/")))
    }
    #expect(AutomaticMetadataPolicy.excludes(URL(fileURLWithPath: "/Example/.AWS/subfolder")))
    #expect(!AutomaticMetadataPolicy.excludes(URL(fileURLWithPath: "/Example/Ordinary")))
}
