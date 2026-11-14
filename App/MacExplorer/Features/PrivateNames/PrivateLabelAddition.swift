import AppKit
import Combine
import FileMemory
import SwiftUI

enum PrivateLabelAdditionActivation {
    static let enabled = true
    static var available: Bool {
        #if DEBUG
        enabled || ProcessInfo.processInfo.arguments.contains("--check-private-labels")
        #else
        enabled
        #endif
    }
}
typealias PrivateLabelSelection = NameLabelTarget

@MainActor final class PrivateLabelAdditionModel: ObservableObject {
    let owner: ApplicationPrivateNames
    let settings: BrowserSettings
    let selection: [PrivateLabelSelection]
    @Published private(set) var titles: [String]
    @Published private(set) var labels: [String] = []
    @Published var draft = ""
    @Published private(set) var notice = ""
    @Published private(set) var saving = false
    @Published private(set) var withdrawn = false
    private let observer = UUID()
    private var work: Task<Void, Never>?
    private var generation = UUID()
    var dismiss: (() -> Void)?
    var clearUndo: (() -> Void)?
    var canSave: Bool { !withdrawn && !saving && (!labels.isEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    init(owner: ApplicationPrivateNames, settings: BrowserSettings, selection: [PrivateLabelSelection], titles: [String]) {
        self.owner = owner; self.settings = settings; self.selection = selection; self.titles = Array(titles.prefix(3))
        owner.observe(observer) { [weak self] change in
            guard let self else { return }
            switch change {
            case .forget(let id): self.forget(id)
            case .closed: self.withdraw()
            case .yielding: self.storageYield()
            default: break
            }
        }
    }
    isolated deinit { work?.cancel(); owner.stopObserving(observer) }
    func addDraft() {
        guard !saving, !withdrawn else { return }
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            labels = try AuthoredNames(labels: labels + [value]).labels
            draft = ""; notice = ""
        } catch { notice = "Add up to 16 short labels. Existing labels stay as they are." }
    }
    func remove(_ label: String) { if !saving && !withdrawn { labels.removeAll { $0 == label } } }
    func save() {
        guard canSave else { return }
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() {
            notice = "Finish text composition before saving."; return
        }
        addDraft()
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !labels.isEmpty else { return }
        let values = labels, token = UUID(); generation = token; saving = true; notice = "Saving labels…"
        work = Task { [self] in
            defer { work = nil; saving = false }
            do {
                _ = try await owner.addPrivateLabels(selection, labels: values) { [weak self] in
                    self?.withdrawn == false && self?.generation == token
                }
                if !withdrawn, generation == token { saving = false; dismiss?() }
            } catch {
                guard !withdrawn, generation == token else { return }
                if error as? NameIndexFailure == .staleEdit {
                    notice = "Some saved descriptions changed. Close this editor, refresh the list and select them again. Nothing from this addition was applied."
                } else if error as? NameStoreFailure == .uncertainCommit {
                    notice = "The Save may have completed. Close this editor and use Recover Saved Names before making another change."
                } else if error as? NameIndexFailure == .invalidInput || error as? NameIndexFailure == .projectionLimit {
                    notice = "One or more items would have too many labels. No items were changed; edit that description or choose fewer labels."
                } else { notice = ApplicationPrivateNames.message(error) }
            }
        }
    }
    func cancel() { if !saving { withdraw() } }
    func selectionChanged(_ ids: Set<RememberedItemID>) {
        if !saving, ids != Set(selection.map(\.id)) { withdraw() }
    }
    func storageYield() { if !saving { withdraw() } }
    func forget(_ id: RememberedItemID?) { if id == nil || selection.contains(where: { $0.id == id }) { withdraw() } }
    func retire() {
        guard !withdrawn else { return }
        withdrawn = true; generation = UUID(); work?.cancel()
        titles = []; labels = []; draft = ""; notice = ""
        clearUndo?(); owner.stopObserving(observer)
    }
    func withdraw() { guard !withdrawn else { return }; retire(); dismiss?() }
    func drain() async { if let work { await work.value } }
}

private struct PrivateLabelAdditionView: View {
    @ObservedObject var model: PrivateLabelAdditionModel
    @ObservedObject var settings: BrowserSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "tag").interfaceFont(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add labels to \(model.selection.count) item\(model.selection.count == 1 ? "" : "s")").interfaceFont(.title2.weight(.semibold))
                    Text("Private labels make these items easier to find.").interfaceFont(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.titles.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(model.titles.enumerated()), id: \.offset) { _, title in Text(title).lineLimit(1).truncationMode(.middle) }
                    if model.selection.count > model.titles.count { Text("and \(model.selection.count - model.titles.count) more").foregroundStyle(.secondary) }
                }.interfaceFont(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("New labels").interfaceFont(.caption.weight(.medium))
                HStack {
                    TextField("Add a label, then Return", text: $model.draft).textFieldStyle(ToolTextEntryStyle()).onSubmit(model.addDraft)
                        .accessibilityIdentifier("private-label-draft")
                    Button("Add", action: model.addDraft).disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.disabled(model.saving || model.withdrawn)
                ScrollView {
                    PrivateNameChipLayout(spacing: 6) {
                        ForEach(model.labels, id: \.self) { label in
                            HStack(spacing: 5) {
                                Text(label).lineLimit(1)
                                Button { model.remove(label) } label: { Image(systemName: "xmark").interfaceFont(.system(size: 8, weight: .semibold)) }
                                    .buttonStyle(.plain).accessibilityLabel("Remove \(label)")
                            }.interfaceFont(.caption).padding(.horizontal, 7).padding(.vertical, 4)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }.toolPageEntrance(model.labels.count, enabled: !model.withdrawn && settings.motion.allows(.pages), mode: settings.motion.mode)
                }.frame(height: 78).disabled(model.saving || model.withdrawn)
            }
            Text("Existing nicknames, alternate names and labels stay. This changes saved descriptions only; your files stay as they are.")
                .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(model.notice.isEmpty ? " " : model.notice).interfaceFont(.caption).foregroundStyle(.secondary)
                .lineLimit(3).frame(height: 42, alignment: .topLeading).accessibilityIdentifier("private-label-outcome")
            HStack {
                if model.saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction).disabled(model.saving)
                Button("Add Labels", action: model.save).keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!model.canSave).buttonStyle(.borderedProminent).accessibilityIdentifier("private-label-save")
            }
        }.padding(22).frame(minWidth: 460)
            .transaction { if model.withdrawn { $0.animation = nil; $0.disablesAnimations = true } }
    }
}

@MainActor final class PrivateLabelAdditionSheet: NSWindowController, NSWindowDelegate {
    let model: PrivateLabelAdditionModel
    var onClose: (() -> Void)?
    private var finished = false
    #if DEBUG
    private(set) var finishAttemptsForVerification = 0
    private(set) var nativeIntervalsForVerification: [String: Double] = [:]
    #endif
    init(owner: ApplicationPrivateNames, settings: BrowserSettings, selection: [PrivateLabelSelection], titles: [String]) {
        model = PrivateLabelAdditionModel(owner: owner, settings: settings, selection: selection, titles: titles)
        let window = ToolWindowChrome.makeWindow(title: "Add Private Labels", size: .init(width: 485, height: 440),
            minimumSize: .zero, content: InterfaceHostingController(rootView: PrivateLabelAdditionView(model: model, settings: settings)),
            styleMask: [.titled, .closable])
        super.init(window: window); window.delegate = self
        ToolWindowChrome.install(in: window, settings: settings)
        model.clearUndo = { [weak window] in clearPrivateTextUndo(in: window) }
        model.dismiss = { [weak self] in self?.finish() }
    }
    required init?(coder: NSCoder) { nil }
    func show(in parent: NSWindow) {
        guard !finished, let window, parent.attachedSheet == nil else { return }
        #if DEBUG
        let began = CACurrentMediaTime()
        defer { nativeIntervalsForVerification["beginSheet"] = CACurrentMediaTime() - began }
        #endif
        parent.beginSheet(window)
    }
    func finish() {
        #if DEBUG
        finishAttemptsForVerification += 1
        #endif
        guard !finished else { return }
        finished = true
        #if DEBUG
        var began = CACurrentMediaTime()
        #endif
        model.retire()
        #if DEBUG
        nativeIntervalsForVerification["retire"] = CACurrentMediaTime() - began
        began = CACurrentMediaTime()
        #endif
        if let window { window.sheetParent?.endSheet(window) }
        #if DEBUG
        nativeIntervalsForVerification["endSheet"] = CACurrentMediaTime() - began
        began = CACurrentMediaTime()
        #endif
        window?.orderOut(nil)
        #if DEBUG
        nativeIntervalsForVerification["orderOut"] = CACurrentMediaTime() - began
        began = CACurrentMediaTime()
        #endif
        let completion = onClose; onClose = nil; completion?()
        #if DEBUG
        nativeIntervalsForVerification["completion"] = CACurrentMediaTime() - began
        #endif
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.cancel(); return false }
}
