#if DEBUG
import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Development-only, current-process recording of one admitted window, or its
/// crop over one other admitted window for closing motion. No whole-display or
/// application-wide capture, audio, permission request, or ordinary startup hook.
/// Native callbacks, encoding and output files stay on one bounded owner queue.
final class NativeMotionRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Frame: Codable, Sendable {
        let presentationSeconds: Double
        let receivedUptimeSeconds: Double
        let contentWidth: Double?
        let contentHeight: Double?
        let contentX: Double?
        let contentY: Double?
        let contentScale: Double?
        let scaleFactor: Double?
    }
    struct Report: Codable, Sendable {
        let source: String
        let width: Int
        let height: Int
        let requestedFPS: Int
        let maximumFrames: Int
        let diagnosticSampling: Bool
        let queueDepth: Int
        let actionUptimeSeconds: Double
        let frames: [Frame]
        let skippedInactiveFrames: Int
        let droppedEncoderFrames: Int
        let streamStopped: Bool
        let writerCompleted: Bool
        let videoBytes: Int64
        let failureCode: Int?
        let captureGeometry: [String: Double]
    }
    enum Failure: String, Error { case scope, unavailable, recording }
    private let queue = DispatchQueue(label: "MacExplorer.GeneratedMotionRecorder", qos: .utility)
    private var capture: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var frames: [Frame] = []
    private var skipped = 0, dropped = 0
    private var failureCode: Int?
    private var captureGeometry: [String: Double] = [:]
    private var sourceDescription = "ScreenCaptureKit.currentProcess/single-window"
    private var first: CheckedContinuation<Void, Error>?
    private var writerStarted = false
    private var output: URL?
    private let recordingBackground = CGColor(gray: 0.12, alpha: 1)
    /// SCShareableContent is an immutable native observation, transferred once
    /// from its callback into our queue; the SDK has no Sendable annotation.
    private struct ContentObservation: @unchecked Sendable { let content: SCShareableContent? }
    struct Sampling: Sendable {
        let width: Int, height: Int, fps: Int, maximumFrames: Int
        let preRollMilliseconds: Int, afterMilliseconds: Int
        let diagnostic: Bool
        static let standard = Sampling(width: 960, height: 640, fps: 60, maximumFrames: 90,
            preRollMilliseconds: 120, afterMilliseconds: 900, diagnostic: false)
        @MainActor static func diagnostic(for window: NSWindow, preRollMilliseconds: Int = 60) -> Sampling {
            let scale = min(1, 1152 / window.frame.width, 800 / window.frame.height)
            return Sampling(width: max(1, Int((window.frame.width * scale).rounded(.down))), height: max(1, Int((window.frame.height * scale).rounded(.down))),
                fps: 120, maximumFrames: 180, preRollMilliseconds: preRollMilliseconds, afterMilliseconds: 650, diagnostic: true)
        }
    }
    private var sampling = Sampling.standard

    @MainActor static func replayToolWindowEntrance(_ window: NSWindow) {
        let motion = ToolContentMotion.prepareWindowEntrance(window, wasVisible: false)
        ToolContentMotion.revealWindow(window, motion: motion)
    }

    @MainActor static func record(window: NSWindow, over background: NSWindow? = nil, root: URL, label: String,
                                  sampling: Sampling = .standard, includingChildWindows: Bool = true,
                                  fixedWindow: Bool = false,
                                  action: @MainActor () throws -> Void) async throws -> Report {
        try validateScope(window: window, root: root, label: label)
        if let background {
            try validateScope(window: background, root: root, label: label)
            guard !fixedWindow, background !== window, background.frame.contains(window.frame) else { throw Failure.scope }
        }
        guard sampling.width > 0, sampling.width <= 1280, sampling.height > 0, sampling.height <= 800,
              sampling.width * sampling.height <= 1152 * 800,
              [60,120].contains(sampling.fps), sampling.maximumFrames <= 180,
              (60...300).contains(sampling.preRollMilliseconds) else { throw Failure.scope }
        let owner = NativeMotionRecorder(); owner.sampling = sampling
        let url = root.appendingPathComponent("evidence/\(label).mov")
        try await owner.start(window: CGWindowID(window.windowNumber), background: background.map { CGWindowID($0.windowNumber) }, expectedWidth: window.frame.width,
                              expectedHeight: window.frame.height, includingChildWindows: includingChildWindows,
                              fixedWindow: fixedWindow, output: url)
        do {
            try await owner.waitForFirstFrame()
            try await Task.sleep(for: .milliseconds(sampling.preRollMilliseconds))
            let began = CACurrentMediaTime(); try action()
            try await Task.sleep(for: .milliseconds(sampling.afterMilliseconds))
            let result = try await owner.finish(action: began)
            if sampling.diagnostic {
                let matches = result.frames.allSatisfy {
                    guard let width = $0.contentWidth, let height = $0.contentHeight,
                          let x = $0.contentX, let y = $0.contentY else { return false }
                    return abs(width - Double(sampling.width)) <= 2 && abs(height - Double(sampling.height)) <= 2 && abs(x) <= 2 && abs(y) <= 2
                }
                try JSONEncoder().encode(result).write(to: url.deletingPathExtension().appendingPathExtension("capture.json"), options: .withoutOverwriting)
                guard matches else { throw Failure.recording }
            }
            guard result.streamStopped, result.writerCompleted, result.failureCode == nil, result.frames.count >= 3 else { throw Failure.recording }
            return result
        } catch {
            _ = try? await owner.finish(action: CACurrentMediaTime())
            throw error
        }
    }
    @MainActor static func validateScope(window: NSWindow, root: URL, label: String) throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let arguments = Set(ProcessInfo.processInfo.arguments)
        guard root.path == ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              root.path.hasPrefix(repo.appendingPathComponent(".build").path + "/"),
              root.resolvingSymlinksInPath() == root,
              GeneratedSignedReviewAdmission.ownedDirectory(root),
              GeneratedSignedReviewAdmission.ownedDirectory(root.appendingPathComponent("evidence")),
              !label.isEmpty, label.utf8.count <= 48,
              label.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              window.isVisible, window.windowNumber > 0, window.title.contains("generated review") else {
            throw Failure.scope
        }
        let parent = root.deletingLastPathComponent()
        let isUUID = UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
        let development = isUUID && parent == repo.appendingPathComponent(".build/traverse-development")
        let release = isUUID && parent == repo.appendingPathComponent(".build/traverse-release")
        func fields(_ leaf: String) -> [String: Any]? {
            GeneratedSignedReviewAdmission.generatedFixtureFields(root.appendingPathComponent(leaf))
        }
        let reservation = development || release ? fields("reservation.json") : nil
        let reservedAction = reservation?["action"] as? String
        func releaseRole(_ flag: String, _ action: String) -> Bool {
            release && arguments.contains(flag) && reservedAction == action
        }
        let downloadBatchCase = arguments.contains("--check-sftp-download-ui")
            && arguments.contains("--batch-flow")
            && development
            && reservedAction == "native-sftp-download-batch"
            && window.title == "SFTP Download · generated review"
        let downloadCase = arguments.contains("--check-sftp-download-ui")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b12-download-qualification")
        let uploadCase = arguments.contains("--check-sftp-upload-ui")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b12-upload-integration")
        let patchCase = arguments.contains("--check-access-patch")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-patch-0.1.1")
        let accessCase = releaseRole("--check-onboarding-access", "traverse-access-onboarding-qualification")
        let commandCase = releaseRole("--check-command-finder", "traverse-command-finder")
        let profileCase = releaseRole("--check-profile-workspaces-ui", "traverse-profile-workspaces-ui")
        let queueCase = releaseRole("--check-queue-priority", "traverse-queue-priority")
        let searchCase = releaseRole("--check-search-progress", "traverse-search-progress")
        let largestCase = releaseRole("--check-largest-files-ui", "traverse-largest-files-ui")
        let archivePaneCase = releaseRole("--check-archive-pane-destination", "traverse-archive-pane-destination")
        let archiveSearchCase = releaseRole("--check-archive-search", "traverse-archive-search")
        let privateLabelsCase = releaseRole("--check-private-labels", "traverse-private-labels")
        let archiveDragCase = releaseRole("--check-archive-member-drag", "traverse-archive-member-drag")
        let archiveOrderCase = releaseRole("--check-archive-sorting", "traverse-archive-sorting")
        let browserTaskCase = releaseRole("--check-browser-tasks", "traverse-browser-tasks")
        let headerHoverCase = releaseRole("--check-header-hover", "traverse-header-hover")
        let propertiesStorageCase = releaseRole("--check-properties-storage", "traverse-properties-storage")
        let folderOpenerCase = releaseRole("--check-folder-opener", "traverse-folder-opener")
        let archiveBytesCase = releaseRole("--check-archive-byte-preview", "traverse-archive-bytes-ui")
        let helpCase = releaseRole("--check-help-diagnostics", "traverse-native-help-diagnostics")
        let testerCase = releaseRole("--check-tester-repairs", "traverse-tester-repair-qualification")
        let developmentCase = arguments.contains("--check-development-motion")
            && development
            && reservation?["packet"] as? String == "traverse-development-v1"
        let routedFolderCase = arguments.contains("--check-sftp-routed-upload")
            && arguments.contains("--folder-upload") && reservedAction == "routed-folder-upload-native"
            && development
        let captureTitleCase = arguments.contains("--check-sftp-folder-upload-preview")
            && arguments.contains("--profile-sheet") && arguments.contains("--record-title")
            && reservedAction == "routed-folder-upload-review-profile"
            && development
        let tarCase = arguments.contains("--check-tar-archive") && reservedAction == "plain-tar-native"
            && development
        let zipRenameCase = arguments.contains("--check-zip-rename-copy")
            && reservedAction == "native-zip-rename-copy" && label == "zip-copy-review"
            && ["ZIP rename · generated review", "ZIP removal · generated review", "ZIP Add · generated review", "ZIP new folder · generated review"].contains(window.title)
            && development
        let smbFolderCase = arguments.contains("--check-smb-folder-download")
            && reservedAction == "smb-folder-download-native" && window.title == "SMB folders · generated review"
            && development
        let smbGroupCase = arguments.contains("--check-smb-selected-download")
            && (reservedAction == "smb-selected-download-group-native" && label == "smb-group-download"
                || reservedAction == "smb-selected-download-group-native-preflight" && label == "smb-group-preflight")
            && window.title == "SMB selected files · generated review"
            && development
        let sftpActionCase = arguments.contains("--check-sftp-drop-upload")
            && reservedAction == "native-sftp-drop-upload"
            && (label == "sftp-action-history-clear" && window.title == "SFTP file actions · generated review"
                || label == "sftp-connection-status" && window.title == "SFTP group upload · generated review")
            && development
        let smbDestinationCase = arguments.contains("--check-smb-selected-download")
            && reservedAction == "smb-selected-download-ordinary-native"
            && (window.title == "SMB Move · generated review" && label == "smb-move-destination"
                || window.title == "SMB Copy · generated review" && label == "smb-copy-destination")
        let remotePropertiesCase = (arguments.contains("--check-remote-properties") && reservedAction == "remote-item-properties"
            || arguments.contains("--check-directory-recovery") && reservedAction == "native-directory-recovery"
            || arguments.contains("--check-smb-open-recovery") && reservedAction == "smb-directory-recovery-native"
            || arguments.contains("--check-smb-selected-download") && reservedAction == "smb-selected-download-live-native"
            || arguments.contains("--check-sftp-routed-upload") && arguments.contains("--folder-upload") && reservedAction == "routed-folder-upload-native"
            || arguments.contains("--check-connection-fields") && reservedAction == "native-connection-fields"
            || arguments.contains("--check-drive-benchmark-native") && reservedAction == "native-drive-benchmark"
                && ["drive-benchmark-run", "drive-benchmark-suite-comparison", "drive-benchmark-suite-comparison-reduced",
                    "drive-benchmark-suite-comparison-off", "drive-benchmark-comparison", "drive-benchmark-comparison-size",
                    "drive-benchmark-size-only", "drive-benchmark-appearance-only", "drive-benchmark-layout-off"].contains(label)
            || tarCase || zipRenameCase || smbGroupCase || sftpActionCase || smbDestinationCase)
            && development
        let folderDownloadCase = (arguments.contains("--check-sftp-folder-download") && reservedAction == "sftp-native-folder-download"
            || arguments.contains("--check-sftp-folder-review") && reservedAction == "sftp-folder-preview")
            && development
        let dataClassificationCase = arguments.contains("--check-data-classification")
            && reservedAction == "data-classification-native"
            && development
        let purposeJourneyCase = arguments.contains("--check-purpose-journey")
            && reservedAction == "purpose-journey-native"
            && development
            && ["Properties · generated review · purpose journey", "Storage Analysis · generated review · purpose journey"].contains(window.title)
        let folderUploadCase = arguments.contains("--check-sftp-folder-upload-preview")
            && (reservedAction == "folder-upload-preview" || captureTitleCase)
            && development
        let exclusiveUploadCase = arguments.contains("--check-sftp-auth-transfer")
            && arguments.contains("--record-exclusive-upload") && arguments.contains("--preview-only") && reservedAction == "exclusive-upload-preview"
            && development
        let driveStatusCase = arguments.contains("--check-drive-storage-status")
            && reservedAction == "native-drive-storage-status"
            && development
            && window.title == "Drive Details · generated review · storage status"
        let chartIntegrationCase = development && reservedAction == "native-storage-chart-integration"
            && arguments.contains("--check-chart-integration") && arguments.contains("--record-chart-integration")
            && window.title == "Storage Analysis · generated review · chart navigation"
            && ["analyzer-folders", "analyzer-drill", "analyzer-back"].contains(label)
        let inlineArchiveCase = arguments.contains("--check-inline-archive-motion")
            && reservedAction == "inline-archive-native"
            && development
            && window.title == "Archives · generated review · motion audit"
            && fields("inline-admission.json")?["phase"] as? String == "motion"
        let tarPreviewCase = arguments.contains("--check-tar-preview-native")
            && reservedAction == "tar-preview-native"
            && development
            && window.title == "TAR preview · generated review · motion audit"
        let renameMotion = development && arguments.contains("rename-motion")
            && fields("selection-group-admission-rename-motion.json")?["phase"] as? String == "rename-motion"
            && ["details", "list", "icons"].contains { mode in
                label == "selection-group-new-folder-\(mode)" || label == "selection-group-new-folder-return-\(mode)"
            }
        let selectionGroupCase = arguments.contains("--check-selection-group-native")
            && reservedAction == "selection-group-native"
            && development
            && window.title == "Grouping · generated review · motion audit"
            && (renameMotion || ["selection-group-draft", "selection-group-results", "selection-group-new-folder",
                "selection-group-new-folder-return"].contains(label))
        let settingsSidebarCase = arguments.contains("--check-settings-sidebar")
            && reservedAction == "settings-sidebar-v1"
            && development
            && window.title == "Settings · generated review · sidebar motion"
            && ["settings-keyboard", "settings-appearance"].contains(label)
            && fields("settings-admission.json")?["master"] as? String == "46F68181-FA2B-4308-8713-7D518F2FF08C"
        let recordedAnalysisCase = arguments.contains("--check-analysis-persistence")
            && arguments.contains("--record-analysis-persistence")
            && reservedAction == "native-analysis-persistence"
            && development
            && window.title == "Storage Analysis · generated review · retained analysis"
            && label == "analysis-refresh"
        let editorComparisonCase = arguments.contains("--verify-ui")
            && arguments.contains("--check-editor-preferences")
            && reservedAction == "native-editor-preferences"
            && development
            && ((window.title == "Compare Changes · generated review"
                 && ["editor-comparison-stack", "editor-comparison-pair"].contains(label))
                || (window.title == "Unified Diff · generated review" && label == "editor-unified-context"
                    && reservation?["editorComparisonOnly"] as? Bool == true)
                || (window.title == "Find in Open Editors · generated review" && label == "editor-open-search-entrance"))
        let helpMotionCase = arguments.contains("--check-help-motion")
            && reservedAction == "help-form-motion-v1"
            && development
            && window.title == "Help · generated review · private field motion"
            && ["help-invitation", "help-support", "help-public-updates"].contains(label)
            && fields("help-motion-admission.json")?["master"] as? String == "46F68181-FA2B-4308-8713-7D518F2FF08C"
        let folderDefaultCase: Bool = {
            guard arguments.contains("--verify-ui"),
                  arguments.contains("--check-folder-default-composition"),
                  Bundle.main.bundleIdentifier == "local.macexplorer.development",
                  reservedAction == "folder-default-app-composition",
                  development,
                  window.title == "Settings · generated review · folder default",
                  window.frame.width == 860, window.frame.height == 692,
                  ["default-owned-100-solid", "default-owned-100-glass", "default-owned-150-solid", "default-owned-150-glass"].contains(label)
            else { return false }
            let admission = fields("folder-default-composition-admission.json")
            return admission?["master"] as? String == "46F68181-FA2B-4308-8713-7D518F2FF08C"
                && admission?["fakeBackendOnly"] as? Bool == true
                && admission?["liveHandlerQueries"] as? Int == 0
                && admission?["liveAssociationSetters"] as? Int == 0
                && admission?["captureProfile"] as? String == "folder-default-static-dark-v1"
        }()
        let legacyFlags = ["--check-access-patch", "--check-smb-connect-standalone", "--check-smb-browser-ui",
                           "--check-motion-modes", "--check-sftp-trust-standalone", "--check-sftp-live-standalone",
                           "--check-sftp-download-ui"]
        let tallerTool = browserTaskCase || developmentCase || dataClassificationCase || purposeJourneyCase
            || exclusiveUploadCase || folderUploadCase || remotePropertiesCase || inlineArchiveCase
            || tarPreviewCase || selectionGroupCase || settingsSidebarCase || helpMotionCase || editorComparisonCase || chartIntegrationCase
        guard legacyFlags.contains(where: arguments.contains) || tallerTool || uploadCase || accessCase
            || commandCase || profileCase || queueCase || searchCase || largestCase || archivePaneCase
            || archiveSearchCase || privateLabelsCase || archiveDragCase || archiveOrderCase || headerHoverCase
            || propertiesStorageCase || folderOpenerCase || archiveBytesCase || helpCase || testerCase
            || folderDownloadCase || smbFolderCase || driveStatusCase || tarCase || folderDefaultCase
            || recordedAnalysisCase else { throw Failure.scope }

        let extendedWidth = downloadBatchCase || folderDownloadCase || routedFolderCase || captureTitleCase
            || tarCase || smbFolderCase
        let extendedHeight = tallerTool || folderDownloadCase || smbFolderCase || driveStatusCase
            || recordedAnalysisCase || tarCase
        let maximumWidth: CGFloat = extendedWidth ? 1280 : tallerTool ? 1152 : downloadCase ? 1024 : 960
        let maximumHeight: CGFloat = downloadBatchCase ? 800 : folderDefaultCase ? 692
            : extendedHeight ? 800 : patchCase || accessCase || helpCase ? 700 : 640
        guard window.frame.width <= maximumWidth, window.frame.height <= maximumHeight else { throw Failure.scope }
    }

    private func start(window id: CGWindowID, background: CGWindowID?, expectedWidth: Double, expectedHeight: Double,
                       includingChildWindows: Bool, fixedWindow: Bool, output: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                observeStart(window: id, background: background, expectedWidth: expectedWidth, expectedHeight: expectedHeight,
                    includingChildWindows: includingChildWindows, fixedWindow: fixedWindow, output: output,
                    attempt: 1, continuation: continuation)
            }
        }
    }
    // A newly ordered window can precede WindowServer's current-process list.
    // Retry only that exact ID/geometry, on this queue, at most fifty times;
    // errors remain terminal. Never enumerate another app or capture a whole display.
    private func observeStart(window id: CGWindowID, background: CGWindowID?, expectedWidth: Double, expectedHeight: Double,
                              includingChildWindows: Bool, fixedWindow: Bool, output: URL, attempt: Int,
                              continuation: CheckedContinuation<Void, Error>) {
        SCShareableContent.getCurrentProcessShareableContent { [self] content, error in
            let observation = ContentObservation(content: content)
            queue.async { [self] in
                let ownWindow = observation.content?.windows.first(where: { $0.windowID == id })
                let ownFilter = ownWindow.map { SCContentFilter(desktopIndependentWindow: $0) }
                let ownBackground = background.flatMap { id in observation.content?.windows.first(where: { $0.windowID == id }) }
                let backgroundReady = background == nil || (ownBackground?.owningApplication?.processID == getpid()
                    && ownWindow.map { ownBackground?.frame.contains($0.frame) == true } == true)
                let geometryReady = ownWindow.map { window in
                    window.frame.width > 0 && window.frame.height > 0 &&
                    (!sampling.diagnostic || (abs(window.frame.width - expectedWidth) <= 2 && abs(window.frame.height - expectedHeight) <= 2 &&
                        (!includingChildWindows || (abs((ownFilter?.contentRect.width ?? 0) - expectedWidth) <= 2
                            && abs((ownFilter?.contentRect.height ?? 0) - expectedHeight) <= 2))))
                } ?? false
                if error == nil, (!geometryReady || ownWindow == nil || !backgroundReady), attempt < 51 {
                    queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [self] in
                        observeStart(window: id, background: background, expectedWidth: expectedWidth, expectedHeight: expectedHeight,
                            includingChildWindows: includingChildWindows, fixedWindow: fixedWindow, output: output,
                            attempt: attempt + 1, continuation: continuation)
                    }
                    return
                }
                func coordinates(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }
                let readiness: [String:Any] = ["lookups": attempt,"exactWindowPresent": ownWindow != nil,"geometryMatches": geometryReady,
                    "ownerMatches": ownWindow?.owningApplication?.processID == getpid(),
                    "backgroundRequested": background != nil, "backgroundReady": backgroundReady,
                    "windowOnScreen": ownWindow?.isOnScreen == true,
                    "windowFrame": ownWindow.map { coordinates($0.frame) } ?? [],
                    "displayFrames": observation.content?.displays.map { coordinates($0.frame) } ?? [],
                    "nativeErrorCode": error.map { ($0 as NSError).code as Any } ?? NSNull()]
                do { try JSONSerialization.data(withJSONObject: readiness,options: [.prettyPrinted,.sortedKeys])
                    .write(to: output.deletingPathExtension().appendingPathExtension("window-ready.json"),options: .withoutOverwriting) }
                catch { continuation.resume(throwing: Failure.recording); return }
            do {
                guard error == nil, let window = observation.content?.windows.first(where: { $0.windowID == id }),
                      window.owningApplication?.processID == getpid(), !FileManager.default.fileExists(atPath: output.path) else { throw Failure.unavailable }
                let filter: SCContentFilter
                let crop: CGRect?
                if let background {
                    guard let under = observation.content?.windows.first(where: { $0.windowID == background }),
                          under.owningApplication?.processID == getpid(), under.frame.contains(window.frame),
                          let display = observation.content?.displays.first(where: { $0.frame.contains(window.frame) }) else { throw Failure.scope }
                    // Including these two exact current-process IDs excludes
                    // all other windows, the desktop and Dock. Only the closing
                    // window's original rectangle reaches the video encoder.
                    filter = SCContentFilter(display: display, including: [under, window])
                    filter.includeMenuBar = false
                    crop = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                    sourceDescription = "ScreenCaptureKit.currentProcess/two-window-closing-crop"
                } else if !includingChildWindows && !fixedWindow {
                    guard let display = observation.content?.displays.first(where: { $0.frame.contains(window.frame) }) else {
                        throw Failure.scope
                    }
                    // Desktop-independent capture grows to include a popover,
                    // rescaling the parent's pixels mid-clip. An exact ID list
                    // and parent-frame crop keep the same region throughout.
                    filter = SCContentFilter(display: display, including: [window])
                    filter.includeMenuBar = false
                    crop = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                    sourceDescription = "ScreenCaptureKit.currentProcess/single-window-fixed-crop"
                } else {
                    filter = SCContentFilter(desktopIndependentWindow: window)
                    crop = nil
                    if fixedWindow { sourceDescription = "ScreenCaptureKit.currentProcess/fixed-window" }
                }
                captureGeometry = ["appKitWidth": expectedWidth, "appKitHeight": expectedHeight,
                    "shareableWidth": window.frame.width, "shareableHeight": window.frame.height,
                    "filterWidth": filter.contentRect.width, "filterHeight": filter.contentRect.height,
                    "pointPixelScale": Double(filter.pointPixelScale)]
                if let crop {
                    captureGeometry["includedWindowCount"] = background == nil ? 1 : 2
                    captureGeometry["includingChildWindows"] = includingChildWindows ? 1 : 0
                    captureGeometry["cropX"] = crop.minX; captureGeometry["cropY"] = crop.minY
                    captureGeometry["cropWidth"] = crop.width; captureGeometry["cropHeight"] = crop.height
                }
                try JSONSerialization.data(withJSONObject: captureGeometry, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.deletingPathExtension().appendingPathExtension("geometry.json"), options: .withoutOverwriting)
                if sampling.diagnostic {
                    guard abs(window.frame.width - expectedWidth) <= 2, abs(window.frame.height - expectedHeight) <= 2,
                          crop != nil || (abs(filter.contentRect.width - expectedWidth) <= 2 && abs(filter.contentRect.height - expectedHeight) <= 2) else { throw Failure.unavailable }
                }
                let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: sampling.width, AVVideoHeightKey: sampling.height,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: sampling.diagnostic ? 3_000_000 : 1_200_000,
                        AVVideoMaxKeyFrameIntervalKey: 60, AVVideoAllowFrameReorderingKey: false]])
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { throw Failure.recording }
                writer.add(input)
                let configuration = SCStreamConfiguration()
                configuration.width = sampling.width; configuration.height = sampling.height
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(sampling.fps)); configuration.queueDepth = 3
                configuration.showsCursor = false; configuration.showMouseClicks = false
                configuration.capturesAudio = false; configuration.captureMicrophone = false
                configuration.scalesToFit = false; configuration.preservesAspectRatio = true
                configuration.captureResolution = .nominal; configuration.ignoreShadowsSingleWindow = true
                if !includingChildWindows || fixedWindow { configuration.includeChildWindows = false }
                if fixedWindow { configuration.ignoreGlobalClipSingleWindow = true }
                if let crop { configuration.sourceRect = crop; configuration.ignoreShadowsDisplay = true }
                configuration.backgroundColor = recordingBackground
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                self.writer = writer; self.input = input; self.capture = stream; self.output = output
                stream.startCapture { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func waitForFirstFrame() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if failureCode != nil { continuation.resume(throwing: Failure.recording) }
                else if !frames.isEmpty { continuation.resume() }
                else {
                    first = continuation
                    // A shareable sheet can have matching geometry while
                    // WindowServer sends only inactive frames. Do not hold a
                    // feature check indefinitely waiting for its first image.
                    queue.asyncAfter(deadline: .now() + .seconds(3)) { [weak self] in
                        guard let self, first != nil else { return }; fail(-5)
                    }
                }
            }
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sample), failureCode == nil else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { skipped += 1; return }
        guard frames.count < sampling.maximumFrames, let writer, let input, let image = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferGetWidth(image) == sampling.width, CVPixelBufferGetHeight(image) == sampling.height else { fail(-1); return }
        if !writerStarted {
            guard writer.startWriting() else { fail(-2); return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample)); writerStarted = true
        }
        guard input.isReadyForMoreMediaData else { dropped += 1; return }
        guard input.append(sample) else { fail(-3); return }
        let values = attachments.first ?? [:]
        let rectangle = (values[.contentRect] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        frames.append(Frame(presentationSeconds: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), receivedUptimeSeconds: CACurrentMediaTime(),
            contentWidth: rectangle.map { Double($0.width) }, contentHeight: rectangle.map { Double($0.height) },
            contentX: rectangle.map { Double($0.minX) }, contentY: rectangle.map { Double($0.minY) },
            contentScale: (values[.contentScale] as? NSNumber)?.doubleValue, scaleFactor: (values[.scaleFactor] as? NSNumber)?.doubleValue))
        first?.resume(); first = nil
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) { queue.async { [self] in fail((error as NSError).code) } }
    private func fail(_ code: Int) { failureCode = code; first?.resume(throwing: Failure.recording); first = nil }
    private func finish(action: Double) async throws -> Report {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Report, Error>) in
            queue.async { [self] in
                guard let capture else { continuation.resume(throwing: Failure.recording); return }
                capture.stopCapture { [self] error in
                    queue.async { [self] in
                        do { try self.capture?.removeStreamOutput(self, type: .screen) } catch { failureCode = -4 }
                        self.capture = nil
                        guard let writer, let input, writerStarted else { continuation.resume(throwing: Failure.recording); return }
                        input.markAsFinished()
                        writer.finishWriting { [self] in
                            queue.async { [self] in
                                let bytes = output.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
                                let report = Report(source: sourceDescription, width: sampling.width, height: sampling.height,
                                    requestedFPS: sampling.fps, maximumFrames: sampling.maximumFrames, diagnosticSampling: sampling.diagnostic, queueDepth: 3, actionUptimeSeconds: action, frames: frames,
                                    skippedInactiveFrames: skipped, droppedEncoderFrames: dropped, streamStopped: error == nil,
                                    writerCompleted: self.writer?.status == .completed, videoBytes: Int64(bytes), failureCode: failureCode, captureGeometry: captureGeometry)
                                self.writer = nil; self.input = nil
                                guard bytes > 0, bytes <= (sampling.diagnostic ? 4_194_304 : 1_048_576) else { continuation.resume(throwing: Failure.recording); return }
                                continuation.resume(returning: report)
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif
