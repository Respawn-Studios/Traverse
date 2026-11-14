import Foundation

/// Two pages of exact metadata only. Offsets are never object identities.
@_spi(Qualification) public struct SFTPDirectoryPageCache: Sendable {
    public private(set) var generation: UUID?
    public private(set) var snapshot: SFTPStoredSnapshot?
    public private(set) var find: SFTPDirectoryFindResult?
    private struct Page: Sendable { let value: SFTPStoredPage, sort: SFTPStoredSort, descending: Bool }
    private var pages: [Page] = []
    public init() {}
    public var retainedCount: Int { pages.reduce(0) { $0 + $1.value.rows.count } }
    public var displayCount: UInt64 { find?.count ?? snapshot?.count ?? 0 }
    /// At most512 sealed observations in the current ordinary or filtered order.
    public var loadedEntries: [(offset: UInt64, row: SFTPStoredRow)] {
        let offsets = Set(pages.flatMap { page in page.value.rows.indices.map { page.value.offset + UInt64($0) } })
        return offsets.sorted().compactMap { offset in entry(at: offset).map { (offset: offset, row: $0) } }
    }
    /// A delayed progress event must not replace a newer page's snapshot.
    @discardableResult public mutating func observe(_ generation: UUID, snapshot: SFTPStoredSnapshot) -> Bool {
        if self.generation == generation, let existing = self.snapshot,
           snapshot.read != existing.read || snapshot.revision < existing.revision { return false }
        if self.generation != generation || self.snapshot != snapshot { pages.removeAll(); find = nil }
        self.generation = generation; self.snapshot = snapshot; return true
    }
    public mutating func setFindResult(_ result: SFTPDirectoryFindResult?) throws {
        if let result, result.generation != generation || result.snapshot != snapshot { throw RemoteDirectoryFindFailure.stale }
        if find != result { pages.removeAll() }; find = result
    }
    public mutating func accept(_ page: SFTPStoredPage, sort: SFTPStoredSort, descending: Bool) throws {
        guard page.generation == generation, page.snapshot == snapshot, page.rows.count <= 256,
              page.find == find, page.offset <= displayCount,
              UInt64(page.rows.count) <= displayCount - page.offset else { throw SFTPBrowserFailure.stale }
        var known: [UInt64: SFTPWorkerEntry] = [:]
        for other in pages { for row in other.value.rows { known[row.observation] = row.entry } }
        for row in page.rows {
            if let old = known[row.observation], old != row.entry { throw SFTPBrowserFailure.invalidInput }
        }
        pages.removeAll { $0.value.offset == page.offset || $0.sort != sort || $0.descending != descending }
        pages.append(.init(value: page, sort: sort, descending: descending)); if pages.count > 2 { pages.removeFirst() }
    }
    public func entry(at offset: UInt64) -> SFTPStoredRow? {
        for page in pages where offset >= page.value.offset {
            let index = offset - page.value.offset
            if index < UInt64(page.value.rows.count) { return page.value.rows[Int(index)] }
        }; return nil
    }
    public mutating func clear() { generation = nil; snapshot = nil; find = nil; pages.removeAll() }
}
