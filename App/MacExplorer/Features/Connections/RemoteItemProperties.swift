import AppKit
import Combine
import ExplorerCore
@_spi(Qualification) import LocalStorage
import SwiftUI

/// Concrete selected-folder work. The retained session owns its request until
/// cleanup; the window owns only whether a result still belongs on screen.
@MainActor struct RemoteFolderSizeAction {
    let cacheKey: RemoteFolderSizeCacheKey
    let isCurrent: () -> Bool
    let isReady: () -> Bool
    let calculate: @Sendable () async throws -> RemoteFolderSizeSummary
    init(cacheKey: RemoteFolderSizeCacheKey, isCurrent: @escaping () -> Bool,
         isReady: @escaping () -> Bool = { true },
         calculate: @escaping @Sendable () async throws -> RemoteFolderSizeSummary) {
        self.cacheKey = cacheKey; self.isCurrent = isCurrent; self.isReady = isReady; self.calculate = calculate
    }
}
enum RemoteFolderSizeCacheKey: Equatable {
    case sftp(connection: UUID, generation: UUID, snapshot: SFTPStoredSnapshot, observation: UInt64)
    case smb(connection: UUID, snapshot: SMBDirectorySnapshot, observation: Int64)
}

@MainActor final class ListedItemPropertiesController: NSObject, ObservableObject, NSWindowDelegate {
    enum Selection {
        case remote(RemoteItemObservation)
        case archive(ArchiveMemberObservation)

        var name: String {
            switch self { case .remote(let value): value.name; case .archive(let value): value.name }
        }
        var copyName: String? {
            switch self { case .remote(let value): value.copyName; case .archive(let value): value.name }
        }
        var copyPath: String? {
            switch self { case .remote(let value): value.copyPath; case .archive(let value): value.path }
        }
        var pathNoun: String {
            switch self { case .remote: "server path"; case .archive: "path in archive" }
        }
        var pathButtonTitle: String {
            switch self { case .remote: "Copy Server Path"; case .archive: "Copy Path in Archive" }
        }
    }

    @Published private(set) var selection: Selection?
    var item: RemoteItemObservation? {
        if case .remote(let value) = selection { value } else { nil }
    }
    @Published private(set) var revision = UUID()
    @Published private(set) var notice = ""
    @Published private(set) var folderSize: RemoteFolderSizeSummary?
    @Published private(set) var isCalculatingSize = false
    @Published private(set) var isWaitingForConnection = false
    @Published private(set) var sizeFailure: RemoteFolderSizeFailure?
    private var sizeAction: RemoteFolderSizeAction?
    private var sizeTask: Task<Void, Never>?
    /// Dated presentation values for this browser only, never remote authority
    /// or persistent server state. A new read/connection cannot reuse them.
    private var measuredSizes: [(RemoteFolderSizeCacheKey, RemoteFolderSizeSummary)] = []
    private let settings: BrowserSettings
    private let publish: (String) -> Bool
    private var controller: NSWindowController?
    var window: NSWindow? { controller?.window }
    init(settings: BrowserSettings, publish: @escaping (String) -> Bool) {
        self.settings = settings; self.publish = publish; super.init()
    }
    func show(_ value: RemoteItemObservation, relativeTo parent: NSWindow?, folderSizeAction: RemoteFolderSizeAction? = nil) {
        show(.remote(value), relativeTo: parent, folderSizeAction: folderSizeAction)
    }
    func show(_ value: Selection, relativeTo parent: NSWindow?, folderSizeAction: RemoteFolderSizeAction? = nil) {
        selection = value; notice = ""; revision = UUID(); folderSize = nil
        sizeFailure = nil; isCalculatingSize = false; sizeAction = item == nil ? nil : folderSizeAction; sizeTask = nil
        refreshFolderSizeAvailability()
        if let action = sizeAction, action.isCurrent() {
            folderSize = measuredSizes.last { $0.0 == action.cacheKey }?.1
        }
        if controller == nil {
            let host = InterfaceHostingController(rootView: ListedItemPropertiesView(model: self, settings: settings))
            let height: CGFloat = item == nil ? 430 : 520
            let window = ToolWindowChrome.makeWindow(title: "Properties", size: .init(width: 620, height: height),
                minimumSize: .init(width: 480, height: 400), content: host)
            ToolWindowChrome.install(in: window,settings: settings)
            window.delegate = self; controller = NSWindowController(window: window)
        }
        guard let window else { return }
        window.title = "Properties · " + String(value.name.prefix(80))
        if !window.isVisible {
            ToolWindowChrome.position(window, relativeTo: parent)
            window.makeKeyAndOrderFront(nil); ToolContentMotion.reveal(window.contentView!,effect:.windows)
        } else { window.makeKeyAndOrderFront(nil) }
    }
    var canCalculateSize: Bool {
        item?.kind == .folder && sizeAction != nil && !isCalculatingSize && !isWaitingForConnection
            && sizeFailure != .stale && sizeFailure != .invalidInput && sizeFailure != .connectionLost
    }
    var hasFolderSizeAction: Bool { sizeAction != nil }
    func refreshFolderSizeAvailability() {
        let waiting = sizeAction.map { !$0.isReady() } ?? false
        if isWaitingForConnection != waiting { isWaitingForConnection = waiting }
    }
    func calculateSize() {
        refreshFolderSizeAvailability()
        guard canCalculateSize, let action = sizeAction else { return }
        guard action.isCurrent() else { sizeFailure = .stale; return }
        let ticket = revision
        isCalculatingSize = true; sizeFailure = nil
        sizeTask = Task { @MainActor [weak self] in
            let result: Result<RemoteFolderSizeSummary, Error>
            do {
                let value = try await ApplicationDiagnostics.shared.remoteMetadata(.remoteFolderSize, count: { UInt64($0.files) }) {
                    try await action.calculate()
                }
                result = .success(value)
            }
            catch { result = .failure(error) }
            guard let self, revision == ticket, item != nil else { return }
            sizeTask = nil; isCalculatingSize = false
            switch result {
            case .success(let value):
                guard action.isCurrent() else { sizeFailure = .stale; return }
                folderSize = value
                measuredSizes.removeAll { $0.0 == action.cacheKey }
                measuredSizes.append((action.cacheKey, value))
                if measuredSizes.count > 16 { measuredSizes.removeFirst(measuredSizes.count - 16) }
            case .failure(let error): sizeFailure = error as? RemoteFolderSizeFailure ?? .unavailable
            }
        }
    }
    func copyName() { copy(selection?.copyName, noun: "name") }
    func copyPath() {
        guard let selection else { return }
        copy(selection.copyPath, noun: selection.pathNoun)
    }
    private func copy(_ value: String?, noun: String) {
        guard let value else { return }
        notice = publish(value) ? "Copied \(noun)." : "The clipboard could not be updated. Try again."
    }
    func close() { window?.close() }
    func done() { window?.performClose(nil) }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        ToolContentMotion.finish(in: closing); closing.title = "Properties"; selection = nil; notice = ""; controller = nil
        // Do not Task.cancel/Stop the authenticated connection on dismissal.
        revision = UUID(); sizeAction = nil; sizeTask = nil; folderSize = nil; isCalculatingSize = false; sizeFailure = nil; isWaitingForConnection = false
    }
}

private struct ListedItemPropertiesView: View {
    @ObservedObject var model: ListedItemPropertiesController
    @ObservedObject var settings: BrowserSettings
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            if let selection = model.selection {
                HStack(alignment: .top,spacing: 12) {
                    Image(systemName: symbol(selection)).interfaceFont(.system(size:32)).foregroundStyle(.secondary)
                    VStack(alignment: .leading,spacing: 5) {
                        Text(selection.name).interfaceFont(.title2.bold()).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                        Text(subtitle(selection)).interfaceFont(.callout).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).help(subtitle(selection))
                    }
                }
                Divider()
                ScrollView {
                    Grid(alignment:.leading,horizontalSpacing:18,verticalSpacing:14) {
                        switch selection {
                        case .remote(let item): remoteRows(item)
                        case .archive(let item): archiveRows(item)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                if case .remote(let item) = selection {
                    Text(remoteExplanation(item))
                        .interfaceFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                if !model.notice.isEmpty { Text(model.notice).interfaceFont(.callout).accessibilityIdentifier("remote-properties-notice") }
                Divider()
                HStack {
                    Button("Copy Name",action:model.copyName).disabled(selection.copyName == nil)
                    Button(selection.pathButtonTitle,action:model.copyPath).disabled(selection.copyPath == nil)
                    Spacer()
                    Button("Done",action:model.done).keyboardShortcut(.cancelAction)
                }
            }
        }.padding(20)
            .toolPageEntrance(model.revision,enabled:settings.motion.allows(.pages),mode:settings.motion.mode)
            // A new measurement inserts several grid rows. Interpolating that
            // layout blends the new counts through Modified/Path. Keep data
            // changes immediate; the native spinner and page entrance own motion.
    }
    @ViewBuilder private func remoteRows(_ item: RemoteItemObservation) -> some View {
        row("Kind",kind(item.kind))
        row(model.folderSize != nil && model.sizeFailure != nil ? "Last Measured" : "Size",size(item)).help(item.kind == .folder
            ? "Adds file sizes, not space on disk. Each file name counts separately. Links are not followed; file contents are not read."
            : "Size reported in the folder listing.")
        if item.kind == .folder && (model.hasFolderSizeAction || model.isCalculatingSize || model.folderSize != nil || model.sizeFailure != nil) { folderSizeControls }
        row("Modified",item.modified?.formatted(date:.abbreviated,time:.standard) ?? "Not available")
        row("Path",item.displayPath)
        switch item.pathRoot {
        case .smbShare(let share): row("Share",share); row("Path starts", "Inside this share")
        case .sftpHome: row("Path starts","Server Home (./)")
        case .sftpAbsolute: row("Path starts","Server root (/)")
        }
        if case .smbShare = item.pathRoot {} else {
            row("Permissions",item.permissions.map { value in
                let text = String(value & 0o7777,radix:8); return String(repeating:"0",count:max(0,4-text.count))+text
            } ?? "Not supplied").help("Unix permissions reported by the server. This window does not change them.")
        }
    }
    @ViewBuilder private func archiveRows(_ item: ArchiveMemberObservation) -> some View {
        row("Kind", item.kind.title)
        row("Date Modified", item.modification?.displayText ?? "Not recorded")
            .help(item.modification?.explanation ?? "The archive did not record a modification date for this item.")
        if let bytes = item.logicalBytes {
            row(item.packedBytes == nil ? "Size" : "Uncompressed Size", FileSizeText.unsigned(bytes))
        }
        if let bytes = item.packedBytes {
            row("Size in ZIP", FileSizeText.unsigned(bytes))
                .help("Size of the stored file data, excluding ZIP headers and the directory.")
        }
        if let compression = item.compression { row("Compression", compression) }
        if item.isEncrypted { row("Encryption", "Encrypted member") }
        row("Path in Archive", item.path)
    }
    private func subtitle(_ selection: ListedItemPropertiesController.Selection) -> String {
        switch selection {
        case .remote: "Details from your server"
        case .archive(let item): "Inside \(item.archiveName)"
        }
    }
    private func remoteExplanation(_ item: RemoteItemObservation) -> String {
        if !item.listingComplete { return "The folder listing is incomplete. These details describe only this observed item." }
        if item.kind == .folder && model.hasFolderSizeAction {
            return "File details come from the folder listing. Folder measurements show when they were calculated."
        }
        return "Details come from the folder listing. Refresh the folder to see later changes."
    }
    private var folderSizeControls: some View {
        GridRow(alignment: .top) {
            Text("")
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if model.hasFolderSizeAction {
                        Button(model.folderSize == nil ? "Calculate Size" : "Calculate Again", action: model.calculateSize)
                            .contentTransition(.identity)
                            .disabled(!model.canCalculateSize)
                            .accessibilityIdentifier("remote-folder-calculate-size")
                    }
                    if model.isCalculatingSize {
                        ProgressView().controlSize(.small)
                        Text("Calculating…").interfaceFont(.callout).foregroundStyle(.secondary)
                    }
                }.frame(minHeight: 22, alignment: .leading)
                if model.isWaitingForConnection && !model.isCalculatingSize {
                    Text("Waiting for the current server task…").interfaceFont(.caption).foregroundStyle(.secondary)
                }
                if let summary = model.folderSize {
                    Text("\(summary.files.formatted()) \(summary.files == 1 ? "file" : "files") · \(summary.folders.formatted()) \(summary.folders == 1 ? "folder" : "folders")")
                        .interfaceFont(.callout).foregroundStyle(.secondary)
                    Text("Measured \(summary.observedAt.formatted(date: .abbreviated, time: .shortened))")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    if summary.excludedLinks > 0 {
                        Text("\(summary.excludedLinks.formatted()) links not included")
                            .interfaceFont(.caption).foregroundStyle(.secondary)
                    }
                }
                if let failure = model.sizeFailure {
                    Text(sizeExplanation(failure)).interfaceFont(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("remote-folder-size-notice")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func sizeExplanation(_ failure: RemoteFolderSizeFailure) -> String {
        switch failure {
        case .stale, .invalidInput: "Refresh this folder, then reopen Properties to calculate its size."
        case .denied: "The server denied access to part of this folder. No complete size is available."
        case .changed: "The folder changed during the size check. Try again."
        case .unsupported: "Some items could not be measured. No complete size is available."
        case .limit: "This folder is too large for a quick size check. Try a smaller subfolder."
        case .deadline: "The size check took too long. Try a smaller subfolder."
        case .connectionLost: "The connection ended before the size check completed."
        case .unavailable: "Folder size is unavailable right now. Try again."
        }
    }
    private func row(_ title: String,_ value: String) -> some View {
        GridRow(alignment:.top) {
            Text(title).interfaceFont(.callout).foregroundStyle(.secondary)
            Text(value).interfaceFont(.callout).textSelection(.enabled)
                .contentTransition(.identity)
                .fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private func kind(_ value: RemoteItemObservation.Kind) -> String {
        switch value {case .file:"File";case .folder:"Folder";case .link:"Link · target not read";case .other:"Other item";case .unknown:"Not supplied"}
    }
    private func symbol(_ selection: ListedItemPropertiesController.Selection) -> String {
        switch selection {
        case .archive(let item): item.kind.symbol
        case .remote(let item):
            switch item.kind { case .folder: "folder"; case .link: "link"; case .file, .other, .unknown: "doc" }
        }
    }
    private func size(_ item: RemoteItemObservation) -> String {
        if item.kind == .folder, let measured = model.folderSize { return FileSizeText.unsigned(measured.logicalBytes) + " in files" }
        guard let bytes = item.logicalBytes else { return item.kind == .folder ? "Not measured" : "Not available" }
        return FileSizeText.unsigned(bytes)
    }
}

@MainActor extension BrowserViewController {
    var observedRemoteItem: RemoteItemObservation? {
        guard !isBrowserSuspended, view.window?.isVisible == true, !view.isHiddenOrHasHiddenAncestor,
              view.window?.attachedSheet == nil else { return nil }
        if isSMBLocation { return smbTabs[activeID]?.selectedItemObservation }
        if isSFTPLocation { return sftpTabs[activeID]?.selectedItemObservation }
        return nil
    }
    func showObservedRemoteProperties() {
        guard let item = observedRemoteItem else { return }
        let sizeAction = isSMBLocation ? smbTabs[activeID]?.folderSizeAction : sftpTabs[activeID]?.folderSizeAction
        showItemProperties(.remote(item), relativeTo: view.window, folderSizeAction: sizeAction)
    }
    func showItemProperties(_ item: ListedItemPropertiesController.Selection, relativeTo parent: NSWindow?,
                            folderSizeAction: RemoteFolderSizeAction? = nil) {
        if listedItemPropertiesController == nil {
            listedItemPropertiesController = .init(settings:settings) { [weak self] text in
                self?.publishObservedMetadataText(text,noun:"text") ?? false
            }
        }
        listedItemPropertiesController?.show(item, relativeTo: parent, folderSizeAction: folderSizeAction)
    }
    func copyObservedRemoteMetadata(name: Bool) {
        guard let item = observedRemoteItem, let text = name ? item.copyName : item.copyPath else { return }
        _ = publishObservedMetadataText(text,noun:name ? "name" : "server path")
    }
    @discardableResult func publishObservedMetadataText(_ text: String,noun: String) -> Bool {
        clearCutSelection()
        let saved: Bool
        if case .text = clipboardWriter(text,[]) { saved = true } else { saved = false }
        status.stringValue = saved ? "Copied \(noun)." : "The clipboard could not be updated. Try again."
        return saved
    }
}
