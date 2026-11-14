import Darwin
import Foundation
import ExplorerCore

/// Concrete SMB/SFTP location owner. Construction and passive inspection are
/// inert/read-only. Only an explicit Connect prepares roots or activates.
@_spi(Qualification) public final class ConnectionWorkspace: Sendable, CustomDebugStringConvertible {
    private let paths: ConnectionWorkspacePaths
    private let statePreparation: PrivateStateDirectorySequence, earlierPreparation: PrivateStateDirectorySequence
    private let executor = UploadLocalExecutor(label: "Traverse.ConnectionWorkspace")
    private let recoveryReader = SFTPInPlaceRecoveryReadOwner()
    private let smbRecoveryReader = SMBInPlaceRecoveryReadOwner()
    private let retirementOwner = SFTPRetainedRetirementOwner()
    private let repairOwner = ConnectionWorkspaceRepairOwner()
    public var debugDescription: String { "<persistent SMB/SFTP connection workspace owner>" }
    public init(layout: ApplicationStorageLayout) throws {
        paths = .init(layout)
        statePreparation = try .init(directories: layout.stateCreationChain)
        earlierPreparation = try .init(directories: layout.channel == .portable ? layout.cacheCreationChain : layout.stateCreationChain)
    }
    public func inspect() async throws -> ConnectionWorkspaceInspection {
        let (value, late) = try await executor.perform { [paths] in
            try ConnectionWorkspaceDisk.checkThread()
            if let file = try ConnectionWorkspaceDisk.File.open(paths.record, writing: false, repairReview: true) {
                defer { file.close() }
                if file.pending != nil || file.snapshot.phase == .repairing {
                    return ConnectionWorkspaceInspection(state: .interruptedRepairNeedsReview, earlierInactiveMetadataCount: 0)
                }
                if file.snapshot.revision > 0 {
                    guard file.snapshot.isActive else { return ConnectionWorkspaceInspection(state: .interruptedActivationNeedsReview, earlierInactiveMetadataCount: 0) }
                    try ConnectionWorkspaceDisk.validateGraph(paths, record: file.snapshot)
                    do { try ConnectionWorkspaceDisk.validateLegacyFence(paths, record: file.snapshot) }
                    catch { return ConnectionWorkspaceInspection(state: .activeCompatibilityNeedsReview, earlierInactiveMetadataCount: 0) }
                    return ConnectionWorkspaceInspection(state: .active, earlierInactiveMetadataCount: 0)
                }
            }
            try ConnectionWorkspaceDisk.requireAbsent(paths.graph)
            do {
                try ConnectionWorkspaceDisk.requireAbsent(paths.earlierSiblings)
                guard let pool = try SMBCatalogFiles.openPool(paths.earlier, create: false) else {
                    return ConnectionWorkspaceInspection(state: .unprepared, earlierInactiveMetadataCount: 0)
                }
                defer { Darwin.close(pool) }
                let lock = try SMBCatalogFiles.lockPool(pool, create: false); defer { Darwin.close(lock) }
                let records = try SMBCatalogFiles.legacyInventory(pool)
                return ConnectionWorkspaceInspection(state: records.isEmpty ? .unprepared : .earlierMetadataNeedsReview,
                    earlierInactiveMetadataCount: records.filter { !$0.summary.active && $0.files["catalog.sqlite-journal"] == nil }.count)
            } catch { return ConnectionWorkspaceInspection(state: .earlierMetadataNeedsReview, earlierInactiveMetadataCount: 0) }
        }
        guard !late else { throw ConnectionWorkspaceFailure.cancelled }; return value
    }
    public func prepareForConnect() async throws -> ConnectionWorkspaceAdmission {
        // Actual filesystem work remains off-main on the bounded owner lane.
        let (value, late) = try await executor.perform { [self] in
            try ConnectionWorkspaceDisk.checkThread()
            // An established location is admitted under record SH. Do not
            // prepare/recreate cache ancestors, fsync a writer or demand EX
            // merely to connect beside a bounded cold recovery read.
            if let admitted = try existingActiveAdmission() { return admitted }
            try statePreparation.prepareFromBackgroundThread(); try earlierPreparation.prepareFromBackgroundThread()
            guard let file = try ConnectionWorkspaceDisk.File.open(paths.record, writing: true) else { throw ConnectionWorkspaceFailure.unsafe }
            defer { file.close() }
            let record: ConnectionWorkspaceRecord
            if file.snapshot.revision == 0 { record = try ConnectionWorkspaceDisk.activate(paths, file: file) }
            else {
                guard file.snapshot.isActive else { throw ConnectionWorkspaceFailure.reviewRequired }
                record = file.snapshot; try ConnectionWorkspaceDisk.validateGraph(paths, record: record)
                try ConnectionWorkspaceDisk.validateLegacyFence(paths, record: record)
            }
            let witness = ConnectionWorkspaceWitness(paths: paths, record: record, identity: try file.recoveryReadIdentity(), access: .connection)
            return ConnectionWorkspaceAdmission.mint(try SMBTemporaryStorage(connectionWorkspaceDirectory: paths.metadata, witness: witness))
        }
        guard !late else { throw ConnectionWorkspaceFailure.cancelled }; return value
    }
    /// Explicit SMB Edit preparation. Ordinary Connect and v3 browse/View do
    /// not call this, so a held location EX leaves those existing paths usable.
    /// A v3-to-v4 commit is one-way for an older v3-only binary.
    public func prepareSMBInPlaceEdits() async throws -> ConnectionWorkspaceAdmission {
        let (value, _) = try await executor.perform { [self] in
            try ConnectionWorkspaceDisk.checkThread()
            if let existing = try ConnectionWorkspaceDisk.File.open(paths.record, writing: false) {
                defer { existing.close() }
                if existing.snapshot.format == 4 {
                    try ConnectionWorkspaceDisk.validateGraph(paths, record: existing.snapshot)
                    try ConnectionWorkspaceDisk.validateLegacyFence(paths, record: existing.snapshot)
                    let witness = ConnectionWorkspaceWitness(paths: paths, record: existing.snapshot,
                        identity: try existing.recoveryReadIdentity(), access: .connection)
                    return ConnectionWorkspaceAdmission.mint(try SMBTemporaryStorage(connectionWorkspaceDirectory: paths.metadata,
                                                                                      witness: witness))
                }
            }
            guard let file = try ConnectionWorkspaceDisk.File.open(paths.record, writing: true,
                                                                   existingOnly: true) else {
                throw ConnectionWorkspaceFailure.reviewRequired
            }
            defer { file.close() }
            let record = try ConnectionWorkspaceSMBUpgradeDisk.prepare(paths, file: file)
            let witness = ConnectionWorkspaceWitness(paths: paths, record: record,
                identity: try file.recoveryReadIdentity(), access: .connection)
            return ConnectionWorkspaceAdmission.mint(try SMBTemporaryStorage(connectionWorkspaceDirectory: paths.metadata,
                                                                              witness: witness))
        }
        // A late Cancel cannot erase an already committed v4 owner. Return
        // its actual witness so the App can replace its stale v3 storage.
        return value
    }
    /// A pending v4 record is only a review choice. Read-only discovery does
    /// not promote it or discard the already prepared subtree.
    public func smbInPlaceUpgradeChoiceAfterExplicitRequest() async throws -> ConnectionWorkspaceSMBUpgradeChoice {
        let (value, late) = try await executor.perform { [paths] in
            try ConnectionWorkspaceDisk.checkThread()
            guard let file = try ConnectionWorkspaceDisk.File.open(paths.record, writing: false, repairReview: true),
                  file.snapshot.format == 3, file.snapshot.isActive else { throw ConnectionWorkspaceFailure.reviewRequired }
            defer { file.close() }
            let action: ConnectionWorkspaceSMBUpgradeChoice.Action
            let proposed: ConnectionWorkspaceRecord
            if let pending = file.pending {
                try ConnectionWorkspaceSMBUpgradeDisk.validatePreparedRoot(paths, old: file.snapshot, next: pending)
                action = .resumePending; proposed = pending
            } else {
                guard try !ConnectionWorkspaceDisk.missing(paths.smbInPlaceRoot) else {
                    throw ConnectionWorkspaceFailure.reviewRequired
                }
                proposed = try ConnectionWorkspaceSMBUpgradeDisk.projectPreparedRoot(paths, old: file.snapshot)
                action = .commitPrepared
            }
            return ConnectionWorkspaceSMBUpgradeChoice(action: action, paths: paths,
                location: try file.repairReadIdentity(), current: try file.snapshot.encoded(),
                proposed: try proposed.encoded())
        }
        guard !late else { throw ConnectionWorkspaceFailure.cancelled }
        return value
    }
    public func resumeSMBInPlaceUpgrade(_ choice: ConnectionWorkspaceSMBUpgradeChoice) async throws -> ConnectionWorkspaceAdmission {
        let (value, _) = try await executor.perform { [paths] in
            try ConnectionWorkspaceDisk.checkThread()
            guard choice.paths == paths,
                  let file = try ConnectionWorkspaceDisk.File.open(paths.record, writing: true,
                                                                   repairReview: true, existingOnly: true) else {
                throw ConnectionWorkspaceFailure.changed
            }
            defer { file.close() }
            guard try file.repairReadIdentity() == choice.location,
                  try file.snapshot.encoded() == choice.current else { throw ConnectionWorkspaceFailure.changed }
            if let pending = file.pending {
                guard choice.action == .resumePending, try pending.encoded() == choice.proposed else {
                    throw ConnectionWorkspaceFailure.changed
                }
                try ConnectionWorkspaceSMBUpgradeDisk.validatePreparedRoot(paths, old: file.snapshot, next: pending)
                try file.promoteExactRepairPending()
            } else {
                guard choice.action == .commitPrepared else { throw ConnectionWorkspaceFailure.changed }
                let proposed = try ConnectionWorkspaceSMBUpgradeDisk.projectPreparedRoot(paths, old: file.snapshot)
                guard try proposed.encoded() == choice.proposed else { throw ConnectionWorkspaceFailure.changed }
                try file.commit(proposed)
            }
            try ConnectionWorkspaceDisk.validateGraph(paths, record: file.snapshot)
            let witness = ConnectionWorkspaceWitness(paths: paths, record: file.snapshot,
                identity: try file.recoveryReadIdentity(), access: .connection)
            return ConnectionWorkspaceAdmission.mint(try SMBTemporaryStorage(connectionWorkspaceDirectory: paths.metadata,
                                                                              witness: witness))
        }
        // The selected pending record may already be durably promoted.
        return value
    }
    /// Explicit activity review may use only an already active workspace. It
    /// never prepares a missing profile or advances an interrupted activation.
    public func admitExistingForReview() async throws -> ConnectionWorkspaceAdmission {
        let (value, late) = try await executor.perform { [self] in
            try ConnectionWorkspaceDisk.checkThread()
            do {
                guard let admitted = try existingActiveAdmission() else { throw ConnectionWorkspaceFailure.reviewRequired }
                return admitted
            } catch RemoteSettingsFailure.recoveryRequired {
                throw ConnectionWorkspaceFailure.reviewRequired
            }
        }
        guard !late else { throw ConnectionWorkspaceFailure.cancelled }; return value
    }
    private func existingActiveAdmission() throws -> ConnectionWorkspaceAdmission? {
        guard let existing = try ConnectionWorkspaceDisk.File.open(paths.record, writing: false) else { return nil }
        defer { existing.close() }
        guard existing.snapshot.revision > 0 else { return nil }
        guard existing.snapshot.isActive else { throw ConnectionWorkspaceFailure.reviewRequired }
        try ConnectionWorkspaceDisk.validateGraph(paths, record: existing.snapshot)
        try ConnectionWorkspaceDisk.validateLegacyFence(paths, record: existing.snapshot)
        let witness = ConnectionWorkspaceWitness(paths: paths, record: existing.snapshot,
            identity: try existing.recoveryReadIdentity(), access: .connection)
        return ConnectionWorkspaceAdmission.mint(try SMBTemporaryStorage(connectionWorkspaceDirectory: paths.metadata, witness: witness))
    }
    public func earlierMetadataChoicesAfterExplicitRequest() async throws -> [ConnectionWorkspaceEarlierMetadataChoice] {
        let (value, late) = try await executor.perform { [paths] in
            try ConnectionWorkspaceDisk.checkThread()
            let file = try ConnectionWorkspaceDisk.File.open(paths.record, writing: false); defer { file?.close() }
            guard (file?.snapshot.revision ?? 0) == 0 else { throw ConnectionWorkspaceFailure.reviewRequired }
            let location = try file?.recoveryReadIdentity()
            try ConnectionWorkspaceDisk.requireAbsent(paths.earlierSiblings + paths.graph)
            guard let pool = try SMBCatalogFiles.openPool(paths.earlier, create: false) else { return [ConnectionWorkspaceEarlierMetadataChoice]() }
            defer { Darwin.close(pool) }
            let lock = try SMBCatalogFiles.lockPool(pool, create: false); defer { Darwin.close(lock) }
            let root = try ConnectionWorkspaceDisk.identity(pool, directory: true)
            let records = try SMBCatalogFiles.legacyInventory(pool)
            // Unknown inventory throws. Known hot/active entries are retained
            // and never minted as cleanup choices; other exact entries remain.
            return try records.filter { !$0.summary.active && $0.files["catalog.sqlite-journal"] == nil }.map {
                ConnectionWorkspaceEarlierMetadataChoice(paths: paths, root: root, record: $0,
                    stamps: try ConnectionWorkspaceDisk.stamps(pool: pool, record: $0), locationIdentity: location)
            }
        }
        guard !late else { throw ConnectionWorkspaceFailure.cancelled }; return value
    }
    public func discardEarlierMetadata(_ choice: ConnectionWorkspaceEarlierMetadataChoice) async throws {
        let (_, late) = try await executor.perform { [paths] in
            try ConnectionWorkspaceDisk.checkThread(); guard choice.paths == paths else { throw ConnectionWorkspaceFailure.changed }
            // If there was no location owner at selection time, retain that
            // absence; cleanup must not fabricate a record and bless it.
            let file: ConnectionWorkspaceDisk.File?
            if choice.locationIdentity == nil {
                guard try ConnectionWorkspaceDisk.missing(paths.record) else { throw ConnectionWorkspaceFailure.changed }; file = nil
            } else {
                file = try ConnectionWorkspaceDisk.File.open(paths.record, writing: true)
                guard let file, try file.recoveryReadIdentity() == choice.locationIdentity, file.snapshot.revision == 0 else { throw ConnectionWorkspaceFailure.changed }
            }
            defer { file?.close() }
            try ConnectionWorkspaceDisk.requireAbsent(paths.earlierSiblings + paths.graph)
            let pool = try ConnectionWorkspaceDisk.openDirectory(paths.earlier); defer { Darwin.close(pool) }
            let lock = try SMBCatalogFiles.lockPool(pool, create: false); defer { Darwin.close(lock) }
            try SMBCatalogFiles.validatePool(pool, at: paths.earlier)
            guard try ConnectionWorkspaceDisk.identity(pool, directory: true) == choice.root else { throw ConnectionWorkspaceFailure.changed }
            _ = try SMBCatalogFiles.legacyInventory(pool)
            let actual = try SMBCatalogFiles.record(pool, name: choice.record.name)
            guard !actual.summary.active, actual.files["catalog.sqlite-journal"] == nil,
                  actual.directory == choice.record.directory, actual.files == choice.record.files, actual.marker == choice.record.marker,
                  try ConnectionWorkspaceDisk.stamps(pool: pool, record: actual) == choice.stamps else { throw ConnectionWorkspaceFailure.changed }
            try ConnectionWorkspaceDisk.requireAbsent(paths.earlierSiblings + paths.graph)
            try SMBCatalogFiles.remove(pool: pool, record: actual)
        }
        guard !late else { throw ConnectionWorkspaceFailure.cancelled }
    }
    public func recoveryChoicesAfterExplicitRequest() async throws -> [SFTPInPlaceRecoveryChoice] {
        try await recoveryListingAfterExplicitRequest().choices
    }
    public func smbRecoveryChoicesAfterExplicitRequest() async throws -> [SMBInPlaceRecoveryChoice] {
        try await smbRecoveryReader.discoverPrepared { [self] in try retainedSMBStorage() }
    }
    private func retainedSMBStorage() throws -> SMBInPlaceWorkingCopyStorage? {
        try ConnectionWorkspaceDisk.checkThread()
        guard let file = try ConnectionWorkspaceDisk.File.open(paths.record, writing: false,
                                                                repairReview: true) else {
            try ConnectionWorkspaceDisk.requireAbsent([paths.smbInPlaceRoot]); return nil
        }
        defer { file.close() }
        guard file.pending == nil, file.snapshot.isActive else { throw ConnectionWorkspaceFailure.reviewRequired }
        try ConnectionWorkspaceDisk.validateGraph(paths, record: file.snapshot, retirementAccess: .passive)
        if file.snapshot.format == 3 {
            try ConnectionWorkspaceDisk.requireAbsent([paths.smbInPlaceRoot])
            return nil
        }
        guard file.snapshot.format == 4 else { throw ConnectionWorkspaceFailure.reviewRequired }
        let witness = ConnectionWorkspaceWitness(paths: paths, record: file.snapshot,
            identity: try file.recoveryReadIdentity(), access: .coldRecovery)
        let storage = try SMBTemporaryStorage(connectionWorkspaceDirectory: paths.metadata, witness: witness)
        return try SMBInPlaceWorkingCopyStorage(metadataStorage: storage, coldRecovery: true)
    }
    public func recoveryListingAfterExplicitRequest() async throws -> SFTPInPlaceRecoveryListing {
        // Registration precedes metadata validation, so Stop joins even a
        // held record/root inspection. No work can begin after a returned drain.
        try await recoveryReader.discoverPrepared { [self] in try retainedLayout() }
    }
    public func retainedDocumentsAfterExplicitRequest() async throws -> [SFTPRetainedDocumentChoice] {
        try await retirementOwner.choices { [self] in try retainedLayout() }
    }
    public func removeRetainedDocument(_ choice: SFTPRetainedDocumentChoice) async throws {
        try await retirementOwner.remove(choice) { [self] in try retainedLayout() }
    }
    private func retainedLayout() throws -> SFTPSharedBudgetLayout? {
        try ConnectionWorkspaceDisk.checkThread()
        guard let file = try ConnectionWorkspaceDisk.File.open(paths.record, writing: false) else {
            try ConnectionWorkspaceDisk.requireAbsent(paths.graph + paths.earlierSiblings); return nil
        }
        defer { file.close() }
        guard file.snapshot.isActive else { throw ConnectionWorkspaceFailure.reviewRequired }
        try ConnectionWorkspaceDisk.validateGraph(paths, record: file.snapshot, retirementAccess: .passive)
        let witness = ConnectionWorkspaceWitness(paths: paths, record: file.snapshot, identity: try file.recoveryReadIdentity(), access: .coldRecovery)
        let storage = try SMBTemporaryStorage(connectionWorkspaceDirectory: paths.metadata, witness: witness)
        return SFTPSharedBudgetLayout(storage: storage)
    }

    /// One explicit, read-only choice for a v1 location record whose mount
    /// device number changed. No profile record is rewritten by discovery.
    public func legacyIdentityChoiceAfterExplicitRequest() async throws -> ConnectionWorkspaceRebindChoice {
        let value = try await repairOwner.perform { [paths] in
            try ConnectionWorkspaceDisk.checkThread()
            guard let file = try ConnectionWorkspaceDisk.File.open(paths.record, writing: false,
                                                                   repairReview: true) else {
                throw ConnectionWorkspaceFailure.reviewRequired
            }
            defer { file.close() }
            let graph = try ConnectionWorkspaceRepairGraph.open(paths: paths, record: file.snapshot,
                                                                 legacyRebind: true)
            defer { graph.close() }
            let next = try ConnectionWorkspaceRebindDisk.project(paths, record: file.snapshot)
            let proposed = try next.encoded()
            if let pending = file.pending {
                guard try ConnectionWorkspaceRebindDisk.successor(file.snapshot, pending),
                      try pending.encoded() == proposed else { throw ConnectionWorkspaceFailure.changed }
            }
            try graph.validateCurrent()
            return .rebind(.init(action: file.pending == nil ? .reconcile : .resume,
                                 paths: paths, location: try file.repairReadIdentity(),
                                 current: try file.snapshot.encoded(), pending: try file.pending?.encoded(),
                                 proposed: proposed, observation: graph.observation,
                                 observedObjectCount: file.snapshot.graph.count + 2))
        }
        guard case .rebind(let choice) = value else { throw ConnectionWorkspaceFailure.changed }
        return choice
    }

    /// Mutation authority stays with the existing location EX and complete
    /// held graph. A selected v1 record and every current APFS object must
    /// still match the read-only choice before its single durable publication.
    public func reconcileLegacyIdentity(_ choice: ConnectionWorkspaceRebindChoice) async throws {
        _ = try await repairOwner.perform { [paths] in
            try ConnectionWorkspaceDisk.checkThread()
            guard choice.paths == paths,
                  let file = try ConnectionWorkspaceDisk.File.open(paths.record, writing: true,
                                                                   repairReview: true, existingOnly: true) else {
                throw ConnectionWorkspaceFailure.changed
            }
            defer { file.close() }
            guard try file.repairReadIdentity() == choice.location,
                  try file.snapshot.encoded() == choice.current,
                  try file.pending?.encoded() == choice.pending else { throw ConnectionWorkspaceFailure.changed }
            let graph = try ConnectionWorkspaceRepairGraph.open(paths: paths, record: file.snapshot,
                                                                 legacyRebind: true)
            defer { graph.close() }
            guard graph.observation == choice.observation,
                  try ConnectionWorkspaceRebindDisk.project(paths, record: file.snapshot).encoded() == choice.proposed else {
                throw ConnectionWorkspaceFailure.changed
            }
            try graph.validateCurrent(); try file.validateRepairCurrent()
            if let pending = file.pending {
                guard choice.action == .resume, try pending.encoded() == choice.proposed else {
                    throw ConnectionWorkspaceFailure.changed
                }
                try file.promoteExactRepairPending()
            } else {
                guard choice.action == .reconcile,
                      let next = try? ConnectionWorkspaceRecord.decode(choice.proposed),
                      try ConnectionWorkspaceRebindDisk.successor(file.snapshot, next) else {
                    throw ConnectionWorkspaceFailure.changed
                }
                try file.commit(next)
            }
            try ConnectionWorkspaceDisk.validateGraph(paths, record: file.snapshot)
            try ConnectionWorkspaceDisk.validateLegacyFence(paths, record: file.snapshot)
            return .done
        }
    }

    #if DEBUG
    var retainedDrainRegisteredForQualification: Bool { retirementOwner.drainingForQualification }
    #endif
    /// A detached, exact repair choice has no mutation authority until the
    /// record owner and complete graph are rechecked under exclusive leases.
    public func repairChoiceAfterExplicitRequest() async throws -> ConnectionWorkspaceRepairChoice {
        let value = try await repairOwner.perform { [paths] in
            try ConnectionWorkspaceDisk.checkThread()
            guard let file = try ConnectionWorkspaceDisk.File.open(paths.record, writing: false, repairReview: true) else { throw ConnectionWorkspaceFailure.reviewRequired }
            defer { file.close() }
            let action: ConnectionWorkspaceRepairAction
            let parents: [String: ConnectionWorkspaceIdentity]
            let effective = file.pending ?? file.snapshot
            if file.pending != nil || file.snapshot.phase == .repairing {
                action = .resume; try ConnectionWorkspaceRepairDisk.validateState(paths, record: effective)
                guard let repair = effective.repair else { throw ConnectionWorkspaceFailure.reviewRequired }
                parents = repair.stage == .intent ? repair.parentBefore : repair.parents
            } else {
                action = .repair; parents = try ConnectionWorkspaceRepairDisk.eligible(paths, record: file.snapshot)
            }
            let graph = try ConnectionWorkspaceRepairGraph.open(paths: paths, record: file.snapshot)
            defer { graph.close() }
            return .choice(.init(action: action, paths: paths, location: try file.repairReadIdentity(),
                current: try file.snapshot.encoded(), pending: try file.pending?.encoded(), observation: graph.observation, parents: parents))
        }
        guard case .choice(let choice) = value else { throw ConnectionWorkspaceFailure.changed }
        return choice
    }
    public func repairConnectionStorage(_ choice: ConnectionWorkspaceRepairChoice) async throws {
        _ = try await repairOwner.perform { [paths] in
            try ConnectionWorkspaceDisk.checkThread()
            guard try ConnectionWorkspaceDisk.missing(paths.record) == false,
                  let file = try ConnectionWorkspaceDisk.File.open(paths.record, writing: true, repairReview: true, existingOnly: true) else { throw ConnectionWorkspaceFailure.changed }
            defer { file.close() }
            let preparation = try PrivateStateDirectorySequence(directories: paths.repairPreparation)
            try ConnectionWorkspaceRepairDisk.repair(paths, file: file, choice: choice, preparation: preparation)
            return .done
        }
    }
    /// Only retained cold discovery/read/removal owners drain here. This is also
    /// the Saved Versions Stop/close seam; it does not stop live connections,
    /// cancel activation or permanently revoke later explicit local review.
    public func stopAndDrain() async {
        async let repair: Void = repairOwner.stopAndDrain()
        async let read: Void = recoveryReader.stopAndDrain()
        async let smbRead: Void = smbRecoveryReader.stopAndDrain()
        async let removal: Void = retirementOwner.stopAndDrain()
        _ = await (repair, read, smbRead, removal)
    }
}
