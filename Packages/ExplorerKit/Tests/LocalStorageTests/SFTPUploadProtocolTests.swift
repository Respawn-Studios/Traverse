import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SFTPUploadProtocolTests: XCTestCase {
    private let session = UUID(), generation = UUID(), request = UUID()
    private let digest = Data(repeating: 7, count: 32)
    private func selection(size: UInt64 = 3, directory: String = "/generated", name: String = "Cafe\u{301}.bin", revision: UInt64 = 1) throws -> SFTPUploadSelection {
        try .init(request: request, generation: generation, revision: revision, directory: directory, name: SFTPRemoteName(Data(name.utf8)), logicalBytes: size)
    }
    private func frame(_ sequence: UInt64, _ kind: UInt8, _ payload: Data = Data(), mode: SFTPWireMode = .exclusiveUploadCatalog) throws -> Data {
        try SFTPWire.body(session: session, sequence: sequence, kind: kind, mode: mode) + payload
    }
    private func summary(complete: Bool) -> Data {
        var data = Data(); let values: [UInt64] = [1, complete ? 1 : 0, complete ? 2 : 0, 0]
        for value in values { SFTPWire.number(value, bytes: 8, into: &data) }
        data.append(complete ? 1 : 0); return data
    }
    private func opened(mode: SFTPWireMode = .exclusiveUploadCatalog, complete: Bool = true) throws -> SFTPWorkerDecoder {
        var decoder = try SFTPWorkerDecoder(session: session, canonicalHost: "generated.example", port: 22, mode: mode)
        var key = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &key); try SFTPWire.field(Data(repeating: 1, count: 32), into: &key)
        var hello = Data([1]); try SFTPWire.field(Data("generated.example".utf8), into: &hello); SFTPWire.number(22, bytes: 2, into: &hello)
        try SFTPWire.field(key, into: &hello); try SFTPWire.field(Data(), into: &hello)
        guard case .challenge(let challenge) = try decoder.consume(frame(0, 100, hello, mode: mode)) else { throw SFTPProtocolFailure.phase }
        try decoder.noteApproval(.connectOnce, challenge: challenge)
        for (sequence, tag) in [(UInt64(1), UInt8(101)), (2, 102), (3, 109)] { _ = try decoder.consume(frame(sequence, tag, mode: mode)) }
        try decoder.beginDirectory(generation); var directory = SFTPWire.token(generation)
        try SFTPWire.field(Data("/generated".utf8), into: &directory); directory.append(summary(complete: false))
        _ = try decoder.consume(frame(4, 110, directory, mode: mode)); try decoder.beginNext(generation)
        _ = try decoder.consume(frame(5, 111, SFTPWire.token(generation) + summary(complete: complete), mode: mode)); return decoder
    }
    private func start(_ decoder: inout SFTPWorkerDecoder, selection: SFTPUploadSelection? = nil, finalPath: Data? = nil) throws {
        let selected = try selection ?? self.selection(); try decoder.beginUpload(selected)
        var bytes = SFTPWire.token(request); bytes.append(SFTPWire.token(generation)); SFTPWire.number(selected.logicalBytes, bytes: 8, into: &bytes)
        try SFTPWire.field(Data(), into: &bytes); try SFTPWire.field(finalPath ?? selected.finalPath, into: &bytes)
        _ = try decoder.consume(frame(6, 130, bytes))
    }
    private func source(_ sequence: UInt64, offset: UInt64 = 0, count: UInt64 = 3, id: UUID? = nil) throws -> Data {
        var data = SFTPWire.token(id ?? request); SFTPWire.number(offset, bytes: 8, into: &data); SFTPWire.number(count, bytes: 4, into: &data); return try frame(sequence, 131, data)
    }
    private func publication(_ sequence: UInt64, size: UInt64 = 3, digest: Data? = nil) throws -> Data {
        var data = SFTPWire.token(request); SFTPWire.number(size, bytes: 8, into: &data); data.append(digest ?? self.digest); return try frame(sequence, 132, data)
    }
    private func complete(_ sequence: UInt64, size: UInt64 = 3, digest: Data? = nil, flags: [UInt8] = [1, 1, 1, 1]) throws -> Data {
        var data = SFTPWire.token(request); SFTPWire.number(size, bytes: 8, into: &data); data.append(digest ?? self.digest); data.append(contentsOf: flags); return try frame(sequence, 133, data)
    }
    private func fill(_ decoder: inout SFTPWorkerDecoder, permit: Bool = true) throws {
        try start(&decoder); _ = try decoder.consume(source(7)); _ = try decoder.noteUploadSource(request, offset: 0, bytes: Data([1, 2, 3]))
        _ = try decoder.consume(publication(8)); if permit { _ = try decoder.noteUploadPublication(request, digest: digest) }
    }
    func testSelectionIsBoundedByteExactAndRedacted() throws {
        let value = try selection(); XCTAssertFalse(String(reflecting: value).contains("Cafe"))
        let command = try value.command(); XCTAssertNil(command.range(of: Data("/generated".utf8))); XCTAssertNotNil(command.range(of: Data("Cafe\u{301}.bin".utf8)))
        for directory in ["relative", "/a//b", "/a/../b", "/a/", "/a\0b"] { XCTAssertThrowsError(try selection(directory: directory)) }
        XCTAssertThrowsError(try selection(size: (1 << 30) + 1)); XCTAssertThrowsError(try selection(name: String(repeating: "a", count: 256)))
        XCTAssertThrowsError(try selection(name: "a/b")); XCTAssertNoThrow(try selection(directory: "/", name: "literal\\name"))
    }
    func testDistinctModeSealedGenerationRevisionAndCanonicalDirectoryAreRequired() throws {
        for mode in [SFTPWireMode.catalog, .transferCatalog, .uploadCatalog, .keyUploadCatalog, .interactiveUploadCatalog, .folderUploadCatalog] { var value = try opened(mode: mode); XCTAssertThrowsError(try value.beginUpload(selection())) }
        var loading = try opened(complete: false); XCTAssertThrowsError(try loading.beginUpload(selection()))
        var value = try opened(); XCTAssertEqual(try value.uploadDirectory(generation, revision: 1), "/generated")
        XCTAssertThrowsError(try value.beginUpload(selection(revision: 0))); XCTAssertThrowsError(try value.beginUpload(selection(directory: "/other")))
        try value.beginUpload(selection()); XCTAssertThrowsError(try value.beginDirectory(UUID())); XCTAssertThrowsError(try value.beginNext(generation))
        XCTAssertThrowsError(try value.beginPage(UUID(), generation: generation, snapshot: .init(read: 1, revision: 1, count: 2, folders: 0, state: .complete), offset: 0, limit: 1))
    }
    func testFullTypedSourceAndDurablePermitSequenceAllowsFreshBrowsing() throws {
        var value = try opened(); try fill(&value)
        guard case .uploadComplete(let receipt) = try value.consume(complete(9)) else { return XCTFail() }
        XCTAssertEqual(receipt.selection, try selection()); XCTAssertEqual(receipt.digest, digest); XCTAssertNoThrow(try value.beginDirectory(UUID()))
        XCTAssertFalse(String(reflecting: SFTPWorkerEvent.uploadComplete(receipt)).contains("Cafe"))
    }
    func testEmptyFileStillRequiresPublicationPermissionAndAllAcknowledgments() throws {
        var value = try opened(); try start(&value, selection: selection(size: 0))
        _ = try value.consume(publication(7, size: 0)); _ = try value.noteUploadPublication(request, digest: digest)
        guard case .uploadComplete(let receipt) = try value.consume(complete(8, size: 0)) else { return XCTFail() }; XCTAssertEqual(receipt.selection.logicalBytes, 0)
    }
    func testCanonicalEquivalentButDifferentDestinationBytesPoisonOutput() throws {
        var value = try opened()
        XCTAssertThrowsError(try start(&value, finalPath: Data("/generated/Café.bin".utf8)))
        XCTAssertThrowsError(try value.consume(source(7)))
    }
    func testWrongRepeatedAndUnboundedSourceRequestsPoisonOutput() throws {
        for bad in [try source(7, id: UUID()), try source(7, offset: 1), try source(7, count: 0), try source(7, count: 32769)] {
            var value = try opened(); try start(&value); XCTAssertThrowsError(try value.consume(bad)); XCTAssertThrowsError(try value.consume(source(7)))
        }
        var value = try opened(); try start(&value); _ = try value.consume(source(7)); XCTAssertThrowsError(try value.consume(source(8)))
    }
    func testNativeSourceReplyAndPermitCannotSkipOrChangeRequests() throws {
        var value = try opened(); try start(&value)
        XCTAssertThrowsError(try value.noteUploadSource(request, offset: 0, bytes: Data([1, 2, 3])))
        _ = try value.consume(source(7)); XCTAssertThrowsError(try value.noteUploadSource(UUID(), offset: 0, bytes: Data([1, 2, 3])))
        XCTAssertThrowsError(try value.noteUploadSource(request, offset: 0, bytes: Data([1])))
        _ = try value.noteUploadSource(request, offset: 0, bytes: Data([1, 2, 3])); XCTAssertThrowsError(try value.noteUploadPublication(request, digest: digest))
        _ = try value.consume(publication(8)); XCTAssertThrowsError(try value.noteUploadPublication(request, digest: Data(repeating: 8, count: 32)))
        _ = try value.noteUploadPublication(request, digest: digest); XCTAssertThrowsError(try value.noteUploadPublication(request, digest: digest))
    }
    func testCompletionNeedsEveryBytePermitDigestAndAcknowledgment() throws {
        var early = try opened(); try start(&early); XCTAssertThrowsError(try early.consume(publication(7)))
        var unpermitted = try opened(); try fill(&unpermitted, permit: false); XCTAssertThrowsError(try unpermitted.consume(complete(9)))
        for index in 0..<4 {
            var flags: [UInt8] = [1, 1, 1, 1]; flags[index] = 0
            var value = try opened(); try fill(&value); XCTAssertThrowsError(try value.consume(complete(9, flags: flags)))
        }
        var value = try opened(); try fill(&value); XCTAssertThrowsError(try value.consume(complete(9, digest: Data(repeating: 8, count: 32))))
    }
    func testInterruptionFlagsAndStatusMustMatchItsPhaseAndPermission() throws {
        func interrupted(_ cause: UInt8, _ stage: UInt8, _ temporary: UInt8, _ published: UInt8, status: UInt64 = 0) throws -> Data {
            var data = SFTPWire.token(request); data.append(contentsOf: [cause, stage, temporary, published]); SFTPWire.number(status, bytes: 4, into: &data); return try frame(7, 134, data)
        }
        var value = try opened(); try start(&value)
        guard case .uploadInterrupted(let result) = try value.consume(interrupted(8, 1, 0, 0)) else { return XCTFail() }
        XCTAssertEqual(result.cause, .unsupportedSync); XCTAssertFalse(result.temporaryMayExist)
        var created = try opened(); try start(&created)
        guard case .uploadInterrupted(let partial) = try created.consume(interrupted(3, 14, 0, 1)) else { return XCTFail() }
        XCTAssertEqual(partial.phase, .openingFinal); XCTAssertTrue(partial.publicationMayHaveHappened)
        for bad in [try interrupted(3, 4, 0, 0), try interrupted(3, 11, 1, 1), try interrupted(8, 4, 1, 0), try interrupted(6, 3, 1, 0, status: 0), try interrupted(3, 4, 1, 0, status: 3)] {
            var decoder = try opened(); try start(&decoder); XCTAssertThrowsError(try decoder.consume(bad))
        }
    }
    func testFirstOpenRefusalIsRequestBoundAndReleasesNextRequest() throws {
        var value = try opened(); try start(&value)
        guard case .uploadOpenRefused(let refused) = try value.consume(frame(7, 137, SFTPWire.token(request))) else { return XCTFail() }
        XCTAssertEqual(refused.selection, try selection())
        XCTAssertNoThrow(try value.beginDirectory(UUID()))
        XCTAssertFalse(String(reflecting: refused).contains("Cafe"))
        for payload in [SFTPWire.token(UUID()), SFTPWire.token(request) + Data([0])] {
            var wrong = try opened(); try start(&wrong)
            XCTAssertThrowsError(try wrong.consume(frame(7, 137, payload)))
        }
        var afterSource = try opened(); try start(&afterSource)
        _ = try afterSource.consume(source(7)); _ = try afterSource.noteUploadSource(request, offset: 0, bytes: Data([1, 2, 3]))
        XCTAssertThrowsError(try afterSource.consume(frame(8, 137, SFTPWire.token(request))))
    }
    func testTerminalDiscardsLiveSourceStateAndOldModesRefuseNewEvents() throws {
        var value = try opened(); try start(&value)
        var terminal = Data([0, 1, 1]); SFTPWire.number(0, bytes: 8, into: &terminal); SFTPWire.number(0, bytes: 8, into: &terminal); terminal.append(1)
        guard case .closed = try value.consume(frame(7, 107, terminal)) else { return XCTFail() }; XCTAssertThrowsError(try value.consume(source(8)))
        for mode in [SFTPWireMode.catalog, .transferCatalog] { var old = try opened(mode: mode); XCTAssertThrowsError(try old.consume(frame(6, 131, mode: mode))) }
    }
    func testUploadConnectionRetainsExplicitDownloadWithoutOverlappingTransfers() throws {
        var value = try opened()
        let name = try SFTPRemoteName(Data("Download.bin".utf8))
        let row = SFTPStoredRow(observation: 1, entry: .init(name: name, logicalBytes: 3, modifiedSeconds: 19, permissions: 0o100644))
        let selected = try SFTPDownloadSelection(generation: generation, row: row, request: request)
        try value.beginDownload(selected); XCTAssertThrowsError(try value.beginUpload(selection()))
        var start = SFTPWire.token(request); start.append(SFTPWire.token(generation))
        SFTPWire.number(1, bytes: 8, into: &start); SFTPWire.number(3, bytes: 8, into: &start)
        SFTPWire.number(19, bytes: 4, into: &start); SFTPWire.number(0o100644, bytes: 4, into: &start); try SFTPWire.field(name.wireUTF8, into: &start)
        _ = try value.consume(frame(6, 120, start))
        var bytes = SFTPWire.token(request); SFTPWire.number(0, bytes: 8, into: &bytes); try SFTPWire.field(Data([1, 2, 3]), into: &bytes)
        _ = try value.consume(frame(7, 121, bytes))
        var end = SFTPWire.token(request); SFTPWire.number(3, bytes: 8, into: &end); end.append(contentsOf: [1, 1])
        guard case .downloadComplete = try value.consume(frame(8, 122, end)) else { return XCTFail() }
        XCTAssertNoThrow(try value.beginUpload(selection()))
    }
}
