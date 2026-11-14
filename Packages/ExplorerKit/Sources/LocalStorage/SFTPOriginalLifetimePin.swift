import Darwin
import Foundation

/// A checked owner SH held throughout the actual editor or viewer lifetime.
/// Only catalog or validated recovery metadata authority constructs it.
final class SFTPOriginalLifetimePin: @unchecked Sendable {
    let reference: SFTPOriginalSpoolReference, layout: SFTPSharedBudgetLayout
    private let pool: Int32, folder: Int32
    private let lease: DownloadDisk.SharedOriginalLease
    private let executor = UploadLocalExecutor(label: "Traverse.SFTP.ManagedBodyPin")
    private let lock = NSLock()
    private var closed = false
    #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
    private var gateBDrainObserver: (@Sendable () -> Void)?
    func installGateBDrainObserver(_ observer: @escaping @Sendable () -> Void) throws {
        try lock.withLock {
            guard !closed, gateBDrainObserver == nil else { throw SFTPTextFailure.changed }
            gateBDrainObserver = observer
        }
    }
    #endif
    private init(layout: SFTPSharedBudgetLayout, budgetID: UUID,
                 reference: SFTPOriginalSpoolReference, pool borrowed: Int32,
                 bodyOwner: SFTPOriginalBodyPoolExclusive,
                 validate: (DownloadDisk.Record) throws -> Void) throws {
        guard !Thread.isMainThread else { throw SFTPTextFailure.busy }
        try bodyOwner.validate(pool: borrowed)
        try SMBCatalogFiles.validatePool(borrowed, at: layout.bodies)
        guard try SFTPSharedBudgetTransaction.readFence(borrowed,
            name: SFTPSharedBudgetTransaction.bodyFence, prefix: "MEXSHAREDBODY1") == budgetID
        else { throw SFTPSharedBudgetFailure.stale }
        let pool = dup(borrowed)
        guard pool >= 0 else { throw SFTPTextFailure.changed }
        var folder: Int32 = -1, held: DownloadDisk.SharedOriginalLease?, keep = false
        defer {
            if !keep {
                _ = held?.closeAfterDrain()
                if folder >= 0 { Darwin.close(folder) }
                Darwin.close(pool)
            }
        }
        let name = "download-" + reference.id.uuidString
        let before = try DownloadDisk.record(pool, name: name)
        try validate(before)
        folder = openat(pool, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard folder >= 0, try DownloadDisk.identity(folder) == before.folder,
              let ownerIdentity = before.files["owner.lock"] else { throw SFTPTextFailure.changed }
        let lease = try DownloadDisk.SharedOriginalLease.acquire(folder: folder, expected: ownerIdentity)
        held = lease
        let actual = try DownloadDisk.record(pool, name: name, heldReadLease: lease)
        try validate(actual)
        guard actual.folder == before.folder, actual.marker == before.marker,
              actual.files == before.files else { throw SFTPTextFailure.changed }
        try SFTPSharedBudgetTransaction.checkDigest(pool: pool, record: actual, reference: reference, bodyDirectory: layout.bodies)
        self.pool = pool; self.folder = folder; self.lease = lease
        self.layout = layout; self.reference = reference; keep = true
        #if DEBUG && !SFTP_PARENT_STANDALONE
        SFTPGeneratedBackendObservation.shared.bodyPinOpened(directory: layout.bodies)
        #endif
    }
    static func open(_ authority: SFTPOriginalLifetimePinAuthority, pool: Int32,
                     bodyOwner: SFTPOriginalBodyPoolExclusive) throws -> SFTPOriginalLifetimePin {
        try .init(layout: authority.layout, budgetID: authority.budgetID,
            reference: authority.reference, pool: pool, bodyOwner: bodyOwner,
            validate: authority.validate)
    }
    static func openForRecovery(_ authority: SFTPInPlaceRecoveryBodyAuthority,
        layout: SFTPSharedBudgetLayout, pool: Int32,
        bodyOwner: SFTPOriginalBodyPoolExclusive) throws -> SFTPOriginalLifetimePin {
        try .init(layout: layout, budgetID: authority.budget, reference: authority.reference,
            pool: pool, bodyOwner: bodyOwner,
            validate: { try authority.validate(record: $0, reference: authority.reference) })
    }
    private func closeOnLane() -> Bool {
        if lock.withLock({ closed }) { return true }
        guard lease.closeAfterDrain() else { return false }
        Darwin.close(folder); Darwin.close(pool)
        lock.withLock { closed = true }
        #if DEBUG && !SFTP_PARENT_STANDALONE
        SFTPGeneratedBackendObservation.shared.bodyPinDrained(directory: layout.bodies)
        #endif
        #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
        let observer = lock.withLock { gateBDrainObserver }
        observer?()
        #endif
        return true
    }
    func closeAndDrain() async -> Bool {
        await executor.drain { [self] in _ = closeOnLane() }
        return lock.withLock { closed }
    }
    #if DEBUG
    /// Qualification only: inspect this exact already-minted SH owner. The
    /// independent EX contender is opened separately by the viewed-version
    /// assertion; a caller cannot supply a body path or spool UUID.
    func generatedQualificationIsOpen() throws -> Bool {
        guard !Thread.isMainThread else { throw SFTPTextFailure.busy }
        if lock.withLock({ closed }) { return false }
        let record = try DownloadDisk.record(pool, name: "download-" + reference.id.uuidString,
            heldReadLease: lease)
        guard record.summary.id == reference.id, record.summary.active else { throw SFTPTextFailure.changed }
        return true
    }
    #endif
    deinit {
        if !closed {
            let held = lease, folder = folder, pool = pool
            executor.enqueueDrain {
                // An unintentionally dropped visible owner keeps its actual
                // SH descriptor in the bounded quarantine until process exit.
                withExtendedLifetime(held) { Darwin.close(folder); Darwin.close(pool) }
            }
        }
    }
}
