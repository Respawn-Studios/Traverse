import AppKit
import LocalStorage

/// One private preparation pool for this running app/profile. Window/tab
/// controllers own their sessions; this owner coordinates cache lifetime.
@MainActor final class ApplicationCompressedArchives {
    static let shared = ApplicationCompressedArchives()
    private var pool: TARCompressedPreparationPool?
    private var preparation: PrivateStateDirectorySequence?
    private var quiescing = false
    #if DEBUG
    // Set by the existing generated native check after its exact scope check.
    var cacheDirectoryForVerification: URL?
    #endif

    private var directory: URL? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--verify-ui") {
            return cacheDirectoryForVerification?.appendingPathComponent("compressed-archives", isDirectory: true)
        }
        #endif
        return AppStorageLocations.layout?.cacheDirectory.appendingPathComponent("compressed-archives", isDirectory: true)
    }
    func reader(excluding roots: [URL]) -> TARArchiveReader {
        guard CompressedTARFeature.available, !quiescing, let directory else {
            return TARArchiveReader(activity: ApplicationFileActivity.gate, excludedRoots: roots)
        }
        if pool == nil { pool = TARCompressedPreparationPool(cacheDirectory: directory, activity: ApplicationFileActivity.gate) }
        return TARArchiveReader(activity: ApplicationFileActivity.gate, excludedRoots: roots + [directory], compressedPool: pool)
    }
    /// Only explicit Prepare creates cache storage, through the existing
    /// guarded off-main directory owner. Merely opening a tab remains inert.
    func prepareStorage() async throws {
        guard !quiescing, pool != nil, let directory else { throw TARArchiveFailure.busy }
        let base = try AppStoragePreparation.owner(for: directory.deletingLastPathComponent())
        if preparation == nil { preparation = try AppStoragePreparation.owner(for: directory) }
        try await base.prepare()
        try await preparation?.prepare()
        guard !quiescing, !Task.isCancelled else { throw TARArchiveFailure.stopped }
    }
    /// Precedes global gate closure so the pool can admit retirement work.
    func prepareForQuiescence() throws {
        quiescing = true
        do { try pool?.prepareForQuiescence() }
        catch { quiescing = false; pool?.resumeAfterQuiescence(); throw error }
    }
    func resumeAfterQuiescence() {
        pool?.resumeAfterQuiescence(); quiescing = false
    }
    func drain() async -> Bool { await pool?.drain() ?? true }
    var storageComponent: AppStorageComponent? {
        guard let usage = pool?.usage else { return nil }
        func bytes(_ value: UInt64) -> String { FileSizeText.string(Int64(clamping: value)) }
        let prefix = usage.isComplete ? "" : "Known: "
        return .init(title: "Prepared compressed archives",
            logical: prefix + bytes(usage.knownLogicalBytes), allocation: prefix + bytes(usage.knownAllocatedBytes),
            note: "\(usage.entryCount) temporary copies · \(bytes(usage.reservedBytes)) reserved. "
                + (usage.isComplete ? "Observed file allocation, including open temporary copies." : "Partial observation; preparation or cleanup is still in progress.")
                + (usage.hasRetainedCleanup ? " Some temporary work needs attention." : "")
                + " Reservations are limits, not used space. Allocation is not exclusive or reclaimable space.")
    }
    func closeAndDrain() async -> Bool {
        quiescing = true
        guard let pool else { quiescing = false; return true }
        guard await pool.closeAndDrain() else { return false }
        self.pool = nil; preparation = nil; quiescing = false
        return true
    }
}

enum CompressedTARFeature {
    #if DEBUG
    @MainActor static var qualifying = false
    #endif
    @MainActor static var available: Bool {
        #if DEBUG
        if qualifying { return true }
        #endif
        return TARBrowseFeature.available
    }
}
