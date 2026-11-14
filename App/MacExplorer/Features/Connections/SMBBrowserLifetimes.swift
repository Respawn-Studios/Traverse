import AppKit
@_spi(Qualification) import LocalStorage

/// A closing tab may disappear visually before its worker finishes. This
/// registry retains only that lifetime, and lets Quit await the same exact work.
@MainActor final class SMBBrowserLifetimes {
    static let shared = SMBBrowserLifetimes()
    private var live: [UUID: SMBBrowserSession] = [:]
    private var closing: [UUID: Task<SMBBrowserDrainResult, Never>] = [:]
    func register(_ session: SMBBrowserSession) {
        live[session.id] = session
        ApplicationDiagnostics.shared.event(.connect, .admitted, trace: session.id)
    }
    func close(_ session: SMBBrowserSession) -> Task<SMBBrowserDrainResult, Never> {
        if let old = closing[session.id] { return old }
        ApplicationDiagnostics.shared.event(.disconnect, .draining, trace: session.id)
        let task = Task {
            let result = await session.close()
            ApplicationRemoteTextEditors.shared.connectionDidDrain(session.id, actual: result)
            ApplicationDiagnostics.shared.event(.disconnect, result.ownerReleased ? .completed : .partial, trace: session.id)
            return result
        }; closing[session.id] = task
        Task { if await task.value.ownerReleased { self.live.removeValue(forKey: session.id); self.closing.removeValue(forKey: session.id) } }
        return task
    }
    func closeAndDrain() async -> Bool {
        for session in Array(live.values) { _ = close(session) }
        var drained = true
        for task in Array(closing.values) { if !(await task.value.ownerReleased) { drained = false } }
        // Successful completed handles contain only numeric outcomes. Retain
        // uncertain handles; a timeout must not silently admit replacements.
        if drained { closing = [:] }
        return drained
    }
}
