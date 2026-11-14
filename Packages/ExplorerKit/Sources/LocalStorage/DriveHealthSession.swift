import Foundation
import IOKit
import DriveHealthNative

public enum DriveHealthKind: UInt8, Equatable, Sendable { case ata = 1, nvme = 2 }
public enum DriveHealthUnavailable: Equatable, Sendable {
    case denied, busy, disconnected, unsupported, stale, unavailable, uncertain
}
public enum DriveHealthOutcome: Equatable, Sendable {
    case warning(kind: DriveHealthKind, rawByte: UInt8, capturedAt: Date)
    case unavailable(DriveHealthUnavailable)
}
/// Failure location and numeric SDK results only. No attachment IDs, paths,
/// provider properties or free-form error descriptions are retained.
public struct DriveHealthDiagnostic: Equatable, Sendable {
    public enum Stage: String, Sendable {
        case sessionAdmission, selection, helperAdmission, installation, launch
        case childAdmission, request, reply, native, revalidation
    }
    public enum AdmissionFailure: String, Sendable { case policy, changed, signature }
    public enum TransportFailure: String, Sendable {
        case peerIdentity, connectionEnded, malformedReply, deadline
    }
    public struct Native: Equatable, Sendable {
        public let status, stage, domain: UInt32
        public let code, destroyCode: Int32
    }
    public let stage: Stage
    /// These flags describe this request, not another active or earlier child.
    public let childStarted, requestSent: Bool
    public let admissionFailure: AdmissionFailure?
    public let transportFailure: TransportFailure?
    public let native: Native?

    internal init(stage: Stage, childStarted: Bool = false, requestSent: Bool = false,
                  admissionFailure: AdmissionFailure? = nil, transportFailure: TransportFailure? = nil, native: Native? = nil) {
        self.stage = stage; self.childStarted = childStarted; self.requestSent = requestSent
        self.admissionFailure = admissionFailure; self.transportFailure = transportFailure; self.native = native
    }
}
/// Native cleanup and an owned child's reap remain separate completion facts.
public enum DriveHealthTransportCompletion: Equatable, Sendable {
    case notStarted
    case ownedChild(reaped: Bool)
    /// Settled means a terminal reply was consumed and the one-request service
    /// exited. Connection invalidation alone cannot establish either fact.
    case serviceReply(settled: Bool)

    public var childReaped: Bool {
        if case .ownedChild(let reaped) = self { return reaped }
        return false
    }
    public var transportSettled: Bool {
        switch self {
        case .notStarted: return true
        case .ownedChild(let reaped): return reaped
        case .serviceReply(let settled): return settled
        }
    }
}
public struct DriveHealthDrain: Equatable, Sendable {
    public let transport: DriveHealthTransportCompletion
    public var childReaped: Bool { transport.childReaped }
    public var transportSettled: Bool { transport.transportSettled }
    public let nativeCleanupConfirmed: Bool
    public init(childReaped: Bool, nativeCleanupConfirmed: Bool) {
        self.init(transport: .ownedChild(reaped: childReaped), nativeCleanupConfirmed: nativeCleanupConfirmed)
    }
    public init(transport: DriveHealthTransportCompletion, nativeCleanupConfirmed: Bool) {
        self.transport = transport
        self.nativeCleanupConfirmed = nativeCleanupConfirmed
    }
}
public struct DriveHealthReport: Equatable, Sendable {
    public let outcome: DriveHealthOutcome
    public let transport: DriveHealthTransportCompletion
    public var childReaped: Bool { transport.childReaped }
    public var transportSettled: Bool { transport.transportSettled }
    public let nativeCleanupConfirmed: Bool
    public let nvmeMeasurements: NVMeHealthMeasurements?
    public let diagnostic: DriveHealthDiagnostic?
    public init(outcome: DriveHealthOutcome, childReaped: Bool, nativeCleanupConfirmed: Bool,
                nvmeMeasurements: NVMeHealthMeasurements? = nil, diagnostic: DriveHealthDiagnostic? = nil) {
        self.init(outcome: outcome, transport: .ownedChild(reaped: childReaped),
                  nativeCleanupConfirmed: nativeCleanupConfirmed,
                  nvmeMeasurements: nvmeMeasurements, diagnostic: diagnostic)
    }
    public init(outcome: DriveHealthOutcome, transport: DriveHealthTransportCompletion, nativeCleanupConfirmed: Bool,
                nvmeMeasurements: NVMeHealthMeasurements? = nil, diagnostic: DriveHealthDiagnostic? = nil) {
        self.outcome = outcome
        self.transport = transport
        self.nativeCleanupConfirmed = nativeCleanupConfirmed
        self.diagnostic = diagnostic
        if nativeCleanupConfirmed, transport.transportSettled, case .warning(kind: .nvme, rawByte: _, capturedAt: _) = outcome {
            self.nvmeMeasurements = nvmeMeasurements
        } else { self.nvmeMeasurements = nil }
    }
    public var drain: DriveHealthDrain {
        DriveHealthDrain(transport: transport, nativeCleanupConfirmed: nativeCleanupConfirmed)
    }
    internal func replacingOutcome(_ outcome: DriveHealthOutcome, diagnostic: DriveHealthDiagnostic? = nil) -> Self {
        .init(outcome: outcome, transport: transport, nativeCleanupConfirmed: nativeCleanupConfirmed,
              nvmeMeasurements: nvmeMeasurements, diagnostic: diagnostic ?? self.diagnostic)
    }
}

/// One explicit selected-device request at a time. There is no startup scan,
/// poll, raw port exposure or automatic retry after uncertain native cleanup.
public actor DriveHealthSession {
    /// Presentation only; the actual Check validates signatures, inheritance,
    /// the helper manifest and the selected physical device before reading.
    public static var isReaderComposed: Bool {
        DriveHealthServiceIdentity.compositionRequested
            ? DriveHealthServiceIdentity.compositionDeclared : DriveHealthHelperIdentity.compositionDeclared
    }
    private let lifecycle: VolumeLifecycle
    private var active: Task<DriveHealthReport, Never>?
    private var control: DriveHealthChildControl?
    private var serviceControl: DriveHealthServiceControl?
    private var activeID: UUID?
    private var publicationID = UUID()
    private var lastDrain = DriveHealthDrain(transport: .notStarted, nativeCleanupConfirmed: true)
    private var fenced = false

    public init(lifecycle: VolumeLifecycle = .shared) { self.lifecycle = lifecycle }
    public var isDraining: Bool { active != nil }
    public var hasUncertainNativeState: Bool { fenced }

    public func check(_ selected: ManagedVolume) async -> DriveHealthReport {
        guard !fenced else { return .init(outcome: .unavailable(.uncertain), transport: lastDrain.transport,
            nativeCleanupConfirmed: lastDrain.nativeCleanupConfirmed, diagnostic: .init(stage: .sessionAdmission)) }
        guard active == nil else { return .init(outcome: .unavailable(.busy), transport: .notStarted,
            nativeCleanupConfirmed: true, diagnostic: .init(stage: .sessionAdmission)) }
        let id = UUID(), publication = UUID()
        // An invalid requested service never falls back to a broader or older
        // process composition. Its own identity preparation will refuse it.
        let service = DriveHealthServiceIdentity.compositionRequested ? DriveHealthServiceControl() : nil
        let child = service == nil ? DriveHealthChildControl() : nil
        publicationID = publication
        control = child
        serviceControl = service
        activeID = id
        let lifecycle = self.lifecycle
        let job = Task.detached(priority: .utility) {
            await Self.perform(selected, lifecycle: lifecycle, control: child, serviceControl: service)
        }
        active = job
        let report = await job.value
        finish(id: id, report: report)
        if !report.nativeCleanupConfirmed || !report.transportSettled { return report.replacingOutcome(.unavailable(.uncertain)) }
        if publicationID != publication { return report.replacingOutcome(.unavailable(.stale)) }
        return report
    }

    /// Selection/close invalidation never releases or interrupts native state.
    public func invalidate() { publicationID = UUID() }

    /// Child Stop signals only that owned process. Service Stop invalidates
    /// publication and awaits the current native call; it cannot prove cleanup
    /// by cancelling a connection. Lost completion fences either composition.
    public func stop() {
        invalidate()
        control?.requestStop()
        serviceControl?.requestStop()
    }

    public func drain() async -> DriveHealthDrain {
        guard let active, let id = activeID else { return lastDrain }
        let report = await active.value
        finish(id: id, report: report)
        return report.drain
    }

    private func finish(id: UUID, report: DriveHealthReport) {
        guard activeID == id else { return }
        active = nil
        control = nil
        serviceControl = nil
        activeID = nil
        lastDrain = report.drain
        if !report.nativeCleanupConfirmed || !report.transportSettled { fenced = true }
    }

    private static func perform(_ selected: ManagedVolume, lifecycle: VolumeLifecycle,
                                control: DriveHealthChildControl?, serviceControl: DriveHealthServiceControl?) async -> DriveHealthReport {
        let prepared: PreparedDriveHealthSelection
        do { prepared = try await lifecycle.prepareHealthSelection(selected) }
        catch {
            let reason: DriveHealthUnavailable
            switch error {
            case VolumeLifecycleFailure.busy: reason = .busy
            case VolumeLifecycleFailure.changed: reason = .stale
            case VolumeLifecycleFailure.denied: reason = .denied
            case VolumeLifecycleFailure.unsupported: reason = .unsupported
            default: reason = .unavailable
            }
            return .init(outcome: .unavailable(reason), transport: .notStarted, nativeCleanupConfirmed: true,
                diagnostic: .init(stage: .selection))
        }
        if control?.stopRequested == true || serviceControl?.stopRequested == true {
            return .init(outcome: .unavailable(.stale), transport: .notStarted, nativeCleanupConfirmed: true,
                diagnostic: .init(stage: .selection))
        }
        let report: DriveHealthReport
        if let serviceControl {
            report = await DriveHealthXPCClient.run(prepared, control: serviceControl)
        } else if let control {
            report = await withCheckedContinuation { continuation in
                let worker = DispatchQueue(label: "local.traverse.drive-health-one-shot", qos: .utility)
                worker.async {
                    continuation.resume(returning: DriveHealthChildProcess.run(prepared, control: control))
                }
            }
        } else {
            return .init(outcome: .unavailable(.unsupported), transport: .notStarted, nativeCleanupConfirmed: true,
                diagnostic: .init(stage: .helperAdmission, admissionFailure: .policy))
        }
        guard report.nativeCleanupConfirmed, report.transportSettled, case .warning = report.outcome else { return report }
        guard await lifecycle.revalidateHealthSelection(prepared) else {
            return report.replacingOutcome(.unavailable(.stale), diagnostic: .init(stage: .revalidation,
                    childStarted: report.diagnostic?.childStarted ?? false,
                    requestSent: report.diagnostic?.requestSent ?? false, native: report.diagnostic?.native))
        }
        return report
    }
}

internal enum DriveHealthWire {
    static func request(_ selected: PreparedDriveHealthSelection, nonce: [UInt8]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes.replaceSubrange(0..<4, with: [84, 72, 82, 50]) // THR2
        bytes[4] = 2
        bytes.replaceSubrange(8..<24, with: nonce)
        for (offset, value) in [(24, selected.selectedMedia), (32, selected.outerWhole),
                                (40, selected.blockBoundary), (48, selected.generation)] {
            for index in 0..<8 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
        return Data(bytes)
    }
    static func decode(_ data: Data, nonce: [UInt8],
                       transport: DriveHealthTransportCompletion = .ownedChild(reaped: true)) -> DriveHealthReport? {
        let bytes = [UInt8](data)
        guard bytes.count == 256, Array(bytes[0..<4]) == [84, 72, 83, 50], bytes[4] == 2,
              bytes[5..<8].allSatisfy({ $0 == 0 }), Array(bytes[8..<24]) == nonce,
              bytes[74..<80].allSatisfy({ $0 == 0 }), bytes[240..<256].allSatisfy({ $0 == 0 }),
              bytes[44] <= 1, bytes[47] <= 1, bytes[68] <= 1 else { return nil }
        func number(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        func wide(_ offset: Int) -> UInt64 {
            (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
        }
        let status = number(24), stage = number(28), domain = number(32)
        let code = Int32(bitPattern: number(36)), destroy = Int32(bitPattern: number(40))
        let cleanup = bytes[47] == 1
        let childStarted: Bool
        if case .ownedChild = transport { childStarted = true } else { childStarted = false }
        let diagnostic = DriveHealthDiagnostic(stage: .native, childStarted: childStarted, requestSent: true,
            native: .init(status: status, stage: stage, domain: domain, code: code, destroyCode: destroy))
        let hasMeasurements = bytes[68] == 1
        guard !hasMeasurements || (status == UInt32(THNativeSample) && bytes[46] == DriveHealthKind.nvme.rawValue
            && bytes[44] == 1 && cleanup) else { return nil }
        guard hasMeasurements || (bytes[69..<74].allSatisfy({ $0 == 0 }) && bytes[80..<240].allSatisfy({ $0 == 0 })) else { return nil }
        guard status <= UInt32(THNativeUncertain) else { return nil }
        if !cleanup || status == UInt32(THNativeUncertain) {
            return .init(outcome: .unavailable(.uncertain), transport: transport, nativeCleanupConfirmed: false,
                diagnostic: diagnostic)
        }
        if status == UInt32(THNativeSample) {
            guard bytes[44] == 1, let kind = DriveHealthKind(rawValue: bytes[46]),
                  hasMeasurements == (kind == .nvme),
                  kind == .nvme || bytes[45] <= 1,
                  stage == UInt32(THStageComplete), domain == UInt32(THDomainNone),
                  code == 0, destroy == 0, wide(48) != 0,
                  wide(56) > 0, number(64) < 1_000_000_000 else { return nil }
            let date = Date(timeIntervalSince1970: TimeInterval(wide(56)) + TimeInterval(number(64)) / 1_000_000_000)
            let measurements: NVMeHealthMeasurements?
            if hasMeasurements {
                let counters = (0..<10).map { field in
                    (0..<16).reduce(UInt128(0)) { $0 | UInt128(bytes[80 + field * 16 + $1]) << (8 * $1) }
                }
                measurements = NVMeHealthMeasurements(temperatureKelvin: UInt16(bytes[69]) | UInt16(bytes[70]) << 8,
                    availableSpare: bytes[71], spareThreshold: bytes[72], percentageUsed: bytes[73], counters: counters)
            } else { measurements = nil }
            let outcome: DriveHealthOutcome = transport.transportSettled
                ? .warning(kind: kind, rawByte: bytes[45], capturedAt: date) : .unavailable(.uncertain)
            return .init(outcome: outcome,
                transport: transport, nativeCleanupConfirmed: true, nvmeMeasurements: measurements, diagnostic: diagnostic)
        }
        let reason: DriveHealthUnavailable
        switch status {
        case UInt32(THNativeUnsupported): reason = .unsupported
        case UInt32(THNativeChanged): reason = .stale
        case UInt32(THNativeReadFailure): reason = nativeFailure(domain: domain, code: code)
        default: reason = .unavailable
        }
        return .init(outcome: .unavailable(reason), transport: transport, nativeCleanupConfirmed: true, diagnostic: diagnostic)
    }
    private static func nativeFailure(domain: UInt32, code: Int32) -> DriveHealthUnavailable {
        if domain == UInt32(THDomainHRESULT) {
            return code == th_smart_no_interface_hresult() ? .unsupported : .unavailable
        }
        guard domain == UInt32(THDomainKernel) || domain == UInt32(THDomainIOReturn) else { return .unavailable }
        switch code {
        case kIOReturnNotPrivileged, kIOReturnNotPermitted: return .denied
        case kIOReturnBusy, kIOReturnExclusiveAccess: return .busy
        case kIOReturnNoDevice, kIOReturnOffline, kIOReturnNotAttached: return .disconnected
        case kIOReturnUnsupported: return .unsupported
        default: return .unavailable
        }
    }
}
