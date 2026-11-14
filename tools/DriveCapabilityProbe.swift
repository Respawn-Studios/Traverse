import DiskArbitration
import Foundation
import IOKit

/// Read-only metadata for one generated fixture mount. No mutation APIs, whole
/// machine enumeration, user-file content or arbitrary registry properties.
@main
enum DriveCapabilityProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let session = DASessionCreate(kCFAllocatorDefault) else { throw CocoaError(.fileReadUnknown) }
        let mount = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard mount.lastPathComponent == "mount", mount.deletingLastPathComponent().lastPathComponent.hasPrefix("drive-lifecycle-"),
              mount.pathComponents.contains(".build"),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, mount as CFURL) else { throw CocoaError(.fileReadUnknown) }
        let fields: [(String, CFString)] = [("internal", kDADiskDescriptionDeviceInternalKey),
            ("network", kDADiskDescriptionVolumeNetworkKey), ("mountable", kDADiskDescriptionVolumeMountableKey),
            ("ejectable", kDADiskDescriptionMediaEjectableKey), ("removable", kDADiskDescriptionMediaRemovableKey),
            ("whole", kDADiskDescriptionMediaWholeKey), ("protocol", kDADiskDescriptionDeviceProtocolKey),
            ("kind", kDADiskDescriptionMediaKindKey)]
        func description(_ disk: DADisk) -> [String: Any] {
            let data = DADiskCopyDescription(disk) as NSDictionary?
            var result: [String: Any] = [:]
            for (name, key) in fields { result[name] = data?[key] ?? NSNull() }
            let media = DADiskCopyIOMedia(disk)
            if media != IO_OBJECT_NULL {
                defer { IOObjectRelease(media) }
                var registry: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(media, &registry) == KERN_SUCCESS { result["registryID"] = registry }
                if let value = IORegistryEntrySearchCFProperty(media, kIOServicePlane,
                    "Protocol Characteristics" as CFString, kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)) as? [String: Any] {
                    var allowlisted: [String: Any] = [:]
                    for key in ["Physical Interconnect", "Physical Interconnect Location"] {
                        if let value = value[key] as? String { allowlisted[key] = value }
                    }
                    result["protocolCharacteristics"] = allowlisted
                }
            }
            return result
        }
        var result: [String: Any] = ["leaf": description(disk)]
        if let whole = DADiskCopyWholeDisk(disk) { result["wholeDisk"] = description(whole) }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
