import AppKit

@MainActor
enum DriveDiskUtilityHandoff {
    static func open() -> Bool {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.DiskUtility") else {
            return false
        }
        return NSWorkspace.shared.open(application)
    }
}
