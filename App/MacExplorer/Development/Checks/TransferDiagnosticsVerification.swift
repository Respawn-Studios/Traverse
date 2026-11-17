#if DEBUG
import AppKit
import FileOperations
@_spi(Qualification) import LocalStorage

/// Exact generated profile only. No connection, password store or personal file.
@MainActor enum TransferDiagnosticsVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws {
        if !value { throw Failure.check(line) }
    }
    static func run() async {
        var root: URL?
        var recorder: DiagnosticRecorder?
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let admitted = URL(fileURLWithPath: raw)
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: admitted.appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(admitted.resolvingSymlinksInPath() == admitted && admitted.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString: admitted.lastPathComponent)?.uuidString == admitted.lastPathComponent
                && marker?["packet"] as? String == "traverse-development-v1" && marker?["action"] as? String == "transfer-diagnostics"
                && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/xcode/Build/Products/Debug/Mac Explorer.app"))
            root = admitted
            let archiveErrors: [(Error, Int64, String)] = [
                (ZIPCreationFailure.resourceFork, 203, "zipCreate.resourceFork"),
                (TARCreationFailure.contentMismatch, 214, "tarCreate.contentMismatch"),
                (ZIPExtractionFailure.destinationChanged, 223, "zipExtract.destinationChanged"),
                (ZIPMemberNewEntryFailure.nameConflict, 234, "zipNew.nameConflict"),
                (BatchRenameValidation.duplicateTarget, 253, "batchRename.duplicateTarget"),
                (ZIPContentFailure.contentMismatch, 263, "zipCheck.contentMismatch")]
            for (error, code, symbol) in archiveErrors {
                let projected = DiagnosticErrors.project(error)
                try require(projected.domain == .archive && projected.code == code && projected.symbol == symbol)
            }
            try require(DiagnosticErrors.project(SFTPDownloadStorageIssue.full) == .init(domain: .network, code: 401))
            try require(DiagnosticErrors.project(SFTPSessionFailure.sourceChanged) == .init(domain: .network, code: 313))
            let workers: [SFTPSessionFailure] = [.busy,.input,.unavailable,.stopped,.deadline,.exited,.output,.remote,
                .authentication,.security,.denied,.storage,.sourceChanged,.keyInput,.keyPassphrase,.keyUnsupported,.keyChanged,.forwardDenied]
            let staging: [SFTPDownloadStorageIssue] = [.full,.busy,.changed,.unavailable]
            let uploads: [SFTPUploadLocalIssue] = [.sourceUnavailable,.unsupportedSource,.additionalFork,.sourceChanged,.historyUnavailable,.historyFull,.busy,.stopped]
            for (n, value) in workers.enumerated() { try require(DiagnosticErrors.project(value).code == 301 + Int64(n) && DiagnosticErrors.project(value).symbol != nil) }
            for (n, value) in staging.enumerated() { try require(DiagnosticErrors.project(value).code == 401 + Int64(n) && DiagnosticErrors.project(value).symbol != nil) }
            for (n, value) in uploads.enumerated() { try require(DiagnosticErrors.project(value).code == 451 + Int64(n) && DiagnosticErrors.project(value).symbol != nil) }
            let logger = DiagnosticRecorder(directory: admitted.appendingPathComponent("state/diagnostics"),
                limits: try .init(bytes: 64 << 10, segmentBytes: 8 << 10), recording: true)
            recorder = logger; ApplicationDiagnostics.shared.configureForVerification(logger)
            let source = admitted.appendingPathComponent("source/Source/Generated-private-file.txt")
            let destination = admitted.appendingPathComponent("source/Destination")
            let engine = RecoverableFileOperations(journalDirectory: admitted.appendingPathComponent("state/operations"))
            let trace = RemoteTransferDiagnostics(.download)
            trace.stage(.destination); trace.stage(.receive, count: 0); trace.stage(.receive, count: 34)
            trace.stage(.prepareHistory); trace.stage(.verify); trace.stage(.publish)
            let binding = ApplicationDiagnostics.shared.operationBinding(trace: trace.trace)
            let result = await engine.perform(.copy(sources: [source], destinationDirectory: destination), progress: { binding.receive($0.jobID) })
            try require(result.result.disposition == .succeeded && result.recordID != nil)
            trace.publication(result.result, stagingRemoved: true)
            trace.finish(.completed); trace.stage(.receive, count: 1_000)
            if let id = result.recordID { try require(await engine.undo(recordID: id).result.disposition == .succeeded) }
            let failing = RemoteTransferDiagnostics(.download)
            failing.stage(.destination)
            let secret = "generated-secret-must-not-be-recorded"
            failing.fail(NSError(domain: NSPOSIXErrorDomain, code: 13,
                userInfo: [NSLocalizedDescriptionKey: secret, NSFilePathErrorKey: source.path,
                    NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue,
                        userInfo: [NSLocalizedDescriptionKey: secret])]), stopped: false)
            let capacity = RemoteTransferDiagnostics(.download); capacity.fail(SFTPDownloadStorageIssue.full, stopped: false)
            let stop = RemoteTransferDiagnostics(.upload); stop.fail(SFTPSessionFailure.stopped, stopped: false)
            let publicationFailure = RemoteTransferDiagnostics(.download)
            let refused = FileOperationResult(items: [
                .init(source: source, destination: nil, status: .failed(.copyMetadataMismatch), recoveryURLs: []),
                .init(source: source, destination: nil, status: .failed(.copyMetadataMismatch), recoveryURLs: []),
                .init(source: source, destination: nil, status: .notStarted, recoveryURLs: [])
            ], cancellationRequested: false)
            publicationFailure.publication(refused, stagingRemoved: false)
            publicationFailure.finish(.completed)
            let partialPublication = RemoteTransferDiagnostics(.download)
            let partial = FileOperationResult(items: [.init(source: source, destination: nil, status: .succeeded, recoveryURLs: [])]
                + [FileOperationFailure.accessDenied, .conflict, .unavailable, .outOfSpace, .ioFailure].map {
                    .init(source: source, destination: nil, status: .failed($0), recoveryURLs: [])
                }, cancellationRequested: false)
            partialPublication.publication(partial, stagingRemoved: false)
            partialPublication.fail(SFTPDownloadStorageIssue.unavailable, stopped: false)
            let adoptionBoundaries: [(OperationDiagnosticCheckpoint, Int64)] = [
                (.downloadAdoptionPathBinding, 510), (.downloadAdoptionRawQuarantine, 511),
                (.downloadAdoptionProvenance, 512), (.downloadAdoptionPublicProperties, 513),
                (.downloadAdoptionAdmission, 520), (.downloadAdoptionArea, 521), (.downloadAdoptionIntent, 522),
                (.downloadAdoptionMove, 523), (.downloadAdoptionStage, 524), (.downloadAdoptionPublication, 525),
                (.downloadAdoptionCommit, 526)
            ]
            for (checkpoint, code) in adoptionBoundaries {
                let projected = DiagnosticErrors.operationBoundary(checkpoint)
                try require(projected?.code == code && projected?.symbol?.hasPrefix("download.adoption.") == true)
            }
            let copyBoundaries: [(OperationDiagnosticCheckpoint, Int64, String)] = [
                (.copyMetadataComparison, 601, "copy.metadataComparison"),
                (.copyReceiptCardinality, 602, "copy.receiptCoverage"),
                (.copyReceiptValidation, 603, "copy.nativeReceipt")
            ]
            for (checkpoint, code, symbol) in copyBoundaries {
                let projected = DiagnosticErrors.operationBoundary(checkpoint)
                try require(projected?.domain == .operation && projected?.code == code && projected?.symbol == symbol)
            }
            await logger.flush()
            let events = try await recordedEvents(logger)
            let own = events.filter { $0.trace == trace.trace && $0.action == .remoteDownload }
            try require(own.filter { $0.phase == .completed }.count == 1
                && own.contains { $0.phase == .verifying } && own.contains { $0.phase == .committing }
                && own.contains { $0.phase == .cleaning }
                && events.contains { $0.trace == trace.trace && $0.relatedTrace != nil }
                && events.contains { $0.action == .fileOperation && $0.ordinal != nil && $0.phase == .verifying })
            try require(events.contains { $0.error?.symbol == "sftp.staging.full" }
                && events.contains { $0.phase == .cancelled && $0.error?.symbol == "sftp.worker.stopped" }
                && events.contains { $0.error?.symbol == "EACCES" && $0.causes?.first?.symbol == "fileReadNoPermission" })
            let refusedTerminal = events.filter { $0.trace == publicationFailure.trace && $0.action == .remoteDownload && $0.phase == .failed }
            try require(refusedTerminal.count == 1 && refusedTerminal[0].error?.symbol == "copyMetadataMismatch"
                && events.contains { $0.trace == publicationFailure.trace && $0.action == .fileOperation
                    && $0.context?.checkpoint == .queueTerminal && $0.error?.symbol == "copyMetadataMismatch" }
                && events.contains { $0.trace == publicationFailure.trace && $0.action == .fileOperation
                    && $0.context == nil && $0.error?.symbol == "copyMetadataMismatch" && $0.count == 2 })
            let partialTerminal = events.filter { $0.trace == partialPublication.trace && $0.action == .remoteDownload && $0.phase == .partial }
            try require(partialTerminal.count == 1 && partialTerminal[0].error?.symbol == "accessDenied"
                && partialTerminal[0].causes?.map(\.symbol) == ["conflict", "unavailable", "outOfSpace"]
                && !events.contains { $0.trace == partialPublication.trace && $0.action == .remoteDownload && $0.phase == .failed })
            let encoded = try JSONEncoder().encode(events), text = String(decoding: encoded, as: UTF8.self)
            try require(!text.contains(secret) && !text.contains(source.path) && !text.contains("Generated-private-file")
                && !text.contains("Generated private diagnostic body"))
            try encoded.write(to: admitted.appendingPathComponent("evidence/transfer-events.json"), options: .withoutOverwriting)
            logger.setRecording(false)
            let paused = RemoteTransferDiagnostics(.upload); paused.finish(.completed)
            await logger.flush(); try require(try await recordedEvents(logger) == events)
            logger.setRecording(true)
            let markerURL = admitted.appendingPathComponent("state/diagnostics/owner.json")
            let originalMarker = try Data(contentsOf: markerURL)
            try FileManager().moveItem(at: markerURL, to: admitted.appendingPathComponent("evidence/original-log-owner.json"))
            try originalMarker.write(to: markerURL, options: .withoutOverwriting)
            try FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
            let bad = RemoteTransferDiagnostics(.download); bad.stage(.receive, count: 1); bad.finish(.completed)
            await logger.flush(); try require(logger.status.failure == .changed)
            // A failed optional writer must not control the real operation engine.
            let continued = await engine.perform(.copy(sources: [source], destinationDirectory: destination))
            try require(continued.result.disposition == .succeeded)
            if let id = continued.recordID { try require(await engine.undo(recordID: id).result.disposition == .succeeded) }
            await ApplicationDiagnostics.shared.closeAndDrain(); recorder = nil
            try write(["passed": true, "typedErrorMappings": workers.count + staging.count + uploads.count,
                "archiveErrorFamilies": archiveErrors.count,
                "oneTerminal": true, "actualEngineCorrelation": true, "privacyCanariesExcluded": true,
                "publicationFailureAtTerminal": true, "partialCausesBounded": true,
                "adoptionBoundaryMappings": adoptionBoundaries.count,
                "copyMetadataBoundaryMappings": copyBoundaries.count,
                "pauseIsInert": true, "failedWriterDoesNotControlCopyUndo": true, "networkRequests": 0, "keychainCalls": 0], root: admitted)
        } catch {
            var line: UInt = 0; if case let Failure.check(value) = error { line = value }
            if let root { try? write(["passed": false, "line": line, "errorType": String(reflecting: type(of: error))], root: root) }
        }
        await recorder?.closeAndDrain(); ApplicationDiagnostics.shared.configureForVerification(nil)
        NSApplication.shared.terminate(nil)
    }
    private static func write(_ value: [String: Any], root: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("evidence/native-transfer-diagnostics.json"), options: .withoutOverwriting)
    }
    private static func recordedEvents(_ logger: DiagnosticRecorder) async throws -> [DiagnosticEvent] {
        var events: [DiagnosticEvent] = [], cursor: DiagnosticHistoryCursor?
        // The real reader limits each request to two segments. More diagnostic
        // cases rotate a third segment; one page is not the complete history.
        for _ in 0..<8 {
            let page = try await logger.page(before: cursor, limit: 256)
            try require(!page.incomplete && events.count + page.events.count <= 256)
            events += page.events; cursor = page.next
            if cursor == nil { return events }
        }
        throw Failure.scope
    }
}
#endif
