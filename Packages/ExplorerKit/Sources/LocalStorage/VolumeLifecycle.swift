import Darwin
import DiskArbitration
import Foundation
import IOKit

public enum VolumeAction: Equatable, Sendable { case mount, unmount, eject, forceUnmountAndEject }
public enum VolumeDeviceKind: String, Sendable { case internalDisk, externalDisk, diskImage, unknown }

/// An observation, never authority derived from a user-entered BSD device name.
public struct ManagedVolume: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let url: URL?
    public let isInternal: Bool?
    public let deviceKind: VolumeDeviceKind
    public let canMount: Bool
    public let canUnmount: Bool
    public let canEject: Bool
    public let fileSystemID: Int64?
    public let group: UInt64?
    public let mediaID: UInt64?
    /// Presentation preference key only; never device/action authority.
    public let volumeUUID: UUID?
    public init(id: UUID, name: String, url: URL?, isInternal: Bool?, canMount: Bool, canUnmount: Bool,
                canEject: Bool, fileSystemID: Int64?, group: UInt64?, deviceKind: VolumeDeviceKind? = nil, mediaID: UInt64? = nil,
                volumeUUID: UUID? = nil) {
        self.id = id; self.name = name; self.url = url; self.isInternal = isInternal
        self.canMount = canMount; self.canUnmount = canUnmount; self.canEject = canEject
        self.fileSystemID = fileSystemID; self.group = group
        self.deviceKind = deviceKind ?? (isInternal == true ? .internalDisk : isInternal == false ? .externalDisk : .unknown)
        self.mediaID = mediaID
        self.volumeUUID = volumeUUID
    }
}

/// A one-request observation of the current selected attachment. Native IDs
/// are deliberately package-private and never become App authority or persisted
/// device identity.
public struct PreparedDriveHealthSelection: Sendable {
    public let selected: ManagedVolume
    let selectedMedia: UInt64
    let outerWhole: UInt64
    let blockBoundary: UInt64
    let generation: UInt64
}

public enum VolumeLifecycleFailure: Error, Sendable {
    case unavailable, changed, protectedStorage, userProtected, protectionUncertain, unsupported, busy, denied, uncertain, stillAttached, system(Int32)
    public var userMessage: String {
        switch self {
        case .unavailable: "The volume is unavailable. Refresh its status and try again."
        case .changed: "The device or its volumes changed. Review the current drive before trying again."
        case .protectedStorage: "This device holds system storage, Mac Explorer or its live history. It cannot be unmounted here."
        case .userProtected: "Drive protection prevents this action. Review the drive's protection in Drives before trying again."
        case .protectionUncertain: "Mac Explorer could not establish where its app or protected state is backed. This drive action is unavailable."
        case .unsupported: "The action or device scope cannot be established safely. Use Disk Utility to inspect it."
        case .busy: "The device is in use. Finish its tasks or close documents using it, then retry."
        case .denied: "macOS did not permit this drive action."
        case .uncertain: "The drive action was submitted, but its final state needs a refresh."
        case .stillAttached: "The device is still attached. Its volumes may be offline; review its status in Drives or Disk Utility."
        case .system: "macOS could not complete this drive action."
        }
    }
}

public struct PreparedVolumeAction: Sendable {
    public let target: ManagedVolume
    public let affected: [ManagedVolume]
    public let action: VolumeAction
    public let protectionMembers: [ManagedVolume]
    fileprivate let removalProtection: VolumeRemovalProtection
    fileprivate let protectedLocations: [URL]
    fileprivate let scope: MountScopeProof?
    fileprivate let deviceScope: NativeDeviceScope?
    fileprivate let memberScopes: [UInt64: NativeDeviceScope]
    public init(target: ManagedVolume, affected: [ManagedVolume], action: VolumeAction, protecting locations: [URL] = [],
                protectionMembers: [ManagedVolume]? = nil, removalProtection: VolumeRemovalProtection = .empty) {
        self.target = target; self.affected = affected; self.action = action; protectedLocations = locations; scope = nil; deviceScope = nil; memberScopes = [:]
        self.protectionMembers = protectionMembers ?? affected; self.removalProtection = removalProtection
    }
    fileprivate init(target: ManagedVolume, affected: [ManagedVolume], action: VolumeAction, protecting locations: [URL], scope: MountScopeProof,
                     deviceScope: NativeDeviceScope, memberScopes: [UInt64: NativeDeviceScope],
                     protectionMembers: [ManagedVolume], removalProtection: VolumeRemovalProtection) {
        self.target = target; self.affected = affected; self.action = action; protectedLocations = locations; self.scope = scope; self.deviceScope = deviceScope; self.memberScopes = memberScopes
        self.protectionMembers = protectionMembers; self.removalProtection = removalProtection
    }
}

public struct VolumeActionResult: Sendable {
    public let unmounted: Bool
    public let ejected: Bool
    public let failure: VolumeLifecycleFailure?
    public init(unmounted: Bool, ejected: Bool, failure: VolumeLifecycleFailure? = nil) {
        self.unmounted = unmounted; self.ejected = ejected; self.failure = failure
    }
}

public protocol VolumeLifecycleManaging: Sendable {
    var updates: AsyncStream<[ManagedVolume]> { get }
    func prepare(_ target: ManagedVolume, action: VolumeAction, protecting locations: [URL], removalProtection: VolumeRemovalProtection) async throws -> PreparedVolumeAction
    func perform(_ prepared: PreparedVolumeAction) async -> VolumeActionResult
}

public extension VolumeLifecycleManaging {
    func prepare(_ target: ManagedVolume, action: VolumeAction, protecting locations: [URL]) async throws -> PreparedVolumeAction {
        try await prepare(target, action: action, protecting: locations, removalProtection: .empty)
    }
}

/// One process-lifetime Disk Arbitration session owns C callback contexts. All
/// mutable state, native metadata and blocking probes remain on its serial queue.
/// Clients observe values; AppKit, transfer admission and UI never live here.
public final class VolumeLifecycle: VolumeLifecycleManaging, VolumeInspecting, DriveTopologyReading, @unchecked Sendable {
    public static let shared = VolumeLifecycle()
    public let updates: AsyncStream<[ManagedVolume]>
    private let continuation: AsyncStream<[ManagedVolume]>.Continuation
    private let queue = DispatchQueue(label: "MacExplorer.Volumes", qos: .utility)
    private var session: DASession?
    private var records: [String: Record] = [:]
    private var discoveryOverflow = false
    private var activeRequest = false

    private struct Record {
        let disk: DADisk
        let registryID: UInt64
        let device: NativeDeviceResolution?
        let value: ManagedVolume
    }

    private init() {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        queue.async { [self] in start() }
    }

    private func start() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { continuation.yield([]); return }
        self.session = session
        // shared retains this object until process exit; these registration
        // contexts cannot outlive their owner. Request contexts have own lifetime.
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, context in
            guard let context else { return }
            Unmanaged<VolumeLifecycle>.fromOpaque(context).takeUnretainedValue().observe(disk)
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, context in
            guard let context else { return }
            Unmanaged<VolumeLifecycle>.fromOpaque(context).takeUnretainedValue().observe(disk)
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            guard let context else { return }
            let owner = Unmanaged<VolumeLifecycle>.fromOpaque(context).takeUnretainedValue()
            if let bsd = DADiskGetBSDName(disk) { owner.records.removeValue(forKey: String(cString: bsd)) }
            owner.publish()
        }, context)
        DASessionSetDispatchQueue(session, queue)
    }

    internal static func registryID(_ disk: DADisk) -> UInt64? {
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }
        var value: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(media, &value) == KERN_SUCCESS ? value : nil
    }

    private func observe(_ disk: DADisk, publishUpdate: Bool = true) {
        guard let bsd = DADiskGetBSDName(disk), let data = DADiskCopyDescription(disk) as NSDictionary?,
              let registryID = Self.registryID(disk) else { return }
        let key = String(cString: bsd)
        guard records[key] != nil || records.count < 512 else { discoveryOverflow = true; return }
        let old = records[key]
        let id = old?.registryID == registryID ? old!.value.id : UUID()
        func bool(_ key: CFString) -> Bool? { data[key] as? Bool }
        let url = data[kDADiskDescriptionVolumePathKey] as? URL
        let mountable = bool(kDADiskDescriptionVolumeMountableKey) == true
        let internalDisk = bool(kDADiskDescriptionDeviceInternalKey)
        let device = session.flatMap { try? NativeDeviceReader.observe(disk, session: $0) }
        let whole = device?.ejectDisk
        let wholeID = device?.scope.outerWhole
        let wholeInfo = whole.flatMap { DADiskCopyDescription($0) } as NSDictionary?
        let wholeExternal = wholeInfo?[kDADiskDescriptionDeviceInternalKey] as? Bool == false
        let ejectable = wholeInfo?[kDADiskDescriptionMediaEjectableKey] as? Bool == true
        var fileSystemID: Int64?
        if let url {
            var value = stat()
            if stat(url.path, &value) == 0 { fileSystemID = Int64(value.st_dev) }
        }
        let name = data[kDADiskDescriptionVolumeNameKey] as? String
            ?? data[kDADiskDescriptionMediaNameKey] as? String ?? "Unnamed volume"
        let protocolName = data[kDADiskDescriptionDeviceProtocolKey] as? String
        let wholeProtocol = wholeInfo?[kDADiskDescriptionDeviceProtocolKey] as? String
        let image = protocolName == "Virtual Interface" && wholeProtocol == "Virtual Interface"
            && Self.protocolLocation(disk) == "File" && whole.flatMap(Self.protocolLocation) == "File"
        let kind = Self.deviceKind(internalFlag: internalDisk, wholeInternal: wholeInfo?[kDADiskDescriptionDeviceInternalKey] as? Bool,
                                   positivelyIdentifiedImage: image && wholeID != nil)
        let manageable = (kind == .externalDisk || kind == .diskImage) && bool(kDADiskDescriptionVolumeNetworkKey) == false && device != nil
        let volumeUUID = Self.preferenceUUID(data[kDADiskDescriptionVolumeUUIDKey])
        let value = ManagedVolume(id: id, name: name, url: url, isInternal: internalDisk,
            canMount: manageable && mountable && url == nil,
            canUnmount: manageable && mountable && url != nil && fileSystemID != nil,
            canEject: manageable && (wholeExternal || kind == .diskImage) && ejectable && wholeID != nil,
            fileSystemID: fileSystemID, group: wholeID, deviceKind: kind, mediaID: registryID, volumeUUID: volumeUUID)
        records[key] = Record(disk: disk, registryID: registryID, device: device, value: value)
        if publishUpdate { publish() }
    }

    internal static func preferenceUUID(_ raw: Any?) -> UUID? {
        guard let raw, CFGetTypeID(raw as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
        let value = raw as! CFUUID // Checked native type; presentation preference only.
        return UUID(uuidString: CFUUIDCreateString(nil, value) as String)
    }

    internal static func deviceKind(internalFlag: Bool?, wholeInternal: Bool?, positivelyIdentifiedImage: Bool) -> VolumeDeviceKind {
        if internalFlag == true || wholeInternal == true { return .internalDisk }
        if positivelyIdentifiedImage { return .diskImage }
        if internalFlag == false { return .externalDisk }
        return .unknown
    }
    private static func protocolLocation(_ disk: DADisk) -> String? {
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }
        let values = IORegistryEntrySearchCFProperty(media, kIOServicePlane, "Protocol Characteristics" as CFString,
            kCFAllocatorDefault, IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)) as? [String: Any]
        guard values?["Physical Interconnect"] as? String == "Virtual Interface" else { return nil }
        return values?["Physical Interconnect Location"] as? String
    }

    private func refreshAll() {
        guard let session else { return }
        for bsd in Array(records.keys) {
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd) else {
                records.removeValue(forKey: bsd); continue
            }
            observe(disk, publishUpdate: false)
        }
        publish()
    }

    private func publish() {
        continuation.yield(records.values.map(\.value).filter {
            $0.url != nil || $0.canMount
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    /// Qualification reads the existing native observation owner directly;
    /// it must not initialize the application's personal protection catalog.
    @_spi(Qualification) public func observationsForQualification() async -> [ManagedVolume] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: records.values.map(\.value).filter { $0.url != nil || $0.canMount }) }
        }
    }

    public func inspect(_ target: ManagedVolume) async throws -> VolumeInspection {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard !activeRequest else { throw VolumeLifecycleFailure.busy }
                    guard let media = target.mediaID, let session,
                          let pair = records.first(where: { $0.value.value.id == target.id }), pair.value.value == target,
                          pair.value.registryID == media, Self.registryID(pair.value.disk) == media,
                          let data = DADiskCopyDescription(pair.value.disk) as NSDictionary?,
                          Self.matchesInspectionMount(data, target: target) else { throw VolumeLifecycleFailure.changed }
                    let device = try? NativeDeviceReader.observe(pair.value.disk, session: session)
                    let verifiedOuter = device.flatMap { value -> DADisk? in
                        guard target.group == nil || value.scope.outerWhole == target.group,
                              Self.registryID(value.ejectDisk) == value.scope.outerWhole else { return nil }
                        return value.ejectDisk
                    }
                    let outer = verifiedOuter.flatMap { DADiskCopyDescription($0) } as NSDictionary?
                    let fields = VolumeInspection.Fields.read(data, outer: outer)
                    guard Self.registryID(pair.value.disk) == media,
                          let after = DADiskCopyDescription(pair.value.disk) as NSDictionary?,
                          Self.matchesInspectionMount(after, target: target), records[pair.key]?.value == target,
                          verifiedOuter.map({ Self.registryID($0) == device?.scope.outerWhole }) != false else {
                        throw VolumeLifecycleFailure.changed
                    }
                    continuation.resume(returning: VolumeInspection(volume: target, deviceName: pair.key, fields: fields))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Explicit health action only. This runs on the Disk Arbitration owner
    /// queue and never opens a SMART plugin or waits for its synchronous call.
    public func prepareHealthSelection(_ target: ManagedVolume) async throws -> PreparedDriveHealthSelection {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard !activeRequest else { throw VolumeLifecycleFailure.busy }
                    guard target.deviceKind == .internalDisk || target.deviceKind == .externalDisk && target.isInternal == false,
                          let selectedID = target.mediaID,
                          let session, let pair = records.first(where: { $0.value.value.id == target.id }),
                          pair.value.value == target, pair.value.registryID == selectedID,
                          Self.registryID(pair.value.disk) == selectedID else { throw VolumeLifecycleFailure.unsupported }
                    let scope = try NativeDeviceReader.observe(pair.value.disk, session: session).scope
                    guard scope.nodes.first?.id == selectedID,
                          scope.outerWhole == target.group,
                          let block = scope.nodes.last?.id, block != selectedID,
                          Self.registryID(pair.value.disk) == selectedID,
                          records[pair.key]?.value == target else { throw VolumeLifecycleFailure.changed }
                    continuation.resume(returning: PreparedDriveHealthSelection(selected: target,
                        selectedMedia: selectedID, outerWhole: scope.outerWhole,
                        blockBoundary: block, generation: UInt64.random(in: 1...UInt64.max)))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    internal func revalidateHealthSelection(_ prepared: PreparedDriveHealthSelection) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let session, let pair = records.first(where: { $0.value.value.id == prepared.selected.id }),
                      pair.value.value == prepared.selected,
                      pair.value.registryID == prepared.selectedMedia,
                      Self.registryID(pair.value.disk) == prepared.selectedMedia,
                      let scope = try? NativeDeviceReader.observe(pair.value.disk, session: session).scope,
                      scope.nodes.first?.id == prepared.selectedMedia,
                      scope.outerWhole == prepared.outerWhole,
                      scope.nodes.last?.id == prepared.blockBoundary else {
                    continuation.resume(returning: false); return
                }
                continuation.resume(returning: true)
            }
        }
    }

    /// Reads all currently observed media, including unmounted devices. Uses the
    /// existing native owner; it neither steals the discovery stream nor opens
    /// user files, launches diskutil, or grants action authority.
    public func readTopology() async throws -> DriveTopologySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard !activeRequest, let session else { throw VolumeLifecycleFailure.busy }
                    let observed = records.sorted { $0.key < $1.key }
                    var nodes: [DriveTopologyNode] = []
                    for (key, record) in observed {
                        guard Self.registryID(record.disk) == record.registryID,
                              let data = DADiskCopyDescription(record.disk) as NSDictionary?,
                              Self.sameTopologyLocation(data, target: record.value) else { throw VolumeLifecycleFailure.changed }
                        let resolution = try? NativeDeviceReader.observe(record.disk, session: session)
                        let media = resolution?.scope.nodes.filter(\.isMedia) ?? []
                        let outer = resolution.flatMap { DADiskCopyDescription($0.ejectDisk) } as NSDictionary?
                        let fields = VolumeInspection.Fields.read(data, outer: outer)
                        let kind: DriveTopologyNode.Kind
                        if resolution?.scope.outerWhole == record.registryID { kind = .device }
                        else if media.first?.whole == true && media.first?.apfsSynthesized == true { kind = .apfsContainer }
                        else if data[kDADiskDescriptionVolumeMountableKey] as? Bool == true || record.value.url != nil { kind = .volume }
                        else if resolution != nil { kind = .partition }
                        else { kind = .unresolved }
                        let parent = media.dropFirst().first?.id
                        let rawName = data[kDADiskDescriptionVolumeNameKey] as? String
                            ?? data[kDADiskDescriptionMediaNameKey] as? String ?? fields.model ?? "Unnamed storage"
                        let name = rawName.utf8.count <= 512
                            && !rawName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                            && !rawName.isEmpty ? rawName : "Unnamed storage"
                        nodes.append(.init(id: record.registryID, parentID: parent, kind: kind, name: name,
                            deviceName: key, capacity: fields.mediaBytes, fields: fields, volume: record.value,
                            relationshipVerified: resolution != nil))
                        guard Self.registryID(record.disk) == record.registryID,
                              let after = DADiskCopyDescription(record.disk) as NSDictionary?,
                              Self.sameTopologyLocation(after, target: record.value),
                              VolumeInspection.Fields.read(after, outer: outer) == fields,
                              resolution.map({ Self.registryID($0.ejectDisk) == $0.scope.outerWhole }) != false
                        else { throw VolumeLifecycleFailure.changed }
                    }
                    // Check the complete native set again after collecting it;
                    // values from a changed attachment never become a new view.
                    for (_, record) in observed {
                        guard Self.registryID(record.disk) == record.registryID,
                              let data = DADiskCopyDescription(record.disk) as NSDictionary?,
                              Self.sameTopologyLocation(data, target: record.value) else { throw VolumeLifecycleFailure.changed }
                    }
                    continuation.resume(returning: try DriveTopologySnapshot(nodes: nodes, discoveryTruncated: discoveryOverflow))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func sameTopologyLocation(_ data: NSDictionary, target: ManagedVolume) -> Bool {
        let path = (data[kDADiskDescriptionVolumePathKey] as? URL)?.path
        let old = target.url?.path
        let samePath = path.map { Data($0.utf8) } == old.map { Data($0.utf8) }
        return samePath && preferenceUUID(data[kDADiskDescriptionVolumeUUIDKey]) == target.volumeUUID
    }

    internal static func matchesInspectionMount(_ data: NSDictionary, target: ManagedVolume) -> Bool {
        let mount = (data[kDADiskDescriptionVolumePathKey] as? URL)?.standardizedFileURL
        return mount == target.url?.standardizedFileURL && preferenceUUID(data[kDADiskDescriptionVolumeUUIDKey]) == target.volumeUUID
    }

    public func prepare(_ target: ManagedVolume, action: VolumeAction, protecting locations: [URL], removalProtection: VolumeRemovalProtection) async throws -> PreparedVolumeAction {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let validated = try validate(target, action: action, protecting: locations, removalProtection: removalProtection)
                    continuation.resume(returning: PreparedVolumeAction(target: target, affected: validated.affected, action: action,
                        protecting: locations, scope: validated.scope, deviceScope: validated.deviceScope, memberScopes: validated.members,
                        protectionMembers: validated.protectionMembers, removalProtection: removalProtection))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private struct Validation {
        let affected: [ManagedVolume]
        let scope: MountScopeProof
        let deviceScope: NativeDeviceScope
        let members: [UInt64: NativeDeviceScope]
        let protectionMembers: [ManagedVolume]
    }
    private func validate(_ target: ManagedVolume, action: VolumeAction, protecting locations: [URL], removalProtection: VolumeRemovalProtection) throws -> Validation {
        guard action != .forceUnmountAndEject else { throw VolumeLifecycleFailure.unsupported }
        guard !discoveryOverflow else { throw VolumeLifecycleFailure.unsupported }
        refreshAll()
        guard let record = records.values.first(where: { $0.value.id == target.id }),
              record.value == target, Self.registryID(record.disk) == record.registryID else { throw VolumeLifecycleFailure.changed }
        guard let targetDevice = record.device else { throw VolumeLifecycleFailure.unsupported }
        let wholeAction = action == .eject || action == .forceUnmountAndEject
        let protectionMembers = try currentProtectionMembers(target: record, action: action, rules: removalProtection)
        try removalProtection.validate(target: target, action: action, members: protectionMembers)
        if action == .mount { guard target.canMount else { throw VolumeLifecycleFailure.unsupported } }
        else if action == .unmount { guard target.canUnmount else { throw VolumeLifecycleFailure.unsupported } }
        else { guard target.canEject else { throw VolumeLifecycleFailure.unsupported } }
        let affectedRecords = wholeAction ? records.values.filter { $0.value.group == target.group && $0.value.url != nil } : [record]
        let affected = affectedRecords.map(\.value)
        var members: [UInt64: NativeDeviceScope] = [:]
        for member in affectedRecords + [record] {
            guard let proof = member.device?.scope else { throw VolumeLifecycleFailure.unsupported }
            members[member.registryID] = proof
        }
        // A known, entirely unmounted device can still be normally ejected.
        // The independent mounted-volume reconciliation below proves emptiness.
        guard !affected.isEmpty || action == .mount || wholeAction else { throw VolumeLifecycleFailure.unavailable }
        guard [.externalDisk, .diskImage].contains(target.deviceKind),
              affected.allSatisfy({ [.externalDisk, .diskImage].contains($0.deviceKind) }) else { throw VolumeLifecycleFailure.protectedStorage }
        guard affected.filter({ $0.url != nil }).allSatisfy({ $0.fileSystemID != nil }) else { throw VolumeLifecycleFailure.unsupported }
        let devices = Set(affected.compactMap(\.fileSystemID))
        guard let session else { throw VolumeLifecycleFailure.unavailable }
        let reader = MountScopeReader(session: session)
        let scope = MountScopeResolver(observe: reader.observe)
        if action != .mount {
            // Independently reconcile mounted local volumes, including hidden
            // siblings; callback discovery alone cannot prove complete impact.
            guard let group = target.group, let urls = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: [.volumeIsLocalKey], options: []) else { throw VolumeLifecycleFailure.unavailable }
            let local = try urls.filter { try $0.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal != false }
            let actualDevices = try scope.normalDiskMembers(in: local, group: group)
            guard wholeAction ? actualDevices == devices : devices.isSubset(of: actualDevices) else { throw VolumeLifecycleFailure.changed }
        }
        for location in locations + [Bundle.main.bundleURL, FileManager.default.homeDirectoryForCurrentUser] {
            var candidate = location
            var identity = stat(), found = false
            for _ in 0..<128 {
                if stat(candidate.path, &identity) == 0 { found = true; break }
                guard errno == ENOENT else { throw VolumeLifecycleFailure.denied }
                let parent = candidate.deletingLastPathComponent()
                guard parent.path != candidate.path else { break }
                candidate = parent
            }
            guard found else { throw VolumeLifecycleFailure.denied }
            if devices.contains(Int64(identity.st_dev)) { throw VolumeLifecycleFailure.protectedStorage }
            try scope.validateProtectedLocation(candidate, devices: devices, wholeGroup: wholeAction ? target.group : nil)
        }
        try scope.revalidate()
        return Validation(affected: affected, scope: scope.proof, deviceScope: targetDevice.scope, members: members, protectionMembers: protectionMembers)
    }

    private func currentProtectionMembers(target: Record, action: VolumeAction, rules: VolumeRemovalProtection) throws -> [ManagedVolume] {
        guard action == .eject || action == .forceUnmountAndEject else { return [target.value] }
        guard let outer = target.device?.scope.outerWhole, target.value.group == outer else { throw VolumeLifecycleFailure.protectionUncertain }
        // A known protected record whose provider cannot be established cannot
        // be declared unrelated to the requested device.
        for record in records.values where rules.level(for: record.value).prevents(action) {
            guard record.device != nil else { throw VolumeLifecycleFailure.protectionUncertain }
        }
        let members = records.values.filter {
            $0.value.id == target.value.id || ($0.value.group == outer && ($0.value.volumeUUID != nil || $0.value.url != nil || $0.value.canMount))
        }
        guard members.allSatisfy({ $0.device?.scope.outerWhole == outer }) else { throw VolumeLifecycleFailure.protectionUncertain }
        return members.map(\.value)
    }

    /// The app coordinator must retain its mutation/reader barrier until this
    /// returns. Native requests cannot be undone by cancelling a Swift Task.
    public func perform(_ prepared: PreparedVolumeAction) async -> VolumeActionResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do {
                    guard !activeRequest else { throw VolumeLifecycleFailure.busy }
                    let validated = try validate(prepared.target, action: prepared.action, protecting: prepared.protectedLocations, removalProtection: prepared.removalProtection)
                    guard Set(validated.affected) == Set(prepared.affected), validated.scope == prepared.scope,
                          validated.deviceScope == prepared.deviceScope, validated.members == prepared.memberScopes,
                          Set(validated.protectionMembers) == Set(prepared.protectionMembers)
                    else { throw VolumeLifecycleFailure.changed }
                    guard let record = records.values.first(where: { $0.value.id == prepared.target.id }) else { throw VolumeLifecycleFailure.changed }
                    activeRequest = true
                    let context = Request(owner: self, record: record, prepared: prepared, continuation: continuation)
                    context.start()
                } catch {
                    continuation.resume(returning: VolumeActionResult(unmounted: false, ejected: false,
                        failure: error as? VolumeLifecycleFailure ?? .unavailable))
                }
            }
        }
    }

    // Native callbacks and reconciliation run only on the owner's serial queue.
    private final class Request: @unchecked Sendable {
        let owner: VolumeLifecycle
        let record: Record
        let prepared: PreparedVolumeAction
        let continuation: CheckedContinuation<VolumeActionResult, Never>
        var unmounted = false
        private var unmountSteps: [(disk: DADisk, hadMountedVolumes: Bool)] = []
        private var step = 0
        init(owner: VolumeLifecycle, record: Record, prepared: PreparedVolumeAction, continuation: CheckedContinuation<VolumeActionResult, Never>) {
            self.owner = owner; self.record = record; self.prepared = prepared; self.continuation = continuation
        }
        func start() {
            if prepared.action == .mount {
                let context = Unmanaged.passRetained(self).toOpaque()
                DADiskMount(record.disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), { _, dissenter, context in
                    let request = Unmanaged<Request>.fromOpaque(context!).takeRetainedValue()
                    request.finish(dissenter)
                }, context)
            } else if prepared.action == .unmount {
                let context = Unmanaged.passRetained(self).toOpaque()
                DADiskUnmount(record.disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), { _, dissenter, context in
                    let request = Unmanaged<Request>.fromOpaque(context!).takeRetainedValue()
                    if let dissenter { request.finish(dissenter); return }
                    request.unmounted = true; request.finish(nil)
                }, context)
            } else {
                do {
                    let members = try validatedMembers()
                    guard let outer = record.device?.ejectDisk, let scope = prepared.deviceScope else { throw VolumeLifecycleFailure.changed }
                    var containers: [UInt64: DADisk] = [:]
                    for member in members where member.value.url != nil {
                        guard let disk = DADiskCopyWholeDisk(member.disk), let id = VolumeLifecycle.registryID(disk),
                              id == prepared.memberScopes[member.registryID]?.nearestWhole else { throw VolumeLifecycleFailure.changed }
                        if id != scope.outerWhole { containers[id] = disk }
                    }
                    unmountSteps = containers.sorted { $0.key < $1.key }.map { ($0.value, true) }
                    unmountSteps.append((outer, members.contains { $0.value.url != nil && $0.device?.scope.nearestWhole == scope.outerWhole }))
                    submitNextUnmount()
                } catch { finishFailure(error as? VolumeLifecycleFailure ?? .changed) }
            }
        }

        private func validatedMembers() throws -> [Record] {
            guard let session = owner.session else { throw VolumeLifecycleFailure.unavailable }
            var members: [Record] = []
            for (id, expected) in prepared.memberScopes {
                guard let member = owner.records.values.first(where: { $0.registryID == id }),
                      VolumeLifecycle.registryID(member.disk) == id,
                      try NativeDeviceReader.observe(member.disk, session: session).scope == expected
                else { throw VolumeLifecycleFailure.changed }
                members.append(member)
            }
            guard members.count == prepared.memberScopes.count else { throw VolumeLifecycleFailure.changed }
            return members
        }

        private func submitNextUnmount() {
            do {
                owner.refreshAll()
                guard let target = owner.records.values.first(where: { $0.value.id == prepared.target.id }) else { throw VolumeLifecycleFailure.changed }
                let current = try owner.currentProtectionMembers(target: target, action: prepared.action, rules: prepared.removalProtection)
                func identities(_ values: [ManagedVolume]) -> Set<ProtectionIdentity> { Set(values.map(ProtectionIdentity.init)) }
                guard identities(current) == identities(prepared.protectionMembers) else { throw VolumeLifecycleFailure.changed }
                try prepared.removalProtection.validate(target: target.value, action: prepared.action, members: current)
                _ = try validatedMembers()
                guard let session = owner.session, let scope = prepared.deviceScope, let proof = prepared.scope
                else { throw VolumeLifecycleFailure.changed }
                let reader = MountScopeReader(session: session)
                // Target mount paths necessarily change after unmount. All
                // unrelated and protected facts retain their original contract.
                for (url, expected) in proof.observations {
                    if case .block(_, let group) = expected.native, group == scope.outerWhole { continue }
                    guard try reader.observe(url) == expected else { throw VolumeLifecycleFailure.changed }
                }
                if step < unmountSteps.count {
                    let current = unmountSteps[step]; step += 1
                    let context = Unmanaged.passRetained(self).toOpaque()
                    DADiskUnmount(current.disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), { _, dissenter, context in
                        let request = Unmanaged<Request>.fromOpaque(context!).takeRetainedValue()
                        if let dissenter { request.finish(dissenter); return }
                        request.unmounted = request.unmounted || request.unmountSteps[request.step - 1].hadMountedVolumes
                        request.submitNextUnmount()
                    }, context)
                } else {
                    guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey], options: [])
                    else { throw VolumeLifecycleFailure.unavailable }
                    let local = try urls.filter { try $0.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal != false }
                    let resolver = MountScopeResolver(observe: reader.observe)
                    guard try resolver.normalDiskMembers(in: local, group: scope.outerWhole).isEmpty else { throw VolumeLifecycleFailure.busy }
                    try resolver.revalidate()
                    guard let outer = record.device?.ejectDisk else { throw VolumeLifecycleFailure.changed }
                    let context = Unmanaged.passRetained(self).toOpaque()
                    DADiskEject(outer, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, context in
                        Unmanaged<Request>.fromOpaque(context!).takeRetainedValue().finish(dissenter)
                    }, context)
                }
            } catch { finishFailure(error as? VolumeLifecycleFailure ?? .changed) }
        }
        private struct ProtectionIdentity: Hashable {
            let id: UUID
            let media: UInt64?
            let volume: UUID?
            let group: UInt64?
            init(_ value: ManagedVolume) { id = value.id; media = value.mediaID; volume = value.volumeUUID; group = value.group }
        }
        func finish(_ dissenter: DADissenter?) {
            let failure: VolumeLifecycleFailure?
            if let dissenter {
                let status = DADissenterGetStatus(dissenter)
                if status == Int32(truncatingIfNeeded: kDAReturnBusy) { failure = .busy }
                else if status == Int32(truncatingIfNeeded: kDAReturnNotPermitted)
                    || status == Int32(truncatingIfNeeded: kDAReturnNotPrivileged) { failure = .denied }
                else { failure = .system(status) }
            } else { failure = nil }
            if let failure { finishFailure(failure) }
            else if prepared.action == .eject { reconcileEjection(until: .now() + .seconds(5)) }
            else { finishSuccess(ejected: false) }
        }
        func reconcileEjection(until deadline: DispatchTime) {
            guard let scope = prepared.deviceScope else { finishFailure(.changed); return }
            if !NativeDeviceReader.isPresent(scope.outerWhole) { finishSuccess(ejected: true); return }
            guard DispatchTime.now() < deadline else { finishFailure(.stillAttached); return }
            // Callback success can precede registry notification delivery. Keep
            // request ownership through bounded, read-only reconciliation.
            owner.queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in reconcileEjection(until: deadline) }
        }
        func finishSuccess(ejected: Bool) {
            owner.activeRequest = false
            continuation.resume(returning: VolumeActionResult(unmounted: unmounted, ejected: ejected))
        }
        func finishFailure(_ failure: VolumeLifecycleFailure) {
            owner.activeRequest = false
            continuation.resume(returning: VolumeActionResult(unmounted: unmounted, ejected: false, failure: failure))
        }
    }
}
