import CoreFoundation
import Foundation

public enum APFSVolumeCreationFailure: Error, Equatable, Sendable {
    case unavailable, unsupported, busy, changed, invalidName, nameConflict, insufficientSpace, denied, cancelled, notCreated, uncertain
    public var userMessage: String {
        switch self {
        case .unavailable: "Volume creation is unavailable here. Use Disk Utility to review this container."
        case .unsupported: "Choose an ordinary, writable APFS volume on an external drive or disk image. Startup, encrypted and special-purpose containers are not supported here."
        case .busy: "Another volume creation check is still finishing."
        case .changed: "The selected volume or its container changed. Refresh and review the new state before continuing."
        case .invalidName: "Enter a name of up to 255 UTF-8 bytes without slashes, colons or control characters, and without a leading hyphen."
        case .nameConflict: "This container already has a volume with that name. Choose a different name."
        case .insufficientSpace: "This container has less than 64 MiB of observed free space. Free space in Disk Utility before adding a volume."
        case .denied: "macOS did not permit volume creation. Review the selected container in Disk Utility."
        case .cancelled: "The check was cancelled before requesting volume creation."
        case .notCreated: "macOS could not create the volume. The checked container still has its original volumes and no new volume. Review it in Disk Utility before trying again."
        case .uncertain: "A creation request was submitted, but its final state could not be confirmed. Refresh or inspect the container in Disk Utility before trying again."
        }
    }
}

/// An opaque review bound to one native attachment and exact APFS membership.
/// It authorizes no operation by itself; perform reobserves the attachment.
public struct APFSVolumeCreationPlan: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let selected: ManagedVolume
    public let name: String
    public let caseSensitive: Bool
    public let observedFreeBytes: UInt64
    public let containerCapacity: UInt64
    public let existingVolumeNames: [String]
    public let capturedAt: Date
    let expiresAt: TimeInterval
    public var description: String { "APFS volume creation review" }
    public var debugDescription: String { description }
    let container: APFSContainerObservation
    init(selected: ManagedVolume, name: String, caseSensitive: Bool, container: APFSContainerObservation) {
        self.selected = selected; self.name = name; self.caseSensitive = caseSensitive; self.container = container
        observedFreeBytes = container.free; containerCapacity = container.capacity
        existingVolumeNames = container.volumes.map(\.name); capturedAt = Date()
        expiresAt = ProcessInfo.processInfo.systemUptime + 120
    }
}

public struct APFSVolumeCreationResult: Sendable {
    public enum FailureStage: String, Sendable {
        case revalidation, submission, creation, reconciliation
        public var userMessage: String {
            switch self {
            case .revalidation: "Rechecking the selected container"
            case .submission: "Submitting the creation request"
            case .creation: "Creating the volume"
            case .reconciliation: "Checking the final container state"
            }
        }
    }
    /// Fixed classifications of recognized tool text, never an inferred cause
    /// from an exit status. Unknown text and user-provided strings are omitted.
    public enum DiagnosticCategory: String, Sendable {
        case commandUsage, authorizationReported, permissionReported, volumeLimitReported
        public var userMessage: String {
            switch self {
            case .commandUsage: "macOS displayed command usage information."
            case .authorizationReported: "macOS reported that authorization is required."
            case .permissionReported: "macOS reported a permission restriction."
            case .volumeLimitReported: "macOS reported that this APFS container has reached its volume limit."
            }
        }
    }
    public struct CreatedVolume: Sendable {
        public let id: UUID
        public let name: String
        public let mountPoint: URL?
    }
    public let submitted: Bool
    public let created: CreatedVolume?
    public let failure: APFSVolumeCreationFailure?
    public let toolExitStatus: Int32?
    public let diskutilErrorCode: Int?
    public let failureStage: FailureStage?
    public let diagnosticCategory: DiagnosticCategory?
    init(submitted: Bool, created: CreatedVolume?, failure: APFSVolumeCreationFailure?, toolExitStatus: Int32? = nil,
         diskutilErrorCode: Int? = nil, failureStage: FailureStage? = nil, diagnosticCategory: DiagnosticCategory? = nil) {
        self.submitted = submitted; self.created = created; self.failure = failure
        self.toolExitStatus = toolExitStatus; self.diskutilErrorCode = diskutilErrorCode
        self.failureStage = failureStage; self.diagnosticCategory = diagnosticCategory
    }
}

/// One typed add-volume owner. No erase, partition, encryption, role, group,
/// privilege prompt or user-supplied device argument exists at this boundary.
/// Before submission cancellation stops only owned read-only inquiries. After
/// submission the actual child and reconciliation drain; cancellation is never
/// described as rollback. Caller owns the app's exclusive device/activity gate.
public final class APFSVolumeCreation: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied = false
    private let inspector: any VolumeInspecting
    private let tool: APFSVolumeTool
    public init() { inspector = VolumeLifecycle.shared; tool = APFSVolumeTool() }
    /// Internal qualification injection; production construction has no raw
    /// terminal observer and retains the same lifecycle/authority checks.
    init(tool: APFSVolumeTool) { inspector = VolumeLifecycle.shared; self.tool = tool }

    public static func validatedName(_ name: String) throws -> String {
        let name = name.precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              name != ".", name != "..", !name.hasPrefix("-"), name.utf8.count <= 255,
              !name.contains("/"), !name.contains(":"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw APFSVolumeCreationFailure.invalidName
        }
        return name
    }

    public func prepare(_ selected: ManagedVolume, name: String, caseSensitive: Bool = false) async throws -> APFSVolumeCreationPlan {
        try admit(); defer { release() }
        let name = try Self.validatedName(name)
        let cancellation = APFSVolumeTool.Cancellation()
        return try await withTaskCancellationHandler {
            let observation = try await observe(selected, cancellation: cancellation)
            try observation.validateNewName(name)
            try Task.checkCancellation()
            return .init(selected: selected, name: name, caseSensitive: caseSensitive, container: observation)
        } onCancel: { cancellation.cancel() }
    }

    /// Distribution policy is supplied by the application and checked again
    /// immediately before submission. False never launches a mutation child.
    public func perform(_ plan: APFSVolumeCreationPlan, permitted: @escaping @Sendable () -> Bool,
                        submitted: @escaping @Sendable () -> Void = {}) async -> APFSVolumeCreationResult {
        do { try admit() } catch { return .init(submitted: false, created: nil, failure: .busy) }
        defer { release() }
        let cancellation = APFSVolumeTool.Cancellation()
        var didSubmit = false
        var terminal: APFSVolumeTool.MutationReply?
        do {
            guard permitted() else { throw APFSVolumeCreationFailure.unavailable }
            let current = try await withTaskCancellationHandler {
                try await observe(plan.selected, cancellation: cancellation)
            } onCancel: { cancellation.cancel() }
            guard plan.container.sameIdentityAndMembers(as: current), ProcessInfo.processInfo.systemUptime < plan.expiresAt else {
                throw APFSVolumeCreationFailure.changed
            }
            try current.validateNewName(plan.name)
            try Task.checkCancellation()
            guard permitted(), !cancellation.isCancelled else { throw APFSVolumeCreationFailure.unavailable }
            // Only the fixed, freshly observed container reaches the tool. No
            // synchronous UI callback opens a device or constructs a command.
            let command = ["apfs", "addVolume", current.device, plan.caseSensitive ? "Case-sensitive APFS" : "APFS", plan.name]
            do { terminal = try await tool.mutate(command, submitted: submitted) }
            catch {
                // The tool only throws before Process.run succeeds; once
                // launched, all terminal statuses return after actual drain.
                return .init(submitted: false, created: nil, failure: (error as? APFSVolumeCreationFailure) ?? .unavailable,
                    failureStage: .submission)
            }
            didSubmit = true
            // Always attempt reconciliation after actual child drain, including
            // nonzero exit and caller cancellation. A failed tool is not proof
            // that no volume was created.
            let after = try APFSContainerObservation.decode(try await tool.inquire(["apfs", "list", "-plist", current.device]), selected: current.selectedUUID)
            if terminal?.status != 0, current.sameIdentityAndMembers(as: after) {
                return .init(submitted: true, created: nil, failure: .notCreated,
                    toolExitStatus: terminal?.status, diskutilErrorCode: terminal?.errorCode,
                    failureStage: .creation, diagnosticCategory: terminal?.diagnosticCategory)
            }
            guard current.preservesMembers(in: after),
                  let added = after.singleAddition(comparedWith: current, name: plan.name) else {
                throw APFSVolumeCreationFailure.uncertain
            }
            let info = try APFSVolumeObservation.decode(try await tool.inquire(["info", "-plist", added.device]))
            guard info.uuid == added.uuid, info.container == current.device,
                  info.name == plan.name, info.caseSensitive == plan.caseSensitive else { throw APFSVolumeCreationFailure.uncertain }
            return .init(submitted: true, created: .init(id: added.uuid, name: added.name, mountPoint: info.mount), failure: nil,
                toolExitStatus: terminal?.status, diskutilErrorCode: terminal?.errorCode)
        } catch {
            let failure: APFSVolumeCreationFailure = didSubmit ? .uncertain
                : error is CancellationError ? .cancelled : (error as? APFSVolumeCreationFailure) ?? .unavailable
            return .init(submitted: didSubmit, created: nil, failure: failure,
                toolExitStatus: terminal?.status, diskutilErrorCode: terminal?.errorCode,
                failureStage: didSubmit ? .reconciliation : .revalidation, diagnosticCategory: terminal?.diagnosticCategory)
        }
    }

    private func admit() throws { try lock.withLock { guard !occupied else { throw APFSVolumeCreationFailure.busy }; occupied = true } }
    private func release() { lock.withLock { occupied = false } }

    private func observe(_ selected: ManagedVolume, cancellation: APFSVolumeTool.Cancellation) async throws -> APFSContainerObservation {
        guard selected.deviceKind == .diskImage || selected.deviceKind == .externalDisk && selected.isInternal == false,
              let uuid = selected.volumeUUID, selected.mediaID != nil, selected.group != nil, selected.url != nil else {
            throw APFSVolumeCreationFailure.unsupported
        }
        let native = try await inspector.inspect(selected)
        guard native.volume == selected, native.fields.fileSystem?.lowercased() == "apfs", native.fields.writable == true,
              APFSContainerObservation.validDevice(native.deviceName) else { throw APFSVolumeCreationFailure.unsupported }
        let info = try APFSVolumeObservation.decode(try await tool.inquire(["info", "-plist", native.deviceName], cancellation: cancellation))
        guard info.uuid == uuid, info.device == native.deviceName, info.mount == selected.url?.standardizedFileURL,
              info.name == selected.name else { throw APFSVolumeCreationFailure.changed }
        let container = try APFSContainerObservation.decode(try await tool.inquire(["apfs", "list", "-plist", info.container], cancellation: cancellation), selected: uuid)
        guard container.device == info.container, container.volumes.contains(where: { $0.uuid == uuid && $0.device == info.device }),
              try await inspector.inspect(selected).volume == selected, !cancellation.isCancelled else { throw APFSVolumeCreationFailure.changed }
        return container
    }
}

struct APFSVolumeObservation: Sendable {
    let uuid: UUID
    let device, container, name: String
    let mount: URL?
    let caseSensitive: Bool
    static func decode(_ data: Data) throws -> Self {
        let d = try APFSContainerObservation.plist(data)
        guard let uuid = (d["VolumeUUID"] as? String).flatMap(UUID.init(uuidString:)),
              let device = d["DeviceIdentifier"] as? String, APFSContainerObservation.validDevice(device),
              let container = d["APFSContainerReference"] as? String, APFSContainerObservation.validContainer(container),
              let name = d["VolumeName"] as? String, d["FilesystemType"] as? String == "apfs",
              let personality = d["FilesystemName"] as? String, ["APFS", "Case-sensitive APFS"].contains(personality),
              APFSContainerObservation.boolean(d["Writable"]) == true,
              APFSContainerObservation.boolean(d["Internal"]) == false,
              APFSContainerObservation.boolean(d["Encryption"]) == false,
              APFSContainerObservation.boolean(d["FileVault"]) == false,
              APFSContainerObservation.boolean(d["Locked"]) == false,
              APFSContainerObservation.boolean(d["APFSSnapshot"]) != true,
              d["APFSVolumeGroupID"] == nil else { throw APFSVolumeCreationFailure.unsupported }
        let path = d["MountPoint"] as? String
        return .init(uuid: uuid, device: device, container: container, name: name,
            mount: path.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL : nil },
            caseSensitive: personality == "Case-sensitive APFS")
    }
}

struct APFSContainerObservation: Sendable {
    struct Store: Equatable, Sendable { let device: String; let uuid: UUID; let capacity: UInt64 }
    struct Volume: Equatable, Sendable { let device: String; let uuid: UUID; let name: String; let quota, reserve: UInt64 }
    let device: String
    let uuid, selectedUUID: UUID
    let capacity, free: UInt64
    let stores: [Store]
    let volumes: [Volume]
    static func validDevice(_ value: String) -> Bool { value.range(of: #"\Adisk[0-9]{1,6}(s[0-9]{1,6}){0,2}\z"#, options: .regularExpression) != nil }
    static func validContainer(_ value: String) -> Bool { value.range(of: #"\Adisk[0-9]{1,6}\z"#, options: .regularExpression) != nil }
    static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }; return value.boolValue
    }
    static func unsigned(_ value: Any?) -> UInt64? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(String(cString: value.objCType)),
              value.compare(0) != .orderedAscending, value.compare(NSNumber(value: Int64.max)) != .orderedDescending else { return nil }
        return value.uint64Value
    }
    static func plist(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= 2 << 20,
              let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw APFSVolumeCreationFailure.unavailable
        }; return value
    }
    static func decode(_ data: Data, selected: UUID) throws -> Self {
        let root = try plist(data)
        guard let containers = root["Containers"] as? [[String: Any]], containers.count == 1, let d = containers.first,
              let device = d["ContainerReference"] as? String, validContainer(device),
              let uuid = (d["APFSContainerUUID"] as? String).flatMap(UUID.init(uuidString:)),
              let capacity = unsigned(d["CapacityCeiling"]), capacity > 0,
              let free = unsigned(d["CapacityFree"]), free <= capacity,
              let rawStores = d["PhysicalStores"] as? [[String: Any]], rawStores.count == 1,
              let rawVolumes = d["Volumes"] as? [[String: Any]], !rawVolumes.isEmpty, rawVolumes.count < 128 else { throw APFSVolumeCreationFailure.unsupported }
        let stores = try rawStores.map { s -> Store in
            guard let device = s["DeviceIdentifier"] as? String, validDevice(device),
                  let uuid = (s["DiskUUID"] as? String).flatMap(UUID.init(uuidString:)),
                  let capacity = unsigned(s["Size"]), capacity > 0 else { throw APFSVolumeCreationFailure.unsupported }
            return .init(device: device, uuid: uuid, capacity: capacity)
        }
        let volumes = try rawVolumes.map { v -> Volume in
            guard let device = v["DeviceIdentifier"] as? String, validDevice(device),
                  let uuid = (v["APFSVolumeUUID"] as? String).flatMap(UUID.init(uuidString:)),
                  let name = v["Name"] as? String, (try? APFSVolumeCreation.validatedName(name)) == name,
                  let roles = v["Roles"] as? [String], roles.isEmpty,
                  boolean(v["Encryption"]) == false, boolean(v["FileVault"]) == false, boolean(v["Locked"]) == false,
                  boolean(v["CryptoMigrationOn"]) == false,
                  let quota = unsigned(v["CapacityQuota"]), let reserve = unsigned(v["CapacityReserve"]) else { throw APFSVolumeCreationFailure.unsupported }
            return .init(device: device, uuid: uuid, name: name, quota: quota, reserve: reserve)
        }.sorted { $0.device < $1.device }
        guard Set(volumes.map(\.uuid)).count == volumes.count, Set(volumes.map(\.device)).count == volumes.count,
              volumes.contains(where: { $0.uuid == selected }) else { throw APFSVolumeCreationFailure.changed }
        return .init(device: device, uuid: uuid, selectedUUID: selected, capacity: capacity, free: free, stores: stores, volumes: volumes)
    }
    func validateNewName(_ name: String) throws {
        _ = try APFSVolumeCreation.validatedName(name)
        let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        guard !volumes.contains(where: { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) == key }) else { throw APFSVolumeCreationFailure.nameConflict }
        // A conservative admission margin, not an APFS minimum-size claim.
        guard free >= 64 << 20 else { throw APFSVolumeCreationFailure.insufficientSpace }
    }
    func sameIdentityAndMembers(as other: Self) -> Bool {
        device == other.device && uuid == other.uuid && selectedUUID == other.selectedUUID
            && capacity == other.capacity && stores == other.stores && volumes == other.volumes
    }
    func preservesMembers(in other: Self) -> Bool {
        device == other.device && uuid == other.uuid && capacity == other.capacity && stores == other.stores
            && volumes.allSatisfy { other.volumes.contains($0) }
    }
    func singleAddition(comparedWith before: Self, name: String) -> Volume? {
        let additions = volumes.filter { value in !before.volumes.contains(where: { $0.uuid == value.uuid }) }
        guard additions.count == 1, additions[0].name == name, additions[0].quota == 0, additions[0].reserve == 0 else { return nil }
        return additions[0]
    }
}
