#if DEBUG
import AppKit
import CryptoKit
import ExplorerCore
import LocalStorage
import ObjectiveC

/// Actual custom-item background drawing under AppKit's documented proposal
/// states. This is a raster component oracle, not a physical marquee gesture.
@MainActor enum SelectionPreviewVerification {
    private enum Failure: Error { case scope, raster }
    private static func raster(_ view: NSView, root: URL, label: String) throws -> [Double] {
        let width = Int(view.bounds.width), height = Int(view.bounds.height)
        guard width > 20, height > 20, width <= 600, height <= 240,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: rep) else { throw Failure.raster }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill(); view.bounds.fill()
            view.draw(view.bounds); NSGraphicsContext.restoreGraphicsState()
        }
        guard let bytes = rep.representation(using: .png, properties: [:]) else { throw Failure.raster }
        try bytes.write(to: root.appendingPathComponent("evidence/\(label).png"), options: .withoutOverwriting)
        var mean = [Double](repeating: 0, count: 3)
        for y in 8..<13 { for x in 8..<13 {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { throw Failure.raster }
            mean[0] += color.redComponent / 25; mean[1] += color.greenComponent / 25; mean[2] += color.blueComponent / 25
        } }
        return mean
    }
    private static func difference(_ a: [Double], _ b: [Double]) -> Double { zip(a,b).map { abs($0 - $1) }.max() ?? 0 }
    static func run() async {
        var root: URL?, reports: [[String:Any]] = [], failures: [String] = []
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let area = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("reservation.json"))) as? [String:Any]
            guard area.resolvingSymlinksInPath() == area, area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development"),
                  marker?["action"] as? String == "native-selection-preview", Bundle.main.bundleIdentifier == "local.macexplorer.development" else { throw Failure.scope }
            root = area
            let (band, bandPassed, metrics) = try TableMarqueeSelection.rasterForVerification()
            try band.write(to:area.appendingPathComponent("evidence/table-band.png"),options:.withoutOverwriting)
            try JSONSerialization.data(withJSONObject:metrics,options:[.prettyPrinted,.sortedKeys]).write(to:area.appendingPathComponent("evidence/table-band.json"),options:.withoutOverwriting)
            if !bandPassed { failures.append("table band raster contrast or hit testing") }
            for name: NSAppearance.Name in [.aqua,.darkAqua] { for emphasized in [true,false] { for kind in ["volume","file"] {
                let item: NSCollectionViewItem
                if kind == "volume" {
                    let tile = VolumeTileItem(); _ = tile.view; tile.view.frame = .init(x: 0, y: 0, width: 300, height: 76)
                    tile.configure(.init(url: area.appendingPathComponent("source/Generated drive", isDirectory: true), name: "Generated drive", kind: .externalDisk, totalBytes: 1024, availableBytes: 512, isReadOnly: false), emphasized: emphasized)
                    item = tile
                } else {
                    let tile = FileIconItem(); _ = tile.view; tile.view.frame = .init(x: 0, y: 0, width: 140, height: 120)
                    tile.configure(.init(url: area.appendingPathComponent("source/Generated.txt"), name: "Generated.txt", kind: .file, byteCount: 16), showsExtensions: true, cut: false, emphasized: emphasized)
                    item = tile
                }
                item.view.appearance = NSAppearance(named: name); item.view.layoutSubtreeIfNeeded()
                let label = kind + "-" + (name == .aqua ? "light" : "dark") + (emphasized ? "-active" : "-inactive")
                item.isSelected = false; item.highlightState = .none
                let idle = try raster(item.view, root: area, label: label + "-idle")
                item.highlightState = .forSelection
                let proposed = try raster(item.view, root: area, label: label + "-proposed")
                let unchangedModel = !item.isSelected
                item.highlightState = .none
                let restored = try raster(item.view, root: area, label: label + "-restored")
                item.isSelected = true
                let committed = try raster(item.view, root: area, label: label + "-committed")
                item.highlightState = .forDeselection
                let deselecting = try raster(item.view, root: area, label: label + "-deselecting")
                let selectedModelKept = item.isSelected
                item.highlightState = .none
                let selectedAgain = try raster(item.view, root: area, label: label + "-selected-again")
                let oracle = difference(idle,committed) > 0.03
                let passed = oracle && unchangedModel && selectedModelKept && difference(proposed,committed) < 0.01
                    && difference(restored,idle) < 0.01 && difference(deselecting,idle) < 0.01 && difference(selectedAgain,committed) < 0.01
                if !passed { failures.append(label) }
                reports.append(["label":label,"passed":passed,"oracleHasCommittedContrast":oracle,"modelUnchangedUntilCommit":unchangedModel && selectedModelKept,
                    "proposalVersusCommitted":difference(proposed,committed),"deselectionVersusIdle":difference(deselecting,idle)])
            } } }
            for type in [VolumeCollectionView.self,FileIconCollectionView.self] {
                guard let collection = class_getInstanceMethod(type, #selector(NSResponder.mouseDown(with:))),
                      let native = class_getInstanceMethod(NSCollectionView.self, #selector(NSResponder.mouseDown(with:))) else { throw Failure.scope }
                if unsafeBitCast(method_getImplementation(collection),to:UInt.self) != unsafeBitCast(method_getImplementation(native),to:UInt.self) { failures.append("native mouseDown replaced") }
            }
        } catch { failures.append(String(reflecting: type(of: error))) }
        if let root {
            let value: [String:Any] = ["passed":failures.isEmpty && reports.count == 8,"cases":reports,"failures":failures,"physicalInputExercised":false,
                "componentRasterOnly":true,"fileBodyReads":0,"networkRequests":0,"activityDrained":ApplicationFileActivity.gate.activeCount == 0]
            try? JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("evidence/native-selection-preview.json"),options:.withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
}
#endif
