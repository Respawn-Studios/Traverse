import Foundation

/// One-hop receive composition remains separate from ordinary route browsing
/// until its native/independent gates pass. No persistent preference migration.
@MainActor enum SFTPRoutedDownloadFeature {
    static let enabled = true
    #if DEBUG
    static var qualifying = false
    static var available: Bool { qualifying || enabled }
    #else
    static var available: Bool { enabled }
    #endif
}
