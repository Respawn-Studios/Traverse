import Foundation

@_spi(Qualification) public enum SMBNewItemKind: Sendable, Equatable {
    case textFile, folder
}

/// An explicit empty item sealed to one complete SMB directory observation.
/// The source bytes/manifest are fixed in LocalStorage; no local path or
/// broader source grant can enter this request.
@_spi(Qualification) public struct SMBRequestedNewItem: Sendable, CustomDebugStringConvertible {
    enum Payload: Sendable {
        case file(SMBRequestedUpload), folder(SMBRequestedFolderUpload)
    }
    public let kind: SMBNewItemKind
    public let name: String
    let payload: Payload
    public var debugDescription: String { "<SMB explicit empty item request>" }

    public init(connection: UUID, snapshot: SMBDirectorySnapshot, directory: [SMBRemoteName],
                kind: SMBNewItemKind, name: String) throws {
        self.kind = kind
        switch kind {
        case .textFile:
            let request = try SMBRequestedUpload(connection: connection, snapshot: snapshot,
                directory: directory, generatedEmptyName: name)
            self.name = request.name.displayName; payload = .file(request)
        case .folder:
            let request = try SMBRequestedFolderUpload(connection: connection, snapshot: snapshot,
                directory: directory, generatedEmptyName: name)
            self.name = request.name.displayName; payload = .folder(request)
        }
    }
}

extension SMBBrowserSession {
    /// Uses the existing exclusive U1/F2 upload owners, ledger and verified
    /// no-replace publication. The caller must hold its normal current-tab
    /// operation preparation and present any uncertain Upload Outcome.
    @_spi(Qualification) public func createEmptyItem(_ request: SMBRequestedNewItem,
                                                      storage: SMBUploadStorage) async throws -> UUID {
        switch request.payload {
        case .file(let value): return try await upload(value, storage: storage, excluding: []).id
        case .folder(let value): return try await uploadFolder(value, storage: storage, excluding: []).id
        }
    }
}
