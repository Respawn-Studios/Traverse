import AppKit
import Combine
import ExplorerCore
import LocalStorage

struct TARClipboardSource {
    let archiveURL: URL
    let generation: UUID
    let ids: Set<TARItemID>
    let paths: [String]
}

/// A concrete TAR owner. It shares Explorer presentation and the existing
/// extraction review, without inventing ZIP compression or integrity facts.
@MainActor final class TARBrowserModel:ObservableObject {
    @Published private(set) var source:URL?
    @Published private(set) var summary:TARArchiveSummary?
    @Published private(set) var compressedSummary: TARCompressedPreparationSummary?
    @Published private(set) var items=[TARArchiveItem]()
    @Published private(set) var breadcrumbs=[TARBreadcrumb]()
    @Published private(set) var offset=0
    @Published private(set) var total=0
    @Published private(set) var busy=false
    @Published private(set) var current=false
    @Published private(set) var suspended=false
    @Published private(set) var isPreviewing=false
    @Published private(set) var isPreparingPreview=false
    @Published private(set) var notice=""
    @Published private(set) var requiresPreparation = false
    @Published var selection=Set<TARItemID>()
    @Published var query="" { didSet { if !installing && query != oldValue { scheduleQuery() } } }
    @Published var scope=ArchiveNameScope.folder { didSet { if !installing && scope != oldValue { scheduleQuery() } } }
    @Published private(set) var order=TARArchiveOrder()
    let settings:BrowserSettings
    weak var window:NSWindow?
    var embeddedNavigate: (([String], ArchiveBrowseState) -> Void)?
    var embeddedBack: (() -> Void)?
    var embeddedForward: (() -> Void)?
    var embeddedUp: (() -> Void)?
    var embeddedIsPresented: (() -> Bool)?
    private var permitsEmbeddedAction: Bool { embeddedIsPresented?() ?? true }
    var embeddedScrollOffset: Double = 0
    private struct EmbeddedPresentation { let location:ArchiveLocation;let state:ArchiveBrowseState;let token:UUID }
    private var embeddedPresentation:EmbeddedPresentation?,desiredEmbedded:EmbeddedPresentation?
    private var embeddedInstalledToken:UUID?
    private var desiredEmbeddedNavigation:(folder:TARFolderID,token:UUID)?
    private var embeddedSelectedPaths=Set<String>()
    private weak var browser:BrowserViewController?
    private let reader:TARArchiveReader
    private let textPreview:ArchiveTextPreviewOwner
    private var session:TARArchiveSession?
    private var token=UUID(),pageToken=UUID(),closed=false,installing=false
    private var readTask:Task<TARArchiveSession,Error>?,queryTask:Task<Page,Error>?
    private var work:Task<Void,Never>?,filterWork:Task<Void,Never>?,selectionWork:Task<Void,Never>?
    private var isPreparingDrag = false
    private struct Open {let source:URL;weak var browser:BrowserViewController?;let token:UUID;let preparesCompressed:Bool}
    private struct Visit {let folder:TARFolderID;var query="",scope=ArchiveNameScope.folder,order=TARArchiveOrder(),offset=0}
    private struct Pending {let visit:Visit;let token:UUID;var selected:TARItemID?}
    private struct Page:Sendable {let items:[TARArchiveItem],breadcrumbs:[TARBreadcrumb];let offset:Int,total:Int}
    private var desiredOpen:Open?,desiredPage:Pending?,history=[Visit](),historyIndex=0
    private var opensExtractionReview=false
    private var matching:AnyCancellable?
    init(settings:BrowserSettings,reader:TARArchiveReader) {
        self.settings=settings;self.reader=reader
        textPreview=ArchiveTextPreviewOwner(tarReader:reader,settings:settings)
        textPreview.onBusy={ [weak self] in self?.isPreviewing=$0 }
        matching=settings.$symbolTolerantNames.dropFirst().receive(on:RunLoop.main).sink{[weak self]_ in self?.scheduleQuery()}
    }
    var canBack:Bool { !closed && !suspended && (embeddedBack != nil || historyIndex>0) }
    var retainsPreviewPresentation:Bool {textPreview.retainsPresentation}
    func validateAddressFolder(_ path: [String]) async throws {
        guard permitsEmbeddedAction, current, !busy, !closed, !suspended, let session else { throw CancellationError() }
        let expected = token
        guard await session.matchesCurrentSourceObservation() else { throw TARArchiveFailure.changed }
        _ = try await session.folder(at: path)
        try Task.checkCancellation()
        guard !closed, !suspended, token == expected, current else { throw CancellationError() }
    }
    var canForward:Bool { !closed && !suspended && (embeddedForward != nil || historyIndex+1<history.count) }
    var canUp:Bool { !closed && !suspended && !busy && (embeddedUp != nil || scope == .archive || breadcrumbs.count>1) }
    var canExtract:Bool { ArchiveExtractionActivation.wholeArchiveAvailable && permitsEmbeddedAction && current && !busy && !isPreviewing && !isPreparingPreview && !suspended && !closed && source != nil && browser?.canStartArchiveExtraction == true }
    var observedMember: ArchiveMemberObservation? {
        guard permitsEmbeddedAction, current, !busy, !closed, !suspended, selection.count == 1,
              let id = selection.first, let source, let item = items.first(where: { $0.id == id }) else { return nil }
        return .init(tar: item, source: source)
    }
    func showMemberProperties(relativeTo parent: NSWindow?) {
        guard let member = observedMember, let browser, !browser.isBrowserSuspended else { return }
        browser.showItemProperties(.archive(member), relativeTo: parent)
    }
    func canPreviewSelection(_ ids:Set<TARItemID>)->Bool {
        TARTextPreviewFeature.available && (!isCompressedSource || compressedSummary != nil && !requiresPreparation)
            && permitsEmbeddedAction && current && !busy && !isPreparingPreview && !closed && !suspended
            && ids.count == 1 && !ApplicationFileActivity.gate.isClosed
            && items.contains{ids.contains($0.id) && $0.kind == .file}
    }
    var canPreviewSelected:Bool {canPreviewSelection(selection)}
    var preferredPreview: ArchivePreviewMode { .preferred(for: items.first { selection.contains($0.id) }?.name) }
    var isCompressedSource: Bool { source.map(Self.isCompressed) ?? false }
    var showsCompressedPreparation: Bool {
        CompressedTARFeature.available && isCompressedSource && (requiresPreparation || busy && summary == nil)
    }
    var compressedSizeDescription: String? {
        guard let value = compressedSummary else { return nil }
        func size(_ bytes: UInt64) -> String { FileSizeText.string(Int64(clamping: bytes)) }
        return "Archive \(size(value.compressedBytes)) · Prepared TAR \(size(value.decodedTARBytes)) · Files \(size(value.memberLogicalBytes))"
    }
    var canPrepareCompressed: Bool {
        CompressedTARFeature.available && requiresPreparation && !busy && !suspended && !closed
            && permitsEmbeddedAction && browser?.isBrowserSuspended == false && !ApplicationFileActivity.gate.isClosed
    }
    static func isCompressed(_ source: URL) -> Bool {
        let name = source.lastPathComponent.lowercased()
        return name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz")
    }
    func prepareCompressed() {
        guard canPrepareCompressed, let source, let browser else { return }
        open(source, from: browser, preparesCompressed: true)
    }
    func previewSelected(){previewSelection(selection)}
    func previewSelectedAsBytes(){previewSelection(selection,mode:.hexadecimal)}
    func previewSelection(_ ids:Set<TARItemID>,mode explicitMode:ArchivePreviewMode? = nil) {
        guard canPreviewSelection(ids),let id=ids.first,let session,let source,let browser,!browser.isBrowserSuspended else{return}
        let mode = explicitMode ?? .preferred(for: items.first { $0.id == id }?.name)
        let currentToken=token,currentPage=pageToken
        isPreparingPreview=true
        selectionWork=Task{[self]in
            defer{selectionWork=nil;isPreparingPreview=false}
            do {
                let chosen = if mode == .image { try await session.selectionForImagePreview(id) }
                    else { try await session.selectionForTextPreview(id) }
                #if DEBUG
                if let beforePreviewSelectionForVerification{await beforePreviewSelectionForVerification()}
                #endif
                guard permitsEmbeddedAction,!Task.isCancelled,!closed,!suspended,currentToken==token,currentPage==pageToken else{return}
                let lifetime=await browser.accessLifetime(for:[source])
                guard permitsEmbeddedAction,!Task.isCancelled,!closed,!suspended,currentToken==token,currentPage==pageToken,
                      !browser.isBrowserSuspended,!ApplicationFileActivity.gate.isClosed else{return}
                var offscreen=browser.isControlledVerification
                #if DEBUG
                if let previewOffscreenForVerification{offscreen=previewOffscreenForVerification}
                #endif
                textPreview.open(chosen,retaining:lifetime,offscreen:offscreen,mode:mode)
            }catch{if !Task.isCancelled,!closed,currentToken==token{notice=ArchiveTextPreviewOwner.message(error,mode:mode)}}
        }
    }
    #if DEBUG
    var beforePreviewSelectionForVerification:(@MainActor () async ->Void)?
    var previewOffscreenForVerification:Bool?
    var textPreviewForVerification:ArchiveTextPreviewOwner {textPreview}
    #endif
    var hasNext:Bool { offset+items.count<total }
    var archiveSearch:Bool { scope == .archive }
    var selectedSupported:Bool { !selection.isEmpty && selection.count<=1024 && selection.isSubset(of:Set(items.map(\.id)))
        && items.filter{selection.contains($0.id)}.allSatisfy{$0.kind == .file || $0.kind == .directory} }

    var canCaptureClipboardMembers: Bool {
        SelectedArchiveExtractionActivation.available && canExtract && selectedSupported && session != nil
    }

    func captureClipboardMembers() -> TARClipboardSource? {
        guard canCaptureClipboardMembers, let source else { return nil }
        return .init(archiveURL: source, generation: token, ids: selection,
                     paths: items.filter { selection.contains($0.id) }.map(\.path))
    }

    func retainsClipboard(_ copied: TARClipboardSource) -> Bool {
        !closed && !suspended && session != nil && token == copied.generation && source == copied.archiveURL
    }

    func matchesClipboardSelection(_ copied: TARClipboardSource) -> Bool {
        permitsEmbeddedAction && current && retainsClipboard(copied) && selection == copied.ids
    }

    func canExportClipboard(_ copied: TARClipboardSource) -> Bool {
        SelectedArchiveExtractionActivation.available && retainsClipboard(copied)
            && !busy && !isPreviewing && !isPreparingPreview && browser?.isBrowserSuspended == false
    }

    func exportClipboard(_ copied: TARClipboardSource, context: ScopedItemPaste, to target: BrowserViewController) {
        guard canExportClipboard(copied), let session, let origin = browser,
              let paste = ArchiveLocalPaste(context, to: target) else { return }
        busy = true
        selectionWork = Task { [self] in
            defer { selectionWork = nil; if work == nil { busy = false } }
            do {
                let members = try await session.selectionForExtraction(copied.ids)
                try await paste.present(.tar(members), source: copied.archiveURL, from: origin)
            } catch { paste.report(error) }
        }
    }
    func canStartMemberDrag(_ ids: Set<TARItemID>) -> Bool {
        ArchiveMemberDragActivation.available && canCaptureClipboardMembers && selection == ids
            && (1...ArchiveMemberDragSource.maximumItems).contains(ids.count)
            && !ApplicationFileActivity.gate.isClosed
    }
    func captureMemberDrag(_ ids: Set<TARItemID>) -> ArchiveMemberDragOffer? {
        guard canStartMemberDrag(ids) else { return nil }
        return .init(tar: self, generation: token, page: pageToken, ids: ids)
    }
    func isCurrentMemberDrag(_ offer: ArchiveMemberDragOffer) -> Bool {
        offer.tarModel === self && !closed && !suspended && current && permitsEmbeddedAction
            && (!busy || isPreparingDrag) && !isPreviewing && !isPreparingPreview
            && token == offer.generation && pageToken == offer.page && selection == offer.tarIDs
            && !offer.tarIDs.isEmpty && items.filter { offer.tarIDs.contains($0.id)
                && ($0.kind == .file || $0.kind == .directory) }.count == offer.tarIDs.count
            && browser?.isBrowserSuspended == false && !ApplicationFileActivity.gate.isClosed
    }
    @discardableResult func extractDropped(_ offer: ArchiveMemberDragOffer, to target: BrowserViewController,
        destination: ArchiveExtractionDestination, isCurrent: @escaping @MainActor () -> Bool) -> Bool {
        guard isCurrentMemberDrag(offer), canStartMemberDrag(offer.tarIDs), let session, let source,
              let origin = browser, target.canStartArchiveExtraction, isCurrent(),
              ApplicationArchiveExtraction.shared.canAcceptPreparedSelection else { return false }
        busy = true; isPreparingDrag = true; notice = "Preparing the selected items for copying…"
        selectionWork = Task { [self, origin, target] in
            defer { selectionWork = nil; isPreparingDrag = false; if work == nil { busy = false } }
            do {
                let members = try await session.selectionForExtraction(offer.tarIDs)
                guard !Task.isCancelled, isCurrentMemberDrag(offer), isCurrent() else { return }
                let access = await origin.accessLifetime(for: [source])
                guard !Task.isCancelled, isCurrentMemberDrag(offer) else { return }
                guard isCurrent(), target.canStartArchiveExtraction else {
                    notice = "That destination changed. Drag the items to its current folder again."; return
                }
                if ApplicationArchiveExtraction.shared.showSelection(source: source, from: target, selection: .tar(members),
                    destination: destination, sourceAccess: access, presentation: .paste) {
                    notice = "Checking the copy destination…"
                } else { notice = "Finish the open archive copy, then drag these items again." }
            } catch { if !Task.isCancelled, !closed, token == offer.generation { notice = Self.message(error) } }
        }
        return true
    }
    var embeddedViewState:ArchiveBrowseState {
        if let embeddedPresentation,embeddedInstalledToken != embeddedPresentation.token {
            var state=embeddedPresentation.state;state.scrollOffset=embeddedScrollOffset;return state
        }
        let field:ArchiveSortField = switch order.field { case .name:.name;case .size:.size;case .modified:.modified;case .kind:.kind }
        return ArchiveBrowseState(query:query,scope:scope == .archive ? .archive:.folder,sortField:field,
            ascending:!order.descending,offset:current ? offset:(history.indices.contains(historyIndex) ? history[historyIndex].offset:0),
            selectedPaths:current ? Set(items.filter{selection.contains($0.id)}.map(\.path)):embeddedSelectedPaths,
            scrollOffset:embeddedScrollOffset)
    }
    private static func tarOrder(_ state:ArchiveBrowseState)->TARArchiveOrder {
        let field:TARArchiveOrder.Field = switch state.sortField {case .size:.size;case .modified:.modified;case .kind:.kind;default:.name}
        return .init(field,descending:!state.ascending)
    }
    func presentEmbedded(_ location:ArchiveLocation,state:ArchiveBrowseState,from browser:BrowserViewController) {
        guard !closed,!suspended else{return}
        do {try location.validate();try state.validate(format:.tar);guard location.format == .tar else{throw TARArchiveFailure.unsupported}}
        catch {notice=Self.message(error);current=false;return}
        let presentation=EmbeddedPresentation(location:location,state:state,token:UUID())
        embeddedPresentation=presentation;embeddedSelectedPaths=state.selectedPaths;embeddedScrollOffset=state.scrollOffset
        installing=true;query=state.query;scope=state.scope == .archive ? .archive:.folder;order=Self.tarOrder(state);installing=false
        window=browser.view.window;self.browser=browser
        if source != location.source || session == nil || desiredOpen != nil || readTask != nil {
            if source != location.source || work?.isCancelled == true || desiredOpen == nil && readTask == nil {open(location.source,from:browser)}
            desiredEmbedded=presentation
        }else{
            desiredEmbedded=presentation;desiredEmbeddedNavigation=nil;desiredPage=nil;pageToken=presentation.token
            queryTask?.cancel();filterWork?.cancel();selectionWork?.cancel();current=false;selection=[];start()
        }
    }
    func open(_ url:URL,from browser:BrowserViewController,reviewExtraction:Bool=false,preparesCompressed:Bool=false) {
        guard !closed,!suspended else{return}
        textPreview.stop(closeWindow:true)
        token=UUID();pageToken=UUID();self.browser=browser;source=url
        opensExtractionReview=reviewExtraction
        requiresPreparation = CompressedTARFeature.available && Self.isCompressed(url) && !preparesCompressed
        current=false;selection=[]
        notice = requiresPreparation ? "Prepare this archive to browse its folders and preview files. Preparation reads the archive and uses temporary space on this Mac." : "Reading archive names…"
        summary=nil;compressedSummary=nil;items=[];breadcrumbs=[];total=0;offset=0;history=[];historyIndex=0
        desiredOpen = .init(source:url,browser:browser,token:token,preparesCompressed:preparesCompressed);desiredPage=nil
        desiredEmbedded=nil;desiredEmbeddedNavigation=nil
        readTask?.cancel();queryTask?.cancel();filterWork?.cancel();selectionWork?.cancel();start()
    }
    func refresh(){if let source,let browser{
        if let embeddedPresentation {self.embeddedPresentation = .init(location:embeddedPresentation.location,state:embeddedViewState,token:UUID())}
        open(source,from:browser)
    }}
    private func start(){if work==nil{busy=true;work=Task{[self]in await pump()}}}
    private func pump()async {
        defer{
            work=nil;readTask=nil;queryTask=nil;busy=false
            if opensExtractionReview,current,!closed,!suspended{opensExtractionReview=false;extract(selected:false)}
            if !closed,!suspended,desiredOpen != nil || desiredEmbedded != nil || desiredEmbeddedNavigation != nil || desiredPage != nil{start()}
        }
        while !closed && !suspended && !Task.isCancelled {
            if let request=desiredOpen {
                desiredOpen=nil
                await textPreview.drain()
                if let session{await session.close()};session=nil;await reader.drain()
                guard request.token==token,let browser=request.browser,!browser.isBrowserSuspended else{continue}
                // Restoring/opening a compressed location never starts a body
                // decode. Only the explicit Prepare action admits that work.
                if requiresPreparation { continue }
                let access=await browser.accessLifetime(for:[request.source])
                guard !closed,!suspended,!Task.isCancelled,request.token==token else{continue}
                let action: DiagnosticAction = request.preparesCompressed ? .archiveCheck : .archiveBrowse
                let diagnostic = ApplicationDiagnostics.shared.begin(action)
                do {
                    let updates = AsyncStream<TARCompressedPreparationProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
                    let progressWork = Task { @MainActor [weak self] in
                        var previousPhase: DiagnosticPhase?
                        for await progress in updates.stream {
                            guard let self, !self.closed, !self.suspended, self.token == request.token, !Task.isCancelled else { return }
                            switch progress.phase {
                            case .checkingSource: self.notice = "Checking the archive…"
                            case .preparingStorage, .checkingOrphans, .checkingRoot: self.notice = "Getting ready…"
                            case .checkingSpace: self.notice = "Checking available space…"
                            case .decoding: self.notice = "Preparing archive… " + FileSizeText.string(Int64(clamping: progress.decodedBytes))
                            case .validating: self.notice = "Checking the prepared archive…"
                            case .cataloging: self.notice = "Reading archive folders and names…"
                            }
                            let phase: DiagnosticPhase = switch progress.phase {
                            case .checkingSource: .verifying
                            case .preparingStorage, .checkingOrphans, .checkingSpace, .checkingRoot: .preparing
                            case .decoding: .reading
                            case .validating: .verifying
                            case .cataloging: .presenting
                            }
                            if phase != previousPhase {
                                previousPhase = phase
                                ApplicationDiagnostics.shared.event(action, phase, trace: diagnostic, count: progress.decodedBytes)
                            }
                        }
                    }
                    let publicSource = ArchiveExtractionActivation.qualifiesPublicTARFile
                        || ArchiveExtractionActivation.qualifiesPublicTARTree
                    let read=Task{[reader,source=request.source,preparesCompressed=request.preparesCompressed]in
                        try await ArchiveMetadataAdmission.shared.withAdmission {
                            if preparesCompressed {
                                try await ApplicationCompressedArchives.shared.prepareStorage()
                                return try await reader.prepareCompressed(source,retaining:access,
                                    publicQuarantineSource: publicSource, progress:{ _ = updates.continuation.yield($0) })
                            }
                            return try await reader.open(source,retaining:access)
                        }
                    };readTask=read
                    let result = await read.result
                    updates.continuation.finish(); await progressWork.value
                    readTask=nil
                    let opened=try result.get()
                    ApplicationDiagnostics.shared.event(action, .completed, trace: diagnostic,
                        count: opened.compressedPreparation?.decodedTARBytes)
                    guard !closed,!suspended,request.token==token else{await opened.close();continue}
                    session=opened;summary=opened.summary;compressedSummary=opened.compressedPreparation
                    if embeddedPresentation == nil{install(Visit(folder:opened.root))};history=[Visit(folder:opened.root)];historyIndex=0
                    if let embeddedPresentation{desiredEmbedded=embeddedPresentation;pageToken=embeddedPresentation.token}else{requestPage(history[0],starting:false)}
                }catch{
                    let stopped = error is CancellationError || error as? TARArchiveFailure == .stopped
                    ApplicationDiagnostics.shared.event(action, stopped ? .cancelled : .failed, trace: diagnostic, error: DiagnosticErrors.project(error))
                    if !closed,request.token==token{notice=Self.message(error);current=false;requiresPreparation = CompressedTARFeature.available && Self.isCompressed(request.source)}
                }
                withExtendedLifetime(access){};continue
            }
            guard let session else{desiredEmbedded=nil;desiredEmbeddedNavigation=nil;desiredPage=nil;break}
            if let navigation=desiredEmbeddedNavigation {
                desiredEmbeddedNavigation=nil
                do {
                    let path=try await session.folderPath(of:navigation.folder)
                    guard !closed,!suspended,!Task.isCancelled,navigation.token==pageToken else{continue}
                    embeddedNavigate?(path,ArchiveBrowseState())
                }catch{if !closed,!Task.isCancelled,navigation.token==pageToken{notice=Self.message(error)}}
                continue
            }
            if let presentation=desiredEmbedded {
                desiredEmbedded=nil
                do {
                    let matches=await session.matchesCurrentSourceObservation()
                    guard !closed,!suspended,!Task.isCancelled,embeddedPresentation?.token==presentation.token,
                          pageToken==presentation.token,desiredEmbedded==nil else{continue}
                    if !matches {
                        // Use the ordinary reader/preparation owner. Compressed
                        // sources return to explicit Prepare, never a hidden decode.
                        refresh();return
                    }
                    let folder=try await session.folder(at:presentation.location.folderPath)
                    guard !closed,!suspended,!Task.isCancelled,embeddedPresentation?.token==presentation.token,pageToken==presentation.token,desiredEmbedded==nil else{continue}
                    let state=presentation.state
                    let visit=Visit(folder:folder,query:state.query,scope:state.scope == .archive ? .archive:.folder,order:Self.tarOrder(state),offset:state.offset)
                    history=[visit];historyIndex=0;install(visit);embeddedSelectedPaths=state.selectedPaths
                    embeddedInstalledToken=presentation.token
                    if state.query.utf8.count>128 {items=[];breadcrumbs=[];current=false;notice="That name search is too long. Try fewer words or characters."}
                    else{requestPage(visit,starting:false)}
                }catch{if !closed,!Task.isCancelled,embeddedPresentation?.token==presentation.token,pageToken==presentation.token{items=[];breadcrumbs=[];current=false;notice=Self.message(error)}}
                continue
            }
            guard let pending=desiredPage else{break};desiredPage=nil
            let symbols=settings.symbolTolerantNames,visit=pending.visit
            do {
                let task=Task{()->Page in
                    if visit.scope == .archive {
                        let result=try await session.searchNames(visit.query,offset:visit.offset,symbolTolerant:symbols,sorting:visit.order)
                        let root=try await session.page(in:session.root)
                        return .init(items:result.items,breadcrumbs:root.breadcrumbs,offset:result.offset,total:result.total)
                    }
                    let result=try await session.page(in:visit.folder,offset:visit.offset,filter:visit.query,symbolTolerant:symbols,sorting:visit.order)
                    return .init(items:result.items,breadcrumbs:result.breadcrumbs,offset:result.offset,total:result.total)
                };queryTask=task
                let page=try await task.value;queryTask=nil
                guard !closed,!suspended,pending.token==pageToken,desiredOpen==nil else{continue}
                items=page.items;breadcrumbs=page.breadcrumbs;offset=page.offset;total=page.total;current=true
                if let selected=pending.selected {selection=page.items.contains{$0.id==selected} ? [selected]:[]}
                else if embeddedPresentation != nil {selection=Set(page.items.filter{item in embeddedSelectedPaths.contains{$0.utf8.elementsEqual(item.path.utf8)}}.map(\.id));embeddedSelectedPaths=[]}
                else{selection=[]}
                notice=(summary?.blockedMembers ?? 0)>0 ? "Links and special items can be viewed by name; they cannot be extracted."
                    : ArchiveBrowsingGuidance.navigationHint
            }catch{if !closed,pending.token==pageToken{notice=Self.message(error);current=false}}
        }
    }
    private func install(_ visit:Visit) {
        installing=true;query=visit.query;scope=visit.scope;order=visit.order;installing=false
    }
    private func requestPage(_ visit:Visit,selected:TARItemID?=nil,starting:Bool=true) {
        pageToken=UUID();current=false;selection=[];desiredPage = .init(visit:visit,token:pageToken,selected:selected)
        queryTask?.cancel();if starting{start()}
    }
    private func scheduleQuery() {
        current=false;selection=[];filterWork?.cancel();queryTask?.cancel();desiredPage=nil;pageToken=UUID()
        filterWork=Task{[weak self]in
            do{try await Task.sleep(for:.milliseconds(160))}catch{return}
            guard let self,!closed,!suspended,history.indices.contains(historyIndex)else{return}
            guard query.utf8.count<=128 else{notice="That name search is too long. Try fewer words or characters.";filterWork=nil;return}
            var visit=history[historyIndex];visit.query=query;visit.scope=scope;visit.order=order;visit.offset=0;history[historyIndex]=visit
            requestPage(visit);filterWork=nil
        }
    }
    func order(by value:TARArchiveOrder){guard !closed,!suspended,history.indices.contains(historyIndex)else{return};order=value;scheduleQuery()}
    func openSelection() {
        guard current,!busy,!isPreparingPreview,selection.count==1,let item=items.first(where:{selection.contains($0.id)}) else{return}
        if let folder=item.folder{visit(folder)}
        else if item.kind == .file { previewSelected() }
    }
    func visit(_ folder:TARFolderID) {
        guard !closed,!suspended,session != nil else{return}
        if embeddedNavigate != nil {
            let token=UUID();pageToken=token;desiredPage=nil;desiredEmbedded=nil
            desiredEmbeddedNavigation=(folder,token);queryTask?.cancel();filterWork?.cancel();start();return
        }
        let value=Visit(folder:folder)
        if historyIndex+1<history.count{history.removeSubrange((historyIndex+1)...)}
        history.append(value);if history.count>128{history.removeFirst()};historyIndex=history.count-1;install(value);requestPage(value)
    }
    func back(){if let embeddedBack{embeddedBack();return};guard canBack else{return};historyIndex-=1;install(history[historyIndex]);requestPage(history[historyIndex])}
    func forward(){if let embeddedForward{embeddedForward();return};guard canForward else{return};historyIndex+=1;install(history[historyIndex]);requestPage(history[historyIndex])}
    func up(){if let embeddedUp{embeddedUp();return};guard canUp,let crumb=scope == .archive ? breadcrumbs.first:breadcrumbs.dropLast().last else{return};visit(crumb.folder)}
    func page(_ forward:Bool) {
        guard current,!busy,history.indices.contains(historyIndex),forward ? hasNext:offset>0 else{return}
        var visit=history[historyIndex];visit.offset=forward ? offset+items.count:max(0,offset-256);history[historyIndex]=visit;requestPage(visit)
    }
    func extract(selected:Bool) {
        guard canExtract,(!selected || selectedSupported),let session,let source,let browser else{return}
        let currentToken=token,currentPage=pageToken,ids=selection
        busy=true
        selectionWork=Task{[self]in
            defer{selectionWork=nil;if work==nil{busy=false}}
            do{
                let members=selected ? try await session.selectionForExtraction(ids):try await session.selectionForWholeExtraction()
                guard permitsEmbeddedAction,!Task.isCancelled,!closed,!suspended,currentToken==token,currentPage==pageToken,
                      !selected || ids==selection,browser.canStartArchiveExtraction else{return}
                if selected { ApplicationArchiveExtraction.shared.showSelection(source: source, from: browser, selection: .tar(members)) }
                else { ApplicationArchiveExtraction.shared.show(source: source, from: browser, tarMembers: members) }
            }catch{if !closed,currentToken==token{notice=Self.message(error)}}
        }
    }
    func stop(){token=UUID();pageToken=UUID();desiredOpen=nil;desiredPage=nil;desiredEmbedded=nil;desiredEmbeddedNavigation=nil;work?.cancel();readTask?.cancel();queryTask?.cancel();filterWork?.cancel();selectionWork?.cancel();textPreview.stop();current=false;requiresPreparation = CompressedTARFeature.available && isCompressedSource;notice="Stopped. Refresh the archive when you’re ready."}
    func suspend(){suspended=true;stop();textPreview.prepareForVolumeQuiescence()}
    func resume(){suspended=false;textPreview.resumeAfterVolumeQuiescence();notice="Refresh to read this archive again."}
    func drain()async {
        if let work{await work.value};if let filterWork{await filterWork.value};if let selectionWork{await selectionWork.value};await textPreview.drain();await reader.drain()
        if suspended, let session { await session.close(); self.session=nil }
    }
    func closeAndDrain()async {
        closed=true;stop();await textPreview.closeAndDrain();await drain()
        if let session{await session.close()};session=nil;source=nil;summary=nil;compressedSummary=nil;items=[];breadcrumbs=[];browser=nil;matching=nil
    }
    static func message(_ error:Error)->String {
        if error is ArchiveMetadataAdmission.Failure{return "Other archives are still opening. Wait briefly, then refresh this archive."}
        if error is CancellationError{return "Stopped. Refresh the archive when you’re ready."}
        guard let failure=error as? TARArchiveFailure else{return ArchiveExtractionModel.message(error)}
        switch failure {
        case .compressed:return "This is a compressed TAR archive. Compressed TAR browsing isn’t available yet. Open it with Archive Utility instead."
        case .malformed:return "This archive is incomplete or damaged. No files were extracted."
        case .unsupported:return "This TAR uses an unsupported entry or format. Links and special items cannot be extracted."
        case .unsafeName,.ambiguousNames:return "Some archive names are unsafe or conflict. No files were extracted."
        case .limited:return "This archive exceeds the current browsing or extraction limits."
        case .changed:return "The archive changed. Refresh it and select the items again."
        case .stopped:return "Stopped. Refresh the archive when you’re ready."
        case .busy:return "The previous archive read is still finishing. Try again shortly."
        case .closed,.invalidSelection:return "That archive selection is no longer available. Refresh and choose it again."
        case .unavailable:return "This archive is unavailable. Check its location and folder access, then try again."
        }
    }
}
