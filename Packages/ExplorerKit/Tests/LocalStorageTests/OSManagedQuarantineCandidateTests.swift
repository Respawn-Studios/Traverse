import CoreServices
import Darwin
import Foundation
import XCTest
@testable import LocalStorage

private struct OSMetadataFixture {
    let root: URL
    let stage: URL

    init() throws {
        root = try LocalStorageTestFixtures.directory()
        stage = root.appendingPathComponent("private-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    func file(_ name: String, in parent: URL? = nil) throws -> (URL, Int32) {
        let url = (parent ?? stage).appendingPathComponent(name)
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW_ANY | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw OSManagedQuarantineCandidate.Failure.unsupported }
        return (url, fd)
    }

    func mark(_ url: URL, agent: String) throws {
        let properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: agent,
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineTimeStampKey as String: Date()
        ]
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var target = URL(fileURLWithPath: url.path)
        try target.setResourceValues(values)
    }

    func properties(_ url: URL) throws -> [String: Any]? {
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
    }
}

final class OSManagedQuarantineCandidateTests: XCTestCase {
    func testReceivedFileGetsPublicQuarantineBeforeBodyAndRetainsItAfterWrite() throws {
        let fixture = try OSMetadataFixture()
        let (url, fd) = try fixture.file("received.bin")
        defer { Darwin.close(fd) }
        let witness = try OSManagedQuarantineCandidate.prepareReceivedEmptyStage(fd, at: url)
        XCTAssertEqual(try fixture.properties(url)?[kLSQuarantineTypeKey as String] as? String,
                       kLSQuarantineTypeOtherDownload as String)
        let body = Data(repeating: 0x5a, count: 1024)
        XCTAssertEqual(body.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }, body.count)
        try witness.require(fd, at: url)
    }

    func testExistingOSMarkIsNotReplacedByReceivedFileCandidate() throws {
        let fixture = try OSMetadataFixture()
        let (url, fd) = try fixture.file("already-marked.bin")
        defer { Darwin.close(fd) }
        try fixture.mark(url, agent: "Existing System Agent")
        let witness = try OSManagedQuarantineCandidate.prepareReceivedEmptyStage(fd, at: url)
        XCTAssertEqual(try fixture.properties(url)?[kLSQuarantineAgentNameKey as String] as? String,
                       "Existing System Agent")
        try witness.require(fd, at: url)
    }

    func testMarkedArchivePropagatesPublicMarkToPrivateExtractedMember() throws {
        let fixture = try OSMetadataFixture()
        let (archiveURL, archiveFD) = try fixture.file("archive.zip", in: fixture.root)
        let (memberURL, memberFD) = try fixture.file("member.bin")
        defer { Darwin.close(archiveFD); Darwin.close(memberFD) }
        try fixture.mark(archiveURL, agent: "Original Downloader")
        let witness = try OSManagedQuarantineCandidate.prepareExtractedStage(memberFD, at: memberURL,
                                                                             from: archiveFD, at: archiveURL)
        XCTAssertEqual(try fixture.properties(memberURL)?[kLSQuarantineAgentNameKey as String] as? String,
                       "Traverse")
        XCTAssertNil(try fixture.properties(memberURL)?[kLSQuarantineOriginURLKey as String])
        try witness.require(memberFD, at: memberURL)
    }

    func testUnmarkedArchiveDoesNotCauseCandidateToInventAnOrigin() throws {
        let fixture = try OSMetadataFixture()
        let (archiveURL, archiveFD) = try fixture.file("plain.zip", in: fixture.root)
        let (memberURL, memberFD) = try fixture.file("plain-member.bin")
        defer { Darwin.close(archiveFD); Darwin.close(memberFD) }
        let witness = try OSManagedQuarantineCandidate.prepareExtractedStage(memberFD, at: memberURL,
                                                                             from: archiveFD, at: archiveURL)
        XCTAssertNil(try fixture.properties(memberURL))
        try witness.require(memberFD, at: memberURL)
    }

    func testExtractedStageMustBeEmptyAndSourcePresenceWitnessRejectsChange() throws {
        let fixture = try OSMetadataFixture()
        let (archiveURL, archiveFD) = try fixture.file("source.zip", in: fixture.root)
        let (memberURL, memberFD) = try fixture.file("member.bin")
        defer { Darwin.close(archiveFD); Darwin.close(memberFD) }
        let source = try OSManagedQuarantineCandidate.observeExtractionSource(archiveFD, at: archiveURL)
        let body = Data("x".utf8)
        XCTAssertEqual(body.withUnsafeBytes { Darwin.write(memberFD, $0.baseAddress, $0.count) }, 1)
        XCTAssertThrowsError(try OSManagedQuarantineCandidate.prepareExtractedStage(memberFD,
            at: memberURL, from: archiveFD, at: archiveURL))
        XCTAssertNil(try fixture.properties(memberURL))
        try fixture.mark(archiveURL, agent: "New Source Mark")
        XCTAssertThrowsError(try source.require(archiveFD, at: archiveURL))
    }

    func testPublishedNameReplacementCannotSatisfyPrivateWitness() throws {
        let fixture = try OSMetadataFixture()
        let (url, fd) = try fixture.file("replace.bin")
        defer { Darwin.close(fd) }
        let witness = try OSManagedQuarantineCandidate.prepareReceivedEmptyStage(fd, at: url)
        try FileManager.default.moveItem(at: url, to: fixture.stage.appendingPathComponent("original.bin"))
        let (_, replacement) = try fixture.file("replace.bin")
        defer { Darwin.close(replacement) }
        XCTAssertThrowsError(try witness.require(fd, at: url))
    }

    func testLostPublicQuarantineCannotSatisfyReceivedStageWitness() throws {
        let fixture = try OSMetadataFixture()
        let (url, fd) = try fixture.file("lost-mark.bin")
        defer { Darwin.close(fd) }
        let witness = try OSManagedQuarantineCandidate.prepareReceivedEmptyStage(fd, at: url)
        var values = URLResourceValues()
        values.quarantineProperties = nil
        var target = URL(fileURLWithPath: url.path)
        try target.setResourceValues(values)
        XCTAssertThrowsError(try witness.require(fd, at: url))
    }

    func testNonemptyReceivedStageIsRefusedBeforeQuarantineWrite() throws {
        let fixture = try OSMetadataFixture()
        let (url, fd) = try fixture.file("nonempty.bin")
        defer { Darwin.close(fd) }
        let body = Data("x".utf8)
        XCTAssertEqual(body.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }, 1)
        XCTAssertThrowsError(try OSManagedQuarantineCandidate.prepareReceivedEmptyStage(fd, at: url))
        XCTAssertNil(try fixture.properties(url))
    }

    func testPublicCopyIntentRejectsExplicitNeverPreserveProperty() throws {
        let ordinary = "com.traverse.generated-opaque"
        XCTAssertTrue(OSManagedQuarantineCandidate.copyIntentAllowsAttribute(named: ordinary))
        let encoded = try XCTUnwrap(ordinary.withCString {
            xattr_name_with_flags($0, XATTR_FLAG_NEVER_PRESERVE)
        })
        defer { free(encoded) }
        XCTAssertFalse(OSManagedQuarantineCandidate.copyIntentAllowsAttribute(named: String(cString: encoded)))
    }
}
