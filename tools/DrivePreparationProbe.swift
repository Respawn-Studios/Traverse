import Darwin
import DiskArbitration
import Foundation
import IOKit

/// Read-only diagnosis for an already attached, positively owned disk image.
/// No perform/unmount/mount/eject call is present in this tool.
@main
enum DrivePreparationProbe {
    static func main() async throws {
        let args = CommandLine.arguments
        let ownedNode = args.count == 4 && args[1] == "--owned-node"
        guard (args.count == 3 || ownedNode), let job = UUID(uuidString: args[ownedNode ? 3 : 2]),
              let session = DASessionCreate(kCFAllocatorDefault) else { throw CocoaError(.fileReadUnknown) }
        let disk: DADisk
        if ownedNode {
            guard let value = DADiskCreateFromBSDName(kCFAllocatorDefault, session, args[2]),
                  let description = DADiskCopyDescription(value) as NSDictionary?,
                  description[kDADiskDescriptionVolumeNameKey] as? String == "MacExplorerDrive-" + job.uuidString
            else { throw CocoaError(.fileReadUnknown) }
            disk = value
        } else {
            let mount = URL(fileURLWithPath: args[1], isDirectory: true)
            let fd = open(mount.appendingPathComponent(".mac-explorer-drive-owner").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
            defer { close(fd) }
            var value = stat(), root = stat()
            guard fstat(fd, &value) == 0, stat(mount.path, &root) == 0,
                  value.st_mode & S_IFMT == S_IFREG, value.st_size == 36, value.st_dev == root.st_dev else { throw CocoaError(.fileReadUnknown) }
            var bytes = [UInt8](repeating: 0, count: 36)
            guard read(fd, &bytes, bytes.count) == 36, String(decoding: bytes, as: UTF8.self) == job.uuidString,
                  let value = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, mount as CFURL)
            else { throw CocoaError(.fileReadUnknown) }
            disk = value
        }
        let binding = try NativeDeviceReader.observe(disk, session: session)
        guard let mediaID = VolumeLifecycle.registryID(disk), let outerBSD = DADiskGetBSDName(binding.ejectDisk)
        else { throw CocoaError(.fileReadUnknown) }
        let backend = VolumeLifecycle.shared
        for await values in backend.updates {
            guard let target = values.first(where: { $0.mediaID == mediaID && $0.group == binding.scope.outerWhole }) else { continue }
            var result: [String: Any] = ["deviceKind": target.deviceKind.rawValue, "canMount": target.canMount,
                "canUnmount": target.canUnmount, "canEject": target.canEject, "mediaID": mediaID,
                "outerMediaID": binding.scope.outerWhole, "nearestWholeID": binding.scope.nearestWhole,
                "outerBSDName": String(cString: outerBSD), "providerNodes": binding.scope.nodes.count,
                "mount": target.url?.path as Any? ?? NSNull(), "mountDevice": target.fileSystemID as Any? ?? NSNull()]
            do {
                let plan = try await backend.prepare(target, action: .eject, protecting: [])
                result["preparation"] = "passed"; result["affectedVolumes"] = plan.affected.count
            } catch { result["preparation"] = String(describing: error) }
            if let session = DASessionCreate(kCFAllocatorDefault),
               let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey], options: []) {
                let reader = MountScopeReader(session: session)
                let resolver = MountScopeResolver(observe: reader.observe)
                var counts = [String: Int]()
                do {
                    for url in urls where try url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal != false {
                        switch try resolver.resolve(url) {
                        case .block: counts["nativeBlock", default: 0] += 1
                        case .knownDeviceNamespace: counts["knownDeviceNamespace", default: 0] += 1
                        case .currentLayer(let group): counts[group == target.group ? "targetLayer" : "apparentlyUnrelatedLayer", default: 0] += 1
                        }
                    }
                    try resolver.revalidate()
                    result["currentDependencyCandidate"] = "stable read-only observations; no historical backing proof"
                } catch { result["currentDependencyCandidate"] = String(describing: error) }
                result["candidateCounts"] = counts
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            print(String(decoding: data, as: UTF8.self)); return
        }
    }
}
