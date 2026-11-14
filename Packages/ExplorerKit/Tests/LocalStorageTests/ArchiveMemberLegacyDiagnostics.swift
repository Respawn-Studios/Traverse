import Darwin
import Foundation
import Testing
@testable import FileOperations
@testable import LocalStorage

/// Characterize the unchanged legacy call, which carries only the current path.
/// No mutation is performed: this demonstrates why a drop needs a new explicit
/// early-directory observation at the existing preparation interface.
@Test func archiveMemberLegacyParentDiagnostic() async throws {
    guard ProcessInfo.processInfo.environment["MAC_EXPLORER_ARCHIVE_DRAG_BASELINE"] == "1" else { return }
    let fixture = try ArchiveDropFixture(), engine = fixture.engine
    _ = try await engine.observeDirectory(fixture.parent)
    let selected = try await engine.observeSelection([fixture.source])
    var before = stat(); #expect(lstat(fixture.parent.path,&before) == 0)
    try fixture.replaceParent()
    var after = stat(); #expect(lstat(fixture.parent.path,&after) == 0 && before.st_ino != after.st_ino)
    let plan = try await engine.prepareZIPExtraction(source: fixture.source, parent: fixture.parent, name: "Extracted", observing: selected)
    #expect(plan.destination == fixture.parent.appendingPathComponent("Extracted"))
    #expect(!FileManager().fileExists(atPath: plan.destination.path) && !FileManager().fileExists(atPath: fixture.root.appendingPathComponent("history").path))
    #expect(try Data(contentsOf: fixture.source) == fixture.expectedArchive)
    guard let base = ProcessInfo.processInfo.environment["MAC_EXPLORER_ARCHIVE_DRAG_TEST_ROOT"] else { throw FileOperationFailure.invalidRequest }
    try JSONSerialization.data(withJSONObject: ["legacyPreparedReplacedParent": true, "guardPresent": false,
        "originalInode": before.st_ino, "replacementInode": after.st_ino, "outputsCreated": 0, "sourceUnchanged": true],options: [.prettyPrinted,.sortedKeys])
        .write(to: URL(fileURLWithPath: base).deletingLastPathComponent().appendingPathComponent("evidence/legacy-parent-diagnostic.json"),options: .withoutOverwriting)
}
