import Darwin
import ExplorerCore
import Foundation
import Testing

@testable import LocalStorage

private struct SequenceFixture {
    let root: URL
    init() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base =
            ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? repo.appendingPathComponent(".build/test-fixtures")
        guard base.path.hasPrefix(repo.path + "/"), base.resolvingSymlinksInPath() == base else {
            throw LocalStorageError.unavailable
        }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("storage-sequence-" + UUID().uuidString)
        try FileManager().createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func path(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
}

struct PrivateStateDirectorySequenceTests {
    @Test func knownTwoLevelPreparationIsInertThenPrivateAndRepeatable() async throws {
        let f = try SequenceFixture()
        let support = f.path("Application Support")
        let state = support.appendingPathComponent("local.generated")
        let sequence = try PrivateStateDirectorySequence(directories: [support, state])
        #expect(!FileManager().fileExists(atPath: support.path))
        async let one: Void = sequence.prepare()
        async let two: Void = sequence.prepare()
        _ = try await (one, two)
        for path in [support, state] {
            var facts = stat()
            #expect(lstat(path.path, &facts) == 0 && facts.st_mode & 0o777 == 0o700)
        }
        let marker = state.appendingPathComponent("preserved.txt")
        let data = Data("Generated preserved metadata".utf8)
        try data.write(to: marker, options: .withoutOverwriting)
        try await Task.detached { try sequence.prepareFromBackgroundThread() }.value
        #expect(try Data(contentsOf: marker) == data)
    }
    @Test func refusesGapsLinksAndReplacedNamespaceWithoutRepair() async throws {
        let f = try SequenceFixture()
        let support = f.path("Support")
        let state = support.appendingPathComponent("local.generated")
        #expect(throws: StateDirectoryPreparationError.invalidLocation) {
            try PrivateStateDirectorySequence(directories: [support, state.appendingPathComponent("gap")])
        }
        let sequence = try PrivateStateDirectorySequence(directories: [support, state])
        try await sequence.prepare()
        let retained = support.appendingPathComponent("retained")
        try FileManager().moveItem(at: state, to: retained)
        try FileManager().createDirectory(at: state, withIntermediateDirectories: false)
        await #expect(throws: StateDirectoryPreparationError.changed) { try await sequence.prepare() }
        #expect(FileManager().fileExists(atPath: retained.path))
        let target = f.path("Target")
        let link = f.path("Link")
        try FileManager().createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager().createSymbolicLink(at: link, withDestinationURL: target)
        let linked = try PrivateStateDirectorySequence(directories: [link, link.appendingPathComponent("uncreated")])
        await #expect(throws: (any Error).self) { try await linked.prepare() }
        #expect(!FileManager().fileExists(atPath: target.appendingPathComponent("uncreated").path))
    }
    @Test func backgroundEntryRefusesMainAndClosedAdmissionCreatesNothing() async throws {
        let f = try SequenceFixture()
        let root = f.path("State")
        let gate = FileActivityGate()
        let sequence = try PrivateStateDirectorySequence(directories: [root], activity: gate)
        _ = await MainActor.run {
            #expect(throws: StateDirectoryPreparationError.requiresBackgroundWorker) {
                try sequence.prepareFromBackgroundThread()
            }
        }
        let token = try #require(gate.closeAdmission())
        await #expect(throws: FileActivityError.admissionClosed) { try await sequence.prepare() }
        #expect(!FileManager().fileExists(atPath: root.path) && gate.activeCount == 0)
        #expect(gate.reopen(token))
        try await sequence.prepare()
        #expect(gate.activeCount == 0)
    }
    @Test func decodedNulAndURLDecorationsCannotCreateTruncatedState() async throws {
        let f = try SequenceFixture()
        let safe = f.path("Uncreated")
        for suffix in ["%00tail", "?query", "#fragment"] {
            let url = try #require(URL(string: safe.absoluteString + suffix))
            await #expect(throws: StateDirectoryPreparationError.invalidLocation) {
                try await PrivateStateDirectory(directory: url).prepare()
            }
        }
        #expect(!FileManager().fileExists(atPath: safe.path))
    }
}
