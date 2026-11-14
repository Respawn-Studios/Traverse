import Foundation

/// A folder is a different source contract, never a fake regular file. File
/// encoding deliberately stays byte-compatible with retained v1/v2 records.
enum SFTPUploadRecordedSource: Sendable, Equatable, Codable {
    case file(SFTPUploadSourceSnapshot), folder(SFTPFolderUploadSourceSnapshot)
    private enum Keys: String, CodingKey { case kind, folder }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if container.contains(.kind) || container.contains(.folder) {
            guard try container.decode(String.self, forKey: .kind) == "folder-v1" else { throw RemoteSettingsFailure.invalidRecord }
            self = .folder(try container.decode(SFTPFolderUploadSourceSnapshot.self, forKey: .folder))
        } else { self = .file(try SFTPUploadSourceSnapshot(from: decoder)) }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .file(let value): try value.encode(to: encoder)
        case .folder(let value):
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode("folder-v1", forKey: .kind); try container.encode(value, forKey: .folder)
        }
    }
    var name: String { switch self { case .file(let v): v.name; case .folder(let v): v.name } }
    var logicalBytes: UInt64 { switch self { case .file(let v): v.logicalBytes; case .folder(let v): v.logicalBytes } }
    var isFolder: Bool { if case .folder = self { true } else { false } }
    func validate() throws { switch self { case .file(let v): try v.validate(); case .folder(let v): try v.validate() } }
}

struct SFTPFolderUploadProgress: Sendable, Equatable, Codable {
    var rootAcknowledged = false
    var verifiedFiles = 0
    var verifiedBytes: UInt64 = 0
}
