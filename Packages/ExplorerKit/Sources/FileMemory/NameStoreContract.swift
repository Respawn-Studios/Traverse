import Foundation

/// Storage status is separate from file-operation recovery. These values carry
/// no authored names, source paths, SQL text or private diagnostics.
public enum NameStoreStatus: Sendable, Equatable {
    case absent, ready, busy, initializationIncomplete, recoveryRequired
    case forgetPending, accessRemovalPending, indexUpdateRequired, referenceUpdateRequired, unsupported, unsafe, unavailable
}

public enum NameStoreFailure: Error, Sendable, Equatable {
    case busy, unsafe, changed, unavailable, unsupported, recoveryRequired
    case initializationIncomplete, indexUpdateRequired, forgetPending, continuityUpdateRequired
    case uncertainCommit, readOnly, invalidRequest, quota, closed, referenceUpdateRequired
}

public struct NameStoreInspection: Sendable, Equatable {
    public let status: NameStoreStatus
    public let records: Int?
    public let pendingRevocations: Int?
    internal init(_ status: NameStoreStatus, records: Int? = nil, pending: Int? = nil) {
        self.status = status; self.records = records; pendingRevocations = pending
    }
}

/// Explicit write admission. Passive inspection never performs either action.
public enum NameStoreOpenAction: Sendable {
    case readOnly, edit, recover, updateIndex, upgradeReferences, upgradeMoveContinuity, upgradeMoveMembers
}

public enum RememberedForgetOutcome: Sendable, Equatable {
    case forgotten
    /// Revocation is durable; cleanup or owned-work drain still needs finishing.
    case hiddenPending
    /// No durable fence was proved. Only this live owner can promise suppression.
    case sessionHiddenOnly
}

internal enum NameStoreFormat {
    static let schema = 2
    static let moveSchema = 3
    static let memberSchema = 4
    static let applicationID = 0x4D454D31
    static let maximumRecords = 100_000
    static let maximumBytes = 512 * 1_024 * 1_024
    // Foundation folding is OS supplied. A changed runtime requires explicit
    // validation/reprojection, never silent reinterpretation of persisted keys.
    static var runtime: String {
        ProcessInfo.processInfo.operatingSystemVersionString + "|foundation-fold-posix-v1"
    }
}

/// Narrow, internal boundary probes for generated qualification only. No global
/// hook, process termination or fault implementation exists in product code.
internal enum NameStoreBoundary: String, Sendable {
    case sourceCapture, sourcePrepared
    case initialized, firstCommit, ready, saveRows, saveCommit
    case revocationRows, revocationCommit, purgeRows, purgeCommit, acknowledged, indexRows
    case referenceUpgradeRows, referenceUpgradeCommit, referenceRows, referenceCommit
    case accessFenceRows, accessFenceCommit, accessPurgeRows, accessPurgeCommit
    case moveUpgradeRows, moveUpgradeCommit, moveIntentRows, moveIntentCommit
    case moveReferenceRows, moveReferenceCommit, moveUndoIntentRows, moveUndoIntentCommit
    case memberUpgradeRows, memberUpgradeCommit, memberReceiptRows, memberReceiptCommit
}
internal typealias NameStoreProbe = @Sendable (NameStoreBoundary) throws -> Void
