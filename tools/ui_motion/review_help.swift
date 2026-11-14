// Decode only the admitted current-process generated Help recordings.
import AppKit
@preconcurrency import AVFoundation
import Foundation
enum HelpReviewFailure: Error { case scope, frame }
func reviewHelp() async throws {
    let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard CommandLine.arguments.count == 2, let id = UUID(uuidString:CommandLine.arguments[1]),
          id.uuidString == CommandLine.arguments[1] else { throw HelpReviewFailure.scope }
    let root = repo.appendingPathComponent(".build/traverse-release/" + id.uuidString)
    guard root.resolvingSymlinksInPath().path == root.path,
          let marker = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("reservation.json"))) as? [String:Any],
          marker["action"] as? String == "traverse-native-help-diagnostics" else { throw HelpReviewFailure.scope }
    var reports: [[String:Any]] = []
    let current = FileManager.default.fileExists(atPath: root.appendingPathComponent("evidence/help-logs.mov").path)
    let names = current ? ["help-release","help-logs","help-support","help-about"] : ["help-release","help-history","help-support"]
    for name in names {
        let asset = AVURLAsset(url:root.appendingPathComponent("evidence/" + name + ".mov"))
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration > 0.4, duration < 3 else { throw HelpReviewFailure.frame }
        let generator = AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1280,pixelsHigh:672,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
              let context = NSGraphicsContext(bitmapImageRep:bitmap) else { throw HelpReviewFailure.frame }
        var times: [Double] = []
        for index in 0..<12 {
            let frame = try await generator.image(at:CMTime(seconds:min(duration-0.02,Double(index)*0.045),preferredTimescale:60000))
            let image = NSImage(cgImage:frame.image,size:.init(width:960,height:640))
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = context
            let target = NSRect(x:CGFloat(index%4)*320,y:CGFloat(2-index/4)*224,width:320,height:224)
            NSColor(white:0.12,alpha:1).setFill();target.fill()
            image.draw(in:target.insetBy(dx:2,dy:12),from:.zero,operation:.copy,fraction:1)
            NSString(string:String(format:"%.3f s",CMTimeGetSeconds(frame.actualTime))).draw(at:.init(x:target.minX+4,y:target.minY+2),
                withAttributes:[.font:NSFont.systemFont(ofSize:9),.foregroundColor:NSColor.white])
            NSGraphicsContext.restoreGraphicsState();times.append(CMTimeGetSeconds(frame.actualTime))
        }
        guard let bytes = bitmap.representation(using:.png,properties:[:]) else { throw HelpReviewFailure.frame }
        try bytes.write(to:root.appendingPathComponent("evidence/" + name + "-contact.png"),options:.withoutOverwriting)
        reports.append(["clip":name,"duration":duration,"nativeFrameTimes":times])
    }
    try JSONSerialization.data(withJSONObject:["generatedOnly":true,"clips":reports],options:[.prettyPrinted,.sortedKeys])
        .write(to:root.appendingPathComponent("evidence/frame-review.json"),options:.withoutOverwriting)
    print("Decoded \(names.count) generated Help movies; retained \(names.count * 12) native frame views.")
}
do { try await reviewHelp() } catch {
    if let failure = error as? HelpReviewFailure { fputs("Generated Help review failed: \(failure). Originals retained.\n",stderr) }
    else { let value = error as NSError; fputs("Generated Help decode failed: \(value.domain) / \(value.code). Originals retained.\n",stderr) }
    exit(1)
}
