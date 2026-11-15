import Foundation

/// The first Format Volume candidate is an erase of one ordinary APFS volume
/// on a disk image. It does not change its APFS personality or partition map.
public enum APFSVolumeFormatFailure: Error, Equatable, Sendable {
    case unavailable, unsupported, busy, changed, protected, denied, confirmationRequired, cancelled, uncertain, recoveryUnavailable

    public var userMessage: String {
        switch self {
        case .unavailable: "Formatting is unavailable in this edition or for this selection."
        case .unsupported: "Choose an ordinary, unencrypted APFS volume on a disk image. Volume groups, special roles, quotas and reserves are not supported here."
        case .busy: "Another volume check is still finishing."
        case .changed: "The volume or its container changed. Refresh and review it again."
        case .protected: "Drive protection or active Traverse storage prevents this action. Review the current drive."
        case .denied: "macOS did not permit this volume action. Inspect the disk image in Disk Utility."
        case .confirmationRequired: "Type the selected volume name exactly to confirm its contents will be erased."
        case .cancelled: "The check was cancelled before the erase request began."
        case .uncertain: "An erase request was submitted, but the final volume state could not be confirmed. Inspect the disk image before taking another action."
        case .recoveryUnavailable: "The drive job record could not be verified. No erase request will start; inspect the saved job before trying again."
        }
    }
}

/// A short-lived, exact-volume review. The name is the confirmation phrase;
/// the preflight and launch gate recheck authority before any process starts.
public struct APFSVolumeFormatPlan: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let selected: ManagedVolume
    public let name: String
    public let caseSensitive: Bool
    public let siblingNames: [String]
    public let capturedAt: Date
    let expiresAt: TimeInterval
    let original: APFSObservedVolume

    public var description: String { "APFS volume format review" }
    public var debugDescription: String { description }

    init(selected: ManagedVolume, original: APFSObservedVolume) {
        self.selected = selected
        name = original.info.name
        caseSensitive = original.info.caseSensitive
        siblingNames = original.container.volumes.filter { $0.uuid != original.info.uuid }.map(\.name)
        capturedAt = Date()
        expiresAt = ProcessInfo.processInfo.systemUptime + 60
        self.original = original
    }
}

public struct APFSVolumeFormatResult: Sendable {
    public struct FormattedVolume: Sendable {
        public let id: UUID
        public let name: String
        public let mountPoint: URL?
    }
    public let submitted: Bool
    /// Present only after a zero-status native return and independent exact
    /// replacement/unchanged-sibling reconciliation. This is not an Undo.
    public let formatted: FormattedVolume?
    public let failure: APFSVolumeFormatFailure?
    public let toolExitStatus: Int32?
    public let diskutilErrorCode: Int?

    init(submitted: Bool, formatted: FormattedVolume?, failure: APFSVolumeFormatFailure?,
         toolExitStatus: Int32? = nil, diskutilErrorCode: Int? = nil) {
        self.submitted = submitted
        self.formatted = formatted
        self.failure = failure
        self.toolExitStatus = toolExitStatus
        self.diskutilErrorCode = diskutilErrorCode
    }
}

public enum APFSVolumeFormatRecoveryInspection: Sendable {
    /// Current APFS identity is compatible with a replacement. This does not
    /// prove the old generated marker was erased or who caused the change.
    case compatibleReplacement(APFSVolumeFormatResult.FormattedVolume)
    case unresolved
}

/// One image-only APFS volume erase. The application must separately require
/// Development policy, a real destructive review and its exclusive activity
/// gate. After Process.run succeeds, this owner waits for the child and then
/// reconciles; Stop, timeout and a nonzero exit never claim data was restored.
public final class APFSVolumeFormat: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied = false
    private let inspector: any VolumeInspecting
    private let tool: APFSVolumeTool

    public init() { inspector = VolumeLifecycle.shared; tool = APFSVolumeTool() }
    init(tool: APFSVolumeTool) { inspector = VolumeLifecycle.shared; self.tool = tool }

    /// Cold recovery is read-only. The caller must independently bind the
    /// original backing image and attachment both before and after inquiries;
    /// a reused BSD name or an absent owner never clears an unresolved job.
    public func inspectRecovery(_ snapshot: APFSVolumeFormatSnapshot,
                                ownerStillCurrent: @escaping @Sendable () -> Bool) async -> APFSVolumeFormatRecoveryInspection {
        guard snapshot.validate(), ownerStillCurrent() else { return .unresolved }
        do {
            let after = try APFSContainerObservation.decode(
                try await tool.inquire(["apfs", "list", "-plist", snapshot.containerDevice]),
                selected: snapshot.targetID, requireSelected: false)
            guard let replacement = Self.reconciledReplacement(before: snapshot.originalContainer(), after: after,
                                                                original: snapshot.targetID, name: snapshot.name) else { return .unresolved }
            let info = try APFSVolumeObservation.decode(try await tool.inquire(["info", "-plist", replacement.device]))
            guard info.uuid == replacement.uuid, info.device == replacement.device,
                  info.container == snapshot.containerDevice, info.name == snapshot.name,
                  info.caseSensitive == snapshot.caseSensitive, ownerStillCurrent() else { return .unresolved }
            return .compatibleReplacement(.init(id: replacement.uuid, name: replacement.name, mountPoint: info.mount))
        } catch { return .unresolved }
    }

    public func prepare(_ selected: ManagedVolume) async throws -> APFSVolumeFormatPlan {
        try admit()
        defer { release() }
        let cancellation = APFSVolumeTool.Cancellation()
        do {
            return try await withTaskCancellationHandler {
                let observed = try await APFSVolumeObservationReader.observe(selected, inspector: inspector, tool: tool,
                                                                              cancellation: cancellation, diskImageOnly: true)
                try Self.validateTarget(observed)
                try Task.checkCancellation()
                return .init(selected: selected, original: observed)
            } onCancel: { cancellation.cancel() }
        } catch { throw Self.preflightFailure(error) }
    }

    /// `confirmedName` must be independently entered by the person reviewing
    /// the loss of this volume's contents. `permitted` is rechecked on the
    /// worker queue at the launch boundary, not only when the sheet opens.
    public func perform(_ plan: APFSVolumeFormatPlan, confirmedName: String,
                        permitted: @escaping @Sendable () -> Bool,
                        submitted: @escaping @Sendable () -> Void = {},
                        recording: (any APFSVolumeFormatRecording)? = nil) async -> APFSVolumeFormatResult {
        do { try admit() } catch { return .init(submitted: false, formatted: nil, failure: .busy) }
        defer { release() }
        guard confirmedName == plan.name else {
            return .init(submitted: false, formatted: nil, failure: .confirmationRequired)
        }
        let cancellation = APFSVolumeTool.Cancellation()
        let submission = APFSVolumeTool.MutationAdmission()
        let recovery = recording.map(APFSVolumeFormatRecoverySession.init)
        var intentRecorded = false
        var didSubmit = false
        var terminal: APFSVolumeTool.MutationReply?
        var result: APFSVolumeFormatResult
        do {
            guard permitted() else { throw APFSVolumeFormatFailure.unavailable }
            let current = try await withTaskCancellationHandler {
                try await APFSVolumeObservationReader.observe(plan.selected, inspector: inspector, tool: tool,
                                                              cancellation: cancellation, diskImageOnly: true)
            } onCancel: { cancellation.cancel() }
            try Self.validateTarget(current)
            guard Self.sameTarget(plan.original, current),
                  ProcessInfo.processInfo.systemUptime < plan.expiresAt else { throw APFSVolumeFormatFailure.changed }
            try Task.checkCancellation()
            if cancellation.isCancelled { throw CancellationError() }
            guard permitted() else { throw APFSVolumeFormatFailure.unavailable }
            if let recovery {
                do { try await recovery.begin(APFSVolumeFormatSnapshot(current)); intentRecorded = true }
                catch { throw APFSVolumeFormatFailure.recoveryUnavailable }
            }
            terminal = try await withTaskCancellationHandler {
                try await tool.eraseVolume(device: current.info.device, name: plan.name, admission: submission,
                                           permitted: { permitted() && (recovery?.ownerStillCurrent() ?? true)
                                               && ProcessInfo.processInfo.systemUptime < plan.expiresAt
                                               && !cancellation.isCancelled }, submitted: {
                                               recovery?.didSubmit(); submitted()
                                           })
            } onCancel: {
                cancellation.cancel()
                submission.cancel()
            }
            didSubmit = true
            // The old volume UUID may have been replaced by eraseVolume. Parse
            // the whole container without demanding that old member still exists.
            let after = try APFSContainerObservation.decode(
                try await tool.inquire(["apfs", "list", "-plist", current.container.device]),
                selected: current.info.uuid, requireSelected: false)
            guard terminal?.status == 0,
                  let replacement = Self.reconciledReplacement(before: current.container, after: after,
                                                               original: current.info.uuid, name: plan.name) else {
                throw APFSVolumeFormatFailure.uncertain
            }
            let info = try APFSVolumeObservation.decode(try await tool.inquire(["info", "-plist", replacement.device]))
            guard info.uuid == replacement.uuid, info.device == replacement.device,
                  info.container == current.container.device, info.name == plan.name,
                  info.caseSensitive == plan.caseSensitive,
                  recovery?.ownerStillCurrent() ?? true else { throw APFSVolumeFormatFailure.uncertain }
            result = .init(submitted: true,
                         formatted: .init(id: replacement.uuid, name: replacement.name, mountPoint: info.mount),
                         failure: nil, toolExitStatus: terminal?.status, diskutilErrorCode: terminal?.errorCode)
        } catch {
            result = .init(submitted: didSubmit, formatted: nil,
                         failure: didSubmit ? .uncertain : Self.preflightFailure(error),
                         toolExitStatus: terminal?.status, diskutilErrorCode: terminal?.errorCode)
        }
        if intentRecorded, let recovery { return await recovery.finish(result) }
        return result
    }

    private func admit() throws {
        try lock.withLock { guard !occupied else { throw APFSVolumeFormatFailure.busy }; occupied = true }
    }
    private func release() { lock.withLock { occupied = false } }

    static func validateTarget(_ observed: APFSObservedVolume) throws {
        let info = observed.info, container = observed.container
        let target = container.volumes.filter { $0.uuid == info.uuid && $0.device == info.device && $0.name == info.name }
        guard target.count == 1, target[0].quota == 0, target[0].reserve == 0,
              container.volumes.filter({ $0.name == info.name }).count == 1, info.mount != nil else {
            throw APFSVolumeFormatFailure.unsupported
        }
    }

    private static func sameTarget(_ old: APFSObservedVolume, _ current: APFSObservedVolume) -> Bool {
        let a = old.info, b = current.info
        return a.uuid == b.uuid && a.device == b.device && a.container == b.container
            && a.name == b.name && a.mount == b.mount && a.caseSensitive == b.caseSensitive
            && old.container.sameIdentityAndMembers(as: current.container)
    }

    /// Exact siblings must survive. An unchanged old identity cannot prove an
    /// erase, even if a tool reported success; it remains uncertain pending an
    /// independently observable replacement.
    static func reconciledReplacement(before: APFSContainerObservation, after: APFSContainerObservation,
                                      original: UUID, name: String) -> APFSContainerObservation.Volume? {
        guard before.device == after.device, before.uuid == after.uuid, before.capacity == after.capacity,
              before.stores == after.stores, before.volumes.count == after.volumes.count,
              let old = before.volumes.first(where: { $0.uuid == original && $0.name == name }) else { return nil }
        let siblings = before.volumes.filter { $0.uuid != original }
        guard siblings.allSatisfy({ after.volumes.contains($0) }),
              let new = after.volumes.first(where: { $0.name == name && $0.uuid != original }),
              after.volumes.filter({ $0.name == name }).count == 1,
              new.quota == 0, new.reserve == 0,
              new.uuid != old.uuid else { return nil }
        return new
    }

    private static func preflightFailure(_ error: Error) -> APFSVolumeFormatFailure {
        if error is CancellationError { return .cancelled }
        if let failure = error as? APFSVolumeFormatFailure { return failure }
        if let failure = error as? APFSVolumeCreationFailure {
            switch failure {
            case .unsupported, .invalidName, .nameConflict, .insufficientSpace: return .unsupported
            case .changed: return .changed
            case .denied: return .denied
            case .cancelled: return .cancelled
            case .busy: return .busy
            default: break
            }
        }
        if let failure = error as? VolumeLifecycleFailure {
            switch failure {
            case .changed: return .changed
            case .protectedStorage, .userProtected, .protectionUncertain: return .protected
            case .denied: return .denied
            case .busy: return .busy
            case .unsupported: return .unsupported
            default: break
            }
        }
        return .unavailable
    }
}
