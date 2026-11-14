import Darwin
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

struct FolderUploadFixture {
    let root: URL, packet: URL
    var tree: URL { root.appendingPathComponent("Generated Folder") }
    var history: URL { root.appendingPathComponent("upload-history") }
    init(fixed: String? = nil) throws {
        guard let raw = ProcessInfo.processInfo.environment["TRAVERSE_EXCLUSIVE_UPLOAD_TEST_ROOT"] else {
            guard fixed == nil else { throw XCTSkip("Actual crash controls require their explicit process fixture") }
            root = try LocalStorageTestFixtures.directory(); packet = root
            try FileManager().createDirectory(at: tree, withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: 0o700])
            return
        }
        packet = URL(fileURLWithPath: raw)
        guard packet.resolvingSymlinksInPath() == packet, UUID(uuidString: packet.lastPathComponent) != nil,
              packet.deletingLastPathComponent().lastPathComponent == "traverse-development",
              #filePath.hasPrefix(packet.path + "/source/package/"),
              let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: packet.appendingPathComponent("reservation.json"))) as? [String: Any],
              marker["packet"] as? String == "traverse-development-v1" else { throw RemoteSettingsFailure.unsafe }
        let modes = ["prepared", "publication", "root", "progress", "final", "upgrade"].flatMap { name in ["h-crash-" + name + "-stage", "h-crash-" + name + "-rename"] }
        guard fixed == nil || modes.contains(fixed!) else { throw RemoteSettingsFailure.unsafe }
        root = packet.appendingPathComponent("source/UploadFixtures/" + (fixed ?? UUID().uuidString))
        if !FileManager().fileExists(atPath: root.path) { try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        if !FileManager().fileExists(atPath: tree.path) { try FileManager().createDirectory(at: tree, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    }
    func file(_ relative: String, _ bytes: Data = Data("Generated folder member".utf8)) throws {
        try bytes.write(to: tree.appendingPathComponent(relative), options: .withoutOverwriting)
    }
    func folder(_ relative: String) throws { try FileManager().createDirectory(at: tree.appendingPathComponent(relative), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    func prepare(probe: (@Sendable () throws -> Void)? = nil) async throws -> SFTPFolderUploadSource {
        try await SFTPFolderUploadSource.prepare(tree, excluding: [], readProbe: probe)
    }
    func image() throws -> [String: Data] {
        guard FileManager().fileExists(atPath: history.path) else { return [:] }
        return try Dictionary(uniqueKeysWithValues: FileManager().contentsOfDirectory(atPath: history.path).map { ($0, try Data(contentsOf: history.appendingPathComponent($0))) })
    }
    func key() throws -> SFTPHostKey {
        var key = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &key); try SFTPWire.field(Data(repeating: 1, count: 32), into: &key); return try SFTPHostKey(key)
    }
    func remember(_ ledger: SFTPUploadLedger, _ snapshot: SFTPFolderUploadSourceSnapshot, revision: UInt64 = 0) async throws -> UUID {
        let result = try await ledger.prepareFolder(host: .init(address: SFTPConnectionAddress("sftp://generated.invalid/")), account: "generated", key: key(),
            directory: "/generated", name: "New Folder", source: snapshot, revision: revision)
        return try XCTUnwrap(result.record?.id)
    }
}

