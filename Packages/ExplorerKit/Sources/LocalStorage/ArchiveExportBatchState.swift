import Foundation

/// The callback lifetime of one selected archive drag. Each root can be requested
/// once; async native callbacks do not create independent filesystem writers.
/// Contains no URLs, access grants, native objects or mutation implementation.
public struct ArchiveExportBatchState: Sendable {
    public enum Entry: Sendable, Equatable {
        case offered, queued, running, succeeded, failed, retired
    }
    public enum Issue: Error, Sendable { case invalidCount, invalidTransition }
    public private(set) var stopped = false
    private var entries: [Entry]
    private var queue: [Int] = []
    private var running: Int?

    public init(count: Int) throws {
        guard (1...128).contains(count) else { throw Issue.invalidCount }
        entries = Array(repeating: .offered, count: count)
    }
    public var isDrained: Bool { running == nil && queue.isEmpty }
    public var isTerminal: Bool { isDrained && !entries.contains(.offered) }
    public var completedCount: Int { entries.filter { $0 == .succeeded }.count }
    public func entry(_ index: Int) -> Entry? { entries.indices.contains(index) ? entries[index] : nil }

    /// Replays, late requests and invalid indices leave the original request
    /// unchanged. The caller completes the rejected new callback with an error.
    public mutating func request(_ index: Int) -> Bool {
        guard !stopped, entries.indices.contains(index), entries[index] == .offered else { return false }
        entries[index] = .queued; queue.append(index); return true
    }
    public mutating func next() -> Int? {
        guard running == nil, !stopped, !queue.isEmpty else { return nil }
        let index = queue.removeFirst(); entries[index] = .running; running = index; return index
    }
    /// Returns exactly the queued callbacks which must now fail. An already
    /// committed root remains succeeded even if Stop raced its acknowledgement.
    public mutating func finish(_ index: Int, succeeded: Bool) throws -> [Int] {
        guard running == index, entries[index] == .running else { throw Issue.invalidTransition }
        entries[index] = succeeded ? .succeeded : .failed; running = nil
        return succeeded ? [] : stop()
    }
    /// Uncalled providers may outlive the view/gesture. Retiring them does not
    /// cancel or release accepted queued/running work.
    public mutating func retireUnrequested() {
        for index in entries.indices where entries[index] == .offered { entries[index] = .retired }
    }
    /// The actual running worker must still drain and finish its own callback.
    public mutating func stop() -> [Int] {
        stopped = true; retireUnrequested()
        let discarded = queue; queue.removeAll(keepingCapacity: false)
        for index in discarded { entries[index] = .retired }
        return discarded
    }
}

/// Stable, bounded flattened names for promises from different archive folders.
/// The engine still checks the actual callback name and final destination.
/// Existing ZIP names remain source-compatible; the state has no format or
/// filesystem authority and is shared by both concrete archive exporters.
public typealias ZIPExportBatchState = ArchiveExportBatchState

public enum ArchiveRootExportNames {
    private struct Root { let name: String; let isFile: Bool }
    public static func offered(_ roots: [ZIPRootExportSelection]) throws -> [String] {
        try offered(roots.map { Root(name: $0.name, isFile: $0.kind == .file) })
    }
    public static func offeredTAR(_ roots: [TARExtractionSelection]) throws -> [String] {
        try offered(roots.map { selection in
            guard let name = selection.singleFileName ?? selection.singleFolderName else {
                throw TARArchiveFailure.invalidSelection
            }
            return Root(name: name, isFile: selection.singleFileName != nil)
        })
    }
    private static func offered(_ roots: [Root]) throws -> [String] {
        guard (1...128).contains(roots.count) else { throw ArchiveExportBatchState.Issue.invalidCount }
        var used = Set<String>(), names: [String] = []
        for root in roots {
            let base = root.name
            guard !base.isEmpty, base != ".", base != "..", !base.contains("/"), !base.contains("\0") else {
                throw ZIPArchiveFailure.unsafeName
            }
            var number = 1, candidate = base
            while candidate.utf8.count > 255 || used.contains(key(candidate)) {
                number += 1
                let ext = root.isFile ? (base as NSString).pathExtension : ""
                let suffix = " (\(number))" + (ext.isEmpty || ext.utf8.count > 32 ? "" : "." + ext)
                let stem = ext.isEmpty || ext.utf8.count > 32 ? base : (base as NSString).deletingPathExtension
                var prefix = "", bytes = 0
                for character in stem {
                    let size = String(character).utf8.count
                    if bytes + size + suffix.utf8.count > 255 { break }
                    prefix.append(character); bytes += size
                }
                candidate = (prefix.isEmpty ? "Item" : prefix) + suffix
            }
            used.insert(key(candidate)); names.append(candidate)
        }
        return names
    }
    private static func key(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

public typealias ZIPRootExportNames = ArchiveRootExportNames
