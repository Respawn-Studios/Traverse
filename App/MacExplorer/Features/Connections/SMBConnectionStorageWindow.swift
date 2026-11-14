import AppKit
import Combine
import SwiftUI
@_spi(Qualification) import LocalStorage

/// Explicit management of this profile's own settings, Keychain claims and
/// inactive temporary catalogs. Inspect never opens SQLite or reads passwords.
@MainActor final class SMBConnectionStorageModel: ObservableObject {
    @Published private(set) var catalogs: [SMBTemporaryCatalogSummary] = []
    @Published private(set) var downloads: [SMBDownloadStorageSummary] = []
    @Published private(set) var uploadHistory: SMBUploadHistorySnapshot?
    @Published private(set) var uploadRecoveryRequired = false
    @Published private(set) var actionHistory: SMBActionHistorySnapshot?
    @Published private(set) var actionRecoveryRequired = false
    @Published private(set) var saved: SMBServerSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var notice = ""
    @Published private(set) var preferencesNeedRecovery = false
    let limits: SMBTemporaryStorage
    var includesDownloads: Bool { downloadStorage != nil }
    var includesUploads: Bool { uploadStorage != nil }
    var includesActions: Bool { actionStorage != nil }
    private let coordinator: SMBConnectionCoordinator, pool: SMBTemporaryCatalogPool
    private let downloadStorage: SMBDownloadStorage?
    private let uploadStorage: SMBUploadStorage?
    private let actionStorage: SMBActionStorage?
    private var work: Task<Void, Never>?
    private var generation = UUID(), accepting = true
    init(coordinator: SMBConnectionCoordinator, storage: SMBTemporaryStorage, downloads: SMBDownloadStorage? = nil,
          uploads: SMBUploadStorage? = nil, actions: SMBActionStorage? = nil) {
        self.coordinator = coordinator; limits = storage; pool = SMBTemporaryCatalogPool(storage: storage); downloadStorage = downloads
        uploadStorage = uploads
        actionStorage = actions
    }
    func refresh() { run { try await self.load() } }
    func discard(_ id: UUID) {
        run {
            try await self.pool.discardIncomplete(id)
            try await self.load(); self.notice = "Incomplete temporary browsing data discarded."
        }
    }
    func discardDownload(_ id: UUID) {
        guard let downloadStorage else { return }
        run {
            try await downloadStorage.discardIncomplete(id)
            try await self.load(); self.notice = "Incomplete temporary file copy discarded. Remote files stay unchanged."
        }
    }
    func forget(_ id: UUID) {
        run {
            let result = await self.coordinator.forget(.password(id))
            try await self.load()
            self.notice = result.password == .complete ? "Saved password removed."
                : "Password removal is incomplete. Its cleanup record is retained; you can retry."
        }
    }
    func finishForgettingServer(_ id: UUID) {
        guard let server = saved?.servers.first(where: { $0.id == id && $0.removalPending }) else { return }
        let removePassword = saved?.credentials.contains(where: { $0.reference.id == server.credentialID && $0.state == .deleting }) == true
        run {
            let result = await self.coordinator.forget(.server(id, removePassword: removePassword))
            try await self.load()
            self.notice = result.server == .complete ? "Saved server removal completed."
                : "Server removal is incomplete. Its hidden cleanup record remains available for retry."
        }
    }
    func recoverPreferences() {
        run {
            try await self.coordinator.discardInterruptedPreferencesUpdate()
            try await self.load(); self.notice = "Interrupted update discarded. Last saved connection details retained."
        }
    }
    func forgetUpload(_ id: UUID) {
        guard let uploadStorage, let revision = uploadHistory?.revision else { return }
        run {
            try await uploadStorage.forget(id, revision: revision)
            try await self.load(); self.notice = "Local upload record removed. No server file was changed."
        }
    }
    func recoverUploadHistory() {
        guard let uploadStorage else { return }
        run {
            try await uploadStorage.recoverUncommittedLocalStage()
            try await self.load(); self.notice = "The last saved upload outcomes were retained. No server action was retried."
        }
    }
    func forgetAction(_ id: UUID) {
        guard let actionStorage, let revision = actionHistory?.revision else { return }
        run {
            try await actionStorage.forget(id, revision: revision)
            try await self.load(); self.notice = "Local action record removed. No server action was retried."
        }
    }
    func recoverActionHistory() {
        guard let actionStorage else { return }
        run {
            try await actionStorage.recoverUncommittedLocalStage()
            try await self.load(); self.notice = "Last saved file-action outcomes retained. No server action was retried."
        }
    }
    private func load() async throws {
        // Use the same live writer owner; an independent reader would contend
        // with its lease. Unrelated browsing data cannot hide these outcomes.
        do { actionHistory = try await actionStorage?.inspect(); actionRecoveryRequired = false }
        catch RemoteSettingsFailure.recoveryRequired {
            actionHistory = nil; actionRecoveryRequired = true
            notice = "A local file-action record update was interrupted. Review its last saved outcomes."
        }
        // Independent bounded readers. Neither is allowed to inspect Keychain.
        async let observed = pool.inspect()
        do { saved = try await coordinator.inspect(); preferencesNeedRecovery = false }
        catch SMBServerStoreFailure.recoveryRequired {
            saved = nil; preferencesNeedRecovery = true
            notice = "A connection-settings update was interrupted. It has not been applied or discarded."
        }
        catalogs = try await observed.sorted { $0.id.uuidString < $1.id.uuidString }
        downloads = try await downloadStorage?.inspect().sorted { $0.id.uuidString < $1.id.uuidString } ?? []
        do { uploadHistory = try await uploadStorage?.inspect(); uploadRecoveryRequired = false }
        catch RemoteSettingsFailure.recoveryRequired {
            uploadHistory = nil; uploadRecoveryRequired = true
            notice = "Saving an upload outcome was interrupted. Review the last saved outcomes before retrying any upload."
        }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard accepting, work == nil else { return }
        busy = true; notice = ""; let token = generation
        work = Task { [self] in
            defer { busy = false; work = nil }
            do { try Task.checkCancellation(); try await operation() }
            catch {
                guard !Task.isCancelled, generation == token else { return }
                switch error {
                case SMBTemporaryStorageFailure.busy, SMBServerStoreFailure.busy:
                    notice = "Connection work is still active. Finish it, then refresh."
                case SMBTemporaryStorageFailure.changed:
                    notice = "Temporary data changed. Nothing further was discarded; refresh to review it."
                default:
                    notice = "Connection storage could not be safely inspected or changed. Existing data is preserved."
                }
            }
        }
    }
    func stopAndDrain() async {
        accepting = false; generation = UUID()
        let pending = work; pending?.cancel(); await pending?.value
    }
    func resume() { accepting = true }
}

@MainActor final class SMBConnectionStorageWindow: NSWindowController, NSWindowDelegate {
    let model: SMBConnectionStorageModel
    private var positioned = false
    init(settings: BrowserSettings, coordinator: SMBConnectionCoordinator, storage: SMBTemporaryStorage,
         downloads: SMBDownloadStorage? = nil, uploads: SMBUploadStorage? = nil, actions: SMBActionStorage? = nil) {
        model = SMBConnectionStorageModel(coordinator: coordinator, storage: storage, downloads: downloads, uploads: uploads, actions: actions)
        let window = ToolWindowChrome.makeWindow(title: "SMB Connection Activity",
            size: .init(width: 640, height: 540), minimumSize: .init(width: 540, height: 400),
            styleMask: [.titled, .closable, .resizable])
        super.init(window: window); window.delegate = self
        let host = InterfaceHostingController(rootView: SMBConnectionStorageView(model: model, settings: settings))
        host.sizingOptions = []
        window.contentViewController = host
        ToolWindowChrome.install(in: window, settings: settings)
        window.setContentSize(.init(width: 640, height: 540))
    }
    required init?(coder: NSCoder) { nil }
    func present(relativeTo owner: NSWindow?) {
        model.resume()
        if !positioned, let window {
            ToolWindowChrome.position(window, relativeTo: owner)
            positioned = true
        }
        showWindow(nil); window?.makeKeyAndOrderFront(nil); model.refresh()
    }
    func closeAndDrain() async { await model.stopAndDrain(); close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy }
}

private struct SMBConnectionStorageView: View {
    @ObservedObject var model: SMBConnectionStorageModel
    @ObservedObject var settings: BrowserSettings
    @Environment(\.colorScheme) private var inheritedColorScheme
    @State private var discarded: UUID?
    @State private var discardedDownload: UUID?
    @State private var forgotten: UUID?
    @State private var forgottenServer: UUID?
    @State private var confirmRecovery = false
    @State private var forgottenUpload: UUID?
    @State private var confirmUploadRecovery = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SMB Connection Activity").interfaceFont(.title2.bold())
                    Text(model.includesUploads ? "Browsing data, transfer outcomes and saved choices"
                        : model.includesDownloads ? "Local browsing data, temporary file copies and saved choices" : "Local browsing metadata and saved connection choices").interfaceFont(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Refresh") { model.refresh() }.disabled(model.busy)
            }
            if !model.notice.isEmpty { Text(model.notice).interfaceFont(.callout).fixedSize(horizontal: false, vertical: true) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.includesActions { SMBFileActionHistoryView(model: model) }
                    if model.includesUploads { uploadOutcomes }
                    GroupBox("Temporary browsing data") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Up to \(size(model.limits.sessionByteLimit)) per connection · \(size(model.limits.poolByteLimit)) total")
                                .interfaceFont(.caption).foregroundStyle(.secondary)
                            if model.catalogs.isEmpty { Text("No temporary browsing data.").interfaceFont(.callout).foregroundStyle(.secondary) }
                            ForEach(model.catalogs, id: \.id) { value in
                                HStack {
                                    Image(systemName: value.active ? "network" : "exclamationmark.folder")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(value.active ? "Active connection" : "Incomplete browsing session")
                                        Text(size(value.observedBytes)).interfaceFont(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if !value.active { Button("Discard…") { discarded = value.id } }
                                }.interfaceFont(.callout)
                            }
                            Text("Normal connection close removes its data after work ends. Interrupted sessions remain here for explicit discard. Discarding changes no remote files.")
                                .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    if model.includesDownloads {
                        GroupBox("Temporary file copies") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Shared local space for requested text views and transfers").interfaceFont(.caption).foregroundStyle(.secondary)
                                if model.downloads.isEmpty { Text("No retained file copies.").interfaceFont(.callout).foregroundStyle(.secondary) }
                                ForEach(model.downloads, id: \.id) { value in
                                    RetainedDownloadRow(isFolder: value.isFolder, observedBytes: value.observedBytes,
                                        active: value.active, publicationProtected: value.publicationProtected) {
                                            discardedDownload = value.id
                                        }
                                }
                                Text("Copies are made only when you request a text view or transfer. Unfinished work is kept. Discarding a local copy changes no remote files or files already saved to your chosen destination.")
                                    .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }
                    GroupBox("Saved connection details") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(model.saved?.visibleServers.count ?? 0) saved servers · \(model.saved?.credentials.count ?? 0) password records")
                                .interfaceFont(.callout)
                            if model.preferencesNeedRecovery {
                                Button("Discard interrupted settings update…") { confirmRecovery = true }
                            }
                            ForEach(model.saved?.servers.filter(\.removalPending) ?? []) { value in
                                HStack {
                                    Image(systemName: "server.rack")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(value.details.name)
                                        Text("Removal pending · hidden from saved servers").interfaceFont(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Retry Forget…") { forgottenServer = value.id }
                                }.interfaceFont(.callout)
                            }
                            ForEach(model.saved?.credentials ?? [], id: \.reference.id) { value in
                                HStack {
                                    Image(systemName: "key")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(passwordTitle(value))
                                        Text(value.state == .ready ? "Stored in login Keychain" : "Incomplete save or removal · not used for connecting")
                                            .interfaceFont(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(value.state == .ready ? "Forget…" : "Retry removal…") { forgotten = value.reference.id }
                                }.interfaceFont(.callout)
                            }
                            Text("No passwords are displayed or read here. Forget removes current app-owned records; it cannot erase copies in existing backups.")
                                .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }.padding(.trailing, 3)
            }.disabled(model.busy)
            Text(model.includesUploads ? "Browsing shows names and details · Transfers start when you choose"
                : model.includesDownloads ? "File contents are read only when you request a view or transfer" : "Metadata only · No file bodies are cached").interfaceFont(.caption).foregroundStyle(.secondary)
        }.padding(20)
        .environment(\.colorScheme, settings.appearance == .system ? inheritedColorScheme : settings.appearance == .dark ? .dark : .light)
        .confirmationDialog("Discard this incomplete browsing session?", isPresented: Binding(get: { discarded != nil }, set: { if !$0 { discarded = nil } })) {
            Button("Discard Temporary Data", role: .destructive) { if let id = discarded { model.discard(id) }; discarded = nil }
        } message: { Text("Only this app’s inactive session data will be removed. Remote files and saved connections stay unchanged.") }
        .confirmationDialog("Discard this incomplete temporary file copy?", isPresented: Binding(get: { discardedDownload != nil }, set: { if !$0 { discardedDownload = nil } })) {
            Button("Discard Local Copy", role: .destructive) { if let id = discardedDownload { model.discardDownload(id) }; discardedDownload = nil }
        } message: { Text("Only this app’s inactive temporary copy is removed. Remote files and any file already saved to your destination stay unchanged.") }
        .confirmationDialog("Remove this saved password?", isPresented: Binding(get: { forgotten != nil }, set: { if !$0 { forgotten = nil } })) {
            Button("Forget Password", role: .destructive) { if let id = forgotten { model.forget(id) }; forgotten = nil }
        } message: { Text("Future connections will need a password. Open connections stay open.") }
        .confirmationDialog("Discard the interrupted settings update?", isPresented: $confirmRecovery) {
            Button("Keep Last Saved Details", role: .destructive) { model.recoverPreferences() }
        } message: { Text("This discards only the uncommitted update. The last committed connection details and password cleanup records remain.") }
        .confirmationDialog("Finish forgetting this saved server?", isPresented: Binding(get: { forgottenServer != nil }, set: { if !$0 { forgottenServer = nil } })) {
            Button("Finish Forgetting", role: .destructive) { if let id = forgottenServer { model.finishForgettingServer(id) }; forgottenServer = nil }
        } message: { Text("Only the already-requested removal is retried, including any saved password whose removal was already requested. Open connections stay open.") }
        .confirmationDialog("Remove this local upload record?", isPresented: Binding(get: { forgottenUpload != nil }, set: { if !$0 { forgottenUpload = nil } })) {
            Button("Remove Local Record", role: .destructive) { if let id = forgottenUpload { model.forgetUpload(id) }; forgottenUpload = nil }
        } message: { Text("Server files are not changed. If this outcome needs review, removing its record also removes the saved working filename and upload details you may need to investigate it.") }
        .confirmationDialog("Review the last saved upload outcomes?", isPresented: $confirmUploadRecovery) {
            Button("Keep Last Saved Outcomes") { model.recoverUploadHistory() }
        } message: { Text("Only the unfinished local record update is discarded. The last saved outcomes stay available; no upload is retried or removed from the server.") }
    }
    private var uploadOutcomes: some View {
        GroupBox("Upload outcomes") {
            VStack(alignment: .leading, spacing: 10) {
                if model.uploadRecoveryRequired {
                    Button("Review last saved outcomes…") { confirmUploadRecovery = true }
                } else if model.uploadHistory?.records.isEmpty != false {
                    Text("No upload records.").interfaceFont(.callout).foregroundStyle(.secondary)
                }
                ForEach((model.uploadHistory?.records ?? []).reversed(), id: \.id) { value in
                    HStack(alignment: .top) {
                        Image(systemName: value.folder != nil ? "folder" : value.outcome == .verified ? "checkmark.circle" : "arrow.up.circle")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(value.remoteName.displayName).textSelection(.enabled)
                            Text("\(value.server.host) · \(size(value.logicalBytes)) · \(uploadStatus(value))")
                                .interfaceFont(.caption).foregroundStyle(.secondary)
                            if let folder = value.folder {
                                Text("\(folder.files.formatted()) files · \(max(0, folder.folders - 1).formatted()) subfolders")
                                    .interfaceFont(.caption).foregroundStyle(.secondary)
                                if folder.rootAcknowledged && value.outcome != .verified {
                                    Text("\(folder.verifiedFiles.formatted()) of \(folder.files.formatted()) files verified"
                                         + (value.active ? "" : " before stopping"))
                                        .interfaceFont(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if [.finalCollision, .stageMayExist, .reviewTemporary, .reviewPublication].contains(value.outcome) {
                                Text("Server working copy: \(value.temporaryName)").interfaceFont(.caption).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if !value.active { Button("Remove Record…") { forgottenUpload = value.id } }
                    }.interfaceFont(.callout)
                }
                Text("Uploads keep existing names. Interrupted work may leave a working server copy; no retry, replacement or deletion happens from this view.")
                    .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
    private func uploadStatus(_ value: SMBUploadRecordSummary) -> String {
        if value.active { return "Upload in progress" }
        switch value.outcome {
        case .verified: return "Verified on server"
        case .notStarted, .prepared: return "Not started"
        case .stageCollision: return "Working name already occupied · no upload started"
        case .finalCollision: return "Existing item kept · working copy retained"
        case .publicationRequested, .reviewPublication: return "Upload not confirmed"
        case .stageRequested, .stageMayExist: return "A working copy may exist"
        case .stageConfirmed, .reviewTemporary: return "Working copy needs review"
        }
    }
    private func size(_ bytes: UInt64) -> String { FileSizeText.string(Int64(bytes)) }
    private func passwordTitle(_ value: SMBOwnedCredential) -> String {
        model.saved?.servers.first(where: { $0.credentialID == value.reference.id })?.details.name ?? "Password saved without server details"
    }
}
