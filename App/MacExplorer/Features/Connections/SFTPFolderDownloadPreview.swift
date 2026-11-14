import AppKit
import Combine
import SwiftUI
@_spi(Qualification) import LocalStorage

/// Presentation has counts, not a session, reference or transfer authority.
struct SFTPFolderPreviewSummary {
    let files: Int, folders: Int
    let logicalBytes: UInt64
    let maximumBytes: UInt64
    init(prepared: SFTPPreparedFolderDownload) { files = prepared.files; folders = prepared.folders; logicalBytes = prepared.logicalBytes; maximumBytes = 1 << 30 }
    init(prepared: SMBPreparedFolderDownload) { files = prepared.files; folders = prepared.folders; logicalBytes = prepared.logicalBytes; maximumBytes = 256 << 20 }
    #if DEBUG
    init(generatedFiles: Int, folders: Int, bytes: UInt64) { files = generatedFiles; self.folders = folders; logicalBytes = bytes; maximumBytes = 1 << 30 }
    #endif
}
@MainActor final class SFTPFolderPreviewModel: ObservableObject {
    @Published var name: String
    @Published var details = false
    @Published var expired = false
    let summary: SFTPFolderPreviewSummary, destination: String
    init(summary: SFTPFolderPreviewSummary, destination: String, name: String) {
        self.summary = summary; self.destination = destination; self.name = name
    }
    var valid: Bool { SFTPFolderDownloadSelection.validLocalName(name) }
}
enum SFTPFolderPreviewChoice { case cancel, download(String), reviewAgain }

@MainActor private struct SFTPFolderPreviewView: View {
    @ObservedObject var model: SFTPFolderPreviewModel
    @ObservedObject var settings: BrowserSettings
    let decide: (SFTPFolderPreviewChoice) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill").interfaceFont(.largeTitle).foregroundStyle(Color(red: 0.70, green: 0.65, blue: 0.84))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download a folder").interfaceFont(.title2.weight(.semibold))
                    Text("One complete copy. Remote originals stay unchanged.").interfaceFont(.callout).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox {
                        HStack(spacing: 20) {
                            metric("Files", value: model.summary.files.formatted())
                            Divider()
                            metric("Folders", value: model.summary.folders.formatted())
                            Divider()
                            metric("To receive", value: FileSizeText.string(Int64(model.summary.logicalBytes)))
                        }.frame(maxWidth: .infinity).padding(8)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("New folder") {
                                TextField("Folder name", text: $model.name).textFieldStyle(ToolTextEntryStyle())
                                    .accessibilityIdentifier("sftp-folder-name")
                            }
                            LabeledContent("Save in") {
                                Text(model.destination).lineLimit(2).truncationMode(.middle)
                                    .help(model.destination).textSelection(.enabled)
                            }
                        }.padding(6)
                    }
                    Text(model.summary.files == 0 && model.summary.folders == 0
                         ? "This folder is empty. Its new copy will be empty too."
                         : "Includes empty folders. The new folder appears after the complete copy is checked.")
                        .interfaceFont(.callout).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("What gets downloaded", isExpanded: $model.details) {
                        Text("Downloads regular files and folders into one new folder. Existing items are preserved. Links and special items are unavailable. Up to 1,024 files and \(FileSizeText.string(Int64(model.summary.maximumBytes))). File permissions use standard local defaults; remote ownership, tags and special permissions are not copied. Stop closes this connection.")
                            .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    }.accessibilityIdentifier("sftp-folder-details")
                    if model.expired {
                        Label("Review this folder again before downloading.", systemImage: "arrow.clockwise")
                            .interfaceFont(.callout).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.scrollBounceBehavior(.basedOnSize)
            HStack {
                Text("Existing items are preserved").interfaceFont(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).minimumScaleFactor(0.8).layoutPriority(-1)
                Spacer()
                Button { decide(.cancel) } label: { Text("Cancel").interfaceFont(.callout) }.keyboardShortcut(.cancelAction)
                Button {
                    if model.expired { decide(.reviewAgain) } else if model.valid { decide(.download(model.name)) }
                } label: { Text(model.expired ? "Review Again" : "Download Folder").interfaceFont(.callout) }
                    .keyboardShortcut(.defaultAction).disabled(!model.expired && !model.valid).accessibilityIdentifier("sftp-folder-confirm")
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(!reduceMotion && settings.motion.allows(.pages) ? .easeInOut(duration: 0.24 * settings.motion.mode.durationScale) : nil, value: model.details)
            .task {
                do { try await Task.sleep(for: .seconds(295)); try Task.checkCancellation(); model.expired = true } catch {}
            }
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).interfaceFont(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            Text(title).interfaceFont(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor final class SFTPFolderDownloadPreview: NSWindowController, NSWindowDelegate {
    typealias Reviewer = @MainActor (SFTPFolderDownloadPreview) async -> SFTPFolderPreviewChoice
    let model: SFTPFolderPreviewModel
    private weak var parent: NSWindow?
    private var chosen = SFTPFolderPreviewChoice.cancel, ending = false
    convenience init(prepared: SFTPPreparedFolderDownload, parentPath: String, name: String, settings: BrowserSettings) {
        self.init(summary: .init(prepared: prepared), parentPath: parentPath, name: name, settings: settings)
    }
    convenience init(prepared: SMBPreparedFolderDownload, parentPath: String, name: String, settings: BrowserSettings) {
        self.init(summary: .init(prepared: prepared), parentPath: parentPath, name: name, settings: settings)
    }
    init(summary: SFTPFolderPreviewSummary, parentPath: String, name: String, settings: BrowserSettings) {
        model = .init(summary: summary, destination: parentPath, name: name)
        let panel = ToolWindowChrome.makePanel(title: "Download Folder",
            size: .init(width: 640, height: 530), minimumSize: .zero)
        super.init(window: panel); panel.delegate = self
        let host = InterfaceHostingController(rootView: SFTPFolderPreviewView(model: model, settings: settings, decide: { [weak self] in self?.finish($0) }))
        host.sizingOptions = []; panel.contentViewController = host
        ToolWindowChrome.install(in: panel, settings: settings,
            initialContentSize: .init(width: 640, height: 530),
            minimumContentSize: .init(width: 560, height: 440))
    }
    required init?(coder: NSCoder) { nil }
    /// Shared presentation decision for both concrete receivers. The caller
    /// keeps transfer authority and revalidates the destination after this.
    static func chooseIfNeeded(summary: SFTPFolderPreviewSummary, parentPath: String, name: String,
        settings: BrowserSettings, in window: NSWindow, requiresReview: Bool,
        review: Reviewer? = nil, onReview: () -> Void) async -> SFTPFolderPreviewChoice {
        guard !Task.isCancelled else { return .cancel }
        guard requiresReview || review != nil else { return .download(name) }
        let controller = SFTPFolderDownloadPreview(summary: summary, parentPath: parentPath, name: name, settings: settings)
        onReview()
        if let review { return await review(controller) }
        return await controller.choose(in: window)
    }
    func choose(in parent: NSWindow) async -> SFTPFolderPreviewChoice {
        guard !Task.isCancelled, let window else { return .cancel }; self.parent = parent
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in parent.beginSheet(window) { [self] _ in continuation.resume(returning: chosen) } }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.cancel) } }
    }
    func finish(_ choice: SFTPFolderPreviewChoice) {
        guard !ending else { return }; ending = true; chosen = choice
        if let window, parent?.attachedSheet === window { parent?.endSheet(window); window.orderOut(nil) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(.cancel); return false }
}
