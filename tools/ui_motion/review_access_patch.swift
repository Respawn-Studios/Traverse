// Decode only the current patch's generated single-window movies. Never
// enumerate displays, capture live UI, replace frames or inspect personal files.
import AppKit
@preconcurrency import AVFoundation
import Foundation

enum PatchReviewFailure: Error { case scope, frame }
func review() async throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard CommandLine.arguments.count == 2, let id = UUID(uuidString: CommandLine.arguments[1]),
          id.uuidString == CommandLine.arguments[1] else { throw PatchReviewFailure.scope }
    let root = repo.appendingPathComponent(".build/traverse-patch-0.1.1/" + id.uuidString)
    guard root.resolvingSymlinksInPath().path == root.path,
          try String(contentsOf: root.appendingPathComponent("owned.txt"), encoding: .utf8) == "Traverse generated access patch v1\n" else { throw PatchReviewFailure.scope }
    var reports: [[String: Any]] = []
    for name in ["to-this-mac", "from-this-mac", "keyboard-entrance"] {
        let movie = root.appendingPathComponent("evidence/\(name).mov")
        let asset = AVURLAsset(url: movie)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration > 0.4, duration < 3 else { throw PatchReviewFailure.frame }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        guard let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 672,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: sheet) else { throw PatchReviewFailure.frame }
        var sampled: [Double] = []
        for frame in 0..<12 {
            let time = min(duration - 0.02, Double(frame) * 0.045)
            let result = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000))
            let image = NSImage(cgImage: result.image, size: .init(width: 960, height: 640))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            let target = NSRect(x: CGFloat(frame % 4) * 320, y: CGFloat(2 - frame / 4) * 224, width: 320, height: 224)
            NSColor.windowBackgroundColor.setFill(); target.fill()
            image.draw(in: target.insetBy(dx: 2, dy: 12), from: .zero, operation: .copy, fraction: 1)
            NSString(string: String(format: "%.3f s", CMTimeGetSeconds(result.actualTime)))
                .draw(at: .init(x: target.minX + 4, y: target.minY + 2), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.labelColor])
            NSGraphicsContext.restoreGraphicsState()
            sampled.append(CMTimeGetSeconds(result.actualTime))
        }
        guard let data = sheet.representation(using: .png, properties: [:]) else { throw PatchReviewFailure.frame }
        try data.write(to: root.appendingPathComponent("evidence/\(name)-contact.png"), options: .withoutOverwriting)
        reports.append(["clip": name, "duration": duration, "nativeFrameTimes": sampled])
    }
    try JSONSerialization.data(withJSONObject: ["generatedOnly": true, "clips": reports], options: [.prettyPrinted, .sortedKeys])
        .write(to: root.appendingPathComponent("evidence/frame-review.json"), options: .withoutOverwriting)
    print("3 native movies decoded; 36 frames retained in contact sheets")
}
do { try await review() }
catch { fputs("Generated patch movie review refused or failed: \(error); originals preserved\n", stderr); exit(1) }
