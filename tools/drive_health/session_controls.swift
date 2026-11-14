import Dispatch
import Foundation
import THSMART
import THSMARTFake

private final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var released = 0
    private var requests: [UInt64] = []
    func acquired(_ target: DeviceHealthTarget) {
        precondition(!Thread.isMainThread)
        lock.withLock { active += 1; peak = max(peak, active); requests.append(target.provider) }
    }
    func release() {
        precondition(!Thread.isMainThread)
        lock.withLock { precondition(active == 1); active -= 1; released += 1 }
    }
    var snapshot: (active: Int, peak: Int, released: Int, requests: [UInt64]) {
        lock.withLock { (active, peak, released, requests) }
    }
}

private final class ReleaseGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    func wait() { lock.withLock { entered = true }; semaphore.wait() }
    func open() { semaphore.signal() }
    var blocked: Bool { lock.withLock { entered } }
}

private final class FakeOwner: @unchecked Sendable {
    let pointer: OpaquePointer
    let target: DeviceHealthTarget
    private let lock = NSLock()
    private let counts: Counts
    private let releaseGate: ReleaseGate?
    private var current = true
    private var freed = false

    init(target: DeviceHealthTarget, configuration: THSMARTFakeConfiguration,
         counts: Counts, initiallyCurrent: Bool, releaseGate: ReleaseGate?) {
        pointer = th_fake_new(configuration)!
        self.target = target; self.counts = counts; self.current = initiallyCurrent
        self.releaseGate = releaseGate
    }
    var nativeCounts: THSMARTFakeCounters { th_fake_counters(pointer) }
    func invalidate() { lock.withLock { current = false } }
    func open() { th_fake_open_gate(pointer) }
    func lease() -> DeviceHealthReadLease {
        DeviceHealthReadLease(target: target, isCurrent: { [self] in lock.withLock { current } },
            read: { [self] in
                precondition(!Thread.isMainThread)
                return DeviceHealthNativeResult(th_fake_read(pointer), expected: target.kind)
            }, release: { [self] in
                if let releaseGate { releaseGate.wait() }
                counts.release()
            })
    }
    func dispose(restoringMalformedTestReference: Bool = false) {
        lock.withLock { precondition(!freed); freed = true }
        if restoringMalformedTestReference { th_fake_restore_missing_release(pointer) }
        th_fake_free(pointer)
    }
}

private final class Backend: @unchecked Sendable {
    let counts = Counts()
    private let lock = NSLock()
    private var owners: [UInt64: FakeOwner] = [:]
    private let configurations: [UInt64: THSMARTFakeConfiguration]
    private let initiallyCurrent: Bool
    private let releaseGate: ReleaseGate?
    private let wrongAssociation: Bool

    init(configurations: [UInt64: THSMARTFakeConfiguration], initiallyCurrent: Bool = true,
         releaseGate: ReleaseGate? = nil, wrongAssociation: Bool = false) {
        self.configurations = configurations; self.initiallyCurrent = initiallyCurrent
        self.releaseGate = releaseGate; self.wrongAssociation = wrongAssociation
    }
    func acquire(_ requested: DeviceHealthTarget) -> Result<DeviceHealthReadLease, DeviceHealthFailure> {
        guard let configuration = configurations[requested.provider] else {
            return .failure(DeviceHealthFailure(stage: UInt32(THStageCreate), domain: UInt32(THDomainIOReturn),
                code: kIOReturnUnsupported, cleanupCode: 0))
        }
        let target = wrongAssociation
            ? DeviceHealthTarget(physicalMedia: requested.physicalMedia, provider: requested.provider + 1,
                attachment: requested.attachment, kind: requested.kind)! : requested
        counts.acquired(target)
        let owner = FakeOwner(target: target, configuration: configuration, counts: counts,
                              initiallyCurrent: initiallyCurrent, releaseGate: releaseGate)
        lock.withLock { precondition(owners[requested.provider] == nil); owners[requested.provider] = owner }
        return .success(owner.lease())
    }
    func owner(_ id: UInt64) -> FakeOwner? { lock.withLock { owners[id] } }
}

@MainActor
private final class Events {
    var observations: [(DeviceHealthTarget, DeviceHealthReadValue)] = []
    var uncertain = 0
    func receive(_ event: DeviceHealthSessionEvent) {
        switch event {
        case .observation(let target, let value): observations.append((target, value))
        case .ownershipUncertain: uncertain += 1
        }
    }
}

@MainActor
private func eventually(_ test: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while !test() {
        precondition(ContinuousClock.now < deadline, "Generated health completion deadline")
        try! await Task.sleep(for: .milliseconds(2))
    }
}
private func config(kind: DeviceHealthKind = .nvme, warning: UInt8 = 0, block: UInt8 = 0) -> THSMARTFakeConfiguration {
    var result = THSMARTFakeConfiguration()
    result.kind = kind.rawValue; result.warning = warning; result.block_stage = block
    return result
}
private func target(_ provider: UInt64, kind: DeviceHealthKind = .nvme) -> DeviceHealthTarget {
    DeviceHealthTarget(physicalMedia: provider + 10_000, provider: provider, attachment: 1, kind: kind)!
}
private func success(kind: DeviceHealthKind = .nvme, warning: UInt8 = 0) -> THSMARTResult {
    var result = THSMARTResult()
    result.provider_kind = kind.rawValue; result.stage = UInt32(THStageComplete)
    result.warning_valid = 1; result.warning_byte = warning
    return result
}

@main
private struct HealthControls {
    @MainActor static func main() async {
        var checks = 0
        for count in [0, 1, 511, 513] { precondition(DeviceHealthWarning.decodeNVMe(Data(repeating: 0, count: count)) == nil); checks += 1 }
        for warning in UInt16(0)...255 {
            var bytes = Data(repeating: 0x6d, count: 512); bytes[0] = UInt8(warning); bytes[1] = 0xff
            let decoded = DeviceHealthWarning.decodeNVMe(bytes)!
            precondition(decoded.raw == warning && decoded.unknownNVMeBits == UInt8(warning) & 0xc0)
            precondition(decoded.warningReported == (warning != 0))
            precondition(DeviceHealthReadValue(native: success(warning: UInt8(warning)), expected: .nvme) == .warning(decoded))
            checks += 1
        }
        for warning: UInt8 in [0, 1] {
            precondition(DeviceHealthReadValue(native: success(kind: .ata, warning: warning), expected: .ata)
                == .warning(DeviceHealthWarning(kind: .ata, raw: warning))); checks += 1
        }
        for bad in [DeviceHealthReadValue(native: success(kind: .ata, warning: 2), expected: .ata),
                    DeviceHealthReadValue(native: success(), expected: .ata)] {
            if case .failure(let value) = bad { precondition(value.category == .invalidContract) }
            else { preconditionFailure("Malformed native success became a sample") }
            checks += 1
        }
        let codes: [(Int32, DeviceHealthFailure.Category)] = [
            (kIOReturnNotPrivileged, .denied), (kIOReturnNotPermitted, .denied),
            (kIOReturnBusy, .busy), (kIOReturnExclusiveAccess, .busy),
            (kIOReturnNoDevice, .disconnected), (kIOReturnOffline, .disconnected),
            (kIOReturnNotAttached, .disconnected), (kIOReturnUnsupported, .unsupported),
            (kIOReturnTimeout, .unavailable), (kIOReturnBadArgument, .unavailable),
            (Int32(bitPattern: 0xe0abcdef), .unavailable)]
        for (code, category) in codes {
            var raw = success(warning: 0xff); raw.warning_valid = 0
            raw.stage = UInt32(THStageRead); raw.code_domain = UInt32(THDomainIOReturn)
            raw.primary_code = code; raw.destroy_code = kIOReturnError
            if case .failure(let value) = DeviceHealthReadValue(native: raw, expected: .nvme) {
                precondition(value.category == category && value.code == code && value.cleanupCode == kIOReturnError)
            } else { preconditionFailure("Failed native read produced a warning sample") }
            checks += 1
        }
        precondition(DeviceHealthFailure(stage: 3, domain: UInt32(THDomainHRESULT), code: th_smart_no_interface_hresult(), cleanupCode: 0).category == .unsupported)
        precondition(DeviceHealthFailure(stage: 3, domain: UInt32(THDomainHRESULT), code: 1, cleanupCode: 0).category == .invalidContract)
        precondition(DeviceHealthTarget(physicalMedia: 0, provider: 1, attachment: 1, kind: .nvme) == nil)
        precondition(DeviceHealthTarget(physicalMedia: 1, provider: 0, attachment: 1, kind: .nvme) == nil)
        precondition(DeviceHealthTarget(physicalMedia: 1, provider: 1, attachment: 0, kind: .nvme) == nil)
        checks += 5

        // Every actual C acquisition/read/cleanup stage blocks on the dedicated
        // queue while the main actor keeps running. Only the latest target runs.
        var heartbeatChecks = 0
        for stage: UInt8 in 1...7 {
            let a = target(100 + UInt64(stage)), b = target(200 + UInt64(stage))
            let backend = Backend(configurations: [a.provider: config(warning: 0x80, block: stage), b.provider: config(warning: 1)])
            let events = Events()
            let session = DeviceHealthReadSession(acquire: { backend.acquire($0) }, onEvent: { events.receive($0) })
            session.select(a)
            await eventually { backend.owner(a.provider)?.nativeCounts.entered_block == 1 }
            precondition(session.isDraining && backend.counts.snapshot.active == 1 && events.observations.isEmpty)
            for i in 0..<100 { session.select(target(9000 + UInt64(i))); precondition(session.pendingCount == 1) }
            session.cancel(); precondition(session.pendingCount == 0 && session.isDraining)
            session.select(b)
            for _ in 0..<5 { try! await Task.sleep(for: .milliseconds(1)); heartbeatChecks += 1 }
            precondition(backend.counts.snapshot.requests == [a.provider] && backend.owner(b.provider) == nil
                         && backend.owner(a.provider)!.nativeCounts.returned == 0 && session.pendingCount == 1)
            backend.owner(a.provider)!.open()
            await eventually { !session.isDraining }
            precondition(backend.counts.snapshot.active == 0 && backend.counts.snapshot.peak == 1
                         && backend.counts.snapshot.released == 2 && backend.counts.snapshot.requests == [a.provider, b.provider])
            precondition(events.observations.count == 1 && events.observations[0].0 == b && events.uncertain == 0)
            backend.owner(a.provider)!.dispose(); backend.owner(b.provider)!.dispose(); checks += 1
        }
        // A post-read changed attachment suppresses publication; no path/number
        // matching can replace the captured association.
        do {
            let a = target(301), backend = Backend(configurations: [301: config(block: 3)]), events = Events()
            let session = DeviceHealthReadSession(acquire: { backend.acquire($0) }, onEvent: { events.receive($0) })
            session.select(a); await eventually { backend.owner(301)?.nativeCounts.entered_block == 1 }
            backend.owner(301)!.invalidate(); backend.owner(301)!.open()
            await eventually { !session.isDraining }
            precondition(events.observations.isEmpty && backend.counts.snapshot.released == 1)
            backend.owner(301)!.dispose(); checks += 1
        }
        for wrong in [false, true] {
            let a = target(401), backend = Backend(configurations: [401: config()], initiallyCurrent: wrong, wrongAssociation: wrong)
            let events = Events(), session = DeviceHealthReadSession(acquire: { backend.acquire($0) }, onEvent: { events.receive($0) })
            session.select(a); await eventually { !session.isDraining }
            precondition(events.observations.isEmpty && backend.owner(401)!.nativeCounts.create == 0
                         && backend.counts.snapshot.released == 1)
            backend.owner(401)!.dispose(); checks += 1
        }
        // Provider release can block after all COM cleanup. It still holds the
        // reader/removal lease and cannot be replaced with a timeout completion.
        do {
            let a = target(501), gate = ReleaseGate(), backend = Backend(configurations: [501: config()], releaseGate: gate)
            let events = Events(), session = DeviceHealthReadSession(acquire: { backend.acquire($0) }, onEvent: { events.receive($0) })
            session.select(a); await eventually { gate.blocked }
            precondition(session.isDraining && backend.owner(501)!.nativeCounts.returned == 1
                         && backend.counts.snapshot.active == 1 && backend.counts.snapshot.released == 0)
            session.cancel(); gate.open(); await eventually { !session.isDraining }
            precondition(events.observations.isEmpty && backend.counts.snapshot.released == 1)
            backend.owner(501)!.dispose(); checks += 1
        }
        // Closing/dropping the UI owner does not destroy a live read.
        do {
            let a = target(601), backend = Backend(configurations: [601: config(block: 3)]), events = Events()
            var session: DeviceHealthReadSession? = DeviceHealthReadSession(acquire: { backend.acquire($0) }, onEvent: { events.receive($0) })
            weak let retained = session
            session!.select(a); await eventually { backend.owner(601)?.nativeCounts.entered_block == 1 }
            session!.cancel(); session = nil
            precondition(retained != nil && backend.counts.snapshot.active == 1)
            backend.owner(601)!.open(); await eventually { retained == nil }
            precondition(events.observations.isEmpty && backend.counts.snapshot.released == 1)
            backend.owner(601)!.dispose(); checks += 1
        }
        do {
            let events = Events(), backend = Backend(configurations: [:])
            let session = DeviceHealthReadSession(acquire: { backend.acquire($0) }, onEvent: { events.receive($0) })
            session.select(target(701)); await eventually { !session.isDraining }
            precondition(events.observations.count == 1 && backend.counts.snapshot.active == 0)
            if case .failure(let value) = events.observations[0].1 { precondition(value.category == .unsupported) }
            else { preconditionFailure("Failed lease acquisition became a sample") }
            checks += 1
        }
        // A deliberately malformed COM contract cannot claim drain. The test
        // restores only its generated fake to dispose that fake before exit;
        // the session still truthfully retains the unresolved lease.
        do {
            var malformed = config(); malformed.missing_release = 1
            let backend = Backend(configurations: [801: malformed, 802: config()]), events = Events()
            let session = DeviceHealthReadSession(acquire: { backend.acquire($0) }, onEvent: { events.receive($0) })
            session.select(target(801)); await eventually { session.hasUnresolvedOwnership }
            session.cancel(); session.select(target(802))
            for _ in 0..<5 { try! await Task.sleep(for: .milliseconds(1)) }
            precondition(session.isDraining && session.pendingCount == 1 && events.uncertain == 1
                         && events.observations.isEmpty && backend.counts.snapshot.active == 1
                         && backend.counts.snapshot.released == 0 && backend.owner(802) == nil)
            backend.owner(801)!.dispose(restoringMalformedTestReference: true); checks += 1
        }
        let report: [String: Any] = ["passed": true, "checks": checks, "heldNativeStages": 7,
            "mainActorHeartbeatChecks": heartbeatChecks, "maximumActualReaders": 1,
            "stalePublications": 0, "malformedCOMOwnershipTruthfullyRetained": true,
            "realDeviceOpens": 0, "hardwareQualified": false]
        let output = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: output, as: UTF8.self))
    }
}
