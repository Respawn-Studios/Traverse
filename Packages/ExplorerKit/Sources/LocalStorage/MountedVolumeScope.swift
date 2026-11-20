import Darwin
import DiskArbitration
import Foundation
import IOKit

/// Kernel observations remain private to one action. A nullfs lower path is a
/// current dependency hint, never proof of its historical lower-vnode identity.
internal struct MountScopeObservation: Equatable, Sendable {
    struct Object: Equatable, Sendable {
        let device: Int64
        let inode: UInt64
        let type: UInt16
        let generation: UInt32
        let birthSeconds: Int64
        let birthNanoseconds: Int64
        init(_ value: stat) {
            device = Int64(value.st_dev); inode = value.st_ino; type = value.st_mode & S_IFMT
            generation = value.st_gen
            birthSeconds = Int64(value.st_birthtimespec.tv_sec); birthNanoseconds = Int64(value.st_birthtimespec.tv_nsec)
        }
        init(device: Int64, inode: UInt64) {
            self.device = device; self.inode = inode; type = UInt16(S_IFDIR); generation = 0; birthSeconds = 0; birthNanoseconds = 0
        }
    }
    enum Native: Equatable, Sendable {
        case block(leaf: UInt64, whole: UInt64)
        case noMedia
        case unresolved
    }
    let requested: URL
    let mount: URL
    let source: String
    let fileSystem: String
    let fileSystemID: Int32
    let fileSystemIDExtra: Int32
    let flags: UInt32
    let object: Object
    let parent: Object
    let native: Native
    let nativeNetwork: Bool?
    let nativeProtocol: String?
}

internal final class MountScopeReader {
    private let session: DASession
    init(session: DASession) { self.session = session }
    func observe(_ url: URL) throws -> MountScopeObservation {
        guard url.isFileURL, url == url.standardizedFileURL else { throw VolumeLifecycleFailure.unsupported }
        var object = stat(), parent = stat(), fs = statfs()
        guard lstat(url.path, &object) == 0, stat(url.deletingLastPathComponent().path, &parent) == 0,
              statfs(url.path, &fs) == 0 else { throw VolumeLifecycleFailure.unavailable }
        let type = withUnsafePointer(to: &fs.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        let source = withUnsafePointer(to: &fs.f_mntfromname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let path = withUnsafePointer(to: &fs.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard path.hasPrefix("/"), !type.isEmpty else { throw VolumeLifecycleFailure.unsupported }
        let mount = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, mount as CFURL) else { throw VolumeLifecycleFailure.unsupported }
        let data = DADiskCopyDescription(disk) as NSDictionary?
        let media = DADiskCopyIOMedia(disk)
        let whole = DADiskCopyWholeDisk(disk)
        let native: MountScopeObservation.Native
        if let leafID = VolumeLifecycle.registryID(disk), let scope = try? NativeDeviceReader.observe(disk, session: session).scope {
            native = .block(leaf: leafID, whole: scope.outerWhole)
        } else if media == IO_OBJECT_NULL && whole == nil { native = .noMedia }
        else { native = .unresolved }
        if media != IO_OBJECT_NULL { IOObjectRelease(media) }
        var after = stat(), parentAfter = stat(), fsAfter = statfs()
        guard lstat(url.path, &after) == 0, stat(url.deletingLastPathComponent().path, &parentAfter) == 0,
              statfs(url.path, &fsAfter) == 0,
              MountScopeObservation.Object(object) == MountScopeObservation.Object(after),
              MountScopeObservation.Object(parent) == MountScopeObservation.Object(parentAfter),
              fs.f_fsid.val.0 == fsAfter.f_fsid.val.0, fs.f_fsid.val.1 == fsAfter.f_fsid.val.1,
              fs.f_flags == fsAfter.f_flags,
              withUnsafeBytes(of: fs.f_fstypename, Array.init) == withUnsafeBytes(of: fsAfter.f_fstypename, Array.init),
              withUnsafeBytes(of: fs.f_mntonname, Array.init) == withUnsafeBytes(of: fsAfter.f_mntonname, Array.init),
              withUnsafeBytes(of: fs.f_mntfromname, Array.init) == withUnsafeBytes(of: fsAfter.f_mntfromname, Array.init)
        else { throw VolumeLifecycleFailure.changed }
        return MountScopeObservation(requested: url, mount: mount, source: source, fileSystem: type,
            fileSystemID: fs.f_fsid.val.0, fileSystemIDExtra: fs.f_fsid.val.1, flags: fs.f_flags,
            object: .init(object), parent: .init(parent), native: native,
            nativeNetwork: data?[kDADiskDescriptionVolumeNetworkKey] as? Bool,
            nativeProtocol: data?[kDADiskDescriptionDeviceProtocolKey] as? String)
    }
}

internal struct MountScopeProof: Equatable, Sendable {
    let observations: [URL: MountScopeObservation]
}

/// Bounded observation/reread seam. This resolver does not authorize a drive
/// action; its layered result explicitly lacks original-object provenance.
internal final class MountScopeResolver {
    enum Membership: Equatable {
        case block(group: UInt64, device: Int64)
        case knownDeviceNamespace
        case currentLayer(group: UInt64)
    }
    private let observe: (URL) throws -> MountScopeObservation
    private var observations: [URL: MountScopeObservation] = [:]
    var proof: MountScopeProof { MountScopeProof(observations: observations) }
    init(observe: @escaping (URL) throws -> MountScopeObservation) { self.observe = observe }
    /// Platform enumeration can include a file URL with a base URL. Normalize
    /// that representation before capturing facts; kernel lower paths below
    /// must already be canonical and are not silently repaired.
    func resolve(_ url: URL) throws -> Membership {
        guard url.isFileURL else { throw VolumeLifecycleFailure.unsupported }
        return try resolve(url.standardizedFileURL, visited: [], depth: 0)
    }
    private func resolve(_ url: URL, visited: Set<URL>, depth: Int) throws -> Membership {
        guard depth < 8, !visited.contains(url), observations.count < 4_096,
              url.isFileURL, url == url.standardizedFileURL else { throw VolumeLifecycleFailure.unsupported }
        let value: MountScopeObservation
        if let existing = observations[url] { value = existing }
        else { value = try observe(url); observations[url] = value }
        guard value.requested == url else { throw VolumeLifecycleFailure.changed }
        switch value.native {
        case .block(_, let whole): return .block(group: whole, device: value.object.device)
        case .unresolved: throw VolumeLifecycleFailure.unsupported
        case .noMedia:
            guard value.nativeNetwork == false, value.nativeProtocol == nil,
                  value.flags & UInt32(MNT_LOCAL) != 0 else { throw VolumeLifecycleFailure.unsupported }
            if value.fileSystem == "devicefs", !value.source.isEmpty, !value.source.hasPrefix("/") { return .knownDeviceNamespace }
            guard value.fileSystem == "nullfs", value.source.hasPrefix("/"), !value.source.utf8.contains(0) else { throw VolumeLifecycleFailure.unsupported }
            let source = URL(fileURLWithPath: value.source).standardizedFileURL
            guard source.path == value.source else { throw VolumeLifecycleFailure.unsupported }
            var visited = visited; visited.insert(url)
            switch try resolve(source, visited: visited, depth: depth + 1) {
            case .block(let group, _), .currentLayer(let group): return .currentLayer(group: group)
            case .knownDeviceNamespace: throw VolumeLifecycleFailure.unsupported
            }
        }
    }
    func revalidate() throws {
        for (url, expected) in observations where try observe(url) != expected { throw VolumeLifecycleFailure.changed }
    }

    /// Qualified only for normal OS requests. Known virtual namespaces are not
    /// block-device siblings. A current target-backed layer is refused; an
    /// apparently unrelated layer leaves outstanding-reference checks to macOS.
    func normalDiskMembers(in urls: [URL], group: UInt64) throws -> Set<Int64> {
        guard urls.count <= 512 else { throw VolumeLifecycleFailure.unsupported }
        var devices = Set<Int64>()
        for url in urls {
            switch try resolve(url) {
            case .block(let whole, let device): if whole == group { devices.insert(device) }
            case .knownDeviceNamespace: break
            case .currentLayer(let whole): if whole == group { throw VolumeLifecycleFailure.busy }
            }
        }
        return devices
    }

    func validateProtectedLocation(_ url: URL, devices: Set<Int64>, wholeGroup: UInt64?) throws {
        switch try resolve(url) {
        case .block(let group, let device):
            if devices.contains(device) || group == wholeGroup { throw VolumeLifecycleFailure.protectedStorage }
        case .currentLayer, .knownDeviceNamespace: throw VolumeLifecycleFailure.protectionUncertain
        }
    }

    /// A booted APFS System can be a snapshot. Prove that both explicit
    /// startup mounts resolve to native storage outside the selected image.
    func validateStartupStorage(outside group: UInt64) throws {
        guard group > 0 else { throw VolumeLifecycleFailure.protectionUncertain }
        for path in ["/", "/System/Volumes/Data"] {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            try validateProtectedLocation(url, devices: [], wholeGroup: group)
            guard let value = observations[url], value.mount.path == path, value.fileSystem == "apfs",
                  value.flags & UInt32(MNT_LOCAL) != 0,
                  case .block(let leaf, let whole) = value.native, leaf > 0, whole > 0 else {
                throw VolumeLifecycleFailure.protectionUncertain
            }
        }
        try revalidate()
    }
}
