import Darwin
import Foundation

/// Immutable root facts only; no retained source FD, permission or catalog.
/// Constructed on the scan worker from its already verified root descriptors.
struct AnalysisLocationSourceScope: Sendable {
    struct Root: Sendable {
        let url: URL
        let identity: AnalysisObjectIdentity
        let physical: StartupNativeIdentity?
        let stamp: Stamp
        let fsid0: Int32, fsid1: Int32
        let isAPFS: Bool
        init(url: URL, descriptor: Int32, identity: AnalysisObjectIdentity, physical: StartupNativeIdentity? = nil) throws {
            var value = stat(), filesystem = statfs()
            guard fstat(descriptor, &value) == 0, fstatfs(descriptor, &filesystem) == 0,
                  value.st_mode & S_IFMT == S_IFDIR, Self.identity(value) == identity,
                  filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw StorageScanFailure.changed }
            self.url = url.standardizedFileURL; self.identity = identity; self.physical = physical
            stamp = Stamp(value); fsid0 = filesystem.f_fsid.val.0; fsid1 = filesystem.f_fsid.val.1
            isAPFS = withUnsafeBytes(of: &filesystem.f_fstypename) { bytes in
                bytes.prefix(while: { $0 != 0 }).elementsEqual(Array("apfs".utf8))
            }
        }
        struct Stamp: Equatable, Sendable {
            let device: Int32, inode: UInt64, generation: UInt32
            let birthSeconds: Int, birthNanoseconds: Int
            init(_ value: stat) {
                device = value.st_dev; inode = value.st_ino; generation = value.st_gen
                birthSeconds = value.st_birthtimespec.tv_sec; birthNanoseconds = value.st_birthtimespec.tv_nsec
            }
        }
        private static func identity(_ value: stat) -> AnalysisObjectIdentity {
            .init(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: value.st_ino)
        }
        func openNamed() throws -> Int32 {
            let fd = url.withUnsafeFileSystemRepresentation { $0.map { open($0, O_EVTONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) } ?? -1 }
            guard fd >= 0 else { throw nativeFailure() }
            do { try validateRoot(fd); return fd } catch { close(fd); throw error }
        }
        func validateRoot(_ fd: Int32) throws {
            var value = stat(), filesystem = statfs()
            guard fstat(fd, &value) == 0, fstatfs(fd, &filesystem) == 0 else { throw nativeFailure() }
            guard value.st_mode & S_IFMT == S_IFDIR, Stamp(value) == stamp,
                  filesystem.f_flags & UInt32(MNT_LOCAL) != 0,
                  filesystem.f_fsid.val.0 == fsid0, filesystem.f_fsid.val.1 == fsid1,
                  value.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0 else { throw StorageScanFailure.changed }
            if let physical {
                let observed = try physicalFields(fd)
                guard observed.device == physical.realDevice, observed.inode == physical.realInode,
                      observed.realFSID0 == physical.realFSID0, observed.realFSID1 == physical.realFSID1 else { throw StorageScanFailure.changed }
                var attributes = attrlist(); attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
                attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_UUID)
                var bytes = [UInt8](repeating: 0, count: 40)
                guard fgetattrlist(fd, &attributes, &bytes, bytes.count, 0) == 0,
                      try StartupNativeRoot.decodeVolume(Data(bytes)) == physical.volume else { throw StorageScanFailure.changed }
            }
        }
        func validate(_ fd: Int32, step: StoredAnalysisLocationReference.Step) throws {
            var value = stat(), filesystem = statfs()
            guard fstat(fd, &value) == 0, fstatfs(fd, &filesystem) == 0 else { throw nativeFailure() }
            let type = value.st_mode & S_IFMT
            guard type == (step.kind == .directory ? S_IFDIR : S_IFREG), value.st_flags == step.flags,
                  value.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0,
                  filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw StorageScanFailure.changed }
            let current: AnalysisObjectIdentity
            if let physical {
                let fields = try physicalFields(fd)
                guard fields.realDevice == physical.realDevice,
                      fields.realFSID0 == physical.realFSID0, fields.realFSID1 == physical.realFSID1 else { throw StorageScanFailure.changed }
                current = .init(device: UInt64(fields.device), inode: fields.inode)
            } else {
                guard filesystem.f_fsid.val.0 == fsid0, filesystem.f_fsid.val.1 == fsid1 else { throw StorageScanFailure.changed }
                current = Self.identity(value)
            }
            guard current == step.identity else { throw StorageScanFailure.changed }
        }
        private func physicalFields(_ fd: Int32) throws -> StartupNativeRoot.ExtendedFields {
            var attributes = attrlist(); attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_DEVID) | UInt32(ATTR_CMN_FILEID)
            attributes.forkattr = UInt32(ATTR_CMNEXT_REALDEVID | ATTR_CMNEXT_REALFSID)
            var bytes = [UInt8](repeating: 0, count: 48)
            guard fgetattrlist(fd, &attributes, &bytes, bytes.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_RETURN_REALDEV)) == 0 else {
                throw nativeFailure()
            }
            return try StartupNativeRoot.decode(Data(bytes))
        }
    }
    let roots: [UInt64: Root]
    let policy: AnalysisMetadataPolicy
    var supportsResolution: Bool { !roots.isEmpty && roots.values.allSatisfy(\.isAPFS) }

    func resolve(_ reference: StoredAnalysisLocationReference, cancelled: () -> Bool,
                 betweenChecks: (() throws -> Void)? = nil) throws -> ResolvedAnalysisLocation {
        let previousPolicy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        guard previousPolicy >= 0 else { throw StorageScanFailure.unsupportedLocation }
        defer { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previousPolicy) }
        guard setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0,
              getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF else {
            throw StorageScanFailure.unsupportedLocation
        }
        guard [64,128].contains(reference.maximumPathComponents), reference.chain.count <= reference.maximumPathComponents,
              let source = roots[reference.source] else { throw StorageScanFailure.invalidOutput }
        guard source.isAPFS else { throw StorageScanFailure.unsupportedLocation }
        var location = source.url
        for step in reference.chain {
            guard step.flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0 else { throw StorageScanFailure.unsupportedLocation }
            guard let name = String(data: step.name, encoding: .utf8), Data(name.utf8) == step.name else { throw StorageScanFailure.unsupportedLocation }
            location.appendPathComponent(name, isDirectory: step.kind == .directory)
            guard !StorageAnalysisPolicy.excludes(location, policy: policy) else { throw StorageScanFailure.unsupportedLocation }
        }
        // These navigation consumers use native URL/path APIs. Do not hand a
        // lossy or over-PATH_MAX path to another UI and imply it was resolved.
        guard location.path.utf8.count < 1024 else { throw StorageScanFailure.unsupportedLocation }
        func walk() throws {
            if cancelled() { throw CancellationError() }
            let root = try source.openNamed(); defer { close(root) }
            var current = root, owned = false
            defer { if owned { close(current) } }
            for step in reference.chain {
                if cancelled() { throw CancellationError() }
                // Names were validated and UTF-8 round-tripped above. Open one
                // component at a time; no symlink resolution or recursive walk.
                let name = String(data: step.name, encoding: .utf8)!
                let next = openat(current, name, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW_ANY | (step.kind == .directory ? O_DIRECTORY : 0))
                guard next >= 0 else { throw nativeFailure() }
                do { try source.validate(next, step: step) } catch { close(next); throw error }
                if owned { close(current) }; current = next; owned = true
            }
            try source.validateRoot(root)
            if cancelled() { throw CancellationError() }
        }
        try walk()
        try betweenChecks?()
        // Reopen the named root and all parents, not just the held leaf. This
        // catches replacement/reparenting during the first metadata pass.
        try walk()
        let rootIdentity = source.physical.map { AnalysisObjectIdentity(device: UInt64($0.realDevice), inode: $0.realInode) } ?? source.identity
        return .init(url: location, kind: reference.chain.last?.kind ?? .directory, sourceID: reference.source,
            recordedIdentity: reference.chain.last?.identity ?? rootIdentity, isSourceRoot: reference.chain.isEmpty)
    }
}

private func nativeFailure() -> StorageScanFailure {
    errno == EACCES || errno == EPERM ? .accessDenied : .unavailable
}
