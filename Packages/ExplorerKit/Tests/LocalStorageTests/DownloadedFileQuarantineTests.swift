import CoreServices
import Darwin
import Foundation
import XCTest
@testable import LocalStorage

private struct DownloadFixture {
    let folder: URL
    init() throws {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_B12_SOURCE"] else {
            folder = try LocalStorageTestFixtures.directory()
            return
        }
        let source = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard source.lastPathComponent == "source", source.deletingLastPathComponent().deletingLastPathComponent() == repo.appendingPathComponent(".build/b12-download-qualification"),
              UUID(uuidString: source.deletingLastPathComponent().lastPathComponent) != nil, source.resolvingSymlinksInPath() == source else {
            throw DownloadQuarantineFailure.unsafe
        }
        folder = source.appendingPathComponent(UUID().uuidString)
        try FileManager().createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func create(_ name: String = "Generated.bin", mode: mode_t = 0o600) throws -> (URL, Int32) {
        let url = folder.appendingPathComponent(name)
        let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw DownloadQuarantineFailure.unavailable }; return (url, fd)
    }
    func raw(_ fd: Int32) -> Data? {
        let count = fgetxattr(fd, "com.apple.quarantine", nil, 0, 0, 0); guard count > 0, count < 4096 else { return nil }
        var data = Data(count: count); let found = data.withUnsafeMutableBytes { fgetxattr(fd, "com.apple.quarantine", $0.baseAddress, count, 0, 0) }
        return found == count ? data : nil
    }
}
final class DownloadedFileQuarantineTests: XCTestCase {
    private func nativeAgentName() throws -> String {
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? ProcessInfo.processInfo.processName
        return try XCTUnwrap(name.isEmpty ? nil : name)
    }
    private func setObservedNativeSandboxMark(_ descriptor: Int32, agent: String, timestamp: String = "6ae64da7") throws {
        // Exact opaque representation retained from the signed sandbox Open
        // case. The test does not assign meaning to its flag field.
        XCTAssertFalse(agent.contains(";"))
        let bytes = Data("0086;\(timestamp);\(agent);".utf8)
        XCTAssertEqual(bytes.withUnsafeBytes {
            fsetxattr(descriptor, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_CREATE)
        }, 0)
    }
    func testFreshPrivateOutputReceivesPublicNativeQuarantineBeforeAnyBodyBytes() throws {
        let fixture = try DownloadFixture(), (url, fd) = try fixture.create(); defer { close(fd) }
        let witness = try DownloadedFileQuarantine.markEmptyFile(fd, at: url)
        let original = try XCTUnwrap(fixture.raw(fd)); XCTAssertFalse(original.isEmpty)
        let properties = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        XCTAssertEqual(properties?[kLSQuarantineTypeKey as String] as? String, kLSQuarantineTypeOtherDownload as String)
        XCTAssertNil(properties?[kLSQuarantineDataURLKey as String]); XCTAssertNil(properties?[kLSQuarantineOriginURLKey as String])
        let generated = Data(repeating: 7, count: 65_537)
        XCTAssertEqual(generated.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, generated.count)
        try witness.validate(fd); XCTAssertEqual(fixture.raw(fd), original)
    }
    func testExistingMarkIsPreservedAndNeverReset() throws {
        let fixture = try DownloadFixture(), (url, fd) = try fixture.create(); defer { close(fd) }
        _ = try DownloadedFileQuarantine.markEmptyFile(fd, at: url); let before = try XCTUnwrap(fixture.raw(fd))
        XCTAssertThrowsError(try DownloadedFileQuarantine.markEmptyFile(fd, at: url)); XCTAssertEqual(fixture.raw(fd), before)
    }
    func testFreshSpoolPreservesOwnedNativeSandboxMarkByteForByte() throws {
        let fixture = try DownloadFixture(), (url, fd) = try fixture.create(); defer { close(fd) }
        try setObservedNativeSandboxMark(fd, agent: nativeAgentName())
        let before = try XCTUnwrap(fixture.raw(fd))
        let properties = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        XCTAssertEqual(properties?[kLSQuarantineTypeKey as String] as? String, "LSQuarantineTypeSandboxed")
        XCTAssertEqual(properties?["LSQuarantineIsOwnedByCurrentUser"] as? Bool, true)
        XCTAssertEqual(properties?[kLSQuarantineAgentNameKey as String] as? String, try nativeAgentName())
        let witness = try DownloadedFileQuarantine.markFreshSpoolFile(fd, at: url)
        XCTAssertEqual(fixture.raw(fd), before)
        XCTAssertThrowsError(try DownloadedFileQuarantine.markEmptyFile(fd, at: url))
        let body = Data(repeating: 0x71, count: 97)
        XCTAssertEqual(body.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, body.count)
        try witness.validate(fd)
        XCTAssertEqual(fixture.raw(fd), before)
    }
    #if DEBUG
    func testDownloadedNativeStageQuarantineTransitionPreservesSourceMark() throws {
        let fixture = try DownloadFixture()
        let (sourceURL, sourceFD) = try fixture.create("DownloadedSpool.bin")
        defer { close(sourceFD) }
        let (_, stageFD) = try fixture.create("PrivateRecovery.bin")
        defer { close(stageFD) }
        let sourceMark = Data("0086;6ae64da7;Mac Explorer;".utf8)
        let stageMark = Data("0082;6ae64da7;Mac Explorer;".utf8)
        XCTAssertEqual(sourceMark.withUnsafeBytes {
            fsetxattr(sourceFD, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_CREATE)
        }, 0)
        XCTAssertEqual(stageMark.withUnsafeBytes {
            fsetxattr(stageFD, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_CREATE)
        }, 0)
        let stageAtCreation = try ZIPSourceSecurity.downloadedStageWitness(stageFD)
        let witness = try ZIPSourceSecurity.extractionWitness(sourceFD, url: sourceURL, allowingInheritance: true)
        XCTAssertThrowsError(try witness.apply(to: stageFD), "Archive extraction keeps its original exact-mark rule")
        // Both generated files have the observed matching provenance for this branch.
        // The test still reads and updates their actual quarantine attributes.
        try witness.applyToDownloadedFileForQualification(from: sourceFD, to: stageFD,
            stageAtCreation: stageAtCreation, readProvenance: { _ in Data([1]) })
        XCTAssertEqual(fixture.raw(sourceFD), sourceMark)
        XCTAssertEqual(fixture.raw(stageFD), sourceMark)
    }
    #endif
    func testDownloadedNativeStageTransitionRefusesOtherMarks() throws {
        let sourceMark = Data("0086;6ae64da7;Mac Explorer;".utf8)
        for stageText in [
            "0082;6ae64da8;Mac Explorer;", // Different timestamp.
            "0082;6ae64da7;Other Agent;", // Different agent.
            "0083;6ae64da7;Mac Explorer;", // Different flag transition.
            "0080;6ae64da7;Mac Explorer;", // Missing sandbox flag.
            "0082;6ae64da7;Mac Explorer;extra", // Different remaining bytes.
        ] {
            let fixture = try DownloadFixture()
            let (sourceURL, sourceFD) = try fixture.create("DownloadedSpool.bin")
            defer { close(sourceFD) }
            let (_, stageFD) = try fixture.create("PrivateRecovery.bin")
            defer { close(stageFD) }
            let stageMark = Data(stageText.utf8)
            XCTAssertEqual(sourceMark.withUnsafeBytes {
                fsetxattr(sourceFD, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_CREATE)
            }, 0)
            XCTAssertEqual(stageMark.withUnsafeBytes {
                fsetxattr(stageFD, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_CREATE)
            }, 0)
            let stageAtCreation = try ZIPSourceSecurity.downloadedStageWitness(stageFD)
            let witness = try ZIPSourceSecurity.extractionWitness(sourceFD, url: sourceURL, allowingInheritance: true)
            XCTAssertThrowsError(try witness.applyToDownloadedFile(from: sourceFD, to: stageFD,
                stageAtCreation: stageAtCreation), stageText)
            XCTAssertEqual(fixture.raw(sourceFD), sourceMark)
            XCTAssertEqual(fixture.raw(stageFD), stageMark)
        }
    }
    func testDownloadedNativeStageTransitionRefusesMarkChangedAfterCreation() throws {
        let fixture = try DownloadFixture()
        let (sourceURL, sourceFD) = try fixture.create("DownloadedSpool.bin")
        defer { close(sourceFD) }
        let (_, stageFD) = try fixture.create("PrivateRecovery.bin")
        defer { close(stageFD) }
        let sourceMark = Data("0086;6ae64da7;Mac Explorer;".utf8)
        let stageMark = Data("0082;6ae64da7;Mac Explorer;".utf8)
        XCTAssertEqual(sourceMark.withUnsafeBytes {
            fsetxattr(sourceFD, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_CREATE)
        }, 0)
        XCTAssertEqual(stageMark.withUnsafeBytes {
            fsetxattr(stageFD, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_CREATE)
        }, 0)
        let stageAtCreation = try ZIPSourceSecurity.downloadedStageWitness(stageFD)
        let altered = Data("0083;6ae64da7;Mac Explorer;".utf8)
        XCTAssertEqual(altered.withUnsafeBytes {
            fsetxattr(stageFD, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_REPLACE)
        }, 0)
        let witness = try ZIPSourceSecurity.extractionWitness(sourceFD, url: sourceURL, allowingInheritance: true)
        XCTAssertThrowsError(try witness.applyToDownloadedFile(from: sourceFD, to: stageFD,
            stageAtCreation: stageAtCreation))
        XCTAssertEqual(fixture.raw(sourceFD), sourceMark)
        XCTAssertEqual(fixture.raw(stageFD), altered)
    }
    func testDownloadedNativeStageTransitionRefusesOtherSourceFamilyAndChangedWitness() throws {
        for sourceText in ["0083;6ae64da7;Mac Explorer;", "0086;6ae64da7;Mac Explorer;"] {
            let fixture = try DownloadFixture()
            let (sourceURL, sourceFD) = try fixture.create("DownloadedSpool.bin")
            defer { close(sourceFD) }
            let (_, stageFD) = try fixture.create("PrivateRecovery.bin")
            defer { close(stageFD) }
            let sourceMark = Data(sourceText.utf8)
            let stageMark = Data("0082;6ae64da7;Mac Explorer;".utf8)
            XCTAssertEqual(sourceMark.withUnsafeBytes {
                fsetxattr(sourceFD, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_CREATE)
            }, 0)
            XCTAssertEqual(stageMark.withUnsafeBytes {
                fsetxattr(stageFD, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_CREATE)
            }, 0)
            let stageAtCreation = try ZIPSourceSecurity.downloadedStageWitness(stageFD)
            let witness = try ZIPSourceSecurity.extractionWitness(sourceFD, url: sourceURL, allowingInheritance: true)
            if sourceText.hasPrefix("0086;") {
                let changed = Data("0086;6ae64da8;Mac Explorer;".utf8)
                XCTAssertEqual(changed.withUnsafeBytes {
                    fsetxattr(sourceFD, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_REPLACE)
                }, 0)
            }
            XCTAssertThrowsError(try witness.applyToDownloadedFile(from: sourceFD, to: stageFD,
                stageAtCreation: stageAtCreation), sourceText)
            XCTAssertEqual(fixture.raw(stageFD), stageMark)
        }
    }
    #if DEBUG
    func testDownloadedNativeStageTransitionRequiresSourceAndStageProvenance() throws {
        // macOS can silently retain com.apple.provenance after removal. Inject
        // only this read boundary so absent and differing values are exercised.
        let cases: [(String, Data?, Data?)] = [
            ("missing source", nil, Data([1])),
            ("different stage", Data([1]), Data([2])),
        ]
        for (label, sourceProvenance, stageProvenance) in cases {
            let fixture = try DownloadFixture()
            let (sourceURL, sourceFD) = try fixture.create("DownloadedSpool.bin")
            defer { close(sourceFD) }
            let (_, stageFD) = try fixture.create("PrivateRecovery.bin")
            defer { close(stageFD) }
            let sourceMark = Data("0086;6ae64da7;Mac Explorer;".utf8)
            let stageMark = Data("0082;6ae64da7;Mac Explorer;".utf8)
            XCTAssertEqual(sourceMark.withUnsafeBytes {
                fsetxattr(sourceFD, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_CREATE)
            }, 0)
            XCTAssertEqual(stageMark.withUnsafeBytes {
                fsetxattr(stageFD, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_CREATE)
            }, 0)
            let stageAtCreation = try ZIPSourceSecurity.downloadedStageWitness(stageFD)
            let witness = try ZIPSourceSecurity.extractionWitness(sourceFD, url: sourceURL, allowingInheritance: true)
            XCTAssertThrowsError(try witness.applyToDownloadedFileForQualification(from: sourceFD, to: stageFD,
                stageAtCreation: stageAtCreation,
                readProvenance: { descriptor in descriptor == sourceFD ? sourceProvenance : stageProvenance }), label)
            XCTAssertEqual(fixture.raw(sourceFD), sourceMark)
            XCTAssertEqual(fixture.raw(stageFD), stageMark)
        }
    }
    #endif
    func testRenamedReviewBundleAcceptsOnlyItsExecutableAsNativeCreator() throws {
        let fixture = try DownloadFixture(), (url, fd) = try fixture.create("RenamedReview.bin"); defer { close(fd) }
        try setObservedNativeSandboxMark(fd, agent: "Mac Explorer", timestamp: "6ae65df2")
        let before = try XCTUnwrap(fixture.raw(fd))
        let properties = try XCTUnwrap(URL(fileURLWithPath: url.path)
            .resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        XCTAssertEqual(Set(properties.keys), Set([kLSQuarantineAgentNameKey as String,
            kLSQuarantineTimeStampKey as String, kLSQuarantineTypeKey as String, "LSQuarantineIsOwnedByCurrentUser"]))
        XCTAssertEqual(properties[kLSQuarantineAgentNameKey as String] as? String, "Mac Explorer")
        XCTAssertTrue(DownloadedFileQuarantine.isOwnedNativeSandboxMark(properties,
            creatorName: "Traverse SFTP Editor Sandbox Review (Generated)", executableName: "Mac Explorer"))
        XCTAssertFalse(DownloadedFileQuarantine.isOwnedNativeSandboxMark(properties,
            creatorName: "Traverse SFTP Editor Sandbox Review (Generated)", executableName: "Unrelated Creator"))
        XCTAssertEqual(fixture.raw(fd), before)
    }
    func testFreshSpoolRefusesUnrelatedExistingMarksWithoutRewritingThem() throws {
        let fixture = try DownloadFixture(), (wrongAgentURL, wrongAgentFD) = try fixture.create("WrongAgent.bin")
        defer { close(wrongAgentFD) }
        try setObservedNativeSandboxMark(wrongAgentFD, agent: "Unrelated Creator")
        let wrongAgentMark = try XCTUnwrap(fixture.raw(wrongAgentFD))
        let wrongAgentProperties = try URL(fileURLWithPath: wrongAgentURL.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        XCTAssertEqual(wrongAgentProperties?[kLSQuarantineTypeKey as String] as? String, "LSQuarantineTypeSandboxed")
        XCTAssertEqual(wrongAgentProperties?["LSQuarantineIsOwnedByCurrentUser"] as? Bool, true)
        XCTAssertEqual(wrongAgentProperties?[kLSQuarantineAgentNameKey as String] as? String, "Unrelated Creator")
        XCTAssertThrowsError(try DownloadedFileQuarantine.markFreshSpoolFile(wrongAgentFD, at: wrongAgentURL))
        XCTAssertEqual(fixture.raw(wrongAgentFD), wrongAgentMark)

        let (otherDownloadURL, otherDownloadFD) = try fixture.create("OtherDownload.bin")
        defer { close(otherDownloadFD) }
        _ = try DownloadedFileQuarantine.markEmptyFile(otherDownloadFD, at: otherDownloadURL)
        let otherDownloadMark = try XCTUnwrap(fixture.raw(otherDownloadFD))
        XCTAssertThrowsError(try DownloadedFileQuarantine.markFreshSpoolFile(otherDownloadFD, at: otherDownloadURL))
        XCTAssertEqual(fixture.raw(otherDownloadFD), otherDownloadMark)
    }
    func testNonemptyOrPubliclyWritableFilesAreRefusedWithoutAddingAMark() throws {
        let fixture = try DownloadFixture(), (url, fd) = try fixture.create(); defer { close(fd) }
        XCTAssertEqual(write(fd, [UInt8(7)], 1), 1); XCTAssertThrowsError(try DownloadedFileQuarantine.markEmptyFile(fd, at: url)); XCTAssertNil(fixture.raw(fd))
        let (second, other) = try fixture.create("Public.bin"); defer { close(other) }; XCTAssertEqual(fchmod(other, 0o666), 0)
        XCTAssertThrowsError(try DownloadedFileQuarantine.markEmptyFile(other, at: second)); XCTAssertNil(fixture.raw(other))
    }
    func testReplacedPathDoesNotTagEitherObject() throws {
        let fixture = try DownloadFixture(), (url, fd) = try fixture.create(); defer { close(fd) }
        let retained = fixture.folder.appendingPathComponent("Retained.bin")
        try FileManager().moveItem(at: url, to: retained); let (_, replacement) = try fixture.create(); defer { close(replacement) }
        XCTAssertThrowsError(try DownloadedFileQuarantine.markEmptyFile(fd, at: url)); XCTAssertNil(fixture.raw(fd)); XCTAssertNil(fixture.raw(replacement))
    }
    func testAChangedMarkInvalidatesTheWitness() throws {
        let fixture = try DownloadFixture(), (url, fd) = try fixture.create(); defer { close(fd) }
        let witness = try DownloadedFileQuarantine.markEmptyFile(fd, at: url)
        let altered = Data("generated-invalid-mark".utf8)
        XCTAssertEqual(altered.withUnsafeBytes { fsetxattr(fd, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_REPLACE) }, 0)
        XCTAssertThrowsError(try witness.validate(fd))
    }
}
