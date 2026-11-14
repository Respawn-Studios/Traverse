import Darwin
import Foundation
@testable import FileMemory

/// Ordinary regressions use disposable shared fixtures. Historical packets
/// retain their repo-local paths and reservations; marked cases stay charged.
struct MoveFixture: Sendable {
    private static let build = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build", isDirectory: true)
    static var ordinary: Bool { ProcessInfo.processInfo.environment["MAC_EXPLORER_B07_MOVE_PACKET"] != "1" }
    static var extended: Bool { ordinary || ProcessInfo.processInfo.environment["MAC_EXPLORER_B07_CONTINUITY_MANAGEMENT"] == "1" }
    static var base: URL { build.appendingPathComponent(ordinary ? "test-fixtures" : extended ? "b07-continuity-management" : "b07-move-continuity", isDirectory: true) }
    static var maximumBytes: Int { (extended ? 2_048 : 512) * 1_024 * 1_024 }
    static var maximumEntries: Int { extended ? 65_536 : 10_240 }
    static var enabled: Bool { ProcessInfo.processInfo.environment["MAC_EXPLORER_B07_MOVE_PACKET"] != "0" }
    let root: URL
    init(existingRoot: URL) throws {
        guard Self.enabled, existingRoot.deletingLastPathComponent() == Self.base,
              UUID(uuidString: Self.ordinary ? String(existingRoot.lastPathComponent.dropFirst("file-memory-move-".count)) : existingRoot.lastPathComponent) != nil,
              !Self.ordinary || existingRoot.lastPathComponent.hasPrefix("file-memory-move-"),
              existingRoot.resolvingSymlinksInPath() == existingRoot,
              FileManager().fileExists(atPath: existingRoot.appendingPathComponent("reservation.json").path),
              !Self.hasRetiredInternalMarker(existingRoot) else {
            throw NameStoreFailure.unsafe
        }
        root = existingRoot
    }
    var source: URL { root.appendingPathComponent("source", isDirectory: true) }
    var destination: URL { root.appendingPathComponent("destination", isDirectory: true) }
    var history: URL { root.appendingPathComponent("history", isDirectory: true) }
    var catalog: URL { root.appendingPathComponent("names", isDirectory: true) }
    static func hasRetiredInternalMarker(_ caseRoot: URL) -> Bool {
        var info = stat()
        return lstat(caseRoot.appendingPathComponent("internal-root.json").path, &info) == 0 || errno != ENOENT
    }
    init(bytes: Int = 2 * 1_024 * 1_024, entries: Int = 48) throws {
        guard Self.enabled, (4_096...64 * 1_024 * 1_024).contains(bytes), (8...8_192).contains(entries),
              Self.base.resolvingSymlinksInPath() == Self.base else { throw NameStoreFailure.unsafe }
        try FileManager().createDirectory(at: Self.base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if Self.ordinary {
            root = Self.base.appendingPathComponent("file-memory-move-" + UUID().uuidString, isDirectory: true)
            try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: ["bytes": bytes, "entries": entries], options: .sortedKeys)
                .write(to: root.appendingPathComponent("reservation.json"), options: .withoutOverwriting)
            for url in [source, destination] { try FileManager().createDirectory(at: url, withIntermediateDirectories: false) }
            return
        }
        let fd = open(Self.base.appendingPathComponent(".budget.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NameStoreFailure.unsafe }; defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw NameStoreFailure.busy }
        var reservedBytes = 0, reservedEntries = 1
        for caseRoot in try FileManager().contentsOfDirectory(at: Self.base, includingPropertiesForKeys: nil)
            where caseRoot.lastPathComponent != ".budget.lock" {
            guard UUID(uuidString: caseRoot.lastPathComponent) != nil, caseRoot.resolvingSymlinksInPath() == caseRoot,
                  let reservation = try JSONSerialization.jsonObject(with: Data(contentsOf: caseRoot.appendingPathComponent("reservation.json"))) as? [String: Int],
                  let size = reservation["bytes"], let count = reservation["entries"], size <= 64 * 1_024 * 1_024 else {
                throw NameStoreFailure.unsafe
            }
            let observed = try Self.usage(caseRoot)
            guard observed.0 <= size, observed.1 <= count else { throw NameStoreFailure.quota }
            // Retired marked cases remain fully charged by their reservation.
            // No external side is inspected or replayed.
            reservedBytes += size; reservedEntries += count
        }
        guard reservedBytes + bytes <= Self.maximumBytes, reservedEntries + entries <= Self.maximumEntries else { throw NameStoreFailure.quota }
        root = Self.base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: ["bytes": bytes, "entries": entries], options: .sortedKeys)
            .write(to: root.appendingPathComponent("reservation.json"), options: .withoutOverwriting)
        for url in [source, destination] { try FileManager().createDirectory(at: url, withIntermediateDirectories: false) }
    }
    static func usage(_ root: URL) throws -> (Int, Int) {
        var queue = [root], bytes = 0, entries = 0
        while let url = queue.popLast() {
            var info = stat(); guard lstat(url.path, &info) == 0 else { throw NameStoreFailure.unsafe }
            // Charge hostile/symlink fixture nodes without following them.
            bytes += max(Int(info.st_size), Int(info.st_blocks) * 512); entries += 1
            guard entries <= maximumEntries, bytes <= maximumBytes else { throw NameStoreFailure.quota }
            if info.st_mode & S_IFMT == S_IFDIR { queue += try FileManager().contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
        }
        return (bytes, entries)
    }
    func file(_ name: String = "Document.txt") throws -> URL {
        let url = source.appendingPathComponent(name)
        try Data("Generated B07.4 data".utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
    func receipt(_ value: [String: Bool], name: String = "receipt.json") throws {
        try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
            .write(to: root.appendingPathComponent(name), options: .withoutOverwriting)
    }
}
