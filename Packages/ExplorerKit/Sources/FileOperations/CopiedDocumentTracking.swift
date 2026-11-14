import Darwin
import Foundation

/// Qualified metadata preservation on an exclusively created staging descriptor.
/// Native copy omits UF_TRACKED; restoring the flag assigns the copy its own
/// document identity. Never copy a document ID or alter the source descriptor.
internal func preserveCopiedDocumentTracking(source: Int32, destination: Int32) throws {
    var original = stat(), copied = stat()
    guard fstat(source, &original) == 0 else { throw posixFailure() }
    guard original.st_flags & UInt32(UF_TRACKED) != 0 else { return }
    guard fstat(destination, &copied) == 0 else { throw posixFailure() }
    let type = original.st_mode & S_IFMT
    guard type == copied.st_mode & S_IFMT else {
        throw FileOperationFailure.unsupported
    }
    guard type == S_IFREG || type == S_IFDIR else { return }
    guard copied.st_flags & UInt32(UF_TRACKED) == 0 else { return }
    let sourceIdentity = try EntrySnapshot(fd: source), destinationIdentity = try EntrySnapshot(fd: destination)
    guard fchflags(destination, copied.st_flags | UInt32(UF_TRACKED)) == 0 else { throw posixFailure() }
    var after = stat()
    guard fstat(destination, &after) == 0, destinationIdentity.sameObject(as: try EntrySnapshot(fd: destination)),
          after.st_gen == copied.st_gen, after.st_flags == copied.st_flags | UInt32(UF_TRACKED),
          try EntrySnapshot(fd: source) == sourceIdentity else { throw FileOperationFailure.copyMetadataMismatch }
}
