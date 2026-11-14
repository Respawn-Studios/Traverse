// Read only our generated movies; render a contact sheet and frame metadata.
// Original videos are preserved. This is frame extraction, never UI redrawing.
import AppKit
@preconcurrency import AVFoundation
import Foundation

enum ReviewFailure: Error { case scope, frame }
func review() async throws {
let repo = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
guard (2...3).contains(CommandLine.arguments.count), let uuid = UUID(uuidString: CommandLine.arguments[1]), uuid.uuidString == CommandLine.arguments[1],
      CommandLine.arguments.count == 2 || ["--completion", "--identity", "--foundation", "--sftp", "--sftp-browser", "--sftp-setup", "--download", "--upload", "--native"].contains(CommandLine.arguments[2]) else { throw ReviewFailure.scope }
let identity = CommandLine.arguments.last == "--identity"
let foundation = CommandLine.arguments.last == "--foundation"
let sftp = CommandLine.arguments.last == "--sftp"
let sftpBrowser = CommandLine.arguments.last == "--sftp-browser"
let sftpSetup = CommandLine.arguments.last == "--sftp-setup"
let download = CommandLine.arguments.last == "--download"
let upload = CommandLine.arguments.last == "--upload"
let native = CommandLine.arguments.last == "--native"
let packet = native ? ".build/traverse-development" : upload ? ".build/b12-upload-integration" : download ? ".build/b12-download-qualification" : sftp || sftpBrowser || sftpSetup ? ".build/b11-native-qualification" : foundation ? ".build/overnight-foundation" : identity ? ".build/b10-helper-identity" : CommandLine.arguments.count == 3 ? ".build/b10-completion-qualification" : ".build/b10-browser-qualification"
let root = repo.appendingPathComponent("\(packet)/\(uuid.uuidString)")
let input = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(native ? "reservation.json" : "inputs.json"))) as? [String: Any]
guard root.resolvingSymlinksInPath().path == root.path else { throw ReviewFailure.scope }
if native {
    guard ["native-drive-benchmark", "native-drive-storage-status", "native-zip-rename-copy", "smb-selected-download-ordinary-native"].contains(input?["action"] as? String ?? "") else {
        throw ReviewFailure.scope
    }
} else if upload {
    guard input?["configuredSignature"] as? Bool == true, input?["personalEndpoints"] as? Int == 0,
          input?["keychainQueries"] as? Int == 0, input?["normalStartupPrevented"] as? Bool == true,
          input?["ordinaryUpload"] as? Bool == false else { throw ReviewFailure.scope }
} else if download {
    guard input?["configuredSignature"] as? Bool == true, input?["personalEndpoints"] as? Int == 0,
          input?["keychainQueriesRequested"] as? Int == 0, input?["normalStartupPrevented"] as? Bool == true else { throw ReviewFailure.scope }
} else if sftpSetup {
    guard input?["scenario"] as? String == "generated-sftp-setup", input?["nativeStream"] as? Bool == true,
          input?["networkConnections"] as? Int == 0, input?["keychainAccesses"] as? Int == 0 else { throw ReviewFailure.scope }
} else if sftpBrowser {
    guard input?["scenario"] as? String == "generated-sftp-browser", input?["nativeStream"] as? Bool == true,
          input?["networkConnections"] as? Int == 1, input?["keychainAccesses"] as? Int == 0,
          input?["personalCatalogs"] as? Int == 0 else { throw ReviewFailure.scope }
} else if sftp {
    guard input?["scenario"] as? String == "generated-sftp-trust", input?["nativeStream"] as? Bool == true,
          input?["networkConnections"] as? Int == 0, input?["keychainAccesses"] as? Int == 0,
          input?["personalCatalogs"] as? Int == 0 else { throw ReviewFailure.scope }
} else if foundation {
    guard input?["scenario"] as? String == "motion-modes", input?["generatedOnly"] as? Bool == true,
          input?["actualSingleWindowRecording"] as? Bool == true, input?["keychainQueries"] as? Int == 0,
          input?["personalCatalogs"] as? Int == 0 else { throw ReviewFailure.scope }
} else if identity {
    guard input?["actualSingleWindowRecording"] as? Bool == true, input?["networkConnections"] as? Int == 0,
          input?["keychainAccesses"] as? Int == 0, input?["personalCatalogs"] as? Int == 0 else { throw ReviewFailure.scope }
} else {
    guard input?["scenario"] as? String == "generated-smb-connect", input?["nativeStream"] as? Bool == true else { throw ReviewFailure.scope }
}
var reports: [[String: Any]] = []
let uploadReport = upload ? try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("evidence/native-upload.json"))) as? [String: Any] : nil
let downloadReport = download ? try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("evidence/native-download.json"))) as? [String: Any] : nil
let downloadScenario = downloadReport?["scenario"] as? String ?? ""
if download { guard ["layout", "success", "stop"].contains(downloadScenario), downloadReport?["passed"] as? Bool == true else { throw ReviewFailure.scope } }
if upload {
    guard ["layout", "success"].contains(uploadReport?["scenario"] as? String ?? ""), uploadReport?["passed"] as? Bool == true,
          uploadReport?["scenario"] as? String == "layout" ? uploadReport?["networkConnections"] as? Int == 0 : uploadReport?["actualSharedConnect"] as? Bool == true else { throw ReviewFailure.scope }
}
let archiveNative = native && input?["action"] as? String == "native-zip-rename-copy"
let statusNative = native && input?["action"] as? String == "native-drive-storage-status"
let moveNative = native && input?["action"] as? String == "smb-selected-download-ordinary-native"
if moveNative {
    let result = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("evidence/native-smb-download.json"))) as? [String: Any]
    guard result?["passed"] as? Bool == true, result?["stage"] as? String == "finished",
          result?["keychainCalls"] as? Int == 0 else { throw ReviewFailure.scope }
}
if archiveNative {
    let result = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("evidence/native-zip-rename-copy.json"))) as? [String: Any]
    guard result?["passed"] as? Bool == true, result?["visualInspection"] as? Bool == true else {
        throw ReviewFailure.scope
    }
}
let nativeClips = moveNative ? ["smb-move-destination"] : archiveNative ? ["zip-copy-review"] : statusNative
    ? ["drive-status-refresh"] + (FileManager.default.fileExists(atPath: root.appendingPathComponent("evidence/drive-health-readings.mov").path) ? ["drive-health-readings"] : [])
    : ["drive-benchmark-run"]
let clips = native ? nativeClips : upload ? [uploadReport?["scenario"] as? String == "layout" ? "upload-preview" : "upload-surface"] : download ? ["download-" + downloadScenario] : sftpSetup ? (input?["setupSMBClip"] as? Bool == true ? ["setup-connect", "setup-smb", "setup-storage"] : ["setup-connect", "setup-storage"]) : sftpBrowser ? ["sftp-solid", "sftp-glass"] : sftp ? ["trust-forward", "trust-back", "trust-reduced", "trust-off"] : foundation ? ["full", "reduced", "off"].flatMap { ["tabs-"+$0, "chart-"+$0] }
    : identity ? ["remote-solid", "remote-glass"] : (1...4).map { "native-motion-\($0)" }
for clip in clips {
    let file = root.appendingPathComponent("evidence/\(clip).mov")
    let asset = AVURLAsset(url: file)
    let duration = CMTimeGetSeconds(try await asset.load(.duration))
    guard duration > 0.4, duration < 3 else { throw ReviewFailure.frame }
    let count = native ? 16 : 8, rows = native ? 4 : 2
    let tileHeight = native ? 210 : 180, imageHeight = native ? 190 : 160
    var action = 0.0
    if native {
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(
            moveNative ? "evidence/smb-move-destination-motion.json" : archiveNative ? "evidence/zip-copy-review.json" : statusNative ? "evidence/\(clip).json" : "evidence/drive-benchmark-motion.json"))) as? [String: Any]
        let frames = report?["frames"] as? [[String: Any]]
        guard let began = report?["actionUptimeSeconds"] as? Double,
              let first = frames?.first?["presentationSeconds"] as? Double,
              report?["source"] as? String == "ScreenCaptureKit.currentProcess/single-window",
              report?["writerCompleted"] as? Bool == true else { throw ReviewFailure.scope }
        action = max(0, began - first)
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    guard let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 960, pixelsHigh: rows * tileHeight,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: sheet) else { throw ReviewFailure.frame }
    var sampled: [[String: Double]] = []
    for frame in 0..<count {
        // Dense early sampling catches brief transitions. The last native
        // sample also retains the settled state. These are actual movie frames.
        let time = native ? (frame == count - 1 ? duration - 0.02 : min(duration - 0.02, max(0, action - 0.04) + Double(frame) * 0.02))
            : duration * Double(frame) / 8
        let extracted = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000))
        let image = NSImage(cgImage: extracted.image, size: NSSize(width: extracted.image.width, height: extracted.image.height))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        let x = CGFloat(frame % 4) * 240, y = CGFloat(rows - 1 - frame / 4) * CGFloat(tileHeight)
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill(); NSRect(x: x, y: y, width: 240, height: CGFloat(tileHeight)).fill()
        let ratio = min(240 / image.size.width, CGFloat(imageHeight) / image.size.height)
        let width = image.size.width * ratio, height = image.size.height * ratio
        image.draw(in: NSRect(x: x + (240 - width) / 2, y: y + 20 + (CGFloat(imageHeight) - height) / 2, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        (String(format: "%.3f s", CMTimeGetSeconds(extracted.actualTime)) as NSString).draw(at: NSPoint(x: x + 8, y: y + 3),
            withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        sampled.append(["requestedSeconds": time, "actualSeconds": CMTimeGetSeconds(extracted.actualTime)])
        if frame == 3 {
            let rep = NSBitmapImageRep(cgImage: extracted.image)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw ReviewFailure.frame }
            try png.write(to: root.appendingPathComponent("evidence/\(clip)-detail.png"), options: .withoutOverwriting)
        }
    }
    guard let png = sheet.representation(using: .png, properties: [:]), png.count < (native ? 1 << 20 : 262144) else { throw ReviewFailure.frame }
    try png.write(to: root.appendingPathComponent("evidence/\(clip)-sheet.png"), options: .withoutOverwriting)
    reports.append(["clip": clip, "durationSeconds": duration, "samples": sampled])
}
let data = try JSONSerialization.data(withJSONObject: ["source": "Exact recorded native movie samples", "clips": reports], options: [.prettyPrinted, .sortedKeys])
try data.write(to: root.appendingPathComponent("evidence/movie-review.json"), options: .withoutOverwriting)
print("\(clips.count) native movies decoded; \(clips.count * (native ? 16 : 8)) frames retained in contact sheets")
}
do { try await review() }
catch { fputs("Generated movie review refused or decoding failed; originals preserved\n", stderr); exit(1) }
