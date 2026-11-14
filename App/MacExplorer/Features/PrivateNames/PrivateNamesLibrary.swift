import AppKit
import Combine
import ExplorerCore
import FileMemory
import SwiftUI

struct PrivateNameRow: Identifiable {
    let names: RememberedNamesSnapshot
    var id: RememberedItemID { names.id }
    var availability: RememberedReferenceAvailability?
    var location: URL?
    var title: String { names.names.nickname ?? location?.lastPathComponent ?? "Saved description" }
    var stateText: String {
        switch availability {
        case .available: "Available"
        case .unavailable: "Unavailable"
        case .accessNeeded: "Access needed"
        case .needsRelink: "Needs Relink"
        case .needsReconciliation: "Needs reconciliation"
        case .accessRemoved: "Access removed"
        case .unsupported: "Unsupported reference"
        case nil: "Checking…"
        }
    }
}

@MainActor
final class PrivateNamesLibraryModel: ObservableObject {
    let owner: ApplicationPrivateNames
    let observer = UUID()
    @Published var query = ""
    @Published var labelOnly = false
    @Published var selectedIDs = Set<RememberedItemID>() {
        didSet { if selectedIDs != oldValue { labelSheet?.model.selectionChanged(selectedIDs) } }
    }
    var selected: RememberedItemID? {
        get { selectedIDs.count == 1 ? selectedIDs.first : nil }
        set { selectedIDs = newValue.map { [$0] } ?? [] }
    }
    var labelSheet: PrivateLabelAdditionSheet?
    var canAddLabels: Bool { PrivateLabelAdditionActivation.available && !owner.isSaving && !loading && (1...64).contains(selectedIDs.count)
        && selectedIDs.isSubset(of: Set(rows.map(\.id))) && window?.attachedSheet == nil }
    @Published private(set) var rows: [PrivateNameRow] = []
    @Published private(set) var notice = ""
    @Published private(set) var loading = false
    @Published private(set) var hasNext = false
    weak var browser: BrowserViewController?
    weak var window: NSWindow?
    var editSheet: PrivateNamesSheet?
    private var task: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var generation = UUID()
    private var cursor: RememberedNameCursor?
    private var uses: [RememberedNameUse] = []
    init(owner: ApplicationPrivateNames) { self.owner = owner }
    isolated deinit { task?.cancel(); actionTask?.cancel(); maintenanceTask?.cancel(); owner.stopObserving(observer) }
    var selection: PrivateNameRow? { rows.first { $0.id == selected } }
    func start(browser: BrowserViewController) {
        self.browser = browser
        owner.observe(observer) { [weak self] change in
            guard let self else { return }
            switch change {
            case .yielding: self.labelSheet?.model.storageYield(); self.retire(preservingMaintenance: true)
            case .forget(let id):
                self.labelSheet?.model.forget(id)
                self.retire(); self.rows.removeAll { id == nil || $0.id == id }; self.selected = nil
                self.query = ""; clearPrivateTextUndo(in: self.window)
            case .access(let id):
                self.actionTask?.cancel(); self.retire()
                if let row = self.rows.firstIndex(where: { $0.id == id }) { self.rows[row].availability = .accessRemoved }
            case .changed: self.reload()
            case .closed: self.close()
            }
        }
        reload()
    }
    func retire(preservingMaintenance: Bool = false) {
        generation = UUID(); task?.cancel(); actionTask?.cancel(); task = nil; actionTask = nil
        if !preservingMaintenance { maintenanceTask?.cancel(); maintenanceTask = nil }
        uses = []; cursor = nil; hasNext = false; loading = false
    }
    func close() { labelSheet?.model.withdraw(); retire(); rows = []; selected = nil; query = ""; notice = ""; owner.stopObserving(observer) }
    func reload(more: Bool = false) {
        task?.cancel(); generation = UUID(); let token = generation
        let previous = more ? cursor : nil
        if !more { uses = []; rows = []; cursor = nil; hasNext = false }
        loading = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = if let previous { try await self.owner.next(previous) }
                    else { try await self.owner.list(query: self.query, labelOnly: self.labelOnly) }
                guard self.generation == token, !Task.isCancelled else { return }
                guard let (page, use) = result else { self.notice = "No items remembered yet. Choose a file or folder, then Names & Labels."; self.loading = false; return }
                defer { withExtendedLifetime(use) {} }
                var values: [RememberedNameMatch] = []
                guard page.publish({ values = $0 }) else { throw RememberedReferenceFailure.stale }
                self.uses.append(use); self.rows.append(contentsOf: values.map { PrivateNameRow(names: $0.item) })
                if self.uses.count > 4 { self.uses.removeFirst(); self.rows.removeFirst(min(64, self.rows.count)) }
                self.selectedIDs.formIntersection(Set(self.rows.map(\.id)))
                self.cursor = page.next; self.hasNext = page.next != nil
                self.notice = page.coverage == .complete ? "" : "Saved-name query reached its limit. Refine the query to check more."
                self.loading = false
                // Two reference checks at a time, only for the newly visible page.
                var index = 0
                await withTaskGroup(of: (RememberedItemID, RememberedReferenceDisplay?).self) { group in
                    func add(_ id: RememberedItemID) { group.addTask { (id, try? await self.owner.availability(id)) } }
                    while index < min(2, values.count) { add(values[index].item.id); index += 1 }
                    while let (id, display) = await group.next() {
                        guard self.generation == token, !Task.isCancelled else { group.cancelAll(); return }
                        if let row = self.rows.firstIndex(where: { $0.id == id }) {
                            self.rows[row].availability = display?.availability ?? .unavailable
                            self.rows[row].location = display?.location
                        }
                        if index < values.count { add(values[index].item.id); index += 1 }
                    }
                }
            } catch { if self.generation == token, !Task.isCancelled { self.notice = ApplicationPrivateNames.message(error); self.loading = false } }
        }
    }
    func addLabels() {
        guard canAddLabels, let window, let browser else { return }
        let selectedRows = rows.filter { selectedIDs.contains($0.id) }
        let sheet = PrivateLabelAdditionSheet(owner: owner, settings: browser.settings,
            selection: selectedRows.map { .init(id: $0.id, revision: $0.names.revision) },
            titles: selectedRows.prefix(3).map(\.title))
        labelSheet = sheet
        sheet.onClose = { [weak self, weak sheet] in if self?.labelSheet === sheet { self?.labelSheet = nil } }
        sheet.show(in: window)
    }
    func edit() {
        guard let selection, let browser, let window else { return }
        let sheet = PrivateNamesSheet(owner: owner, browser: browser, source: selection.location, itemID: selection.id)
        editSheet = sheet; sheet.show(in: window)
    }
    func open(reveal: Bool = false) {
        guard let row = selection, row.availability == .available, let browser else { return }
        actionTask?.cancel(); let token = generation, id = row.id
        actionTask = Task { [weak self, weak browser] in
            guard let self, let browser else { return }
            do {
                let entry = try await self.owner.entry(id)
                let validation = SearchResultOpenReader()
                try await self.owner.use(id) { url in
                    guard url == entry.url, await validation.validate(entry) == .ready else { throw RememberedReferenceFailure.changed }
                    try Task.checkCancellation()
                    try await MainActor.run {
                        guard self.generation == token, self.selected == id else { throw RememberedReferenceFailure.stale }
                        if reveal || entry.kind == .directory {
                            if let workspace = browser.workspace { workspace.resumeWorkspace() } else { browser.resumeBrowser() }
                            browser.view.window?.makeKeyAndOrderFront(nil)
                            browser.navigate(to: .directory(reveal ? entry.url.deletingLastPathComponent() : entry.url))
                        } else if !NSWorkspace.shared.open(url) { throw RememberedReferenceFailure.unavailable }
                    }
                }
            } catch { if self.generation == token, !Task.isCancelled { self.notice = ApplicationPrivateNames.message(error) } }
        }
    }
    func forget() {
        guard let row = selection, let window, !owner.isSaving else { return }
        let id = row.id
        let alert = NSAlert(); alert.messageText = "Forget this item?"
        alert.informativeText = "Remove its nickname, alternate names and labels from Traverse. The source file stays in place. There is no Undo; older backups or exports are unchanged."
        alert.addButton(withTitle: "Forget"); alert.addButton(withTitle: "Cancel")
        Task { [weak self] in
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn, let self else { return }
            do { _ = try await self.owner.forget(id) } catch { self.notice = ApplicationPrivateNames.message(error) }
        }
    }
    func removeAccess() {
        guard let row = selection, let window, !owner.isSaving else { return }
        let alert = NSAlert(); alert.messageText = "Remove reference access?"
        alert.informativeText = "Keep your saved names while removing this remembered reference's access. macOS permissions and independent browser access stay unchanged."
        alert.addButton(withTitle: "Remove Access"); alert.addButton(withTitle: "Cancel")
        Task { [weak self] in
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn, let self else { return }
            do { try await self.owner.removeAccess(row.id) } catch { self.notice = ApplicationPrivateNames.message(error) }
        }
    }
    func relink() {
        guard let row = selection, let window, let browser, !owner.isSaving else { return }
        let token = generation
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Choose Item"; panel.message = "Choose the file or folder for these saved names. A confirmation follows."
        Task { [weak self] in
            guard await panel.beginSheetModal(for: window) == .OK, let chosen = panel.url, let self, self.generation == token else { return }
            let alert = NSAlert(); alert.messageText = "Relink these saved names?"
            alert.informativeText = "Previous: \(row.location?.path ?? "No verified location")\n\nChosen: \(chosen.path)\n\nThe saved description will refer to this chosen item. Files are not moved or renamed."
            alert.addButton(withTitle: "Relink This Item"); alert.addButton(withTitle: "Cancel")
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn, self.generation == token else { return }
            let access = await browser.accessLifetime(for: [chosen])
            do { try await self.owner.relink(row.id, source: chosen, access: access, allowFollowing: browser.settings.privateNamesAllowFollowing) }
            catch RememberedReferenceFailure.alreadyRemembered(let existing) { self.selected = existing; self.notice = "That item is already remembered. Its existing description was selected; no records were merged." }
            catch RememberedReferenceFailure.followingRequired { self.notice = "This item needs document following. Review the setting under Privacy & Search, then choose Relink again." }
            catch { self.notice = ApplicationPrivateNames.message(error) }
        }
    }
    func repair(_ action: NameStoreOpenAction) {
        Task { [weak self] in
            guard let self else { return }
            do { try await self.owner.storageAction(action) } catch { self.notice = ApplicationPrivateNames.message(error) }
        }
    }
    func enableMoveFollowing() {
        guard let window, !owner.isSaving else { return }
        let members = PrivateMoveActivation.membersEnabled
        let alert = NSAlert(); alert.messageText = members && owner.moveContinuityAvailable
            ? "Follow saved names inside moved folders?" : "Enable saved names to follow Explorer moves?"
        alert.informativeText = members
            ? "Update this local catalog to follow verified items, including saved items inside moved folders. Saved locations help find candidates; externally changed locations may need Relink. Your descriptions stay local, and no file contents are indexed. Older builds cannot use the updated catalog. This update does not move files or change operation history."
            : "Update this local saved-name catalog for Move and Undo following. Older builds cannot read or write the updated catalog. Your descriptions stay local; no file contents are indexed. Interrupted updates can be reviewed here without moving files."
        alert.addButton(withTitle: "Update Saved Names"); alert.addButton(withTitle: "Cancel")
        maintenanceTask = Task { [weak self] in
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn, let self, !Task.isCancelled else { return }
            do { try await self.owner.storageAction(members ? .upgradeMoveMembers : .upgradeMoveContinuity); self.reload() }
            catch { self.notice = ApplicationPrivateNames.message(error) }
        }
    }
    func reconcile() {
        guard let item = selection?.id, let browser, let engine = browser.recoverableFileOperations,
              !owner.isSaving else { return }
        let operations = browser.operationCoordinator, token = UUID()
        guard operations.beginPreparation(owner: token) else { notice = "Wait for file operations to finish or pause the queue before reconciling."; return }
        maintenanceTask = Task { [weak self] in
            defer { operations.finishPreparation(owner: token) }
            guard let self, !Task.isCancelled else { return }
            do { try await self.owner.reconcileMoveNames(item, engine: engine); self.reload() }
            catch { self.notice = "This location cannot be confirmed yet. Your description is still saved. Review the file operation, or use Relink to choose its location." }
        }
    }
    func retryPrivacyAction(forget: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do { if forget { try await self.owner.retryForget() } else { try await self.owner.retryAccessRemoval() } }
            catch { self.notice = ApplicationPrivateNames.message(error) }
        }
    }
}

struct PrivateNamesLibraryView: View {
    @ObservedObject var model: PrivateNamesLibraryModel
    @ObservedObject var owner: ApplicationPrivateNames
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text("Remembered Items").interfaceFont(.title2.weight(.semibold)); Text("Private names and labels · stored locally").interfaceFont(.caption).foregroundStyle(.secondary) }
                Spacer()
                if PrivateLabelAdditionActivation.available {
                    Button("Add Labels…") { model.addLabels() }.disabled(!model.canAddLabels)
                        .help(model.selectedIDs.count > 64 ? "Select up to 64 remembered items at a time." : "Add private labels to the selected descriptions.")
                        .accessibilityIdentifier("remembered-add-labels")
                }
                if model.loading { ProgressView().controlSize(.small) }
            }.padding(18)
            HStack {
                TextField("Search saved names and labels", text: $model.query).textFieldStyle(ToolTextEntryStyle()).onSubmit { model.reload() }
                Toggle("Exact label", isOn: $model.labelOnly).toggleStyle(.checkbox)
                Button("Search") { model.reload() }; Button("Refresh") { model.reload() }
                if owner.enablesImport {
                    Button("Import…") { if let window = model.window { owner.chooseNameImport(in: window) } }
                        .disabled(owner.isSaving || owner.importInProgress)
                }
            }.padding(.horizontal, 18).padding(.bottom, 12)
            Divider()
            HSplitView {
                List(selection: $model.selectedIDs) {
                    ForEach(model.rows) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(row.title).lineLimit(1); Spacer(); Text(row.stateText).interfaceFont(.caption).foregroundStyle(.secondary) }
                            if let location = row.location { Text(location.path).interfaceFont(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            if !row.names.names.labels.isEmpty { Text(row.names.names.labels.joined(separator: " · ")).interfaceFont(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }.padding(.vertical, 5).tag(row.id)
                    }
                }.frame(minWidth: 340, minHeight: 280).accessibilityIdentifier("remembered-items-list").disabled(owner.isSaving)
                VStack(alignment: .leading, spacing: 12) {
                    if let row = model.selection {
                        Text(row.location?.lastPathComponent ?? "Saved description").interfaceFont(.headline).lineLimit(2)
                        Text(row.location?.path ?? "No verified location").interfaceFont(.caption).foregroundStyle(.secondary).lineLimit(3)
                        Text(row.stateText).interfaceFont(.caption)
                        Divider()
                        if let nickname = row.names.names.nickname { Text("Nickname").interfaceFont(.caption).foregroundStyle(.secondary); Text(nickname) }
                        if !row.names.names.alternateNames.isEmpty { Text("Alternate search names").interfaceFont(.caption).foregroundStyle(.secondary); Text(row.names.names.alternateNames.joined(separator: " · ")) }
                        HStack { Button("Open") { model.open() }; Button("Show in Explorer") { model.open(reveal: true) } }.disabled(row.availability != .available)
                        HStack { Button("Edit…") { model.edit() }; Button(row.availability == .accessRemoved ? "Restore Access…" : "Relink…") { model.relink() } }
                        if owner.enablesMoveContinuity && row.availability == .needsReconciliation {
                            Button("Reconcile Saved Names") { model.reconcile() }.accessibilityIdentifier("reconcile-saved-names")
                        }
                        Button("Remove Access…") { model.removeAccess() }.disabled(row.availability == .accessRemoved)
                        Spacer()
                        Button("Forget…", role: .destructive) { model.forget() }.accessibilityIdentifier("remembered-item-forget")
                    } else if model.selectedIDs.count > 1 {
                        Image(systemName: "tag").interfaceFont(.title).foregroundStyle(.secondary)
                        Text("\(model.selectedIDs.count) remembered items selected").interfaceFont(.headline)
                        Text("Add shared private labels to make these items easier to find. Existing names and files stay as they are.")
                            .interfaceFont(.callout).foregroundStyle(.secondary)
                        Button("Add Labels…") { model.addLabels() }.disabled(!model.canAddLabels)
                        if model.selectedIDs.count > 64 { Text("Choose up to 64 items at a time.").interfaceFont(.caption).foregroundStyle(.secondary) }
                        Spacer()
                    } else { Text(model.rows.isEmpty ? "No remembered items yet." : "Select a saved description.").foregroundStyle(.secondary); Spacer() }
                }.padding(18).frame(minWidth: 270, maxWidth: 380).disabled(owner.isSaving)
                    // Only the enclosing entrance animates. Privacy-driven
                    // child removal must never inherit a default fade-out.
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
                    .toolPageEntrance(model.selectedIDs, enabled: model.browser?.settings.motion.allows(.pages) ?? true,
                        mode: model.browser?.settings.motion.mode ?? .full)
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Newest first · \(model.rows.count) visible\(model.selectedIDs.isEmpty ? "" : " · \(model.selectedIDs.count) selected")").interfaceFont(.caption).foregroundStyle(.secondary)
                    Spacer(); if model.hasNext { Button("Next Page") { model.reload(more: true) } }
                }
                if !model.notice.isEmpty { Text(model.notice).interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if owner.enablesMoveContinuity && (!owner.moveContinuityAvailable
                    || PrivateMoveActivation.membersEnabled && !owner.moveMembersAvailable) && !model.rows.isEmpty {
                    HStack {
                        Text(owner.moveContinuityAvailable ? "Extend following to saved items inside moved folders."
                            : "Update saved names once to follow future Explorer moves and Undo.").interfaceFont(.caption).foregroundStyle(.secondary)
                        Spacer(); Button(owner.moveContinuityAvailable ? "Extend Move Following…" : "Enable Move Following…") {
                            model.enableMoveFollowing()
                        }.disabled(owner.isSaving)
                    }
                }
                if !owner.moveNotice.isEmpty { Text(owner.moveNotice).interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if !owner.moveCoverageNotice.isEmpty {
                    Text(owner.moveCoverageNotice).interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !owner.status.isEmpty {
                    Text(owner.status).interfaceFont(.caption).foregroundStyle(.secondary)
                    HStack {
                        if owner.pendingForget != nil { Button("Retry Forget") { model.retryPrivacyAction(forget: true) } }
                        if owner.pendingAccessRemoval != nil { Button("Retry Remove Access") { model.retryPrivacyAction(forget: false) } }
                        if owner.pendingForget == nil && owner.pendingAccessRemoval == nil && [.forgetPending, .accessRemovalPending, .recoveryRequired, .initializationIncomplete].contains(owner.storageStatus) { Button("Recover Saved Names") { model.repair(.recover) } }
                        if owner.storageStatus == .referenceUpdateRequired { Button("Update References") { model.repair(.upgradeReferences) } }
                        if owner.storageStatus == .indexUpdateRequired { Button("Update Search Index") { model.repair(.updateIndex) } }
                    }.disabled(owner.isSaving)
                }
            }.padding(14)
        }.frame(minWidth: 740, minHeight: 480)
    }
}

@MainActor
final class PrivateNamesWindowController: NSWindowController, NSWindowDelegate {
    let model: PrivateNamesLibraryModel
    init(owner: ApplicationPrivateNames) {
        model = PrivateNamesLibraryModel(owner: owner)
        let window = ToolWindowChrome.makeWindow(title: "Remembered Items", size: .init(width: 860, height: 560),
            minimumSize: .init(width: 740, height: 480),
            content: InterfaceHostingController(rootView: PrivateNamesLibraryView(model: model, owner: owner)))
        super.init(window: window); window.delegate = self; model.window = window
    }
    required init?(coder: NSCoder) { nil }
    func show(browser: BrowserViewController) {
        if let window { ToolWindowChrome.install(in: window, settings: browser.settings) }
        model.start(browser: browser)
        if let window, !window.isVisible { ToolWindowChrome.position(window, relativeTo: browser.view.window) }
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { model.close() }
}
