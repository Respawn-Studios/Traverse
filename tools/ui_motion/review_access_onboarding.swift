// Read only the generated access/tour recording. No live capture or display
// enumeration; originals remain intact and every decoded frame is authentic.
import AppKit
@preconcurrency import AVFoundation
import Foundation

enum AccessMotionFailure: Error { case scope, frame }
func reviewAccessMotion() async throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard CommandLine.arguments.count == 2, let id = UUID(uuidString: CommandLine.arguments[1]),
        id.uuidString == CommandLine.arguments[1] else { throw AccessMotionFailure.scope }
    let root = repo.appendingPathComponent(".build/traverse-release/" + id.uuidString)
    guard root.resolvingSymlinksInPath().path == root.path,
        let reservation = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any],
        reservation["action"] as? String == "traverse-access-onboarding-qualification" else { throw AccessMotionFailure.scope }
    let movie = root.appendingPathComponent("evidence/tour-next.mov")
    guard movie.resolvingSymlinksInPath() == movie,
        let size = try movie.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 16 << 20 else { throw AccessMotionFailure.scope }
    let asset = AVURLAsset(url: movie)
    let duration = CMTimeGetSeconds(try await asset.load(.duration))
    guard duration > 0.5, duration < 3 else { throw AccessMotionFailure.frame }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    guard let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 672,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: sheet) else { throw AccessMotionFailure.frame }
    var times: [Double] = []
    for frame in 0..<12 {
        let result = try await generator.image(at: CMTime(seconds: Double(frame) * 0.045, preferredTimescale: 60000))
        let image = NSImage(cgImage: result.image, size: .init(width: 960, height: 640))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        let target = NSRect(x: CGFloat(frame % 4) * 320, y: CGFloat(2 - frame / 4) * 224, width: 320, height: 224)
        NSColor.windowBackgroundColor.setFill(); target.fill()
        image.draw(in: target.insetBy(dx: 2, dy: 12), from: .zero, operation: .copy, fraction: 1)
        NSString(string: String(format: "%.3f s", CMTimeGetSeconds(result.actualTime)))
            .draw(at: .init(x: target.minX + 4, y: target.minY + 2), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.labelColor])
        NSGraphicsContext.restoreGraphicsState(); times.append(CMTimeGetSeconds(result.actualTime))
    }
    guard let png = sheet.representation(using: .png, properties: [:]) else { throw AccessMotionFailure.frame }
    try png.write(to: root.appendingPathComponent("evidence/tour-contact.png"), options: .withoutOverwriting)
    try JSONSerialization.data(withJSONObject: ["generatedOnly": true, "originalUnmodified": true,
        "duration": duration, "frameTimes": times], options: [.sortedKeys])
        .write(to: root.appendingPathComponent("evidence/tour-frame-review.json"), options: .withoutOverwriting)
    print("Generated tour clip decoded; twelve authentic frames retained")
}
do { try await reviewAccessMotion() }
catch { fputs("Generated tour movie review refused: \(error)\n", stderr); exit(1) }
