import Foundation
import LocalStorage

struct DriveProtectionLibrary: Codable, Equatable, Sendable {
    struct Rule: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let name: String
        let level: VolumeProtectionLevel
    }
    var version = 1
    var revision = UUID()
    var rules: [Rule] = []
    enum Failure: Error { case invalid, stale, unavailable }
    func validate() throws {
        guard version == 1, rules.count <= 256, Set(rules.map(\.id)).count == rules.count,
              rules.allSatisfy({ $0.level != .none && !$0.name.isEmpty && $0.name.utf8.count <= 256
                && !$0.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) })
        else { throw Failure.invalid }
    }
    var saved: [UUID: VolumeProtectionLevel] { Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0.level) }) }
    mutating func set(_ id: UUID, name: String, level: VolumeProtectionLevel) throws {
        rules.removeAll { $0.id == id }
        if level != .none { rules.append(.init(id: id, name: name, level: level)) }
        revision = UUID(); try validate()
    }
}

/// Separate from cosmetic preferences: failed reads/writes never become an
/// empty rule library. The coordinator owns the unavailable state and all UI.
final class DriveProtectionStore: @unchecked Sendable {
    struct Snapshot: Sendable {
        let library: DriveProtectionLibrary
        let bytes: Data?
    }
    private let queue = DispatchQueue(label: "MacExplorer.DriveProtection", qos: .utility)
    private let directory: URL?
    private let memoryOnly: Bool
    private let writeCheckpoint: @Sendable (BrowserSnapshotFile.WriteBoundary) throws -> Void
    private var memory = DriveProtectionLibrary()
    init(directory: URL?, memoryOnly: Bool = false,
         writeCheckpoint: @escaping @Sendable (BrowserSnapshotFile.WriteBoundary) throws -> Void = { _ in }) {
        self.directory = directory; self.memoryOnly = memoryOnly; self.writeCheckpoint = writeCheckpoint
    }
    private var file: BrowserSnapshotFile? {
        directory.map { BrowserSnapshotFile(directory: $0, name: "drive-protection-v1.json", maximumBytes: 131_072, requiresPrivateDurability: true) }
    }
    private func decode(_ bytes: Data) throws -> DriveProtectionLibrary {
        let library = try JSONDecoder().decode(DriveProtectionLibrary.self, from: bytes)
        try library.validate(); return library
    }
    func load() async throws -> Snapshot {
        try await perform {
            if self.memoryOnly { return Snapshot(library: self.memory, bytes: nil) }
            guard let file = self.file else { throw DriveProtectionLibrary.Failure.unavailable }
            let bytes = try file.read(expectDocumentInExistingDirectory: true)
            return Snapshot(library: try bytes.map(self.decode) ?? DriveProtectionLibrary(), bytes: bytes)
        }
    }
    func set(_ id: UUID, name: String, level: VolumeProtectionLevel, expected: Snapshot) async throws -> Snapshot {
        try await perform {
            if self.memoryOnly {
                guard self.memory == expected.library else { throw DriveProtectionLibrary.Failure.stale }
                try self.memory.set(id, name: name, level: level)
                return Snapshot(library: self.memory, bytes: nil)
            }
            guard let file = self.file else { throw DriveProtectionLibrary.Failure.unavailable }
            let before = try file.read(expectDocumentInExistingDirectory: true)
            guard before == expected.bytes else { throw DriveProtectionLibrary.Failure.stale }
            var library = try before.map(self.decode) ?? DriveProtectionLibrary()
            try library.set(id, name: name, level: level)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(library)
            try file.write(bytes, replacing: before.map(BrowserSnapshotFile.ExpectedVersion.bytes) ?? .absent,
                           checkpoint: self.writeCheckpoint) { _ = try self.decode($0) }
            guard try file.read() == bytes else { throw DriveProtectionLibrary.Failure.unavailable }
            return Snapshot(library: library, bytes: bytes)
        }
    }
    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) } }
        }
    }
    func drain() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
}
