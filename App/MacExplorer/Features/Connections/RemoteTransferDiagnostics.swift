import FileOperations
import Foundation
@_spi(Qualification) import LocalStorage

/// Native observation adapter. It retains no request, URL, name or password and
/// can neither cancel work nor authorize a mutation. The real owner drains work.
@MainActor final class RemoteTransferDiagnostics {
    enum Direction { case download, upload }
    let trace: UUID
    private let logger: ApplicationDiagnostics
    private let action: DiagnosticAction
    private var timeline: RemoteTransferDiagnosticTimeline
    private var recordedDrain = false
    init(_ direction: Direction, logger: ApplicationDiagnostics = .shared) {
        self.logger = logger; action = direction == .download ? .remoteDownload : .remoteUpload
        timeline = .init(uptimeNanoseconds: Self.now)
        if let existing = logger.currentTrace {
            trace = existing; logger.event(action, .requested, trace: existing)
        } else { trace = logger.begin(action) }
    }
    func stage(_ value: RemoteTransferDiagnosticTimeline.Stage, count: UInt64? = nil) {
        if let value = timeline.advance(value, count: count, uptimeNanoseconds: Self.now) { record(value) }
    }
    func finish(_ outcome: RemoteTransferDiagnosticTimeline.Outcome, count: UInt64? = nil) {
        if let value = timeline.finish(outcome, count: count, uptimeNanoseconds: Self.now) { record(value) }
    }
    func fail(_ error: Error, stopped: Bool) {
        if let batch = error as? SFTPDownloadBatchInterruption {
            logger.event(action, .retaining, trace: trace, count: UInt64(batch.completedFiles), context: .init(.queueMutation))
            logger.event(action, .retaining, trace: trace, count: UInt64(batch.retainedFileIDs.count), context: .init(.queueTerminal))
        }
        if let batch = error as? SFTPUploadBatchInterruption {
            logger.event(action, .retaining, trace: trace, count: UInt64(batch.completed.count), context: .init(.queueMutation))
            logger.event(action, .retaining, trace: trace, count: UInt64(batch.notSubmitted), context: .init(.queueTerminal))
            let outcome: RemoteTransferDiagnosticTimeline.Outcome = !batch.completed.isEmpty || batch.currentMayHaveStarted ? .partial : stopped ? .cancelled : .failed
            if let value = timeline.finish(outcome, count: batch.completed.reduce(0) { $0 + $1.logicalBytes }, uptimeNanoseconds: Self.now) {
                record(value, error: DiagnosticErrors.project(error), causes: DiagnosticErrors.causes(error))
            }
            return
        }
        if let group = error as? SMBUploadGroupInterruption {
            logger.event(action, .retaining, trace: trace, count: UInt64(group.completed.count), context: .init(.queueMutation))
            logger.event(action, .retaining, trace: trace, count: UInt64(group.notSubmitted), context: .init(.queueTerminal))
            let outcome: RemoteTransferDiagnosticTimeline.Outcome = !group.completed.isEmpty || group.currentMayHaveStarted
                ? .partial : stopped || group.cause is CancellationError ? .cancelled : .failed
            if let value = timeline.finish(outcome, count: group.completed.reduce(0) { $0 + $1.logicalBytes }, uptimeNanoseconds: Self.now) {
                record(value, error: DiagnosticErrors.project(error), causes: DiagnosticErrors.causes(error))
            }
            return
        }
        let outcome: RemoteTransferDiagnosticTimeline.Outcome
        if let value = error as? SFTPUploadInterruption, value.publicationMayHaveHappened { outcome = .partial }
        else if let value = error as? SFTPFolderUploadInterruption, value.rootMayExist { outcome = .partial }
        else if stopped || error is CancellationError || error as? SFTPBrowserFailure == .stopped
            || error as? SFTPSessionFailure == .stopped || error as? SMBBrowserFailure == .stopped || error as? SFTPUploadLocalIssue == .stopped
            || (error as? SFTPUploadInterruption)?.cause == .stopped
            || (error as? SFTPFolderUploadInterruption)?.cause == .stopped { outcome = .cancelled }
        else { outcome = .failed }
        let folder = error as? SFTPFolderUploadInterruption
        if let folder {
            // Fixed numerical observations only: member index and verified-file
            // lower bound. No relative path, name, server text or source hash.
            logger.event(action, .retaining, trace: trace, count: UInt64(folder.node), context: .init(.queueMutation))
            logger.event(action, .retaining, trace: trace, count: UInt64(folder.verifiedFiles), context: .init(.queueTerminal))
        }
        if let value = timeline.finish(outcome, count: folder?.verifiedBytes, uptimeNanoseconds: Self.now) {
            record(value, error: DiagnosticErrors.project(error), causes: DiagnosticErrors.causes(error))
        }
    }
    func publication(_ result: FileOperationResult, stagingRemoved: Bool) {
        guard !timeline.finished else { return }
        logger.recordOperationResult(result, trace: trace)
        stage(stagingRemoved ? .clean : .retain, count: 1)
        let outcome: RemoteTransferDiagnosticTimeline.Outcome
        switch result.disposition {
        case .succeeded: outcome = .completed; case .partial: outcome = .partial
        case .cancelled: outcome = .cancelled; case .failed: outcome = .failed
        }
        if let value = timeline.finish(outcome, count: UInt64(result.items.count), uptimeNanoseconds: Self.now) {
            let failures = DiagnosticErrors.operationFailures(result)
            record(value, error: failures.first.map { DiagnosticErrors.operation($0.failure) },
                   causes: failures.isEmpty ? nil : failures.dropFirst().prefix(3).map { DiagnosticErrors.operation($0.failure) })
        }
    }
    func cleanupFailure(_ error: Error) {
        logger.event(action, .retaining, trace: trace, level: .warning, error: DiagnosticErrors.project(error),
                     context: .init(.queueTerminal), causes: DiagnosticErrors.causes(error))
    }
    /// Fixed bits: exit=1, EOF=2, contained=4, valid protocol=8, catalog removed=16.
    /// Local lifetime ending does not imply trusted protocol or removed storage.
    func drained(_ value: SFTPWorkerClose) {
        guard !recordedDrain else { return }; recordedDrain = true
        let bits: UInt64 = (value.actualExit ? 1 : 0) | (value.ipcEOF ? 2 : 0) | (value.contained ? 4 : 0)
            | (value.protocolValid ? 8 : 0) | (value.temporaryStoreRemoved == true ? 16 : 0)
        logger.event(action, value.localResourcesEnded ? .finished : .retaining, trace: trace,
                     level: value.localResourcesEnded ? .information : .warning, count: bits,
                     duration: DiagnosticErrors.milliseconds(value.drainElapsedSeconds), context: .init(.queueTerminal))
    }
    func drained(_ value: SMBBrowserDrainResult, commandCounts: [UInt64]? = nil) {
        guard !recordedDrain else { return }; recordedDrain = true
        let bits: UInt64 = (value.actualExit ? 1 : 0) | (value.pipeDrained ? 2 : 0) | (value.forcedContainment ? 4 : 0)
            | (value.socketAndCatalogDrained ? 8 : 0) | (value.temporaryCatalogRemoved == true ? 16 : 0)
        let ended = value.actualExit && value.pipeDrained && value.ownerReleased
        logger.event(action, ended ? .finished : .retaining, trace: trace, level: ended ? .information : .warning,
                     count: bits, context: .init(.queueTerminal,
                        smbCommandCounts: commandCounts?.count == 19 ? commandCounts : nil))
    }
    static func folderFailure(_ value: SMBFolderUploadDiagnostic, trace: UUID) {
        let coordinates = DiagnosticSMBFailure(boundary: value.boundary, cause: value.cause,
            command: value.command, status: value.status)
        ApplicationDiagnostics.shared.event(.remoteUpload, .failed, trace: trace,
            error: .init(domain: .network, code: 1500 + Int64(value.cause)),
            context: .init(.nativeStatus, smbFailure: coordinates))
    }
    private func record(_ value: RemoteTransferDiagnosticTimeline.Observation, error: DiagnosticErrorCode? = nil,
                        causes: [DiagnosticErrorCode]? = nil) {
        logger.event(action, value.phase, trace: trace, count: value.count, duration: value.durationMilliseconds,
                     error: error, context: value.context, causes: causes)
    }
    private static var now: UInt64 {
        let value = ProcessInfo.processInfo.systemUptime
        return value.isFinite && value >= 0 && value < 1_000_000_000 ? UInt64(value * 1_000_000_000) : 0
    }
}
