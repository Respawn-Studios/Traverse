// Shared offscreen native inspection for all isolated pipeline lanes.
import AppKit
import Foundation
import SwiftUI

private final class PagedInspectionBackground:NSView {
    override var isOpaque:Bool {true}
    override func draw(_ dirtyRect:NSRect) {
        NSColor.windowBackgroundColor.setFill();dirtyRect.fill()
    }
}

@MainActor
final class PagedNativeInspection:NSObject,NSTableViewDataSource,NSTableViewDelegate {
    let window:NSWindow
    let generation=UUID()
    private let began=ProcessInfo.processInfo.systemUptime
    private let label=NSTextField(labelWithString:"Preparing generated metadata scan…")
    private let table=NSTableView(),scroll=NSScrollView()
    private var host:NSHostingView<StorageAttributionView>?
    private var rows:[PagedRow]=[]
    private var memoryRows:StorageAnalysisPreparedRows?
    private var wrappers:[Int:StorageAnalysisFolderItem]=[:]
    private var heartbeatTask:Task<Void,Never>?
    private var heartbeatGaps:[Double]=[]
    private var firstFeedback:Double?
    private var finished=false
    private(set) var peakVisibleRows=0
    private(set) var rootWrapperCount=0
    init(title:String) {
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:980,height:720),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        super.init()
        window.title=title;window.isReleasedWhenClosed=false;window.setFrameOrigin(NSPoint(x:-12000,y:-12000))
        window.appearance=NSAppearance(named:.darkAqua)
        let content=PagedInspectionBackground(frame:NSRect(x:0,y:0,width:980,height:720));window.contentView=content
        label.drawsBackground=true;label.backgroundColor = .windowBackgroundColor
        label.frame=NSRect(x:16,y:678,width:948,height:24);content.addSubview(label)
        scroll.frame=NSRect(x:16,y:340,width:948,height:326);scroll.documentView=table;scroll.hasVerticalScroller=true
        table.frame=NSRect(x:0,y:0,width:948,height:326);table.dataSource=self;table.delegate=self;table.rowHeight=25
        for (id,title,width) in [("name","Folder or file",570.0),("kind","Kind",120.0),("size","Observed logical size",230.0)] {
            let column=NSTableColumn(identifier:.init(id));column.title=title;column.width=width;table.addTableColumn(column)
        }
        content.addSubview(scroll)
        heartbeatTask=Task { [weak self] in
            var previous=ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for:.milliseconds(20))
                guard let self,!Task.isCancelled else {return}
                let now=ProcessInfo.processInfo.systemUptime
                if self.heartbeatGaps.count<15000 {self.heartbeatGaps.append(now-previous)}
                previous=now
            }
        }
    }
    func progress(_ count:UInt64,token:UUID) {
        guard token==generation,!finished else {return}
        label.stringValue="Scanning · \(count) observed entries · generated fixture only"
        if firstFeedback==nil {firstFeedback=ProcessInfo.processInfo.systemUptime-began}
    }
    func completed(_ count:UInt64,complete:Bool) {
        label.stringValue="\(complete ? "Finished selected scope":"Partial observation") · \(count) generated metadata entries · read only"
    }
    func showMemory(_ prepared:StorageAnalysisPreparedRows) {
        memoryRows=prepared;rows=[]
        wrappers[0]=StorageAnalysisFolderItem(0)
        for id in prepared.children(of:0) {wrappers[id]=StorageAnalysisFolderItem(id)}
        rootWrapperCount=wrappers.count;table.reloadData();window.contentView?.layoutSubtreeIfNeeded()
    }
    func showPage(_ values:[PagedRow]) {
        memoryRows=nil;wrappers=[:];rows=values
        peakVisibleRows=max(peakVisibleRows,values.count);table.reloadData();window.contentView?.layoutSubtreeIfNeeded()
    }
    func showChart(_ report:AnalysisAttributionReport,kind:Int) {
        host?.removeFromSuperview()
        let view=NSHostingView(rootView:StorageAttributionView(report:report,initialGroup:kind))
        view.frame=NSRect(x:16,y:12,width:948,height:314)
        window.contentView?.addSubview(view);host=view
        view.layoutSubtreeIfNeeded();view.displayIfNeeded()
    }
    func snapshot(path:String) throws {
        let prefix=FileManager.default.currentDirectoryPath+"/.build/b06-analyzer/evidence-extension-20261018/"
        guard path.hasPrefix(prefix),!path.dropFirst(prefix.count).contains("/"),
              path.hasSuffix(".png"),let content=window.contentView,
              let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) else {throw PagedFailure(code:-180)}
        content.layoutSubtreeIfNeeded()
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            content.cacheDisplay(in:content.bounds,to:bitmap)
        }
        guard let data=bitmap.representation(using:.png,properties:[:]),data.count<=1<<20 else {throw PagedFailure(code:-181)}
        let parent=b06_open_root(String(prefix.dropLast()))
        guard parent>=0 else {throw PagedFailure(code:-183)}
        defer {Darwin.close(parent)}
        let fd=Darwin.openat(parent,String(path.dropFirst(prefix.count)),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else {throw PagedFailure(code:-182)}
        let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true);try file.write(contentsOf:data);try file.close()
    }
    func finish()->[String:Any] {
        finished=true
        heartbeatTask?.cancel();heartbeatTask=nil
        let sorted=heartbeatGaps.sorted()
        let result:[String:Any]=["first_feedback_seconds":firstFeedback.map {$0 as Any} ?? NSNull(),
            "heartbeat_p99_seconds":sorted.isEmpty ? 0:sorted[min(sorted.count-1,Int(Double(sorted.count-1)*0.99))],
            "heartbeat_max_seconds":sorted.last ?? 0,"heartbeat_samples":sorted.count,
            "peak_visible_rows":peakVisibleRows,"reference_root_wrappers":rootWrapperCount]
        host=nil;window.orderOut(nil);return result
    }
    func numberOfRows(in tableView:NSTableView)->Int {memoryRows.map {$0.children(of:0).count} ?? rows.count}
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView? {
        let text=NSTextField(labelWithString:"");text.lineBreakMode = .byTruncatingMiddle
        guard row>=0 else {return text}
        let name:String,kind:String,size:String
        if let prepared=memoryRows {
            let children=prepared.children(of:0)
            guard row<children.count else {return text}
            let folder=prepared.snapshot.folders[children[children.startIndex+row]],path=folder.relativePath
            let start=path.lastIndex(of:47).map {path.index(after:$0)} ?? path.startIndex
            name=String(bytes:path[start...],encoding:.utf8) ?? "Name is not UTF-8";kind="Folder"
            size=storageMetricText(folder.namespaceSubtotals.dataLogical,files:folder.counts.regularFiles)
        } else {
            guard rows.indices.contains(row) else {return text}
            let value=rows[row];name=value.title;kind=value.kind==1 ? "Folder":"File"
            size=value.value.map {storageMetricText($0.bytes.dataLogical,files:$0.counts[0])} ?? "Calculating"
        }
        text.stringValue=column?.identifier.rawValue=="kind" ? kind:column?.identifier.rawValue=="size" ? size:name
        return text
    }
}
