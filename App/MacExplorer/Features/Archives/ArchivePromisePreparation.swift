import AppKit
import LocalStorage

/// Coalesces metadata-only offer preparation for the concrete ZIP/TAR models.
/// One task drains before its newest replacement starts; no file payload is
/// produced until the shared native export job receives a real callback.
@MainActor final class ArchivePromisePreparation<Key: Equatable> {
    private struct Request {
        let key: Key, generation: UUID, source: URL
        let browser: BrowserViewController, window: NSWindow?
        let roots: @MainActor () async throws -> ArchivePromiseRoots
        let isCurrent: @MainActor () -> Bool
        let canPrepare: @MainActor () -> Bool
        let notice: @MainActor (String) -> Void
    }
    private var generation = UUID()
    private var desired: Request?
    private var work: Task<Void, Never>?
    private(set) var prepared: ArchivePromiseExport?
    private var preparedKey: Key?
    private var capacityObserver: UUID?
    var changed: (@MainActor () -> Void)?
    var refreshRequested: (@MainActor () -> Void)?

    init() {
        capacityObserver = ApplicationArchiveExports.shared.observeAvailableCapacity { [weak self] in
            self?.refreshRequested?()
        }
    }
    isolated deinit {
        if let capacityObserver { ApplicationArchiveExports.shared.removeCapacityObserver(capacityObserver) }
    }

    func offer(for key: Key) -> ArchivePromiseExport? {
        preparedKey == key && prepared?.canHandOff == true ? prepared : nil
    }
    func invalidate() {
        generation = UUID(); desired = nil
        prepared?.retireUnlessHanded(); prepared = nil; preparedKey = nil
        changed?()
    }
    func request(_ key: Key, source: URL, browser: BrowserViewController, window: NSWindow?,
                 roots: @escaping @MainActor () async throws -> ArchivePromiseRoots,
                 isCurrent: @escaping @MainActor () -> Bool,
                 canPrepare: @escaping @MainActor () -> Bool,
                 notice: @escaping @MainActor (String) -> Void) {
        invalidate()
        desired = Request(key: key, generation: generation, source: source, browser: browser,
            window: window, roots: roots, isCurrent: isCurrent, canPrepare: canPrepare, notice: notice)
        start()
    }
    private func start() {
        guard work == nil, desired != nil else { return }
        work = Task { [self] in
            defer { work = nil; if desired != nil { start() } }
            while !Task.isCancelled, let request = desired {
                desired = nil
                do {
                    guard request.isCurrent(), request.canPrepare() else { continue }
                    let roots = try await request.roots()
                    guard !Task.isCancelled, generation == request.generation,
                          request.isCurrent(), request.canPrepare() else { continue }
                    let access = await request.browser.accessLifetime(for: [request.source])
                    guard !Task.isCancelled, generation == request.generation, request.isCurrent(), request.canPrepare(),
                          !request.browser.isBrowserSuspended else { continue }
                    // Completion belongs to its captured view, even while the
                    // accepted operation still owns exclusive command admission.
                    let isCurrent = request.isCurrent, notice = request.notice
                    prepared = try ArchivePromiseExport(roots: roots, sourceAccess: access,
                        browser: request.browser, window: request.window, notice: {
                            if isCurrent() { notice($0) }
                        }, workFinished: { [weak self] in
                            if isCurrent() { self?.refreshRequested?() }
                        })
                    preparedKey = request.key; changed?()
                } catch {
                    // An unavailable offer never disables explicit extraction
                    // or the existing internal drag route.
                    if generation == request.generation { prepared = nil; preparedKey = nil; changed?() }
                }
            }
        }
    }
    func stop() { invalidate(); work?.cancel() }
    func drain() async { while let work { await work.value } }
}
