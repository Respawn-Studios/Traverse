#if DEBUG
import Foundation

/// The source checkout that compiled these checks, not a user-selected path.
/// Individual checks still validate their generated case, markers and limits.
enum DevelopmentFixturePaths {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let cases = repository.appendingPathComponent(".build/traverse-development", isDirectory: true)
}
#endif
