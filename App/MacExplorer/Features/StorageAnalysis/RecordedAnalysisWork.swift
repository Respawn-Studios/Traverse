import Foundation
@_spi(ApplicationOwnership) import StorageAnalysis

/// Strongly owns each model's revoke/drain callbacks. A queued model task is
/// still owned even if its window and hosting view have already disappeared.
@MainActor
final class RecordedAnalysisPresentationConsumers {
    struct ClosureReceipt: Sendable {
        fileprivate let epoch: UUID
    }
    @MainActor private final class Entry {
        let catalogID: UUID
        let viewID: UUID
        let revoke: @MainActor () -> Void
        let join: @MainActor () async -> Void
        var revoked = false
        var joining: Task<Void, Never>?
        init(catalogID: UUID, viewID: UUID, revoke: @escaping @MainActor () -> Void,
             join: @escaping @MainActor () async -> Void) {
            self.catalogID = catalogID; self.viewID = viewID
            self.revoke = revoke; self.join = join
        }
        func stop() {
            guard !revoked else { return }
            revoked = true; revoke()
        }
        func finish() async {
            stop()
            if let joining { await joining.value; return }
            let join = join
            let task = Task { @MainActor in await join() }
            joining = task
            await task.value
        }
    }
    private let maximumConsumers: Int
    private var entries: [UUID: Entry] = [:]
    private var closingCatalogs: [UUID: Int] = [:]
    private var closure: ClosureReceipt?
    private var activeDrains = 0
    var registeredCount: Int { entries.count }
    var hasActiveDrains: Bool { activeDrains > 0 }

    init(maximumConsumers: Int = 64) {
        precondition(maximumConsumers > 0)
        self.maximumConsumers = maximumConsumers
    }

    @discardableResult
    func register(catalogID: UUID, consumerID: UUID, viewID: UUID,
                  revoke: @escaping @MainActor () -> Void,
                  join: @escaping @MainActor () async -> Void) -> Bool {
        guard closure == nil, closingCatalogs[catalogID] == nil,
              entries.count < maximumConsumers, entries[consumerID] == nil,
              !entries.values.contains(where: { $0.viewID == viewID }) else { return false }
        entries[consumerID] = Entry(catalogID: catalogID, viewID: viewID, revoke: revoke, join: join)
        return true
    }

    func closeAdmissions() -> ClosureReceipt {
        if let closure { return closure }
        let receipt = ClosureReceipt(epoch: UUID())
        closure = receipt
        return receipt
    }

    func revokeAndJoin(consumerID: UUID) async {
        guard let entry = entries[consumerID] else { return }
        activeDrains += 1; defer { activeDrains -= 1 }
        entry.stop()
        await entry.finish()
        if entries[consumerID] === entry { entries.removeValue(forKey: consumerID) }
    }

    func revokeAndJoin(catalogID: UUID) async {
        closingCatalogs[catalogID, default: 0] += 1
        defer {
            let count = closingCatalogs[catalogID, default: 1] - 1
            closingCatalogs[catalogID] = count == 0 ? nil : count
        }
        activeDrains += 1; defer { activeDrains -= 1 }
        let selected = entries.filter { $0.value.catalogID == catalogID }
        // Revoke all affected models before the first join can suspend.
        for entry in selected.values { entry.stop() }
        for (id, entry) in selected {
            await entry.finish()
            if entries[id] === entry { entries.removeValue(forKey: id) }
        }
    }

    func revokeAllAndJoin() async {
        _ = closeAdmissions()
        activeDrains += 1; defer { activeDrains -= 1 }
        let selected = entries
        for entry in selected.values { entry.stop() }
        for (id, entry) in selected {
            await entry.finish()
            if entries[id] === entry { entries.removeValue(forKey: id) }
        }
    }

    func reopenAdmissions(_ receipt: ClosureReceipt) -> Bool {
        guard closure?.epoch == receipt.epoch, entries.isEmpty,
              activeDrains == 0, closingCatalogs.isEmpty else { return false }
        closure = nil
        return true
    }
}

@MainActor
final class RecordedAnalysisConsumerDrainAdapter: RecordedAnalysisConsumerDrain,
    RecordedAnalysisViewConsumerDrain {
    private let registry: RecordedAnalysisPresentationConsumers
    init(_ registry: RecordedAnalysisPresentationConsumers) { self.registry = registry }
    func revokeAndJoin(catalogID: UUID) async { await registry.revokeAndJoin(catalogID: catalogID) }
    func revokeAndJoin(consumerID: UUID) async { await registry.revokeAndJoin(consumerID: consumerID) }
    func revokeAllAndJoin() async { await registry.revokeAllAndJoin() }
}
