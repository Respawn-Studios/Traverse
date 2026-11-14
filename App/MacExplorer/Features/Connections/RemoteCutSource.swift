import Foundation
@_spi(Qualification) import LocalStorage

/// In-memory observations only. They grant no local-file, reconnect or mutation
/// authority, and deliberately retain neither a controller nor a session.
struct SFTPClipboardSource: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let connectionID: UUID
    let directory: SFTPDefaultDirectory
    let row: SFTPStoredRow
    private let owner: ObjectIdentifier
    @MainActor init(owner: SFTPTabController, directory: SFTPDefaultDirectory, row: SFTPStoredRow) {
        connectionID = owner.connectionID; self.owner = ObjectIdentifier(owner)
        self.directory = directory; self.row = row
    }
    @MainActor func belongs(to candidate: SFTPTabController) -> Bool {
        owner == ObjectIdentifier(candidate) && connectionID == candidate.connectionID
    }
    var description: String { "<SFTP clipboard observation>" }
    var debugDescription: String { description }
}

struct SMBClipboardSource: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let connectionID: UUID
    let directory: [SMBRemoteName]
    let row: SMBDirectoryObservation
    private let owner: ObjectIdentifier
    @MainActor init(owner: SMBTabController, directory: [SMBRemoteName], row: SMBDirectoryObservation) {
        connectionID = owner.connectionID; self.owner = ObjectIdentifier(owner)
        self.directory = directory; self.row = row
    }
    @MainActor func belongs(to candidate: SMBTabController) -> Bool {
        owner == ObjectIdentifier(candidate) && connectionID == candidate.connectionID
    }
    func matches(_ candidate: SMBDirectoryObservation) -> Bool {
        // Catalog row IDs change on re-enumeration; native observed facts do not
        // get replaced with whatever object happens to occupy the old name.
        candidate.name == row.name && candidate.attributes == row.attributes
            && candidate.logicalBytes == row.logicalBytes && candidate.modifiedFileTime == row.modifiedFileTime
            && candidate.objectID == row.objectID && candidate.parentID == row.parentID
    }
    var description: String { "<SMB clipboard observation>" }
    var debugDescription: String { description }
}

enum RemoteSourceObservationFailure: Error, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    case stale, unavailable, changed, incomplete, deadline
    var description: String {
        switch self {
        case .stale: "Remote source observation is no longer current."
        case .unavailable: "Remote source observation is unavailable."
        case .changed: "The remote clipboard source changed."
        case .incomplete: "The remote clipboard source could not be checked completely."
        case .deadline: "The remote source observation deadline elapsed."
        }
    }
    var debugDescription: String { description }
    var userMessage: String {
        switch self {
        case .changed: "The item changed or moved. Select it again before copying or moving it."
        case .stale: "The folder changed while preparing the action. Nothing was started."
        case .unavailable: "The source folder could not be checked. Nothing was started."
        case .incomplete, .deadline: "The item could not be checked completely. Open its folder and select it again."
        }
    }
}

/// Clipboard source rechecks do not reduce explicit Copy To/Move To scope.
/// The deadline rejects late observations; it is not proof that an in-flight
/// native read has drained. Its tab keeps the suppression lease until restore.
@MainActor final class RemoteSourceObservationLease {
    static let maximumPages = 64
    let preparation: UUID
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    var started = false
    var stopRequested = false
    private var timer: Task<Void, Never>?
    init(preparation: UUID) { self.preparation = preparation }
    func armDeadline(stop: @escaping @MainActor () -> Void) {
        timer = Task { @MainActor [weak self] in
            guard let deadline = self?.deadline else { return }
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard let self, !Task.isCancelled else { return }
            stopRequested = true; stop()
        }
    }
    func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw RemoteSourceObservationFailure.deadline }
    }
    func finishWaiting() { timer?.cancel(); timer = nil }
    isolated deinit { timer?.cancel() }
}
