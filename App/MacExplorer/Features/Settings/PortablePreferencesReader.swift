import Foundation

/// Bounded, no-follow passive read of app configuration. No creation/recovery,
/// hidden fallback or UI work. Cancellation awaits the real serial read.
final class PortablePreferencesReader: Sendable {
    private let queue = DispatchQueue(label: "MacExplorer.PreferenceRead", qos: .userInitiated)
    #if DEBUG
        private let beforeRead: (@Sendable () -> Void)?
        init(beforeRead: (@Sendable () -> Void)? = nil) { self.beforeRead = beforeRead }
    #else
        init() {}
    #endif
    func read(_ file: URL) async throws -> Data? {
        try Task.checkCancellation()
        #if DEBUG
            let beforeRead = beforeRead
        #endif
        let result: Data? = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    #if DEBUG
                        beforeRead?()
                    #endif
                    var store = BrowserSnapshotFile(
                        directory: file.deletingLastPathComponent(), name: file.lastPathComponent, maximumBytes: 131_072
                    )
                    store.requiresPrivateDurability = true
                    let data = try store.read()
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return result
    }
}
