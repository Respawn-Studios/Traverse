import DiskArbitration
import Foundation
import IOKit

/// A bounded, single-provider path. APFS's nearest Whole medium can be its
/// synthesized container; device removal must bind the outer storage medium.
/// Unknown/branched storage is deliberately outside this first qualification.
internal struct NativeDeviceScope: Equatable, Sendable {
    struct Node: Equatable, Sendable {
        let id: UInt64
        let parents: [UInt64]
        let isMedia: Bool
        let whole: Bool?
        let apfsSynthesized: Bool
        let apfsBridge: Bool
        let blockStorageDevice: Bool
    }
    let nodes: [Node]
    let nearestWhole: UInt64
    let outerWhole: UInt64

    init(nodes: [Node], nearestWhole: UInt64) throws {
        guard (2...64).contains(nodes.count), nodes.first?.isMedia == true,
              nodes.last?.blockStorageDevice == true,
              Set(nodes.map(\.id)).count == nodes.count, !nodes.contains(where: { $0.id == 0 })
        else { throw VolumeLifecycleFailure.unsupported }
        for (index, node) in nodes.enumerated() {
            if node.isMedia && node.whole == nil { throw VolumeLifecycleFailure.unsupported }
            if index < nodes.count - 1 {
                guard !node.blockStorageDevice, node.parents == [nodes[index + 1].id]
                else { throw VolumeLifecycleFailure.unsupported }
            }
        }
        let wholes = nodes.filter { $0.isMedia && $0.whole == true }
        guard (1...2).contains(wholes.count), wholes.first?.id == nearestWhole,
              let outer = wholes.last, !outer.apfsSynthesized else { throw VolumeLifecycleFailure.unsupported }
        if wholes.count == 2 {
            guard wholes[0].apfsSynthesized, nodes.contains(where: \.apfsBridge)
            else { throw VolumeLifecycleFailure.unsupported }
        }
        self.nodes = nodes; self.nearestWhole = nearestWhole; outerWhole = outer.id
    }
}

internal struct NativeDeviceResolution {
    let scope: NativeDeviceScope
    let ejectDisk: DADisk
}

internal enum NativeDeviceReader {
    static func observe(_ disk: DADisk, session: DASession) throws -> NativeDeviceResolution {
        guard let nearest = DADiskCopyWholeDisk(disk), let nearestID = VolumeLifecycle.registryID(nearest)
        else { throw VolumeLifecycleFailure.unsupported }
        var current = DADiskCopyIOMedia(disk)
        guard current != IO_OBJECT_NULL else { throw VolumeLifecycleFailure.unsupported }
        defer { if current != IO_OBJECT_NULL { IOObjectRelease(current) } }
        var nodes: [NativeDeviceScope.Node] = []
        var outer: DADisk?
        for _ in 0..<64 {
            var id: UInt64 = 0
            guard IORegistryEntryInPlane(current, kIOServicePlane) != 0,
                  IORegistryEntryGetRegistryEntryID(current, &id) == KERN_SUCCESS,
                  !nodes.contains(where: { $0.id == id }) else { throw VolumeLifecycleFailure.changed }
            let media = IOObjectConformsTo(current, "IOMedia") != 0
            let whole = media ? IORegistryEntryCreateCFProperty(current, "Whole" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool : nil
            let terminal = IOObjectConformsTo(current, "IOBlockStorageDevice") != 0
            if whole == true { outer = DADiskCreateFromIOMedia(kCFAllocatorDefault, session, current) }
            if terminal {
                nodes.append(.init(id: id, parents: [], isMedia: media, whole: whole,
                    apfsSynthesized: false, apfsBridge: false, blockStorageDevice: true))
                let scope = try NativeDeviceScope(nodes: nodes, nearestWhole: nearestID)
                guard let outer, VolumeLifecycle.registryID(outer) == scope.outerWhole,
                      DADiskCopyWholeDisk(outer).flatMap(VolumeLifecycle.registryID) == scope.outerWhole
                else { throw VolumeLifecycleFailure.changed }
                return NativeDeviceResolution(scope: scope, ejectDisk: outer)
            }
            var iterator: io_iterator_t = 0
            guard IORegistryEntryGetParentIterator(current, kIOServicePlane, &iterator) == KERN_SUCCESS
            else { throw VolumeLifecycleFailure.unsupported }
            let parent = IOIteratorNext(iterator), other = IOIteratorNext(iterator)
            let valid = IOIteratorIsValid(iterator) != 0
            IOObjectRelease(iterator)
            if other != IO_OBJECT_NULL { IOObjectRelease(other) }
            guard valid, parent != IO_OBJECT_NULL, other == IO_OBJECT_NULL else {
                if parent != IO_OBJECT_NULL { IOObjectRelease(parent) }
                throw VolumeLifecycleFailure.unsupported
            }
            var parentID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(parent, &parentID) == KERN_SUCCESS else {
                IOObjectRelease(parent); throw VolumeLifecycleFailure.changed
            }
            nodes.append(.init(id: id, parents: [parentID], isMedia: media, whole: whole,
                apfsSynthesized: IOObjectConformsTo(current, "AppleAPFSMedia") != 0,
                apfsBridge: IOObjectConformsTo(current, "AppleAPFSContainerScheme") != 0,
                blockStorageDevice: false))
            IOObjectRelease(current); current = parent
        }
        throw VolumeLifecycleFailure.unsupported
    }

    static func isPresent(_ id: UInt64) -> Bool {
        guard let matching = IORegistryEntryIDMatching(id) else { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        return IORegistryEntryInPlane(service, kIOServicePlane) != 0
    }
}
