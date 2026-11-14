// Decode only these finite packets' generated, current-process window clips.
import AppKit
@preconcurrency import AVFoundation
import Foundation

enum CommandMotionFailure: Error { case scope, redirectedRoot, reservation, movie, receipt, frame }
func reviewCommandMotion() async throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let profiles = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--profiles"
    let queue = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--queue"
    let search = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--search"
    let largest = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--largest"
    let archivePane = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--archive-pane"
    let archiveSearch = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--archive-search"
    let privateLabels = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--private-labels"
    let archiveDrag = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--archive-drag"
    let archiveOrder = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--archive-order"
    let browserTasks = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--browser-tasks"
    let headerHover = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--header-hover"
    let propertiesStorage = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--properties-storage"
    let folderOpener = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--folder-opener"
    let archiveBytes = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--archive-bytes"
    guard CommandLine.arguments.count == (profiles || queue || search || largest || archivePane || archiveSearch || privateLabels || archiveDrag || archiveOrder || browserTasks || headerHover || propertiesStorage || folderOpener || archiveBytes ? 3 : 2), let last = CommandLine.arguments.last,
          let id = UUID(uuidString: last), id.uuidString == last else { throw CommandMotionFailure.scope }
    let action = profiles ? "traverse-profile-workspaces-ui" : queue ? "traverse-queue-priority" : search ? "traverse-search-progress" : largest ? "traverse-largest-files-ui" : archivePane ? "traverse-archive-pane-destination" : archiveSearch ? "traverse-archive-search" : privateLabels ? "traverse-private-labels" : archiveDrag ? "traverse-archive-member-drag" : archiveOrder ? "traverse-archive-sorting" : browserTasks ? "traverse-browser-tasks" : headerHover ? "traverse-header-hover" : propertiesStorage ? "traverse-properties-storage" : folderOpener ? "traverse-folder-opener" : archiveBytes ? "traverse-archive-bytes-ui" : "traverse-command-finder"
    let prefix = profiles ? "profiles-" : queue ? "queue-" : search ? "search-" : largest ? "largest-" : archivePane ? "archive-pane-" : archiveSearch ? "archive-names-" : privateLabels ? "private-labels-" : archiveDrag ? "archive-drag-" : archiveOrder ? "archive-order-" : browserTasks ? "browser-task-" : headerHover ? "header-hover-" : propertiesStorage ? "properties-storage-" : folderOpener ? "folder-opening-" : archiveBytes ? "archive-bytes-" : "command-"
    let root = repo.appendingPathComponent(".build/traverse-release/" + id.uuidString)
    guard root.resolvingSymlinksInPath().path == root.path else { throw CommandMotionFailure.redirectedRoot }
    guard let reservation = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any],
          reservation["action"] as? String == action else { throw CommandMotionFailure.reservation }
    var clips = ["full", "reduced", "off"].map { (prefix, $0) }
    if action == "traverse-command-finder",
       FileManager.default.fileExists(atPath: root.appendingPathComponent("evidence/editor-command-full.json").path) {
        clips.append(("editor-command-", "full"))
    }
    for (prefix, mode) in clips {
        let movie = root.appendingPathComponent("evidence/" + prefix + mode + ".mov")
        guard movie.resolvingSymlinksInPath().path == movie.path,
              let size = try movie.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 1 << 20 else { throw CommandMotionFailure.movie }
        guard let report = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("evidence/" + prefix + mode + ".json"))) as? [String: Any],
              let began = report["actionUptimeSeconds"] as? Double,
              let frames = report["frames"] as? [[String: Any]],
              let first = frames.first?["receivedUptimeSeconds"] as? Double else { throw CommandMotionFailure.receipt }
        let asset = AVURLAsset(url: movie)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration > 0.5, duration < 3 else { throw CommandMotionFailure.frame }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        guard let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 672,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: sheet) else { throw CommandMotionFailure.frame }
        let detailSheet = queue ? NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 1376,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) : headerHover ? NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1920,pixelsHigh:1140,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0) : nil
        var times: [Double] = []
        // Include curve and settled frames, rather than inspecting only the
        // first quarter-second. NSButton.performClick itself has a native press
        // interval, so this remains visual evidence, not an input-latency test.
        let offsets = [-0.03, 0, 0.022, 0.045, 0.070, 0.10, 0.14, 0.19, 0.27, 0.38, 0.58, 0.82]
        for frame in 0..<12 {
            let time = max(0, min(duration - 0.02, began - first + offsets[frame]))
            let result = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000))
            let image = NSImage(cgImage: result.image, size: .init(width: result.image.width, height: result.image.height))
            if frame == 11 {
                let original = NSBitmapImageRep(cgImage: result.image)
                guard let png = original.representation(using: .png, properties: [:]) else { throw CommandMotionFailure.frame }
                try png.write(to: root.appendingPathComponent("evidence/" + prefix + mode + "-settled.png"), options: .withoutOverwriting)
            }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            let target = NSRect(x: CGFloat(frame % 4) * 320, y: CGFloat(2 - frame / 4) * 224, width: 320, height: 224)
            NSColor.windowBackgroundColor.setFill(); target.fill()
            let available = target.insetBy(dx: 2, dy: 12)
            let scale = min(available.width / image.size.width, available.height / image.size.height)
            let fitted = NSRect(x: available.midX - image.size.width * scale / 2,
                y: available.midY - image.size.height * scale / 2,
                width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: fitted, from: .zero, operation: .copy, fraction: 1)
            NSString(string: mode + String(format: " %.3f s", CMTimeGetSeconds(result.actualTime)))
                .draw(at: .init(x: target.minX + 4, y: target.minY + 2), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.labelColor])
            NSGraphicsContext.restoreGraphicsState(); times.append(CMTimeGetSeconds(result.actualTime))
            if let detailSheet, let detailContext = NSGraphicsContext(bitmapImageRep: detailSheet) {
                // Declared 1:1 native crops: queue lower-right quarter, or
                // the header packet's top160 pixels. Never interpolate small
                // glyphs to make an artificial appearance/motion claim.
                guard result.image.width == 960, result.image.height == 640,
                      let crop = result.image.cropping(to:headerHover ? CGRect(x:0,y:0,width:960,height:160) : CGRect(x:480,y:320,width:480,height:320)) else { throw CommandMotionFailure.frame }
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = detailContext
                let area = headerHover ? NSRect(x:CGFloat(frame%2)*960,y:CGFloat(5-frame/2)*190,width:960,height:190)
                    : NSRect(x:CGFloat(frame%3)*480,y:CGFloat(3-frame/3)*344,width:480,height:344)
                NSColor.windowBackgroundColor.setFill(); area.fill()
                let cropSize = NSSize(width:crop.width,height:crop.height)
                NSImage(cgImage:crop,size:cropSize)
                    .draw(in:NSRect(x:area.minX,y:area.minY+24,width:cropSize.width,height:cropSize.height),from:.zero,operation:.copy,fraction:1)
                NSString(string: mode + String(format: " %.3f s · generated-window "+(headerHover ? "top160 pixels" : "lower-right quarter"), CMTimeGetSeconds(result.actualTime)))
                    .draw(at: .init(x: area.minX + 4, y: area.minY + 4), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.labelColor])
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        guard let png = sheet.representation(using: .png, properties: [:]) else { throw CommandMotionFailure.frame }
        try png.write(to: root.appendingPathComponent("evidence/" + prefix + mode + "-contact.png"), options: .withoutOverwriting)
        if let detailSheet {
            guard let detailPNG = detailSheet.representation(using: .png, properties: [:]) else { throw CommandMotionFailure.frame }
            try detailPNG.write(to: root.appendingPathComponent("evidence/" + prefix + mode + "-detail.png"), options: .withoutOverwriting)
        }
        try JSONSerialization.data(withJSONObject: ["generatedOnly": true, "originalUnmodified": true,
            "duration": duration, "frameTimes": times], options: [.sortedKeys])
            .write(to: root.appendingPathComponent("evidence/" + prefix + mode + "-frame-review.json"), options: .withoutOverwriting)
    }
    print("\(clips.count) generated window clips decoded; \(clips.count * 12) authentic sample frames retained")
}
do { try await reviewCommandMotion() }
catch { fputs("Generated command movie review refused: \(error)\n", stderr); exit(1) }
