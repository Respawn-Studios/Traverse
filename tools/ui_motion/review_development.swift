// Decode every real frame around generated native actions; never synthesizes frames.
import AppKit
@preconcurrency import AVFoundation
import Foundation
import CoreVideo

@main struct DevelopmentMotionReview {
    enum Failure: Error { case scope, media, pixels, geometry }
    @MainActor static func main() async {
        var checkpoint="scope"
        do {
            let args=CommandLine.arguments
            let suffix=args.firstIndex(of:"--review-id").flatMap{args.indices.contains($0+1) ? args[$0+1] : nil} ?? "timing"
            guard !suffix.isEmpty,suffix.utf8.count<=24,suffix.utf8.allSatisfy({(97...122).contains($0)||(48...57).contains($0)||$0==45})else{throw Failure.scope}
            guard args.count >= 2, let id=UUID(uuidString:args[1]),id.uuidString==args[1] else { throw Failure.scope }
            let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let developmentRoot=repo.appendingPathComponent(".build/traverse-development/"+id.uuidString)
            let releaseRoot=repo.appendingPathComponent(".build/traverse-release/"+id.uuidString)
            let developmentExists=FileManager.default.fileExists(atPath:developmentRoot.path)
            let releaseExists=FileManager.default.fileExists(atPath:releaseRoot.path)
            guard developmentExists != releaseExists else {throw Failure.scope}
            let root=developmentExists ? developmentRoot : releaseRoot
            let reports = [
                "motion-audit":"native.json", "sftp-native-folder-download":"native-folder-download.json",
                "sftp-folder-preview":"native-folder-download.json", "data-classification-native":"native-data-classification.json",
                "sftp-native-auth-transfer":"native-auth-transfer.json", "exclusive-upload-preview":"native-upload-preview.json",
                "folder-upload-preview":"native-folder-upload-preview.json", "remote-item-properties":"native-remote-properties.json",
                "native-directory-recovery":"native-directory-recovery.json", "native-connection-fields":"native-connection-fields.json",
                "purpose-journey-native":"native-purpose-journey.json", "smb-directory-recovery-native":"native-smb-open-recovery.json",
                "smb-selected-download-live-native":"native-smb-download.json",
                "routed-folder-upload-native":"native-routed-upload.json","plain-tar-native":"native-tar-archive.json",
                "native-zip-rename-copy":"native-zip-rename-copy.json", "native-drive-benchmark":"native-drive-benchmark.json",
                "smb-folder-download-native":"native-smb-folder.json", "native-drive-storage-status":"native-storage-status.json",
                "inline-archive-native":"native-inline-archive-motion.json", "tar-preview-native":"native-tar-preview.json",
                "selection-group-native":"native-selection-group.json",
                "settings-sidebar-v1":"native-settings-sidebar.json",
                "help-form-motion-v1":"native-help-motion.json",
                "native-analysis-persistence":"persistence-reopen-result.json",
                "native-sidebar-layout":"sidebar-layout-result.json",
                "native-sftp-download-batch":"native-download-batch.json",
                "smb-selected-download-group-native":"native-smb-download.json",
                "smb-selected-download-ordinary-native":"native-smb-download.json",
                "native-sftp-drop-upload":"native-sftp-drop-upload.json",
                "native-editor-preferences":"native-editor-preferences.json",
                "traverse-command-finder":"result.json",
                "traverse-native-help-diagnostics":"result.json"
            ]
            guard root.resolvingSymlinksInPath().path==root.path,
                let marker=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("reservation.json")))as?[String:Any],
                let captureAction=marker["action"]as?String, let report=reports[captureAction],
                developmentExists || ["traverse-command-finder", "traverse-native-help-diagnostics"].contains(captureAction),
                let native=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent(["traverse-command-finder", "traverse-native-help-diagnostics"].contains(captureAction) ? report : "evidence/"+report)))as?[String:Any] else { throw Failure.scope }
            var clips=native["clips"]as?[[String:Any]] ?? []
            if native["clips"] == nil {
                if captureAction == "traverse-native-help-diagnostics" {
                    guard native["realOSGrants"]as?Int == 0, native["networkRequests"]as?Int == 0,
                          native["actualRecoveryOpensRecordedOperationLogs"]as?Bool == true else { throw Failure.scope }
                    clips = ["help-release", "help-logs", "help-support", "help-about"].map { ["label": $0] }
                } else if captureAction == "traverse-command-finder" {
                    // Only the new diagnostic-size editor clip. Older command
                    // clips use a fixed-size capture and keep their own review.
                    clips = [["label": "editor-command-full"]]
                } else if captureAction == "native-drive-benchmark", (native["motionFrames"] as? Int ?? 0) > 0 {
                    clips = [["label": "drive-benchmark-run"]]
                } else if captureAction == "native-editor-preferences" {
                    let comparisonLabels = ["editor-comparison-stack", "editor-comparison-pair"]
                    clips = comparisonLabels.contains { FileManager.default.fileExists(atPath: root.appendingPathComponent("evidence/\($0).mov").path) }
                        ? comparisonLabels.map { ["label": $0] } : []
                    if FileManager.default.fileExists(atPath: root.appendingPathComponent("evidence/editor-open-search-entrance.mov").path) {
                        clips.append(["label": "editor-open-search-entrance"])
                    }
                    guard !clips.isEmpty else { throw Failure.scope }
                } else {
                    guard captureAction == "native-sftp-download-batch", native["motionAccepted"]as?Bool == true else { throw Failure.scope }
                    clips = [["label": "download-batch-results"]]
                }
            }
            let includesBenchmarkNavigation = captureAction == "motion-audit"
                && native["surface"] as? String == "tools"
                && (native["additionalChecks"] as? [String: Any])?["deviceRootBenchmarkNavigation"] as? Bool == true
            guard clips.count <= (includesBenchmarkNavigation ? 13 : 12) else { throw Failure.scope }
            let forensic = args.contains("--forensic-settings") || args.contains("--forensic-analysis") || args.contains("--forensic-help")
            guard native["passed"]as?Bool == true || (forensic && ["settings-sidebar-v1", "native-analysis-persistence", "help-form-motion-v1"].contains(captureAction)) else { throw Failure.scope }
            if captureAction == "smb-selected-download-ordinary-native" {
                let labels = clips.compactMap { $0["label"] as? String }
                guard native["stage"]as?String == "finished", native["keychainCalls"]as?Int == 0,
                      labels.count == clips.count,
                      labels == ["smb-move-destination"]
                        || labels == ["smb-move-destination", "smb-copy-destination"] else { throw Failure.scope }
            }
            if forensic {
                guard (args.contains("--forensic-settings") && captureAction == "settings-sidebar-v1"
                    || args.contains("--forensic-analysis") && captureAction == "native-analysis-persistence"
                    || args.contains("--forensic-help") && captureAction == "help-form-motion-v1"),
                    native["passed"]as?Bool == false else { throw Failure.scope }
                // Recover only declared clip references after a failed
                // geometry gate. Frames and timing still come from the actual
                // retained movies/capture metadata; no UI or frame is invented.
                let labels: [String]
                switch captureAction {
                case "settings-sidebar-v1": labels = ["settings-keyboard", "settings-appearance"]
                case "help-form-motion-v1": labels = ["help-invitation", "help-support", "help-public-updates"]
                default: labels = ["analysis-refresh"]
                }
                for label in labels where !clips.contains(where: { $0["label"]as?String == label }) {
                    let capture = root.appendingPathComponent("evidence/\(label).capture.json")
                    let movie = root.appendingPathComponent("evidence/\(label).mov")
                    if FileManager.default.fileExists(atPath: capture.path), FileManager.default.fileExists(atPath: movie.path) {
                        clips.append(["label": label, "forensicClipReference": true])
                    }
                }
            }
            var results:[[String:Any]]=[]
            for clip in clips {
                guard let label=clip["label"]as?String,label.utf8.allSatisfy({(97...122).contains($0)||(48...57).contains($0)||$0==45})else{throw Failure.scope}
                let metadataName: String
                if ["settings-sidebar-v1", "native-sidebar-layout", "help-form-motion-v1", "native-analysis-persistence", "native-sftp-download-batch", "smb-selected-download-group-native", "native-sftp-drop-upload", "native-drive-benchmark", "native-editor-preferences", "remote-item-properties"].contains(captureAction) {
                    metadataName = label + ".capture.json"
                } else if captureAction == "smb-folder-download-native" {
                    metadataName = "smb-folder-motion.json"
                } else {
                    metadataName = label + (["smb-selected-download-live-native", "smb-selected-download-ordinary-native"].contains(captureAction) ? "-motion" : "") + ".json"
                }
                guard let metadata=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("evidence/"+metadataName)))as?[String:Any],
                      let recorded=metadata["frames"]as?[[String:Double]],let first=recorded.first,
                      let firstPTS=first["presentationSeconds"],let action=metadata["actionUptimeSeconds"]as?Double,
                      recorded.count<=180 else {throw Failure.scope}
                if captureAction == "traverse-native-help-diagnostics" {
                    guard metadata["diagnosticSampling"]as?Bool == true,
                          metadata["requestedFPS"]as?Int == 120, metadata["writerCompleted"]as?Bool == true,
                          metadata["streamStopped"]as?Bool == true else { throw Failure.geometry }
                }
                let geometryRequired=native["surface"]as?String == "filters" || metadata["captureGeometry"] != nil
                var geometryVerified=false
                if geometryRequired {
                    guard let width=metadata["width"]as?Int,let height=metadata["height"]as?Int,
                          let declared=metadata["captureGeometry"]as?[String:Double],
                          let sourceWidth=declared["appKitWidth"],let sourceHeight=declared["appKitHeight"],
                          sourceWidth>0,sourceHeight>0 else {throw Failure.geometry}
                    // Diagnostic sampling is shared by ordinary archive/editor
                    // flows too; its bounded raster is declared by the recorder.
                    let scaled=metadata["diagnosticSampling"]as?Bool == true
                        || ["native-sftp-download-batch", "traverse-native-help-diagnostics"].contains(captureAction)
                    let scale=scaled ? min(1,1152/sourceWidth,800/sourceHeight) : 1
                    guard abs((sourceWidth*scale).rounded(.down)-Double(width))<=2,
                          abs((sourceHeight*scale).rounded(.down)-Double(height))<=2,
                          (forensic || recorded.allSatisfy({ frame in
                            guard let w=frame["contentWidth"],let h=frame["contentHeight"],let x=frame["contentX"],let y=frame["contentY"]else{return false}
                            return abs(w-Double(width))<=2 && abs(h-Double(height))<=2 && abs(x)<=2 && abs(y)<=2
                          })),native["surface"]as?String != "filters" || clip["fieldOwnerVerified"]as?Bool == true else{throw Failure.geometry}
                    geometryVerified=recorded.allSatisfy { frame in
                        guard let w=frame["contentWidth"],let h=frame["contentHeight"],let x=frame["contentX"],let y=frame["contentY"]else{return false}
                        return abs(w-Double(width))<=2 && abs(h-Double(height))<=2 && abs(x)<=2 && abs(y)<=2
                    }
                }
                let url=root.appendingPathComponent("evidence/\(label).mov")
                let size=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
                guard size.isRegularFile==true,size.isSymbolicLink != true,(size.fileSize ?? 0)<=4<<20 else {throw Failure.scope}
                checkpoint="open \(label)"
                let asset=AVURLAsset(url:url)
                guard let track=try await asset.loadTracks(withMediaType:.video).first else {throw Failure.media}
                let reader=try AVAssetReader(asset:asset)
                let output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
                guard reader.canAdd(output)else{throw Failure.media}
                let provider=reader.outputProvider(for:output)
                try reader.start()
                let region=(clip["fieldRegion"]as?[String:Double]).map{CGRect(x:$0["x"] ?? 0,y:$0["y"] ?? 0,width:$0["width"] ?? 0,height:$0["height"] ?? 0)}
                let actionOffset=action-firstPTS
                var values:[[String:Any]]=[];var pictures:[(Double,CGImage)]=[];var fieldPictures:[(Double,CGImage)]=[]
                // Evidence only: do not add fields to revision6 metrics or
                // retain full-window arrays. One actual delivered frame can
                // satisfy several nominal targets when delivery skips ahead.
                let driveSelectionDetail = captureAction == "motion-audit" && label == "tool-drive-selection"
                let folderSizeDetail = captureAction == "remote-item-properties" && label.hasPrefix("remote-folder-size-")
                let detailEnabled=folderSizeDetail || driveSelectionDetail || ["inline-archive-native","plain-tar-native","native-zip-rename-copy","tar-preview-native","selection-group-native","settings-sidebar-v1","native-sidebar-layout","help-form-motion-v1","traverse-native-help-diagnostics","native-analysis-persistence","native-sftp-drop-upload","native-editor-preferences","smb-selected-download-ordinary-native"].contains(captureAction)
                let detailTargets:[Double]=folderSizeDetail ? [0.280,0.360,0.450,0.600] : driveSelectionDetail ? [0.008,0.020,0.035,0.260,0.500,0.540,0.650] : ["settings-sidebar-v1", "native-sidebar-layout", "help-form-motion-v1","traverse-native-help-diagnostics","native-analysis-persistence"].contains(captureAction)
                    ? [0.008,0.016,0.035,0.070,0.140,0.260]
                    : detailEnabled ? [0.035,0.070,0.140,0.260]:[]
                let maximumDetailFrames = driveSelectionDetail ? 7 : ["settings-sidebar-v1", "native-sidebar-layout", "help-form-motion-v1","traverse-native-help-diagnostics","native-analysis-persistence"].contains(captureAction) ? 6 : 4
                var nextDetail=0,detailFrames=[[String:Any]]()
                checkpoint="decode \(label)"
                var movieStart:Double?;var decoded=0;var visualSamples:[[Double]]=[];var settledImage:CGImage?
                while let ready=try await provider.next() {
                    try ready.withUnsafeSampleBuffer { sample in
                    try autoreleasepool {
                        guard decoded<180,let buffer=CMSampleBufferGetImageBuffer(sample)else{throw Failure.media}
                        let pts=CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));if movieStart==nil{movieStart=pts}
                        let relative=pts-(movieStart ?? 0)-actionOffset;decoded+=1
                        var dueTargets=[Double]()
                        while nextDetail<detailTargets.count,relative>=detailTargets[nextDetail]{dueTargets.append(detailTargets[nextDetail]);nextDetail+=1}
                        CVPixelBufferLockBaseAddress(buffer,.readOnly);defer{CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
                        let width=CVPixelBufferGetWidth(buffer),height=CVPixelBufferGetHeight(buffer),stride=CVPixelBufferGetBytesPerRow(buffer)
                        guard width <= (captureAction != "motion-audit" ? 1280 : 1152),height<=800,width*height<=1152*800,
                            let base=CVPixelBufferGetBaseAddress(buffer),let context=CGContext(data:base,width:width,height:height,bitsPerComponent:8,bytesPerRow:stride,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue),context.makeImage() != nil else{throw Failure.pixels}
                        let retainedImage: CGImage?
                        if ((relative >= -0.025 && relative <= 0.30) || decoded == recorded.count || !dueTargets.isEmpty),
                           let bytes=CVPixelBufferGetBaseAddress(buffer),
                           let data=CGDataProvider(data:Data(bytes:bytes,count:stride*height) as CFData) {
                            retainedImage=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:stride,
                                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue),
                                provider:data,decode:nil,shouldInterpolate:false,intent:.defaultIntent)
                        } else {retainedImage=nil}
                        if !dueTargets.isEmpty {
                            guard let retainedImage,detailFrames.count<maximumDetailFrames,recorded.indices.contains(decoded-1),
                                  let recordedPTS=recorded[decoded-1]["presentationSeconds"],
                                  let png=NSBitmapImageRep(cgImage:retainedImage).representation(using:.png,properties:[:])else{throw Failure.pixels}
                            let name=String(format:"%@-detail-%@-frame-%04d.png",label,suffix,decoded-1)
                            try png.write(to:root.appendingPathComponent("evidence/"+name),options:.withoutOverwriting)
                            var detail:[String:Any]=["image":name,"frameIndexZeroBased":decoded-1,
                                "actionSeconds":relative,"movieSeconds":pts-(movieStart ?? 0),
                                "decodedPresentationSeconds":pts,"nominalTargetSeconds":dueTargets,
                                "width":width,"height":height,"selection":"first-delivered-frame-at-or-after-target"]
                            detail["recordedPresentationSeconds"]=recordedPTS
                            detailFrames.append(detail)
                        }
                        if decoded == recorded.count {settledImage=retainedImage}
                        var row:[String:Any]=["actionSeconds":relative,"movieSeconds":pts-(movieStart ?? 0)]
                        if let region {
                            let crop=region.insetBy(dx:3,dy:3).integral.intersection(CGRect(x:0,y:0,width:CGFloat(width),height:CGFloat(height)))
                            guard crop.width>1,crop.height>1 else{throw Failure.pixels}
                            let ptr=base.assumingMemoryBound(to:UInt8.self);var sum=0.0,black=0,count=0
                            for y in Int(crop.minY)..<Int(crop.maxY){for x in Int(crop.minX)..<Int(crop.maxX){let i=y*stride+x*4;let b=Double(ptr[i]),g=Double(ptr[i+1]),r=Double(ptr[i+2]);sum+=(0.2126*r+0.7152*g+0.0722*b)/255;if max(r,max(g,b))<48{black+=1};count+=1}}
                            row["fieldMeanLuminance"]=sum/Double(count);row["fieldBlackFraction"]=Double(black)/Double(count)
                            if relative >= -0.025 && relative<=0.30,let part=retainedImage?.cropping(to:region.integral){fieldPictures.append((relative,try thumbnail(part,width:480,height:58)))}
                        }
                        var grid:[Double]=[];let bytes=base.assumingMemoryBound(to:UInt8.self);var sy=60
                        while sy<height-20{var sx=20;while sx<width-20{let i=sy*stride+sx*4;grid.append((0.2126*Double(bytes[i+2])+0.7152*Double(bytes[i+1])+0.0722*Double(bytes[i]))/255);sx+=8};sy+=8}
                        visualSamples.append(grid)
                        values.append(row)
                        if relative >= -0.025 && relative<=0.25 {if let retainedImage{pictures.append((relative,try thumbnail(retainedImage,width:240,height:181)))}}
                    }
                    }
                }
                checkpoint="finished \(label) decoded=\(decoded) expected=\(recorded.count) status=\(reader.status.rawValue)"
                guard reader.status == .completed,decoded==recorded.count else{throw Failure.media}
                if detailEnabled {
                    let detail:[String:Any]=["clip":label,"reviewID":suffix,"captureAction":captureAction,
                        "sourceMovie":label+".mov","sourceMetadata":metadataName,
                        "frameIndexConvention":"zero-based-delivered-decode-order",
                        "targetActionSeconds":detailTargets,"frames":detailFrames,
                        "unfulfilledTargetSeconds":Array(detailTargets.dropFirst(nextDetail)),
                        "synthesizedFrames":0,"interpolatedFrames":0,"metricsAlgorithmRevision":7]
                    try JSONSerialization.data(withJSONObject:detail,options:[.prettyPrinted,.sortedKeys])
                        .write(to:root.appendingPathComponent("evidence/\(label)-detail-\(suffix).json"),options:.withoutOverwriting)
                }
                let finalPixels=visualSamples.last ?? []
                let distances=visualSamples.map{pixels in zip(pixels,finalPixels).reduce(0.0){$0+abs($1.0-$1.1)}/Double(max(1,pixels.count))}
                let startingDistance=distances.first ?? 0
                let progress=distances.map{startingDistance>0.001 ? max(0,min(1,1-$0/startingDistance)) : 1}
                var largestStep=0.0
                for index in values.indices{values[index]["settledProgress"]=progress[index];if index>0,(values[index]["actionSeconds"]as?Double ?? -1)>=0{largestStep=max(largestStep,progress[index]-progress[index-1])}}
                let timed=values.filter{($0["actionSeconds"]as?Double ?? -1)>=0 && ($0["actionSeconds"]as?Double ?? 1)<=0.35}
                let means=timed.compactMap{$0["fieldMeanLuminance"]as?Double},blacks=timed.compactMap{$0["fieldBlackFraction"]as?Double}
                let settled=values.suffix(3).compactMap{$0["fieldMeanLuminance"]as?Double};let finalMean=settled.reduce(0,+)/Double(max(1,settled.count))
                let settledBlack=values.suffix(3).compactMap{$0["fieldBlackFraction"]as?Double};let finalBlack=settledBlack.reduce(0,+)/Double(max(1,settledBlack.count))
                // An observed late-created field has no field pixels in the
                // pre-action window. Keep those raw samples/images, but do not
                // label its formerly empty location a field flicker. Existing
                // captures without this observation keep their original gate.
                let fieldBlackGateApplicable=region != nil && clip["fieldPresentBeforeAction"]as?Bool != false
                let rawFieldDarkDip=region != nil && (means.min() ?? 1)<finalMean*0.55 && (blacks.max() ?? 0)-finalBlack>0.25
                let spike=fieldBlackGateApplicable && rawFieldDarkDip
                checkpoint="sheets \(label) full=\(pictures.count) field=\(fieldPictures.count)"
                try sheet(pictures,columns:4,cell:NSSize(width:240,height:205),to:root.appendingPathComponent("evidence/\(label)-dense-\(suffix).png"))
                guard let settledImage,let settledPNG=NSBitmapImageRep(cgImage:settledImage).representation(using:.png,properties:[:])else{throw Failure.pixels}
                try settledPNG.write(to:root.appendingPathComponent("evidence/\(label)-settled-\(suffix).png"),options:.withoutOverwriting)
                if !fieldPictures.isEmpty{try sheet(fieldPictures,columns:2,cell:NSSize(width:480,height:58),to:root.appendingPathComponent("evidence/\(label)-field-\(suffix).png"))}
                let intervals=zip(recorded.dropFirst(),recorded).map{($0["presentationSeconds"] ?? 0)-($1["presentationSeconds"] ?? 0)}.sorted()
                // A scroll/accordion/result reveal is not a whole-page fade.
                // Keep its measurements, but apply the frozen page-step gate
                // to actual page/device transitions with a proven identity
                // change. Keep scrolling, accordions and no-op refresh out.
                let mode=clip["mode"]as?String ?? native["mode"]as?String
                let pageStepApplicable=mode != "off" &&
                    ((captureAction == "remote-item-properties" && label.hasPrefix("remote-") && !label.hasPrefix("remote-folder-size-")) || captureAction == "settings-sidebar-v1" || captureAction == "traverse-native-help-diagnostics" || (native["surface"]as?String == "settings" && label != "settings-search-scroll") || native["surface"]as?String == "help" ||
                     (native["surface"]as?String == "tools" &&
                      (label.hasPrefix("tool-trust-") || (label == "tool-drive-selection" && (native["additionalChecks"]as?[String:Any])?["actualDriveSelectionChanged"]as?Bool == true))))
                var summary:[String:Any]=["clip":label,"decodedFrames":decoded,"actionOffsetSeconds":actionOffset,"decodedActionFrames":pictures.count,"blackSpike":spike,"largestContentProgressStep":largestStep,"startingContentDistance":startingDistance,"pageStepApplicable":pageStepApplicable,"captureGeometryVerified":geometryVerified,"perFrame":values]
                if let visibility=clip["fieldVisibility"]{summary["fieldVisibility"]=visibility}
                summary["fieldBlackGateApplicable"]=fieldBlackGateApplicable
                summary["rawFieldDarkDip"]=rawFieldDarkDip
                if clip["fieldPresentBeforeAction"]as?Bool == false {
                    summary["fieldBlackAssessment"]="Visual review only: field was absent before action"
                }
                if !intervals.isEmpty{summary["medianFrameSeconds"]=intervals[intervals.count/2];summary["maximumFrameSeconds"]=intervals.last!}
                if region != nil{summary["settledFieldMean"]=finalMean;summary["minimumFieldMean"]=means.min() ?? 0;summary["maximumBlackFraction"]=blacks.max() ?? 0;summary["settledBlackFraction"]=finalBlack}
                results.append(summary)
            }
            let abrupt=results.contains{$0["pageStepApplicable"]as?Bool==true && ($0["largestContentProgressStep"]as?Double ?? 0)>0.30}
            let result:[String:Any]=["passed":!forensic && !results.contains{$0["blackSpike"]as?Bool==true},"smoothPageStepsPassed":!forensic && !abrupt,"forensicOnly":forensic,"nativeQualificationPassed":native["passed"]as?Bool==true,"allDeliveredFramesDecoded":true,"clips":results,"synthesizedFrames":0,"veryDarkRGBThreshold":48,"algorithmRevision":7]
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("evidence/dense-review-\(suffix).json"),options:.withoutOverwriting)
            let compact=results.map{value in value.filter{$0.key != "perFrame"}}
            print(String(decoding:try JSONSerialization.data(withJSONObject:compact,options:[.sortedKeys]),as:UTF8.self))
            if args.contains("--assert-no-black"),result["passed"]as?Bool != true{exit(2)}
            if args.contains("--assert-smooth-pages"),abrupt{exit(3)}
        } catch {FileHandle.standardError.write(Data("Generated motion review failed at \(checkpoint): \((error as? Failure).map { String(describing:$0) } ?? "media error")\n".utf8));exit(1)}
    }
    // Keep full-resolution metrics and the final source frame, but retain only
    // contact-sheet-sized evidence between frames. Crops must also be copied:
    // a small CGImage crop can otherwise retain its entire large source bitmap.
    static func thumbnail(_ image:CGImage,width:Int,height:Int)throws->CGImage {
        let scale=min(1,min(Double(width)/Double(image.width),Double(height)/Double(image.height)))
        let w=max(1,Int(Double(image.width)*scale)),h=max(1,Int(Double(image.height)*scale))
        guard let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{throw Failure.pixels}
        context.interpolationQuality = .high;context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
        guard let result=context.makeImage()else{throw Failure.pixels};return result
    }
    @MainActor static func sheet(_ pictures:[(Double,CGImage)],columns:Int,cell:NSSize,to url:URL)throws{
        guard !pictures.isEmpty,pictures.count<=60 else{throw Failure.pixels}
        let rows=(pictures.count+columns-1)/columns,width=Int(cell.width)*columns,height=Int(cell.height)*rows
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let context=NSGraphicsContext(bitmapImageRep:bitmap)else{throw Failure.pixels}
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        NSColor(white:0.13,alpha:1).setFill();NSRect(x:0,y:0,width:CGFloat(width),height:CGFloat(height)).fill()
        for(i,picture)in pictures.enumerated(){let(time,image)=picture;let target=NSRect(x:CGFloat(i%columns)*cell.width,y:CGFloat(rows-1-i/columns)*cell.height,width:cell.width,height:cell.height);let scale=min((target.width-8)/CGFloat(image.width),(target.height-19)/CGFloat(image.height));let frame=NSRect(x:target.midX-CGFloat(image.width)*scale/2,y:target.minY+16,width:CGFloat(image.width)*scale,height:CGFloat(image.height)*scale);NSImage(cgImage:image,size:NSSize(width:CGFloat(image.width),height:CGFloat(image.height))).draw(in:frame);NSString(string:String(format:"action %+.4f s",time)).draw(at:NSPoint(x:target.minX+5,y:target.minY+2),withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:10,weight:.regular),.foregroundColor:NSColor.white])}
        NSGraphicsContext.restoreGraphicsState()
        guard let data=bitmap.representation(using:.png,properties:[:])else{throw Failure.pixels};try data.write(to:url,options:.withoutOverwriting)
    }
}
