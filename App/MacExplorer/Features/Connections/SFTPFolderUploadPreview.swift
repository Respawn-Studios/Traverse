import AppKit
import Combine
import SwiftUI
@_spi(Qualification) import LocalStorage

enum SFTPFolderUploadFeature {
    // Qualification first. Never expand G file-only consent or a saved layout.
    @MainActor static var available: Bool {
        #if DEBUG
        if qualifying { return true }
        #endif
        return AppFeatureAvailability.allows(.serverFolderUpload)
    }
    #if DEBUG
    @MainActor static var qualifying = false
    #endif
}
@MainActor final class SFTPFolderUploadPreviewModel: ObservableObject {
    let source: SFTPFolderUploadSourceReview, destination: String
    @Published var name: String
    @Published var details = false
    init(source: SFTPFolderUploadSourceReview, destination: String) { self.source = source; self.destination = destination; name = source.name }
    var valid: Bool { name.utf8.count <= 255 && (try? SFTPRemoteName(Data(name.utf8))) != nil }
    var displaySource: String { (try? SFTPRemoteName(Data(source.name.utf8)).displayName) ?? "Selected folder" }
}
@MainActor private struct SFTPFolderUploadPreviewView: View {
    @ObservedObject var model: SFTPFolderUploadPreviewModel
    @ObservedObject var settings: BrowserSettings
    let decide: (String?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Upload a new folder", systemImage: "folder.badge.plus").interfaceFont(.title2.weight(.semibold))
            Text(model.destination).interfaceFont(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                .help(model.destination).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("Local folder") {
                                Text(model.displaySource).lineLimit(2).truncationMode(.middle)
                                    .help(model.displaySource).textSelection(.enabled)
                            }
                            Text("\(model.source.files.formatted()) \(model.source.files == 1 ? "file" : "files") · \(model.source.folders.formatted()) \(model.source.folders == 1 ? "folder" : "folders") · \(ByteCountFormatter.string(fromByteCount: Int64(model.source.logicalBytes), countStyle: .file))")
                                .interfaceFont(.callout).monospacedDigit().foregroundStyle(.secondary)
                            LabeledContent("New folder name") {
                                TextField("Folder name", text: $model.name).textFieldStyle(ToolTextEntryStyle())
                                    .accessibilityIdentifier("sftp-folder-upload-name")
                            }
                        }.padding(6)
                    }
                    Text("Creates a new folder here. An existing name won’t be replaced or merged.").interfaceFont(.callout).fixedSize(horizontal: false, vertical: true)
                    Label("The folder appears while copying. If you stop or lose connection, review the partial copy before trying again.", systemImage: "info.circle")
                        .interfaceFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("What happens during Upload", isExpanded: $model.details) {
                        Text("Each file is read back and checked. Your local folder is kept. This beta supports up to 1,024 files, 2,048 items, 32 folder levels and 1 GiB in total. Links, cloud-only items and extra Mac resource data are refused as a whole selection. Files use standard permissions (0644) and folders use 0755; Mac tags, ACLs and executable bits aren’t copied. Use a destination that others won’t move or replace while copying. Stop closes this connection. Traverse does not remove partial remote folders or retry automatically. Upload results are saved on this Mac; older Traverse versions cannot read folder-upload results.")
                            .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.scrollBounceBehavior(.basedOnSize)
            HStack(spacing: 12) {
                Text("Local folder kept · no remote Undo").interfaceFont(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Button { decide(nil) } label: { Text("Cancel").interfaceFont(.callout) }.keyboardShortcut(.cancelAction).fixedSize()
                Button { if model.valid { decide(model.name) } } label: { Text("Upload Folder").interfaceFont(.callout) }.keyboardShortcut(.defaultAction)
                    .disabled(!model.valid).fixedSize().accessibilityIdentifier("sftp-folder-upload-confirm")
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(reduceMotion || !settings.motion.allows(.pages) || settings.motion.mode == .off ? nil
                : .easeInOut(duration:0.22*settings.motion.mode.durationScale),value:model.details)
    }
}
@MainActor final class SFTPFolderUploadPreview: NSWindowController, NSWindowDelegate {
    let model: SFTPFolderUploadPreviewModel
    #if DEBUG
    var lifecycleForVerification: ((String, TimeInterval) -> Void)?
    #endif
    private weak var parent: NSWindow?
    private var ending = false, chosen: String?
    init(source: SFTPFolderUploadSourceReview, destination: String, settings: BrowserSettings) {
        model = .init(source: source, destination: destination)
        let panel = ToolWindowChrome.makePanel(title: "Upload Folder",
            size: .init(width: 608, height: 560), minimumSize: .zero)
        super.init(window: panel); panel.delegate = self
        let host = InterfaceHostingController(rootView: SFTPFolderUploadPreviewView(model: model, settings: settings, decide: { [weak self] in self?.finish($0) }))
        host.sizingOptions = []; panel.contentViewController = host
        ToolWindowChrome.install(in: panel, settings: settings,
            initialContentSize: .init(width: 608, height: 560),
            minimumContentSize: .init(width: 588, height: 520))
    }
    required init?(coder: NSCoder) { nil }
    func choose(in parent: NSWindow) async -> String? {
        guard !Task.isCancelled, let window else { return nil }; self.parent = parent
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                #if DEBUG
                lifecycleForVerification?("begin-sheet-enter",0)
                let began=ProcessInfo.processInfo.systemUptime
                #endif
                parent.beginSheet(window) { [self] _ in
                    #if DEBUG
                    lifecycleForVerification?("sheet-completion",0)
                    #endif
                    continuation.resume(returning: chosen)
                }
                #if DEBUG
                lifecycleForVerification?("begin-sheet-call",ProcessInfo.processInfo.systemUptime-began)
                #endif
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(nil) } }
    }
    func finish(_ value: String?) {
        guard !ending else { return }; ending = true; chosen = value
        if let window, parent?.attachedSheet === window {
            #if DEBUG
            lifecycleForVerification?("end-sheet-enter",0)
            let began=ProcessInfo.processInfo.systemUptime
            #endif
            parent?.endSheet(window)
            #if DEBUG
            lifecycleForVerification?("end-sheet-call",ProcessInfo.processInfo.systemUptime-began)
            let ordering=ProcessInfo.processInfo.systemUptime
            #endif
            window.orderOut(nil)
            #if DEBUG
            lifecycleForVerification?("order-out-call",ProcessInfo.processInfo.systemUptime-ordering)
            #endif
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(nil); return false }
}
