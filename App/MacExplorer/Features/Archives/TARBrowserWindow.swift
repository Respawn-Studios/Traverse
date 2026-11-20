import AppKit
import LocalStorage
import SwiftUI

/// Shared by the inline browser and the standalone archive window.
struct CompressedArchivePreparationView: View {
    @ObservedObject var model: TARBrowserModel
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "archivebox").interfaceFont(.system(size: 38)).foregroundStyle(.secondary)
            Text(model.busy ? "Preparing your archive" : "Browse this compressed archive").interfaceFont(.title3.weight(.semibold))
            Text("Traverse prepares a temporary copy on this Mac so you can explore folders and preview files. The original archive stays unchanged.")
                .interfaceFont(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.notice).interfaceFont(.callout).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
            } else {
                Button("Prepare Archive", action: model.prepareCompressed)
                    .disabled(!model.canPrepareCompressed)
                    .accessibilityIdentifier("archive-prepare-compressed")
                    .help("Reads the compressed archive and prepares up to 128 MiB of temporary data. The original archive stays unchanged.")
            }
        }
        .frame(maxWidth: 460).padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TARBrowserView:View {
    @ObservedObject var model:TARBrowserModel
    @ObservedObject var settings:BrowserSettings
    let clipboard: ArchiveWindowClipboard
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:10) {
                Image(systemName:"archivebox").interfaceFont(.title2).foregroundStyle(.secondary)
                VStack(alignment:.leading,spacing:3) {
                    Text(model.source?.lastPathComponent ?? "TAR Archive").interfaceFont(.title3.weight(.semibold)).lineLimit(1)
                    Text(model.compressedSizeDescription ?? (model.isCompressedSource ? "Compressed " + model.formatName : "Uncompressed TAR"))
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                        .help("Archive is the original compressed size. Prepared TAR includes headers and padding. Files is the sum of recorded member sizes.")
                }
                Spacer();if model.busy{ProgressView().controlSize(.small)}
                Button("Refresh",action:model.refresh).disabled(model.suspended)
                Button("Extract All…"){model.extract(selected:false)}.disabled(!model.canExtract)
                Button("Extract Selected…"){model.extract(selected:true)}.disabled(!model.canExtract || !model.selectedSupported)
            }
            HStack(spacing:6) {
                Button(action:model.back){Image(systemName:"chevron.left")}.help("Back").disabled(!model.canBack)
                Button(action:model.forward){Image(systemName:"chevron.right")}.help("Forward").disabled(!model.canForward)
                Button(action:model.up){Image(systemName:"arrow.up")}.help("Up").disabled(!model.canUp)
                ForEach(Array(model.breadcrumbs.enumerated()),id:\.offset){index,crumb in
                    if index>0{Image(systemName:"chevron.right").interfaceFont(.caption).foregroundStyle(.secondary)}
                    Button(crumb.name){model.visit(crumb.folder)}.buttonStyle(.plain).lineLimit(1).disabled(model.busy)
                }
                Spacer(minLength:8)
                ArchiveNameQueryField(text: $model.query, global: model.scope == .archive, onSubmit: model.applyQuery,
                    fieldID: "tar-name-query", placeholder: "Find names")
                    .modifier(ToolTextEntrySurface()).frame(minWidth:160,maxWidth:260)
                    .help("Search recorded names. File contents are not searched.")
                Picker("Find in",selection:$model.scope){ForEach(ArchiveNameScope.allCases){Text($0.title).tag($0)}}.labelsHidden().frame(width:135)
            }
            if model.showsCompressedPreparation {
                CompressedArchivePreparationView(model:model).frame(minHeight:200)
            } else {
                TARBrowserRows(model:model,settings:settings,clipboard:clipboard).frame(minHeight:200)
            }
            HStack {
                Text(model.current ? "\(model.total==0 ? 0:model.offset+1)–\(model.offset+model.items.count) of \(model.total.formatted()) items":" ")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Previous"){model.page(false)}.disabled(!model.current || model.busy || model.offset==0)
                Button("Next"){model.page(true)}.disabled(!model.current || model.busy || !model.hasNext)
                if model.busy{Button("Stop",action:model.stop)}
            }
            Text(model.notice).interfaceFont(.callout).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:36,alignment:.leading)
                .help("TAR records names and sizes. It has no per-file content checksum. Extraction verifies the bytes copied into the new folder and preserves download-security information.")
        }.padding(18)
    }
}
@MainActor private struct TARBrowserRows:NSViewRepresentable {
    @ObservedObject var model:TARBrowserModel
    @ObservedObject var settings:BrowserSettings
    let clipboard: ArchiveWindowClipboard
    func makeNSView(context:Context)->TARMetadataRows {
        let rows = TARMetadataRows(model:model); clipboard.bind(rows); return rows
    }
    func updateNSView(_ rows:TARMetadataRows,context:Context){rows.update(model,settings:settings)}
    static func dismantleNSView(_ rows:TARMetadataRows,coordinator:()){rows.retire()}
}
@MainActor final class TARMetadataRows:NSView,NSTableViewDataSource,NSTableViewDelegate,NSMenuItemValidation {
    let table=ArchiveMetadataTable()
    private(set) var memberDragSource: ArchiveMemberDragSource?
    private let scroll=NSScrollView()
    var fileScrollView:NSScrollView {scroll}
    var animatesNewRows = true
    var embeddedShortcut:((NSEvent)->Bool)? {
        didSet { table.embeddedShortcut = embeddedShortcut }
    }
    var onCut: (() -> Void)?
    var onCopyMembers: (() -> Void)?
    var canCaptureClipboard: ((TransferClipboardFeedback.Intent) -> Bool)?
    var isCut: ((TARItemID) -> Bool)?
    var onPaste: (() -> Void)?
    var canPaste: (() -> Bool)?
    private var acceptedFileDrop: LocalFileDropKey?
    private weak var model:TARBrowserModel?
    private var items=[TARArchiveItem](),updating=false,shownLocation=false
    #if DEBUG
    var rowIDsForVerification: [TARItemID] { items.map(\.id) }
    #endif
    init(model:TARBrowserModel) {
        self.model=model;super.init(frame:.zero)
        table.keyboardContextSettings = model.settings
        table.allowsNameSelection = { [weak model] in model?.allowsVisibleNameSelection == true }
        table.reportNameSelection = { [weak model] in model?.reportNameSelection($0) }
        memberDragSource = .init(tar: model, table: table); table.memberDragSource = memberDragSource
        table.usesAutomaticRowHeights=false;InterfaceMetrics.setRowHeight(table,base:26)
        for(key,title,width)in[("name","Name",310.0),("size","Size",100.0),("modified","Date Modified",172.0),
                              ("kind","Kind",140.0),("location","Location",230.0)] {
            let column=NSTableColumn(identifier:.init(key));column.title=title;column.width=width;column.minWidth=key=="name" ? 160:75
            column.isHidden=key=="location";column.sortDescriptorPrototype=key=="location" ? nil:NSSortDescriptor(key:key,ascending:key != "size" && key != "modified");table.addTableColumn(column)
        }
        table.headerView=FileTableHeaderView(frame:.init(x:0,y:0,width:800,height:28))
        table.columnAutoresizingStyle = .noColumnAutoresizing;table.dataSource=self;table.delegate=self;table.allowsMultipleSelection=true
        if TARArchiveEditingFeature.available { table.registerForDraggedTypes([.fileURL, ArchiveMemberDragSource.pasteboardType]) }
        table.setDraggingSourceOperationMask(TARArchiveEditingFeature.available ? [.copy, .move] : .copy, forLocal: true)
        table.setDraggingSourceOperationMask(TARPromiseExportFeature.available ? .copy : [], forLocal: false)
        table.target=self;table.doubleAction = #selector(openSelected(_:));table.onOpen={[weak self]in self?.model?.openSelection()}
        table.onRename = { [weak self] in self?.model?.reviewMutation(.rename) }
        table.nameClickRenameEnabled = { [weak model] in
            model?.settings.renamesSelectedNameOnClick == true && model?.canModifySelectedMembers == true && model?.selection.count == 1
        }
        table.onBack={[weak self]in self?.model?.back()};table.commandValidation={_ in false}
        table.onPreview = { [weak self] in self?.model?.previewSelected() }
        table.onUp = { [weak self] in self?.model?.up() }
        table.onForward = { [weak self] in self?.model?.forward() }
        table.onRefresh = { [weak self] in self?.model?.refresh() }
        table.setAccessibilityLabel("TAR archive members. Open folders or preview selected files.")
        let menu=NSMenu();menu.addItem(withTitle:"Open",action:#selector(openSelected(_:)),keyEquivalent:"").target=self
        if TARArchiveEditingFeature.available {
            menu.addItem(withTitle: "Edit in Traverse", action: #selector(editText(_:)), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle:"Preview Text",action:#selector(previewText(_:)),keyEquivalent:"").target=self
        menu.addItem(withTitle: "Compare Text Files…", action: #selector(compareText(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle:"Preview as Hex",action:#selector(previewHex(_:)),keyEquivalent:"").target=self
        if TARArchiveEditingFeature.available { menu.addItem(withTitle: "Cut", action: #selector(cutMembers(_:)), keyEquivalent: "").target = self }
        menu.addItem(withTitle: "Copy", action: #selector(copyMembers(_:)), keyEquivalent: "").target = self
        if TARArchiveEditingFeature.available { menu.addItem(withTitle: "Paste", action: #selector(pasteMembers(_:)), keyEquivalent: "").target = self }
        if TARArchiveEditingFeature.available {
            for (title, action) in [("Duplicate", #selector(duplicateMember(_:))), ("Rename…", #selector(renameMember(_:))),
                ("Remove from Archive…", #selector(removeMember(_:))), ("New Folder with Selection…", #selector(groupMembers(_:))),
                ("Create File…", #selector(createMember(_:))), ("New Folder…", #selector(createFolder(_:))),
                ("Add Files…", #selector(addMembers(_:)))] {
                menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
            }
        }
        menu.addItem(withTitle:"Extract Selected…",action:#selector(extractSelected(_:)),keyEquivalent:"").target=self
        menu.addItem(withTitle:"Properties…",action:#selector(showMemberProperties(_:)),keyEquivalent:"").target=self
        table.menu=menu
        table.memberCommandTarget = self
        table.memberCommands = [
            .newFolder: #selector(createFolder(_:)), .newTextFile: #selector(createMember(_:)),
            .newFolderWithSelection: #selector(groupMembers(_:)), .duplicate: #selector(duplicateMember(_:)),
            .rename: #selector(renameMember(_:)), .trash: #selector(removeMember(_:)),
            .properties: #selector(showMemberProperties(_:)), .editText: #selector(editText(_:)),
            .compareTextFiles: #selector(compareText(_:))]
        table.contextMenuProvider = { [weak self] in
            guard let self else { return nil }
            return NativeContextMenu.arrange(table.menu,
                groups: [[#selector(openSelected(_:)), #selector(editText(_:)), #selector(compareText(_:)), #selector(previewText(_:)), #selector(previewHex(_:))],
                         [#selector(cutMembers(_:)), #selector(copyMembers(_:)), #selector(pasteMembers(_:)), #selector(duplicateMember(_:)), #selector(renameMember(_:)), #selector(removeMember(_:))],
                         [#selector(groupMembers(_:)), #selector(createMember(_:)), #selector(createFolder(_:)), #selector(addMembers(_:))],
                         [#selector(extractSelected(_:)), #selector(showMemberProperties(_:))]],
                allows: validateMenuItem)
        }
        scroll.documentView=table;scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.autohidesScrollers=true
        scroll.translatesAutoresizingMaskIntoConstraints=false;addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:leadingAnchor,constant:12).interfaceScaled,scroll.trailingAnchor.constraint(equalTo:trailingAnchor),
            scroll.topAnchor.constraint(equalTo:topAnchor),scroll.bottomAnchor.constraint(equalTo:bottomAnchor)])
        table.marquee=TableMarqueeSelection(table:table,scroll:scroll,parent:self)
    }
    required init?(coder:NSCoder){nil}
    override func layout() { super.layout(); table.columnSizing.fit(table) }
    func retire() {
        table.retireNameSelection()
        memberDragSource?.retire(); memberDragSource = nil; table.memberDragSource = nil
        table.marquee?.cancel(restore: false); table.marquee = nil
        table.onOpen = nil; table.onBack = nil; table.onUp = nil; table.onPreview = nil
        table.onRename = nil; table.nameClickRenameEnabled = nil; table.onShortcut = nil
        table.onCopy = nil; table.onCut = nil; table.onPaste = nil; table.contextMenuProvider = nil
        table.memberCommandTarget = nil; table.memberCommands = [:]
        onCut = nil; onCopyMembers = nil; canCaptureClipboard = nil; isCut = nil; onPaste = nil; canPaste = nil
        model = nil
    }
    func update(_ model:TARBrowserModel,settings:BrowserSettings,glassOverride:Bool?=nil,showsOnlyCurrent:Bool=false) {
        updating=true;defer{updating=false}
        table.behavior = settings.behavior
        let glass=glassOverride ?? (settings.navigationStyle == .glass)
        table.backgroundColor=glass ? .clear:.controlBackgroundColor;table.usesAlternatingRowBackgroundColors = !glass
        scroll.drawsBackground = !glass;scroll.contentView.drawsBackground = !glass
        if let header=table.headerView as? FileTableHeaderView {
            if header.usesGlass != glass{header.usesGlass=glass};header.motionEnabled=settings.motion.allows(.sortIndicators);header.motionMode=settings.motion.mode
        }
        let pageItems=showsOnlyCurrent && !model.current ? []:model.items
        if items.map(\.id) != pageItems.map(\.id) || shownLocation != model.archiveSearch {
            shownLocation=model.archiveSearch;table.tableColumns.first{$0.identifier.rawValue=="location"}?.isHidden = !shownLocation
            items=pageItems;table.installNameSelectionPage(pageItems.map(\.name));table.reloadData();table.layoutSubtreeIfNeeded()
            let visible=table.rows(in:table.visibleRect)
            if animatesNewRows, visible.location != NSNotFound{for row in visible.location..<min(visible.upperBound,items.count){if let view=table.rowView(atRow:row,makeIfNecessary:false){ToolContentMotion.reveal(view)}}}
        }
        let selection=IndexSet(items.indices.filter{model.selection.contains(items[$0].id)})
        if table.selectedRowIndexes != selection{table.selectRowIndexes(selection,byExtendingSelection:false)}
        let desired=[NSSortDescriptor(key:model.order.field.rawValue,ascending:!model.order.descending)]
        if table.sortDescriptors != desired{table.sortDescriptors=desired;table.headerView?.needsDisplay=true}
    }
    func numberOfRows(in tableView:NSTableView)->Int{items.count}
    private func dropFolder(at row: Int, operation: NSTableView.DropOperation) -> TARFolderID? {
        operation == .on && items.indices.contains(row) ? items[row].folder : nil
    }
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard let model else { return [] }
        let folder = dropFolder(at: row, operation: operation)
        if let source = info.draggingSource as? ArchiveMetadataTable {
            guard source === table, let folder,
                  let offer = ArchiveMemberDragSource.capture(info, for: .moveWithinArchive),
                  model.canMoveMembers(offer.tarIDs, into: folder) else { return [] }
            tableView.setDropRow(row, dropOperation: .on); return .move
        }
        guard model.canAddLocalFiles(to: folder),
              let source = BrowserDragDropController.captureLocalFileDropSource(info), source.key != acceptedFileDrop else { return [] }
        tableView.setDropRow(folder == nil ? -1 : row, dropOperation: .on); return .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation operation: NSTableView.DropOperation) -> Bool {
        guard let model else { return false }
        let folder = dropFolder(at: row, operation: operation)
        if let source = info.draggingSource as? ArchiveMetadataTable {
            guard source === table, let folder,
                  let offer = ArchiveMemberDragSource.capture(info, for: .moveWithinArchive),
                  model.canMoveMembers(offer.tarIDs, into: folder) else { return false }
            return ArchiveMemberDragSource.admit(offer) { model.moveMembers(offer, into: folder) }
        }
        guard model.canAddLocalFiles(to: folder),
              let source = BrowserDragDropController.captureLocalFileDropSource(info), source.key != acceptedFileDrop,
              model.addLocalFiles(source, to: folder) else { return false }
        acceptedFileDrop = source.key; return true
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let model, items.indices.contains(row), model.selection.contains(items[row].id),
              items.map(\.id) == model.items.map(\.id) else { return nil }
        return memberDragSource?.writer(tarIDs: model.selection, item: model.items[row])
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        guard rowIndexes.allSatisfy({ items.indices.contains($0) }) else { return }
        memberDragSource?.begin(sequence: session.draggingSequenceNumber,
            tarIDs: Set(rowIndexes.map { items[$0].id }), board: session.draggingPasteboard)
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        #if DEBUG
        table.lastDragEndPointForVerification = [screenPoint.x,screenPoint.y]
        table.lastDragEndOperationForVerification = operation.rawValue
        #endif
        memberDragSource?.end(sequence: session.draggingSequenceNumber, operation: operation, point: screenPoint)
    }
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView? {
        guard items.indices.contains(row),let key=column?.identifier else{return nil};let item=items[row]
        let cell=table.makeView(withIdentifier:key,owner:nil)as?NSTableCellView ?? NSTableCellView();cell.identifier=key
        if cell.textField==nil {
            let field=NSTextField(labelWithString:"");field.lineBreakMode = .byTruncatingMiddle;field.translatesAutoresizingMaskIntoConstraints=false
            InterfaceMetrics.setFont(field,base:.systemFont(ofSize:NSFont.systemFontSize));cell.addSubview(field);cell.textField=field
            if key.rawValue=="name" {
                let image=NSImageView();image.translatesAutoresizingMaskIntoConstraints=false;cell.addSubview(image);cell.imageView=image
                NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:7),image.widthAnchor.constraint(equalToConstant:16).interfaceScaled,
                    image.heightAnchor.constraint(equalToConstant:16).interfaceScaled,image.centerYAnchor.constraint(equalTo:cell.centerYAnchor),field.leadingAnchor.constraint(equalTo:image.trailingAnchor,constant:7)])
            }else{field.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:5).isActive=true}
            NSLayoutConstraint.activate([field.trailingAnchor.constraint(lessThanOrEqualTo:cell.trailingAnchor,constant:-7),field.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
        }
        switch key.rawValue {
        case "name":
            cell.alphaValue = isCut?(item.id) == true ? 0.55 : 1
            cell.textField?.stringValue=item.name;cell.textField?.textColor = .labelColor
            let kind = item.kind == .directory ? "directory" : item.kind == .file ? "file" : "symbolicLink"
            cell.imageView?.image = BrowserCellSymbols.image(FileIconRole.classify(name: item.name, kind: kind))
            cell.imageView?.contentTintColor = FileOpeningSymbol.tint(.ordinary, directory: item.kind == .directory)
        case "location":cell.textField?.stringValue=(item.path as NSString).deletingLastPathComponent
        case "size":cell.textField?.stringValue=ArchiveBrowserModel.size(item.logicalBytes)
        case "modified":
            cell.textField?.stringValue = item.modification?.displayText ?? "—"
            cell.toolTip = item.modification?.explanation
            return cell
        case "kind":cell.textField?.stringValue=item.kind == .file ? "File":item.kind == .directory ? "Folder":"Unsupported item"
        default:return nil
        }
        cell.toolTip=item.path;return cell
    }
    func tableViewSelectionDidChange(_ notification:Notification){if !updating{model?.selection=Set(table.selectedRowIndexes.compactMap{items.indices.contains($0) ? items[$0].id:nil})}}
    func tableView(_ tableView:NSTableView,sortDescriptorsDidChange old:[NSSortDescriptor]) {
        guard !updating,let value=table.sortDescriptors.first,let key=value.key,let field=TARArchiveOrder.Field(rawValue:key)else{return}
        model?.order(by:.init(field,descending:!value.ascending))
    }
    @objc private func openSelected(_ sender:Any?){model?.openSelection()}
    @objc private func previewText(_ sender:Any?){model?.previewSelected()}
    @objc private func editText(_ sender: Any?) { model?.editSelectedText() }
    @objc private func compareText(_ sender: Any?) { model?.compareSelectedText(relativeTo: window) }
    @objc private func duplicateMember(_ sender: Any?) { model?.reviewMutation(.duplicate) }
    @objc private func renameMember(_ sender: Any?) { model?.reviewMutation(.rename) }
    @objc private func removeMember(_ sender: Any?) { model?.reviewMutation(.remove) }
    @objc private func groupMembers(_ sender: Any?) { model?.reviewMutation(.group) }
    @objc private func createMember(_ sender: Any?) { model?.reviewMutation(.newFile) }
    @objc private func createFolder(_ sender: Any?) { model?.reviewMutation(.newFolder) }
    @objc private func addMembers(_ sender: Any?) { model?.reviewMutation(.add) }
    @objc private func previewHex(_ sender:Any?){model?.previewSelectedAsBytes()}
    @objc private func cutMembers(_ sender: Any?) { if canCaptureClipboard?(.move) == true { onCut?() } }
    @objc private func copyMembers(_ sender: Any?) { if canCaptureClipboard?(.copy) == true { onCopyMembers?() } }
    @objc private func pasteMembers(_ sender: Any?) { if canPaste?() == true { onPaste?() } }
    @objc private func extractSelected(_ sender:Any?){model?.extract(selected:true)}
    @objc private func showMemberProperties(_ sender: Any?) { model?.showMemberProperties(relativeTo: window) }
    func validateMenuItem(_ item:NSMenuItem)->Bool {
        guard let model else{return false}
        if item.action == #selector(openSelected(_:)){return model.current && !model.busy && !model.isPreparingPreview && model.selection.count==1 && (items.contains{model.selection.contains($0.id) && $0.folder != nil} || model.canPreviewSelected)}
        if item.action == #selector(previewText(_:)) { item.title = model.preferredPreview.commandTitle; return model.canPreviewSelected }
        if item.action == #selector(editText(_:)) { return model.canEditSelectedText }
        if item.action == #selector(compareText(_:)) { return model.canCompareSelectedText }
        if item.action == #selector(renameMember(_:)) { return model.canModifySelectedMembers }
        if item.action == #selector(duplicateMember(_:)) || item.action == #selector(removeMember(_:)) { return model.canModifySelectedMembers }
        if item.action == #selector(groupMembers(_:)) { return model.canGroupMembers }
        if let action = item.action, [#selector(createMember(_:)), #selector(createFolder(_:)), #selector(addMembers(_:))].contains(action) { return model.canCreateMember }
        if item.action == #selector(previewHex(_:)){return model.canPreviewSelected}
        if item.action == #selector(cutMembers(_:)) { return canCaptureClipboard?(.move) == true }
        if item.action == #selector(copyMembers(_:)) { return canCaptureClipboard?(.copy) == true }
        if item.action == #selector(pasteMembers(_:)) { return canPaste?() == true }
        if item.action == #selector(showMemberProperties(_:)) { return model.observedMember != nil }
        return item.action == #selector(extractSelected(_:)) && model.canExtract && model.selectedSupported
    }
}
@MainActor final class TARBrowserWindowController:NSWindowController,NSWindowDelegate {
    let model:TARBrowserModel
    let clipboard: ArchiveWindowClipboard
    var onClose:(()->Void)?
    init(model:TARBrowserModel) {
        self.model=model
        clipboard = ArchiveWindowClipboard(tar: model)
        let window=ArchiveKeyboardWindow(contentViewController:InterfaceHostingController(rootView:TARBrowserView(model:model,settings:model.settings,clipboard:clipboard)))
        window.shortcutSettings = model.settings
        window.focusArchiveSearch = { [weak window] in window?.focusArchiveSearchField(identifier: "tar-name-query") }
        window.title="TAR Archive";window.styleMask=[.titled,.closable,.resizable,.miniaturizable];window.isReleasedWhenClosed=false;window.tabbingMode = .disallowed
        window.setContentSize(.init(width:980,height:650));window.contentMinSize = .init(width:820,height:560)
        super.init(window:window);window.delegate=self;model.window=window;ToolWindowChrome.install(in:window,settings:model.settings)
        clipboard.window = window
    }
    required init?(coder:NSCoder){nil}
    func windowWillClose(_ notification:Notification){clipboard.retire();onClose?()}
}
@MainActor final class ApplicationTARBrowser {
    static let shared=ApplicationTARBrowser()
    private(set) var controller:TARBrowserWindowController?
    private var retirement:Task<Void,Never>?
    func show(_ url:URL,from browser:BrowserViewController,reviewExtraction:Bool=false) {
        if GeneratedArchiveDriveReview.requested,
           !GeneratedArchiveDriveReview.permitsFixtureLocations([url]) {
            browser.status.stringValue = "This review accepts generated archive fixtures only."
            return
        }
        guard TARBrowseFeature.available,retirement==nil,!ApplicationFileActivity.gate.isClosed else{return}
        if controller==nil {
            let reader=ApplicationCompressedArchives.shared.reader(excluding:(browser.developmentStateDirectory.map{[$0]} ?? [])+AppStorageLocations.protectedDirectories)
            let model=TARBrowserModel(settings:browser.settings,reader:reader),created=TARBrowserWindowController(model:model)
            created.onClose={[weak self,weak model]in
                guard let self,let model else{return};model.stop();retirement=Task{[self]in await model.closeAndDrain();controller=nil;retirement=nil}
            };controller=created
        }
        controller?.clipboard.attach(to: browser)
        controller?.model.open(url,from:browser,reviewExtraction:reviewExtraction)
        if controller?.window?.isVisible != true {
            if browser.isControlledVerification{controller?.window?.setFrameOrigin(.init(x:-12000,y:-12000))}
            else if let window = controller?.window { ToolWindowChrome.position(window, relativeTo: browser.view.window) }
        }
        controller?.showWindow(nil);controller?.window?.makeKeyAndOrderFront(nil)
    }
    func suspend(){controller?.model.suspend()}
    func resume(){controller?.model.resume()}
    func drain()async{await controller?.model.drain();if let retirement{await retirement.value}}
    func closeAndDrain()async{controller?.close();if let retirement{await retirement.value}}
}
enum TARBrowseFeature {
    static var available:Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--check-tar-archive")
            || ProcessInfo.processInfo.arguments.contains("--check-inline-archives")
            || ProcessInfo.processInfo.arguments.contains("--check-inline-archive-motion")
            || ProcessInfo.processInfo.arguments.contains("--check-tar-preview-native")
            || ProcessInfo.processInfo.arguments.contains("--check-archive-open-routing"){return true}
        #endif
        return AppFeatureAvailability.allows(.tarBrowsing)
    }
}
