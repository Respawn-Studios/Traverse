#if DEBUG
import Foundation

/// DEBUG-only current-process observations. These are actual LocalStorage
/// boundary events, not caller-supplied numbers or an all-process assertion.
@_spi(Qualification) public struct SFTPGeneratedBackendSnapshot: Sendable {
    public let bodyReads: Int
    /// Entry into canonical payload digest validation, including failures.
    public let payloadValidationReadEntries: Int
    public let bodyReaderOpens: Int
    public let bodyReaderDrains: Int
    public let bodyPinOpens: Int
    public let bodyPinDrains: Int
    /// All LocalStorage SMB/SFTP worker launch entries, including failures.
    public let workerStarts: Int
    public let workerDrains: Int
    /// Parent-side successful send or positive socket read operations.
    public let workerIPC: Int
    /// Parent-side attempts to submit write-capable commands 9, 23, 42 or 52.
    public let remoteWriteSubmissions: Int
    /// Accepted transfer or Original/InPlace save completion, not a UI flag.
    public let remoteSaveAcknowledgements: Int
    /// Body reader/pin and successfully spawned SFTP child owners not drained.
    /// A non-SFTP worker attempt makes the separate offline check fail.
    public let outstandingOwners: Int
}

/// Must be armed once, from the generated App route, before any connection or
/// LocalStorage owner is constructed. No reset/disarm exists in this process.
@_spi(Qualification) public final class SFTPGeneratedBackendObservation: @unchecked Sendable {
    static let shared = SFTPGeneratedBackendObservation()
    private let lock = NSLock()
    private var preArmEvents = 0
    private var state: State?
    private init() {}

    private struct State {
        let root: URL, bodies: URL
        var invalid = false
        var bodyReads = 0, payloadValidationReadEntries = 0
        var bodyReaderOpens = 0, bodyReaderDrains = 0
        var bodyPinOpens = 0, bodyPinDrains = 0
        var workerStarts = 0, workerDrains = 0, workerIPC = 0
        var remoteWriteSubmissions = 0, remoteSaveAcknowledgements = 0
        var liveReaders = 0, livePins = 0, liveWorkers = 0
    }
    private enum Event {
        case bodyRead, payloadValidationRead, readerOpen, readerDrain, pinOpen, pinDrain
        case workerStart, sftpChildStart, workerDrain, workerIPC, writeSubmission, saveAcknowledgement
    }

    /// The only App-facing constructor. The generated case verifies exact
    /// private portable roots and capacity off the main thread first.
    public static func arm(generatedCase: ConnectionWorkspaceGeneratedCase) async throws -> SFTPGeneratedBackendObservation {
        try await Task.detached { try generatedCase.validate() }.value
        return try shared.lock.withLock {
            guard shared.state == nil, shared.preArmEvents == 0 else { throw ConnectionWorkspaceFailure.reviewRequired }
            let bodies = generatedCase.layout.persistentConnectionWorkspaceDirectory.appendingPathExtension("original-bodies")
            shared.state = State(root: generatedCase.root, bodies: bodies)
            return shared
        }
    }

    /// A missing arm, foreign case/body, counter overflow, or drain without an
    /// actual open throws. No adapter may replace this with a default zero.
    public func snapshot(generatedCase: ConnectionWorkspaceGeneratedCase) async throws -> SFTPGeneratedBackendSnapshot {
        try await Task.detached { try generatedCase.validate() }.value
        return try lock.withLock {
            guard let value = state, !value.invalid,
                  value.root == generatedCase.root,
                  value.bodies == generatedCase.layout.persistentConnectionWorkspaceDirectory.appendingPathExtension("original-bodies")
            else { throw ConnectionWorkspaceFailure.reviewRequired }
            return .init(bodyReads: value.bodyReads,
                payloadValidationReadEntries: value.payloadValidationReadEntries,
                bodyReaderOpens: value.bodyReaderOpens, bodyReaderDrains: value.bodyReaderDrains,
                bodyPinOpens: value.bodyPinOpens, bodyPinDrains: value.bodyPinDrains,
                workerStarts: value.workerStarts, workerDrains: value.workerDrains,
                workerIPC: value.workerIPC,
                remoteWriteSubmissions: value.remoteWriteSubmissions,
                remoteSaveAcknowledgements: value.remoteSaveAcknowledgements,
                outstandingOwners: value.liveReaders + value.livePins + value.liveWorkers)
        }
    }

    private func event(_ kind: Event, bodyDirectory: URL? = nil) {
        lock.withLock {
            guard var value = state else {
                if preArmEvents < 1_000_000 { preArmEvents += 1 }
                return
            }
            if let bodyDirectory, bodyDirectory != value.bodies { value.invalid = true }
            var overflow = false
            func bumped(_ count: Int) -> Int {
                if count >= 1_000_000 { overflow = true; return count }
                return count + 1
            }
            switch kind {
            case .bodyRead: value.bodyReads = bumped(value.bodyReads)
            case .payloadValidationRead: value.payloadValidationReadEntries = bumped(value.payloadValidationReadEntries)
            case .readerOpen:
                value.bodyReaderOpens = bumped(value.bodyReaderOpens)
                value.liveReaders = bumped(value.liveReaders)
            case .readerDrain:
                if value.liveReaders < 1 { overflow = true }
                else { value.liveReaders -= 1; value.bodyReaderDrains = bumped(value.bodyReaderDrains) }
            case .pinOpen:
                value.bodyPinOpens = bumped(value.bodyPinOpens)
                value.livePins = bumped(value.livePins)
            case .pinDrain:
                if value.livePins < 1 { overflow = true }
                else { value.livePins -= 1; value.bodyPinDrains = bumped(value.bodyPinDrains) }
            case .workerStart: value.workerStarts = bumped(value.workerStarts)
            case .sftpChildStart: value.liveWorkers = bumped(value.liveWorkers)
            case .workerDrain:
                if value.liveWorkers < 1 { overflow = true }
                else { value.liveWorkers -= 1; value.workerDrains = bumped(value.workerDrains) }
            case .workerIPC: value.workerIPC = bumped(value.workerIPC)
            case .writeSubmission: value.remoteWriteSubmissions = bumped(value.remoteWriteSubmissions)
            case .saveAcknowledgement: value.remoteSaveAcknowledgements = bumped(value.remoteSaveAcknowledgements)
            }
            if overflow { value.invalid = true }
            state = value
        }
    }

    func bodyReaderOpened(directory: URL) { event(.readerOpen, bodyDirectory: directory) }
    func bodyReaderDrained(directory: URL) { event(.readerDrain, bodyDirectory: directory) }
    func bodyRead(directory: URL) { event(.bodyRead, bodyDirectory: directory) }
    func payloadValidationRead(directory: URL) { event(.payloadValidationRead, bodyDirectory: directory) }
    func bodyPinOpened(directory: URL) { event(.pinOpen, bodyDirectory: directory) }
    func bodyPinDrained(directory: URL) { event(.pinDrain, bodyDirectory: directory) }
    /// Called at the launch entry, before validation or posix_spawn. A failed
    /// attempt still makes GateA's offline boundary fail closed.
    func workerLaunchAttempt() { event(.workerStart) }
    /// Only SFTP's successfully created child owner is tracked for drain;
    /// GateA cannot pass if any worker launch was attempted.
    func sftpWorkerChildStarted() { event(.sftpChildStart) }
    func workerDrained() { event(.workerDrain) }
    func protocolTransferred() { event(.workerIPC) }
    func protocolReceived() { event(.workerIPC) }
    func remoteWriteAttempt(kind: UInt8) {
        if [UInt8(9), 23, 42, 52].contains(kind) { event(.writeSubmission) }
    }
    func remoteSaveAcknowledged() { event(.saveAcknowledgement) }
}
#endif
