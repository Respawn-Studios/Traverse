import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SFTPDirectoryRecoveryProtocolTests: XCTestCase {
    private let session = UUID(), generation = UUID()
    private func frame(_ sequence: UInt64, _ kind: UInt8, _ payload: Data = Data(), mode: SFTPWireMode = .folderCatalog) throws -> Data {
        try SFTPWire.body(session: session, sequence: sequence, kind: kind, mode: mode) + payload
    }
    private func ready(_ mode: SFTPWireMode = .folderCatalog) throws -> SFTPWorkerDecoder {
        var value = try SFTPWorkerDecoder(session: session, canonicalHost: "generated.example", port: 22, mode: mode)
        var key = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &key); try SFTPWire.field(Data(repeating: 1, count: 32), into: &key)
        var hello = Data([1]); try SFTPWire.field(Data("generated.example".utf8), into: &hello); SFTPWire.number(22, bytes: 2, into: &hello)
        try SFTPWire.field(key, into: &hello); try SFTPWire.field(Data(), into: &hello)
        guard case .challenge(let challenge) = try value.consume(frame(0, 100, hello, mode: mode)) else { throw SFTPProtocolFailure.phase }
        try value.noteApproval(.connectOnce, challenge: challenge)
        _ = try value.consume(frame(1, 101, mode: mode)); _ = try value.consume(frame(2, 102, mode: mode)); _ = try value.consume(frame(3, 109, mode: mode))
        return value
    }
    private func enabled() throws -> SFTPWorkerDecoder {
        var value = try ready(); try value.beginDirectoryRecovery()
        guard case .directoryRecoveryEnabled = try value.consume(frame(4, 169, Data([1]))) else { throw SFTPProtocolFailure.phase }
        return value
    }
    func testCapabilityIsExplicitAndLegacyModesDoNotGainItImplicitly() throws {
        for mode: SFTPWireMode in [.catalog, .transferCatalog, .keyCatalog, .interactiveCatalog, .folderCatalog, .exclusiveUploadCatalog, .freshFolderUploadCatalog] {
            var value = try ready(mode); try value.beginDirectoryRecovery()
            guard case .directoryRecoveryEnabled = try value.consume(frame(4, 169, Data([1]), mode: mode)) else { return XCTFail() }
            XCTAssertThrowsError(try value.beginDirectoryRecovery())
        }
        var batch = try ready(.batches); XCTAssertThrowsError(try batch.beginDirectoryRecovery())
        var legacy = try ready(); try legacy.beginDirectory(generation)
        XCTAssertThrowsError(try legacy.consume(frame(4, 170, SFTPWire.token(generation) + Data([3]))))
    }
    func testNegotiationRefusesUnsolicitedWrongVersionDuplicateOrTrailingReply() throws {
        for variant in 0..<5 {
            var value = try ready()
            if variant != 0 { try value.beginDirectoryRecovery() }
            if variant == 1 { _ = try value.consume(frame(4, 169, Data([1]))) }
            let sequence: UInt64 = variant == 1 ? 5 : 4
            let payload = Data(variant == 2 ? [2] : variant == 3 ? [1, 0] : variant == 4 ? [] : [1])
            XCTAssertThrowsError(try value.consume(frame(sequence, 169, payload)))
            XCTAssertThrowsError(try value.consume(frame(sequence + 1, 169, Data([1]))))
        }
    }
    func testEachAllowedStatusClearsAuthorityAndAllowsAnotherExplicitDirectory() throws {
        for status: UInt8 in [2, 3, 4] {
            var value = try enabled(); try value.beginDirectory(generation)
            guard case .directoryRejected(let id, let reason) = try value.consume(frame(5, 170, SFTPWire.token(generation) + Data([status]))) else { return XCTFail() }
            XCTAssertEqual(id, generation); XCTAssertEqual(reason.rawValue, status)
            XCTAssertThrowsError(try value.beginNext(generation))
            XCTAssertThrowsError(try value.beginPage(UUID(), generation: generation, snapshot: .init(read: 1, revision: 0, count: 1, folders: 0, state: .complete), offset: 0, limit: 1))
            try value.beginDirectory(UUID())
        }
    }
    func testRejectedReplyRefusesWrongGenerationStatusPhaseAndExtraBytes() throws {
        for variant in 0..<7 {
            var value = try enabled()
            if variant != 0 { try value.beginDirectory(generation) }
            let id = variant == 1 ? UUID() : generation
            let status: UInt8 = variant == 2 ? 0 : variant == 3 ? 1 : variant == 4 ? 8 : 3
            var payload = SFTPWire.token(id) + Data([status])
            if variant == 5 { payload.append(0) }
            if variant == 6 { payload = Data(payload.prefix(16)) }
            XCTAssertThrowsError(try value.consume(frame(5, 170, payload)))
            XCTAssertThrowsError(try value.consume(frame(6, 170, SFTPWire.token(generation) + Data([3]))))
        }
    }
    func testAReplyCannotBeRepeatedOrNegotiatedDuringADirectoryAttempt() throws {
        var value = try enabled(); try value.beginDirectory(generation)
        _ = try value.consume(frame(5, 170, SFTPWire.token(generation) + Data([3])))
        XCTAssertThrowsError(try value.consume(frame(6, 170, SFTPWire.token(generation) + Data([3]))))
        var pending = try ready(); try pending.beginDirectory(generation)
        XCTAssertThrowsError(try pending.beginDirectoryRecovery())
    }
}
