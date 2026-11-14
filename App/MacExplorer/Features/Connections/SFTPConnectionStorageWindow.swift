import AppKit
import Combine
import SwiftUI
@_spi(Qualification) import LocalStorage

@MainActor final class SFTPConnectionStorageModel: ObservableObject {
    @Published private(set) var saved: SFTPSettingsSnapshot?
    @Published private(set) var catalogs: [SMBTemporaryCatalogSummary] = []
    @Published private(set) var bodies: [SFTPDownloadStorageSummary] = []
    @Published private(set) var uploadHistory: SFTPUploadHistorySnapshot?
    @Published private(set) var uploadRecoveryRequired = false
    @Published private(set) var actionHistory: SFTPRemoteActionSnapshot?
    @Published private(set) var actionRecoveryRequired = false
    @Published private(set) var busy = false
    @Published private(set) var needsRecovery = false
    @Published private(set) var notice = ""
    private let remembered: SFTPRememberedState, pool: SMBTemporaryCatalogPool
    private let downloads: SFTPDownloadStorage?
    private let uploads: SFTPUploadStorage?
    private let remoteActions: SFTPRemoteActionStore?
    private var work: Task<Void, Never>?, accepting = true
    init(remembered: SFTPRememberedState, storage: SMBTemporaryStorage, downloads: SFTPDownloadStorage? = nil,
         uploads: SFTPUploadStorage? = nil, remoteActions: SFTPRemoteActionStore? = nil) {
        self.remembered = remembered; pool = .init(storage: storage); self.downloads = downloads; self.uploads = uploads
        self.remoteActions = remoteActions
    }
    func refresh() { run {} }
    func forget(_ target: SFTPRememberedState.ForgetTarget) {
        run {
            let result = await self.remembered.forget(target)
            self.notice = [result.host, result.server, result.password].contains(.incomplete)
                ? "Forgetting is incomplete. Hidden cleanup records are retained; retry when access is available."
                : "Selected saved data forgotten. Open connections stay open."
        }
    }
    func recover() { run { try await self.remembered.discardInterruptedUpdate(); self.notice = "Interrupted update discarded. The last committed details were retained." } }
    func discard(_ id: UUID) { run { try await self.pool.discardIncomplete(id); self.notice = "Owned inactive temporary catalog discarded." } }
    func discardBody(_ id: UUID) { run { try await self.downloads?.discardIncomplete(id); self.notice = "Retained temporary download discarded." } }
    func forgetUpload(_ id: UUID) { run {
        guard let revision = self.uploadHistory?.revision else { throw RemoteSettingsFailure.staleRevision }
        try await self.uploads?.forget(id, revision: revision); self.notice = "Local upload record forgotten. No remote request was made."
    } }
    func recoverUpload() { run {
        try await self.uploads?.recoverUncommittedLocalStage(); self.notice = "Uncommitted local upload update discarded. The last durable outcome remains; remote work was not resumed or changed."
    } }
    func forgetAction(_ id: UUID) { run {
        guard let revision = self.actionHistory?.revision else { throw RemoteSettingsFailure.staleRevision }
        try await self.remoteActions?.forgetReviewed(id, revision: revision)
        self.notice = "Local file-action record forgotten. Nothing was changed on the server."
    } }
    func recoverActions() { run {
        try await self.remoteActions?.recoverUncommittedLocalStage()
        self.notice = "The last recorded file-action results were kept. No server action was retried."
    } }
    func clearCompletedActions() { run {
        guard let revision = self.actionHistory?.revision else { throw RemoteSettingsFailure.staleRevision }
        try await self.remoteActions?.forgetCompleted(revision: revision)
        self.notice = "Completed local file-action records cleared. Actions needing review were kept; nothing changed on the server."
    } }
    private func load() async throws {
        async let observations = pool.inspect()
        do { saved = try await remembered.inspect(); needsRecovery = false }
        catch SFTPSettingsFailure.recoveryRequired { saved = nil; needsRecovery = true; notice = "An interrupted update needs explicit review. No recovery was performed." }
        catalogs = try await observations.sorted { $0.id.uuidString < $1.id.uuidString }
        bodies = try await downloads?.inspect().sorted { $0.id.uuidString < $1.id.uuidString } ?? []
        do { uploadHistory = try await uploads?.inspect(); uploadRecoveryRequired = false }
        catch RemoteSettingsFailure.recoveryRequired { uploadHistory = nil; uploadRecoveryRequired = true; notice = "An interrupted local upload update needs review. Remote files were not inspected or changed." }
        do { actionHistory = try await remoteActions?.inspect(); actionRecoveryRequired = false }
        catch RemoteSettingsFailure.recoveryRequired { actionHistory = nil; actionRecoveryRequired = true; notice = "An interrupted file-action update needs review. Earlier results were kept; nothing was retried." }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard accepting, work == nil else { return }; busy = true; notice = ""
        work = Task { [self] in
            defer { busy = false; work = nil }
            do { try Task.checkCancellation(); try await action(); try await load() }
            catch { notice = "Storage could not be safely inspected or changed. Existing data and cleanup authority are preserved." }
        }
    }
    func closeAndDrain() async { accepting = false; let pending = work; pending?.cancel(); await pending?.value }
    func resume() { accepting = true }
}

@MainActor private struct SFTPConnectionStorageView: View {
    @ObservedObject var model: SFTPConnectionStorageModel
    @ObservedObject var settings: BrowserSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmation: SFTPRememberedState.ForgetTarget?
    @State private var confirmForget = false
    @State private var confirmRecovery = false
    @State private var discardingBody: UUID?
    @State private var confirmDiscardBody = false
    @State private var forgettingUpload: UUID?
    @State private var confirmForgetUpload = false
    @State private var confirmUploadRecovery = false
    @State private var forgettingAction: UUID?
    @State private var confirmForgetAction = false
    @State private var confirmActionRecovery = false
    @State private var confirmClearCompletedActions = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("SFTP Connection Activity").interfaceFont(.title2.weight(.semibold)); Spacer(); if model.busy { ProgressView().controlSize(.small) }; Button("Refresh") { model.refresh() } }
            Text("Review transfers, file actions and saved connections. Passwords stay in your Mac’s Keychain and are never displayed here.")
                .interfaceFont(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.actionRecoveryRequired { Button("Review interrupted file-action update…") { confirmActionRecovery = true } }
                    if let history = model.actionHistory { fileActionHistory(history) }
                    if model.uploadRecoveryRequired { Button("Review interrupted upload record…") { confirmUploadRecovery = true } }
                    if let history = model.uploadHistory {
                        GroupBox("Upload outcomes · \(history.records.count) of 64 local records") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("No automatic retry, remote removal or remote Undo. Forget removes only a local record; backups may retain older copies.").interfaceFont(.caption).foregroundStyle(.secondary)
                                ForEach(history.records.reversed(), id: \.id) { record in
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("\(record.sourceName) → \(record.remoteName.displayName)").lineLimit(1).truncationMode(.middle)
                                            Text(Self.uploadStatus(record)).interfaceFont(.callout).foregroundStyle(record.outcome == .verified ? Color.secondary : Color.orange)
                                            DisclosureGroup("Destination and retained name") {
                                                Text("\(record.host):\(String(record.port)) · \(record.account)").interfaceFont(.caption)
                                                Text(String(decoding: record.directoryUTF8, as: UTF8.self)).interfaceFont(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                                Text("Temporary name: .mac-explorer-upload-\(record.id.uuidString.replacingOccurrences(of: "-", with: "")).part")
                                                    .interfaceFont(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                            }.interfaceFont(.caption)
                                        }
                                        Spacer()
                                        Button("Forget Local Record…") { forgettingUpload = record.id; confirmForgetUpload = true }.disabled(record.active)
                                    }
                                }
                                if history.records.isEmpty { Text("No upload records. Browsing creates none.").foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                    }
                    if model.needsRecovery { Button("Review interrupted settings update…") { confirmRecovery = true } }
                    if let saved = model.saved {
                        if saved.forgetAllPending { Label("Forget All remains incomplete. Its records stay hidden.", systemImage: "exclamationmark.triangle") }
                        GroupBox("Verified server keys · \(saved.visibleHosts.count)") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(saved.visibleHosts, id: \.identity) { host in
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading) { Text("\(host.identity.host) · \(String(host.identity.port))"); Text(host.key.fingerprint).interfaceFont(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                                        Spacer(); Button("Forget Key…") { ask(.host(host.identity)) }
                                    }
                                }
                                if saved.visibleHosts.isEmpty { Text("No verified keys saved.").foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                        GroupBox("Saved servers · \(saved.visibleServers.count)") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(saved.servers) { server in
                                    HStack { VStack(alignment: .leading) { Text(server.details.name); Text(server.removalPending ? "Hidden · removal incomplete" : server.details.address.displayAddress).interfaceFont(.caption).foregroundStyle(.secondary) }
                                        Spacer(); Button(server.removalPending ? "Finish Forgetting…" : "Forget Server…") { ask(.server(server.id, removePassword: true)) } }
                                }
                                if saved.servers.isEmpty { Text("No servers saved.").foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                        GroupBox("Saved passwords · \(saved.credentials.count)") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(saved.credentials, id: \.reference.id) { claim in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(passwordTitle(claim, in: saved))
                                            Text(claim.state == .ready ? "Saved in Keychain" : claim.state == .deleting ? "Removal not completed" : "Save not completed")
                                                .interfaceFont(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button(claim.state == .deleting ? "Retry Removal…" : "Forget Password…") { ask(.password(claim.reference.id)) } }
                                }
                                if saved.credentials.isEmpty { Text("No saved passwords.").foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                        if let routes = saved.routes {
                            GroupBox("Saved jump connections · \(saved.visibleRoutes.count)") {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(routes) { route in
                                        HStack(alignment: .top) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(route.details.destination.name)
                                                Text(route.removalPending ? "Hidden · removal incomplete" : "\(route.details.jump.address.host) → \(route.details.destination.address.host)")
                                                    .interfaceFont(.caption).foregroundStyle(.secondary)
                                                DisclosureGroup("Verified server identities") {
                                                    Text("Jump: \(route.jump.key.fingerprint)")
                                                    Text("Destination: \(route.destination.key.fingerprint)")
                                                }.interfaceFont(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                            }
                                            Spacer()
                                            Button(route.removalPending ? "Finish Forgetting…" : "Forget Connection…") { ask(.route(route.id, removePasswords: true)) }
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            }
                        }
                        Button(saved.forgetAllPending ? "Finish Forgetting Saved SFTP Details…" : "Forget All Saved SFTP Details…", role: .destructive) { ask(.all) }
                    }
                    GroupBox("Temporary browsing data") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(model.catalogs, id: \.id) { catalog in
                                HStack { Text("\(catalog.active ? "Active connection" : "Interrupted session") · \(ByteCountFormatter.string(fromByteCount: Int64(catalog.observedBytes), countStyle: .file))")
                                    Spacer(); if !catalog.active { Button("Discard…") { model.discard(catalog.id) } } }
                            }
                            if model.catalogs.isEmpty { Text("No temporary browsing data.").foregroundStyle(.secondary) }
                            Text("Removed when a connection closes normally. Discarding an interrupted session changes no server files.")
                                .interfaceFont(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    GroupBox("Retained downloads") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Unfinished downloads stay here for review. Discard removes only the temporary copy, keeping the server original and any file already saved.").interfaceFont(.caption).foregroundStyle(.secondary)
                            ForEach(model.bodies, id: \.id) { body in
                                RetainedDownloadRow(isFolder: body.isFolder, observedBytes: body.observedBytes,
                                    active: body.active, publicationProtected: body.publicationProtected) {
                                        discardingBody = body.id; confirmDiscardBody = true
                                    }
                            }
                            if model.bodies.isEmpty { Text("No retained downloads.").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }.padding(.trailing, 8)
            }
            Text(model.notice).interfaceFont(.callout).foregroundStyle(.secondary).frame(minHeight: 30, alignment: .topLeading)
        }.padding(22).disabled(model.busy)
            .alert("Forget selected SFTP data?", isPresented: $confirmForget) {
                Button("Forget", role: .destructive) { if let confirmation { model.forget(confirmation) }; confirmation = nil }; Button("Cancel", role: .cancel) { confirmation = nil }
            } message: { Text("Open connections stay open. Forgetting a key makes future connections require a fresh identity review. Forgetting a connection here also removes its saved passwords. Backups may retain older copies.") }
            .alert("Discard the interrupted settings update?", isPresented: $confirmRecovery) {
                Button("Discard Update") { model.recover() }; Button("Cancel", role: .cancel) {}
            } message: { Text("Keep the last committed SFTP settings and durable cleanup claims. This does not reset incompatible or unreadable storage.") }
            .alert("Discard this retained download?", isPresented: $confirmDiscardBody) {
                Button("Discard Staging", role: .destructive) { if let discardingBody { model.discardBody(discardingBody) }; discardingBody = nil }
                Button("Cancel", role: .cancel) { discardingBody = nil }
            } message: { Text("Remove only this app-owned, inactive temporary copy. Published files and the remote original stay unchanged. Interrupted copies cannot be resumed automatically.") }
            .alert("Forget this local upload record?", isPresented: $confirmForgetUpload) {
                Button("Forget Local Record", role: .destructive) { if let forgettingUpload { model.forgetUpload(forgettingUpload) }; forgettingUpload = nil }
                Button("Cancel", role: .cancel) { forgettingUpload = nil }
            } message: { Text("Only this local record will be removed. Temporary or final remote files are not inspected, deleted or retried. Backups may retain this record.") }
            .alert("Discard the uncommitted local upload update?", isPresented: $confirmUploadRecovery) {
                Button("Discard Local Update") { model.recoverUpload() }; Button("Cancel", role: .cancel) {}
            } message: { Text("Keep the last committed local outcome. This does not prove a remote file is absent, undo a publication or resume a transfer.") }
            .alert("Forget this local file-action record?", isPresented: $confirmForgetAction) {
                Button("Forget Local Record", role: .destructive) { if let forgettingAction { model.forgetAction(forgettingAction) }; forgettingAction = nil }
                Button("Cancel", role: .cancel) { forgettingAction = nil }
            } message: { Text("Only this local result is removed. No server action is retried or undone. Backups may retain earlier records.") }
            .alert("Keep the last recorded file-action results?", isPresented: $confirmActionRecovery) {
                Button("Keep Recorded Results") { model.recoverActions() }; Button("Cancel", role: .cancel) {}
            } message: { Text("Discard the interrupted local update and retain the previous results, including any actions that need review. This does not confirm a server action or retry it.") }
            .alert("Clear completed local file-action records?", isPresented: $confirmClearCompletedActions) {
                Button("Clear Completed Records", role: .destructive) { model.clearCompletedActions() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Keep active actions and any results that still need review. This removes only completed local records, without changing anything on the server. Backups may retain older records.") }
    }
    private func passwordTitle(_ value: SFTPOwnedCredential, in saved: SFTPSettingsSnapshot) -> String {
        if let server = saved.servers.first(where: { $0.credentialID == value.reference.id }) {
            return server.details.name
        }
        if let route = saved.routes?.first(where: { $0.jump.credentialID == value.reference.id || $0.destination.credentialID == value.reference.id }) {
            return route.details.destination.name + (route.jump.credentialID == value.reference.id ? " · Jump server" : " · Destination")
        }
        return "Password saved without server details"
    }
    private func fileActionHistory(_ history: SFTPRemoteActionSnapshot) -> some View {
        GroupBox("File Action History · \(history.records.count) of 64 local records") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Results from New Folder, Copy, Move, Rename and Delete Permanently. An uncertain action is never retried automatically.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
                ForEach(history.records.sorted { $0.updatedAt > $1.updatedAt }) { record in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Self.actionTitle(record)).lineLimit(2)
                            Text(Self.actionStatus(record, active: history.active.contains(record.id)))
                                .interfaceFont(.callout).foregroundStyle(record.outcome == .needsReview ? Color.orange : Color.secondary)
                            Text(record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .interfaceFont(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("Server and location") {
                                Text(record.serverDisplay).interfaceFont(.caption).textSelection(.enabled)
                                Text(record.displayRemoteDirectory).interfaceFont(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                if let destination = record.displayDestinationDirectory {
                                    Text("To " + destination).interfaceFont(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                }
                                if record.kind == .copyFile, let stage = record.copyStageName {
                                    Text("Temporary copy: " + stage).interfaceFont(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                }
                            }.interfaceFont(.caption)
                        }
                        Spacer()
                        Button("Forget Local Record…") { forgettingAction = record.id; confirmForgetAction = true }
                            .disabled(history.active.contains(record.id))
                    }
                    .transition(.opacity)
                }
                if history.records.isEmpty { Text("No file-action records. Browsing creates none.").foregroundStyle(.secondary) }
                Button("Clear Completed Records…") { confirmClearCompletedActions = true }
                    .disabled(!history.records.contains { !history.active.contains($0.id) && ($0.outcome == .confirmed || $0.outcome == .failedSafe) })
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        .animation(reduceMotion || !settings.motion.allows(.pages) ? nil
            : .easeInOut(duration: 0.22 * settings.motion.mode.durationScale), value: history.revision)
    }
    private static func actionTitle(_ record: SFTPRemoteActionRecord) -> String {
        switch record.kind {
        case .newFolder: "New Folder · \(record.displayRemoteName)"
        case .renameFile: "Rename · \(record.displayRemoteName) → \(record.displayDestinationName ?? "")"
        case .renameDirectory: "Rename Folder · \(record.displayRemoteName) → \(record.displayDestinationName ?? "")"
        case .copyFile: "Copy · \(record.displayRemoteName) → \(record.displayDestinationName ?? "")"
        case .moveFile: "Move · \(record.displayRemoteName)"
        case .moveDirectory: "Move Folder · \(record.displayRemoteName)"
        case .deleteFilePermanently: "Delete Permanently · \(record.displayRemoteName)"
        case .deleteEmptyDirectoryPermanently: "Delete Empty Folder · \(record.displayRemoteName)"
        }
    }
    private static func actionStatus(_ record: SFTPRemoteActionRecord, active: Bool) -> String {
        if active { return "In progress…" }
        return switch record.outcome {
        case .prepared: "Not sent"
        case .confirmed: "Confirmed by the server"
        case .failedSafe: BrowserSFTPFileActions.message(record)
        case .needsReview: "Needs review · the server may have changed; inspect it before trying again"
        }
    }
    private func ask(_ target: SFTPRememberedState.ForgetTarget) { confirmation = target; confirmForget = true }
    private static func uploadStatus(_ record: SFTPUploadRecordSummary) -> String {
        if record.active { return "Uploading or verifying…" }
        if let folder = record.folder {
            if record.outcome == .verified { return "Folder verified · \(folder.files.formatted()) files" }
            if record.outcome == .notStarted { return "Folder upload not started" }
            if folder.rootAcknowledged { return "Incomplete · at least \(folder.verifiedFiles.formatted()) files verified · review the remote folder" }
            return record.outcome == .prepared ? "Folder upload prepared · not running" : "Folder creation uncertain · review the destination"
        }
        switch record.outcome {
        case .verified: return "Server copy verified"
        case .notStarted: return "Not started · no remote mutation reported"
        case .prepared, .reviewTemporary:
            return record.publication == .exclusiveFinal ? "Incomplete · remote file may need review" : "Incomplete · remote temporary file may remain"
        case .publicationRequested, .reviewPublication:
            return record.publication == .exclusiveFinal ? "Incomplete or unverified · review the remote file" : "Publication uncertain · final remote file may exist"
        }
    }
}

@MainActor final class SFTPConnectionStorageWindow: NSWindowController, NSWindowDelegate {
    let model: SFTPConnectionStorageModel
    private var positioned = false
    init(settings: BrowserSettings, remembered: SFTPRememberedState, storage: SMBTemporaryStorage,
         downloads: SFTPDownloadStorage? = nil, uploads: SFTPUploadStorage? = nil, remoteActions: SFTPRemoteActionStore? = nil) {
        model = .init(remembered: remembered, storage: storage, downloads: downloads, uploads: uploads, remoteActions: remoteActions)
        let window = ToolWindowChrome.makeWindow(title: "SFTP Connection Activity",
            size: .init(width: 720, height: 620), minimumSize: .init(width: 620, height: 420),
            styleMask: [.titled, .closable, .resizable])
        super.init(window: window); window.delegate = self
        let host = InterfaceHostingController(rootView: SFTPConnectionStorageView(model: model, settings: settings)); host.sizingOptions = []
        window.contentViewController = host; ToolWindowChrome.install(in: window, settings: settings); window.setContentSize(.init(width: 720, height: 620))
    }
    required init?(coder: NSCoder) { nil }
    func present(relativeTo owner: NSWindow?) {
        guard let window else { return }
        if !positioned { ToolWindowChrome.position(window, relativeTo: owner); positioned = true }
        model.resume(); model.refresh(); showWindow(nil); window.makeKeyAndOrderFront(nil)
    }
    func closeAndDrain() async { await model.closeAndDrain(); close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.busy else { Task { [self] in await model.closeAndDrain(); close() }; return false }; return true
    }
}
