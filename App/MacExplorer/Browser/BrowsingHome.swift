import Foundation
import LocalStorage

/// Resolve once off-main before ordinary browser composition. The URL carries
/// no scope and never replaces Application Support/Caches container locations.
@MainActor enum BrowsingHome {
    private(set) static var url: URL?
    private static var resolved = false
    private static var pending: Task<URL?, Never>?
    static func prepare() async {
        guard !resolved else { return }
        let task: Task<URL?, Never>
        if let pending { task = pending }
        else {
            task = Task { try? await UserAccountHome.resolve() }
            pending = task
        }
        let found = await task.value
        guard !Task.isCancelled else { return }
        url = found; resolved = true; pending = nil
    }
    static func completionHome(for text: String) -> URL? {
        // The completion parser never uses home for an absolute path. Do not
        // invent a home for tilde input when the account lookup was unavailable.
        text.hasPrefix("~") ? url : url ?? URL(fileURLWithPath: "/", isDirectory: true)
    }
    #if DEBUG
    /// The sidebar check exits before ordinary account-Home preparation. Give
    /// it an explicit generated Home without consulting or listing the owner’s.
    static func withGeneratedSidebarHome(_ home: URL, root: URL, work: @MainActor () async throws -> Void) async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard ProcessInfo.processInfo.arguments.contains("--check-sidebar-layout") else {
            throw UIVerification.Failure(message: "Generated sidebar Home scope refused")
        }
        let admitted = try await Task.detached {
            guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development"),
                  UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
                  home == root.appendingPathComponent("source/Sidebar Home", isDirectory: true),
                  root.resolvingSymlinksInPath() == root, home.resolvingSymlinksInPath() == home else { return false }
            let bytes = try Data(contentsOf: root.appendingPathComponent("reservation.json"))
            guard bytes.count <= 4096, let marker = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
            return marker["packet"] as? String == "traverse-development-v1" && marker["action"] as? String == "native-sidebar-layout"
        }.value
        guard admitted else { throw UIVerification.Failure(message: "Generated sidebar Home scope refused") }
        let previous = url; url = home
        defer { url = previous }
        try await work()
    }

    static func withGeneratedHome(_ home: URL, root: URL, work: @MainActor () async throws -> Void) async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard ProcessInfo.processInfo.arguments.contains("--check-onboarding-access"),
            root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),
            UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
            home.path.hasPrefix(root.appendingPathComponent("source").path + "/"),
            root.resolvingSymlinksInPath() == root, home.resolvingSymlinksInPath() == home else {
            throw UIVerification.Failure(message: "Generated Home scope refused")
        }
        let previous = url; url = home
        defer { url = previous }
        try await work()
    }
    #endif
}
