import Foundation

/// Sidebar ordering uses the existing private preference-file boundary. This
/// serial worker adds no filesystem primitive and grants no file/drive access.
final class BrowserSidebarLayoutFile: BrowserSidebarLayoutPersistence, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Traverse.SidebarLayout")
    private let file: BrowserSnapshotFile

    init(directory: URL) {
        var file = BrowserSnapshotFile(directory: directory, name: "sidebar-layout-v1.json",
                                       maximumBytes: SidebarLayoutPreferences.maximumEncodedBytes)
        file.requiresPrivateDurability = true
        self.file = file
    }
    func load() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in continuation.resume(with: Result { try file.read() }) }
        }
    }
    func save(_ bytes: Data, replacing expectedBytes: Data?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                continuation.resume(with: Result {
                    _ = try SidebarLayoutPreferences.decode(bytes)
                    let expected = expectedBytes.map(BrowserSnapshotFile.ExpectedVersion.bytes) ?? .absent
                    try file.write(bytes, replacing: expected) { _ = try SidebarLayoutPreferences.decode($0) }
                })
            }
        }
    }
}

@MainActor
enum BrowserSidebarLayoutRegistry {
    private final class WeakOwner {
        weak var value: BrowserSidebarLayoutController?
        init(_ value: BrowserSidebarLayoutController) { self.value = value }
    }
    private static var owners: [String: WeakOwner] = [:]
    static func controller(directory: URL?) -> BrowserSidebarLayoutController {
        guard let directory else { return .init() }
        owners = owners.filter { $0.value.value != nil }
        let key = directory.standardizedFileURL.path
        if let owner = owners[key]?.value { return owner }
        let owner = BrowserSidebarLayoutController(persistence: BrowserSidebarLayoutFile(directory: directory))
        owners[key] = WeakOwner(owner)
        return owner
    }
}
