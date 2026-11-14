import Foundation

/// Local presentation history only. It stores release numbers, never payment,
/// browsing, file or contributor information.
public struct SupportReminderPreferences: Codable, Equatable, Sendable {
    public var enabled = true
    public private(set) var presentedReleases: [String] = []
    public private(set) var launchesBeforeFirstReminder = 0

    public init() {}

    /// Called once per ordinary public-launch process, never for each window.
    /// The first launch remains focused on setup; updates can be shown once
    /// after the initial invitation has already been presented.
    public mutating func recordLaunch() {
        launchesBeforeFirstReminder = min(2, launchesBeforeFirstReminder + 1)
    }

    public func shouldPresent(version: String, build: String) -> Bool {
        guard enabled, launchesBeforeFirstReminder >= 2 || !presentedReleases.isEmpty,
              let key = Self.releaseKey(version: version, build: build) else { return false }
        return !presentedReleases.contains(key)
    }

    public mutating func recordPresentation(version: String, build: String) {
        guard let key = Self.releaseKey(version: version, build: build), !presentedReleases.contains(key) else { return }
        presentedReleases.append(key)
        if presentedReleases.count > 64 { presentedReleases.removeFirst(presentedReleases.count - 64) }
    }

    private static func releaseKey(version: String, build: String) -> String? {
        func numeric(_ value: String, dotted: Bool) -> Bool {
            guard !value.isEmpty, value.utf8.count <= 32 else { return false }
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard dotted ? (1...3).contains(parts.count) : parts.count == 1 else { return false }
            return parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
        }
        guard numeric(version, dotted: true), numeric(build, dotted: false) else { return nil }
        return version + " (" + build + ")"
    }

    private enum CodingKeys: String, CodingKey { case enabled, presentedReleases, launchesBeforeFirstReminder }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let history = try values.decodeIfPresent([String].self, forKey: .presentedReleases) ?? []
        guard history.count <= 64, Set(history).count == history.count,
              history.allSatisfy({ key in
                  let parts = key.components(separatedBy: " (")
                  guard parts.count == 2, parts[1].hasSuffix(")") else { return false }
                  return Self.releaseKey(version: parts[0], build: String(parts[1].dropLast())) == key
              }) else {
            throw DecodingError.dataCorruptedError(forKey: .presentedReleases, in: values,
                debugDescription: "Invalid support reminder history")
        }
        presentedReleases = history
        let count = try values.decodeIfPresent(Int.self, forKey: .launchesBeforeFirstReminder) ?? (history.isEmpty ? 0 : 2)
        guard (0...2).contains(count) else {
            throw DecodingError.dataCorruptedError(forKey: .launchesBeforeFirstReminder, in: values,
                debugDescription: "Invalid local launch count")
        }
        launchesBeforeFirstReminder = count
    }
}
