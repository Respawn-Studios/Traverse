import CryptoKit
import Darwin
import Foundation

/// Selection binds the exact v3 owner and pending v4 record. It grants no
/// directory cleanup or automatic retry after an interrupted publication.
@_spi(Qualification) public final class ConnectionWorkspaceSMBUpgradeChoice: Sendable, CustomDebugStringConvertible {
    public enum Action: Sendable { case commitPrepared, resumePending }
    public let action: Action
    let paths: ConnectionWorkspacePaths
    let location: RemoteSettingsReadIdentity
    let current: Data, proposed: Data
    init(action: Action, paths: ConnectionWorkspacePaths, location: RemoteSettingsReadIdentity,
         current: Data, proposed: Data) {
        self.action = action; self.paths = paths; self.location = location
        self.current = current; self.proposed = proposed
    }
    public var debugDescription: String { "<explicit SMB Edit workspace upgrade choice>" }
}

enum ConnectionWorkspaceSMBUpgradeDisk {
    typealias File = ConnectionWorkspaceDisk.File
    static func successor(_ old: ConnectionWorkspaceRecord, _ next: ConnectionWorkspaceRecord) throws -> Bool {
        guard old.format == 3, old.isActive, old.repair == nil, old.smbUpgradeSourceDigest == nil,
              next.format == 4, next.protocolIdentity == "traverse-persistent-connections-v4",
              next.revision == old.revision + 1, next.phase == .active, next.repair == nil,
              next.activationID == old.activationID, next.budgetID == old.budgetID,
              next.locationDigest == old.locationDigest,
              next.earlier == old.earlier, next.earlierLock == old.earlierLock,
              next.legacySourceDigest == old.legacySourceDigest,
              next.smbUpgradeSourceDigest == Data(SHA256.hash(data: try old.encoded())),
              Set(old.graph.keys) == ConnectionWorkspaceDisk.graphKeys,
              Set(next.graph.keys) == ConnectionWorkspaceDisk.smbGraphKeys,
              old.graph.allSatisfy({ next.graph[$0.key] == $0.value }) else { return false }
        return true
    }
    static func validatePreparedRoot(_ paths: ConnectionWorkspacePaths, old: ConnectionWorkspaceRecord,
                                     next: ConnectionWorkspaceRecord) throws {
        guard try successor(old, next) else { throw ConnectionWorkspaceFailure.changed }
        try ConnectionWorkspaceDisk.validateGraph(paths, record: old)
        try ConnectionWorkspaceDisk.validateLegacyFence(paths, record: old)
        let graph = try ConnectionWorkspaceDisk.graphIdentity(paths, stable: true, includingSMB: true)
        guard graph.count == next.graph.count,
              next.graph.allSatisfy({ entry in
                  graph[entry.key].map { entry.value.matchesPersisted($0) } == true
              }) else {
            throw ConnectionWorkspaceFailure.changed
        }
        let bodies = try ConnectionWorkspaceDisk.openDirectory(paths.smbInPlaceBodies)
        defer { Darwin.close(bodies) }
        guard Set(try DownloadDisk.names(bodies, maximum: 1)) == ["pool.lock"] else {
            throw ConnectionWorkspaceFailure.reviewRequired
        }
        guard let journal = try RemoteSettingsFile<SMBInPlaceJournalDocument>.open(paths.smbInPlaceJournal, writing: false) else {
            throw ConnectionWorkspaceFailure.changed
        }
        defer { journal.close() }
        try journal.validateCurrent()
        let journalDirectory = try ConnectionWorkspaceDisk.openDirectory(paths.smbInPlaceJournal)
        defer { Darwin.close(journalDirectory) }
        _ = try ConnectionWorkspaceDisk.namedIdentity(journalDirectory, "servers.json", stable: true)
        guard journal.snapshot.revision == 0, journal.snapshot.records.isEmpty else {
            throw ConnectionWorkspaceFailure.reviewRequired
        }
    }
    static func projectPreparedRoot(_ paths: ConnectionWorkspacePaths,
                                    old: ConnectionWorkspaceRecord) throws -> ConnectionWorkspaceRecord {
        guard old.format == 3, old.isActive, old.repair == nil else {
            throw ConnectionWorkspaceFailure.reviewRequired
        }
        var next = old
        next.format = 4; next.protocolIdentity = "traverse-persistent-connections-v4"
        next.revision += 1
        next.smbUpgradeSourceDigest = Data(SHA256.hash(data: try old.encoded()))
        next.graph = try ConnectionWorkspaceDisk.graphIdentity(paths, stable: true, includingSMB: true)
        try validatePreparedRoot(paths, old: old, next: next)
        return next
    }
    static func prepare(_ paths: ConnectionWorkspacePaths, file: File) throws -> ConnectionWorkspaceRecord {
        try ConnectionWorkspaceDisk.checkThread(); try file.validateCurrent()
        let old = file.snapshot
        guard old.format == 3, old.isActive, old.repair == nil else { throw ConnectionWorkspaceFailure.reviewRequired }
        try ConnectionWorkspaceDisk.validateGraph(paths, record: old)
        try ConnectionWorkspaceDisk.validateLegacyFence(paths, record: old)
        try ConnectionWorkspaceDisk.requireAbsent([paths.smbInPlaceRoot])
        guard let root = try SMBCatalogFiles.openPool(paths.smbInPlaceRoot, create: true) else {
            throw ConnectionWorkspaceFailure.unsafe
        }
        defer { Darwin.close(root) }
        guard try DownloadDisk.names(root, maximum: 0).isEmpty else { throw ConnectionWorkspaceFailure.changed }
        guard let bodies = try SMBCatalogFiles.openPool(paths.smbInPlaceBodies, create: true) else {
            throw ConnectionWorkspaceFailure.unsafe
        }
        defer { Darwin.close(bodies) }
        let bodyLock = try SMBCatalogFiles.lockPool(bodies, create: true)
        defer { Darwin.close(bodyLock) }
        guard Set(try DownloadDisk.names(bodies, maximum: 1)) == ["pool.lock"] else {
            throw ConnectionWorkspaceFailure.changed
        }
        do {
            guard let journal = try RemoteSettingsFile<SMBInPlaceJournalDocument>.open(paths.smbInPlaceJournal,
                                                                                         writing: true) else {
                throw ConnectionWorkspaceFailure.unsafe
            }
            defer { journal.close() }
            guard journal.snapshot.revision == 0 else { throw ConnectionWorkspaceFailure.changed }
            try journal.commit(SMBInPlaceJournalDocument())
        }
        try ConnectionWorkspaceDisk.sync(bodies)
        try ConnectionWorkspaceDisk.sync(root)
        let parent = Darwin.open(paths.smbInPlaceRoot.deletingLastPathComponent().path,
                                 O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard parent >= 0 else { throw ConnectionWorkspaceFailure.unsafe }
        defer { Darwin.close(parent) }
        try ConnectionWorkspaceDisk.sync(parent)
        let next = try projectPreparedRoot(paths, old: old)
        try file.commit(next)
        try ConnectionWorkspaceDisk.validateGraph(paths, record: next)
        return next
    }
}
