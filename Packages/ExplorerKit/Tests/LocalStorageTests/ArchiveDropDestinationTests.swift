import CryptoKit
import Darwin
import Foundation
import Testing
@_spi(ArchiveProduction) @testable import FileOperations
@testable import LocalStorage

struct ArchiveDropFixture {
    let root: URL, source: URL, parent: URL
    let payload = Data("Generated archive drop payload.\n".utf8)
    init() throws {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_ARCHIVE_DRAG_TEST_ROOT"] else { throw FileOperationFailure.invalidRequest }
        let base = URL(fileURLWithPath: path), owner = base.deletingLastPathComponent()
        var repo = URL(fileURLWithPath: #filePath); for _ in 0..<5 { repo.deleteLastPathComponent() }
        guard base.lastPathComponent == "source", base.resolvingSymlinksInPath() == base,
              owner.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),
              UUID(uuidString: owner.lastPathComponent)?.uuidString == owner.lastPathComponent,
              let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: owner.appendingPathComponent("reservation.json"))) as? [String: Any],
              marker["action"] as? String == "traverse-archive-member-drag" else { throw FileOperationFailure.invalidRequest }
        root = base.appendingPathComponent(UUID().uuidString)
        source = root.appendingPathComponent("Generated.zip"); parent = root.appendingPathComponent("Destination")
        try FileManager().createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try GeneratedZIP.bytes([.init("Folder/Report.txt", bytes: payload)]).write(to: source, options: .withoutOverwriting)
    }
    var engine: RecoverableFileOperations { .init(journalDirectory: root.appendingPathComponent("history")) }
    var expectedArchive: Data { GeneratedZIP.bytes([.init("Folder/Report.txt", bytes: payload)]) }
    func replaceParent() throws {
        try FileManager().moveItem(at: parent, to: root.appendingPathComponent("Original Destination"))
        try FileManager().createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
}

private final class ArchiveDropProbe: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    var count: Int { lock.withLock { value } }
    func entered() { lock.withLock { value += 1 } }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_ARCHIVE_DRAG_TEST_ROOT"] != nil))
struct ArchiveDropDestinationTests {
    @Test func observedParentSurvivesUnrelatedDirectoryChangesAndExactUndo() async throws {
        let f = try ArchiveDropFixture(), engine = f.engine
        let parent = try await engine.observeDirectory(f.parent), source = try await engine.observeSelection([f.source])
        try Data("unrelated generated item".utf8).write(to: f.parent.appendingPathComponent("Existing.txt"),options: .withoutOverwriting)
        let plan = try await engine.prepareZIPExtraction(source: f.source,parent: f.parent,name: "Extracted",observing: source,observingParent: parent)
        let result = await engine.performArchiveExtraction(plan)
        #expect(result.result.disposition == .succeeded)
        #expect(try Data(contentsOf: plan.destination.appendingPathComponent("Folder/Report.txt")) == f.payload)
        #expect(await engine.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
        #expect(!FileManager().fileExists(atPath: plan.destination.path))
        #expect(try Data(contentsOf: f.source) == f.expectedArchive)
        #expect(try Data(contentsOf: f.parent.appendingPathComponent("Existing.txt")) == Data("unrelated generated item".utf8))
    }
    @Test func replacedEarlyParentRefusesBeforeProducerAndLeavesBothFoldersEmpty() async throws {
        let f = try ArchiveDropFixture(), engine = f.engine, probe = ArchiveDropProbe()
        let parent = try await engine.observeDirectory(f.parent), source = try await engine.observeSelection([f.source])
        try f.replaceParent()
        await #expect(throws: FileOperationFailure.destinationChanged) {
            try await engine.prepareArchiveExtraction(source: f.source,parent: f.parent,name: "Extracted",observing: source,observingParent: parent) { check in
                probe.entered(); return try PreparedZIPDirectory(f.source,check: check)
            }
        }
        #expect(probe.count == 0)
        #expect(try FileManager().contentsOfDirectory(atPath: f.parent.path).isEmpty)
        #expect(try FileManager().contentsOfDirectory(atPath: f.root.appendingPathComponent("Original Destination").path).isEmpty)
        #expect(!FileManager().fileExists(atPath: f.root.appendingPathComponent("history").path))
        #expect(try Data(contentsOf: f.source) == f.expectedArchive)
    }
    @Test func wrongPathFileAndMultipleDirectoryObservationsAreNotAuthority() async throws {
        let f = try ArchiveDropFixture(), engine = f.engine
        let source = try await engine.observeSelection([f.source]), first = try await engine.observeDirectory(f.parent)
        let other = f.root.appendingPathComponent("Other")
        try FileManager().createDirectory(at: other,withIntermediateDirectories: false,attributes: [.posixPermissions:0o700])
        let wrong = try await engine.observeDirectory(other)
        for capture in [source,wrong,first.combining(wrong)] {
            await #expect(throws: FileOperationFailure.invalidRequest) {
                try await engine.prepareZIPExtraction(source: f.source,parent: f.parent,name: "Extracted",observing: source,observingParent: capture)
            }
        }
        #expect(try FileManager().contentsOfDirectory(atPath: f.parent.path).isEmpty)
    }
    @Test func replacingParentAfterPreparedPlanStillRefusesPublication() async throws {
        let f = try ArchiveDropFixture(), engine = f.engine
        let source = try await engine.observeSelection([f.source]), parent = try await engine.observeDirectory(f.parent)
        let plan = try await engine.prepareZIPExtraction(source: f.source,parent: f.parent,name: "Extracted",observing: source,observingParent: parent)
        try f.replaceParent()
        let result = await engine.performArchiveExtraction(plan)
        #expect(result.result.disposition != .succeeded)
        #expect(try FileManager().contentsOfDirectory(atPath: f.parent.path).isEmpty)
        #expect(try FileManager().contentsOfDirectory(atPath: f.root.appendingPathComponent("Original Destination").path).isEmpty)
        #expect(try Data(contentsOf: f.source) == f.expectedArchive)
    }
    @Test func changedSourceStillRefusesWithCorrectEarlyParent() async throws {
        let f = try ArchiveDropFixture(), engine = f.engine
        let source = try await engine.observeSelection([f.source]), parent = try await engine.observeDirectory(f.parent)
        let changed = GeneratedZIP.bytes([.init("Other.txt",bytes: Data("replacement".utf8))])
        try changed.write(to: f.source)
        await #expect(throws: FileOperationFailure.sourceChanged) {
            try await engine.prepareZIPExtraction(source: f.source,parent: f.parent,name: "Extracted",observing: source,observingParent: parent)
        }
        #expect(try Data(contentsOf: f.source) == changed && FileManager().contentsOfDirectory(atPath: f.parent.path).isEmpty)
    }
    @Test func legacyCallAndForeignEnginePlanCannotChangeNewGuardSemantics() async throws {
        let f = try ArchiveDropFixture(), engine = f.engine
        let source = try await engine.observeSelection([f.source]), parent = try await engine.observeDirectory(f.parent)
        let legacy = try await engine.prepareZIPExtraction(source: f.source,parent: f.parent,name: "Legacy",observing: source)
        #expect(legacy.files == 1 && !FileManager().fileExists(atPath: legacy.destination.path))
        let plan = try await engine.prepareZIPExtraction(source: f.source,parent: f.parent,name: "Observed",observing: source,observingParent: parent)
        let foreign = RecoverableFileOperations(journalDirectory: f.root.appendingPathComponent("foreign history"))
        #expect(await foreign.performArchiveExtraction(plan).result.disposition != .succeeded)
        #expect(!FileManager().fileExists(atPath: plan.destination.path))
        let result = await engine.performArchiveExtraction(plan)
        #expect(result.result.disposition == .succeeded)
        #expect(await engine.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
        #expect(await engine.performArchiveExtraction(plan).result.disposition != .succeeded)
        #expect(try Data(contentsOf: f.source) == f.expectedArchive)
    }
}
