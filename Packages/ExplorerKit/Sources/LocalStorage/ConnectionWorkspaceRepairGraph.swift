import Darwin
import Foundation

/// All ownership is real filesystem ownership; the outer location EX is held
/// by the caller. No body open, SQLite open, document commit or graph repair.
final class ConnectionWorkspaceRepairGraph {
    let observation: ConnectionWorkspaceRepairObservation
    private var descriptors: [Int32] = []
    private var validators: [() throws -> Void] = []
    private var budget: SFTPSharedBudgetTransaction?
    private var editors: RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>?
    private var journal: RemoteSettingsFile<SFTPInPlaceJournalDocument>?
    private init(paths: ConnectionWorkspacePaths, record: ConnectionWorkspaceRecord,
                 legacyRebind: Bool) throws {
        var held: [Int32] = [], transaction: SFTPSharedBudgetTransaction?
        var editorFile: RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>?
        var journalFile: RemoteSettingsFile<SFTPInPlaceJournalDocument>?
        var checks: [() throws -> Void] = []
        var keep = false
        defer { if !keep { journalFile?.close(); editorFile?.close(); transaction?.close(); held.reversed().forEach { Darwin.close($0) } } }
        if legacyRebind { _ = try ConnectionWorkspaceRebindDisk.project(paths, record: record) }
        else { try ConnectionWorkspaceDisk.validateGraphIdentity(paths, record: record) }
        let pool = try ConnectionWorkspaceDisk.openDirectory(paths.metadata); held.append(pool)
        let lock = try SMBCatalogFiles.lockPool(pool, create: false); held.append(lock)
        let layout = SFTPSharedBudgetLayout(storage: try SMBTemporaryStorage(unadmittedWorkspaceDirectory: paths.metadata))
        transaction = try SFTPSharedBudgetTransaction.existing(layout: layout, pool: pool, guardFD: lock, writing: false)
        // Repair is available only after every retained-body retirement has
        // completed. Only explicit legacy rebind may retain an independently
        // recognized, cold, unconfirmed receive. The ledger and body owners
        // stay held; ordinary graph repair still requires settled bodies.
        guard let transaction, transaction.document.budgetID == record.budgetID,
              transaction.document.retirements?.isEmpty != false,
              !transaction.document.metadata.contains(where: { [.allocating, .removalPending].contains($0.phase) }),
              !transaction.document.bodies.contains(where: { $0.phase == .removalPending }),
              (legacyRebind || !transaction.document.bodies.contains(where: { $0.phase == .allocating }))
        else { throw ConnectionWorkspaceFailure.reviewRequired }
        editorFile = try RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>.open(layout.editors, writing: false)
        journalFile = try RemoteSettingsFile<SFTPInPlaceJournalDocument>.open(layout.journal, writing: false)
        guard let editorFile, let journalFile else { throw ConnectionWorkspaceFailure.reviewRequired }
        _ = try editorFile.snapshot.encoded(); _ = try journalFile.snapshot.encoded()
        let pendingBodyCount = transaction.document.bodies.filter { $0.phase == .allocating }.count
        let incomplete: SFTPIncompleteReceiveDiscovery
        if legacyRebind && pendingBodyCount > 0 {
            // This opens its own body pool EX only before this graph takes the
            // long-held body EX. No body bytes are read or phase rewritten.
            incomplete = try SFTPIncompleteReceiveDiscovery.inspect(transaction: transaction,
                editors: editorFile.snapshot, journal: journalFile.snapshot)
            guard incomplete.editorIDs.count == pendingBodyCount else { throw ConnectionWorkspaceFailure.reviewRequired }
        } else { incomplete = .init(editorIDs: []) }
        // Reserve bounded location-record work inside the EXISTING global2MiB
        // metadata allowance; never allocate another body/metadata budget.
        guard try ConnectionWorkspaceDisk.recordFootprint(paths) <= 64 << 10 else { throw ConnectionWorkspaceFailure.capacity }
        try SFTPSharedBudgetTransaction.validateMetadataFootprint(layout, workspaceRecordBytes: 64 << 10)
        var stamps: [String: ConnectionWorkspaceStamp] = [:]
        func observe(_ fd: Int32, prefix: String, names: [String]) throws {
            var facts = stat(); guard fstat(fd, &facts) == 0 else { throw ConnectionWorkspaceFailure.changed }
            stamps[prefix] = .init(facts)
            for name in names {
                guard fstatat(fd, name, &facts, AT_SYMLINK_NOFOLLOW) == 0 else { throw ConnectionWorkspaceFailure.changed }
                stamps[prefix + "/" + name] = .init(facts)
                let expected = ConnectionWorkspaceStamp(facts)
                checks.append {
                    var current = stat()
                    guard fstatat(fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0, ConnectionWorkspaceStamp(current) == expected else { throw ConnectionWorkspaceFailure.changed }
                }
            }
        }
        let records = try SFTPSharedBudgetTransaction.records(pool)
        for before in records.sorted(by: { $0.name < $1.name }) {
            try Task.checkCancellation()
            guard !before.summary.active, before.files["catalog.sqlite-journal"] == nil else { throw ConnectionWorkspaceFailure.busy }
            let fd = openat(pool, before.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { throw ConnectionWorkspaceFailure.changed }; held.append(fd)
            let lease = try Self.holdLease(fd); held.append(lease)
            let actual = try SMBCatalogFiles.record(pool, name: before.name, heldLease: lease)
            guard actual.directory == before.directory, actual.files == before.files, actual.marker == before.marker else { throw ConnectionWorkspaceFailure.changed }
            try observe(fd, prefix: "metadata/" + actual.name, names: actual.files.keys.sorted())
            checks.append {
                let fresh = try SMBCatalogFiles.record(pool, name: actual.name, heldLease: lease)
                guard fresh.directory == actual.directory, fresh.files == actual.files, fresh.marker == actual.marker else { throw ConnectionWorkspaceFailure.changed }
            }
        }
        let bodies = try ConnectionWorkspaceDisk.openDirectory(layout.bodies); held.append(bodies)
        let bodyLock = try SMBCatalogFiles.lockPool(bodies, create: false); held.append(bodyLock)
        guard let budgetID = record.budgetID, try SFTPSharedBudgetTransaction.readFence(bodies, name: SFTPSharedBudgetTransaction.bodyFence, prefix: "MEXSHAREDBODY1") == budgetID else { throw ConnectionWorkspaceFailure.changed }
        for before in try DownloadDisk.inventory(bodies, originalBudgetID: budgetID).sorted(by: { $0.name < $1.name }) {
            try Task.checkCancellation()
            guard !before.summary.active, !before.summary.isFolder else { throw ConnectionWorkspaceFailure.busy }
            let fd = openat(bodies, before.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { throw ConnectionWorkspaceFailure.changed }; held.append(fd)
            let lease = try Self.holdLease(fd); held.append(lease)
            let actual = try DownloadDisk.record(bodies, name: before.name, heldLease: lease)
            guard actual.folder == before.folder, actual.files == before.files, actual.marker == before.marker else { throw ConnectionWorkspaceFailure.changed }
            try observe(fd, prefix: "bodies/" + actual.name, names: actual.files.keys.sorted())
            checks.append {
                let fresh = try DownloadDisk.record(bodies, name: actual.name, heldLease: lease)
                guard fresh.folder == actual.folder, fresh.files == actual.files, fresh.marker == actual.marker else { throw ConnectionWorkspaceFailure.changed }
            }
        }
        for save in journalFile.snapshot.records {
            let matches = editorFile.snapshot.records.filter { $0.journals.contains(save.id) }
            guard matches.count == 1, let editor = matches.first, editor.session == save.session,
                  editor.context == save.context, editor.path == save.path,
                  editor.recovery.contains(save.baseline), editor.recovery.contains(save.edited) else { throw ConnectionWorkspaceFailure.changed }
        }
        for editor in editorFile.snapshot.records where editor.phase != .closedUnused {
            guard Set(editor.journals) == Set(journalFile.snapshot.records.filter { $0.session == editor.session && editor.journals.contains($0.id) }.map(\.id)) else { throw ConnectionWorkspaceFailure.changed }
            if incomplete.editorIDs.contains(editor.id) { continue }
            let context = try SFTPSharedBudgetTransaction.contextDigest(editor.context)
            let owners = transaction.document.metadata.filter { $0.kind == .original && $0.session == editor.session && $0.context == context }
            guard owners.count == 1, let owner = owners.first, let initial = editor.body else { throw ConnectionWorkspaceFailure.changed }
            for reference in [initial] + editor.recovery {
                guard transaction.document.bodies.contains(where: { $0.id == reference.id && $0.owner == owner.id && $0.phase == .allocated && $0.expectedBytes == reference.logicalBytes }) else { throw ConnectionWorkspaceFailure.changed }
            }
        }
        try transaction.file.validateCurrent(); try editorFile.validateCurrent(); try journalFile.validateCurrent()
        if legacyRebind { _ = try ConnectionWorkspaceRebindDisk.project(paths, record: record) }
        else { try ConnectionWorkspaceDisk.validateGraphIdentity(paths, record: record) }
        observation = .init(ledger: try transaction.file.recoveryReadIdentity(), editors: try editorFile.recoveryReadIdentity(), journal: try journalFile.recoveryReadIdentity(), stamps: stamps)
        let metadataNames = Set(try DownloadDisk.names(pool, maximum: 66))
        let bodyNames = Set(try DownloadDisk.names(bodies, maximum: 66))
        checks.append {
            guard Set(try DownloadDisk.names(pool, maximum: 66)) == metadataNames,
                  Set(try DownloadDisk.names(bodies, maximum: 66)) == bodyNames else { throw ConnectionWorkspaceFailure.changed }
            guard transaction.document.retirements?.isEmpty != false,
                  !transaction.document.metadata.contains(where: { [.allocating, .removalPending].contains($0.phase) }),
                  !transaction.document.bodies.contains(where: { $0.phase == .removalPending }),
                  (legacyRebind || !transaction.document.bodies.contains(where: { $0.phase == .allocating }))
            else { throw ConnectionWorkspaceFailure.reviewRequired }
            guard try ConnectionWorkspaceDisk.recordFootprint(paths) <= 64 << 10 else { throw ConnectionWorkspaceFailure.capacity }
            try SFTPSharedBudgetTransaction.validateMetadataFootprint(layout, workspaceRecordBytes: 64 << 10)
            try transaction.file.validateCurrent(); try editorFile.validateCurrent(); try journalFile.validateCurrent()
            if legacyRebind { _ = try ConnectionWorkspaceRebindDisk.project(paths, record: record) }
            else { try ConnectionWorkspaceDisk.validateGraphIdentity(paths, record: record) }
        }
        self.budget = transaction; self.editors = editorFile; self.journal = journalFile; descriptors = held; validators = checks; keep = true
    }
    static func open(paths: ConnectionWorkspacePaths, record: ConnectionWorkspaceRecord,
                     legacyRebind: Bool = false) throws -> ConnectionWorkspaceRepairGraph {
        try ConnectionWorkspaceDisk.checkThread(); return try .init(paths: paths, record: record, legacyRebind: legacyRebind)
    }
    private static func holdLease(_ directory: Int32) throws -> Int32 {
        let fd = openat(directory, "owner.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ConnectionWorkspaceFailure.changed }
        do {
            _ = try ConnectionWorkspaceDisk.identity(fd, directory: false)
            var facts = stat(); guard fstat(fd, &facts) == 0, facts.st_size == 0,
                try ConnectionWorkspaceDisk.identity(fd, directory: false) == ConnectionWorkspaceDisk.namedIdentity(directory, "owner.lock") else { throw ConnectionWorkspaceFailure.changed }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ConnectionWorkspaceFailure.busy }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    func validateCurrent() throws { for validate in validators { try validate() } }
    func close() {
        journal?.close(); journal = nil; editors?.close(); editors = nil; budget?.close(); budget = nil
        validators.removeAll(); descriptors.reversed().forEach { Darwin.close($0) }; descriptors.removeAll()
    }
    deinit { close() }
}
