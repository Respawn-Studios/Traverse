import Darwin
import Foundation
import Testing
@testable import FileMemory

/// Initial native evidence control. Generated files only; no private catalog or
/// source body enters the reference reader. Receipts contain numeric metadata.
@Test func b07NativeEvidenceProbe() async throws {
    guard NameStoreFixture.nativePacket else { return }
    let fixture = try NameStoreFixture(reservedBytes: 1_048_576, reservedEntries: 16)
    try await Task.detached {
        try runNativeEvidenceProbe(fixture: fixture, sourceRoot: fixture.root, tracked: false)
        let trackedRoot = fixture.child("tracked")
        try FileManager().createDirectory(at: trackedRoot, withIntermediateDirectories: false)
        try runNativeEvidenceProbe(fixture: fixture, sourceRoot: trackedRoot, tracked: true)
    }.value
}

private func runNativeEvidenceProbe(fixture: NameStoreFixture, sourceRoot: URL, tracked: Bool) throws {
        let file = sourceRoot.appendingPathComponent("generated.txt"), directory = sourceRoot.appendingPathComponent("generated-folder")
        try Data("Generated B07 identity fixture".utf8).write(to: file, options: .withoutOverwriting)
        try FileManager().createDirectory(at: directory, withIntermediateDirectories: false)
        if tracked {
            // Test-fixture setup only, never a production reference-reader step.
            #expect(chflags(file.path, UInt32(UF_TRACKED)) == 0)
            #expect(chflags(directory.path, UInt32(UF_TRACKED)) == 0)
        }
        var rows: [[String: Any]] = []
        for url in [file, directory] {
            func observation() throws -> [String: Any] {
                var info = stat(); guard lstat(url.path, &info) == 0 else { throw NameStoreFailure.unavailable }
                (url as NSURL).removeAllCachedResourceValues()
                let value = try url.resourceValues(forKeys: [.documentIdentifierKey, .volumeUUIDStringKey])
                let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW_ANY)
                guard fd >= 0 else { throw NameStoreFailure.unavailable }
                defer { Darwin.close(fd) }
                var attributes = attrlist()
                attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                attributes.commonattr = ATTR_CMN_RETURNED_ATTRS | UInt32(ATTR_CMN_DOCUMENT_ID)
                var bytes = [UInt8](repeating: 0, count: 64)
                let result = fgetattrlist(fd, &attributes, &bytes, bytes.count, UInt32(FSOPT_ATTR_CMN_EXTENDED))
                let status = errno
                func word(_ at: Int) -> UInt32 { bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) } }
                return ["document": value.documentIdentifier ?? -1, "volumePresent": value.volumeUUIDString != nil,
                        "descriptorStatus": result, "descriptorError": result == 0 ? 0 : status,
                        "returnedBytes": word(0), "returnedCommon": word(4), "descriptorDocument": word(24),
                        "flags": info.st_flags, "inode": info.st_ino,
                        "ctimeSec": info.st_ctimespec.tv_sec, "ctimeNSec": info.st_ctimespec.tv_nsec]
            }
            let before = try observation()
            let data = try url.bookmarkData(options: [.withoutImplicitSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            let after = try observation()
            var stale = false
            let resolved = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing],
                                   relativeTo: nil, bookmarkDataIsStale: &stale)
            var scopedBytes = 0, scopedError = 0
            do {
                scopedBytes = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil, relativeTo: nil).count
            } catch { scopedError = (error as NSError).code }
            rows.append(["directory": url == directory, "before": before, "after": after,
                         "bookmarkBytes": data.count, "resolvedOriginal": resolved.path == url.path, "stale": stale,
                         "scopedBytes": scopedBytes, "scopedError": scopedError, "afterScope": try observation()])
        }
        let data = try JSONSerialization.data(withJSONObject: ["rows": rows], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fixture.child(tracked ? "tracked-probe.json" : "native-probe.json"), options: .withoutOverwriting)
}

@Test func b07NativeReaderMovesAndSafeSave() async throws {
    guard NameStoreFixture.nativePacket else { return }
    let fixture = try NameStoreFixture(reservedBytes: 2 * 1_024 * 1_024, reservedEntries: 32)
    let original = fixture.child("generated.txt"), moved = fixture.child("Renamed.txt")
    try Data("Generated original".utf8).write(to: original, options: .withoutOverwriting)
    let reader = NativeDocumentReferenceReader(activity: nil)
    await #expect(throws: RememberedReferenceFailure.followingRequired) {
        _ = try await reader.capture(original, cancellation: .init())
    }
    try await reader.qualificationEnableTracking(original, cancellation: .init())
    let captured = try await reader.capture(original, cancellation: .init())
    #expect(try NativeDocumentReference(data: captured.reference.encoded()) == captured.reference)
    try FileManager().moveItem(at: original, to: moved)
    let renamed = try await reader.resolve(captured.reference, cancellation: .init())
    #expect(renamed.url.path == moved.path)
    // In-place edited contents do not enter the reader or change its contract.
    try Data("Generated later edits".utf8).write(to: moved)
    #expect(try await reader.resolve(captured.reference, cancellation: .init()).reference.document == captured.reference.document)
    let replacement = fixture.child("replacement.txt")
    try Data("Generated safe save".utf8).write(to: replacement, options: .withoutOverwriting)
    _ = try FileManager().replaceItemAt(moved, withItemAt: replacement)
    let safe = try await reader.resolve(captured.reference, cancellation: .init())
    #expect(safe.reference.document == captured.reference.document)
    let clone = fixture.child("copy.txt")
    try FileManager().copyItem(at: moved, to: clone)
    await #expect(throws: RememberedReferenceFailure.followingRequired) { _ = try await reader.capture(clone, cancellation: .init()) }
    try await reader.qualificationEnableTracking(clone, cancellation: .init())
    #expect(try await reader.capture(clone, cancellation: .init()).reference.document != captured.reference.document)
    let marker = try JSONSerialization.data(withJSONObject: ["rename": true, "inPlace": true, "safeSave": true, "copySeparate": true], options: .sortedKeys)
    try marker.write(to: fixture.child("reader-result.json"), options: .withoutOverwriting)
}

@Test func b07NativeReaderRefusesReusedPathsLinksAndDenial() async throws {
    guard NameStoreFixture.nativePacket else { return }
    let fixture = try NameStoreFixture(reservedBytes: 2 * 1_024 * 1_024, reservedEntries: 32)
    let reader = NativeDocumentReferenceReader(activity: nil)
    let source = fixture.child("name.txt"), moved = fixture.child("NAME.txt")
    try Data("Generated replacement controls".utf8).write(to: source, options: .withoutOverwriting)
    try await reader.qualificationEnableTracking(source, cancellation: .init())
    let original = try await reader.capture(source, cancellation: .init())
    #expect(rename(source.path, moved.path) == 0)
    #expect(try await reader.resolve(original.reference, cancellation: .init()).url.lastPathComponent == moved.lastPathComponent)
    let linkURL = fixture.child("hard-link")
    #expect(link(moved.path, linkURL.path) == 0)
    await #expect(throws: RememberedReferenceFailure.unsupported) { _ = try await reader.resolve(original.reference, cancellation: .init()) }
    let symbolic = fixture.child("symbolic")
    #expect(symlink(moved.path, symbolic.path) == 0)
    await #expect(throws: RememberedReferenceFailure.unsupported) { _ = try await reader.capture(symbolic, cancellation: .init()) }
    let folder = fixture.child("folder"), renamedFolder = fixture.child("renamed-folder")
    try FileManager().createDirectory(at: folder, withIntermediateDirectories: false)
    try await reader.qualificationEnableTracking(folder, cancellation: .init())
    let capturedFolder = try await reader.capture(folder, cancellation: .init())
    try FileManager().moveItem(at: folder, to: renamedFolder)
    #expect(try await reader.resolve(capturedFolder.reference, cancellation: .init()).url.path == renamedFolder.path)
    let denied = fixture.child("denied")
    try Data("Generated inaccessible".utf8).write(to: denied, options: .withoutOverwriting)
    #expect(chmod(denied.path, 0) == 0)
    await #expect(throws: RememberedReferenceFailure.accessNeeded) { _ = try await reader.capture(denied, cancellation: .init()) }
    let disappearing = fixture.child("disappearing"), unrelated = fixture.child("unrelated")
    try Data("Generated old object".utf8).write(to: disappearing, options: .withoutOverwriting)
    try Data("Generated unrelated".utf8).write(to: unrelated, options: .withoutOverwriting)
    try await reader.qualificationEnableTracking(disappearing, cancellation: .init())
    try await reader.qualificationEnableTracking(unrelated, cancellation: .init())
    let reference = try await reader.capture(disappearing, cancellation: .init())
    // Deliberately remove only this generated source to exercise pathname reuse.
    try FileManager().removeItem(at: disappearing)
    try FileManager().moveItem(at: unrelated, to: disappearing)
    do { _ = try await reader.resolve(reference.reference, cancellation: .init()); Issue.record("Unrelated pathname occupant inherited a description") }
    catch { #expect([RememberedReferenceFailure.changed, .unavailable, .unsupported].contains(NativeDocumentReferenceReader.classify(error))) }
}

@Test func b07NativeFormerHardlinkRetainsLogicalDocument() async throws {
    guard NameStoreFixture.nativePacket else { return }
    let fixture = try NameStoreFixture(reservedBytes: 1_048_576, reservedEntries: 16)
    let a = fixture.child("original"), b = fixture.child("different-entry")
    try Data("Generated historical-hardlink probe".utf8).write(to: a, options: .withoutOverwriting)
    let reader = NativeDocumentReferenceReader(activity: nil)
    try await reader.qualificationEnableTracking(a, cancellation: .init())
    let reference = try await reader.capture(a, cancellation: .init())
    #expect(link(a.path, b.path) == 0)
    #expect(unlink(a.path) == 0)
    // Owner-approved logical-document contract: native evidence cannot infer
    // whether this relocation used rename or link/unlink. Active links refuse.
    let value = try await reader.resolve(reference.reference, cancellation: .init())
    #expect(value.url.path == b.path)
    #expect(value.reference.volume == reference.reference.volume)
    #expect(value.reference.document == reference.reference.document)
    try JSONSerialization.data(withJSONObject: ["resolvedOtherEntry": true, "result": "resolved"], options: .sortedKeys)
        .write(to: fixture.child("former-hardlink.json"), options: .withoutOverwriting)
}
