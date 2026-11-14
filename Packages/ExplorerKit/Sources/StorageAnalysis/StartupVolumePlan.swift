import CoreFoundation
import Foundation

public enum StartupStorageFailure: Error, Equatable, Sendable {
    case busy, cancelled, unavailable, unsupportedSchema, invalidFacts, changed, nativeIdentityUnavailable
}
public enum APFSGroupTag: Sendable {}
public enum APFSContainerTag: Sendable {}
public enum APFSVolumeTag: Sendable {}
public enum APFSSnapshotTag: Sendable {}

/// Separate types prevent a snapshot, volume and group UUID being substituted
/// for one another. These private-session facts are never diagnostic strings.
public struct APFSIdentity<Kind: Sendable>: Hashable, Sendable {
    let value: UUID
    init(_ text: String) throws {
        guard let id = UUID(uuidString: text), id != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) else { throw StartupStorageFailure.invalidFacts }
        value = id
    }
}

enum StartupMemberRole: String, Sendable { case system = "System", data = "Data" }
struct StartupInfoFacts: Equatable, Sendable {
    let device: String, containerReference: String
    let group: APFSIdentity<APFSGroupTag>
    let volume, disk: APFSIdentity<APFSVolumeTag>
    let snapshot: APFSIdentity<APFSSnapshotTag>?
    let mount: String?
    // Sandboxed diskutil can omit this field. Unknown is not an assertion that
    // the volume is unlocked; admitted scan sources must still be opened and
    // checked against their native physical-volume identities.
    let locked: Bool?
}
struct StartupGroupMember: Equatable, Sendable {
    let role: StartupMemberRole
    let device: String
    let volume: APFSIdentity<APFSVolumeTag>
}
struct StartupGroupFacts: Equatable, Sendable {
    let group: APFSIdentity<APFSGroupTag>
    let container: APFSIdentity<APFSContainerTag>
    let containerReference: String
    let system, data: StartupGroupMember
}
struct StartupFacts: Equatable, Sendable {
    let active: StartupInfoFacts
    let membership: StartupGroupFacts
    let system, data: StartupInfoFacts
    let containerCapacity, containerFree: UInt64?
}

/// Decoder for the XML-plist schema observed/qualified on macOS27. It accepts
/// explicit group membership, never a drive name or sliced BSD snapshot name.
enum StartupFactDecoder {
    static let revision = "apple-diskutil-startup-27-v2"

    static func info(_ object: [String: Any]) throws -> StartupInfoFacts {
        guard try text(object, "FilesystemType") == "apfs" else { throw StartupStorageFailure.unsupportedSchema }
        let device = try text(object, "DeviceIdentifier"), container = try text(object, "APFSContainerReference")
        guard validDevice(device), validContainer(container) else { throw StartupStorageFailure.invalidFacts }
        let isSnapshot = try boolean(object, "APFSSnapshot")
        let snapshot = try isSnapshot ? APFSIdentity<APFSSnapshotTag>(text(object, "APFSSnapshotUUID")) : nil
        // diskutil explicitly returns an empty mount point for the unmounted
        // backing System member. It is not authority to invent or mount a path.
        let mount: String?
        if let value = object["MountPoint"] {
            guard let value = value as? String else { throw StartupStorageFailure.unsupportedSchema }
            mount = value.isEmpty ? nil : value
        } else { mount = nil }
        if let mount { guard validMount(mount) else { throw StartupStorageFailure.invalidFacts } }
        return try .init(device: device, containerReference: container, group: APFSIdentity(text(object, "APFSVolumeGroupID")),
            volume: APFSIdentity(text(object, "VolumeUUID")), disk: APFSIdentity(text(object, "DiskUUID")),
            snapshot: snapshot, mount: mount, locked: optionalBoolean(object, "Locked"))
    }

    static func group(_ object: [String: Any], root: StartupInfoFacts) throws -> StartupGroupFacts {
        let containers = try array(object, "Containers", limit: 128)
        let matching = try containers.filter { try text($0, "ContainerReference") == root.containerReference }
        guard matching.count == 1 else { throw StartupStorageFailure.invalidFacts }
        let container = matching[0], containerID = try APFSIdentity<APFSContainerTag>(text(container, "APFSContainerUUID"))
        let groups = try array(container, "VolumeGroups", limit: 128)
        let group = try groups.filter { try APFSIdentity<APFSGroupTag>(text($0, "APFSVolumeGroupUUID")) == root.group }
        guard group.count == 1 else { throw StartupStorageFailure.invalidFacts }
        let members = try array(group[0], "Volumes", limit: 16)
        guard members.count == 2 else { throw StartupStorageFailure.invalidFacts }
        var system: StartupGroupMember?, data: StartupGroupMember?
        for member in members {
            guard let role = StartupMemberRole(rawValue: try text(member, "Role")) else { throw StartupStorageFailure.invalidFacts }
            let device = try text(member, "DeviceIdentifier")
            guard validDevice(device) else { throw StartupStorageFailure.invalidFacts }
            let fact = try StartupGroupMember(role: role, device: device, volume: APFSIdentity(text(member, "DiskUUID")))
            switch role {
            case .system: guard system == nil else { throw StartupStorageFailure.invalidFacts }; system = fact
            case .data: guard data == nil else { throw StartupStorageFailure.invalidFacts }; data = fact
            }
        }
        guard let system, let data, system.volume != data.volume, system.device != data.device else { throw StartupStorageFailure.invalidFacts }
        return .init(group: root.group, container: containerID, containerReference: root.containerReference, system: system, data: data)
    }

    static func assemble(root: StartupInfoFacts, group: StartupGroupFacts, container object: [String: Any],
                         system: StartupInfoFacts, data: StartupInfoFacts) throws -> StartupFacts {
        guard root.mount == "/", root.locked != true, root.group == group.group,
              root.containerReference == group.containerReference,
              root.volume != group.data.volume, root.disk != group.data.volume,
              root.snapshot != nil || (root.volume == group.system.volume && root.disk == group.system.volume) else { throw StartupStorageFailure.invalidFacts }
        let containers = try array(object, "Containers", limit: 128)
        guard containers.count == 1, let container = containers.first,
              try text(container, "ContainerReference") == group.containerReference,
              try APFSIdentity<APFSContainerTag>(text(container, "APFSContainerUUID")) == group.container else { throw StartupStorageFailure.invalidFacts }
        let members = try array(container, "Volumes", limit: 4096)
        for (member, info) in [(group.system, system), (group.data, data)] {
            let rows = try members.filter { try text($0, "DeviceIdentifier") == member.device }
            guard rows.count == 1,
                  try APFSIdentity<APFSVolumeTag>(text(rows[0], "APFSVolumeUUID")) == member.volume,
                  let roles = rows[0]["Roles"] as? [String], roles == [member.role.rawValue],
                  info.locked != true, try optionalBoolean(rows[0], "Locked") != true,
                  info.snapshot == nil, info.volume == member.volume, info.disk == member.volume,
                  info.device == member.device, info.containerReference == group.containerReference,
                  info.group == group.group else { throw StartupStorageFailure.invalidFacts }
        }
        guard let dataMount = data.mount, dataMount != "/" else { throw StartupStorageFailure.unavailable }
        // Capacity reporting is independent of membership/access. Sandboxed
        // diskutil omits these fields; never turn that into guessed zeroes or
        // a refusal to analyze already verified mounted volumes.
        let capacity = try container["CapacityCeiling"].map { _ in try unsigned(container, "CapacityCeiling") }
        let free = try container["CapacityFree"].map { _ in try unsigned(container, "CapacityFree") }
        if let capacity { guard capacity > 0 else { throw StartupStorageFailure.invalidFacts } }
        if let capacity, let free { guard free <= capacity else { throw StartupStorageFailure.invalidFacts } }
        return .init(active: root, membership: group, system: system, data: data, containerCapacity: capacity, containerFree: free)
    }

    static func text(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty, value.utf8.count <= 1024, !value.utf8.contains(0) else { throw StartupStorageFailure.unsupportedSchema }
        return value
    }
    static func boolean(_ object: [String: Any], _ key: String) throws -> Bool {
        guard let value = object[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw StartupStorageFailure.unsupportedSchema }
        return value.boolValue
    }
    static func optionalBoolean(_ object: [String: Any], _ key: String) throws -> Bool? {
        guard object[key] != nil else { return nil }
        return try boolean(object, key)
    }
    static func unsigned(_ object: [String: Any], _ key: String) throws -> UInt64 {
        guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: value.objCType)),
              value.int64Value >= 0 else { throw StartupStorageFailure.unsupportedSchema }
        return value.uint64Value
    }
    static func array(_ object: [String: Any], _ key: String, limit: Int) throws -> [[String: Any]] {
        guard let value = object[key] as? [[String: Any]], value.count <= limit else { throw StartupStorageFailure.unsupportedSchema }; return value
    }
    static func validContainer(_ value: String) -> Bool {
        value.hasPrefix("disk") && !value.dropFirst(4).isEmpty && value.dropFirst(4).utf8.allSatisfy { (48...57).contains($0) }
    }
    static func validDevice(_ value: String) -> Bool {
        guard value.utf8.count <= 64, value.hasPrefix("disk") else { return false }
        let components = value.dropFirst(4).split(separator: "s", omittingEmptySubsequences: false)
        return (1...3).contains(components.count) && components.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
    }
    static func validMount(_ value: String) -> Bool {
        guard value.hasPrefix("/"), value.utf8.count < 1024, !value.utf8.contains(0) else { return false }
        if value == "/" { return true }
        return value.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

/// Preflight XML structure before Foundation materializes the plist tree. No
/// external entity resolution, raw output logging or file-reference loading.
final class BoundedStartupPlist: NSObject, XMLParserDelegate {
    private var depth = 0, nodes = 0, rejected = false
    static func decode(_ data: Data) throws -> [String: Any] {
        guard data.count > 0, data.count <= 4 << 20, data.starts(with: Data("<?xml".utf8)) else { throw StartupStorageFailure.unsupportedSchema }
        let delegate = BoundedStartupPlist(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.externalEntityResolvingPolicy = .never; parser.delegate = delegate
        guard parser.parse(), !delegate.rejected, delegate.depth == 0 else { throw StartupStorageFailure.unsupportedSchema }
        do {
            guard let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { throw StartupStorageFailure.unsupportedSchema }
            return value
        } catch { throw StartupStorageFailure.unsupportedSchema }
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        depth += 1; nodes += 1
        if depth > 32 || nodes > 32768 { rejected = true; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { depth -= 1 }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { rejected = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { rejected = true; parser.abortParsing() }
}
