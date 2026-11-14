import AppKit
import Combine
import FileOperations
@_spi(ApplicationOwnership) import StorageAnalysis
import SwiftUI

enum StoredLocationAction: String, CaseIterable {
    case showInExplorer = "Show in Explorer", properties = "Properties", copyPath = "Copy Path"
    case reviewTrash = "Move to Trash…"

    var availableInCurrentBuild: Bool {
        self != .reviewTrash || NativeLocalProtectionPolicy.analyzerSelectedTrashAvailable
    }
    var unavailableHelp: String? {
        availableInCurrentBuild ? nil
            : "Open this location in Traverse to move it to Trash. Cleanup directly from analysis is unavailable in this beta."
    }
}
enum AnalysisBrowserMode: String, CaseIterable { case browse = "Browse", largest = "Largest Files" }

/// Native presentation of one result page. Folder navigation reuses stored
/// metadata; it never scans another scope or accumulates the entire hierarchy.
@MainActor
final class PagedAnalysisBrowserModel: ObservableObject {
    struct Location {
        let id: UInt64, title: String, cursor: UInt64
        let previous: [UInt64]
    }
    @Published private(set) var rows: [StoredAnalysisRow] = []
    @Published private(set) var title: String
    @Published private(set) var loading = false
    @Published private(set) var message = ""
    @Published private(set) var ancestors: [Location] = []
    @Published private(set) var cursor: UInt64 = 0
    @Published private(set) var selectedID: UInt64?
    @Published private(set) var pagePresentation = UUID()
    @Published private(set) var mode = AnalysisBrowserMode.browse
    @Published private(set) var largestMetric = AnalysisLargestFileMetric.logical
    var allowsPageMotion: () -> Bool = { true }
    var pageMotionMode: () -> BrowserMotionMode = { .full }
    @Published private(set) var actionRunning = false
    @Published private(set) var actionMessage = ""
    @Published var operationFeedback: AnalysisOperationFeedback?
    private var observedRows: [StoredAnalysisRow] = []
    private var largestFileInfo: [UInt64: StoredLargestFile] = [:]
    private var largestCounts: (known: UInt64, unknown: UInt64)?
    private let rootTitle: String
    private struct BrowsePosition { let location: Location; let ancestors: [Location] }
    private var browsePosition: BrowsePosition?
    private var knownTrashes: [UUID: UInt64] = [:]
    private var changeObservation: AnyCancellable?
    private weak var changeBrowser: BrowserViewController?
    private weak var changeEngine: RecoverableFileOperations?
    @Published private(set) var sortOrder = StoredAnalysisSortOrder.logicalDescending
    @Published private var nextPageAvailable = false
    private let sortedPagesAvailable: Bool
    private let maximumFolderDepth: Int
    private(set) var sortGeneration = UUID()
    var onLocationAction: ((StorageAnalysisResult, UInt64, StoredLocationAction, @escaping (String) -> Void) -> Void)?
    var onCancelLocationAction: ((UUID) -> Void)?
    private var node: UInt64 = 0
    private var previous: [UInt64] = []
    private var result: StorageAnalysisResult?
    // The presentation owner retains a recorded view. Queries retain it only
    // until their actual return; this model cannot prolong its authority.
    private weak var readView: (any AnalysisStoredReadView)?
    private var request: Task<Void, Never>?
    private var token = UUID()
    private var pending: (node: UInt64, cursor: UInt64, order: StoredAnalysisSortOrder, mode: AnalysisBrowserMode, metric: AnalysisLargestFileMetric)?
    private var closed = false
    let metadataPolicy: AnalysisMetadataPolicy
    var canGoBack: Bool { !previous.isEmpty }
    var hasNext: Bool { nextPageAvailable }
    var canSort: Bool { !closed && readView != nil && sortedPagesAvailable && mode == .browse }
    var canChooseLargest: Bool { !closed && readView?.supportsLargestFiles == true }
    func recordedFolder(_ id: UInt64) -> String { largestFileInfo[id]?.recordedFolder ?? "" }
    var hasWork: Bool { request != nil }
    var selectedRow: StoredAnalysisRow? { rows.first { $0.id == selectedID } }
    var canActOnSelection: Bool {
        !closed && !loading && !actionRunning && result?.supportsStoredLocations == true
            && selectedRow.map { $0.kind == .directory || $0.kind == .regularFile } == true && onLocationAction != nil
    }
    func canAct(_ action: StoredLocationAction) -> Bool {
        action.availableInCurrentBuild && canActOnSelection && (action != .reviewTrash || knownTrashes.count < 1024)
    }
    /// Presentation only: the caller has already verified this exact operation.
    /// Never changes a stored observation or supplies mutation authority.
    func recordTrash(node: UInt64, recordID: UUID, browser: BrowserViewController, engine: RecoverableFileOperations) {
        guard !closed, knownTrashes.count < 1024, changeEngine == nil || changeEngine === engine else { return }
        knownTrashes[recordID] = node
        changeBrowser = browser; changeEngine = engine
        if changeObservation == nil {
            changeObservation = browser.operationCoordinator.objectWillChange.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconcileKnownUndos() }
            }
        }
        applyKnownChanges()
    }
    func recordUndo(recordID: UUID) {
        guard !closed, knownTrashes.removeValue(forKey: recordID) != nil else { return }
        applyKnownChanges()
    }
    private func reconcileKnownUndos() {
        guard let browser = changeBrowser, browser.recoverableFileOperations === changeEngine else { return }
        for record in browser.recoveryRecords where record.state == "undone" { recordUndo(recordID: record.id) }
    }
    private func applyKnownChanges() {
        let removed = Set(knownTrashes.values)
        rows = observedRows.filter { !removed.contains($0.id) }
        if let selectedID, !rows.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        let changed = observedRows.count - rows.count
        if changed > 0 {
            message = "\(rows.count) shown · \(changed) moved to Trash since analysis · sizes remain recorded"
        } else {
            if mode == .largest, let largestCounts {
                message = "\(rows.count) largest observed file names · \(largestCounts.known.formatted()) with known sizes"
                    + (largestCounts.unknown > 0 ? " · \(largestCounts.unknown.formatted()) unknown sizes excluded" : "")
                    + ". Shared blocks can overlap; sizes remain recorded."
            } else {
                message = observedRows.isEmpty ? "No child observations in this stored result."
                    : "\(observedRows.count) observed items on this page · folder sizes include recorded descendants"
            }
        }
    }
    var locationActionHelp: String {
        if knownTrashes.count >= 1024 { return "Refresh this analysis before making more selected changes." }
        if !actionMessage.isEmpty { return actionMessage }
        if result == nil { return "These are saved observations. Analyze Again before using actions on current files." }
        if result?.supportsStoredLocations != true { return "Location actions need a supported local APFS result. Stored browsing is still available." }
        return selectedRow == nil ? "Select a file or folder to inspect its current location." : ""
    }

    convenience init(result: StorageAnalysisResult, title: String) {
        self.init(readView: result, liveResult: result, title: title)
    }
    convenience init(recordedView: any AnalysisStoredReadView, title: String) {
        self.init(readView: recordedView, liveResult: nil, title: title)
    }
    private init(readView: any AnalysisStoredReadView, liveResult: StorageAnalysisResult?, title: String) {
        self.result = liveResult; self.readView = readView
        self.title = title; rootTitle = title; metadataPolicy = readView.metadataPolicy
        sortedPagesAvailable = readView.supportsSortedPages
        maximumFolderDepth = readView.maximumStoredHierarchyDepth
        load()
    }
    deinit { request?.cancel() }
    func close() {
        cancelLocationAction()
        operationFeedback?.close(); operationFeedback = nil
        changeObservation = nil; changeBrowser = nil; changeEngine = nil
        knownTrashes.removeAll(); observedRows = []
        largestFileInfo = [:]; largestCounts = nil; browsePosition = nil
        closed = true; token = UUID(); pending = nil; request?.cancel(); rows = []; loading = false
        // A closed hosting view may retain its observed model until a later
        // render pass. Release this view's store ownership now; an in-flight
        // query keeps its own handle until actual drain.
        readView = nil; result = nil
    }
    func waitUntilQueriesDrained() async { await request?.value }
    func select(_ id: UInt64?) { selectedID = id.flatMap { value in rows.contains(where: { $0.id == value }) ? value : nil } }
    func changeMode(_ mode: AnalysisBrowserMode) {
        guard canChooseLargest, mode != self.mode else { return }
        if mode == .largest {
            browsePosition = .init(location: .init(id: node, title: title, cursor: cursor, previous: previous), ancestors: ancestors)
            node = 0; title = rootTitle; cursor = 0; previous = []; ancestors = []
        } else if let position = browsePosition {
            node = position.location.id; title = position.location.title; cursor = position.location.cursor
            previous = position.location.previous; ancestors = position.ancestors; browsePosition = nil
        }
        self.mode = mode; sortGeneration = UUID(); load()
    }
    func changeLargestMetric(_ metric: AnalysisLargestFileMetric) {
        guard canChooseLargest, mode == .largest, metric != largestMetric else { return }
        largestMetric = metric; sortGeneration = UUID(); load()
    }
    func changeSort(_ value: StoredAnalysisSortOrder) {
        guard canSort, value != sortOrder else { return }
        sortOrder = value; sortGeneration = UUID(); cursor = 0; previous = []
        ancestors = ancestors.map { .init(id: $0.id, title: $0.title, cursor: 0, previous: []) }
        load()
    }
    var tableSort: (key: String, ascending: Bool) {
        switch sortOrder {
        case .nameAscending: ("name", true)
        case .nameDescending: ("name", false)
        case .logicalDescending: ("logical", false)
        case .logicalAscending: ("logical", true)
        case .allocatedDescending: ("allocated", false)
        case .allocatedAscending: ("allocated", true)
        }
    }
    func changeTableSort(key: String, ascending: Bool) {
        switch key {
        case "name": changeSort(ascending ? .nameAscending : .nameDescending)
        case "logical": changeSort(ascending ? .logicalAscending : .logicalDescending)
        case "allocated": changeSort(ascending ? .allocatedAscending : .allocatedDescending)
        default: break
        }
    }
    func act(_ action: StoredLocationAction) {
        guard canAct(action), let result, let row = selectedRow else { return }
        let token = token
        actionRunning = true; actionMessage = "Checking the recorded location…"
        onLocationAction?(result, row.id, action) { [weak self] message in
            guard let self, !self.closed, self.token == token else { return }
            self.actionRunning = false; self.actionMessage = message
        }
    }
    private func cancelLocationAction() {
        if actionRunning, let result { onCancelLocationAction?(result.id) }
        actionRunning = false; actionMessage = ""
    }
    func next() {
        // The cursor belongs to the recorded page, even if its tail or every
        // row has since been hidden by a confirmed operation.
        guard !closed, let last = observedRows.last, hasNext, !loading else { return }
        if previous.count == 256 { previous.removeFirst() }
        previous.append(cursor); cursor = last.id; load()
    }
    func back() {
        guard !closed, !loading, let old = previous.popLast() else { return }; cursor = old; load()
    }
    func start() { guard !closed, !loading else { return }; cursor = 0; previous = []; load() }
    func open(_ row: StoredAnalysisRow) {
        guard !closed, mode == .browse, rows.contains(where: { $0.id == row.id }), row.kind == .directory, !loading else { return }
        guard ancestors.count < maximumFolderDepth else {
            message = "This result reaches its folder-depth limit here. Scan a smaller folder to explore further."
            return
        }
        ancestors.append(.init(id: node, title: title, cursor: cursor, previous: previous))
        node = row.id; title = row.title; cursor = 0; previous = []; load()
    }
    func up(to index: Int? = nil) {
        guard !closed, !loading, !ancestors.isEmpty else { return }
        let index = index ?? (ancestors.count - 1)
        guard ancestors.indices.contains(index) else { return }
        let old = ancestors[index]; ancestors.removeSubrange(index...)
        node = old.id; title = old.title; cursor = old.cursor; previous = old.previous; load()
    }
    private func load() {
        guard !closed else { return }
        cancelLocationAction(); selectedID = nil
        token = UUID(); loading = true; message = "Loading stored observations…"
        // Retain the previous recorded rows while the replacement query runs.
        // Loading disables all row actions; an error withdraws them. Keeping
        // the native canvas/header steady avoids flashing an empty dark table.
        nextPageAvailable = false
        pending = (node, cursor, sortOrder, mode, largestMetric); request?.cancel(); pump()
    }
    private func pump() {
        guard !closed, request == nil, let pending else { return }
        self.pending = nil
        guard let readView else {
            loading = false; rows = []; observedRows = []; largestFileInfo = [:]; largestCounts = nil
            nextPageAvailable = false
            message = "This saved analysis is no longer open. Reopen it to continue browsing."
            return
        }
        let token = token
        request = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let values: [StoredAnalysisRow], more: Bool
                var largest: StoredLargestFiles?
                if pending.mode == .largest {
                    let page = try await readView.largestFiles(metric: pending.metric)
                    largest = page; values = page.files.map(\.row); more = false
                } else if readView.supportsSortedPages {
                    let page = try await readView.sortedPage(parent: pending.node, after: pending.cursor, order: pending.order)
                    values = page.rows; more = page.hasMore
                } else {
                    values = try await readView.page(parent: pending.node, after: pending.cursor); more = values.count == 256
                }
                guard let self else { return }
                if self.token == token, !Task.isCancelled {
                    self.largestFileInfo = [:]; self.largestCounts = nil
                    if let largest {
                        self.largestFileInfo = Dictionary(uniqueKeysWithValues: largest.files.map { ($0.id, $0) })
                        self.largestCounts = (largest.rankableFileNames, largest.unknownSizeFileNames)
                    }
                    self.observedRows = values; self.nextPageAvailable = more; self.loading = false
                    self.applyKnownChanges()
                    self.pagePresentation = UUID()
                }
            } catch {
                guard let self else { return }
                if self.token == token, !Task.isCancelled {
                    self.loading = false
                    self.rows = []; self.observedRows = []; self.largestFileInfo = [:]; self.largestCounts = nil
                    self.message = "This page is unavailable. The result may have changed; Analyze Again to refresh."
                }
            }
            guard let self else { return }
            self.request = nil; self.pump()
        }
    }
}

struct PagedAnalysisBrowser: View {
    @ObservedObject var model: PagedAnalysisBrowserModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.canChooseLargest {
                HStack {
                    Picker("Analysis view", selection: Binding(get: { model.mode }, set: { model.changeMode($0) })) {
                        ForEach(AnalysisBrowserMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 215)
                        .accessibilityLabel("Analysis view")
                    Spacer()
                    if model.mode == .largest {
                        Picker("Rank by", selection: Binding(get: { model.largestMetric }, set: { model.changeLargestMetric($0) })) {
                            ForEach(AnalysisLargestFileMetric.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.frame(width: 270)
                    }
                }.controlSize(.small)
            }
            if model.mode == .browse {
            HStack {
                Button { model.up() } label: { Image(systemName: "arrow.up") }
                    .help("Parent folder in this analysis").disabled(model.ancestors.isEmpty || model.loading)
                Menu {
                    ForEach(Array(model.ancestors.enumerated()), id: \.offset) { index, item in
                        Button(item.title) { model.up(to: index) }
                    }
                } label: { Text(model.title).lineLimit(1).truncationMode(.middle) }
                .disabled(model.ancestors.isEmpty || model.loading)
                Spacer()
                if model.canSort {
                    Picker("Sort", selection: Binding(get: { model.sortOrder }, set: { model.changeSort($0) })) {
                        ForEach(StoredAnalysisSortOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 190)
                        .help("Sort this whole stored folder. Unknown sizes come last; partial sizes are known subtotals. Names use exact stored order.")
                }
                if model.loading { ProgressView().controlSize(.small) }
                Button("First") { model.start() }.disabled(model.cursor == 0 || model.loading)
                Button("Previous") { model.back() }.disabled(!model.canGoBack || model.loading)
                Button("Next") { model.next() }.disabled(!model.hasNext || model.loading)
            }.controlSize(.small)
            } else {
                Text("Across " + model.title + " · up to 32 files").interfaceFont(.caption).foregroundStyle(.secondary)
            }
            if model.metadataPolicy != .standard {
                Label(model.metadataPolicy.title, systemImage: "externaldrive.badge.checkmark")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
            }
            StoredAnalysisTable(rows: model.rows, model: model)
                .frame(minHeight: 110)
                .accessibilityLabel(model.mode == .largest ? "Largest observed file names across this analysis, at most 32."
                    : "Stored storage-analysis page, at most 256 items. Double-click a folder to inspect it.")
            HStack {
                ForEach(StoredLocationAction.allCases, id: \.self) { action in
                    Button(action.rawValue) { model.act(action) }.disabled(!model.canAct(action))
                        .help(action.unavailableHelp ?? action.rawValue)
                }
                if model.actionRunning { ProgressView().controlSize(.small) }
                Text(model.locationActionHelp).foregroundStyle(.secondary).lineLimit(2)
            }.controlSize(.small).interfaceFont(.caption)
            if let feedback = model.operationFeedback { AnalysisOperationFeedbackView(model: feedback) }
            Text(model.message).interfaceFont(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// AppKit owns row reuse and selection. Actions defer model changes until the
/// table delegate callback returns, avoiding reentrant SwiftUI Table updates.
private struct StoredAnalysisTable: NSViewRepresentable {
    let rows: [StoredAnalysisRow]
    let model: PagedAnalysisBrowserModel
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let table = StoredAnalysisNativeTable()
        #if DEBUG
        if StoredAnalysisTableProbe.enabled { StoredAnalysisTableProbe.latest = table }
        #endif
        InterfaceMetrics.setRowHeight(table, base: 25); table.style = .plain; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (key, title, width) in [("name", "Name", 320.0), ("logical", "Logical", 125.0),
                                   ("allocated", "Allocated", 125.0), ("recorded", "Recorded folder", 280.0), ("files", "Files", 80.0), ("folders", "Folders", 80.0)] {
            let column = NSTableColumn(identifier: .init(key)); column.title = title; column.width = width
            if model.canSort && ["name", "logical", "allocated"].contains(key) {
                column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: key == "name")
            }
            column.minWidth = key == "name" ? 140 : 60; table.addTableColumn(column)
        }
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.openFolder(_:))
        table.contextMenu = { [weak owner = context.coordinator] row in owner?.menu(for: row) }
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let table = view.documentView as? NSTableView else { return }
        let owner = context.coordinator
        owner.model = model
        let oldIDs = owner.rows.map(\.id), newIDs = rows.map(\.id)
        let newPage = owner.presentation != model.pagePresentation
        owner.presentation = model.pagePresentation
        let changed = oldIDs != newIDs || owner.mode != model.mode
        owner.mode = model.mode
        if let native = table as? StoredAnalysisNativeTable {
            native.configureLargestColumns(model.mode == .largest)
        }
        if model.loading && table.selectedRow >= 0 { table.deselectAll(nil) }
        for column in table.tableColumns {
            let key = column.identifier.rawValue
            column.isHidden = key == "recorded" ? model.mode != .largest : ["files", "folders"].contains(key) && model.mode == .largest
            column.sortDescriptorPrototype = model.canSort && ["name", "logical", "allocated"].contains(key)
                ? NSSortDescriptor(key: key, ascending: key == "name") : nil
        }
        owner.rows = rows
        #if DEBUG
        if StoredAnalysisTableProbe.enabled, let table = table as? StoredAnalysisNativeTable { table.installedRowIDsForQualification = rows.map(\.id) }
        #endif
        if changed {
            // Animate only a single known local removal/restoration. Page and
            // sort replacements keep the existing full reload semantics.
            if model.allowsPageMotion(), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
               oldIDs.count == newIDs.count + 1,
               let index = oldIDs.firstIndex(where: { !newIDs.contains($0) }),
               oldIDs.enumerated().filter({ $0.offset != index }).map(\.element) == newIDs {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.20 * model.pageMotionMode().durationScale
                    table.removeRows(at: IndexSet(integer: index), withAnimation: .effectFade)
                }
                table.deselectAll(nil)
            } else if model.allowsPageMotion(), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      newIDs.count == oldIDs.count + 1,
                      let index = newIDs.firstIndex(where: { !oldIDs.contains($0) }),
                      newIDs.enumerated().filter({ $0.offset != index }).map(\.element) == oldIDs {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.20 * model.pageMotionMode().durationScale
                    table.insertRows(at: IndexSet(integer: index), withAnimation: .effectFade)
                }
            } else {
                table.reloadData(); table.enclosingScrollView?.tile()
                (table as? StoredAnalysisNativeTable)?.fitLargestColumns()
                if oldIDs != newIDs && !model.loading { (table as? StoredAnalysisNativeTable)?.revealCurrentRows(model) }
            }
        }
        if model.canSort {
            let sort = model.tableSort, current = table.sortDescriptors.first
            if current?.key != sort.key || current?.ascending != sort.ascending {
                table.sortDescriptors = [NSSortDescriptor(key: sort.key, ascending: sort.ascending)]
            }
        } else if !table.sortDescriptors.isEmpty { table.sortDescriptors = [] }
        if newPage && !model.loading && !rows.isEmpty { table.scrollRowToVisible(0) }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [StoredAnalysisRow] = []
        var mode = AnalysisBrowserMode.browse
        var presentation: UUID?
        weak var model: PagedAnalysisBrowserModel?
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let model, model.canSort, let sort = tableView.sortDescriptors.first, let key = sort.key else { return }
            let generation = model.sortGeneration, ascending = sort.ascending
            DispatchQueue.main.async { [weak model] in
                guard model?.sortGeneration == generation else { return }
                model?.changeTableSort(key: key, ascending: ascending)
            }
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
            DispatchQueue.main.async { [weak model] in model?.select(selected) }
        }
        func menu(for index: Int) -> NSMenu? {
            guard rows.indices.contains(index), let model else { return nil }
            let row = rows[index]
            model.select(row.id)
            let menu = NSMenu(); menu.autoenablesItems = false
            for action in StoredLocationAction.allCases {
                let item = NSMenuItem(title: action.rawValue, action: #selector(performLocation(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = model.canAct(action)
                item.toolTip = action.unavailableHelp
                // Pin the row and model that originated this menu. Never use
                // the key window, a chart title or another browser selection.
                item.representedObject = StoredLocationMenuIntent(model: model, row: row.id, action: action)
                menu.addItem(item)
            }
            return menu
        }
        @objc private func performLocation(_ sender: NSMenuItem) {
            guard let intent = sender.representedObject as? StoredLocationMenuIntent,
                  intent.model?.selectedID == intent.row else { return }
            intent.model?.act(intent.action)
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let column else { return nil }
            let value = rows[row], key = column.identifier.rawValue
            let text = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTextField)
                ?? NSTextField(labelWithString: "")
            text.identifier = column.identifier; text.lineBreakMode = .byTruncatingMiddle
            text.font = key == "name" ? .systemFont(ofSize: 12) : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            switch key {
            case "name": text.stringValue = (value.kind == .directory ? "▸ " : "") + value.title
            case "logical": text.stringValue = value.kind == .regularFile || value.kind == .directory ? storageMetricText(value.value.bytes.dataLogical, files: value.value.counts.regularFiles) : "Not measured"
            case "allocated": text.stringValue = value.kind == .regularFile || value.kind == .directory ? storageMetricText(value.value.bytes.allForkAllocated, files: value.value.counts.regularFiles) : "Not measured"
            case "recorded": text.stringValue = model?.recordedFolder(value.id) ?? ""
            case "files": text.stringValue = String(value.value.counts.regularFiles)
            default: text.stringValue = String(value.value.counts.directories)
            }
            text.toolTip = key == "recorded" ? text.stringValue : value.kind == .directory ? "Double-click to inspect this folder’s stored observations" : nil
            return text
        }
        @objc func openFolder(_ sender: NSTableView) {
            guard rows.indices.contains(sender.clickedRow) else { return }
            let row = rows[sender.clickedRow]
            DispatchQueue.main.async { [weak model] in model?.open(row) }
        }
    }
}

@MainActor private final class StoredLocationMenuIntent: NSObject {
    weak var model: PagedAnalysisBrowserModel?
    let row: UInt64
    let action: StoredLocationAction
    init(model: PagedAnalysisBrowserModel, row: UInt64, action: StoredLocationAction) {
        self.model = model; self.row = row; self.action = action
    }
}

@MainActor final class StoredAnalysisNativeTable: NSTableView {
    var contextMenu: ((Int) -> NSMenu?)?
    private var largestColumns = false
    private var browseWidths: [NSUserInterfaceItemIdentifier: CGFloat] = [:]
    func configureLargestColumns(_ largest: Bool) {
        guard largestColumns != largest else { return }
        if largest { browseWidths = Dictionary(uniqueKeysWithValues: tableColumns.map { ($0.identifier, $0.width) }) }
        largestColumns = largest
        columnAutoresizingStyle = largest ? .noColumnAutoresizing : .lastColumnOnlyAutoresizingStyle
        enclosingScrollView?.hasHorizontalScroller = !largest
        if let scroll = enclosingScrollView { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
        if !largest {
            for column in tableColumns { if let width = browseWidths[column.identifier] { column.width = width } }
            browseWidths = [:]
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        fitLargestColumns()
    }
    func fitLargestColumns() {
        guard largestColumns, let scroll = enclosingScrollView else { return }
        let width = min(scroll.contentSize.width, scroll.contentView.visibleRect.width)
        guard width > 400 else { return }
        let name = min(280, max(170, width * 0.28))
        let spacing = max(0, intercellSpacing.width) * 4 + 2
        let desired = ["name": name, "logical": CGFloat(105), "allocated": CGFloat(105), "recorded": max(100, width - name - 210 - spacing)]
        for column in tableColumns {
            if let width = desired[column.identifier.rawValue], abs(column.width - width) > 0.5 { column.width = width }
        }
    }
    func revealCurrentRows(_ model: PagedAnalysisBrowserModel) {
        guard model.allowsPageMotion(), model.pageMotionMode() != .off else { return }
        layoutSubtreeIfNeeded()
        let visible = rows(in: visibleRect)
        guard visible.location != NSNotFound else { return }
        // Animate only current rows. Headers/materials stay fixed, no outgoing
        // names/bitmap are retained, and visible targets always match input.
        for index in visible.location..<min(numberOfRows, visible.location + min(256, visible.length)) {
            if let row = rowView(atRow: index, makeIfNecessary: false) { ToolContentMotion.reveal(row) }
        }
    }
    #if DEBUG
    var installedRowIDsForQualification: [UInt64] = []
    #endif
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        return contextMenu?(index)
    }
}

#if DEBUG
@MainActor enum StoredAnalysisTableProbe {
    static var enabled = false
    static weak var latest: StoredAnalysisNativeTable?
}
#endif
