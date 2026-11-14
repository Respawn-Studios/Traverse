import Darwin
import Foundation

// Built with exact pre-member v3 sources, not the current FileMemory module.
@main enum FrozenV3NameStoreProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw NameStoreFailure.invalidRequest }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard root.deletingLastPathComponent().lastPathComponent == "b07-continuity-management",
              UUID(uuidString: root.lastPathComponent) != nil, root.resolvingSymlinksInPath() == root,
              FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path) else { throw NameStoreFailure.unsafe }
        let catalog = root.appendingPathComponent("names")
        func image() throws -> [String: Data] {
            var value: [String: Data] = [:]
            for file in try FileManager().contentsOfDirectory(at: catalog, includingPropertiesForKeys: nil) {
                var s = stat(); guard lstat(file.path, &s) == 0, s.st_mode & S_IFMT == S_IFREG,
                    s.st_nlink == 1, s.st_size <= 4_194_304 else { throw NameStoreFailure.unsafe }
                value[file.lastPathComponent] = try Data(contentsOf: file)
                value[file.lastPathComponent + ".stat"] = Data("\(s.st_ino)|\(s.st_size)|\(s.st_mtimespec)|\(s.st_ctimespec)".utf8)
            }
            return value
        }
        let before = try image(), inspection = await PersistentNameStore.inspect(directory: catalog)
        guard inspection.status == .unsupported, try image() == before else { throw NameStoreFailure.unsafe }
        var refused = false
        do { let store = try await PersistentNameStore.open(directory: catalog, action: .recover); await store.close() }
        catch NameStoreFailure.unsupported { refused = true }
        guard refused, try image() == before else { throw NameStoreFailure.unsafe }
        try JSONSerialization.data(withJSONObject: ["unsupportedRead": true, "recoveryRefused": true, "unchanged": true], options: .sortedKeys)
            .write(to: root.appendingPathComponent("frozen-v3.json"), options: .withoutOverwriting)
    }
}
