import Dispatch
import Foundation
import THSMART

// Generated qualification module. It is not linked by ExplorerKit or the app.
// No registry traversal, native backend, access grant or device enable exists.
enum DeviceHealthKind: UInt8, Sendable { case ata = 1, nvme = 2 }

struct DeviceHealthTarget: Equatable, Sendable {
    let physicalMedia: UInt64
    let provider: UInt64
    let attachment: UInt64
    let kind: DeviceHealthKind

    init?(physicalMedia: UInt64, provider: UInt64, attachment: UInt64, kind: DeviceHealthKind) {
        guard physicalMedia != 0, provider != 0, attachment != 0 else { return nil }
        self.physicalMedia = physicalMedia; self.provider = provider
        self.attachment = attachment; self.kind = kind
    }
}

struct DeviceHealthWarning: Equatable, Sendable {
    let kind: DeviceHealthKind
    let raw: UInt8
    // No temperature, lifetime or universal Healthy inference follows.
    var warningReported: Bool { raw != 0 }
    var unknownNVMeBits: UInt8 { kind == .nvme ? raw & 0xc0 : 0 }

    static func decodeNVMe(_ bytes: Data) -> Self? {
        guard bytes.count == 512, let warning = bytes.first else { return nil }
        return Self(kind: .nvme, raw: warning)
    }
}

struct DeviceHealthFailure: Error, Equatable, Sendable {
    enum Category: Equatable, Sendable { case denied, busy, disconnected, unsupported, unavailable, invalidContract }
    let category: Category
    let stage: UInt32
    let domain: UInt32
    let code: Int32
    let cleanupCode: Int32

    static func contract(_ code: Int32) -> Self {
        Self(category: .invalidContract, stage: UInt32(THStageAdmission),
             domain: UInt32(THDomainContract), code: code, cleanupCode: 0)
    }

    init(stage: UInt32, domain: UInt32, code: Int32, cleanupCode: Int32) {
        self.stage = stage; self.domain = domain; self.code = code; self.cleanupCode = cleanupCode
        if domain == UInt32(THDomainContract) { category = .invalidContract }
        else if domain == UInt32(THDomainHRESULT) {
            category = code == th_smart_no_interface_hresult() ? .unsupported : .invalidContract
        } else if domain == UInt32(THDomainKernel) || domain == UInt32(THDomainIOReturn) {
            switch code {
            case kIOReturnNotPrivileged, kIOReturnNotPermitted: category = .denied
            case kIOReturnBusy, kIOReturnExclusiveAccess: category = .busy
            case kIOReturnNoDevice, kIOReturnOffline, kIOReturnNotAttached: category = .disconnected
            case kIOReturnUnsupported: category = .unsupported
            default: category = .unavailable
            }
        } else { category = .invalidContract }
    }

    private init(category: Category, stage: UInt32, domain: UInt32, code: Int32, cleanupCode: Int32) {
        self.category = category; self.stage = stage; self.domain = domain
        self.code = code; self.cleanupCode = cleanupCode
    }
}

enum DeviceHealthReadValue: Equatable, Sendable {
    case warning(DeviceHealthWarning)
    case failure(DeviceHealthFailure)

    init(native: THSMARTResult, expected: DeviceHealthKind) {
        guard native.provider_kind == expected.rawValue else {
            self = .failure(.contract(-1)); return
        }
        guard native.warning_valid == 1, native.cleanup_incomplete == 0,
              native.stage == THStageComplete, native.code_domain == THDomainNone,
              native.primary_code == 0, native.destroy_code == 0,
              expected == .nvme || native.warning_byte <= 1 else {
            self = .failure(DeviceHealthFailure(stage: native.stage, domain: native.code_domain,
                code: native.primary_code, cleanupCode: native.destroy_code)); return
        }
        self = .warning(DeviceHealthWarning(kind: expected, raw: native.warning_byte))
    }
}

struct DeviceHealthNativeResult: Sendable {
    let value: DeviceHealthReadValue
    let cleanupComplete: Bool
    init(_ native: THSMARTResult, expected: DeviceHealthKind) {
        value = DeviceHealthReadValue(native: native, expected: expected)
        cleanupComplete = native.cleanup_incomplete == 0
    }
}

// The lease is private to its actual worker until cleanup has returned. Its
// mutable release state is locked; all injected functions are Sendable and may
// block only on this module's dedicated serial queue.
final class DeviceHealthReadLease: @unchecked Sendable {
    let target: DeviceHealthTarget
    private let isCurrent: @Sendable () -> Bool
    private let read: @Sendable () -> DeviceHealthNativeResult
    private let release: @Sendable () -> Void
    private let lock = NSLock()
    private var releaseStarted = false
    private var releaseFinished = false

    init(target: DeviceHealthTarget, isCurrent: @escaping @Sendable () -> Bool,
         read: @escaping @Sendable () -> DeviceHealthNativeResult,
         release: @escaping @Sendable () -> Void) {
        self.target = target; self.isCurrent = isCurrent; self.read = read; self.release = release
    }
    var didRelease: Bool { lock.withLock { releaseFinished } }

    fileprivate func perform() -> DeviceHealthJobResult {
        guard isCurrent() else { finishRelease(); return .stale }
        let result = read()
        guard result.cleanupComplete else {
            // Malformed COM cleanup has no safe retry. Do not release the
            // provider lease, claim drain or start a pending reader.
            return .ownershipUncertain(self, result.value)
        }
        let current = isCurrent()
        finishRelease()
        return current ? .value(result.value) : .stale
    }

    private func finishRelease() {
        let admitted = lock.withLock { () -> Bool in
            guard !releaseStarted else { return false }; releaseStarted = true; return true
        }
        precondition(admitted, "Health lease release must occur exactly once")
        release()
        lock.withLock { releaseFinished = true }
    }
}

private enum DeviceHealthJobResult: Sendable {
    case value(DeviceHealthReadValue)
    case stale
    case ownershipUncertain(DeviceHealthReadLease, DeviceHealthReadValue)
}

enum DeviceHealthSessionEvent: Sendable {
    case observation(DeviceHealthTarget, DeviceHealthReadValue)
    case ownershipUncertain(DeviceHealthTarget, DeviceHealthReadValue)
}

@MainActor
final class DeviceHealthReadSession {
    typealias Acquire = @Sendable (DeviceHealthTarget) -> Result<DeviceHealthReadLease, DeviceHealthFailure>
    private struct Request: Sendable { let generation: UUID; let target: DeviceHealthTarget }
    private let queue = DispatchQueue(label: "local.traverse.generated-health-reader", qos: .utility)
    private let acquire: Acquire
    private let onEvent: @MainActor (DeviceHealthSessionEvent) -> Void
    private var generation: UUID?
    private var active: Request?
    private var pending: Request?
    private var retainedLease: DeviceHealthReadLease?

    init(acquire: @escaping Acquire, onEvent: @escaping @MainActor (DeviceHealthSessionEvent) -> Void) {
        self.acquire = acquire; self.onEvent = onEvent
    }
    var isDraining: Bool { active != nil || retainedLease != nil }
    var pendingCount: Int { pending == nil ? 0 : 1 }
    var hasUnresolvedOwnership: Bool { retainedLease != nil }

    func select(_ target: DeviceHealthTarget) {
        let id = UUID(); generation = id
        pending = Request(generation: id, target: target)
        startIfPossible()
    }
    func cancel() { generation = nil; pending = nil }

    private func startIfPossible() {
        guard active == nil, retainedLease == nil, let request = pending else { return }
        pending = nil; active = request
        let acquire = acquire
        // The queued job retains this owner through actual acquisition, native
        // read/Release/destroy, provider release and main-actor completion.
        queue.async { [self] in
            let result: DeviceHealthJobResult
            switch acquire(request.target) {
            case .success(let lease):
                if lease.target == request.target { result = lease.perform() }
                else {
                    // A different association cannot be adopted. Its owned
                    // lease still drains without invoking a native read.
                    result = lease.refuseChangedTarget()
                }
            case .failure(let error): result = .value(.failure(error))
            }
            Task { @MainActor [self] in finish(request, result: result) }
        }
    }
    private func finish(_ request: Request, result: DeviceHealthJobResult) {
        guard active?.generation == request.generation else {
            preconditionFailure("Health worker ownership changed before actual return")
        }
        active = nil
        switch result {
        case .ownershipUncertain(let lease, let value):
            retainedLease = lease
            onEvent(.ownershipUncertain(request.target, value))
        case .value(let value):
            if generation == request.generation { onEvent(.observation(request.target, value)) }
        case .stale: break
        }
        startIfPossible()
    }
}

private extension DeviceHealthReadLease {
    func refuseChangedTarget() -> DeviceHealthJobResult { finishRelease(); return .stale }
}
