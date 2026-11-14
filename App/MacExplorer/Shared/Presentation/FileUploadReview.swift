import AppKit
import Combine
import SwiftUI
@_spi(Qualification) import LocalStorage

/// Presentation only. Each concrete transfer owner supplies its own name rules
/// and mutation authority; sharing the review does not grant server access.
typealias RemoteUploadHistoryAction = @MainActor (BrowserSettings, NSWindow?) -> Void

/// Session-only presentation that follows a closed SMB/SFTP tab. It retains
/// no connection, source, body or mutation authority and is never serialized.
@MainActor struct RemoteClosedTransferNotice {
    let message: String
    let showHistory: RemoteUploadHistoryAction?
}

enum FileUploadReviewPolicy: Equatable {
    case directSFTP, stagedSMB
    var identifierPrefix: String { self == .directSFTP ? "sftp-upload" : "smb-upload" }
    var progressExplanation: String {
        switch self {
        case .directSFTP:
            "The new file appears while uploading. If interrupted, an incomplete copy may remain on the server for you to review."
        case .stagedSMB:
            "A working copy is verified before the new file appears. If interrupted, a working copy may remain on the server for you to review."
        }
    }
    var transferDetails: String {
        switch self {
        case .directSFTP:
            "Creates a new name without replacing an existing file, then reads back the uploaded data to verify it. Sends the data fork only, with standard read/write permissions (0644). Mac tags, ACLs and executable permissions are not copied. Files with a resource fork are refused. Stop closes this connection; incomplete copies are never retried or removed automatically."
        case .stagedSMB:
            "Sends the file to a new working name, reads it back to verify it, then publishes without replacing an existing file. Server permissions determine access. Mac tags, ACLs and executable permissions are not copied; files with a resource fork are refused. Stopping an active upload closes this connection. An interrupted result stays available for review and is never retried or removed automatically."
        }
    }
}

@MainActor final class FileUploadReviewModel: ObservableObject {
    @Published var name: String
    @Published var details = false
    let source: SFTPUploadSourceReview, destination: String
    let policy: FileUploadReviewPolicy
    private let nameIsValid: (String) -> Bool
    private let nameIsOccupied: (String) -> Bool
    init(source: SFTPUploadSourceReview, destination: String, policy: FileUploadReviewPolicy = .directSFTP,
         nameIsValid: @escaping (String) -> Bool = { $0.utf8.count <= 255 && (try? SFTPRemoteName(Data($0.utf8))) != nil },
         nameIsOccupied: @escaping (String) -> Bool = { _ in false }) {
        self.source = source; self.destination = destination; self.policy = policy
        self.nameIsValid = nameIsValid; self.nameIsOccupied = nameIsOccupied; name = source.name
    }
    var occupied: Bool { nameIsValid(name) && nameIsOccupied(name) }
    var valid: Bool { nameIsValid(name) && !occupied }
}
@MainActor private struct FileUploadReviewView: View {
    @ObservedObject var model: FileUploadReviewModel
    @ObservedObject var settings: BrowserSettings
    let decide: (String?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Upload a new file", systemImage: "arrow.up.doc").interfaceFont(.title2.weight(.semibold))
            Text(model.destination).interfaceFont(.callout).lineLimit(2).truncationMode(.middle).foregroundStyle(.secondary)
                .help(model.destination).textSelection(.enabled)
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Local file") {
                        Text(model.source.name).lineLimit(1).truncationMode(.middle)
                            .help(model.source.name).textSelection(.enabled)
                    }
                    LabeledContent("Size") { Text(ByteCountFormatter.string(fromByteCount: Int64(model.source.logicalBytes), countStyle: .file)) }
                    LabeledContent("Remote name") { TextField("New filename", text: $model.name).textFieldStyle(ToolTextEntryStyle()).accessibilityIdentifier(model.policy.identifierPrefix + "-name") }
                    if model.occupied {
                        Text("A matching name was found in this folder. Choose a different name.")
                            .interfaceFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(6)
            }
            Text("Existing remote files are preserved. Your local original stays unchanged.").interfaceFont(.callout)
            Text(model.policy.progressExplanation).interfaceFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Transfer details", isExpanded: $model.details) {
                Text(model.policy.transferDetails)
                    .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }.scrollBounceBehavior(.basedOnSize)
            HStack { Text("One selected file · up to 1 GiB").interfaceFont(.caption).foregroundStyle(.secondary); Spacer()
                Button { decide(nil) } label: { Text("Cancel").interfaceFont(.callout) }
                    .keyboardShortcut(.cancelAction).fixedSize()
                Button { if model.valid { decide(model.name) } } label: { Text("Upload").interfaceFont(.callout) }
                    .keyboardShortcut(.defaultAction).disabled(!model.valid).fixedSize().accessibilityIdentifier(model.policy.identifierPrefix + "-confirm") }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(!reduceMotion && settings.motion.allows(.pages) ? .easeInOut(duration: 0.22 * settings.motion.mode.durationScale) : nil, value: model.details)
    }
}
@MainActor final class FileUploadReview: NSWindowController, NSWindowDelegate {
    let model: FileUploadReviewModel
    private weak var parent: NSWindow?
    private var chosen: String?, ending = false
    init(source: SFTPUploadSourceReview, destination: String, settings: BrowserSettings,
         policy: FileUploadReviewPolicy = .directSFTP,
         nameIsValid: @escaping (String) -> Bool = { $0.utf8.count <= 255 && (try? SFTPRemoteName(Data($0.utf8))) != nil },
         nameIsOccupied: @escaping (String) -> Bool = { _ in false }) {
        model = .init(source: source, destination: destination, policy: policy, nameIsValid: nameIsValid, nameIsOccupied: nameIsOccupied)
        let panel = ToolWindowChrome.makePanel(title: "Upload File",
            size: .init(width: 588, height: 520), minimumSize: .zero)
        super.init(window: panel); panel.delegate = self
        let host = InterfaceHostingController(rootView: FileUploadReviewView(model: model, settings: settings, decide: { [weak self] in self?.finish($0) }))
        host.sizingOptions = []; panel.contentViewController = host
        ToolWindowChrome.install(in: panel, settings: settings,
            initialContentSize: .init(width: 588, height: 520),
            minimumContentSize: .init(width: 588, height: 520))
    }
    required init?(coder: NSCoder) { nil }
    func choose(in parent: NSWindow) async -> String? {
        guard !Task.isCancelled, let window else { return nil }; self.parent = parent
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in parent.beginSheet(window) { [self] _ in continuation.resume(returning: chosen) } }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(nil) } }
    }
    func finish(_ value: String?) {
        guard !ending else { return }; ending = true; chosen = value
        if let window, parent?.attachedSheet === window { parent?.endSheet(window); window.orderOut(nil) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(nil); return false }
}
