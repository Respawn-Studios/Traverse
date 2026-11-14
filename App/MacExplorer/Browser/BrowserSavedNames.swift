import AppKit
import ExplorerCore
import FileMemory
import Search

/// One bounded, explicitly submitted lane. Authored matches become file rows
/// only after current native reference, scope and metadata checks succeed.
@MainActor
final class BrowserSavedNames {
    struct Match { let id: RememberedItemID; let reasons: [RememberedNameMatchReason] }
    weak var browser: BrowserViewController?
    var changed: (() -> Void)?
    var forgotten: (() -> Void)?
    private let observer = UUID()
    private var owner: ApplicationPrivateNames?
    private var task: Task<Void, Never>?
    private var worker: UUID?
    private enum PendingLoad { case first(RememberedNameQuery), next }
    private var pending: PendingLoad?
    private var generation = UUID()
    private var uses: [RememberedNameUse] = []
    private var cursor: RememberedNameCursor?
    private var filters: SearchRequest?
    private var scope: SearchScope?
    private var external = false
    private var showsHidden = false
    private(set) var matches: [URL: Match] = [:]
    private(set) var filenameEntries: [URL: FileEntry] = [:]
    private(set) var isRunning = false
    private(set) var status = ""
    var hasNext: Bool { cursor != nil && uses.count < 4 && !isRunning }
    init(browser: BrowserViewController) { self.browser = browser }
    isolated deinit { task?.cancel(); owner?.stopObserving(observer) }
    func reset() {
        generation = UUID(); task?.cancel(); pending = nil; uses = []; cursor = nil
        matches = [:]; filenameEntries = [:]; isRunning = false; status = ""
        owner?.stopObserving(observer); owner = nil
    }
    func stopKeepingResults() {
        guard isRunning else { return }
        generation = UUID(); task?.cancel(); pending = nil; cursor = nil; isRunning = false
        status = "Saved names: stopped · \(matches.count) verified"; changed?()
        // Keep observed rows, their display uses and the Forget/access observer.
        // The actual task and its lookups remain owned until their defer runs.
    }
    func drain() async { while let task { await task.value } }
    #if DEBUG
    var beforeLoadedPageForVerification: (() async -> Void)?
    var afterVerifiedEntryForVerification: (() async -> Void)?
    var hasWorkerForVerification: Bool { task != nil }
    #endif
    func rememberFilename(_ entries: [FileEntry]) {
        guard let browser else { return }
        for entry in entries {
            filenameEntries[entry.url] = entry
            // Keep the freshly verified saved row when both lanes match it.
            if matches[entry.url] == nil, !browser.rawEntries.contains(where: { $0.url == entry.url }) { browser.rawEntries.append(entry) }
        }
    }
    func begin(query: RememberedNameQuery, filters: SearchRequest, scope: SearchScope?, external: Bool, showsHidden: Bool) {
        guard let browser else { return }
        self.filters = filters; self.scope = scope; self.external = external; self.showsHidden = showsHidden
        owner = browser.privateNames
        owner?.observe(observer) { [weak self, weak browser] change in
            guard let self, let browser else { return }
            switch change {
            case .forget, .access, .yielding, .closed, .changed:
                // Withdraw every saved result and its copied reason before
                // releasing display leases. Literal filename results remain.
                self.generation = UUID(); self.task?.cancel(); self.pending = nil
                let savedURLs = Set(self.matches.keys)
                browser.rawEntries.removeAll { savedURLs.contains($0.url) && self.filenameEntries[$0.url] == nil }
                for (url, entry) in self.filenameEntries where savedURLs.contains(url) {
                    if let index = browser.rawEntries.firstIndex(where: { $0.url == url }) { browser.rawEntries[index] = entry }
                }
                self.matches = [:]; self.uses = []; self.cursor = nil; self.isRunning = false
                self.status = "Saved names changed; submit again to refresh."
                if case .forget = change { self.forgotten?() }
                self.changed?()
            }
        }
        load(query: query)
    }
    func loadMore() { guard hasNext else { return }; load(query: nil) }
    private func load(query: RememberedNameQuery?) {
        guard let owner, let browser, let filters else { return }
        guard task == nil else {
            pending = query.map(PendingLoad.first) ?? .next
            isRunning = true; status = "Saved names: waiting for earlier checks…"; changed?(); return
        }
        let token = generation, visit = browser.sessionID, cursor = cursor
        let scope = scope, external = external, hidden = showsHidden
        let worker = UUID(); self.worker = worker
        isRunning = true; status = "Saved names: checking references…"; changed?()
        task = Task { [weak self, weak browser] in
            guard let self else { return }
            defer {
                if self.worker == worker {
                    self.task = nil; self.worker = nil
                    let pending = self.pending; self.pending = nil
                    if let pending {
                        switch pending { case .first(let value): self.load(query: value); case .next: self.load(query: nil) }
                    }
                }
            }
            guard let browser else { self.isRunning = false; return }
            do {
                guard self.generation == token, browser.sessionID == visit, !Task.isCancelled else { return }
                let result: (StoredNamePage, RememberedNameUse)? = if let query { try await owner.search(query) }
                    else if let cursor { try await owner.next(cursor) } else { nil }
                #if DEBUG
                if let beforeLoadedPageForVerification { await beforeLoadedPageForVerification() }
                #endif
                guard self.generation == token, browser.sessionID == visit, !Task.isCancelled else { return }
                guard let (page, use) = result else { self.isRunning = false; self.status = "Saved names: none saved yet"; self.changed?(); return }
                defer { withExtendedLifetime(use) {} }
                var values: [RememberedNameMatch] = []
                guard page.publish({ values = $0 }) else { throw RememberedReferenceFailure.stale }
                self.uses.append(use); self.cursor = page.next
                var skipped = 0
                var lastPublication = ContinuousClock.now
                await withTaskGroup(of: (RememberedNameMatch, FileEntry?).self) { group in
                    var index = 0
                    func add(_ match: RememberedNameMatch) {
                        group.addTask { (match, try? await owner.entry(match.item.id, scope: scope,
                            includeExternal: scope != nil || external, showHidden: hidden)) }
                    }
                    while index < min(2, values.count) { add(values[index]); index += 1 }
                    while let (match, entry) = await group.next() {
                        guard self.generation == token, browser.sessionID == visit, !Task.isCancelled else { group.cancelAll(); return }
                        if let entry, filters.matches(entry) {
                            self.matches[entry.url] = Match(id: match.item.id, reasons: match.reasons)
                            if let old = browser.rawEntries.firstIndex(where: { $0.url == entry.url }) { browser.rawEntries[old] = entry }
                            else { browser.rawEntries.append(entry) }
                            if self.matches.count == 1 || lastPublication.duration(to: .now) >= .milliseconds(250) {
                                self.status = "Saved names: checking references… · \(self.matches.count) verified"
                                self.changed?(); lastPublication = .now
                            }
                            #if DEBUG
                            if let afterVerifiedEntryForVerification { await afterVerifiedEntryForVerification() }
                            #endif
                        } else { skipped += 1 }
                        guard self.generation == token, browser.sessionID == visit, !Task.isCancelled else { group.cancelAll(); return }
                        if index < values.count { add(values[index]); index += 1 }
                    }
                }
                guard self.generation == token, browser.sessionID == visit, !Task.isCancelled else { return }
                self.isRunning = false
                let limit = page.coverage != .complete ? " · query limited" : ""
                let next = self.cursor != nil ? " · more candidates available" : ""
                self.status = "Saved names: \(self.matches.count) verified\(limit)\(next)" + (skipped > 0 ? " · some candidates unavailable, excluded or outside scope" : "")
                self.changed?()
            } catch {
                if self.generation == token, !Task.isCancelled { self.isRunning = false; self.status = "Saved names: " + ApplicationPrivateNames.message(error); self.changed?() }
            }
        }
    }
    func reason(_ url: URL) -> String {
        guard let match = matches[url] else { return filenameEntries[url] == nil ? "" : "Filename" }
        var values = match.reasons.prefix(3).map { reason in
            let field = switch reason.field { case .nickname: "Nickname"; case .alternateName: "Alternate name"; case .label: "Label" }
            return field + " · " + reason.value
        }
        if filenameEntries[url] != nil { values.insert("Filename", at: 0) }
        return values.joined(separator: " · ")
    }
}
