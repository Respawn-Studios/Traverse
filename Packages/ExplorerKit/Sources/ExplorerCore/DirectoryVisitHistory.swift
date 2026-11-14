import Foundation

public struct DirectoryVisitPolicy: Sendable, Equatable {
    public let maximumEntries: Int
    public let retentionDays: Int
    public init(maximumEntries: Int = 200, retentionDays: Int = 30) {
        self.maximumEntries = min(1_000, max(10, maximumEntries))
        self.retentionDays = min(365, max(1, retentionDays))
    }
}

/// A bounded ranking signal, never a location catalog or access grant. Only
/// successful explicit folder visits are recorded by the application.
public struct DirectoryVisitHistory: Codable, Sendable, Equatable {
    public struct Visit: Codable, Sendable, Equatable {
        public let path: String
        public var count: Int
        public var lastVisit: Date
    }
    public private(set) var visits: [Visit] = []
    public init() {}
    public mutating func prune(policy: DirectoryVisitPolicy, now: Date) {
        visits.removeAll { $0.lastVisit < now.addingTimeInterval(-Double(policy.retentionDays) * 86_400) || $0.lastVisit > now.addingTimeInterval(300) }
        visits.sort { $0.lastVisit == $1.lastVisit ? $0.path < $1.path : $0.lastVisit > $1.lastVisit }
        if visits.count > policy.maximumEntries { visits.removeLast(visits.count - policy.maximumEntries) }
    }
    public mutating func record(_ url: URL, policy: DirectoryVisitPolicy, now: Date = Date()) {
        guard Self.validPath(url.path), url.isFileURL else { return }
        prune(policy: policy, now: now)
        if let i = visits.firstIndex(where: { $0.path == url.path }) {
            visits[i].count = min(1_000_000, visits[i].count + 1); visits[i].lastVisit = now
        } else { visits.append(Visit(path: url.path, count: 1, lastVisit: now)) }
        prune(policy: policy, now: now)
    }
    public func counts(policy: DirectoryVisitPolicy, now: Date = Date()) -> [String: Int] {
        var current = self; current.prune(policy: policy, now: now)
        return Dictionary(uniqueKeysWithValues: current.visits.map { ($0.path, $0.count) })
    }
    public func validate() throws {
        guard visits.count <= 1_000, Set(visits.map(\.path)).count == visits.count,
              visits.allSatisfy({ Self.validPath($0.path) && (1...1_000_000).contains($0.count) && $0.lastVisit.timeIntervalSinceReferenceDate.isFinite }) else {
            throw AddressCompletionError.invalidPath
        }
    }
    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 8_192 && !path.utf8.contains(0) && !path.contains("\n")
            && URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path == path
    }
}
