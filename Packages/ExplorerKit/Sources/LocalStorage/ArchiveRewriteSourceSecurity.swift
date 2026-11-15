import Darwin
import Foundation
@_spi(ArchiveProduction) import FileOperations

/// Root metadata that a rewritten archive can preserve. The native stage keeps
/// its own quarantine; these source bytes are only a revalidation witness.
internal struct ArchiveRewriteSourceSecurity: Equatable, Sendable {
    let witness: ZIPSourceSecurity.CreationInputWitness
    let mode: mode_t, owner: uid_t, group: gid_t, flags: UInt32
    var marked: Bool { witness.marked }
    init(_ source: PinnedLocalFileSource) throws {
        var facts = stat()
        guard fstat(source.descriptor, &facts) == 0, facts.st_nlink == 1,
              facts.st_uid == geteuid(), [mode_t(0o600), mode_t(0o644)].contains(facts.st_mode & 0o7777),
              facts.st_flags == 0 || facts.st_flags == UInt32(UF_TRACKED) else {
            throw TARMemberEditFailure.unsupportedArchive
        }
        errno = 0
        if let acl = acl_get_fd_np(source.descriptor, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(acl)); throw TARMemberEditFailure.unsupportedArchive
        }
        guard errno == ENOENT else { throw TARMemberEditFailure.unsupportedArchive }
        let count = flistxattr(source.descriptor, nil, 0, 0)
        guard count >= 0, count <= 4_096 else { throw TARMemberEditFailure.unsupportedArchive }
        var names = [CChar](repeating: 0, count: max(1, count))
        guard flistxattr(source.descriptor, &names, count, 0) == count else { throw FileOperationFailure.sourceChanged }
        for name in names.prefix(count).split(separator: 0) {
            let bytes = name.map { UInt8(bitPattern: $0) }
            guard bytes.elementsEqual("com.apple.quarantine".utf8) || bytes.elementsEqual("com.apple.provenance".utf8) else {
                throw TARMemberEditFailure.unsupportedArchive
            }
        }
        witness = try ZIPSourceSecurity.creationInputWitness(source.descriptor, url: source.url, allowingNativeMark: true)
        mode = facts.st_mode & 0o7777; owner = facts.st_uid; group = facts.st_gid; flags = facts.st_flags
    }
}
