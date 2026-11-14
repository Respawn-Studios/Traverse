#if DEBUG
import Darwin
import Foundation
import StorageAnalysis

struct AnalysisReuseFixtureAuthority: Sendable {
    static let repository = DevelopmentFixturePaths.repository
    static let sourceByteLimit: Int64 = 65_536, sourceEntryLimit = 64
    let root: URL, lane: URL, fixture: URL, roots: [URL], worker: URL
    let selected: AnalysisReuseCase, storage: AnalysisResultStorage
    enum Failure: Error { case refused(String) }
    private final class EnumerationFailure: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func mark() { lock.withLock { value = true } }
        var occurred: Bool { lock.withLock { value } }
    }
    struct Budget: Sendable { let entries: Int, logicalBytes: Int64, allocatedBytes: Int64 }
    static func auditRoot(_ root: URL) throws -> Budget {
        let failure = EnumerationFailure()
        guard let enumeration = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            options: [], errorHandler: { _, _ in failure.mark(); return false }) else { throw Failure.refused("case-audit-open") }
        var entries = 0, logical: Int64 = 0, allocated: Int64 = 0
        func add(_ url: URL) throws {
            var value = stat()
            try need(lstat(url.path, &value) == 0 && value.st_uid == geteuid()
                && (value.st_mode & S_IFMT == S_IFDIR || value.st_mode & S_IFMT == S_IFREG)
                && value.st_size >= 0 && value.st_blocks >= 0
                && (value.st_mode & S_IFMT != S_IFREG || value.st_nlink == 1), "case-audit-type")
            entries += 1
            try need(entries <= 512 && value.st_size <= (64 << 20) - logical
                && value.st_blocks <= ((64 << 20) - allocated) / 512, "case-audit-bound")
            logical += value.st_size; allocated += value.st_blocks * 512
        }
        try add(root)
        for case let url as URL in enumeration { try add(url) }
        try need(!failure.occurred, "case-audit-unavailable")
        return .init(entries: entries, logicalBytes: logical, allocatedBytes: allocated)
    }
    private static func need(_ value: Bool, _ code: String) throws { if !value { throw Failure.refused(code) } }
    private static func smallJSON(_ url: URL) throws -> [String: Any] {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.refused("admission-open") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var s = stat()
        try need(fstat(fd, &s) == 0 && s.st_mode & S_IFMT == S_IFREG && s.st_nlink == 1
            && s.st_uid == geteuid() && s.st_mode & 0o077 == 0 && s.st_size > 0 && s.st_size <= 65_536, "admission-file")
        guard let data = try file.read(upToCount: 65_537), data.count <= 65_536,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.refused("admission-json") }
        return value
    }
    /// Runs only on a utility task. Validates generated names/metadata, never
    /// reads source bodies. Root's CLI owns exact body hashes and budgets.
    static func load(arguments: [String], environment: [String: String], bundleVariant: String?, state: URL?, cache: URL?) throws -> Self {
        func argument(_ flag: String) throws -> String {
            try need(arguments.filter { $0 == flag }.count == 1, "argument-count")
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { throw Failure.refused("argument-missing") }
            return arguments[index + 1]
        }
        try need(arguments.contains("--verify-ui") && arguments.contains("--check-analysis-session-reuse"), "isolated-dispatch")
        guard let selected = AnalysisReuseCase(rawValue: try argument("--analysis-reuse-case")),
              let raw = environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.refused("case-root") }
        let visible = arguments.contains("--analysis-reuse-visible")
        try need(visible ? (!arguments.contains("--offscreen") && selected.permitsVisible) : arguments.contains("--offscreen"), "explicit-presentation-mode")
        let root = URL(fileURLWithPath: raw, isDirectory: true)
        try need(root.deletingLastPathComponent() == repository.appendingPathComponent(".build/traverse-development", isDirectory: true)
            && root.standardizedFileURL == root && root.resolvingSymlinksInPath() == root
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent, "root-authority")
        var rootInfo = stat()
        try need(lstat(root.path, &rootInfo) == 0 && rootInfo.st_mode & S_IFMT == S_IFDIR
            && rootInfo.st_mode & 0o777 == 0o700 && rootInfo.st_uid == geteuid(), "private-owned-root")
        _ = try auditRoot(root)
        try need(state == root.appendingPathComponent("state", isDirectory: true)
            && cache == root.appendingPathComponent("cache", isDirectory: true), "actual-app-profile-must-match-admitted-root")
        try need(bundleVariant == selected.variant, "binary-variant-mismatch")
        let admission = try smallJSON(root.appendingPathComponent("analysis-reuse-admission.json"))
        try need(admission["schema"] as? Int == 1 && admission["action"] as? String == "analysis-session-reuse"
            && admission["rootID"] as? String == root.lastPathComponent
            && admission["maximumBytes"] as? Int == (64 << 20) && admission["maximumEntries"] as? Int == 512
            && admission["fixtureBytesPerLane"] as? Int == 65_536 && admission["fixtureEntriesPerLane"] as? Int == 64
            && admission["sessionByteLimit"] as? Int == (4 << 20), "prospective-admission")
        let worker = URL(fileURLWithPath: try argument("--analysis-reuse-worker"))
        try need(worker.isFileURL && worker.standardizedFileURL == worker && worker.resolvingSymlinksInPath() == worker
            && worker.path == admission["workerPath"] as? String, "qualified-worker-path")
        var w = stat()
        try need(lstat(worker.path, &w) == 0 && w.st_mode & S_IFMT == S_IFREG && w.st_uid == geteuid()
            && w.st_mode & 0o022 == 0 && w.st_size > 0 && w.st_size <= (64 << 20), "qualified-worker-file")
        let lane = root.appendingPathComponent("runs/" + selected.rawValue, isDirectory: true)
        let fixture = root.appendingPathComponent("source/analysis-reuse/" + selected.rawValue + "/fixtures", isDirectory: true)
        try need(fixture.resolvingSymlinksInPath() == fixture && lane.resolvingSymlinksInPath() == lane, "generated-paths-no-symlinks")
        var fixtureInfo = stat(), laneInfo = stat(), poolInfo = stat()
        try need(lstat(fixture.path, &fixtureInfo) == 0 && fixtureInfo.st_mode & S_IFMT == S_IFDIR && fixtureInfo.st_mode & 0o777 == 0o700
            && fixtureInfo.st_uid == geteuid() && lstat(lane.path, &laneInfo) == 0 && laneInfo.st_mode & S_IFMT == S_IFDIR
            && laneInfo.st_mode & 0o777 == 0o700 && laneInfo.st_uid == geteuid(), "generated-owned-directories")
        let pool = lane.appendingPathComponent("pool", isDirectory: true)
        try need(lstat(pool.path, &poolInfo) != 0 && errno == ENOENT, "fresh-pool-required")
        let roots = (0..<5).map { fixture.appendingPathComponent("Root-\($0)", isDirectory: true) }
        let expected = Set((0..<5).flatMap { index in ["Root-\(index)", "Root-\(index)/a.swift", "Root-\(index)/b.json"] })
        let enumerationFailure = EnumerationFailure()
        guard let enumerator = FileManager.default.enumerator(at: fixture,
            includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in enumerationFailure.mark(); return false }) else { throw Failure.refused("fixture-open") }
        var found = Set<String>(), total: Int64 = 0, entries = 0
        for case let url as URL in enumerator {
            entries += 1; try need(entries <= sourceEntryLimit, "fixture-entry-bound")
            var s = stat()
            try need(lstat(url.path, &s) == 0 && s.st_uid == geteuid(), "fixture-native-metadata")
            let relative = String(url.path.dropFirst(fixture.path.count + 1))
            try need(expected.contains(relative) && found.insert(relative).inserted, "fixture-exact-names")
            if s.st_mode & S_IFMT == S_IFREG {
                try need(s.st_nlink == 1 && s.st_mode & 0o077 == 0 && s.st_size >= 0 && s.st_size <= sourceByteLimit - total, "fixture-byte-bound")
                total += s.st_size
            } else { try need(s.st_mode & S_IFMT == S_IFDIR && s.st_mode & 0o777 == 0o700, "fixture-directory") }
        }
        try need(!enumerationFailure.occurred && found == expected && total > 0 && total <= sourceByteLimit, "fixture-complete")
        let storage = try AnalysisResultStorage(directory: lane.appendingPathComponent("pool", isDirectory: true),
            sessionByteLimit: 4 << 20, poolByteLimit: selected.poolGiB << 30)
        return .init(root: root, lane: lane, fixture: fixture, roots: roots, worker: worker, selected: selected, storage: storage)
    }
}
#endif
