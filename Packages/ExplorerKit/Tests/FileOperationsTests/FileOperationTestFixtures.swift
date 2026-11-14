import Foundation
@testable import FileOperations

/// Shared generated root for ordinary package tests. Older explicit packets may
/// still supply their exact repository-owned root; neither mode grants access.
enum FileOperationTestFixtures {
    static func base(legacyVariable: String? = nil, legacyParent: String? = nil) throws -> URL {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        if let legacyVariable, let text = ProcessInfo.processInfo.environment[legacyVariable] {
            let base = URL(fileURLWithPath: text)
            let repo = package.deletingLastPathComponent().deletingLastPathComponent()
            guard let legacyParent, base.lastPathComponent == "source",
                  base.resolvingSymlinksInPath() == base,
                  base.deletingLastPathComponent().deletingLastPathComponent()
                    == repo.appendingPathComponent(".build/" + legacyParent),
                  UUID(uuidString: base.deletingLastPathComponent().lastPathComponent)?.uuidString
                    == base.deletingLastPathComponent().lastPathComponent else {
                throw FileOperationFailure.invalidRequest
            }
            return base
        }
        let base = package.appendingPathComponent(".build/test-fixtures", isDirectory: true)
        guard base.resolvingSymlinksInPath().path == base.path else {
            throw FileOperationFailure.invalidRequest
        }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        return base
    }
}
