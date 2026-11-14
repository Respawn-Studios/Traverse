import CryptoKit
import Darwin
import Foundation

internal struct TextNativeMetadataV2 {
    struct Attribute: Encodable { let name: String, bytes: Int, digest: RevisionDigest }
    struct Plain: Encodable {
        let mode: UInt16, uid: UInt32, gid: UInt32, flags: UInt32
        let birth: RevisionTime, acl: RevisionDigest, attributes: [Attribute]
    }
    let plain: RevisionDigest, security: RevisionDigest
    let bytes: UInt64
    init(_ fd: Int32) throws {
        var facts = stat(); guard fstat(fd, &facts) == 0 else { throw posixFailure() }
        let length = flistxattr(fd, nil, 0, 0)
        guard length >= 0 else { throw posixFailure() }
        guard length <= 65_536 else { throw FileOperationFailure.unsupported }
        var list = [CChar](repeating: 0, count: max(1, length))
        guard flistxattr(fd, &list, length, 0) == length else { throw FileOperationFailure.sourceChanged }
        var attributes: [Attribute] = [], marks: [Attribute] = []
        var total = length
        for nameBytes in list.prefix(length).split(separator: 0) {
            guard let name = String(bytes: nameBytes.map({ UInt8(bitPattern: $0) }), encoding: .utf8) else { throw FileOperationFailure.unsupported }
            let count = fgetxattr(fd, name, nil, 0, 0, 0)
            guard count >= 0 else { throw posixFailure() }
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow, next <= 262_144 else { throw FileOperationFailure.unsupported }; total = next
            var value = Data(count: count)
            guard value.withUnsafeMutableBytes({ fgetxattr(fd, name, $0.baseAddress, count, 0, 0) }) == count else { throw FileOperationFailure.sourceChanged }
            let item = Attribute(name: name, bytes: count, digest: .bytes(value))
            if name == CopySecurity.quarantineName || name == CopySecurity.provenanceName { marks.append(item) }
            else { attributes.append(item) }
        }
        var aclBytes = Data(); errno = 0
        if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var count: ssize_t = 0
            guard let text = acl_to_text(acl, &count) else { throw posixFailure() }
            defer { acl_free(UnsafeMutableRawPointer(text)) }
            guard count >= 0, count <= 262_144 - total else { throw FileOperationFailure.unsupported }
            aclBytes = Data(bytes: text, count: count); total += count
        } else if errno != ENOENT { throw posixFailure() }
        plain = .bytes(try textEncoded(Plain(mode: facts.st_mode, uid: facts.st_uid, gid: facts.st_gid,
            flags: facts.st_flags, birth: .init(seconds: Int64(facts.st_birthtimespec.tv_sec), nanos: facts.st_birthtimespec.tv_nsec),
            acl: .bytes(aclBytes), attributes: attributes.sorted { $0.name < $1.name })))
        security = .bytes(try textEncoded(marks.sorted { $0.name < $1.name })); bytes = UInt64(total)
    }
}

internal func textDocumentID(_ fd: Int32) throws -> UInt32 {
    var attributes = attrlist(); attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_DOCUMENT_ID)
    var values = [UInt32](repeating: 0, count: 7)
    let result = values.withUnsafeMutableBytes { fgetattrlist(fd, &attributes, $0.baseAddress, $0.count, UInt32(FSOPT_ATTR_CMN_EXTENDED)) }
    guard result == 0 else { throw posixFailure() }
    guard values[0] == 28, values[1] & UInt32(ATTR_CMN_DOCUMENT_ID) != 0 else { throw FileOperationFailure.unsupported }
    return values[6]
}

internal func textReadBytes(_ fd: Int32, cancellation: OperationCancellation) throws -> Data {
    let before = try EntrySnapshot(fd: fd)
    guard before.type == S_IFREG, before.size >= 0, before.size <= 1_048_576 else { throw FileOperationFailure.unsupported }
    var bytes = Data(count: Int(before.size))
    try bytes.withUnsafeMutableBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            try cancellation.check()
            let count = pread(fd, buffer.baseAddress!.advanced(by: offset), min(16_384, buffer.count - offset), off_t(offset))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw FileOperationFailure.sourceChanged }; offset += count
        }
    }
    guard try EntrySnapshot(fd: fd) == before else { throw FileOperationFailure.sourceChanged }; return bytes
}

internal func textProjection(_ fd: Int32, volume: UUID, cancellation: OperationCancellation = .init()) throws -> RevisionWitness {
    let before = try EntrySnapshot(fd: fd)
    var facts = stat(); guard fstat(fd, &facts) == 0 else { throw posixFailure() }
    guard facts.st_mode & S_IFMT == S_IFREG, facts.st_uid == geteuid(), facts.st_nlink <= 1,
          facts.st_size >= 0, facts.st_size <= 1_048_576,
          facts.st_flags == 0 || facts.st_flags == UInt32(UF_TRACKED) else { throw FileOperationFailure.unsupported }
    let metadata = try TextNativeMetadataV2(fd), body = try textReadBytes(fd, cancellation: cancellation)
    let document = try textDocumentID(fd)
    guard try EntrySnapshot(fd: fd) == before else { throw FileOperationFailure.sourceChanged }
    let value = RevisionWitness(volume: volume, device: UInt64(UInt32(bitPattern: facts.st_dev)), inode: facts.st_ino,
        birth: .init(seconds: Int64(facts.st_birthtimespec.tv_sec), nanos: facts.st_birthtimespec.tv_nsec),
        modified: .init(seconds: Int64(facts.st_mtimespec.tv_sec), nanos: facts.st_mtimespec.tv_nsec),
        changed: .init(seconds: Int64(facts.st_ctimespec.tv_sec), nanos: facts.st_ctimespec.tv_nsec),
        links: UInt8(facts.st_nlink), bytes: UInt64(facts.st_size), body: .bytes(body),
        metadata: metadata.plain, security: metadata.security, flags: facts.st_flags, document: document)
    try value.validate(); return value
}

internal final class TextPinnedFileV2 {
    let url: URL, parent: DirectoryAnchor, fd: Int32, volume: UUID
    let volumeBinding: PersistentVolumeBinding
    let witness: RevisionWitness
    let bytes: Data
    init(_ url: URL, cancellation: OperationCancellation = .init()) throws {
        guard url.isFileURL, url == url.standardizedFileURL, url.query == nil, url.fragment == nil, url.baseURL == nil,
              url.path != "/", url.resolvingSymlinksInPath() == url else { throw FileOperationFailure.unsupported }
        try validateName(url.lastPathComponent)
        self.url = url; parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
        // This first profile shares the already-qualified case-preserving,
        // case-insensitive local APFS namespace. Other layouts refuse explicitly.
        guard let native = try NativeRenameVolume.qualified(in: parent),
              let binding = try PersistentVolumeBinding.qualified(in: parent),
              native.device == binding.device, native.uuid == binding.uuid else { throw FileOperationFailure.unsupported }
        try preflightPrivateTextCopyEntry(parent: parent.fd, name: url.lastPathComponent)
        let resources = try url.resourceValues(forKeys: [.isAliasFileKey, .isUbiquitousItemKey])
        guard resources.isAliasFile == false, resources.isUbiquitousItem != true else { throw FileOperationFailure.unsupported }
        volumeBinding = binding; volume = binding.uuidValue
        let descriptor = openat(parent.fd, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixFailure() }
        do {
            var filesystem = statfs(); guard fstatfs(descriptor, &filesystem) == 0 else { throw posixFailure() }
            let kind = withUnsafeBytes(of: filesystem.f_fstypename) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            guard kind == "apfs", filesystem.f_flags & UInt32(MNT_LOCAL | MNT_RDONLY) == UInt32(MNT_LOCAL) else { throw FileOperationFailure.unsupported }
            guard try EntrySnapshot(parent: parent.fd, name: url.lastPathComponent) == EntrySnapshot(fd: descriptor),
                  try EntrySnapshot(fd: descriptor).device == binding.device else { throw FileOperationFailure.sourceChanged }
            let observed = try textProjection(descriptor, volume: volume, cancellation: cancellation)
            guard observed.links == 1 else { throw FileOperationFailure.sourceChanged }
            bytes = try textReadBytes(descriptor, cancellation: cancellation); witness = observed
            guard RevisionDigest.bytes(bytes) == observed.body,
                  try textProjection(descriptor, volume: volume, cancellation: cancellation) == observed else { throw FileOperationFailure.sourceChanged }
            try parent.validate(); fd = descriptor
        } catch { close(descriptor); throw error }
    }
    deinit { close(fd) }
    func validate(_ expected: RevisionWitness? = nil, cancellation: OperationCancellation = .init()) throws {
        try parent.validate()
        guard try PersistentVolumeBinding.qualified(in: parent) == volumeBinding else { throw FileOperationFailure.sourceChanged }
        let target = expected ?? witness
        guard try textProjection(fd, volume: volume, cancellation: cancellation) == target,
              try EntrySnapshot(parent: parent.fd, name: url.lastPathComponent) == EntrySnapshot(fd: fd) else { throw FileOperationFailure.sourceChanged }
    }
}

@discardableResult internal func textPrivateCopy(_ source: URL, _ target: URL, cancellation: OperationCancellation) throws -> RevisionCopySeal {
    let pinned = try TextPinnedFileV2(source, cancellation: cancellation)
    let from = CopyComparison(), to = CopyComparison(), receipts = NativeCopyReceipts()
    _ = try verifiedTree(source, cancellation: cancellation, copyComparison: from, requiresMaterialized: true)
    let parent = try DirectoryAnchor(target.deletingLastPathComponent(), resolve: false)
    try copyVerifiedNode(sourceParent: pinned.parent.fd, sourceName: source.lastPathComponent,
        destinationParent: parent.fd, destinationName: target.lastPathComponent,
        originalDevice: pinned.parent.identity.device, cancellation: cancellation,
        nativeProfile: .privateTextRevisionV1, securityReceipt: { try receipts.append($0) })
    _ = try verifiedTree(target, cancellation: cancellation, copyComparison: to, requiresMaterialized: true)
    try receipts.validate(source: from, destination: to, policy: .strict); try pinned.validate(cancellation: cancellation)
    let copy = try TextPinnedFileV2(target, cancellation: cancellation)
    let seal = RevisionCopySeal(profile: .apfsNewMetadataPrivateBirthV1, source: pinned.witness,
        copy: copy.witness, metadataBytes: try TextNativeMetadataV2(pinned.fd).bytes)
    try seal.validate(); try textSync(copy.fd); try syncDirectory(parent); return seal
}

internal func textSync(_ fd: Int32) throws {
    guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw posixFailure() }
}
internal func textWriteEdited(_ bytes: Data, to url: URL) throws {
    let fd = open(url.path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
    guard ftruncate(fd, 0) == 0 else { throw posixFailure() }
    try bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw posixFailure() }; offset += count
        }
    }
    try textSync(fd)
}
