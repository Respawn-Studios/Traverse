import Darwin
import ExplorerCore
import Foundation

/// A verified, interval-observed pair. Topology never grants descendant access.
/// Backing System is not mounted: its active / view is the scan source.
public struct StartupStoragePlan: Sendable, CustomStringConvertible {
    public var dataRoot: URL { data.url }
    public var systemRoot: URL { system.url }
    public var snapshotBased: Bool { facts.active.snapshot != nil }
    public var containerCapacity: UInt64? { facts.containerCapacity }
    public var containerAvailable: UInt64? { facts.containerFree }
    public var isTopologyUnchanged: Bool { !watch.isChanged }
    public var description: String { "Verified startup System/Data interval observation" }
    let facts: StartupFacts
    let data, system: StartupNativeRoot
    let watch: StartupTopologyWatch.Registration
    var isChanged: Bool { watch.isChanged }
    func revalidateNative() throws {
        guard !watch.isChanged else { throw StartupStorageFailure.changed }
        try data.revalidate(info: facts.data); try system.revalidate(info: facts.active)
        guard !watch.isChanged else { throw StartupStorageFailure.changed }
    }
}

/// One small Apple-tool adapter, confined to a utility queue. No shell, mount,
/// unlock, private API, raw-device read, stored plist or guessed partner path.
public final class StartupVolumeDiscovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacExplorer.StartupDiscovery", qos: .utility)
    private let gate: FileActivityGate
    private let lock = NSLock()
    private var occupied = false
    private var currentControl: ScannerProcessControl?
    public init(activityGate: FileActivityGate) { gate = activityGate }

    public func discover() async throws -> StartupStoragePlan {
        try await perform { control in try Self.discover(control: control) }
    }
    public func revalidate(_ plan: StartupStoragePlan) async throws {
        _ = try await perform { control -> Bool in
            try Self.validate(plan, control: control); return true
        }
    }
    public func cancelCurrentInquiry() { lock.withLock { currentControl }?.cancel() }

    /// Called only by the scanner's synchronous utility pump while its child
    /// waits at a finite control pipe. No main-actor wait or nested process PID
    /// reuse: discovery owns/drains its own tool control separately.
    func revalidateDuringScan(_ plan: StartupStoragePlan, scanner: ScannerProcessControl) throws {
        let control = ScannerProcessControl()
        try lock.withLock {
            guard !occupied else { throw StartupStorageFailure.busy }; occupied = true; currentControl = control
        }
        defer { lock.withLock { occupied = false; currentControl = nil }; control.finished() }
        try queue.sync {
            let activity = try gate.begin(); defer { withExtendedLifetime(activity) {} }
            guard !scanner.cancelled else { throw CancellationError() }
            try Self.validate(plan, control: control)
            guard !scanner.cancelled else { throw CancellationError() }
        }
    }
    private static func validate(_ plan: StartupStoragePlan, control: ScannerProcessControl) throws {
        try plan.revalidateNative()
        let root = try StartupFactDecoder.info(inquiry(["info", "-plist", "/"], control: control))
        let group = try StartupFactDecoder.group(inquiry(["apfs", "listVolumeGroups", "-plist"], control: control), root: root)
        guard root == plan.facts.active, group == plan.facts.membership else { throw StartupStorageFailure.changed }
        try plan.revalidateNative()
    }
    private func perform<T: Sendable>(_ body: @escaping @Sendable (ScannerProcessControl) throws -> T) async throws -> T {
        guard lock.withLock({ if occupied { return false }; occupied = true; return true }) else { throw StartupStorageFailure.busy }
        let control = ScannerProcessControl()
        lock.withLock { currentControl = control }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    let result: Result<T, Error>
                    do {
                        let activity = try gate.begin(); defer { withExtendedLifetime(activity) {} }
                        guard !control.cancelled else { throw CancellationError() }
                        let value = try body(control)
                        guard !control.cancelled else { throw CancellationError() }
                        result = .success(value)
                    } catch { result = .failure(error) }
                    lock.withLock { occupied = false; currentControl = nil }; control.finished()
                    continuation.resume(with: result)
                }
            }
        } onCancel: { control.cancel() }
    }

    private static func inquiry(_ arguments: [String], control: ScannerProcessControl) throws -> [String: Any] {
        guard !control.cancelled else { throw CancellationError() }
        let allowed: Bool
        if arguments == ["info", "-plist", "/"] || arguments == ["apfs", "listVolumeGroups", "-plist"] { allowed = true }
        else if arguments.count == 3 && arguments.prefix(2) == ["info", "-plist"] { allowed = StartupFactDecoder.validDevice(arguments[2]) }
        else if arguments.count == 4 && arguments.prefix(3) == ["apfs", "list", "-plist"] { allowed = StartupFactDecoder.validContainer(arguments[3]) }
        else { allowed = false }
        guard allowed else { throw StartupStorageFailure.invalidFacts }
        let pipes = try ScannerWorkerProcess.launch(workerURL: URL(fileURLWithPath: "/usr/sbin/diskutil"),
            descriptors: [], arguments: arguments, control: control)
        let data = try ScannerWorkerProcess.collect(pipes: pipes, control: control)
        return try BoundedStartupPlist.decode(data)
    }
    private static func discover(control: ScannerProcessControl) throws -> StartupStoragePlan {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else { throw StartupStorageFailure.unsupportedSchema }
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        defer { if previous >= 0 { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) } }
        guard previous >= 0, setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else { throw StartupStorageFailure.unavailable }
        let watch = try StartupTopologyWatch.shared.register()
        watch.whenInvalidated { control.cancel() }
        defer { watch.whenInvalidated(nil) }
        let root = try StartupFactDecoder.info(inquiry(["info", "-plist", "/"], control: control))
        let group = try StartupFactDecoder.group(inquiry(["apfs", "listVolumeGroups", "-plist"], control: control), root: root)
        try watch.target([root.device, group.system.device, group.data.device, group.containerReference])
        let container = try inquiry(["apfs", "list", "-plist", group.containerReference], control: control)
        let system = try StartupFactDecoder.info(inquiry(["info", "-plist", group.system.device], control: control))
        let data = try StartupFactDecoder.info(inquiry(["info", "-plist", group.data.device], control: control))
        let facts = try StartupFactDecoder.assemble(root: root, group: group, container: container, system: system, data: data)
        guard let dataMount = data.mount else { throw StartupStorageFailure.unavailable }
        let dataRoot = try StartupNativeRoot(url: URL(fileURLWithPath: dataMount, isDirectory: true), info: data)
        let systemRoot = try StartupNativeRoot(url: URL(fileURLWithPath: "/", isDirectory: true), info: root)
        guard (dataRoot.identity.realDevice != systemRoot.identity.realDevice
            || dataRoot.identity.realFSID0 != systemRoot.identity.realFSID0
            || dataRoot.identity.realFSID1 != systemRoot.identity.realFSID1), dataRoot.identity.volume != systemRoot.identity.volume else { throw StartupStorageFailure.invalidFacts }
        let again = try StartupFactDecoder.info(inquiry(["info", "-plist", "/"], control: control))
        let againGroup = try StartupFactDecoder.group(inquiry(["apfs", "listVolumeGroups", "-plist"], control: control), root: again)
        guard root == again, group == againGroup, !watch.isChanged else { throw StartupStorageFailure.changed }
        let plan = StartupStoragePlan(facts: facts, data: dataRoot, system: systemRoot, watch: watch)
        try plan.revalidateNative(); return plan
    }
}
