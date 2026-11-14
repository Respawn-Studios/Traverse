import Foundation

/// Resolves only typed, opaque trace links in this app's retained logs. Bodies,
/// locations and user-authored strings never participate in this graph.
struct DiagnosticCorrelation {
    let traces: Set<UUID>?
    let incomplete: Bool
    let hasEvents: Bool

    static func collect(scope: DiagnosticLogScope, cancellation: DiagnosticExportCancellation,
                        page: (DiagnosticHistoryCursor?) throws -> DiagnosticHistoryPage) throws -> Self {
        try cancellation.check()
        guard case .operation(let root) = scope else {
            return .init(traces: nil, incomplete: false, hasEvents: true)
        }
        // A graph of links is much smaller than retaining every decoded event.
        // Bound it independently of the on-disk 64-MiB limit and report any gap.
        let maximumLinks = 16_384
        var links: [UUID: Set<UUID>] = [:], linkCount = 0
        var cursor: DiagnosticHistoryCursor?, incomplete = false, rootSeen = false
        for _ in 0..<2_048 {
            try cancellation.check()
            let current = try page(cursor)
            incomplete = incomplete || current.incomplete
            for event in current.events {
                if event.trace == root || event.relatedTrace == root { rootSeen = true }
                guard let related = event.relatedTrace, related != event.trace,
                      links[event.trace]?.contains(related) != true else { continue }
                guard linkCount < maximumLinks else { incomplete = true; continue }
                links[event.trace, default: []].insert(related)
                links[related, default: []].insert(event.trace)
                linkCount += 1
            }
            guard let next = current.next else {
                var connected: Set<UUID> = [root], pending = [root]
                while let node = pending.popLast() {
                    try cancellation.check()
                    for peer in links[node] ?? [] where connected.insert(peer).inserted { pending.append(peer) }
                }
                return .init(traces: connected, incomplete: incomplete, hasEvents: rootSeen)
            }
            cursor = next
        }
        throw DiagnosticHistoryFailure.capacity
    }

    /// A filtered page still advances over unrelated segments. Do not show an
    /// empty intermediate page while a matching operation lies farther back.
    func page(before: DiagnosticHistoryCursor?, limit: Int, cancellation: DiagnosticExportCancellation,
              read: (DiagnosticHistoryCursor?, Int, Set<UUID>?) throws -> DiagnosticHistoryPage) throws -> DiagnosticHistoryPage {
        try cancellation.check()
        guard (1...256).contains(limit) else { throw DiagnosticHistoryFailure.invalidInput }
        guard traces != nil else { return try read(before, limit, nil) }
        guard hasEvents else { return .init(events: [], next: nil, incomplete: incomplete) }
        var cursor = before, events: [DiagnosticEvent] = [], partial = incomplete
        for _ in 0..<2_048 {
            try cancellation.check()
            let next = try read(cursor, limit - events.count, traces)
            events.append(contentsOf: next.events); partial = partial || next.incomplete
            if events.count == limit || next.next == nil {
                return .init(events: events, next: next.next, incomplete: partial)
            }
            cursor = next.next
        }
        throw DiagnosticHistoryFailure.capacity
    }
}
