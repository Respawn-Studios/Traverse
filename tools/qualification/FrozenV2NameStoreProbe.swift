import Darwin
import Foundation

// Compiled with the exact pre-B07.4 FileMemory sources, never the new module.
@main enum FrozenV2NameStoreProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw NameStoreFailure.invalidRequest }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard UUID(uuidString: root.lastPathComponent) != nil,
              root.deletingLastPathComponent().lastPathComponent == "b07-move-continuity",
              root.resolvingSymlinksInPath() == root,
              FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path) else { throw NameStoreFailure.unsafe }
        let catalog = root.appendingPathComponent("names")
        func image() throws -> [String: Data] {
            var result: [String: Data] = [:]
            for url in try FileManager().contentsOfDirectory(at: catalog, includingPropertiesForKeys: nil) {
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 4 * 1_024 * 1_024 else {
                    throw NameStoreFailure.unsafe
                }
                result[url.lastPathComponent] = try Data(contentsOf: url)
                result[url.lastPathComponent + ".stat"] = Data("\(info.st_ino)|\(info.st_mode)|\(info.st_size)|\(info.st_mtimespec)|\(info.st_ctimespec)".utf8)
            }
            return result
        }
        let before = try image()
        let inspection = await PersistentNameStore.inspect(directory: catalog)
        guard inspection.status == .unsupported, try image() == before else { throw NameStoreFailure.unsafe }
        var refused = false
        do {
            let store = try await PersistentNameStore.open(directory: catalog, action: .recover)
            await store.close()
        } catch NameStoreFailure.unsupported { refused = true }
        guard refused, try image() == before else { throw NameStoreFailure.unsafe }
        try JSONSerialization.data(withJSONObject: ["unsupportedRead": true, "writableRecoveryRefused": true, "unchanged": true], options: .sortedKeys)
            .write(to: root.appendingPathComponent("frozen-v2.json"), options: .withoutOverwriting)
    }
}
