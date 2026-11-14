import Foundation
@testable import FileOperations
import Testing

private struct PreferenceFixture {
    let root: URL
    let source: URL
    let destination: URL
    let engine: RecoverableFileOperations
    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures")
        guard base.resolvingSymlinksInPath() == base else { throw FileOperationFailure.invalidRequest }
        root = base.appendingPathComponent("conflict-preferences-" + UUID().uuidString)
        source = root.appendingPathComponent("source"); destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        engine = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("journal"))
    }
    func file(_ name: String, at parent: URL, text: String) throws -> URL {
        let url = parent.appendingPathComponent(name)
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized) struct ConflictPreferencesTests {
    @Test func matchingTypesAndUnsupportedKinds() async throws {
        let f = try PreferenceFixture(); defer { f.remove() }
        let file = try f.file("report.txt", at: f.source, text: "source")
        _ = try f.file("report.txt", at: f.destination, text: "destination")
        let directory = f.source.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: f.destination.appendingPathComponent("Photos"), withIntermediateDirectories: false)
        let link = f.source.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "report.txt")
        _ = try f.file("Link", at: f.destination, text: "existing")
        let plan = try await f.engine.prepareTransfer(sources: [file, directory, link], destinationDirectory: f.destination, move: false)
        let prefs = TransferConflictPreferences(files: .keepBoth, folders: .skip)
        let choices = prefs.choices(for: plan.conflicts)
        #expect(choices.automatic.count == 2)
        #expect(choices.asking.count == 1 && choices.asking.first?.source == link)
        #expect(choices.automatic[try #require(plan.conflicts.first { $0.source.path == file.path }).id] == .keepBoth)
        #expect(choices.automatic[try #require(plan.conflicts.first { $0.source.path == directory.path }).id] == .skip)
        #expect(TransferConflictPreferences().choices(for: plan.conflicts).automatic.isEmpty)
    }

    @Test func keepBothUsesRecoverableEngineAndUndo() async throws {
        let f = try PreferenceFixture(); defer { f.remove() }
        let source = try f.file("report.txt", at: f.source, text: "new")
        let existing = try f.file("report.txt", at: f.destination, text: "old")
        let plan = try await f.engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: false)
        let choices = TransferConflictPreferences(files: .keepBoth).choices(for: plan.conflicts)
        #expect(choices.asking.isEmpty)
        let result = await f.engine.perform(plan, resolutions: choices.automatic)
        #expect(result.result.disposition == .succeeded)
        let copied = try #require(result.result.items.first?.destination)
        #expect(copied.lastPathComponent == "report (1).txt")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "old")
        #expect(try String(contentsOf: copied, encoding: .utf8) == "new")
        let undone = await f.engine.undo(recordID: try #require(result.recordID))
        #expect(undone.result.disposition == .succeeded)
        #expect(!FileManager.default.fileExists(atPath: copied.path))
        #expect(try String(contentsOf: existing, encoding: .utf8) == "old")
        #expect(try String(contentsOf: source, encoding: .utf8) == "new")
    }

    @Test func skipMoveRetainsSourceAndIsNotFailure() async throws {
        let f = try PreferenceFixture(); defer { f.remove() }
        let source = try f.file("report.txt", at: f.source, text: "new")
        let existing = try f.file("report.txt", at: f.destination, text: "old")
        let plan = try await f.engine.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
        let choices = TransferConflictPreferences(files: .skip).choices(for: plan.conflicts)
        let result = await f.engine.perform(plan, resolutions: choices.automatic)
        #expect(result.result.items.first?.status == .skipped)
        #expect(result.result.disposition == .succeeded)
        #expect(try String(contentsOf: source, encoding: .utf8) == "new")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "old")
    }

    @Test func continuedMoveCanKeepBothWithoutRepeatingCompletedWork() async throws {
        let f = try PreferenceFixture(); defer { f.remove() }
        let skipped = try f.file("report.txt", at: f.source, text: "new")
        let completed = try f.file("complete.txt", at: f.source, text: "complete")
        let existing = try f.file("report.txt", at: f.destination, text: "old")
        let initial = try await f.engine.prepareTransfer(sources: [skipped, completed], destinationDirectory: f.destination, move: true)
        let first = await f.engine.perform(initial, resolutions: TransferConflictPreferences(files: .skip).choices(for: initial.conflicts).automatic)
        let token = try #require(first.continuation)
        let remaining = try await f.engine.prepareContinuation(token)
        let choices = TransferConflictPreferences(files: .keepBoth).choices(for: remaining.conflicts)
        #expect(choices.asking.isEmpty && choices.automatic.count == 1)
        let second = await f.engine.perform(remaining, resolutions: choices.automatic)
        #expect(second.result.disposition == .succeeded)
        #expect(second.result.items.filter { $0.status == .succeeded }.map(\.destination?.lastPathComponent) == ["report (1).txt"])
        #expect(!FileManager.default.fileExists(atPath: skipped.path))
        #expect(!FileManager.default.fileExists(atPath: completed.path))
        #expect(try String(contentsOf: existing, encoding: .utf8) == "old")
        let undo = await f.engine.undo(recordID: try #require(second.recordID))
        #expect(undo.result.disposition == .succeeded)
        #expect(try String(contentsOf: skipped, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: completed.path))
    }

    @Test func packagesAndTypeDifferencesStillAskUnderAutomaticDefaults() async throws {
        let f = try PreferenceFixture(); defer { f.remove() }
        let package = f.source.appendingPathComponent("Example.app")
        let mismatched = f.source.appendingPathComponent("Different")
        for url in [package, f.destination.appendingPathComponent("Example.app"), f.destination.appendingPathComponent("Different")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        _ = try f.file("Different", at: f.source, text: "regular")
        let plan = try await f.engine.prepareTransfer(sources: [package, mismatched], destinationDirectory: f.destination, move: false)
        let choices = TransferConflictPreferences(files: .keepBoth, folders: .skip).choices(for: plan.conflicts)
        #expect(choices.automatic.isEmpty && choices.asking.count == 2)
    }

    @Test func preferencesAreValuesAndRejectUnknownPolicies() throws {
        var settings = TransferConflictPreferences(files: .skip, folders: .keepBoth)
        let captured = settings
        settings.files = .keepBoth
        #expect(captured.files == .skip)
        #expect(try JSONDecoder().decode(TransferConflictPreferences.self, from: JSONEncoder().encode(captured)) == captured)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(TransferConflictPreferences.self, from: Data(#"{"files":"replace","folders":"ask"}"#.utf8))
        }
    }
}
