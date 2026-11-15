import CryptoKit
import CoreServices
import Darwin
import Foundation
@_spi(ArchiveProduction) @testable import FileOperations
@testable import LocalStorage
import Testing

struct TARTextEditTests {
    private typealias Fixture = TARTestFixture
    private func parsed(_ bytes: Data) throws -> TARParsedDirectory {
        try TARMetadataParser.parse(length: UInt64(bytes.count), check: {}, read: {
            bytes.subdata(in: Int($0)..<(Int($0) + $1))
        })
    }

    @Test(arguments: [false, true]) func preservesRawMetadataAndUnchangedMembers(pax: Bool) async throws {
        let fixture = try Fixture(pax: pax), document = try await fixture.document()
        let edited = try TextDocumentValue.edited("{\n    \"value\": 42\n}\n", format: document.contents.format)
        let producer = try PreparedTARMemberMutation(document, contents: edited, check: {})
        let (output, fd) = try fixture.output(); defer { close(fd) }
        let receipt = try producer.produce(into: fd, check: {}, progress: { _, _ in })
        let bytes = try Data(contentsOf: output), before = try parsed(fixture.bytes), after = try parsed(bytes)
        #expect(receipt.contentSHA256 == Data(SHA256.hash(data: bytes)))
        #expect(after.records.map(\.path) == ["data.json", "other.bin", "empty"])
        let old = before.records[0], new = after.records[0]
        #expect(new.bytes == UInt64(edited.encoded.count))
        #expect(bytes[Int(new.dataOffset)..<Int(new.dataOffset + new.bytes)] == edited.encoded)
        for range in [100..<124, 157..<512] {
            #expect(fixture.bytes[(Int(old.headerOffset) + range.lowerBound)..<(Int(old.headerOffset) + range.upperBound)]
                == bytes[(Int(new.headerOffset) + range.lowerBound)..<(Int(new.headerOffset) + range.upperBound)])
        }
        #expect(fixture.bytes[Int(before.records[1].headerOffset)...] == bytes[Int(after.records[1].headerOffset)...])
        if pax {
            let retained = TARMemberHeader.attribute("uid", "123456789")
                + TARMemberHeader.attribute("uname", "original owner")
            #expect(bytes.range(of: retained) != nil)
            #expect(bytes.range(of: TARMemberHeader.attribute("atime", "1700000000.125")) != nil)
            #expect(bytes.range(of: TARMemberHeader.attribute("size", String(edited.encoded.count))) != nil)
        }
        #expect(try Data(contentsOf: fixture.source) == fixture.bytes)
    }

    @Test func rejectsStaleSourceAndUnsupportedMemberTypes() async throws {
        let linked = try Fixture(link: true), linkedDocument = try await linked.document()
        #expect(throws: TARMemberEditFailure.unsupportedArchive) {
            try PreparedTARMemberMutation(linkedDocument, contents: linkedDocument.contents, check: {})
        }
        let fixture = try Fixture(), document = try await fixture.document()
        let producer = try PreparedTARMemberMutation(document, contents: document.contents, check: {})
        try Data("changed".utf8).write(to: fixture.source)
        #expect(throws: FileOperationFailure.sourceChanged) { try producer.validate(check: {}) }
    }

    @Test func refusesCorruptStageAndCancellationWithoutReceipt() async throws {
        let fixture = try Fixture(), document = try await fixture.document()
        var hooks = ZIPCreationHooks()
        hooks.beforeValidation = { fd in
            var byte: UInt8 = 255
            guard pwrite(fd, &byte, 1, 0) == 1 else { throw FileOperationFailure.ioFailure }
        }
        let producer = try PreparedTARMemberMutation(document, contents: document.contents, check: {}, hooks: hooks)
        let (_, fd) = try fixture.output(); defer { close(fd) }
        #expect(throws: (any Error).self) { try producer.produce(into: fd, check: {}, progress: { _, _ in }) }
        let cancelled = try Fixture(), original = try await cancelled.document()
        let second = try PreparedTARMemberMutation(original, contents: original.contents, check: {})
        let (output, other) = try cancelled.output(); defer { close(other) }
        #expect(throws: CancellationError.self) {
            try second.produce(into: other, check: { throw CancellationError() }, progress: { _, _ in })
        }
        #expect(try Data(contentsOf: output).isEmpty)
        #expect(try Data(contentsOf: fixture.source) == fixture.bytes)
    }

    @Test func copyUsesGuardedPublicationRebindAndColdUndo() async throws {
        let fixture = try Fixture(pax: true), document = try await fixture.document()
        let history = fixture.root.appendingPathComponent("history")
        let engine = RecoverableFileOperations(journalDirectory: history, strictPortableTARCreationPolicy: .nativeCreateQualification)
        let observed = try await engine.observeSelection([fixture.source])
        let edited = try TextDocumentValue.edited("{\"edited\":true}\n", format: document.contents.format)
        let plan = try await engine.prepareTARMemberTextReplacementCopy(document, contents: edited,
            outputName: "Edited.tar", observing: observed)
        let result = await engine.performArchiveCreation(plan)
        #expect(result.result.disposition == .succeeded)
        let record = try #require(result.recordID)
        let rebound = try await TARArchiveReader().reopenTextForEdit(document, at: plan.destination, expecting: edited)
        #expect(rebound.contents.encoded == edited.encoded)
        #expect(rebound.archivePath == document.archivePath)
        do {
            _ = try await engine.prepareTARMemberTextReplacementCopy(document, contents: edited,
                outputName: "Edited.tar", observing: observed)
            Issue.record("An existing destination must be refused")
        } catch { #expect(error as? FileOperationFailure == .conflict) }
        let cold = RecoverableFileOperations(journalDirectory: history)
        let undo = await cold.undo(recordID: record)
        #expect(undo.result.disposition == .succeeded)
        #expect(!FileManager().fileExists(atPath: plan.destination.path))
        #expect(try Data(contentsOf: fixture.source) == fixture.bytes)
    }

    @Test func originalUpdateHasIndependentAdmissionAndColdUndo() async throws {
        let fixture = try Fixture(pax: true), document = try await fixture.document()
        let history = fixture.root.appendingPathComponent("history")
        let zipOnly = RecoverableFileOperations(journalDirectory: history,
            authoredZIPOriginalUpdateNativePolicy: .qualifiedNativeStage)
        let observed = try await zipOnly.observeSelection([fixture.source])
        let edited = try TextDocumentValue.edited("{\"edited\":true}\n", format: document.contents.format)
        do {
            _ = try await zipOnly.prepareTARMemberTextReplacementOriginal(document, contents: edited, observing: observed)
            Issue.record("ZIP admission must not authorize TAR original updates")
        } catch { #expect(error as? FileOperationFailure == .unsupported) }
        let engine = RecoverableFileOperations(journalDirectory: history,
            authoredTAROriginalUpdatePolicy: .developmentNativeStage)
        let plan = try await engine.prepareTARMemberTextReplacementOriginal(document, contents: edited, observing: observed)
        let result = await engine.performArchiveOriginalUpdate(plan)
        #expect(result.result.disposition == .succeeded)
        let id = try #require(result.recordID)
        let inspection = try await engine.inspectExistingHistory()
        let record = try #require(inspection.records.first { $0.id == id })
        #expect(record.operation == "Update TAR" && record.canUndo)
        let raw = try #require(try OperationJournal(history).inspectRecord(id))
        #expect(raw.version == 18)
        let heldInspection = try await zipOnly.inspectExistingHistory()
        #expect(heldInspection.records.first { $0.id == id }?.canUndo == false)
        let refused = await zipOnly.undo(recordID: id)
        #expect(refused.result.disposition != .succeeded)
        let rebound = try await TARArchiveReader().reopenTextForEdit(document, expecting: edited)
        #expect(rebound.contents.encoded == edited.encoded)
        let cold = RecoverableFileOperations(journalDirectory: history,
            authoredTAROriginalUpdatePolicy: .developmentNativeStage)
        let undone = await cold.undo(recordID: id)
        #expect(undone.result.disposition == .succeeded)
        #expect(try Data(contentsOf: fixture.source) == fixture.bytes)
    }

    @Test func retainedOriginalRequiresExplicitFormatAdmittedRestore() async throws {
        let fixture = try Fixture(), document = try await fixture.document()
        let history = fixture.root.appendingPathComponent("history")
        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, _ in
            if stage == .originalRetained { throw FileOperationFailure.ioFailure }
        }
        let engine = RecoverableFileOperations(journalDirectory: history, hooks: hooks,
            authoredTAROriginalUpdatePolicy: .developmentNativeStage)
        let observed = try await engine.observeSelection([fixture.source])
        let edited = try TextDocumentValue.edited("{\"retained\":true}\n", format: document.contents.format)
        let plan = try await engine.prepareTARMemberTextReplacementOriginal(document, contents: edited, observing: observed)
        let result = await engine.performArchiveOriginalUpdate(plan)
        #expect(result.result.disposition != .succeeded)
        let id = try #require(result.recordID)
        #expect(!FileManager().fileExists(atPath: fixture.source.path))
        let cold = RecoverableFileOperations(journalDirectory: history,
            authoredTAROriginalUpdatePolicy: .developmentNativeStage)
        let before = try await cold.inspectExistingHistory()
        let row = try #require(before.records.first { $0.id == id })
        #expect(row.operation == "Update TAR" && row.canRestoreOriginalZIP && !row.canRecover && !row.canUndo)
        let generic = await cold.recover(recordID: id)
        #expect(generic.result.disposition != .succeeded)
        #expect(!FileManager().fileExists(atPath: fixture.source.path))
        let zipOnly = RecoverableFileOperations(journalDirectory: history,
            authoredZIPOriginalUpdateNativePolicy: .qualifiedNativeStage)
        let wrong = await zipOnly.restoreInterruptedOriginalArchive(recordID: id)
        #expect(wrong.result.disposition != .succeeded)
        #expect(!FileManager().fileExists(atPath: fixture.source.path))
        let restored = await cold.restoreInterruptedOriginalArchive(recordID: id)
        #expect(restored.result.disposition == .succeeded)
        #expect(try Data(contentsOf: fixture.source) == fixture.bytes)
        let after = try await cold.inspectExistingHistory()
        #expect(after.records.first { $0.id == id }?.state == "undone")
    }

    @Test func markedOriginalKeepsNativeStageProtectionWithoutCopyingSourceMark() async throws {
        let fixture = try Fixture()
        @Sendable func mark(_ url: URL, agent: String) throws {
            var properties = URLResourceValues()
            properties.quarantineProperties = [
                kLSQuarantineAgentNameKey as String: agent,
                kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                kLSQuarantineTimeStampKey as String: Date()
            ]
            var target = url; try target.setResourceValues(properties)
        }
        try mark(fixture.source, agent: "Generated TAR source")
        let originalMark = try fixture.source.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        let document = try await fixture.document()
        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, url in
            if stage == .payloadCreated { try mark(url, agent: "Generated TAR stage") }
        }
        let history = fixture.root.appendingPathComponent("history")
        let engine = RecoverableFileOperations(journalDirectory: history, hooks: hooks,
            authoredTAROriginalUpdatePolicy: .developmentNativeStage)
        let observed = try await engine.observeSelection([fixture.source])
        let edited = try TextDocumentValue.edited("{\"marked\":true}\n", format: document.contents.format)
        let plan = try await engine.prepareTARMemberTextReplacementOriginal(document, contents: edited, observing: observed)
        let result = await engine.performArchiveOriginalUpdate(plan)
        #expect(result.result.disposition == .succeeded)
        let properties = try URL(fileURLWithPath: fixture.source.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(properties?[kLSQuarantineAgentNameKey as String] as? String == "Generated TAR stage")
        #expect(originalMark?[kLSQuarantineAgentNameKey as String] as? String == "Generated TAR source")
        let id = try #require(result.recordID)
        let undone = await engine.undo(recordID: id)
        #expect(undone.result.disposition == .succeeded)
        #expect(try Data(contentsOf: fixture.source) == fixture.bytes)
        let restored = try URL(fileURLWithPath: fixture.source.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(restored?[kLSQuarantineAgentNameKey as String] as? String == "Generated TAR source")
    }
}
