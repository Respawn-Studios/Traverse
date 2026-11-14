// Decode only one completed generated tester packet; no desktop capture.
import AppKit
@preconcurrency import AVFoundation
import Foundation

enum TesterReviewFailure: Error { case scope, frame }
func reviewTesterRepairs() async throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard CommandLine.arguments.count == 2, let id = UUID(uuidString: CommandLine.arguments[1]),
          id.uuidString == CommandLine.arguments[1] else { throw TesterReviewFailure.scope }
    let root = repo.appendingPathComponent(".build/traverse-release/" + id.uuidString)
    guard root.resolvingSymlinksInPath().path == root.path,
          let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any],
          marker["action"] as? String == "traverse-tester-repair-qualification",
          let result = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("evidence/native.json"))) as? [String: Any],
          result["passed"] as? Bool == true,
          let motion = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("evidence/motion.json"))) as? [String: [String: Any]] else { throw TesterReviewFailure.scope }
    let modes = ["full", "reduced", "off"].filter { motion["tester-folder-" + $0] != nil }
    guard !modes.isEmpty, motion.count == modes.count * 3, result["recordedClips"] as? Int == motion.count else { throw TesterReviewFailure.scope }
    var reports: [[String: Any]] = []
    for direction in ["folder", "computer", "return"] {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: modes.count * 672,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw TesterReviewFailure.frame }
        for (modeIndex, mode) in modes.enumerated() {
            let name = "tester-\(direction)-\(mode)"
            guard let metadata = motion[name], let action = metadata["actionUptimeSeconds"] as? Double,
                  let frames = metadata["frames"] as? [[String: Any]], let first = frames.first,
                  let received = first["receivedUptimeSeconds"] as? Double else { throw TesterReviewFailure.frame }
            let asset = AVURLAsset(url: root.appendingPathComponent("evidence/\(name).mov"))
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            guard duration > 0.4, duration < 3 else { throw TesterReviewFailure.frame }
            let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            var times: [Double] = []
            for (index, offset) in [-0.06, 0, 0.035, 0.07, 0.105, 0.14, 0.18, 0.22, 0.30, 0.42, 0.60, 0.80].enumerated() {
                let requested = min(duration - 0.02, max(0, action - received + offset))
                let frame = try await generator.image(at: CMTime(seconds: requested, preferredTimescale: 60000))
                let image = NSImage(cgImage: frame.image, size: .init(width: 960, height: 640))
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                let row = modeIndex * 3 + index / 4
                let target = NSRect(x: CGFloat(index % 4) * 320, y: CGFloat(modes.count * 3 - 1 - row) * 224, width: 320, height: 224)
                NSColor(white: 0.12, alpha: 1).setFill(); target.fill()
                image.draw(in: target.insetBy(dx: 2, dy: 12), from: .zero, operation: .copy, fraction: 1)
                NSString(string: String(format: "%@ · action %+.3f s", mode, offset)).draw(at: .init(x: target.minX + 4, y: target.minY + 2),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.white])
                NSGraphicsContext.restoreGraphicsState(); times.append(CMTimeGetSeconds(frame.actualTime))
            }
            reports.append(["clip": name, "duration": duration, "sampledMovieSeconds": times, "actionOffsetSeconds": action - received])
        }
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw TesterReviewFailure.frame }
        try bytes.write(to: root.appendingPathComponent("evidence/tester-\(direction)-contact.png"), options: .withoutOverwriting)
    }
    try JSONSerialization.data(withJSONObject: ["generatedOnly": true, "clips": reports, "sampledFrames": motion.count * 12], options: [.sortedKeys, .prettyPrinted])
        .write(to: root.appendingPathComponent("evidence/frame-review.json"), options: .withoutOverwriting)
    print("Decoded \(motion.count) owned-window movies into \(motion.count * 12) frame views.")
}
do { try await reviewTesterRepairs() } catch {
    if let known = error as? TesterReviewFailure { fputs("Generated tester review failed: \(known). Originals retained.\n", stderr) }
    else { let value = error as NSError; fputs("Generated tester decode failed: \(value.domain)/\(value.code). Originals retained.\n", stderr) }
    exit(1)
}
