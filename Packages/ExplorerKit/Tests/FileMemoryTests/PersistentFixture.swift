import Darwin
import Foundation
import SQLite3
import Testing
@testable import FileMemory

/// Ordinary name-store fixtures have their own shared-test family. Historical
/// cross-process packets keep their original reservations and failed cases.
struct NameStoreFixture: Sendable {
    let root: URL
    var catalog: URL { child("catalog") }
    static var base: URL {
        if MoveFixture.enabled {
            // The store's reservation walk owns its entire base. It must not
            // treat a LocalStorage or Move test's sibling as a name-store case.
            let ordinary = MoveFixture.ordinary && !authoringPacket
                && ProcessInfo.processInfo.environment["MAC_EXPLORER_B07_NATIVE_PACKET"] != "1"
            return ordinary ? MoveFixture.base.appendingPathComponent("file-memory-store", isDirectory: true) : MoveFixture.base
        }
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        return repo.appendingPathComponent(authoringPacket ? ".build/b07-authoring-search" : nativePacket ? ".build/b07-native-references" : ".build/b07-private-store")
    }
    static var authoringPacket: Bool { ProcessInfo.processInfo.environment["MAC_EXPLORER_B07_AUTHORING_PACKET"] == "1" }
    static var nativePacket: Bool { MoveFixture.enabled || authoringPacket || ProcessInfo.processInfo.environment["MAC_EXPLORER_B07_NATIVE_PACKET"] == "1" }
    init(reservedBytes requestedBytes: Int? = nil, reservedEntries: Int = 12) throws {
        let reservedBytes = requestedBytes ?? (Self.authoringPacket ? 512 * 1_024 : (Self.nativePacket ? 2 : 8) * 1_024 * 1_024)
        let base = Self.base
        guard base.resolvingSymlinksInPath().path == base.path else { throw NameStoreFailure.unsafe }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(base.appendingPathComponent(".budget.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NameStoreFailure.quota }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw NameStoreFailure.quota }
        let usage = try Self.usage()
        guard usage.reserved + reservedBytes <= (MoveFixture.extended ? MoveFixture.maximumBytes : (Self.nativePacket ? 512 : 2_048) * 1_024 * 1_024),
              usage.entriesReserved + reservedEntries <= (MoveFixture.enabled ? MoveFixture.maximumEntries : Self.authoringPacket ? 8_192 : Self.nativePacket ? 3_584 : 2_048),
              reservedBytes <= (Self.nativePacket ? 64 : 512) * 1_024 * 1_024 else { throw NameStoreFailure.quota }
        root = base.appendingPathComponent(UUID().uuidString)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: ["bytes": reservedBytes, "entries": reservedEntries], options: [.sortedKeys])
        try data.write(to: child("reservation.json"), options: .withoutOverwriting)
        guard chmod(child("reservation.json").path, 0o600) == 0 else { throw NameStoreFailure.unsafe }
    }
    init(existingRoot: URL) throws {
        guard existingRoot.deletingLastPathComponent() == Self.base,
              UUID(uuidString: existingRoot.lastPathComponent) != nil,
              existingRoot.resolvingSymlinksInPath().path == existingRoot.path,
              FileManager().fileExists(atPath: existingRoot.appendingPathComponent("reservation.json").path),
              !MoveFixture.hasRetiredInternalMarker(existingRoot) else { throw NameStoreFailure.unsafe }
        root = existingRoot
    }
    func child(_ name: String) -> URL { root.appendingPathComponent(name) }
    static func usage() throws -> (reserved: Int, entriesReserved: Int, bytes: Int, entries: Int) {
        var reserved = 0, entriesReserved = 1, bytes = 0, entries = 0
        for caseURL in try FileManager().contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            if caseURL.lastPathComponent == ".budget.lock" { continue }
            var info = stat()
            guard lstat(caseURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw NameStoreFailure.unsafe }
            let receipt = caseURL.appendingPathComponent("reservation.json")
            guard let values = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Int],
                  let allocation = values["bytes"], let allowance = values["entries"] else { throw NameStoreFailure.unsafe }
            var stack = [caseURL], caseBytes = 0, caseEntries = 0
            while let path = stack.popLast() {
                guard lstat(path.path, &info) == 0 else { throw NameStoreFailure.unsafe }
                caseEntries += 1
                caseBytes += max(Int(info.st_size), Int(info.st_blocks) * 512)
                if info.st_mode & S_IFMT == S_IFDIR {
                    stack += try FileManager().contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
                }
            }
            guard caseBytes <= allocation, caseEntries <= allowance else { throw NameStoreFailure.quota }
            if MoveFixture.hasRetiredInternalMarker(caseURL) {
                // Preserve the old external side's whole reservation without
                // reading or replaying anything outside this repo case.
                caseBytes = allocation; caseEntries = allowance
            }
            reserved += allocation; entriesReserved += allowance; bytes += caseBytes; entries += caseEntries
        }
        return (reserved, entriesReserved, bytes, entries)
    }
    func databaseSQL(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(catalog.appendingPathComponent("names.sqlite").path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw NameStoreFailure.unavailable
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw NameStoreFailure.unsafe }
    }
    /// Hash-like exact byte/identity capture for tiny generated cases. Read-only
    /// checks include native timestamps, permissions and namespace, not atime.
    func image() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for url in try FileManager().contentsOfDirectory(at: catalog, includingPropertiesForKeys: nil) {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_size <= 8 * 1_024 * 1_024 else { throw NameStoreFailure.quota }
            result[url.lastPathComponent] = try Data(contentsOf: url)
            result[url.lastPathComponent + ".stat"] = Data("\(info.st_ino)|\(info.st_mode)|\(info.st_nlink)|\(info.st_size)|\(info.st_mtimespec)|\(info.st_ctimespec)".utf8)
        }
        return result
    }
}

func storedMatches(_ page: StoredNamePage) throws -> [RememberedNameMatch] {
    var result: [RememberedNameMatch]?
    #expect(page.publish { result = $0 })
    return try #require(result)
}

func storedSnapshot(_ snapshot: StoredNameSnapshot) throws -> RememberedNamesSnapshot {
    var result: RememberedNamesSnapshot?
    #expect(snapshot.publish { result = $0 })
    return try #require(result)
}
