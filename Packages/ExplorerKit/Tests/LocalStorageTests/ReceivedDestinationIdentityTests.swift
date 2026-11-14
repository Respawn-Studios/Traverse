import Foundation
import XCTest
@_spi(ArchiveProduction) @testable import FileOperations
@_spi(Qualification) @testable import LocalStorage

private struct ObservedDestinationFixture {
    let root: URL, parent: URL, pool: URL, engine: RecoverableFileOperations
    init() throws {
        if let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_DESTINATION_TEST_ROOT"] {
            let caseRoot = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard caseRoot.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),
              caseRoot.resolvingSymlinksInPath() == caseRoot,
              UUID(uuidString: caseRoot.lastPathComponent)?.uuidString == caseRoot.lastPathComponent,
              let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: caseRoot.appendingPathComponent("reservation.json"))) as? [String: Any],
              marker["action"] as? String == "traverse-received-destination" else { throw FileOperationFailure.invalidRequest }
            root = caseRoot.appendingPathComponent("source/" + UUID().uuidString)
        } else {
            root = try LocalStorageTestFixtures.directory()
        }
        parent = root.appendingPathComponent("Destination"); pool = root.appendingPathComponent("downloads")
        try FileManager().createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        engine = .init(journalDirectory: root.appendingPathComponent("history"), protecting: [pool])
    }
    func file() async throws -> RemoteDownloadedFile {
        let selection = try SFTPDownloadSelection(generation: UUID(), row: .init(observation: 2,
            entry: .init(name: SFTPRemoteName(Data("Generated.bin".utf8)), logicalBytes: 7, modifiedSeconds: 19, permissions: 0o100644)))
        let file = try await RemoteDownloadStore(directory: pool).reserve(selection)
        try await file.append(request: selection.request, offset: 0, bytes: Data("Fixture".utf8))
        _ = try await file.seal(.init(selection: selection, receivedBytes: 7))
        return file
    }
    func replaceParent() throws {
        try FileManager().moveItem(at: parent, to: root.appendingPathComponent("Retained original destination"))
        try FileManager().createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
}

final class ReceivedDestinationIdentityTests: XCTestCase, @unchecked Sendable {
    func testGroupPreflightPreservesOneParentThroughPublicationAndColdUndo() async throws {
        let fixture = try ObservedDestinationFixture(), engine = fixture.engine
        let names = ["First.bin", "Second.bin"]
        let observed = try await engine.checkReceivedFileDestinations(parent: fixture.parent, names: names)
        var ids: [UUID] = []
        for name in names {
            let file = try await fixture.file()
            let plan = try await file.preparePublication(using: engine, parent: fixture.parent, name: name, observing: observed)
            let result = await engine.performReceivedFile(plan)
            XCTAssertEqual(result.result.disposition, .succeeded)
            ids.append(try XCTUnwrap(result.recordID))
            try await file.removeAfterDrain()
            XCTAssertEqual(try Data(contentsOf: plan.destination), Data("Fixture".utf8))
        }
        let cold = RecoverableFileOperations(journalDirectory: fixture.root.appendingPathComponent("history"), protecting: [fixture.pool])
        for id in ids.reversed() {
            let result = await cold.undo(recordID: id)
            XCTAssertEqual(result.result.disposition, .succeeded)
        }
        for name in names { XCTAssertFalse(FileManager().fileExists(atPath: fixture.parent.appendingPathComponent(name).path)) }
    }

    func testGroupPreflightRefusesCanonicalDuplicatesOccupiedNamesAndChangedParent() async throws {
        let fixture = try ObservedDestinationFixture(), engine = fixture.engine
        for names in [["Same.txt", "Same.txt"], ["Café.txt", "Cafe\u{301}.txt"]] {
            do { try await engine.checkReceivedFileDestinations(parent: fixture.parent, names: names); XCTFail("Conflicting group admitted") }
            catch { XCTAssertEqual(error as? FileOperationFailure, .conflict) }
        }
        let existing = fixture.parent.appendingPathComponent("Existing.txt")
        try Data("Keep existing".utf8).write(to: existing, options: .withoutOverwriting)
        do { try await engine.checkReceivedFileDestinations(parent: fixture.parent, names: ["New.txt", "Existing.txt"]); XCTFail("Occupied group admitted") }
        catch { XCTAssertEqual(error as? FileOperationFailure, .conflict) }
        XCTAssertEqual(try Data(contentsOf: existing), Data("Keep existing".utf8))
        let observed = try await engine.checkReceivedFileDestinations(parent: fixture.parent, names: ["One.txt", "Two.txt"])
        try fixture.replaceParent()
        do { try await engine.checkReceivedFileDestinations(parent: fixture.parent, names: ["One.txt", "Two.txt"], observing: observed); XCTFail("Replaced group parent admitted") }
        catch { XCTAssertEqual(error as? FileOperationFailure, .destinationChanged) }
        let history = try await engine.inspectExistingHistory()
        XCTAssertTrue(history.records.isEmpty)
        XCTAssertTrue(try FileManager().contentsOfDirectory(atPath: fixture.parent.path).isEmpty)
    }
    func testReplacementBetweenEarlyCheckAndFinalPreparationIsRefused() async throws {
        let fixture = try ObservedDestinationFixture(), engine = fixture.engine
        let observation = try await engine.checkReceivedFileDestination(parent: fixture.parent, name: "Received.bin")
        let file = try await fixture.file()
        try fixture.replaceParent()
        do {
            let plan = try await file.preparePublication(using: engine, parent: fixture.parent, name: "Received.bin", observing: observation)
            let result = await engine.performReceivedFile(plan)
            XCTFail("A replaced preflight directory was admitted: \(result.result.disposition)")
        } catch { XCTAssertEqual(error as? FileOperationFailure, .destinationChanged) }
        XCTAssertFalse(FileManager().fileExists(atPath: fixture.parent.appendingPathComponent("Received.bin").path))
        let history = try await engine.inspectExistingHistory()
        XCTAssertTrue(history.records.isEmpty)
        // Failure must leave the exact checked source available to its owner.
        _ = try await file.verifiedSource(); try await file.removeAfterDrain()
    }

    func testUnrelatedChildrenDoNotChangeObservedDirectoryIdentity() async throws {
        let fixture = try ObservedDestinationFixture(), engine = fixture.engine
        let observed = try await engine.checkReceivedFileDestination(parent: fixture.parent, name: "Received.bin")
        try Data("Keep child".utf8).write(to: fixture.parent.appendingPathComponent("Unrelated.txt"), options: .withoutOverwriting)
        let file = try await fixture.file()
        let plan = try await file.preparePublication(using: engine, parent: fixture.parent, name: "Received.bin", observing: observed)
        let result = await engine.performReceivedFile(plan)
        XCTAssertEqual(result.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: plan.destination), Data("Fixture".utf8))
        let undone = await engine.undo(recordID: try XCTUnwrap(result.recordID))
        XCTAssertEqual(undone.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: fixture.parent.appendingPathComponent("Unrelated.txt")), Data("Keep child".utf8))
        try await file.removeAfterDrain()
    }

    func testWrongParentFileAndCombinedObservationsAreRefusedBeforeClaim() async throws {
        let fixture = try ObservedDestinationFixture(), engine = fixture.engine, file = try await fixture.file()
        let other = fixture.root.appendingPathComponent("Other"), regular = fixture.root.appendingPathComponent("Regular.txt")
        try FileManager().createDirectory(at: other, withIntermediateDirectories: false)
        try Data("Keep regular".utf8).write(to: regular, options: .withoutOverwriting)
        let correct = try await engine.checkReceivedFileDestination(parent: fixture.parent, name: "Received.bin")
        let foreign = try await engine.observeDirectory(other), nonDirectory = try await engine.observeSelection([regular])
        for token in [foreign, nonDirectory, correct.combining(foreign), correct.excluding(Set(correct.urls))] {
            do {
                _ = try await file.preparePublication(using: engine, parent: fixture.parent, name: "Received.bin", observing: token)
                XCTFail("A mismatched or malformed parent observation was accepted")
            } catch { XCTAssertEqual(error as? FileOperationFailure, .invalidRequest) }
        }
        // Refused attempts do not claim the one-use received source.
        let plan = try await file.preparePublication(using: engine, parent: fixture.parent, name: "Received.bin", observing: correct)
        let outcome = await engine.performReceivedFile(plan)
        XCTAssertEqual(outcome.result.disposition, .succeeded)
        try await file.removeAfterDrain()
    }

    func testPostPlanReplacementAndOccupiedNameStillPreserveDestination() async throws {
        for replace in [false, true] {
            let fixture = try ObservedDestinationFixture(), engine = fixture.engine, file = try await fixture.file()
            let observed = try await engine.checkReceivedFileDestination(parent: fixture.parent, name: "Received.bin")
            let plan = try await file.preparePublication(using: engine, parent: fixture.parent, name: "Received.bin", observing: observed)
            if replace { try fixture.replaceParent() }
            else { try Data("Keep existing".utf8).write(to: plan.destination, options: .withoutOverwriting) }
            let outcome = await engine.performReceivedFile(plan)
            XCTAssertNotEqual(outcome.result.disposition, .succeeded)
            if !replace { XCTAssertEqual(try Data(contentsOf: plan.destination), Data("Keep existing".utf8)) }
            else { XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path)) }
            try await file.removeAfterDrain()
        }
    }

    func testObservedPlanRetainsForeignEngineAndReplayGuards() async throws {
        let fixture = try ObservedDestinationFixture(), engine = fixture.engine, file = try await fixture.file()
        let observed = try await engine.checkReceivedFileDestination(parent: fixture.parent, name: "Received.bin")
        let plan = try await file.preparePublication(using: engine, parent: fixture.parent, name: "Received.bin", observing: observed)
        let wrong = await RecoverableFileOperations(journalDirectory: fixture.root.appendingPathComponent("Other history")).performReceivedFile(plan)
        XCTAssertNotEqual(wrong.result.disposition, .succeeded)
        let right = await engine.performReceivedFile(plan)
        XCTAssertEqual(right.result.disposition, .succeeded)
        let replay = await engine.performReceivedFile(plan)
        XCTAssertNotEqual(replay.result.disposition, .succeeded)
        try await file.removeAfterDrain()
    }
}
