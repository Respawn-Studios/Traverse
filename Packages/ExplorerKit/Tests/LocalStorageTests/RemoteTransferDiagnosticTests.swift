import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class RemoteTransferDiagnosticTests: XCTestCase {
    func testProgressThrottlesAndStagesAreImmediate() {
        var state = RemoteTransferDiagnosticTimeline(uptimeNanoseconds: 0)
        XCTAssertEqual(state.advance(.receive, count: 0, uptimeNanoseconds: 0)?.phase, .transferring)
        for n in 1...10_000 { XCTAssertNil(state.advance(.receive, count: UInt64(n), uptimeNanoseconds: UInt64(n) * 10_000)) }
        XCTAssertEqual(state.advance(.receive, count: 20_000, uptimeNanoseconds: 1_000_000_000)?.count, 20_000)
        XCTAssertNil(state.advance(.receive, count: 19_000, uptimeNanoseconds: 2_000_000_000))
        XCTAssertEqual(state.advance(.verify, count: 20_000, uptimeNanoseconds: 1_000_000_001)?.phase, .verifying)
        XCTAssertEqual(state.advance(.publish, uptimeNanoseconds: 1_000_000_002)?.phase, .committing)
    }
    func testOneGapAndTerminalSurviveSaturatedObservations() {
        var state = RemoteTransferDiagnosticTimeline(uptimeNanoseconds: 0)
        var emitted = 0, gaps = 0
        for n in 0..<5_000 {
            if let value = state.advance(n % 2 == 0 ? .metadata : .review, uptimeNanoseconds: UInt64(n)) {
                emitted += 1; if value.phase == .gap { gaps += 1 }
            }
        }
        XCTAssertEqual(emitted, 2_049); XCTAssertEqual(gaps, 1)
        XCTAssertEqual(state.finish(.failed, uptimeNanoseconds: 5_001)?.phase, .failed)
        XCTAssertNil(state.finish(.completed, uptimeNanoseconds: 5_002))
    }
    func testRegressedAndMaximumClockCannotOverflowOrBypassThrottle() {
        var state = RemoteTransferDiagnosticTimeline(uptimeNanoseconds: 1_000_000_000)
        XCTAssertNotNil(state.advance(.receive, count: 10, uptimeNanoseconds: 1_000_000_000))
        XCTAssertNil(state.advance(.receive, count: 20, uptimeNanoseconds: 0))
        XCTAssertEqual(state.advance(.review, uptimeNanoseconds: 0)?.durationMilliseconds, 0)
        XCTAssertEqual(state.advance(.receive, count: 20, uptimeNanoseconds: 2_000_000_000)?.durationMilliseconds, 1_000)
        XCTAssertNotNil(state.finish(.completed, uptimeNanoseconds: .max))
    }
    func testEveryTerminalIsExactlyOnceAndStopsProgress() {
        for outcome in [RemoteTransferDiagnosticTimeline.Outcome.completed,.partial,.cancelled,.blocked,.failed] {
            var state = RemoteTransferDiagnosticTimeline(uptimeNanoseconds: 0)
            XCTAssertNotNil(state.finish(outcome, uptimeNanoseconds: 1)); XCTAssertTrue(state.finished)
            XCTAssertNil(state.advance(.receive, count: 10, uptimeNanoseconds: 2_000_000_000))
            XCTAssertNil(state.finish(outcome, uptimeNanoseconds: 3_000_000_000))
        }
    }
    func testUnchangedProgressIsNotSampledAndMaximumCountIsSafe() {
        var state = RemoteTransferDiagnosticTimeline(uptimeNanoseconds: 0)
        XCTAssertNotNil(state.advance(.receive, count: .max, uptimeNanoseconds: 0))
        XCTAssertNil(state.advance(.receive, count: .max, uptimeNanoseconds: .max))
        XCTAssertNil(state.advance(.receive, uptimeNanoseconds: .max))
        XCTAssertEqual(state.finish(.completed, count: .max, uptimeNanoseconds: .max)?.count, .max)
    }
    func testCanonicalNewErrorsAndUnknownStatusRemainNumeric() throws {
        let values: [(Int64, String)] = [(301,"sftp.worker.busy"),(313,"sftp.worker.sourceChanged"),
            (318,"sftp.worker.forwardDenied"),(401,"sftp.staging.full"),(404,"sftp.staging.unavailable"),
            (451,"sftp.upload.sourceUnavailable"),(458,"sftp.upload.stopped"),(501,"sftp.upload.input"),
            (511,"sftp.upload.sourceChanged"),(601,"sftp.upload.admission"),(614,"sftp.upload.shutdown"),
            (701,"sftp.status.ok"),(704,"sftp.status.permissionDenied")]
        for (code, symbol) in values {
            let value = DiagnosticErrorCode(domain: .network, code: code)
            XCTAssertEqual(value.symbol, symbol)
            XCTAssertEqual(try JSONDecoder().decode(DiagnosticErrorCode.self, from: JSONEncoder().encode(value)), value)
        }
        let unknown = DiagnosticErrorCode(domain: .network, code: 701 + Int64(UInt32.max))
        XCTAssertNil(unknown.symbol)
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticErrorCode.self, from: JSONEncoder().encode(unknown)), unknown)
    }
    func testImportedSymbolsNeverBecomeUserText() throws {
        let incoming = Data("{\"domain\":\"network\",\"code\":401,\"symbol\":\"/Users/private/password\"}".utf8)
        let value = try JSONDecoder().decode(DiagnosticErrorCode.self, from: incoming)
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(value.symbol, "sftp.staging.full")
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("password"))
    }
    func testExistingNetworkCodesAreNotReinterpreted() {
        for (code, symbol) in [(Int64(101),"smb.invalidInput"),(113,"smb.remote"),(201,"sftp.invalidInput"),
                               (210,"sftp.security"),(615,"sftp.upload.openingFinal"),(-1009,"notConnectedToInternet")] {
            XCTAssertEqual(DiagnosticErrorCode(domain: .network, code: code).symbol, symbol)
        }
        for code: Int64 in [0,100,114,200,211,300,319,400,405,450,459,500,512,600,616,700] {
            XCTAssertNil(DiagnosticErrorCode(domain: .network, code: code).symbol)
        }
    }
    func testDirectoryAndGroupErrorsHaveClosedCanonicalSymbols() throws {
        let values: [(Int64,String)] = [(811,"smb.directory.missing"),(812,"smb.directory.denied"),(813,"smb.directory.unavailable"),
            (851,"sftp.group.invalidSelection"),(852,"sftp.group.overlappingSources"),(853,"sftp.group.duplicateNames"),
            (854,"sftp.group.tooLarge"),(855,"sftp.group.historyFull")]
        for (code,symbol) in values {
            let error = DiagnosticErrorCode(domain: .network,code: code)
            XCTAssertEqual(error.symbol,symbol)
            let data = try JSONEncoder().encode(error)
            XCTAssertEqual(try JSONDecoder().decode(DiagnosticErrorCode.self,from: data),error)
        }
        for code: Int64 in [804,810,814,850,856,900] { XCTAssertNil(DiagnosticErrorCode(domain: .network,code: code).symbol) }
        let imported = try JSONDecoder().decode(DiagnosticErrorCode.self,from: Data("{\"domain\":\"network\",\"code\":812,\"symbol\":\"PRIVATE-DIAGNOSTIC-SENTINEL\"}".utf8))
        XCTAssertEqual(imported.symbol,"smb.directory.denied")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(imported),as: UTF8.self).contains("PRIVATE-DIAGNOSTIC-SENTINEL"))
    }
    func testRemoteTextOpenLocalFailureProjectionIsClosedAndBounded() throws {
        let cases: [(any Error, Int64)] = [
            (DownloadQuarantineFailure.unsafe, 1201), (DownloadQuarantineFailure.changed, 1202),
            (DownloadQuarantineFailure.unavailable, 1203),
            (RemoteDownloadStorageFailure.unsafe, 1211), (RemoteDownloadStorageFailure.changed, 1212),
            (RemoteDownloadStorageFailure.unavailable, 1213), (RemoteDownloadStorageFailure.capacity, 1214),
            (RemoteDownloadStorageFailure.busy, 1215), (RemoteDownloadStorageFailure.incomplete, 1216),
            (SFTPSharedBudgetFailure.unsafe, 1231), (SFTPSharedBudgetFailure.busy, 1232),
            (SFTPSharedBudgetFailure.capacity, 1233), (SFTPSharedBudgetFailure.recoveryRequired, 1234),
            (SFTPSharedBudgetFailure.ownerEnded, 1235), (SFTPSharedBudgetFailure.stale, 1236),
            (SFTPSharedBudgetFailure.referenced, 1237)
        ]
        for (failure, code) in cases {
            let projected = try XCTUnwrap(SFTPInPlaceOpenDiagnostic.project(failure))
            XCTAssertEqual(projected.error, .init(domain: .network, code: code))
            XCTAssertNil(projected.cause)
            XCTAssertEqual(try JSONDecoder().decode(DiagnosticErrorCode.self, from: JSONEncoder().encode(projected.error)), projected.error)
        }
        let io = try XCTUnwrap(SFTPInPlaceOpenDiagnostic.project(RemoteDownloadStorageFailure.io(2)))
        XCTAssertEqual(io.error, .init(domain: .network, code: 1217))
        XCTAssertEqual(io.cause, .init(domain: .posix, code: 2))
        XCTAssertNil(SFTPInPlaceOpenDiagnostic.project(RemoteDownloadStorageFailure.io(0))?.cause)
        XCTAssertNil(SFTPInPlaceOpenDiagnostic.project(RemoteDownloadStorageFailure.io(4096))?.cause)
        XCTAssertNil(SFTPInPlaceOpenDiagnostic.project(SFTPBrowserFailure.stale))
    }
}
