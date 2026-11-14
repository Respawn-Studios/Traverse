import Darwin
import Foundation
import Testing
@testable import LocalStorage

@Suite struct LocalAvailableNameTests {
    @Test func completeFilenameAndOccupiedKindsUseDeterministicNumbering() async throws {
        let root = try LocalStorageTestFixtures.directory()
        defer { try? FileManager().removeItem(at: root) }
        #expect(try await LocalAvailableName.available(in: root, preferredName: "Archive.zip", extension: "zip") == "Archive.zip")
        try Data().write(to: root.appendingPathComponent("notes.txt.zip"), options: .withoutOverwriting)
        try FileManager().createDirectory(at: root.appendingPathComponent("notes.txt 2.zip"), withIntermediateDirectories: false)
        try FileManager().createSymbolicLink(atPath: root.appendingPathComponent("notes.txt 3.zip").path,
                                           withDestinationPath: "generated-missing-target")
        #expect(try await LocalAvailableName.available(in: root, preferredName: "notes.txt.zip", extension: "zip") == "notes.txt 4.zip")
        try FileManager().createDirectory(at: root.appendingPathComponent("写真"), withIntermediateDirectories: false)
        #expect(try await LocalAvailableName.available(in: root, preferredName: "写真") == "写真 2")
        #expect(try FileManager().contentsOfDirectory(atPath: root.path).count == 4)
    }

    @Test func filesystemCaseRulesAreUsedRatherThanAnAppComparison() async throws {
        let root = try LocalStorageTestFixtures.directory()
        defer { try? FileManager().removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("Photos.zip"), options: .withoutOverwriting)
        var facts = stat()
        let occupied = lstat(root.appendingPathComponent("photos.zip").path, &facts) == 0
        #expect(try await LocalAvailableName.available(in: root, preferredName: "photos.zip", extension: "zip")
                == (occupied ? "photos 2.zip" : "photos.zip"))
    }

    @Test func errorsAndCancellationDoNotBecomeFalseAbsence() async throws {
        let root = try LocalStorageTestFixtures.directory()
        defer { try? FileManager().removeItem(at: root) }
        await #expect(throws: LocalAvailableName.Failure.fileSystem(ENOENT)) {
            try await LocalAvailableName.available(in: root.appendingPathComponent("Missing"), preferredName: "Archive.zip", extension: "zip")
        }
        await #expect(throws: LocalAvailableName.Failure.invalidName) {
            try await LocalAvailableName.available(in: root, preferredName: "../Archive.zip", extension: "zip")
        }
        let denied = root.appendingPathComponent("Denied")
        try FileManager().createDirectory(at: denied, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o000])
        defer { _ = chmod(denied.path, 0o700) }
        if geteuid() != 0 {
            await #expect(throws: LocalAvailableName.Failure.fileSystem(EACCES)) {
                try await LocalAvailableName.available(in: denied, preferredName: "Archive.zip", extension: "zip")
            }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalAvailableName.available(in: root, preferredName: "Archive.zip", extension: "zip")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func candidateSearchHasAFiniteBound() async throws {
        let root = try LocalStorageTestFixtures.directory()
        defer { try? FileManager().removeItem(at: root) }
        for number in 1...1_024 {
            let name = number == 1 ? "Archive.zip" : "Archive \(number).zip"
            try Data().write(to: root.appendingPathComponent(name), options: .withoutOverwriting)
        }
        await #expect(throws: LocalAvailableName.Failure.exhausted) {
            try await LocalAvailableName.available(in: root, preferredName: "Archive.zip", extension: "zip")
        }
    }
}
