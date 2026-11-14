import ExplorerCore
import Foundation

final class FolderViewStore: @unchecked Sendable {
    struct Snapshot: Sendable { let library: FolderViewPresets; let bytes: Data?; let ordinal: UInt64 }
    enum Failure: Error { case unavailable, stale }
    private let queue = DispatchQueue(label: "MacExplorer.FolderViews", qos: .utility)
    private let directory: URL?
    private let beforeRead: @Sendable () throws -> Void
    private let checkpoint: @Sendable (BrowserSnapshotFile.WriteBoundary) throws -> Void
    private var ordinal: UInt64 = 0
    init(directory: URL?, beforeRead: @escaping @Sendable () throws -> Void = {},
         checkpoint: @escaping @Sendable (BrowserSnapshotFile.WriteBoundary) throws -> Void = { _ in }) {
        self.directory = directory; self.beforeRead = beforeRead; self.checkpoint = checkpoint
    }
    private var file: BrowserSnapshotFile? {
        directory.map { BrowserSnapshotFile(directory: $0, name: "folder-views-v1.json", maximumBytes: 4 << 20, requiresPrivateDurability: true) }
    }
    private func decode(_ bytes: Data) throws -> FolderViewPresets {
        let value = try JSONDecoder().decode(FolderViewPresets.self, from: bytes); try value.validate(); return value
    }
    private func snapshot(_ library: FolderViewPresets, _ bytes: Data?) throws -> Snapshot {
        guard ordinal < .max else { throw Failure.unavailable }; ordinal += 1
        return Snapshot(library: library, bytes: bytes, ordinal: ordinal)
    }
    func load() async throws -> Snapshot {
        try await perform {
            try self.beforeRead()
            guard let file = self.file else { throw Failure.unavailable }
            let bytes = try file.read(expectDocumentInExistingDirectory: true)
            return try self.snapshot(try bytes.map(self.decode) ?? FolderViewPresets(), bytes)
        }
    }
    func edit(expected: Snapshot?, _ mutation: @escaping @Sendable (inout FolderViewPresets) throws -> Void) async throws -> Snapshot {
        try await perform {
            guard let file = self.file else { throw Failure.unavailable }
            let before = try file.read(expectDocumentInExistingDirectory: true)
            if let expected, before != expected.bytes { throw Failure.stale }
            var value = try before.map(self.decode) ?? FolderViewPresets()
            try mutation(&value); try value.validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(value)
            try file.write(bytes, replacing: before.map(BrowserSnapshotFile.ExpectedVersion.bytes) ?? .absent,
                           checkpoint: self.checkpoint) { _ = try self.decode($0) }
            guard try file.read() == bytes else { throw Failure.unavailable }
            return try self.snapshot(value, bytes)
        }
    }
    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in queue.async {
            do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
        } }
    }
    func drain() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
}
