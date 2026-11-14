import Foundation

/// An immutable original capture, not a serialized ticket that a caller can
/// reconstruct or replace. Copies share one identity and can apply only once.
public final class PreparedNameEdit: Sendable {
    public let itemID: RememberedItemID
    fileprivate let owner: UUID
    fileprivate let token = UUID()
    fileprivate init(owner: UUID, id: RememberedItemID) {
        self.owner = owner; itemID = id
    }
    internal var mutationID: UUID { token }
}

/// An opaque one-shot cursor. The actor owns its bounded candidate cache, so
/// removal/edit/close can release hidden text even if a caller retains a cursor.
public final class RememberedNameCursor: Sendable {
    fileprivate let owner: UUID
    fileprivate let token = UUID()
    fileprivate init(owner: UUID) { self.owner = owner }
}

public final class RememberedNamePage: Sendable {
    public let matches: [RememberedNameMatch]
    public let coverage: RememberedNameCoverage
    public let next: RememberedNameCursor?
    public let visitedPostings: Int
    fileprivate let owner: UUID
    fileprivate let generation: UInt64
    fileprivate let cancellation: [RememberedNameCancellation]
    internal var cancelled: Bool { cancellation.contains(where: \.isCancelled) }
    fileprivate init(matches: [RememberedNameMatch], coverage: RememberedNameCoverage,
                     next: RememberedNameCursor?, visited: Int, owner: UUID, generation: UInt64,
                     cancellation: [RememberedNameCancellation]) {
        self.matches = matches; self.coverage = coverage; self.next = next
        visitedPostings = visited; self.owner = owner; self.generation = generation
        self.cancellation = cancellation
    }
}

/// Synchronous session state shared by the memory reference and persistent owner.
/// Confined to one non-main actor; no handle contains hidden authored text.
internal final class NameSessionCore {
    private let owner = UUID()
    private let database: NameIndexDatabase
    private var closed = false
    private var generation: UInt64 = 0
    private struct PendingEdit {
        let handle: PreparedNameEdit
        let names: AuthoredNames
        let expectedRevision: UInt64?
    }
    private var pending: [UUID: PendingEdit] = [:]
    private struct LabelRow {
        let id: RememberedItemID
        let revision: UInt64
        let changedNames: AuthoredNames?
    }
    private var labelAddition: (handle: PreparedNameLabelAddition, rows: [LabelRow])?
    internal var pendingLabelAdditionCount: Int { labelAddition == nil ? 0 : 1 }
    private var cursors: [UUID: CursorState] = [:]
    private var cursorOrder: [UUID] = []
    private struct LibraryCursor {
        let handle: RememberedNameCursor
        let generation: UInt64
        let before: Int
        let count: Int
    }
    private var libraryCursors: [UUID: LibraryCursor] = [:]
    private var recordCount = 0

    init(database: NameIndexDatabase) throws {
        self.database = database; recordCount = try database.statistics().records
    }

    public func prepareNew(_ names: AuthoredNames) throws -> PreparedNameEdit {
        try requireOpen()
        guard pending.count < 64 else { throw NameIndexFailure.pendingLimit }
        let capture = PreparedNameEdit(owner: owner, id: RememberedItemID(UUID()))
        pending[capture.token] = PendingEdit(handle: capture, names: names, expectedRevision: nil)
        return capture
    }

    public func prepareEdit(_ id: RememberedItemID, names: AuthoredNames) throws -> PreparedNameEdit {
        try requireOpen()
        guard pending.count < 64 else { throw NameIndexFailure.pendingLimit }
        guard let revision = try database.revision(id) else { throw NameIndexFailure.missingRecord }
        let capture = PreparedNameEdit(owner: owner, id: id)
        pending[capture.token] = PendingEdit(handle: capture, names: names, expectedRevision: revision)
        return capture
    }

    @discardableResult
    public func apply(_ capture: PreparedNameEdit) throws -> RememberedItemID {
        try applyCaptured(capture, failAfterNames: false)
    }
    internal func applyRemembered(_ capture: PreparedNameEdit, reference: NativeDocumentReference) throws -> RememberedItemID {
        try applyCaptured(capture, failAfterNames: false, reference: reference)
    }

    public func cancel(_ capture: PreparedNameEdit) {
        guard capture.owner == owner, pending[capture.token]?.handle === capture else { return }
        pending.removeValue(forKey: capture.token)
    }

    /// Session-only removal for contract tests. B07.1 must qualify durability,
    /// suppression-on-failure and the real work/export drain before app Forget.
    public func remove(_ id: RememberedItemID) throws {
        try requireOpen(); try requireGenerationCapacity()
        // Invalidation happens even when the item is only a pending creation.
        pending = pending.filter { $0.value.handle.itemID != id }
        if labelAddition?.handle.itemIDs.contains(id) == true { labelAddition = nil }
        let existed = try database.revision(id) != nil
        try database.remove(id)
        if existed { recordCount -= 1 }
        changed()
    }

    public func snapshot(_ id: RememberedItemID) throws -> RememberedNamesSnapshot {
        try requireOpen(); return try database.snapshot(id)
    }

    public func query(_ request: RememberedNameQuery, budget: RememberedNameQueryBudget = .init(),
                      cancellation: RememberedNameCancellation = .init()) throws -> RememberedNamePage {
        try requireOpen()
        if cancellation.isCancelled { throw NameIndexFailure.cancelled }
        let execution = NameQueryExecution(budget: budget, cancellation: cancellation)
        let projection = QueryProjection(request)
        var hits: [RememberedItemID: Candidate] = [:]
        var visited = 0
        var coverage: RememberedNameCoverage = .complete
        database.installProgress(execution)
        do {
            for initialLane in Self.lanes(request, projection: projection) {
                if !execution.check() { break }
                var lane = initialLane
                if lane.shape == 1, projection.words.count > 1 {
                    let remaining = budget.maximumPostings - visited
                    // At most one quarter of the remaining posting allowance,
                    // with no persistent term-frequency table or directory work.
                    let limit = min(1_025, remaining / (4 * projection.words.count))
                    if limit > 0 {
                        var best: (NameIndexDatabase.Lane, Int)?
                        for word in projection.words.sorted(by: { $0.utf8.count > $1.utf8.count }) {
                            let probeLane = NameIndexDatabase.Lane(variant: lane.variant, shape: 1,
                                key: Data(word.utf8), equality: false, fields: request.fields)
                            let count = try database.probe(probeLane, limit: limit)
                            visited += count
                            if best == nil || count < best!.1 { best = (probeLane, count) }
                            if count == 0 { break }
                        }
                        if let best {
                            if best.1 == 0 { continue }
                            lane = best.0
                        }
                    }
                }
                let remaining = budget.maximumPostings - visited
                // One lookahead establishes truncation without decoding a whole
                // candidate set. It never becomes a returned match.
                try database.enumerate(lane, limit: remaining + 1) { hit in
                    if !execution.check() { return false }
                    if visited >= budget.maximumPostings { coverage = .candidateLimit; return false }
                    visited += 1
                    guard request.fields.contains(hit.field), let kind = Self.match(hit, request: request, projection: projection) else { return true }
                    let reason = RememberedNameMatchReason(field: hit.field, ordinal: hit.ordinal, value: hit.original, kind: kind)
                    if var candidate = hits[hit.id] {
                        if let position = candidate.reasons.firstIndex(where: { $0.field == hit.field && $0.ordinal == hit.ordinal }) {
                            if kind < candidate.reasons[position].kind { candidate.reasons[position] = reason }
                        } else { candidate.reasons.append(reason) }
                        hits[hit.id] = candidate
                    } else { hits[hit.id] = Candidate(id: hit.id, sortKey: hit.sortKey, reasons: [reason]) }
                    return true
                }
                if coverage == .candidateLimit { break }
            }
        } catch {
            database.installProgress(nil)
            if cancellation.isCancelled { throw NameIndexFailure.cancelled }
            guard execution.coverage != nil else { throw error }
        }
        database.installProgress(nil)
        if cancellation.isCancelled { throw NameIndexFailure.cancelled }
        if let stopped = execution.coverage { coverage = stopped }
        let candidates = hits.values.map { value in
            var sorted = value; sorted.reasons.sort(by: Self.reasonOrder); return sorted
        }.sorted(by: Self.candidateOrder)
        let state = CursorState(generation: generation, pageSize: request.pageSize,
            candidates: candidates, offset: 0, coverage: coverage, visited: visited, cancellation: cancellation)
        return try page(state, cancellation: cancellation)
    }

    public func nextPage(_ cursor: RememberedNameCursor,
                         cancellation: RememberedNameCancellation = .init()) throws -> RememberedNamePage {
        try requireOpen()
        if let state = libraryCursors.removeValue(forKey: cursor.token) {
            guard state.handle === cursor, state.generation == generation else { throw NameIndexFailure.stalePage }
            return try library(count: state.count, before: state.before, cancellation: cancellation)
        }
        guard cursor.owner == owner, let state = cursors.removeValue(forKey: cursor.token),
              state.handle === cursor, state.generation == generation else { throw NameIndexFailure.stalePage }
        cursorOrder.removeAll { $0 == cursor.token }
        return try page(state, cancellation: cancellation)
    }

    /// Required immediately before a UI publication, including an empty result.
    /// Exposed page text is already-delivered data; it is not a hidden Undo copy.
    public func isCurrent(_ page: RememberedNamePage) -> Bool {
        !closed && page.owner == owner && page.generation == generation
            && !page.cancellation.contains(where: \.isCancelled)
    }

    public func close() {
        guard !closed else { return }
        closed = true; pending.removeAll(); labelAddition = nil; cursors.removeAll(); libraryCursors.removeAll(); cursorOrder.removeAll(); database.close()
    }

    func library(count: Int, before: Int? = nil, cancellation: RememberedNameCancellation) throws -> RememberedNamePage {
        try requireOpen()
        guard (1...256).contains(count) else { throw NameIndexFailure.invalidPageSize }
        if cancellation.isCancelled { throw NameIndexFailure.cancelled }
        let rows = try database.libraryRows(count: count + 1, before: before)
        let current = Array(rows.prefix(count))
        let matches = try current.map { RememberedNameMatch(item: try database.snapshot($0.1), reasons: []) }
        if cancellation.isCancelled { throw NameIndexFailure.cancelled }
        var next: RememberedNameCursor?
        if rows.count > count, let last = current.last {
            if libraryCursors.count >= 4, let oldest = libraryCursors.keys.first { libraryCursors.removeValue(forKey: oldest) }
            let handle = RememberedNameCursor(owner: owner)
            libraryCursors[handle.token] = LibraryCursor(handle: handle, generation: generation, before: last.0, count: count)
            next = handle
        }
        return RememberedNamePage(matches: matches, coverage: .complete, next: next, visited: current.count,
            owner: owner, generation: generation, cancellation: [cancellation])
    }

    private struct Candidate {
        let id: RememberedItemID
        let sortKey: Data
        var reasons: [RememberedNameMatchReason]
    }
    private struct CursorState {
        let generation: UInt64
        let pageSize: Int
        let candidates: [Candidate]
        let offset: Int
        let coverage: RememberedNameCoverage
        let visited: Int
        let cancellation: RememberedNameCancellation
        var handle: RememberedNameCursor?
    }
    private func page(_ state: CursorState, cancellation: RememberedNameCancellation) throws -> RememberedNamePage {
        if cancellation.isCancelled || state.cancellation.isCancelled { throw NameIndexFailure.cancelled }
        let end = min(state.offset + state.pageSize, state.candidates.count)
        var matches: [RememberedNameMatch] = []
        for candidate in state.candidates[state.offset..<end] {
            if cancellation.isCancelled || state.cancellation.isCancelled { throw NameIndexFailure.cancelled }
            matches.append(RememberedNameMatch(item: try database.snapshot(candidate.id), reasons: candidate.reasons))
        }
        if cancellation.isCancelled || state.cancellation.isCancelled { throw NameIndexFailure.cancelled }
        var next: RememberedNameCursor?
        if end < state.candidates.count {
            let handle = RememberedNameCursor(owner: owner)
            while cursors.count >= 4 || cursors.values.reduce(0, { $0 + $1.visited }) + state.visited > 65_536 {
                guard let oldest = cursorOrder.first else { break }
                cursors.removeValue(forKey: oldest); cursorOrder.removeFirst()
            }
            cursors[handle.token] = CursorState(generation: state.generation, pageSize: state.pageSize,
                candidates: state.candidates, offset: end, coverage: state.coverage, visited: state.visited,
                cancellation: state.cancellation, handle: handle)
            cursorOrder.append(handle.token); next = handle
        }
        return RememberedNamePage(matches: matches, coverage: state.coverage, next: next,
            visited: state.visited, owner: owner, generation: generation, cancellation: [state.cancellation, cancellation])
    }

    internal func prepareLabelAddition(_ ids: [RememberedItemID], labels: [String]) throws -> PreparedNameLabelAddition {
        try requireOpen()
        guard labelAddition == nil else { throw NameIndexFailure.pendingLimit }
        guard (1...64).contains(ids.count), Set(ids).count == ids.count else { throw NameIndexFailure.invalidInput }
        let additions = try AuthoredNames(labels: labels).labels
        var rows: [LabelRow] = [], bytes = 0
        for id in ids {
            let previous = try database.snapshot(id)
            var seen = Set(previous.names.labels)
            let merged = previous.names.labels + additions.filter { seen.insert($0).inserted }
            let names = try AuthoredNames(nickname: previous.names.nickname, alternateNames: previous.names.alternateNames, labels: merged)
            bytes += (names.nickname?.utf8.count ?? 0) + names.alternateNames.reduce(0) { $0 + $1.utf8.count }
                + names.labels.reduce(0) { $0 + $1.utf8.count }
            guard bytes <= 1_048_576 else { throw NameIndexFailure.resourceLimit }
            rows.append(.init(id: id, revision: previous.revision, changedNames: names == previous.names ? nil : names))
        }
        let handle = PreparedNameLabelAddition(owner: owner, ids: ids, changed: rows.filter { $0.changedNames != nil }.map(\.id), labelCount: additions.count)
        labelAddition = (handle, rows)
        return handle
    }
    internal func cancelLabelAddition(_ handle: PreparedNameLabelAddition) {
        if handle.owner == owner, labelAddition?.handle === handle { labelAddition = nil }
    }
    internal func validateLabelAddition(_ handle: PreparedNameLabelAddition) throws {
        try requireOpen()
        guard handle.owner == owner, let captured = labelAddition, captured.handle === handle else { throw NameIndexFailure.staleEdit }
        for row in captured.rows {
            guard try database.revision(row.id) == row.revision else { throw NameIndexFailure.staleEdit }
            if row.changedNames != nil, row.revision >= UInt64(Int64.max) { throw NameIndexFailure.resourceLimit }
        }
        if handle.changedCount > 0 { try requireGenerationCapacity() }
    }
    internal func applyLabelAddition(_ handle: PreparedNameLabelAddition) throws -> NameLabelAdditionResult {
        defer { cancelLabelAddition(handle) }
        try validateLabelAddition(handle)
        guard let captured = labelAddition else { throw NameIndexFailure.staleEdit }
        labelAddition = nil
        if handle.changedCount > 0 {
            try autoreleasepool {
                try database.transaction {
                    for row in captured.rows {
                        if let names = row.changedNames {
                            try database.save(id: row.id, names: names, expected: row.revision, nonce: handle.token, withinTransaction: true)
                        }
                    }
                }
            }
            changed()
        }
        return .init(selectedItems: captured.rows.count, changedItems: handle.changedCount)
    }

    private func applyCaptured(_ capture: PreparedNameEdit, failAfterNames: Bool, reference: NativeDocumentReference? = nil) throws -> RememberedItemID {
        try requireOpen()
        guard capture.owner == owner, let captured = pending[capture.token], captured.handle === capture else {
            throw NameIndexFailure.staleEdit
        }
        pending.removeValue(forKey: capture.token)
        try requireGenerationCapacity()
        if captured.expectedRevision == nil, recordCount >= 100_000 { throw NameIndexFailure.resourceLimit }
        try autoreleasepool {
            if let reference {
                guard captured.expectedRevision == nil else { throw NameIndexFailure.staleEdit }
                try database.transaction {
                    try database.save(id: capture.itemID, names: captured.names, expected: nil,
                        failAfterNames: failAfterNames, nonce: capture.token, withinTransaction: true)
                    try database.saveReference(capture.itemID, evidence: reference, expected: nil, nonce: capture.token)
                }
            } else {
                try database.save(id: capture.itemID, names: captured.names, expected: captured.expectedRevision,
                                  failAfterNames: failAfterNames, nonce: capture.token)
            }
        }
        if captured.expectedRevision == nil { recordCount += 1 }
        changed()
        return capture.itemID
    }
    func invalidate(_ id: RememberedItemID? = nil) throws {
        try requireGenerationCapacity()
        pending = id.map { id in pending.filter { $0.value.handle.itemID != id } } ?? [:]
        if let id {
            if labelAddition?.handle.itemIDs.contains(id) == true { labelAddition = nil }
        } else { labelAddition = nil }
        recordCount = try database.statistics().records
        changed()
    }
    private func changed() { generation += 1; cursors.removeAll(); libraryCursors.removeAll(); cursorOrder.removeAll() }
    private func requireOpen() throws { if closed { throw NameIndexFailure.closed } }
    private func requireGenerationCapacity() throws {
        guard generation < UInt64.max else { throw NameIndexFailure.resourceLimit }
    }

    private static func reasonOrder(_ lhs: RememberedNameMatchReason, _ rhs: RememberedNameMatchReason) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        if lhs.field != rhs.field { return lhs.field.rawValue < rhs.field.rawValue }
        return lhs.ordinal < rhs.ordinal
    }
    private static func candidateOrder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let a = lhs.reasons[0], b = rhs.reasons[0]
        if a.kind != b.kind { return a.kind < b.kind }
        if a.field != b.field { return a.field.rawValue < b.field.rawValue }
        if lhs.sortKey != rhs.sortKey { return lhs.sortKey.lexicographicallyPrecedes(rhs.sortKey) }
        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }
    private struct QueryProjection {
        let literal: String
        let key: String
        let words: [String]
        init(_ request: RememberedNameQuery) {
            literal = RememberedNameNormalization.key(request.text)
            key = RememberedNameNormalization.key(request.text, separatorTolerant: request.separatorTolerant && request.match != .exact)
            words = RememberedNameNormalization.words(key)
        }
    }
    private static func match(_ hit: NameIndexDatabase.Hit, request: RememberedNameQuery,
                              projection: QueryProjection) -> RememberedNameMatchKind? {
        if hit.original == request.text { return .literal }
        if hit.literal == projection.literal { return .normalized }
        guard request.match != .exact else { return nil }
        let candidate = request.separatorTolerant ? hit.tolerant : hit.literal
        if candidate == projection.key { return .separatorEquivalent }
        if RememberedNameNormalization.starts(candidate, with: projection.key) { return .namePrefix }
        let words = RememberedNameNormalization.words(candidate)
        if projection.words.allSatisfy({ query in words.contains { RememberedNameNormalization.starts($0, with: query) } }) {
            return .wordPrefixes
        }
        return nil
    }

    private static func lanes(_ request: RememberedNameQuery, projection: QueryProjection) -> [NameIndexDatabase.Lane] {
        let literal = projection.literal
        var result = [NameIndexDatabase.Lane(variant: 0, shape: 0, key: Data(literal.utf8), equality: true, fields: request.fields)]
        guard request.match != .exact else { return result }
        let key = projection.key
        let variant = request.separatorTolerant ? 1 : 0
        if request.separatorTolerant, key != literal {
            result.append(NameIndexDatabase.Lane(variant: 1, shape: 0, key: Data(key.utf8), equality: true, fields: request.fields))
        }
        result.append(NameIndexDatabase.Lane(variant: variant, shape: 0, key: Data(key.utf8), equality: false, fields: request.fields))
        if let anchor = projection.words.max(by: { $0.utf8.count < $1.utf8.count }) {
            result.append(NameIndexDatabase.Lane(variant: variant, shape: 1, key: Data(anchor.utf8), equality: false, fields: request.fields))
        }
        return result
    }

    // Narrow qualification observations; these expose counts/plans, never names,
    // SQL parameters, paths or filesystem handles to diagnostics.
    internal func qualificationStatistics() throws -> NameIndexDatabase.Statistics { try database.statistics() }
    internal func qualificationPlans(_ request: RememberedNameQuery) throws -> [[String]] {
        let projection = QueryProjection(request)
        let lanes = Self.lanes(request, projection: projection)
        var plans = try lanes.map { try database.queryPlan($0) }
        if projection.words.count > 1, let word = lanes.first(where: { $0.shape == 1 }) {
            plans.append(try database.queryPlan(word, probe: true))
        }
        return plans
    }
    internal func qualificationFailNextApply(_ capture: PreparedNameEdit) throws {
        _ = try applyCaptured(capture, failAfterNames: true)
    }
}

/// In-memory qualification/reference lane. Disk durability belongs to
/// PersistentNameStore; neither lane resolves source files or reads their bodies.
public actor SessionNameIndex {
    private let core: NameSessionCore
    public init() throws { core = try NameSessionCore(database: NameIndexDatabase()) }
    public func prepareNew(_ names: AuthoredNames) throws -> PreparedNameEdit { try core.prepareNew(names) }
    public func prepareEdit(_ id: RememberedItemID, names: AuthoredNames) throws -> PreparedNameEdit {
        try core.prepareEdit(id, names: names)
    }
    @discardableResult public func apply(_ capture: PreparedNameEdit) throws -> RememberedItemID { try core.apply(capture) }
    public func cancel(_ capture: PreparedNameEdit) { core.cancel(capture) }
    public func remove(_ id: RememberedItemID) throws { try core.remove(id) }
    public func snapshot(_ id: RememberedItemID) throws -> RememberedNamesSnapshot { try core.snapshot(id) }
    public func query(_ request: RememberedNameQuery, budget: RememberedNameQueryBudget = .init(),
                      cancellation: RememberedNameCancellation = .init()) throws -> RememberedNamePage {
        try core.query(request, budget: budget, cancellation: cancellation)
    }
    public func nextPage(_ cursor: RememberedNameCursor,
                         cancellation: RememberedNameCancellation = .init()) throws -> RememberedNamePage {
        try core.nextPage(cursor, cancellation: cancellation)
    }
    public func isCurrent(_ page: RememberedNamePage) -> Bool { core.isCurrent(page) }
    public func close() { core.close() }
    internal func qualificationStatistics() throws -> NameIndexDatabase.Statistics { try core.qualificationStatistics() }
    internal func qualificationPlans(_ request: RememberedNameQuery) throws -> [[String]] { try core.qualificationPlans(request) }
    internal func qualificationFailNextApply(_ capture: PreparedNameEdit) throws { try core.qualificationFailNextApply(capture) }
}
