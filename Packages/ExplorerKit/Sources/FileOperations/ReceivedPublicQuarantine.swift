import Darwin
import Foundation

/// V14 checks the documented public quarantine view while pinning the same
/// regular file on both sides of Foundation's path-based observation. Presence
/// is an admission witness, not a claim about Gatekeeper or raw mark equality.
internal func requireReceivedPublicQuarantine(parent: DirectoryAnchor, name: String,
    descriptor: Int32, identity: EntrySnapshot) throws {
    try parent.validate()
    let before = try EntrySnapshot(parent: parent.fd, name: name)
    var facts = stat()
    guard before.sameObject(as: identity), try EntrySnapshot(fd: descriptor) == before,
          fstat(descriptor, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG,
          facts.st_nlink == 1, facts.st_uid == geteuid() else {
        throw FileOperationFailure.copyMetadataMismatch
    }
    let properties = try parent.url.appendingPathComponent(name)
        .resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
    guard properties?.isEmpty == false else { throw FileOperationFailure.copyMetadataMismatch }
    try parent.validate()
    guard try EntrySnapshot(fd: descriptor) == before,
          try EntrySnapshot(parent: parent.fd, name: name) == before else {
        throw FileOperationFailure.copyMetadataMismatch
    }
}
