import ExplorerCore
import Foundation

/// One serial background owner. Callers receive validated UI templates, never
/// file handles or filesystem authority from their saved locations.
final class LaunchProfileStore: @unchecked Sendable {
    struct Snapshot: Sendable {
        let library: WorkspaceLaunchProfiles
        let exists: Bool
        var revision: UUID? { exists ? library.revision : nil }
    }
    private let queue = DispatchQueue(label: "MacExplorer.LaunchProfiles", qos: .utility)
    private let directory: URL?
    #if DEBUG
    private var checkpointForVerification: (@Sendable (BrowserSnapshotFile.WriteBoundary) throws -> Void)?
    #endif
    init(directory: URL?) { self.directory = directory }
    private var file: BrowserSnapshotFile? {
        directory.map {
            var value = BrowserSnapshotFile(directory: $0, name: "launch-profiles-v1.json", maximumBytes: 4_194_304)
            // Keep the existing format and passive legacy reads. Explicit edits
            // establish the shared writer inode and synchronize publication.
            value.requiresPrivateDurability = true
            return value
        }
    }
    private func decode(_ bytes: Data) throws -> WorkspaceLaunchProfiles {
        let library = try JSONDecoder().decode(WorkspaceLaunchProfiles.self, from: bytes)
        try library.validate(); return library
    }
    func load() async throws -> Snapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let file else { throw WorkspaceLaunchProfiles.Failure.invalidDocument }
                    guard let bytes = try file.read() else { continuation.resume(returning: Snapshot(library: .init(), exists: false)); return }
                    continuation.resume(returning: Snapshot(library: try decode(bytes), exists: true))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func edit(expected: UUID?, _ mutation: @escaping @Sendable (inout WorkspaceLaunchProfiles) throws -> Void) async throws -> Snapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let file else { throw WorkspaceLaunchProfiles.Failure.invalidDocument }
                    let before = try file.read()
                    var library = try before.map(decode) ?? WorkspaceLaunchProfiles()
                    guard (before == nil ? nil : library.revision) == expected else { throw WorkspaceLaunchProfiles.Failure.stale }
                    try mutation(&library); try library.validate()
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let bytes = try encoder.encode(library)
                    try file.write(bytes, replacing: before.map(BrowserSnapshotFile.ExpectedVersion.bytes) ?? .absent,
                        checkpoint: { boundary in
                            #if DEBUG
                            try self.checkpointForVerification?(boundary)
                            #endif
                        }, validating: { _ = try self.decode($0) })
                    continuation.resume(returning: Snapshot(library: library, exists: true))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func drain() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    #if DEBUG
    func setCheckpointForVerification(_ checkpoint: (@Sendable (BrowserSnapshotFile.WriteBoundary) throws -> Void)?) async {
        await withCheckedContinuation { continuation in queue.async { self.checkpointForVerification = checkpoint; continuation.resume() } }
    }
    #endif
}
