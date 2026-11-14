import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SMBBrowserProtocolTests: XCTestCase {
    func testOriginalEditCannotInterleaveWithFindOrFolderSize() throws {
        for first in 0...2 {
            var peer = Peer(); peer.magic = "MEXSMBU1"
            var decoder = SMBBrowserDecoder(session: peer.session, requireEncryption: true, mode: .selectedUpload)
            _ = try decoder.consume(peer.line("connected encrypted"))
            let read = try begin(&decoder, &peer, count: 2)
            _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 1 2 1 1"))
            _ = try decoder.consume(peer.line("idle 1 complete"))
            let snapshot = try XCTUnwrap(decoder.snapshot)
            let file = SMBDirectoryObservation(id: 1, name: try .init("File.txt"), attributes: 32,
                logicalBytes: 3, modifiedFileTime: 12)
            let selected = try SMBDownloadSelection(connection: peer.session, snapshot: snapshot, observation: file)
            let baseline = SMBRemoteFileSnapshot(size: 3, allocated: 4096, created: 11, modified: 12, changed: 13,
                attributes: 32, links: 1, index: 17, volumeCreated: 18, volumeSerial: 19)
            let edit = try SMBOriginalEditRequest(id: UUID(), selection: selected, before: baseline,
                beforeDigest: Data(repeating: 1, count: 32), editedLength: 3, editedDigest: Data(repeating: 2, count: 32))
            let find = try SMBDirectoryFindRequest(query: RemoteDirectoryFindQuery(text: "File"), snapshot: snapshot)
            let folder = SMBDirectoryObservation(id: 2, name: try .init("Folder"), attributes: 16,
                logicalBytes: 0, modifiedFileTime: 12)
            let size = try SMBFolderSizeSelection(connection: peer.session, snapshot: snapshot, observation: folder)
            switch first {
            case 0:
                _ = try decoder.prepareEdit(edit)
                XCTAssertThrowsError(try decoder.request(find))
                XCTAssertThrowsError(try decoder.request(size))
                XCTAssertThrowsError(try decoder.request(SMBDirectoryPageRequest(snapshot: snapshot, offset: 0)))
                XCTAssertThrowsError(try decoder.navigate(components: []))
            case 1:
                _ = try decoder.request(find)
                XCTAssertThrowsError(try decoder.prepareEdit(edit))
            default:
                _ = try decoder.request(size)
                XCTAssertThrowsError(try decoder.prepareEdit(edit))
            }
            XCTAssertTrue(decoder.connected); XCTAssertFalse(decoder.closed)
        }
    }
    func testFolderSizeUsesTheCompleteSelectionOnBrowseOnlyAndDenialDoesNotDisconnect() throws {
        var peer = Peer(), decoder = try connect(&peer)
        let read = try begin(&decoder, &peer)
        _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 1 1 1 1"))
        _ = try decoder.consume(peer.line("idle 1 complete"))
        let snapshot = try XCTUnwrap(decoder.snapshot)
        let row = SMBDirectoryObservation(id: 1, name: try .init("Folder"), attributes: 16, logicalBytes: 0, modifiedFileTime: 0)
        let selected = try SMBFolderSizeSelection(connection: peer.session, snapshot: snapshot, observation: row)
        XCTAssertEqual(try decoder.request(selected), "SIZE_FOLDER \(selected.request.uuidString) 1 \(read.id.uuidString) 1 1 1 1 1\n")
        XCTAssertThrowsError(try decoder.navigate(components: []))
        guard case .folderSizeUnavailable(selected.request, .denied) = try decoder.consume(peer.line("folderSizeUnavailable \(selected.request.uuidString) 2")) else { return XCTFail() }
        XCTAssertTrue(decoder.connected); XCTAssertFalse(decoder.hasPendingPage)
        let again = try SMBFolderSizeSelection(connection: peer.session, snapshot: snapshot, observation: row)
        _ = try decoder.request(again)
        guard case .folderSize(again.request, let measured) = try decoder.consume(peer.line("folderSize \(again.request.uuidString) 1 \(read.id.uuidString) 1 1 1 1 1 8589934592 3000 1 1")) else { return XCTFail() }
        XCTAssertEqual(measured.logicalBytes, 8 << 30); XCTAssertEqual(measured.files, 3_000); XCTAssertEqual(measured.excludedLinks, 1)
        XCTAssertFalse(decoder.hasPendingPage)
        let page = try SMBDirectoryPageRequest(snapshot: snapshot, offset: 0)
        XCTAssertNoThrow(try decoder.request(page))
    }
    func testFindDeadlineIsRequestScopedAndAFilteredPageRetainsReadAndRowIdentity() throws {
        var peer = Peer(), decoder = try connect(&peer)
        let read = try begin(&decoder, &peer, count: 768), snapshot = try XCTUnwrap(decoder.snapshot)
        let first = try RemoteDirectoryFindQuery(text: "Needle")
        _ = try decoder.request(SMBDirectoryFindRequest(query: first, snapshot: snapshot))
        guard case .queryUnavailable(first.id) = try decoder.consume(peer.line("findUnavailable \(first.id.uuidString) 1 deadline")) else { return XCTFail() }
        XCTAssertTrue(decoder.connected); XCTAssertFalse(decoder.closed); XCTAssertFalse(decoder.hasPendingPage)
        let query = try RemoteDirectoryFindQuery(text: "Needle")
        _ = try decoder.request(SMBDirectoryFindRequest(query: query, snapshot: snapshot))
        guard case .found(1, let found) = try decoder.consume(peer.line("find \(query.id.uuidString) 1 \(read.id.uuidString) 0 768 0 0 1 0")) else { return XCTFail() }
        let request = try SMBDirectoryPageRequest(snapshot: snapshot, offset: 0, find: found)
        let command = try decoder.request(request); XCTAssertTrue(command.hasSuffix(" \(query.id.uuidString)\n"))
        XCTAssertNil(try decoder.consume(peer.line("findRow \(request.token.uuidString) 1 \(query.id.uuidString) 701 0 1 0 0 0 0041")))
        guard case .page(1, let page) = try decoder.consume(peer.line("findPage \(request.token.uuidString) 1 \(query.id.uuidString) \(read.id.uuidString) 0 0 1 0 1")) else { return XCTFail() }
        XCTAssertEqual(page.entries.first?.id, 701); XCTAssertEqual(page.request.find, found)
    }
    func testKnownFailedOpenIsRequestScopedAndAllowsTheNextExplicitRead() throws {
        var peer = Peer(), decoder = try connect(&peer)
        let read = try begin(&decoder, &peer, count: 0)
        _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 1 0 0 3"))
        XCTAssertNoThrow(try decoder.consume(peer.line("rejected 1 \(read.id.uuidString) denied")))
        let next = try decoder.navigate(components: [])
        XCTAssertNoThrow(try decoder.consume(peer.line("began 2 \(next.id.uuidString)")))
        XCTAssertTrue(decoder.connected); XCTAssertFalse(decoder.closed)
    }
    func testRejectedReadCannotPageOrAcceptARepeatedOrUnknownRejection() throws {
        for reason in ["denied", "missing", "unavailable"] {
            var peer = Peer(), decoder = try connect(&peer)
            let read = try begin(&decoder, &peer, count: 0)
            _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 1 0 0 3"))
            guard case .rejected(1, let rejection) = try decoder.consume(peer.line("rejected 1 \(read.id.uuidString) \(reason)")) else { return XCTFail() }
            XCTAssertEqual(rejection.rawValue, reason); XCTAssertEqual(decoder.directoryRejection, rejection)
            let page = try SMBDirectoryPageRequest(snapshot: XCTUnwrap(decoder.snapshot), offset: 0)
            XCTAssertThrowsError(try decoder.request(page))
            XCTAssertThrowsError(try decoder.consume(peer.line("rejected 1 \(read.id.uuidString) \(reason)")))
        }
        for payload in ["rejected 1 WRONG denied", "rejected 2 READ denied", "rejected 1 READ authentication", "rejected 1 READ denied extra"] {
            var peer = Peer(), decoder = try connect(&peer); let read = try begin(&decoder, &peer, count: 0)
            _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 1 0 0 3"))
            XCTAssertThrowsError(try decoder.consume(peer.line(payload.replacingOccurrences(of: "READ", with: read.id.uuidString))))
        }
    }
    func testOnlyAnEmptyStoppedGenerationCanBeRejected() throws {
        for state in ["0", "1", "2", "3"] {
            for count in [0, 1] where state != "3" || count != 0 {
                var peer = Peer(), decoder = try connect(&peer); let read = try begin(&decoder, &peer, count: count)
                _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 1 \(count) 0 \(state)"))
                XCTAssertThrowsError(try decoder.consume(peer.line("rejected 1 \(read.id.uuidString) denied")))
            }
        }
        var peer = Peer(), decoder = try connect(&peer); let read = try decoder.navigate(components: [])
        _ = try decoder.consume(peer.line("began 1 \(read.id.uuidString)"))
        XCTAssertThrowsError(try decoder.consume(peer.line("rejected 1 \(read.id.uuidString) denied")))
    }
    func testRejectionRetiresPendingPageWithoutPublishingItIntoNextRead() throws {
        var peer = Peer(), decoder = try connect(&peer); let read = try begin(&decoder, &peer, count: 0)
        let page = try SMBDirectoryPageRequest(snapshot: XCTUnwrap(decoder.snapshot), offset: 0); _ = try decoder.request(page)
        _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 1 0 0 3"))
        _ = try decoder.consume(peer.line("rejected 1 \(read.id.uuidString) missing"))
        let next = try decoder.navigate(components: []); XCTAssertNil(decoder.directoryRejection)
        _ = try decoder.consume(peer.line("began 2 \(next.id.uuidString)"))
        guard case .stale(let token) = try decoder.consume(peer.line("page \(page.token.uuidString) 1 \(read.id.uuidString) 0 0 0")) else { return XCTFail() }
        XCTAssertEqual(token, page.token); XCTAssertFalse(decoder.hasPendingPage)
        _ = try decoder.consume(peer.line("snapshot 2 \(next.id.uuidString) 0 0 0 0"))
        XCTAssertEqual(decoder.snapshot?.readID, next.id); XCTAssertNil(decoder.directoryRejection)
    }
    func testPreviousWorkerVersionIsRefusedBeforeAdmission() {
        let peer = Peer(); var decoder = SMBBrowserDecoder(session: peer.session, requireEncryption: true)
        XCTAssertThrowsError(try decoder.consume(Data("MEXSMBB1 \(peer.session.uuidString) 0 connected encrypted".utf8)))
        XCTAssertFalse(decoder.connected)
    }
    private struct Peer {
        let session = UUID()
        var magic = "MEXSMBB2"
        var sequence = 0
        mutating func line(_ payload: String) -> Data {
            defer { sequence += 1 }
            return Data("\(magic) \(session.uuidString) \(sequence) \(payload)".utf8)
        }
    }
    private func connect(_ peer: inout Peer) throws -> SMBBrowserDecoder {
        var decoder = SMBBrowserDecoder(session: peer.session, requireEncryption: true,
                                        mode: peer.magic == "MEXSMBD1" ? .selectedDownload : .metadata)
        _ = try decoder.consume(peer.line("connected encrypted")); return decoder
    }
    private func begin(_ decoder: inout SMBBrowserDecoder, _ peer: inout Peer, count: Int = 1) throws -> SMBBrowserReadRequest {
        let request = try decoder.navigate(components: [])
        _ = try decoder.consume(peer.line("began \(request.number) \(request.id.uuidString)"))
        _ = try decoder.consume(peer.line("snapshot \(request.number) \(request.id.uuidString) 0 \(count) 0 0"))
        return request
    }
    private func finish(_ read: SMBBrowserReadRequest, _ decoder: inout SMBBrowserDecoder, _ peer: inout Peer) throws {
        _ = try decoder.consume(peer.line("snapshot \(read.number) \(read.id.uuidString) 1 1 0 1"))
        _ = try decoder.consume(peer.line("idle \(read.number) complete"))
    }

    func testSeventyReadsDoNotExpireAndKeepEachGenerationDistinct() throws {
        var peer = Peer(), decoder = try connect(&peer)
        for number in 1...70 {
            let read = try begin(&decoder, &peer)
            XCTAssertEqual(read.number, UInt64(number)); XCTAssertEqual(decoder.snapshot?.readID, read.id)
            try finish(read, &decoder, &peer)
        }
        _ = try decoder.consume(peer.line("profile " + [String](repeating: "0", count: 19).joined(separator: ",")))
        _ = try decoder.consume(peer.line("networkDrained 4 0 1"))
        guard case .closed("stopped") = try decoder.consume(peer.line("closed stopped 1 0")) else { return XCTFail() }
        XCTAssertTrue(decoder.closed); XCTAssertNil(decoder.snapshot)
    }

    func testOldPageDrainsWithoutPublicationAfterNavigation() throws {
        var peer = Peer(), decoder = try connect(&peer)
        let read = try begin(&decoder, &peer)
        let page = try SMBDirectoryPageRequest(snapshot: XCTUnwrap(decoder.snapshot), offset: 0)
        _ = try decoder.request(page)
        let next = try decoder.navigate(components: [SMBRemoteName("Folder")])
        XCTAssertNil(decoder.snapshot)
        XCTAssertNil(try decoder.consume(peer.line("row \(page.token.uuidString) 1 1 0 128 0 0041")))
        guard case .stale(let token) = try decoder.consume(peer.line("page \(page.token.uuidString) 1 \(read.id.uuidString) 0 0 1")) else { return XCTFail() }
        XCTAssertEqual(token, page.token)
        try finish(read, &decoder, &peer)
        _ = try decoder.consume(peer.line("began 2 \(next.id.uuidString)"))
        _ = try decoder.consume(peer.line("snapshot 2 \(next.id.uuidString) 0 0 0 0"))
        XCTAssertEqual(decoder.readNumber, 2); XCTAssertEqual(decoder.snapshot?.count, 0)
    }

    func testRetiredPageTerminalCannotBecomeTheNewRead() throws {
        var peer = Peer(), decoder = try connect(&peer)
        let read = try begin(&decoder, &peer)
        let page = try SMBDirectoryPageRequest(snapshot: XCTUnwrap(decoder.snapshot), offset: 0)
        _ = try decoder.request(page)
        let next = try decoder.navigate(components: [])
        try finish(read, &decoder, &peer)
        _ = try decoder.consume(peer.line("began 2 \(next.id.uuidString)"))
        guard case .stale(let token) = try decoder.consume(peer.line("stale \(page.token.uuidString) 1")) else { return XCTFail() }
        XCTAssertEqual(token, page.token); XCTAssertFalse(decoder.hasPendingPage)
        _ = try decoder.consume(peer.line("snapshot 2 \(next.id.uuidString) 0 0 0 0"))
        XCTAssertEqual(decoder.snapshot?.readID, next.id)
    }

    func testNewReadRequiresThePreviousActualIdleAndOnlyOneFutureAdmission() throws {
        var peer = Peer(), decoder = try connect(&peer)
        _ = try begin(&decoder, &peer)
        let next = try decoder.navigate(components: [])
        XCTAssertThrowsError(try decoder.navigate(components: []))
        XCTAssertThrowsError(try decoder.consume(peer.line("began 2 \(next.id.uuidString)")))
    }

    func testClosedRequiresSocketAndCatalogAndTaskDrainProofs() throws {
        for payload in ["closed stopped 1 0", "networkDrained 4 1 0", "networkDrained 4 0 2", "networkDrained 0 0 0"] {
            var peer = Peer(), decoder = try connect(&peer)
            if payload.hasPrefix("networkDrained") { _ = try decoder.consume(peer.line("profile " + [String](repeating: "0", count: 19).joined(separator: ","))) }
            XCTAssertThrowsError(try decoder.consume(peer.line(payload)))
        }
        for payload in ["closed stopped 0 0", "closed stopped 1 1", "closed arbitrary 1 0"] {
            var peer = Peer(), decoder = try connect(&peer)
            _ = try decoder.consume(peer.line("profile " + [String](repeating: "0", count: 19).joined(separator: ",")))
            _ = try decoder.consume(peer.line("networkDrained 4 0 0"))
            XCTAssertThrowsError(try decoder.consume(peer.line(payload)))
        }
    }

    func testNoDowngradeReplayUnrequestedRowOrOversizedFrame() throws {
        var peer = Peer(), decoder = SMBBrowserDecoder(session: peer.session, requireEncryption: true)
        XCTAssertThrowsError(try decoder.consume(peer.line("connected signed")))
        peer = Peer(); decoder = try connect(&peer)
        XCTAssertThrowsError(try decoder.consume(Data("MEXSMBB2 \(peer.session.uuidString) 0 connected encrypted".utf8)))
        peer = Peer(); decoder = try connect(&peer)
        XCTAssertThrowsError(try decoder.consume(peer.line("row \(UUID().uuidString) 1 1 0 1 0 0041")))
        XCTAssertThrowsError(try decoder.consume(Data(repeating: 65, count: 16513)))
    }

    func testTypedCommandsPreserveRemoteUnicodeAndNeverBecomeFileURLs() throws {
        var peer = Peer(), decoder = try connect(&peer)
        let read = try decoder.navigate(components: [SMBRemoteName("Café"), SMBRemoteName("A B")])
        XCTAssertTrue(read.command.hasSuffix("00430061006600e9,004100200042\n"))
        XCTAssertFalse(read.command.contains("file:"))
        var otherPeer = Peer(), other = try connect(&otherPeer)
        XCTAssertThrowsError(try other.navigate(components: Array(repeating: SMBRemoteName("Folder"), count: 129)))
    }
    func testSelectedDownloadWireAcceptsSequentialFilesInOneCompleteRead() throws {
        var peer = Peer(magic: "MEXSMBD1"), decoder = try connect(&peer)
        let read = try decoder.navigate(components: [])
        _ = try decoder.consume(peer.line("began 1 \(read.id.uuidString)"))
        _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 0 0 0 0"))
        _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 1 2 0 1"))
        _ = try decoder.consume(peer.line("idle 1 complete"))
        let snapshot = try XCTUnwrap(decoder.snapshot)
        for (ordinal, name) in [(1,"A"),(2,"B")] {
            let selection = try SMBDownloadSelection(connection: peer.session, snapshot: snapshot,
                observation: .init(id: Int64(ordinal), name: SMBRemoteName(name), attributes: 32,
                                   logicalBytes: 0, modifiedFileTime: 300))
            XCTAssertTrue(try decoder.prepareDownload(selection).hasPrefix("PREPARE_DOWNLOAD "))
            if ordinal == 1 {
                let premature = try SMBDownloadSelection(connection: peer.session, snapshot: snapshot,
                    observation: .init(id: 2, name: SMBRemoteName("B"), attributes: 32,
                                       logicalBytes: 0, modifiedFileTime: 300))
                XCTAssertThrowsError(try decoder.prepareDownload(premature))
            }
            let encoded = ordinal == 1 ? "0041" : "0042"
            _ = try decoder.consume(peer.line("downloadPrepared \(selection.request.uuidString) \(ordinal) 32 0 300 \(encoded)"))
            XCTAssertTrue(try decoder.beginDownload(selection.request).hasPrefix("BEGIN_DOWNLOAD "))
            guard case .download(.complete(let receipt)) = try decoder.consume(peer.line(
                "downloadComplete \(selection.request.uuidString) \(ordinal) 0")) else { return XCTFail() }
            XCTAssertEqual(receipt.selection, selection)
        }
        XCTAssertEqual(decoder.snapshot, snapshot)
    }
    func testNumericProfileRefusesBodyCommandsAndDuplicateOrUnboundedFields() throws {
        for fault in ["body", "ioctl", "duplicate", "count", "overflow"] {
            var peer = Peer(), decoder = try connect(&peer), counts = [String](repeating: "0", count: 19)
            if fault == "body" { counts[8] = "1" }
            if fault == "ioctl" { counts[11] = "1" }
            if fault == "count" { counts.append("0") }
            if fault == "overflow" { counts[0] = "18446744073709551616" }
            let frame = "profile " + counts.joined(separator: ",")
            if fault == "duplicate" { _ = try decoder.consume(peer.line(frame)) }
            XCTAssertThrowsError(try decoder.consume(peer.line(frame)))
        }
    }
}
