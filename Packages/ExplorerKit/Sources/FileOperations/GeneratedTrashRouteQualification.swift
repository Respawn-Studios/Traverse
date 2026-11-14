#if DEBUG
import Darwin
import Foundation

/// A sealed App-route fixture. The adapter performs one ordinary rename inside
/// its generated root; it cannot call FileManager.trashItem or accept another URL.
@_spi(Qualification) public final class GeneratedTrashRouteProbe: @unchecked Sendable {
    private let root: URL
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var calls = 0

    fileprivate init(root: URL) { self.root = root }

    public var didEnter: Bool { condition.withLock { entered } }
    public var callCount: Int { condition.withLock { calls } }
    public func release() { condition.withLock { released = true; condition.broadcast() } }

    fileprivate func rename(_ supplied: URL) throws -> URL {
        let source = root.appendingPathComponent("Input/Generated.bin")
        let target = root.appendingPathComponent("Returned/Generated.bin")
        guard supplied == source else { throw FileOperationFailure.invalidRequest }
        condition.lock()
        calls += 1
        let oneCall = calls == 1
        entered = true
        condition.broadcast()
        let deadline = Date().addingTimeInterval(8)
        while !released && Date() < deadline { _ = condition.wait(until: deadline) }
        let permitted = released && oneCall
        condition.unlock()
        guard permitted else { throw FileOperationFailure.unavailable }
        try Self.requireRegular(source)
        try Self.requireDirectory(target.deletingLastPathComponent())
        var sourceStat = stat(), parentStat = stat()
        guard lstat(source.path, &sourceStat) == 0,
              lstat(target.deletingLastPathComponent().path, &parentStat) == 0,
              sourceStat.st_dev == parentStat.st_dev else { throw FileOperationFailure.invalidRequest }
        var targetStat = stat()
        guard lstat(target.path, &targetStat) != 0 && errno == ENOENT else { throw FileOperationFailure.conflict }
        try FileManager().moveItem(at: source, to: target)
        guard chmod(target.path, 0o640) == 0 else { throw FileOperationFailure.ioFailure }
        return target
    }

    private static func requireRegular(_ url: URL) throws {
        guard url.resolvingSymlinksInPath() == url else { throw FileOperationFailure.invalidRequest }
        var value = stat()
        guard lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFREG,
              value.st_uid == geteuid(), value.st_mode & 0o077 == 0, value.st_nlink == 1 else {
            throw FileOperationFailure.invalidRequest
        }
    }

    private static func requireDirectory(_ url: URL) throws {
        guard url.resolvingSymlinksInPath() == url else { throw FileOperationFailure.invalidRequest }
        var value = stat()
        guard lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFDIR,
              value.st_uid == geteuid(), value.st_mode & 0o077 == 0 else {
            throw FileOperationFailure.invalidRequest
        }
    }

    /// Only a fresh UUID fixture under this checkout's development root can
    /// construct the adapter. The reservation is checked again at the call.
    @_spi(Qualification) public static func make(root: URL) throws -> (RecoverableFileOperations, GeneratedTrashRouteProbe) {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        guard root.isFileURL, root.resolvingSymlinksInPath() == root,
              root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development"),
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent else {
            throw FileOperationFailure.invalidRequest
        }
        try requireDirectory(root)
        try requireDirectory(root.appendingPathComponent("Input"))
        try requireDirectory(root.appendingPathComponent("Returned"))
        try requireDirectory(root.appendingPathComponent("State"))
        let marker = root.appendingPathComponent("reservation.json")
        try requireRegular(marker)
        guard let bytes = try? Data(contentsOf: marker),
              let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              fields["packet"] as? String == "traverse-development-v1",
              fields["action"] as? String == "trash-app-route-generated" else {
            throw FileOperationFailure.invalidRequest
        }
        try requireRegular(root.appendingPathComponent("Input/Generated.bin"))
        let probe = GeneratedTrashRouteProbe(root: root)
        let adapter = LocalFileOperations(trash: { supplied in
            let marker = root.appendingPathComponent("reservation.json")
            try requireRegular(marker)
            guard let bytes = try? Data(contentsOf: marker),
                  let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  fields["packet"] as? String == "traverse-development-v1",
                  fields["action"] as? String == "trash-app-route-generated" else {
                throw FileOperationFailure.invalidRequest
            }
            return try probe.rename(supplied)
        })
        let state = root.appendingPathComponent("State")
        let engine = RecoverableFileOperations(journalDirectory: state.appendingPathComponent("operations"),
            hooks: RecoveryHooks(), legacy: adapter, protecting: [state])
        return (engine, probe)
    }
}
#endif
