import Foundation

/// Pure typed handoff. It grants no file access and is not proof of a durable
/// intent; the transaction owner must bind its live source and ledger record.
struct SFTPUploadSelection: Sendable, Equatable, CustomDebugStringConvertible {
    let request: UUID, generation: UUID, revision: UInt64
    let directory: String, name: SFTPRemoteName, logicalBytes: UInt64
    var debugDescription: String { "<SFTP fresh upload selection>" }
    var temporaryPath: Data { Data(((directory == "/" ? "" : directory) + "/.mac-explorer-upload-" + request.uuidString.replacingOccurrences(of: "-", with: "") + ".part").utf8) }
    var finalPath: Data { Data((directory == "/" ? "" : directory).utf8) + Data([47]) + name.wireUTF8 }
    init(request: UUID, generation: UUID, revision: UInt64, directory: String, name: SFTPRemoteName, logicalBytes: UInt64) throws {
        guard SFTPWire.validToken(request), SFTPWire.validToken(generation), revision <= UInt64(Int64.max), logicalBytes <= 1 << 30,
              name.wireUTF8.count <= 255, directory.hasPrefix("/"), directory.utf8.count <= 8192, !directory.utf8.contains(0),
              directory == "/" || !directory.hasSuffix("/") && directory.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              directory.split(separator: "/").count <= 127 else { throw SFTPProtocolFailure.invalidInput }
        self.request = request; self.generation = generation; self.revision = revision; self.directory = directory; self.name = name; self.logicalBytes = logicalBytes
        guard temporaryPath.count <= 8192, finalPath.count <= 8192, temporaryPath != finalPath else { throw SFTPProtocolFailure.invalidInput }
    }
    func command() throws -> Data {
        var bytes = SFTPWire.token(request); bytes.append(SFTPWire.token(generation)); SFTPWire.number(revision, bytes: 8, into: &bytes)
        try SFTPWire.field(name.wireUTF8, into: &bytes); SFTPWire.number(logicalBytes, bytes: 8, into: &bytes); return bytes
    }
}
struct SFTPUploadReceipt: Sendable, Equatable, CustomDebugStringConvertible {
    let selection: SFTPUploadSelection, digest: Data
    var debugDescription: String { "<SFTP acknowledged upload receipt>" }
}
@_spi(Qualification) public struct SFTPUploadOpenRefusal: Error, Sendable, CustomDebugStringConvertible {
    let selection: SFTPUploadSelection
    public var debugDescription: String { "<SFTP first open permission refusal>" }
}
@_spi(Qualification) public struct SFTPUploadInterruption: Error, Sendable, CustomDebugStringConvertible {
    public enum Cause: UInt8, Sendable { case input, io, deadline, stopped, truncated, protocolError, status, conflict, unsupportedSync, verification, sourceChanged }
    public enum Phase: UInt8, Sendable { case admission, negotiation, destination, openingTemporary, writing, readback, permissions, syncing, closing, temporaryCheck, authorization, publishing, finalReadback, shutdown, openingFinal }
    let selection: SFTPUploadSelection
    public let cause: Cause, phase: Phase, status: UInt32
    public let temporaryMayExist: Bool, publicationMayHaveHappened: Bool
    public var debugDescription: String { "<SFTP interrupted upload>" }
}
