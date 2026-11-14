import Darwin
import Foundation

// Directory access is proved before any source body enters this namespace.
// An inherited ACL is refused; this code never edits any source/existing ACL.
internal func textRequirePrivateDirectory(_ anchor: DirectoryAnchor) throws {
    try anchor.validate()
    var facts = stat()
    guard fstat(anchor.fd, &facts) == 0, facts.st_mode & S_IFMT == S_IFDIR,
          facts.st_uid == geteuid(), facts.st_mode & 0o7777 == 0o700 else {
        throw FileOperationFailure.accessDenied
    }
    errno = 0
    if let acl = acl_get_fd_np(anchor.fd, ACL_TYPE_EXTENDED) {
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        errno = 0
        guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1,
              errno == EINVAL else { throw FileOperationFailure.accessDenied }
    } else if errno != ENOENT { throw posixFailure() }
    try anchor.validate()
}

internal func textCreatePrivateDirectory(parent: DirectoryAnchor, name: String, owner: UUID) throws -> DirectoryAnchor {
    try parent.validate(); try validateName(name)
    guard mkdirat(parent.fd, name, 0o700) == 0 else { throw posixFailure() }
    let area = try DirectoryAnchor(parent.url.appendingPathComponent(name), resolve: false)
    try textRequirePrivateDirectory(area)
    guard try GroupedCopyFilesystemEvidence.children(in: area, cancellation: .init(), limit: 1).isEmpty else {
        throw FileOperationFailure.recoveryUncertain
    }
    try OperationJournal.writeExclusive(Data(owner.uuidString.utf8), name: ".traverse-text-owner", anchor: area)
    try textRequirePrivateDirectory(area); try syncDirectory(area); try syncDirectory(parent)
    return area
}
