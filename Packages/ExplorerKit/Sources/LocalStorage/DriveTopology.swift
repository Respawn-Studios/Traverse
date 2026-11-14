import Foundation

/// Session observations for presentation. No node is an operation capability.
public struct DriveTopologyNode: Identifiable, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable { case device, partition, apfsContainer, volume, unresolved }
    public let id: UInt64
    public let parentID: UInt64?
    public let kind: Kind
    public let name: String
    public let deviceName: String
    public let capacity: UInt64?
    public let fields: VolumeInspection.Fields
    public let volume: ManagedVolume
    public let relationshipVerified: Bool
    public var description: String { "Drive topology observation" }
    public init(id: UInt64, parentID: UInt64?, kind: Kind, name: String, deviceName: String,
                capacity: UInt64?, fields: VolumeInspection.Fields, volume: ManagedVolume, relationshipVerified: Bool) {
        self.id = id; self.parentID = parentID; self.kind = kind; self.name = name; self.deviceName = deviceName
        self.capacity = capacity; self.fields = fields; self.volume = volume; self.relationshipVerified = relationshipVerified
    }
    public var sharesContainerSpace: Bool { kind == .volume && fields.fileSystem?.lowercased() == "apfs" }
}

public struct DriveTopologySnapshot: Sendable, CustomStringConvertible {
    public let capturedAt: Date
    public let nodes: [DriveTopologyNode]
    public let discoveryTruncated: Bool
    private let byID: [UInt64: DriveTopologyNode]
    private let childrenByID: [UInt64: [DriveTopologyNode]]
    public var description: String { "Drive topology snapshot (\(nodes.count) observations)" }
    public init(nodes: [DriveTopologyNode], discoveryTruncated: Bool = false, capturedAt: Date = Date()) throws {
        guard nodes.count <= 512, Set(nodes.map(\.id)).count == nodes.count,
              nodes.allSatisfy({ $0.id != 0 && !$0.name.isEmpty && $0.name.utf8.count <= 512
                  && !$0.deviceName.isEmpty && $0.deviceName.utf8.count <= 128
                  && !$0.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                  && !$0.deviceName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                  && ($0.capacity ?? 0) <= UInt64(Int64.max) })
        else { throw VolumeLifecycleFailure.unsupported }
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        for node in nodes {
            var current: DriveTopologyNode? = node, seen = Set<UInt64>(), depth = 0
            while let value = current {
                guard seen.insert(value.id).inserted, depth < 64 else { throw VolumeLifecycleFailure.unsupported }
                depth += 1; current = value.parentID.flatMap { index[$0] }
            }
        }
        self.nodes = nodes; self.capturedAt = capturedAt; self.discoveryTruncated = discoveryTruncated; byID = index
        childrenByID = Dictionary(grouping: nodes.filter { $0.parentID != nil }, by: { $0.parentID! })
    }
    public func node(_ id: UInt64) -> DriveTopologyNode? { byID[id] }
    public func children(of id: UInt64) -> [DriveTopologyNode] {
        (childrenByID[id] ?? []).sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
    public var roots: [DriveTopologyNode] {
        nodes.filter { $0.parentID == nil || byID[$0.parentID!] == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public var hasUnresolvedRelationships: Bool {
        discoveryTruncated || nodes.contains { !$0.relationshipVerified || $0.kind == .unresolved
            || ($0.parentID != nil && byID[$0.parentID!] == nil) }
    }
    public func path(to id: UInt64) -> [DriveTopologyNode] {
        var path: [DriveTopologyNode] = [], current = byID[id]
        while let value = current {
            path.append(value); current = value.parentID.flatMap { byID[$0] }
        }
        return path.reversed()
    }
    public func containsSystemStorage(_ id: UInt64) -> Bool {
        nodes.contains { node in
            guard let path = node.volume.url?.path, path == "/" || path == "/System/Volumes/Data" else { return false }
            return self.path(to: node.id).contains { $0.id == id }
        }
    }
}

public protocol DriveTopologyReading: Sendable {
    func readTopology() async throws -> DriveTopologySnapshot
}
