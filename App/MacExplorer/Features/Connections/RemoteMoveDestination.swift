import AppKit
import LocalStorage
import SwiftUI

@MainActor private struct RemoteMoveDestinationView: View {
    @Bindable var model: RemoteMoveDestinationModel
    @ObservedObject var settings: BrowserSettings
    let decide: (String?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Field { case folder, name }
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(model.operation.title, systemImage: model.isCopy ? "doc.on.doc" : "folder")
                .interfaceFont(.title2.weight(.semibold))
            Text(model.server).interfaceFont(.callout).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: model.isFolder ? "folder" : "doc").interfaceFont(.title2)
                            .foregroundStyle(.secondary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.name).interfaceFont(.headline).textSelection(.enabled)
                                .lineLimit(3).truncationMode(.middle).help(model.name)
                            Text("From " + model.currentFolder).interfaceFont(.callout)
                                .foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Destination folder").interfaceFont(.headline)
                            TextField("/Folder", text: $model.path)
                                .textFieldStyle(ToolTextEntryStyle()).interfaceFont(.body)
                                .focused($focusedField, equals: .folder)
                                .accessibilityLabel("Destination folder on this server")
                                .accessibilityIdentifier("remote-move-destination")
                                .onSubmit { if model.canMove { decide(model.path) } }
                            if model.isCopy {
                                Text("New filename").interfaceFont(.headline)
                                TextField(model.name, text: $model.destinationName)
                                    .textFieldStyle(ToolTextEntryStyle()).interfaceFont(.body)
                                    .focused($focusedField, equals: .name)
                                    .accessibilityLabel("New filename, including extension")
                                    .accessibilityIdentifier("remote-copy-name")
                                    .onSubmit { if model.canMove { decide(model.path) } }
                            }
                            HStack(spacing: 10) {
                                Button { model.path = "/"; focusedField = .folder } label: { Text(model.rootTitle).interfaceFont(.callout) }
                                if !model.suggestions.isEmpty {
                                    Menu {
                                        ForEach(model.suggestions) { item in
                                            Button(item.title) { model.path = item.path }
                                        }
                                    } label: { Text("Recent Folders").interfaceFont(.callout) }
                                    .help("Use a folder already visited in this connection.")
                                }
                                Spacer(minLength: 0)
                            }
                            Text(model.issue ?? model.destinationNotice)
                                .interfaceFont(.callout)
                                .foregroundStyle(model.issue == nil ? Color.secondary : Color.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: InterfaceMetrics.points(34), alignment: .topLeading)
                                .accessibilityIdentifier("remote-move-feedback")
                            if model.isCopy {
                                Text("Other file details depend on the server.")
                                    .interfaceFont(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .help("Copies file contents on this server. Only supported permissions and dates are preserved; other file details are not cloned.")
                            }
                        }.padding(8)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.scrollBounceBehavior(.basedOnSize)
            HStack(spacing: 12) {
                Text(model.isCopy ? "Original kept · no automatic Undo" : "On this server · no automatic Undo")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button { decide(nil) } label: { Text("Cancel").interfaceFont(.callout) }
                    .keyboardShortcut(.cancelAction).fixedSize()
                    .accessibilityIdentifier("remote-move-cancel")
                Button { if model.canMove { decide(model.path) } } label: { Text(model.operation.buttonTitle).interfaceFont(.callout) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canMove).fixedSize()
                    .accessibilityIdentifier("remote-move-confirm")
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { focusedField = model.operation == .duplicate ? .name : .folder }
            .animation(reduceMotion || !settings.motion.allows(.pages) ? nil
                : .easeInOut(duration: 0.16 * settings.motion.mode.durationScale), value: model.issue)
    }
}

/// Reuses the common native sheet/chrome and text-field treatment. It owns no
/// network session or file operation, and Cancel cannot submit an action.
@MainActor final class RemoteMoveDestination: NSWindowController, NSWindowDelegate {
    let model: RemoteMoveDestinationModel
    private weak var parent: NSWindow?
    private var chosen: String?, ending = false
    private var diagnosticTrace: UUID?

    init(model: RemoteMoveDestinationModel, settings: BrowserSettings) {
        self.model = model
        let initialSize = NSSize(width: 580, height: model.isCopy ? 530 : 430)
        let panel = ToolWindowChrome.makePanel(title: model.operation.title,
            size: initialSize, minimumSize: .zero)
        super.init(window: panel); panel.delegate = self
        let host = InterfaceHostingController(rootView: RemoteMoveDestinationView(
            model: model, settings: settings, decide: { [weak self] in self?.finish($0) }))
        host.sizingOptions = []; panel.contentViewController = host
        ToolWindowChrome.install(in: panel, settings: settings,
            initialContentSize: initialSize,
            minimumContentSize: .init(width: InterfaceMetrics.points(480), height: InterfaceMetrics.points(370)))
    }
    required init?(coder: NSCoder) { nil }

    func choose(in parent: NSWindow) async -> String? {
        guard !Task.isCancelled, !ending, parent.attachedSheet == nil, let window else { return nil }
        self.parent = parent
        diagnosticTrace = ApplicationDiagnostics.shared.begin(model.isCopy ? .copy : .move)
        recordFocus(.presenting)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !ending else { continuation.resume(returning: nil); return }
                parent.beginSheet(window) { [self] _ in continuation.resume(returning: chosen) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(nil) } }
    }

    func finish(_ path: String?) {
        guard !ending else { return }
        guard path == nil || path == model.path && model.canMove else { return }
        ending = true; chosen = path
        recordFocus(path == nil ? .cancelled : .completed)
        if let window, parent?.attachedSheet === window {
            parent?.endSheet(window); window.orderOut(nil)
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(nil); return false }
    func windowDidBecomeKey(_ notification: Notification) { recordFocus(.admitted) }
    func windowDidResignKey(_ notification: Notification) { if !ending { recordFocus(.paused) } }

    /// Observe presentation/focus only. Never inspect the field editor's text,
    /// either path, the server label, a filename or individual key events.
    private func recordFocus(_ phase: DiagnosticPhase) {
        guard let diagnosticTrace else { return }
        ApplicationDiagnostics.shared.event(model.isCopy ? .copy : .move, phase,
            trace: diagnosticTrace, context: .init(.remoteDestinationReview,
                flags: window?.isKeyWindow == true ? [] : [.windowNotKey]))
    }
}
