import AppKit
import SwiftUI

/// Embed this single card in the existing Settings -> General page. The caller
/// supplies the application-owned coordinator; this view never creates one.
@MainActor struct FolderDefaultSettingsCard: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @ObservedObject private var owner: FolderDefaultCoordinator
    @ObservedObject private var presentation: FolderDefaultSettingsPresentation
    init(owner: FolderDefaultCoordinator, presentation: FolderDefaultSettingsPresentation) {
        self.owner = owner
        self.presentation = presentation
    }
    @ViewBuilder private var actionButtons: some View {
        Button(owner.traverse?.bundleIdentifier == FolderDefaultIdentityPolicy.previewIdentifier ? "Make Traverse Preview Default" : "Make Traverse Default") { presentation.present(.makeTraverse) }
            .disabled(!presentation.isActive || !owner.canMakeDefault)
        Button("Restore Previous") { presentation.present(.restorePrevious) }
            .disabled(!presentation.isActive || !owner.canRestorePrevious)
    }
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Current app: \(owner.current?.name ?? "Unavailable")")
                        .interfaceFont(.callout).textSelection(.enabled)
                    Spacer(minLength: 8)
                    if owner.isBusy { ProgressView().controlSize(.small) }
                    Button("Refresh", action: owner.refresh).disabled(owner.isBusy)
                }
                Text(owner.detail).interfaceFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if owner.permitsChanges {
                    if interfaceScale >= 1.3 { VStack(alignment: .leading, spacing: 8) { actionButtons } }
                    else { HStack { actionButtons } }
                }
                if owner.permitsChanges, let recovery = owner.recovery {
                    Text("Saved previous app: \(recovery.previous.name)")
                        .interfaceFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if owner.permitsChanges {
                    Text("Finder remains available. Some apps open Finder directly. Open and Save dialogs keep their usual behavior. Changing the folder app does not grant folder access.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if IncomingFolderService.available {
                    Label(owner.permitsChanges
                        ? "Traverse can also receive folders opened explicitly with it. This does not change your folder app."
                        : "In Finder, select a folder, then choose Services → Open in Traverse.", systemImage: "arrow.up.forward.app")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        } label: { Label("Default Folder App", systemImage: "folder.badge.gearshape") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            presentation.refresh()
        }
    }
}

