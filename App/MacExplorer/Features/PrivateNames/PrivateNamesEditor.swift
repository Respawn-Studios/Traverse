import AppKit
import Combine
import ExplorerCore
import FileMemory
import SwiftUI

@MainActor
final class PrivateNamesEditorModel: ObservableObject {
    let owner: ApplicationPrivateNames
    let settings: BrowserSettings
    let observerID = UUID()
    @Published var nickname = ""
    @Published var alternateNames: [String] = []
    @Published var labels: [String] = []
    @Published var alternateDraft = ""
    @Published var labelDraft = ""
    @Published private(set) var source: URL?
    @Published private(set) var itemID: RememberedItemID?
    @Published private(set) var notice = ""
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published var showsConsent = false
    private var originalRevision: UInt64?
    private var originalNames: AuthoredNames?
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var loadGeneration = UUID()
    private var use: RememberedNameUse?
    private var observing = false
    private var withdrawn = false
    private var consentNotPersisted = false
    private var completionMessage: String?
    private var access: @MainActor @Sendable (URL) async -> (any Sendable)?
    var dismiss: (() -> Void)?
    var clearNativeUndo: (() -> Void)?
    var hasChanges: Bool {
        nickname != (originalNames?.nickname ?? "") || alternateNames != (originalNames?.alternateNames ?? [])
            || labels != (originalNames?.labels ?? []) || !alternateDraft.isEmpty || !labelDraft.isEmpty
    }
    init(owner: ApplicationPrivateNames, settings: BrowserSettings,
         access: @escaping @MainActor @Sendable (URL) async -> (any Sendable)?) {
        self.owner = owner; self.settings = settings; self.access = access
    }
    isolated deinit { loadTask?.cancel(); owner.stopObserving(observerID) }
    func select(_ url: URL) {
        guard !saving else { return }
        cancel(); source = url; withdrawn = false; itemID = nil; originalRevision = nil; originalNames = nil; consentNotPersisted = false
        nickname = ""; alternateNames = []; labels = []; alternateDraft = ""; labelDraft = ""; notice = ""
        observe(); reload()
    }
    private func observe() {
        guard !observing else { return }; observing = true
        owner.observe(observerID) { [weak self] change in
            guard let self else { return }
            switch change {
            case .yielding: self.use = nil; self.loadTask?.cancel(); self.loadGeneration = UUID()
            case .forget(let id) where id == nil || id == self.itemID:
                self.withdrawn = true; self.loadTask?.cancel(); self.loadGeneration = UUID(); self.use = nil
                self.nickname = ""; self.alternateNames = []; self.labels = []; self.alternateDraft = ""; self.labelDraft = ""
                self.itemID = nil; self.originalRevision = nil; self.originalNames = nil; self.showsConsent = false; self.loading = false
                self.clearNativeUndo?(); self.notice = "This item's saved names were withdrawn. Close this editor before remembering it again."
            case .access(let id) where id == self.itemID: self.use = nil
            case .closed: self.cancel()
            default: break
            }
        }
    }
    func reload() {
        guard let source, !withdrawn, !saving else { return }
        loadTask?.cancel(); use = nil; loading = true; let token = UUID(); loadGeneration = token
        loadTask = Task { [weak self] in
            guard let self else { return }
            let lease = await self.access(source)
            do {
                let found = try await self.owner.lookup(source, retaining: lease)
                guard !Task.isCancelled, self.loadGeneration == token, !self.withdrawn else { return }
                if let (snapshot, use) = found {
                    var value: RememberedNamesSnapshot?
                    guard snapshot.publish({ value = $0 }), let value else { throw RememberedReferenceFailure.stale }
                    self.use = use; self.itemID = value.id; self.originalRevision = value.revision; self.originalNames = value.names
                    self.nickname = value.names.nickname ?? ""; self.alternateNames = value.names.alternateNames; self.labels = value.names.labels
                }
                self.notice = ""
            } catch RememberedReferenceFailure.followingRequired { if self.loadGeneration == token { self.notice = "A new private description · following is enabled only after Remember." } }
            catch { if self.loadGeneration == token, !Task.isCancelled { self.notice = ApplicationPrivateNames.message(error) } }
            if self.loadGeneration == token { self.loading = false }
        }
    }
    func reloadCurrent() { if let itemID { editSaved(itemID) } else { reload() } }
    func editSaved(_ id: RememberedItemID) {
        cancel(); withdrawn = false; observe(); loading = true
        let token = UUID(); loadGeneration = token
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (snapshot, use) = try await self.owner.snapshot(id)
                var value: RememberedNamesSnapshot?
                guard snapshot.publish({ value = $0 }), let value, !Task.isCancelled, self.loadGeneration == token else { return }
                self.use = use; self.itemID = id; self.originalRevision = value.revision; self.originalNames = value.names
                self.nickname = value.names.nickname ?? ""; self.alternateNames = value.names.alternateNames; self.labels = value.names.labels
                self.source = try? await self.owner.availability(id).location
                self.notice = self.completionMessage ?? "Editing saved names. No source access is needed to change this description."
                self.completionMessage = nil
            } catch { if self.loadGeneration == token { self.notice = ApplicationPrivateNames.message(error) } }
            if self.loadGeneration == token { self.loading = false }
        }
    }
    func addAlternate() { let text = alternateDraft.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }; alternateNames.append(text); alternateDraft = "" }
    func addLabel() { let text = labelDraft.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }; labels.append(text); labelDraft = "" }
    func save(allowingFollowing: Bool? = nil) {
        guard source != nil || itemID != nil, !loading, !saving, !withdrawn else { return }
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() {
            notice = "Finish text composition before saving."; return
        }
        addAlternate(); addLabel()
        let names: AuthoredNames
        do { names = try AuthoredNames(nickname: nickname, alternateNames: alternateNames, labels: labels) }
        catch { notice = ApplicationPrivateNames.message(error); return }
        let id = itemID, revision = originalRevision
        let source = source
        let allowed = allowingFollowing ?? settings.privateNamesAllowFollowing
        saving = true; notice = "Saving…"; use = nil
        let diagnosticTrace = ApplicationDiagnostics.shared.begin(.privateNames)
        saveTask = Task { [weak self] in
            guard let self else { return }
            let lease = if id == nil, let source { await self.access(source) } else { nil as (any Sendable)? }
            do {
                let id = try await self.owner.save(names, source: source, id: id, revision: revision, access: lease, allowFollowing: allowed)
                ApplicationDiagnostics.shared.event(.privateNames, .completed, trace: diagnosticTrace)
                self.itemID = id; self.saving = false; self.notice = "Names saved."
                if self.consentNotPersisted { self.completionMessage = "Names saved. Following consent was not saved as a preference, so another Remember may ask again." }
                self.editSaved(id)
                if !self.consentNotPersisted { self.dismiss?() }
            } catch RememberedReferenceFailure.followingRequired { self.saving = false; self.showsConsent = true; self.notice = "" }
            catch {
                ApplicationDiagnostics.shared.event(.privateNames, .failed, trace: diagnosticTrace, error: DiagnosticErrors.project(error))
                self.saving = false; self.notice = ApplicationPrivateNames.message(error)
                if allowed && id == nil { self.notice += " Document following may already be enabled; your draft is kept." }
            }
        }
    }
    func allowAndSave() {
        guard !saving else { return }
        showsConsent = false; saving = true
        Task {
            do { try await settings.acceptPrivateNamesFollowing(); consentNotPersisted = false }
            catch { consentNotPersisted = true }
            saving = false
            save(allowingFollowing: true)
        }
    }
    func cancel() {
        loadTask?.cancel(); loadTask = nil; loadGeneration = UUID(); use = nil; loading = false
        nickname = ""; alternateNames = []; labels = []; alternateDraft = ""; labelDraft = ""; originalNames = nil
        source = nil; itemID = nil; originalRevision = nil; showsConsent = false
        clearNativeUndo?()
        if observing { owner.stopObserving(observerID); observing = false }
    }
}

struct PrivateNamesEditorView: View {
    @ObservedObject var model: PrivateNamesEditorModel
    var embedded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if embedded { form }
            else { ScrollView { form.frame(maxWidth: .infinity, alignment: .leading) } }
            if !model.showsConsent { actions }
        }
        .disabled(model.saving)
        .padding(embedded ? 0 : 22)
        .frame(minWidth: embedded ? 0 : 420)
    }
    private var form: some View {
        VStack(alignment: .leading, spacing: 13) {
            if model.showsConsent { consent }
            else {
                HStack {
                    Text("Names & Labels").interfaceFont(embedded ? .headline : .title2.weight(.semibold))
                    Spacer()
                    if model.loading || model.saving { ProgressView().controlSize(.small) }
                }
                if let source = model.source {
                    Text(source.lastPathComponent).interfaceFont(.subheadline.weight(.medium)).lineLimit(1)
                    Text(source.deletingLastPathComponent().path).interfaceFont(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nickname (optional)").interfaceFont(.caption.weight(.medium))
                    TextField("A name that comes naturally", text: $model.nickname).textFieldStyle(ToolTextEntryStyle())
                        .accessibilityIdentifier("private-nickname")
                }
                chipField(title: "Alternate search names", values: $model.alternateNames, draft: $model.alternateDraft, add: model.addAlternate)
                chipField(title: "Labels", values: $model.labels, draft: $model.labelDraft, add: model.addLabel)
                Text("Stored locally. Backups may retain older copies. File contents are not read; real filenames and Finder tags stay unchanged.")
                    .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Following moves and saves") {
                    Text("An explicit Remember may enable macOS document following after consent. Forget removes saved information without turning off that native metadata flag.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }.interfaceFont(.caption)
                if !model.notice.isEmpty { Text(model.notice).interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("private-names-notice") }

            }
        }
    }
    private var actions: some View {
        HStack {
            Button("Reload") { model.reloadCurrent() }.disabled(model.saving || model.loading)
            Spacer()
            if !embedded { Button("Cancel") { model.dismiss?() }.keyboardShortcut(.cancelAction).disabled(model.saving) }
            Button(model.itemID == nil ? "Remember" : "Save") { model.save() }
                .keyboardShortcut(.return, modifiers: [.command]).disabled(model.saving || model.loading)
                .accessibilityIdentifier("private-names-save")
        }
    }
    private func chipField(title: String, values: Binding<[String]>, draft: Binding<String>, add: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).interfaceFont(.caption.weight(.medium))
            if !values.wrappedValue.isEmpty {
                PrivateNameChipLayout(spacing: 6) {
                    ForEach(Array(values.wrappedValue.enumerated()), id: \.offset) { index, value in
                        HStack(spacing: 5) {
                            Text(value).lineLimit(1)
                            Button { values.wrappedValue.remove(at: index) } label: { Image(systemName: "xmark").interfaceFont(.system(size: 8, weight: .semibold)) }
                                .buttonStyle(.plain).accessibilityLabel("Remove \(value)")
                        }.interfaceFont(.caption).padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            HStack { TextField("Add a name or label, then Return", text: draft).textFieldStyle(ToolTextEntryStyle()).onSubmit(add); Button("Add", action: add) }
        }
    }
    private var consent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "tag").interfaceFont(.title).foregroundStyle(.tint)
            Text("Follow moves and saves").interfaceFont(.title2.weight(.semibold))
            Text("Traverse can enable macOS document following for items you choose to remember. This changes a native metadata flag so saved names can follow supported renames and saves.")
            Text("File contents are not read or changed.")
            Text("If saving fails, that flag may already be enabled. Forget removes Traverse's saved information; it does not turn off macOS document following.").foregroundStyle(.secondary)
            HStack { Button("Back") { model.showsConsent = false }; Spacer(); Button("Allow & Remember") { model.allowAndSave() }.buttonStyle(.borderedProminent) }
        }.interfaceFont(.callout).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
final class PrivateNamesSheet: NSWindowController, NSWindowDelegate {
    let model: PrivateNamesEditorModel
    init(owner: ApplicationPrivateNames, browser: BrowserViewController, source: URL?, itemID: RememberedItemID? = nil) {
        model = PrivateNamesEditorModel(owner: owner, settings: browser.settings, access: { [weak browser] url in await browser?.accessLifetime(for: [url]) })
        let window = ToolWindowChrome.makeWindow(title: "Names & Labels", size: .init(width: 475, height: 510),
            minimumSize: .init(width: 475, height: 460),
            content: InterfaceHostingController(rootView: PrivateNamesEditorView(model: model)),
            styleMask: [.titled, .closable, .resizable])
        super.init(window: window); window.delegate = self
        ToolWindowChrome.install(in: window, settings: browser.settings)
        model.dismiss = { [weak self] in self?.requestClose() }
        model.clearNativeUndo = { [weak window] in clearPrivateTextUndo(in: window) }
        if let itemID { model.editSaved(itemID) } else if let source { model.select(source) }
    }
    required init?(coder: NSCoder) { nil }
    func show(in parent: NSWindow) { guard let window else { return }; parent.beginSheet(window) }
    func finish() { model.cancel(); if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) } }
    private func requestClose() {
        guard !model.saving else { return }
        guard model.hasChanges, let window else { finish(); return }
        let alert = NSAlert(); alert.messageText = "Discard these changes?"
        alert.informativeText = "Your changes to the private description have not been saved."
        alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Keep Editing")
        // A sheet cannot host another sheet. Present the confirmation on the
        // originating window after ordering its editor out, then restore it.
        guard let parent = window.sheetParent else { return }
        parent.endSheet(window); window.orderOut(nil)
        Task { [weak self] in
            if await alert.beginSheetModal(for: parent) == .alertFirstButtonReturn { self?.finish() }
            else if let self { self.show(in: parent) }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { requestClose(); return false }
}

/// Intrinsic-width chips wrap without distributing a row's unused width into
/// large gaps. Work is bounded by the editor's 16 values in each field.
struct PrivateNameChipLayout: Layout {
    let spacing: CGFloat
    private func arrangement(width: CGFloat, subviews: Subviews) -> (CGSize, [(CGPoint, CGSize)]) {
        let width = max(1, width)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var positions: [(CGPoint, CGSize)] = []
        for item in subviews {
            let intrinsic = item.sizeThatFits(.unspecified)
            let size = item.sizeThatFits(.init(width: min(width, intrinsic.width), height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            positions.append((CGPoint(x: x, y: y), size)); usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), positions)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? 440, subviews: subviews).0
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrangement(width: bounds.width, subviews: subviews).1
        for (index, position) in positions.enumerated() {
            subviews[index].place(at: .init(x: bounds.minX + position.0.x, y: bounds.minY + position.0.y), anchor: .topLeading,
                proposal: .init(width: position.1.width, height: position.1.height))
        }
    }
}

@MainActor func clearPrivateTextUndo(in window: NSWindow?) {
    let editor = window?.firstResponder as? NSTextView
    editor?.undoManager?.removeAllActions()
    editor?.string = ""
    window?.makeFirstResponder(nil)
    window?.undoManager?.removeAllActions()
}
