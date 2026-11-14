import CoreServices
import CryptoKit
import Darwin
import Foundation
import XCTest
@_spi(ArchiveProduction) @testable import FileOperations
@testable import LocalStorage

final class TARCreationTests: XCTestCase {
    private static func mark(_ url: URL, agent: String) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: agent,
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineTimeStampKey as String: Date()
        ]
        var target = URL(fileURLWithPath: url.path)
        try target.setResourceValues(values)
    }

    private static func quarantine(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FileOperationFailure.ioFailure }
        defer { close(fd) }
        return try AuthoredZIPSecurityWitness.observe(fd).quarantine
    }

    private struct Fixture {
        let root: URL, folder: URL, file: URL, output: URL
        let bytes = Data((0..<65_539).map { UInt8(truncatingIfNeeded: $0 * 19) })
        init() throws {
            root = try LocalStorageTestFixtures.directory()
            folder = root.appendingPathComponent("Café 日本語", isDirectory: true)
            file = folder.appendingPathComponent(String(repeating: "λ", count: 60) + ".json")
            output = root.appendingPathComponent("Created.tar")
            try FileManager().createDirectory(at: folder.appendingPathComponent("Empty", isDirectory: true), withIntermediateDirectories: true)
            try bytes.write(to: file, options: .withoutOverwriting)
            try FileManager().setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_123.125)], ofItemAtPath: file.path)
        }
        func descriptor(_ name: String = "Created.tar") throws -> Int32 {
            let fd = open(root.appendingPathComponent(name).path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw FileOperationFailure.ioFailure }
            return fd
        }
    }

    func testStreamedTARPreservesUnicodeNamesEmptyFoldersBytesAndFractionalDates() throws {
        let fixture = try Fixture()
        let early = fixture.folder.appendingPathComponent("Early.txt")
        try Data().write(to: early, options: .withoutOverwriting)
        try FileManager().setAttributes([.modificationDate: Date(timeIntervalSince1970: -0.5)], ofItemAtPath: early.path)
        let producer = try PreparedTARCreation([fixture.folder], check: {})
        let fd = try fixture.descriptor(); defer { close(fd) }
        let output = try producer.produce(into: fd, check: {}, progress: { _, _ in })
        let bytes = try Data(contentsOf: fixture.output)
        XCTAssertEqual(output.contentSHA256, Data(SHA256.hash(data: bytes)))
        XCTAssertEqual(bytes.count % 512, 0)
        XCTAssertEqual(bytes.suffix(1024), Data(repeating: 0, count: 1024))
        let parsed = try TARMetadataParser.parse(length: UInt64(bytes.count), check: {}, read: {
            bytes.subdata(in: Int($0)..<(Int($0) + $1))
        })
        XCTAssertEqual(parsed.records.count, 4)
        XCTAssertTrue(parsed.records.allSatisfy { $0.kind == .file || $0.kind == .directory })
        let member = try XCTUnwrap(parsed.records.first { $0.path.hasSuffix(".json") })
        XCTAssertEqual(member.path, fixture.folder.lastPathComponent + "/" + fixture.file.lastPathComponent)
        XCTAssertEqual(member.modification?.date, Date(timeIntervalSince1970: 1_700_000_123.125))
        XCTAssertEqual(bytes.subdata(in: Int(member.dataOffset)..<(Int(member.dataOffset + member.bytes))), fixture.bytes)
        XCTAssertTrue(parsed.records.contains { $0.path == fixture.folder.lastPathComponent + "/Empty" && $0.kind == .directory })
        XCTAssertEqual(parsed.records.first { $0.path.hasSuffix("/Early.txt") }?.modification?.date,
                       Date(timeIntervalSince1970: -0.5))
        XCTAssertEqual(producer.preview.files, 2); XCTAssertEqual(producer.preview.folders, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.bytes)
    }

    func testChangedSourceAndCorruptOutputAreRefused() throws {
        let changed = try Fixture()
        let prepared = try PreparedTARCreation([changed.file], check: {})
        try Data("changed".utf8).write(to: changed.file)
        XCTAssertThrowsError(try prepared.validate(check: {})) { XCTAssertEqual($0 as? FileOperationFailure, .sourceChanged) }

        let corrupt = try Fixture()
        var hooks = ZIPCreationHooks()
        hooks.beforeValidation = { fd in
            let value: [UInt8] = [255]
            guard value.withUnsafeBytes({ pwrite(fd, $0.baseAddress, 1, 0) }) == 1 else { throw FileOperationFailure.ioFailure }
        }
        let producer = try PreparedTARCreation([corrupt.folder], check: {}, hooks: hooks)
        let fd = try corrupt.descriptor(); defer { close(fd) }
        XCTAssertThrowsError(try producer.produce(into: fd, check: {}, progress: { _, _ in }))
        XCTAssertEqual(try Data(contentsOf: corrupt.file), corrupt.bytes)
    }

    func testCancellationAndBoundedOutputDoNotReturnAReceipt() throws {
        let fixture = try Fixture()
        var limits = ZIPCreationHooks(); limits.maximumEncodedBytes = 1023
        XCTAssertThrowsError(try PreparedTARCreation([fixture.folder], check: {}, hooks: limits)) {
            XCTAssertEqual($0 as? TARCreationFailure, .limitReached)
        }
        let producer = try PreparedTARCreation([fixture.folder], check: {})
        let fd = try fixture.descriptor(); defer { close(fd) }
        XCTAssertThrowsError(try producer.produce(into: fd, check: { throw CancellationError() }, progress: { _, _ in })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.output).count, 0)
    }

    func testDefaultHeldCreationAndExplicitStrictCreateColdUndo() async throws {
        let f = try Fixture()
        let history = f.root.appendingPathComponent("history")
        let held = RecoverableFileOperations(journalDirectory: history)
        let observation = try await held.observeSelection([f.folder])
        do {
            _ = try await held.prepareTARCreation(sources: [f.folder], parent: f.root, name: "Created.tar", observing: observation)
            XCTFail("Default engine must hold TAR creation")
        } catch { XCTAssertEqual(error as? FileOperationFailure, .unsupported) }
        let nativeZIP = RecoverableFileOperations(journalDirectory: history, authoredZIPMetadataPolicy: .nativeCreate,
            strictPortableTARCreationPolicy: .developmentExactSource)
        do {
            _ = try await nativeZIP.prepareTARCreation(sources: [f.folder], parent: f.root, name: "Created.tar", observing: observation)
            XCTFail("The ZIP native contract must not admit TAR")
        } catch { XCTAssertEqual(error as? FileOperationFailure, .unsupported) }
        let strict = RecoverableFileOperations(journalDirectory: history, strictPortableTARCreationPolicy: .developmentExactSource)
        let plan = try await strict.prepareTARCreation(sources: [f.folder], parent: f.root, name: "Created.tar", observing: observation)
        let result = await strict.performArchiveCreation(plan)
        XCTAssertEqual(result.result.disposition, .succeeded)
        let cold = RecoverableFileOperations(journalDirectory: history)
        let records = try await cold.inspectExistingHistory()
        XCTAssertEqual(records.records.first?.operation, "Create TAR")
        let id = try XCTUnwrap(result.recordID)
        let before = try XCTUnwrap(OperationJournal(history).inspectRecord(id))
        XCTAssertEqual(before.version, 3)
        let requirement = try await cold.undoAccessRequirement(recordID: id)
        let lead = try XCTUnwrap(requirement)
        XCTAssertEqual(lead.recordID, id)
        XCTAssertEqual(lead.directory.standardizedFileURL.pathComponents, f.root.standardizedFileURL.pathComponents)
        let unchanged = try XCTUnwrap(OperationJournal(history).inspectRecord(id))
        XCTAssertEqual(unchanged.revision, before.revision)
        XCTAssertEqual(unchanged.state, "committed")
        let undo = await cold.undo(recordID: id)
        XCTAssertEqual(undo.result.disposition, .succeeded)
        XCTAssertFalse(FileManager().fileExists(atPath: f.output.path))
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)
        do {
            _ = try await cold.undoAccessRequirement(recordID: id)
            XCTFail("An undone TAR must not offer a cold access prompt")
        } catch { XCTAssertEqual(error as? FileOperationFailure, .recoveryUncertain) }
    }

    func testNativeTARUsesFreshStageSecurityForMarkedAndUnmarkedSources() async throws {
        for marked in [false, true] {
            let f = try Fixture()
            let history = f.root.appendingPathComponent("history")
            if marked { try Self.mark(f.file, agent: "Generated TAR input") }
            let sourceMark = try Self.quarantine(f.file)
            var hooks = RecoveryHooks()
            if marked {
                hooks.archiveProduction.stage = { stage, payload in
                    if stage == .payloadCreated {
                        try Self.mark(payload, agent: "Generated TAR stage")
                    }
                }
            }
            let engine = RecoverableFileOperations(journalDirectory: history, hooks: hooks,
                strictPortableTARCreationPolicy: .nativeCreateQualification)
            let selection = try await engine.observeSelection([f.folder])
            let plan = try await engine.prepareTARCreation(sources: [f.folder], parent: f.root,
                name: "Created.tar", observing: selection)
            let result = await engine.performArchiveCreation(plan)
            XCTAssertEqual(result.result.disposition, .succeeded)
            XCTAssertEqual(try Self.quarantine(f.file), sourceMark)
            XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)
            let outputMark = try Self.quarantine(f.output)
            if marked {
                XCTAssertNotNil(sourceMark)
                XCTAssertNotNil(outputMark)
                XCTAssertNotEqual(outputMark, sourceMark, "The TAR must retain its own stage mark, not copy the source mark")
            }
            let cold = RecoverableFileOperations(journalDirectory: history)
            let undo = await cold.undo(recordID: try XCTUnwrap(result.recordID))
            XCTAssertEqual(undo.result.disposition, .succeeded)
            XCTAssertFalse(FileManager().fileExists(atPath: f.output.path))
            XCTAssertEqual(try Self.quarantine(f.file), sourceMark)
        }
    }

    func testExactAndNativeTARHaveTheSameStreamedBodyWithIndependentStageSecurity() async throws {
        let f = try Fixture()
        let exact = RecoverableFileOperations(journalDirectory: f.root.appendingPathComponent("exact-history"),
            strictPortableTARCreationPolicy: .developmentExactSource)
        let exactPlan = try await exact.prepareTARCreation(sources: [f.folder], parent: f.root,
            name: "Exact.tar", observing: try await exact.observeSelection([f.folder]))
        let exactResult = await exact.performArchiveCreation(exactPlan)
        XCTAssertEqual(exactResult.result.disposition, .succeeded)

        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, payload in
            if stage == .payloadCreated { try Self.mark(payload, agent: "Generated native TAR stage") }
        }
        let native = RecoverableFileOperations(journalDirectory: f.root.appendingPathComponent("native-history"),
            hooks: hooks, strictPortableTARCreationPolicy: .nativeCreateQualification)
        let nativePlan = try await native.prepareTARCreation(sources: [f.folder], parent: f.root,
            name: "Native.tar", observing: try await native.observeSelection([f.folder]))
        let nativeResult = await native.performArchiveCreation(nativePlan)
        XCTAssertEqual(nativeResult.result.disposition, .succeeded)

        XCTAssertEqual(try Data(contentsOf: exactPlan.destination), try Data(contentsOf: nativePlan.destination))
        XCTAssertNotNil(try Self.quarantine(nativePlan.destination))
        XCTAssertNil(try Self.quarantine(f.file))
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)
    }

    func testMarkedSourceRequiresNativeTARStageMarkAndExactSourceRemainsHeld() async throws {
        let f = try Fixture()
        try Self.mark(f.file, agent: "Generated TAR input")
        let originalMark = try Self.quarantine(f.file)
        let history = f.root.appendingPathComponent("history")
        let exact = RecoverableFileOperations(journalDirectory: history,
            strictPortableTARCreationPolicy: .developmentExactSource)
        let selection = try await exact.observeSelection([f.folder])
        do {
            _ = try await exact.prepareTARCreation(sources: [f.folder], parent: f.root,
                name: "Created.tar", observing: selection)
            XCTFail("Exact-source TAR must refuse marked inputs")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, payload in
            guard stage == .payloadCreated else { return }
            let removed = payload.path.withCString { removexattr($0, "com.apple.quarantine", 0) }
            guard removed == 0 || errno == ENOATTR else { throw FileOperationFailure.ioFailure }
        }
        let native = RecoverableFileOperations(journalDirectory: history, hooks: hooks,
            strictPortableTARCreationPolicy: .nativeCreateQualification)
        let ready = try await native.prepareTARCreation(sources: [f.folder], parent: f.root,
            name: "Created.tar", observing: try await native.observeSelection([f.folder]))
        let result = await native.performArchiveCreation(ready)
        XCTAssertEqual(result.result.items.first?.status, .failed(.copyMetadataMismatch))
        XCTAssertFalse(FileManager().fileExists(atPath: f.output.path))
        XCTAssertEqual(try Self.quarantine(f.file), originalMark)
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)
    }

    func testQualifiedPublicStageMarksFreshTARWithoutCopyingSourceMarkAndColdUndo() async throws {
        let f = try Fixture()
        try Self.mark(f.file, agent: "Generated TAR input")
        let sourceMark = try XCTUnwrap(try Self.quarantine(f.file))
        let history = f.root.appendingPathComponent("history")
        let stillExact = RecoverableFileOperations(journalDirectory: history,
            strictPortableTARCreationPolicy: .developmentExactSource,
            nativeAuthoredCreatePublicMarkPolicy: .sourceQualification)
        do {
            _ = try await stillExact.prepareTARCreation(sources: [f.folder], parent: f.root,
                name: "Created.tar", observing: try await stillExact.observeSelection([f.folder]))
            XCTFail("The public-stage policy alone must not admit marked TAR sources")
        } catch { XCTAssertFalse(error is CancellationError) }

        let service = RecoverableFileOperations(journalDirectory: history,
            strictPortableTARCreationPolicy: .nativeCreateQualification,
            nativeAuthoredCreatePublicMarkPolicy: .sourceQualification)
        let plan = try await service.prepareTARCreation(sources: [f.folder], parent: f.root,
            name: "Created.tar", observing: try await service.observeSelection([f.folder]))
        let result = await service.performArchiveCreation(plan)
        XCTAssertEqual(result.result.disposition, .succeeded)
        let outputMark = try XCTUnwrap(try Self.quarantine(f.output))
        XCTAssertNotEqual(outputMark, sourceMark)
        let properties = try XCTUnwrap(try f.output.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        XCTAssertEqual(properties[kLSQuarantineAgentNameKey as String] as? String, "Traverse")
        XCTAssertNotNil(properties[kLSQuarantineTimeStampKey as String] as? Date)
        XCTAssertNil(properties[kLSQuarantineTypeKey as String])
        XCTAssertEqual(try Self.quarantine(f.file), sourceMark)
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)

        let cold = RecoverableFileOperations(journalDirectory: history)
        let undone = await cold.undo(recordID: try XCTUnwrap(result.recordID))
        XCTAssertEqual(undone.result.disposition, .succeeded)
        XCTAssertFalse(FileManager().fileExists(atPath: f.output.path))
        XCTAssertEqual(try Self.quarantine(f.file), sourceMark)
    }

    func testQualifiedPublicTARStageRetainsExistingNativeMark() async throws {
        let f = try Fixture()
        try Self.mark(f.file, agent: "Generated TAR input")
        let sourceMark = try Self.quarantine(f.file)
        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, payload in
            if stage == .payloadCreated { try Self.mark(payload, agent: "Native generated stage") }
        }
        let service = RecoverableFileOperations(journalDirectory: f.root.appendingPathComponent("history"),
            hooks: hooks, strictPortableTARCreationPolicy: .nativeCreateQualification,
            nativeAuthoredCreatePublicMarkPolicy: .sourceQualification)
        let plan = try await service.prepareTARCreation(sources: [f.folder], parent: f.root,
            name: "Created.tar", observing: try await service.observeSelection([f.folder]))
        let result = await service.performArchiveCreation(plan)
        XCTAssertEqual(result.result.disposition, .succeeded)
        let properties = try XCTUnwrap(try f.output.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        XCTAssertEqual(properties[kLSQuarantineAgentNameKey as String] as? String, "Native generated stage")
        XCTAssertEqual(try Self.quarantine(f.file), sourceMark)
    }

    func testQualifiedPublicTARStageRefusesChangedProtectionBeforePublication() async throws {
        let f = try Fixture()
        try Self.mark(f.file, agent: "Generated TAR input")
        let sourceMark = try Self.quarantine(f.file)
        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, payload in
            guard stage == .produced else { return }
            let removed = payload.path.withCString { removexattr($0, "com.apple.quarantine", 0) }
            guard removed == 0 else { throw FileOperationFailure.ioFailure }
        }
        let service = RecoverableFileOperations(journalDirectory: f.root.appendingPathComponent("history"),
            hooks: hooks, strictPortableTARCreationPolicy: .nativeCreateQualification,
            nativeAuthoredCreatePublicMarkPolicy: .sourceQualification)
        let plan = try await service.prepareTARCreation(sources: [f.folder], parent: f.root,
            name: "Created.tar", observing: try await service.observeSelection([f.folder]))
        let result = await service.performArchiveCreation(plan)
        XCTAssertEqual(result.result.items.first?.status, .failed(.sourceChanged))
        XCTAssertFalse(FileManager().fileExists(atPath: f.output.path))
        XCTAssertEqual(try Self.quarantine(f.file), sourceMark)
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)
    }

    func testQualifiedPublicTARStageRequiresPrivateEmptyPayload() async throws {
        let f = try Fixture()
        try Self.mark(f.file, agent: "Generated TAR input")
        let sourceMark = try Self.quarantine(f.file)
        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, payload in
            guard stage == .payloadCreated else { return }
            guard chmod(payload.path, 0o644) == 0 else { throw FileOperationFailure.ioFailure }
        }
        let service = RecoverableFileOperations(journalDirectory: f.root.appendingPathComponent("history"),
            hooks: hooks, strictPortableTARCreationPolicy: .nativeCreateQualification,
            nativeAuthoredCreatePublicMarkPolicy: .sourceQualification)
        let plan = try await service.prepareTARCreation(sources: [f.folder], parent: f.root,
            name: "Created.tar", observing: try await service.observeSelection([f.folder]))
        let result = await service.performArchiveCreation(plan)
        XCTAssertEqual(result.result.items.first?.status, .failed(.copyMetadataMismatch))
        XCTAssertFalse(FileManager().fileExists(atPath: f.output.path))
        XCTAssertEqual(try Self.quarantine(f.file), sourceMark)
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)
    }

    func testQualifiedPublicTARStageRefusesPathSubstitution() async throws {
        let f = try Fixture()
        try Self.mark(f.file, agent: "Generated TAR input")
        let sourceMark = try Self.quarantine(f.file)
        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, payload in
            guard stage == .payloadCreated else { return }
            let displaced = payload.deletingLastPathComponent().appendingPathComponent("displaced-payload")
            guard rename(payload.path, displaced.path) == 0 else { throw FileOperationFailure.ioFailure }
            let replacement = open(payload.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard replacement >= 0 else { throw FileOperationFailure.ioFailure }
            close(replacement)
        }
        let service = RecoverableFileOperations(journalDirectory: f.root.appendingPathComponent("history"),
            hooks: hooks, strictPortableTARCreationPolicy: .nativeCreateQualification,
            nativeAuthoredCreatePublicMarkPolicy: .sourceQualification)
        let plan = try await service.prepareTARCreation(sources: [f.folder], parent: f.root,
            name: "Created.tar", observing: try await service.observeSelection([f.folder]))
        let result = await service.performArchiveCreation(plan)
        XCTAssertEqual(result.result.items.first?.status, .failed(.copyMetadataMismatch))
        XCTAssertFalse(FileManager().fileExists(atPath: f.output.path))
        XCTAssertEqual(try Self.quarantine(f.file), sourceMark)
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)
    }
}
