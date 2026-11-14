import AppKit
import Combine
import ExplorerCore

/// Owns optional remembering across browser replacements. A view may close
/// during an accepted state edit; the edit and its lease still drain here.
@MainActor final class ProfileWorkspaceController: ObservableObject {
    @Published private(set) var records: [UUID: WorkspaceProfileMemory.Record] = [:]
    @Published private(set) var available = false
    @Published private(set) var isBusy = false
    @Published private(set) var notice = ""
    @Published private(set) var currentProfile: WorkspaceLaunchProfile?
    @Published private(set) var isFollowing = false
    private weak var workspace: BrowserWorkspaceController?
    private var currentKey: String?
    private var session: WorkspaceProfileStore.Session?
    private var operation: Task<Void, Error>?
    private var saving: Task<Void, Never>?
    private var reopening: Task<Void, Never>?
    private var resumeOnReopen: WorkspaceLaunchProfile?
    private var pending: PaneWorkspaceSnapshot?
    private var saveFailure: Error?
    private var acceptingCaptures = true
    private var closing = false
    init(workspace: BrowserWorkspaceController) { self.workspace = workspace }
    private var store: WorkspaceProfileStore? { workspace?.profileWorkspaceStore }

    /// Startup deliberately opens only the saved template. Identifying that
    /// copy permits a later explicit opt-in, without reading working state.
    func noteStartupTemplate(_ profile: WorkspaceLaunchProfile, key: String) {
        guard !closing, currentProfile == nil, session == nil else { return }
        currentProfile = profile; currentKey = key; updateIndicator()
    }

    @discardableResult func refresh() async throws -> WorkspaceProfileStore.Snapshot {
        guard let store else { throw WorkspaceProfileStore.Failure.unavailable }
        do {
            let value = try await store.load()
            records = Dictionary(uniqueKeysWithValues: value.memory.records.map { ($0.id, $0) }); available = true
            return value
        } catch { available = false; throw error }
    }
    private func ownedOperation(_ action: @escaping @MainActor () async throws -> Void) async throws {
        guard operation == nil, !isBusy, !closing else { throw WorkspaceLaunchProfiles.Failure.stale }
        isBusy = true
        let task = Task { try await action() }; operation = task
        defer { operation = nil; isBusy = false; if !closing { workspaceChanged() } }
        do { try await task.value }
        catch { notice = Self.message(error); updateIndicator(); throw error }
    }

    func open(_ profile: WorkspaceLaunchProfile, resuming: Bool) async throws {
        try await ownedOperation { [self] in
            guard let workspace, let store, workspace.canOpenLaunchProfile else { throw WorkspaceLaunchProfiles.Failure.stale }
            let before = try workspace.captureSessionSnapshot(syncViewState: false)
            let old = session
            var candidate: WorkspaceProfileStore.Session?
            do {
                let recovering = saveFailure != nil
                if recovering {
                    guard resuming, currentProfile?.id == profile.id else { throw saveFailure! }
                    pending = nil
                } else if let currentProfile, old != nil { try queueLatest(includingWhileBusy: true, profile: currentProfile) }
                await drainSaving()
                if recovering {
                    if let old { await store.end(old.token) }
                    session = nil; isFollowing = false
                } else if let saveFailure { throw saveFailure }
                if resuming { candidate = try await store.begin(profile) }
                let key: String
                if let candidate { key = candidate.record.templateKey } else { key = try await store.key(for: profile) }
                let latest = try await workspace.launchProfileStore.load()
                guard !Task.isCancelled, !closing, workspace.canOpenLaunchProfile,
                      latest.library.profiles.first(where: { $0.id == profile.id }) == profile,
                      try workspace.captureSessionSnapshot(syncViewState: false) == before else { throw WorkspaceLaunchProfiles.Failure.stale }
                try workspace.applyLaunchProfileSnapshot(candidate?.record.snapshot ?? profile.snapshot)
                currentProfile = profile; currentKey = key; session = candidate
                isFollowing = candidate != nil; saveFailure = nil; pending = nil
                if let old, old.token != candidate?.token { await store.end(old.token) }
                if let candidate { records[profile.id] = candidate.record }
                notice = resuming ? "Resumed \(profile.name). Local workspace changes will be remembered."
                    : "Opened \(profile.name)’s saved layout. Its remembered workspace stays as it was."
                updateIndicator()
            } catch {
                if let candidate, candidate.token != old?.token { await store.end(candidate.token) }
                throw error
            }
        }
    }

    func setRemembering(_ enabled: Bool, for profile: WorkspaceLaunchProfile) async throws {
        try await ownedOperation { [self] in
            guard let workspace, let store else { throw WorkspaceProfileStore.Failure.unavailable }
            let latest = try await workspace.launchProfileStore.load()
            guard latest.library.profiles.first(where: { $0.id == profile.id }) == profile else { throw WorkspaceLaunchProfiles.Failure.stale }
            let memory = try await refresh()
            if enabled {
                guard memory.memory.record(for: profile.id) == nil else { return }
                let key = try await store.key(for: profile)
                let isCurrent = currentProfile?.id == profile.id && currentKey == key
                let initial = isCurrent ? try workspace.captureWorkingProfile(includeFilters: profile.includesFilters) : profile.snapshot
                let record = try await store.enable(profile, initial: initial)
                records[profile.id] = record
                if isCurrent, !closing, !Task.isCancelled {
                    session = try await store.begin(profile); isFollowing = true; saveFailure = nil
                }
                notice = isFollowing && isCurrent ? "This profile now remembers its local workspace."
                    : "Remembering enabled. Resume this profile to continue from its workspace."
            } else {
                let owns = currentProfile?.id == profile.id
                if owns { pending = nil; await drainSaving() }
                let old = owns ? session : nil
                do {
                    try await store.disable(profile.id, expectedConsent: memory.memory.record(for: profile.id)?.consent, ownedBy: old?.token)
                    if let old { await store.end(old.token) }
                    if owns { session = nil; isFollowing = false; saveFailure = nil }
                    records.removeValue(forKey: profile.id)
                    notice = "Remembered workspace forgotten. The saved layout remains; older backups may retain locations."
                } catch {
                    if let old { await store.end(old.token); session = nil; isFollowing = false }
                    throw error
                }
            }
            updateIndicator()
        }
    }

    /// Used before explicit template update/delete, never by passive browsing.
    func stopFollowing(_ id: UUID, forget: Bool) async throws {
        guard operation == nil else { throw WorkspaceLaunchProfiles.Failure.stale }
        if forget {
            guard let workspace, let profile = try await workspace.launchProfileStore.load().library.profiles.first(where: { $0.id == id }) else { throw WorkspaceLaunchProfiles.Failure.missingProfile }
            try await setRemembering(false, for: profile)
        } else if currentProfile?.id == id {
            try await ownedOperation { [self] in
                if let currentProfile { try queueLatest(includingWhileBusy: true, profile: currentProfile) }
                await drainSaving()
                if let saveFailure { throw saveFailure }
                if let session, let store { await store.end(session.token) }
                session = nil; isFollowing = false; updateIndicator()
            }
        }
    }

    func workspaceChanged() {
        guard acceptingCaptures, !isBusy, isFollowing, let profile = currentProfile, session != nil else { updateIndicator(); return }
        do { try queueLatest(profile: profile) }
        catch { pause(error) }
    }
    private func queueLatest(includingWhileBusy: Bool = false, profile: WorkspaceLaunchProfile) throws {
        guard acceptingCaptures, isFollowing, (!isBusy || includingWhileBusy), let session, let workspace else { return }
        let snapshot = try workspace.captureWorkingProfile(includeFilters: profile.includesFilters)
        guard snapshot != session.record.snapshot || pending != nil else { return }
        pending = snapshot
        startSaving()
    }
    private func startSaving() {
        guard saving == nil, session != nil, let store else { return }
        saving = Task { [self] in
            defer { saving = nil; updateIndicator() }
            while let snapshot = pending, let session, let workspace {
                pending = nil
                do {
                    let library = try await workspace.launchProfileStore.load()
                    guard let profile = library.library.profiles.first(where: { $0.id == session.record.id }),
                          try await store.key(for: profile) == session.record.templateKey else { throw WorkspaceProfileStore.Failure.stale }
                    let record = try await store.save(session.token, snapshot: snapshot)
                    if self.session?.token == session.token {
                        self.session = .init(token: session.token, record: record); records[record.id] = record
                    }
                } catch {
                    await store.end(session.token)
                    if self.session?.token == session.token { self.session = nil; pause(error) }
                    break
                }
            }
        }
        updateIndicator()
    }
    private func pause(_ error: Error) {
        saveFailure = error; pending = nil; isFollowing = false
        notice = "Workspace remembering paused. Your tabs are still open. Review this profile before switching."
        updateIndicator()
    }
    private func drainSaving() async { while let saving { await saving.value } }
    func prepareToClose() {
        if isFollowing { resumeOnReopen = currentProfile }
        if let currentProfile { try? queueLatest(includingWhileBusy: true, profile: currentProfile) }
        acceptingCaptures = false; closing = true; operation?.cancel(); reopening?.cancel()
    }
    func flush(closing: Bool) async {
        if closing { prepareToClose() }
        else if let currentProfile { do { try queueLatest(includingWhileBusy: true, profile: currentProfile) } catch { pause(error) } }
        if closing, let reopening { await reopening.value }
        if let operation { _ = await operation.result }
        await drainSaving()
        if closing {
            if let session, let store { await store.end(session.token) }
            session = nil; isFollowing = false
        }
        await store?.drain()
    }
    func windowReopened() {
        guard closing, reopening == nil else { return }
        let resume = resumeOnReopen; resumeOnReopen = nil
        isBusy = true
        reopening = Task { [self] in
            defer { reopening = nil; isBusy = false; workspaceChanged(); updateIndicator() }
            if let operation { _ = await operation.result }
            await drainSaving()
            if let session, let store { await store.end(session.token) }
            session = nil; isFollowing = false
            guard !Task.isCancelled, let workspace, !workspace.isClosing, let store else { return }
            closing = false; acceptingCaptures = true
            guard let resume else { return }
            var candidate: WorkspaceProfileStore.Session?
            do {
                let before = try workspace.captureWorkingProfile(includeFilters: resume.includesFilters)
                let library = try await workspace.launchProfileStore.load()
                guard library.library.profiles.first(where: { $0.id == resume.id }) == resume else { throw WorkspaceProfileStore.Failure.stale }
                candidate = try await store.begin(resume)
                guard !Task.isCancelled, !closing, !workspace.isClosing,
                      try workspace.captureWorkingProfile(includeFilters: resume.includesFilters) == before else { throw WorkspaceProfileStore.Failure.stale }
                session = candidate; isFollowing = true; saveFailure = nil; workspaceChanged()
            } catch {
                if let candidate { await store.end(candidate.token) }
                notice = "Your tabs are open. Resume this profile when ready to continue remembering its workspace."
            }
        }
    }
    func profileWasRemoved(_ id: UUID) {
        records.removeValue(forKey: id)
        if currentProfile?.id == id { currentProfile = nil; currentKey = nil; saveFailure = nil; updateIndicator() }
    }
    func noteLibrary(_ profiles: [WorkspaceLaunchProfile]) {
        if let currentProfile, let fresh = profiles.first(where: { $0.id == currentProfile.id }),
           currentProfile.snapshot == fresh.snapshot, currentProfile.includesFilters == fresh.includesFilters {
            self.currentProfile = fresh; updateIndicator()
        }
    }
    private func updateIndicator() {
        guard let workspace else { return }
        let detail = saveFailure != nil ? "Remembering paused" : isFollowing ? (saving == nil ? "Workspace saved" : "Saving workspace…") : "Saved layout copy"
        for browser in workspace.browsers.values {
            browser.tabStrip.setProfile(name: browser === workspace.primaryBrowser ? currentProfile?.name : nil,
                detail: detail, action: { [weak workspace] in workspace?.quickProfiles.open() })
        }
    }
    static func message(_ error: Error) -> String {
        switch error {
        case WorkspaceProfileStore.Failure.templateChanged: "The saved layout changed. Open its saved layout, or forget the older remembered workspace first."
        case BrowserSnapshotFile.Failure.writerBusy: "This workspace is in use, or a save is finishing. Close its other window or try again."
        case BrowserSnapshotFile.Failure.oversized, WorkspaceLaunchProfiles.Failure.limitReached: "This workspace is too large to remember. Existing saved data remains available."
        case WorkspaceProfileMemory.Failure.missing: "This profile has no remembered workspace. Open its saved layout."
        default: "Reading or saving this workspace could not be confirmed. Refresh the profile before trying again."
        }
    }
}

@MainActor extension BrowserWorkspaceController {
    func captureWorkingProfile(includeFilters: Bool) throws -> PaneWorkspaceSnapshot {
        guard sessionReady, !restoringSession else { throw WorkspaceLaunchProfiles.Failure.stale }
        let panes = try layout.paneIDs.compactMap { id -> PaneWorkspaceSnapshot.Pane? in
            guard let browser = browsers[id] else { return nil }
            browser.captureArchiveViewState()
            var local = browser.tabs.filter { !$0.location.isRemote || $0.connectionBookmark != nil }
            if local.isEmpty { local = [BrowserTab(location: .computer)] }
            let active = local.contains { $0.id == browser.activeID } ? browser.activeID : local[0].id
            let tabs = try WorkspaceSession.captureLaunchTemplate(local, activeID: active, includeFilters: includeFilters)
            return .init(id: id, tabs: tabs, viewMode: browser.paneViewMode.rawValue)
        }
        let value = PaneWorkspaceSnapshot(layout: layout, activePane: activePaneID, panes: panes)
        try value.validate(); return value
    }
}
