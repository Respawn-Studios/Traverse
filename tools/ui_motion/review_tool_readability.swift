import AppKit
@preconcurrency import AVFoundation
import Foundation

enum ReadabilityFailure:Error {case scope,source,frame}
func review()async throws {
    let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard CommandLine.arguments.count == 3,let id = UUID(uuidString:CommandLine.arguments[1]),id.uuidString == CommandLine.arguments[1],
        CommandLine.arguments[2].hasPrefix("readability-"),UUID(uuidString:String(CommandLine.arguments[2].dropFirst(12))) != nil else {throw ReadabilityFailure.scope}
    let root = repo.appendingPathComponent(".build/traverse-release/"+id.uuidString),output = root.appendingPathComponent("evidence/"+CommandLine.arguments[2])
    guard root.resolvingSymlinksInPath() == root,output.resolvingSymlinksInPath() == output,
        let marker = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("reservation.json")))as?[String:Any],
        marker["action"]as?String == "traverse-properties-storage" else {throw ReadabilityFailure.scope}
    var modes:[[String:Any]] = [],all = true
    for mode in ["full","reduced","off"] {
        let movie = root.appendingPathComponent("evidence/properties-storage-"+mode+".mov")
        guard movie.resolvingSymlinksInPath() == movie,let size = try movie.resourceValues(forKeys:[.fileSizeKey]).fileSize,size>0,size<=1<<20,
            let receipt = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("evidence/properties-storage-"+mode+".json")))as?[String:Any],
            let began = receipt["actionUptimeSeconds"]as?Double,let frames = receipt["frames"]as?[[String:Any]],let first = frames.first?["receivedUptimeSeconds"]as?Double else {throw ReadabilityFailure.source}
        let asset = AVURLAsset(url:movie),duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration>0.8,duration<3 else {throw ReadabilityFailure.frame}
        let generator = AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        func ink(_ image:CGImage)throws->Int {
            guard image.width == 960,image.height == 640 else {throw ReadabilityFailure.frame}
            let pixels = NSBitmapImageRep(cgImage:image)
            var count = 0
            for y in 330..<370 {for x in 20..<180 {
                guard let color = pixels.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else {throw ReadabilityFailure.frame}
                if max(color.redComponent,color.greenComponent,color.blueComponent)>=0.65 {count += 1}
            }}
            return count
        }
        let settled = try await generator.image(at:CMTime(seconds:min(duration-0.03,began-first+0.82),preferredTimescale:60000))
        let reference = try ink(settled.image)
        guard reference>=20 else {throw ReadabilityFailure.frame}
        var samples:[[String:Any]] = [],minimum = 1.0
        for offset in stride(from:15,through:300,by:15) {
            let time = began-first+Double(offset)/1000
            guard time>=0,time<duration else {throw ReadabilityFailure.frame}
            let frame = try await generator.image(at:CMTime(seconds:time,preferredTimescale:60000))
            let count = try ink(frame.image),fraction = Double(count)/Double(reference);minimum = min(minimum,fraction)
            samples.append(["requestedOffsetMilliseconds":offset,"actualMovieSeconds":CMTimeGetSeconds(frame.actualTime),"ink":count,"settledFraction":fraction])
        }
        let passed = minimum>=0.5;all = all&&passed
        modes.append(["mode":mode,"passed":passed,"settledInk":reference,"minimumFraction":minimum,"samples":samples])
    }
    try JSONSerialization.data(withJSONObject:["passed":all,"modes":modes,"generatedOnly":true,"fixedRect":[20,330,160,40],"newCapture":false],options:[.prettyPrinted,.sortedKeys])
        .write(to:output.appendingPathComponent("result.json"),options:.withoutOverwriting)
}
do {try await review()}catch {fputs("Owned tool readability review refused: \(error)\n",stderr);exit(1)}
