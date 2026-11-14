import AppKit
import FileMemory
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// View owns only a revocable opaque export and native presentation. All source
/// access, storage and destination mutation stays behind the private-name owner.
struct PrivateNamesPrivacyView: View {
    @ObservedObject var owner: ApplicationPrivateNames
    @ObservedObject var settings: BrowserSettings
    @State private var includesLocations = false
    @State private var preview: PreparedNameExport?
    @State private var working = false
    @State private var exportCancellation: RememberedNameCancellation?
    @State private var confirmsForget = false
    @State private var notice = ""
    @State private var window: NSWindow?
    @State private var observer = UUID()
    @State private var refresh: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var preparation: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Private saved names") {
                Text("Nicknames, alternate names and labels stay on this Mac under normal macOS protection. No AI model is required and file contents are not indexed.")
                    .interfaceFont(.callout)
                Picker("Default search sources", selection: $settings.privateNamesSources) {
                    ForEach(PrivateNameSources.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Suggest saved folder names in addresses", isOn: $settings.privateNamesAddressSuggestions)
                Text("Turning search off retains saved information. Forget removes current app records; older backups, exports and already viewed copies may retain them.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
                if let value = owner.management {
                    LabeledContent("Saved items", value: "\(value.savedItems)")
                    LabeledContent("Names and labels", value: "\(value.nicknames) nicknames · \(value.alternateNames) alternate names · \(value.labels) labels")
                    LabeledContent("Stored references", value: "\(value.storedReferences) · \(value.accessRemoved) access removed")
                    if value.pendingForget + value.pendingAccessRemovals + value.pendingMoveHandoffs > 0 {
                        Text("Pending: \(value.pendingForget) Forget · \(value.pendingAccessRemovals) access removal · \(value.pendingMoveHandoffs) Move following")
                            .interfaceFont(.caption).foregroundStyle(.secondary)
                    }
                    Text("Reference counts describe saved bindings, not a live scan of your files. Remembered Items checks availability when needed.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                if !owner.managementNotice.isEmpty { Text(owner.managementNotice).interfaceFont(.caption).foregroundStyle(.secondary) }
                Button("Refresh Storage Figures") { Task { await owner.refreshManagement() } }.disabled(owner.isSaving)
            }
            Section("Storage and backups") {
                if let value = owner.management {
                    LabeledContent("Database", value: bytes(value.databaseLogicalBytes))
                    LabeledContent("Observed allocation", value: bytes(value.databaseAllocatedBytes + value.journalAllocatedBytes))
                    if value.journalLogicalBytes > 0 { LabeledContent("Rollback journal", value: bytes(value.journalLogicalBytes)) }
                    LabeledContent("Unused SQLite pages", value: bytes(value.sqliteFreePageBytes))
                    LabeledContent("Derived search pages", value: value.derivedIndexPageBytes.map(bytes) ?? "Unavailable on this SQLite build")
                }
                Text("Names and rebuildable search keys share one database. Allocation can overlap APFS storage; unused/index pages are not a promise of reclaimable space. Normal backups include saved names. This is a private local catalog, not app-level encryption.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
                Text("Spotlight's index is managed by macOS and excluded from these figures. Traverse has no content index.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
                Button("Open App Storage Analysis") { ApplicationStorageAnalysis.shared.showAppStorage(settings: settings) }
            }
            Section("Export saved names") {
                Toggle("Include last-known locations", isOn: $includesLocations).disabled(working)
                    .onChange(of: includesLocations) { _, _ in cancelPreview() }
                Text("Export version 1 includes record IDs, nicknames, alternate names and labels. Locations are optional. Access tokens, native identities, operation evidence and file contents are never exported.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
                if let preview {
                    Text("\(preview.recordCount) items · \(bytes(Int64(preview.encodedBytes))) · \(preview.includesLocations ? "with last-known paths" : "without locations")")
                        .accessibilityIdentifier("private-export-preview")
                    Text("Save creates a new local file without replacing one. An interruption may leave a partial export; any file already created is outside later Forget.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Save Export…") { saveExport(preview) }.disabled(working)
                        Button("Cancel Preview") { cancelPreview() }.disabled(working)
                    }
                } else {
                    Button("Preview Export…") { prepare() }.disabled(working || owner.isSaving)
                }
                if working { ProgressView().controlSize(.small); Button("Stop Export") { exportCancellation?.cancel() } }
                if !notice.isEmpty { Text(notice).interfaceFont(.callout).textSelection(.enabled).accessibilityIdentifier("private-export-outcome") }
            }
            Section("Restore from an export") {
                Button("Import Saved Names…") { if let window { owner.chooseNameImport(in: window) } }
                    .disabled(!owner.enablesImport || working || owner.isSaving || owner.importInProgress)
                if owner.importInProgress { ProgressView("Preparing or importing…").controlSize(.small) }
                Text("Review one local metadata export before adding it. Imported descriptions get new IDs and need Relink; exported locations are discarded. Existing records are never replaced or merged. An older export may contain previously forgotten names.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
            }
            Section("Forget") {
                if owner.pendingForgetAll {
                    Button("Retry Forget All") { Task { do { try await owner.retryForgetAllNames() } catch { notice = ApplicationPrivateNames.message(error) } } }
                        .disabled(owner.isSaving)
                } else {
                    Button("Forget All Saved Names…", role: .destructive) { confirmsForget = true }.disabled(owner.isSaving)
                }
                if !owner.status.isEmpty { Text(owner.status).interfaceFont(.caption).foregroundStyle(.secondary) }
                Text("Removes names, labels, derived keys and saved access from this catalog. It does not delete source files, disable native document flags, erase SSD blocks or control older backups/exports.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .background(PrivatePrivacyWindow { window = $0 })
        .onAppear {
            owner.observe(observer) { change in
                switch change {
                case .changed:
                    if preview != nil { cancelPreview(); notice = "Saved names changed. Preview again before exporting." }
                    refresh?.cancel(); refresh = Task { await owner.refreshManagement() }
                case .forget, .closed, .yielding: cancelPreview()
                case .access: break
                }
            }
            refresh = Task { await owner.refreshManagement() }
        }
        .onDisappear { owner.stopObserving(observer); refresh?.cancel(); preparation?.cancel(); cancelPreview(); exportCancellation?.cancel() }
        .alert("Forget all saved names?", isPresented: $confirmsForget) {
            Button("Forget All", role: .destructive) {
                cancelPreview()
                Task { do { _ = try await owner.forgetAllNames() } catch { notice = ApplicationPrivateNames.message(error) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your files stay in place. Current app names, labels, search keys and saved access will be removed. Backups and exports remain separate copies.") }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    private func cancelPreview() { generation = UUID(); if let preview { owner.cancelNameExport(preview) }; preview = nil }
    private func prepare() {
        working = true; notice = ""; let token = UUID(); generation = token
        preparation = Task {
            defer { working = false; preparation = nil }
            do {
                let value = try await owner.prepareNameExport(locations: includesLocations)
                guard !Task.isCancelled, generation == token else { owner.cancelNameExport(value); return }
                preview = value
            }
            catch { if generation == token { notice = exportMessage(error) } }
        }
    }
    private func saveExport(_ preview: PreparedNameExport) {
        guard let window else { return }
        let token = generation
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Traverse Saved Names.json"
        panel.canCreateDirectories = false; panel.prompt = "Save Export"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            guard generation == token else { owner.cancelNameExport(preview); return }
            working = true; let cancellation = RememberedNameCancellation(); exportCancellation = cancellation
            Task {
                let outcome = await owner.publishNameExport(preview, to: url, cancellation: cancellation)
                self.preview = nil; working = false; exportCancellation = nil
                switch outcome {
                case .saved(let size, let count): notice = "Export saved: \(count) items · \(bytes(Int64(size)))."
                case .createdButIncomplete: notice = "A new export file was created, but writing or synchronization did not finish. It may be partial; review it before using it. Forget will not remove this external copy."
                case .notCreated(let failure): notice = exportMessage(failure)
                }
            }
        }
    }
    private func exportMessage(_ error: Error) -> String {
        switch error {
        case NameExportFailure.empty: "There are no saved names to export."
        case NameExportFailure.tooLarge: "This export exceeds 16 MiB. No file was created."
        case NameExportFailure.alreadyExists: "That name already exists. Choose a new filename; nothing was replaced."
        case NameExportFailure.stalePreview: "The preview changed or was revoked. Preview again before saving."
        case NameExportFailure.invalidDestination, NameExportFailure.unsupportedDestination: "Choose an ordinary local APFS folder outside app storage and cloud/provider locations. No file was created."
        case NameExportFailure.cancelled: "Export stopped before a file was created."
        case NameExportFailure.accessDenied: "macOS denied access to that destination. No file was created."
        default: "Export could not create a file. Refresh the preview and choose an accessible local destination."
        }
    }
}

private struct PrivatePrivacyWindow: NSViewRepresentable {
    let update: (NSWindow?) -> Void
    func makeNSView(context: Context) -> Observer { Observer(update: update) }
    func updateNSView(_ view: Observer, context: Context) { view.update = update }
    final class Observer: NSView {
        var update: (NSWindow?) -> Void
        init(update: @escaping (NSWindow?) -> Void) { self.update = update; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Task { @MainActor [weak self] in guard let self else { return }; update(window) }
        }
    }
}
