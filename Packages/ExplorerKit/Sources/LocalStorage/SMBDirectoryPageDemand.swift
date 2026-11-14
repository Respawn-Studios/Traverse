import Foundation

/// One active page plus the latest desired page. Repeated native redraw/scroll
/// callbacks cannot turn one missing page into a second overlapping request.
@_spi(Qualification) public struct SMBDirectoryPageDemand: Sendable {
    public struct Key: Equatable, Sendable {
        public let snapshot: SMBDirectorySnapshot
        public let offset: Int64
        public let sort: SMBDirectorySort
        public let descending: Bool
        public init(snapshot: SMBDirectorySnapshot, offset: Int64, sort: SMBDirectorySort, descending: Bool) throws {
            guard offset >= 0 else { throw SMBDirectoryFailure.invalidInput }
            self.snapshot = snapshot; self.offset = offset; self.sort = sort; self.descending = descending
        }
    }
    private var active: Key?, queued: Key?
    public init() {}
    public var hasQueued: Bool { queued != nil }
    public mutating func request(_ key: Key, alreadyCached: Bool) {
        guard !alreadyCached, key != active, key != queued else { return }
        queued = key
    }
    public mutating func take() -> Key? {
        guard active == nil, let queued else { return nil }
        self.queued = nil; active = queued; return queued
    }
    public mutating func finish(_ key: Key) { if active == key { active = nil } }
    public mutating func clear() { active = nil; queued = nil }
}
