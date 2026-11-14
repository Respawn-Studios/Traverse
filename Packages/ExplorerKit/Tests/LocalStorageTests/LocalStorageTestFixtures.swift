import Foundation

/// Ordinary package tests share one ignored root. Explicit historical packets
/// keep validating their own inputs in the caller; they are not needed here.
enum LocalStorageTestFixtures {
    static func directory() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let base = repo.appendingPathComponent(".build/test-fixtures", isDirectory: true)
        guard base.resolvingSymlinksInPath().path == base.path else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        let root = base.appendingPathComponent("local-storage-" + UUID().uuidString, isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false,
                                         attributes: [.posixPermissions: 0o700])
        return root
    }
}
