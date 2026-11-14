import Darwin
import Foundation

/// Immutable admission proof; no lifetime SH lock. Every disk transaction
/// opens a fresh record SH lease BEFORE its real metadata pool.lock.
final class ConnectionWorkspaceWitness: Sendable {
    enum Access: Sendable, Equatable { case connection, coldRecovery }
    let paths: ConnectionWorkspacePaths, record: ConnectionWorkspaceRecord
    let identity: RemoteSettingsReadIdentity, access: Access
    init(paths: ConnectionWorkspacePaths, record: ConnectionWorkspaceRecord, identity: RemoteSettingsReadIdentity, access: Access) {
        self.paths = paths; self.record = record; self.identity = identity; self.access = access
    }
    func begin() throws -> ConnectionWorkspaceRecordLease {
        try ConnectionWorkspaceDisk.checkThread()
        guard let file = try ConnectionWorkspaceDisk.File.open(paths.record, writing: false) else { throw ConnectionWorkspaceFailure.changed }
        do {
            guard try file.recoveryReadIdentity() == identity,
                  try file.snapshot.encoded() == record.encoded() else { throw ConnectionWorkspaceFailure.changed }
            try ConnectionWorkspaceDisk.validateGraph(paths, record: record, retirementAccess: access == .coldRecovery ? .passive : nil)
            if access == .connection { try ConnectionWorkspaceDisk.validateLegacyFence(paths, record: record) }
            return .init(file, witness: self)
        } catch { file.close(); throw error }
    }
}
final class ConnectionWorkspaceRecordLease {
    private let file: ConnectionWorkspaceDisk.File
    private let witness: ConnectionWorkspaceWitness
    private var closed = false
    init(_ file: ConnectionWorkspaceDisk.File, witness: ConnectionWorkspaceWitness) { self.file = file; self.witness = witness }
    func validateCurrent() throws {
        try file.validateCurrent()
        // Revalidate pinned roots/fences after the real pool lock and before
        // mutation; do not recursively open a ledger writer already held by
        // this transaction. Its actual file owner validates that revision.
        try ConnectionWorkspaceDisk.validateGraphIdentity(witness.paths, record: witness.record)
        if witness.access == .connection { try ConnectionWorkspaceDisk.validateLegacyFence(witness.paths, record: witness.record) }
    }
    func close() { if !closed { closed = true; file.close() } }
    deinit { close() }
}

extension SMBTemporaryStorage {
    func beginWorkspaceTransaction() throws -> ConnectionWorkspaceRecordLease? {
        if let workspaceWitness { return try workspaceWitness.begin() }
        guard directory.lastPathComponent != "connection-workspace" else { throw ConnectionWorkspaceFailure.reviewRequired }
        return nil
    }
    func requireDurableOriginalAdmission() throws {
        if let workspaceWitness {
            guard workspaceWitness.access == .connection else { throw ConnectionWorkspaceFailure.reviewRequired }
            return
        }
        #if DEBUG
        // Exact retained Source7/8/9 generated controls remain independently
        // runnable. This is not a production/portable Original admission path.
        if directory.path.contains("/.build/traverse-development/"), directory.lastPathComponent != "connection-workspace" { return }
        #endif
        throw ConnectionWorkspaceFailure.reviewRequired
    }
}
