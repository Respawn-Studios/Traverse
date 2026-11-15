import CryptoKit
import CoreServices
import Darwin
import Foundation
@_spi(ArchiveProduction) @testable import FileOperations
@testable import LocalStorage
import Testing
import zlib

struct TARGzipMutationTests {
    private func fixture(compressed: Bool = true, marked: Bool = false, transform: (Data) throws -> Data = { $0 },
        body: (TARArchiveReader, TARArchiveSession, URL, URL, Data) async throws -> Void) async throws {
        let f = try TARTestFixture(pax: true), source = try (compressed ? f.gzipSource() : f.source)
        let bytes = try transform(Data(contentsOf: source)); try bytes.write(to: source)
        if marked { try Self.mark(source, agent: "Generated gzip source") }
        let cache = f.root.appendingPathComponent("cache")
        try FileManager().createDirectory(at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: .init())
        let reader = TARArchiveReader(compressedPool: pool)
        let session = try await (compressed ? reader.prepareCompressed(source) : reader.open(source))
        do { try await body(reader, session, source, f.root.appendingPathComponent("history"), bytes) }
        catch { await session.close(); _ = await pool.closeAndDrain(); throw error }
        await session.close(); #expect(await pool.closeAndDrain())
    }
    private func document(_ reader: TARArchiveReader, _ session: TARArchiveSession) async throws -> TARTextEditDocument {
        let selection = try await session.selectionForTextPreview(atPath: "data.json")
        return try await reader.openTextForEdit(selection)
    }
    private static func mark(_ url: URL, agent: String) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: agent,
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineTimeStampKey as String: Date()]
        var target = url; try target.setResourceValues(values)
    }
    @Test(arguments: [false, true], [UInt32(0), UInt32.max])
    func headerFieldsTextSaveRebindAndExactColdUndo(text: Bool, time: UInt32) async throws {
        try await fixture(transform: { input in
            var bytes = input; bytes[3] = text ? 1 : 0; bytes[9] = text ? 255 : 3; bytes[8] = 2
            for n in 0..<4 { bytes[4 + n] = UInt8(truncatingIfNeeded: time >> (n * 8)) }
            return bytes
        }) { reader, session, source, history, before in
            let opened = try await document(reader, session)
            let edited = try TextDocumentValue.edited("{\"saved\":true}\n", format: opened.contents.format)
            let engine = RecoverableFileOperations(journalDirectory: history,
                tarGzipCreationPolicy: .developmentNativeCreate, authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage)
            let observed = try await engine.observeSelection([source])
            let plan = try await engine.prepareTARMemberTextReplacementOriginal(opened, contents: edited, observing: observed)
            let result = await engine.performArchiveOriginalUpdate(plan)
            #expect(result.result.disposition == .succeeded)
            let output = try Data(contentsOf: source)
            #expect(try GzipArchiveHeader(output.prefix(10)) == GzipArchiveHeader(before.prefix(10)))
            #expect(output[8] == 0)
            let rebound = try await reader.reopenTextForEdit(opened, expecting: edited)
            #expect(rebound.contents.encoded == edited.encoded && rebound.isCompressed)
            let id = try #require(result.recordID)
            for wrong in [RecoverableFileOperations(journalDirectory: history,
                authoredZIPOriginalUpdateNativePolicy: .qualifiedNativeStage),
                RecoverableFileOperations(journalDirectory: history, authoredTAROriginalUpdatePolicy: .developmentNativeStage),
                RecoverableFileOperations(journalDirectory: history, tarGzipCreationPolicy: .developmentNativeCreate)] {
                let rows = try await wrong.inspectExistingHistory()
                #expect(rows.records.first { $0.id == id }?.canUndo == false)
                #expect(await wrong.undo(recordID: id).result.disposition != .succeeded)
                #expect(try Data(contentsOf: source) == output)
            }
            let cold = RecoverableFileOperations(journalDirectory: history, authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage)
            #expect(try await cold.inspectExistingHistory().records.first { $0.id == id }?.operation == "Update TAR.gz")
            #expect(await cold.undo(recordID: id).result.disposition == .succeeded)
            #expect(try Data(contentsOf: source) == before)
        }
    }
    private func withHeader(_ input: Data, flags: UInt8, empty: Bool = false) -> Data {
        var bytes = Data(input.prefix(10)); bytes[3] = flags; bytes[8] = 2
        if flags & 4 != 0 { bytes.append(empty ? Data([0, 0]) : Data([3, 0, 0, 255, 3])) }
        if flags & 8 != 0 { bytes.append(empty ? Data([0]) : Data([46, 46, 47, 255, 0])) }
        if flags & 16 != 0 { bytes.append(empty ? Data([0]) : Data([99, 0xfe, 109, 0])) }
        if flags & 2 != 0 {
            let crc = bytes.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(bytes.count)) }
            bytes.append(contentsOf: [UInt8(truncatingIfNeeded: crc), UInt8(truncatingIfNeeded: crc >> 8)])
        }
        bytes.append(input.dropFirst(10)); return bytes
    }
    @Test(arguments: [UInt8(2), 4, 8, 16, 30, 31], [false, true])
    func optionalHeadersKeepOpaqueFieldsAndRegenerateHeaderCRC(flag: UInt8, empty: Bool) async throws {
        try await fixture(transform: { input in
            withHeader(input, flags: flag, empty: empty)
        }) { _, session, source, history, before in
            let destination = try await session.destinationForMemberChanges(session.root)
            let engine = RecoverableFileOperations(journalDirectory: history, authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage)
            let observed = try await engine.observeSelection([source])
            let plan = try await engine.prepareTARMemberMutationOriginal(.newFile(destination, name: "New.txt"), observing: observed)
            let result = await engine.performArchiveOriginalUpdate(plan)
            #expect(result.result.disposition == .succeeded)
            let output = try Data(contentsOf: source)
            #expect(try GzipArchiveHeader(output) == GzipArchiveHeader(before))
            #expect(output[8] == 0)
            let cold = RecoverableFileOperations(journalDirectory: history, authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage)
            #expect(await cold.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
            #expect(try Data(contentsOf: source) == before)
        }
    }
    @Test func malformedReservedAndOverBudgetHeadersRefuseBeforeMutation() throws {
        let fixed = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
        var reserved = fixed; reserved[3] = 32
        var missingName = fixed; missingName[3] = 8; missingName.append(Data(repeating: 65, count: 65_526))
        var badExtra = fixed; badExtra[3] = 4; badExtra.append(contentsOf: [255, 255, 1])
        var badCRC = withHeader(fixed, flags: 2); badCRC[10] ^= 1
        for bytes in [Data(fixed.prefix(9)), reserved, missingName, badExtra, badCRC] {
            #expect(throws: TARMemberEditFailure.unsupportedArchive) { try GzipArchiveHeader(bytes) }
        }
        var maximum = fixed; maximum[3] = 8; maximum.append(Data(repeating: 65, count: 65_525)); maximum.append(0)
        #expect(try GzipArchiveHeader(maximum).name?.count == 65_525)
        maximum.insert(65, at: 10)
        #expect(throws: TARMemberEditFailure.unsupportedArchive) { try GzipArchiveHeader(maximum) }
    }
    @Test func maximumHeaderSurvivesEncoderChunkBoundaryAndColdUndo() async throws {
        try await fixture(transform: { input in
            var header = Data(input.prefix(10)); header[3] = 8
            header.append(Data(repeating: 65, count: 65_525)); header.append(0)
            return header + input.dropFirst(10)
        }) { _, session, source, history, before in
            let root = try await session.destinationForMemberChanges(session.root)
            let engine = RecoverableFileOperations(journalDirectory: history,
                authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage)
            let plan = try await engine.prepareTARMemberMutationOriginal(.newFile(root, name: "Boundary.txt"),
                observing: try await engine.observeSelection([source]))
            let result = await engine.performArchiveOriginalUpdate(plan)
            #expect(result.result.disposition == .succeeded)
            #expect(try GzipArchiveHeader(Data(contentsOf: source)) == GzipArchiveHeader(before))
            let cold = RecoverableFileOperations(journalDirectory: history,
                authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage)
            #expect(await cold.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
            #expect(try Data(contentsOf: source) == before)
        }
    }
    @Test func concatenatedEmptyMemberRefusesEvenWhenDecodedTARIsUnchanged() async throws {
        try await fixture(transform: { $0 + Data([0x1f,0x8b,8,0,0,0,0,0,0,3,3,0,0,0,0,0,0,0,0,0]) }) { _, session, source, history, before in
            let root = try await session.destinationForMemberChanges(session.root)
            let engine = RecoverableFileOperations(journalDirectory: history, authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage)
            let observed = try await engine.observeSelection([source])
            await #expect(throws: (any Error).self) {
                try await engine.prepareTARMemberMutationOriginal(.newFolder(root, name: "New"), observing: observed)
            }
            #expect(try Data(contentsOf: source) == before)
        }
    }
    @Test func retainedCompressedOriginalUsesOnlyItsOwnExplicitRestore() async throws {
        try await fixture { reader, session, source, history, before in
            let opened = try await document(reader, session)
            var hooks = RecoveryHooks()
            hooks.archiveProduction.stage = { stage, _ in if stage == .originalRetained { throw FileOperationFailure.ioFailure } }
            let engine = RecoverableFileOperations(journalDirectory: history, hooks: hooks,
                authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage)
            let observed = try await engine.observeSelection([source])
            let edited = try TextDocumentValue.edited("{\"interrupted\":true}\n", format: opened.contents.format)
            let plan = try await engine.prepareTARMemberTextReplacementOriginal(opened, contents: edited, observing: observed)
            let result = await engine.performArchiveOriginalUpdate(plan), id = try #require(result.recordID)
            #expect(result.result.disposition != .succeeded && !FileManager().fileExists(atPath: source.path))
            let cold = RecoverableFileOperations(journalDirectory: history, authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage)
            let row = try #require(try await cold.inspectExistingHistory().records.first { $0.id == id })
            #expect(row.canRestoreOriginalZIP && !row.canRecover && !row.canUndo)
            #expect(row.originalArchiveFormatName == "TAR.gz")
            #expect(await cold.recover(recordID: id).result.disposition != .succeeded)
            #expect(await cold.restoreInterruptedOriginalArchive(recordID: id).result.disposition == .succeeded)
            #expect(try Data(contentsOf: source) == before)
        }
    }
    @Test func consumedPlanDoesNotKeepItsPreparedSpoolAlive() async throws {
        let f = try TARTestFixture(), source = try f.gzipSource(), cache = f.root.appendingPathComponent("cache")
        try FileManager().createDirectory(at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: .init())
        let reader = TARArchiveReader(compressedPool: pool)
        let engine = RecoverableFileOperations(journalDirectory: f.root.appendingPathComponent("history"),
            authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage)
        func prepare() async throws -> ArchiveUpdatePlan {
            let session = try await reader.prepareCompressed(source)
            let destination = try await session.destinationForMemberChanges(session.root)
            let observed = try await engine.observeSelection([source])
            let plan = try await engine.prepareTARMemberMutationOriginal(.newFile(destination, name: "Fresh.txt"), observing: observed)
            await session.close(); return plan
        }
        let plan = try await prepare()
        #expect(await engine.performArchiveOriginalUpdate(plan).result.disposition == .succeeded)
        #expect(await pool.closeAndDrain())
        // The caller still owns the consumed plan when the pool drains.
        withExtendedLifetime(plan) {}
    }
    @Test func markedOriginalRetainsItsOwnStageProtectionAndRestoresItsOriginalProperties() async throws {
        try await fixture(marked: true) { reader, session, source, history, before in
            let opened = try await document(reader, session)
            let properties = try #require(try URL(fileURLWithPath: source.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
            var hooks = RecoveryHooks()
            hooks.archiveProduction.stage = { stage, payload in
                if stage == .payloadCreated { try Self.mark(payload, agent: "Generated gzip stage") }
            }
            let engine = RecoverableFileOperations(journalDirectory: history, hooks: hooks,
                authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage)
            let observed = try await engine.observeSelection([source])
            let edited = try TextDocumentValue.edited("{\"marked\":true}\n", format: opened.contents.format)
            let plan = try await engine.prepareTARMemberTextReplacementOriginal(opened, contents: edited, observing: observed)
            let result = await engine.performArchiveOriginalUpdate(plan)
            #expect(result.result.disposition == .succeeded)
            let current = try #require(try URL(fileURLWithPath: source.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
            #expect(current[kLSQuarantineAgentNameKey as String] as? String == "Generated gzip stage")
            let cold = RecoverableFileOperations(journalDirectory: history, authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage)
            #expect(await cold.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
            #expect(try Data(contentsOf: source) == before)
            let restored = try #require(try URL(fileURLWithPath: source.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
            #expect((restored as NSDictionary).isEqual(to: properties))
        }
    }
    @Test func changedCompressedOriginalRefusesWithoutPublishingTheStaleSpool() async throws {
        try await fixture { _, session, source, history, before in
            let root = try await session.destinationForMemberChanges(session.root)
            let engine = RecoverableFileOperations(journalDirectory: history, authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage)
            let observed = try await engine.observeSelection([source])
            let plan = try await engine.prepareTARMemberMutationOriginal(.newFile(root, name: "New.txt"), observing: observed)
            var changed = before; changed[4] ^= 1; try changed.write(to: source)
            let result = await engine.performArchiveOriginalUpdate(plan)
            #expect(result.result.disposition != .succeeded)
            #expect(try Data(contentsOf: source) == changed)
        }
    }
    @Test(arguments: [false, true], [false, true])
    func updateStageMarkNeedsItsOwnAdmission(admitted: Bool, gzip: Bool) async throws {
        try await fixture(compressed: gzip, marked: true) { reader, session, source, history, before in
            let opened = try await document(reader, session)
            var hooks = RecoveryHooks()
            hooks.archiveProduction.stage = { stage, payload in
                if stage == .payloadCreated {
                    let result = payload.path.withCString { removexattr($0, "com.apple.quarantine", 0) }
                    guard result == 0 || errno == ENOATTR else { throw FileOperationFailure.ioFailure }
                }
            }
            let engine = RecoverableFileOperations(journalDirectory: history, hooks: hooks,
                nativeAuthoredCreatePublicMarkPolicy: .sourceQualification,
                nativeAuthoredUpdatePublicMarkPolicy: admitted ? .sourceQualification : .held,
                authoredTAROriginalUpdatePolicy: .developmentNativeStage,
                authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage)
            let observed = try await engine.observeSelection([source])
            let edited = try TextDocumentValue.edited("{\"native\":true}\n", format: opened.contents.format)
            let plan = try await engine.prepareTARMemberTextReplacementOriginal(opened, contents: edited, observing: observed)
            let result = await engine.performArchiveOriginalUpdate(plan)
            if !admitted {
                let unchanged = try Data(contentsOf: source)
                #expect(result.result.disposition != .succeeded && unchanged == before)
                return
            }
            #expect(result.result.disposition == .succeeded)
            let current = try #require(try URL(fileURLWithPath: source.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
            #expect(current[kLSQuarantineAgentNameKey as String] as? String == "Traverse")
            #expect(current[kLSQuarantineTimeStampKey as String] is Date)
            #expect(current[kLSQuarantineTypeKey as String] == nil)
            let cold = RecoverableFileOperations(journalDirectory: history,
                authoredTAROriginalUpdatePolicy: .developmentNativeStage, authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage)
            #expect(await cold.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
            #expect(try Data(contentsOf: source) == before)
        }
    }
}
