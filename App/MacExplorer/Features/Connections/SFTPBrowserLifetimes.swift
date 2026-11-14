import AppKit
@_spi(Qualification) import LocalStorage

@MainActor final class SFTPBrowserLifetimes {
    static let shared = SFTPBrowserLifetimes()
    private var live: [UUID: SFTPBrowserSession] = [:]
    private var newTextAwaitingDrain: [UUID: [SFTPEditedTextSnapshot]] = [:]
    private var closing: [UUID: (id: UUID, task: Task<SFTPWorkerClose, Never>)] = [:]
    func register(_ session: SFTPBrowserSession) {
        live[session.id] = session
        ApplicationDiagnostics.shared.event(.connect, .admitted, trace: session.id)
    }
    /// A close timeout is not a source drain. The same application lifetime
    /// owner keeps the exact generated source until a later actual close ends.
    func retainNewTextAfterUncertainClose(_ source: SFTPEditedTextSnapshot, session: SFTPBrowserSession) {
        live[session.id] = session
        newTextAwaitingDrain[session.id, default: []].append(source)
    }
    func close(_ session: SFTPBrowserSession) -> Task<SFTPWorkerClose, Never> {
        if let previous = closing[session.id] { return previous.task }
        let token = UUID()
        ApplicationDiagnostics.shared.event(.disconnect, .draining, trace: session.id)
        let task = Task { [self] in
            let result = await session.close()
            if result.localResourcesEnded {
                let sources = newTextAwaitingDrain.removeValue(forKey: session.id) ?? []
                for source in sources { _ = await source.closeAndDrain() }
            }
            ApplicationDiagnostics.shared.event(.disconnect, result.localResourcesEnded ? .completed : .partial, trace: session.id)
            if closing[session.id]?.id == token {
                closing.removeValue(forKey: session.id)
                if result.localResourcesEnded { live.removeValue(forKey: session.id) }
            }
            return result
        }
        closing[session.id] = (token, task)
        return task
    }
    func closeAndDrain() async -> Bool {
        let attempts = Array(live.values).map { close($0) }
        var drained = true; for task in attempts { if !(await task.value.localResourcesEnded) { drained = false } }
        return drained
    }
}
