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
        @MainActor static func diagnostic(for window: NSWindow) -> Sampling {
            let scale = min(1, 1152 / window.frame.width, 800 / window.frame.height)
            return Sampling(width: max(1, Int((window.frame.width * scale).rounded(.down))), height: max(1, Int((window.frame.height * scale).rounded(.down))),
                fps: 120, maximumFrames: 180, preRollMilliseconds: 60, afterMilliseconds: 650, diagnostic: true)
        }
    }
    private var sampling = Sampling.standard

    @MainActor static func record(window: NSWindow, over background: NSWindow? = nil, root: URL, label: String,
                                  sampling: Sampling = .standard, includingChildWindows: Bool = true,
                                  action: @MainActor () throws -> Void) async throws -> Report {
        try validateScope(window: window, root: root, label: label)
        if let background {
            try validateScope(window: background, root: root, label: label)
            guard background !== window, background.frame.contains(window.frame) else { throw Failure.scope }
        }
        guard sampling.width > 0, sampling.width <= 1280, sampling.height > 0, sampling.height <= 800,
              sampling.width * sampling.height <= 1152 * 800,
              [60,120].contains(sampling.fps), sampling.maximumFrames <= 180 else { throw Failure.scope }
        let owner = NativeMotionRecorder(); owner.sampling = sampling
        let url = root.appendingPathComponent("evidence/\(label).mov")
        try await owner.start(window: CGWindowID(window.windowNumber), background: background.map { CGWindowID($0.windowNumber) }, expectedWidth: window.frame.width,
                              expectedHeight: window.frame.height, includingChildWindows: includingChildWindows, output: url)
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
        let downloadBatchCase = ProcessInfo.processInfo.arguments.contains("--check-sftp-download-ui")
            && ProcessInfo.processInfo.arguments.contains("--batch-flow")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf: root.appendingPathComponent("reservation.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["action"] as? String == "native-sftp-download-batch"
            && window.title == "SFTP Download · generated review"
        let downloadCase = ProcessInfo.processInfo.arguments.contains("--check-sftp-download-ui")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b12-download-qualification")
        let uploadCase = ProcessInfo.processInfo.arguments.contains("--check-sftp-upload-ui")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b12-upload-integration")
        let patchCase = ProcessInfo.processInfo.arguments.contains("--check-access-patch")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-patch-0.1.1")
        let accessCase = ProcessInfo.processInfo.arguments.contains("--check-onboarding-access")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf: root.appendingPathComponent("reservation.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["action"] as? String == "traverse-access-onboarding-qualification"
        let commandCase = ProcessInfo.processInfo.arguments.contains("--check-command-finder")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf: root.appendingPathComponent("reservation.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["action"] as? String == "traverse-command-finder"
        let profileCase = ProcessInfo.processInfo.arguments.contains("--check-profile-workspaces-ui")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf: root.appendingPathComponent("reservation.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["action"] as? String == "traverse-profile-workspaces-ui"
        let queueCase = ProcessInfo.processInfo.arguments.contains("--check-queue-priority")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf: root.appendingPathComponent("reservation.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["action"] as? String == "traverse-queue-priority"
        let searchCase = ProcessInfo.processInfo.arguments.contains("--check-search-progress")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf: root.appendingPathComponent("reservation.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["action"] as? String == "traverse-search-progress"
        let largestCase = ProcessInfo.processInfo.arguments.contains("--check-largest-files-ui")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf: root.appendingPathComponent("reservation.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["action"] as? String == "traverse-largest-files-ui"
        let archivePaneCase = ProcessInfo.processInfo.arguments.contains("--check-archive-pane-destination")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf: root.appendingPathComponent("reservation.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["action"] as? String == "traverse-archive-pane-destination"
        let archiveSearchCase = ProcessInfo.processInfo.arguments.contains("--check-archive-search")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf: root.appendingPathComponent("reservation.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["action"] as? String == "traverse-archive-search"
        let privateLabelsCase = ProcessInfo.processInfo.arguments.contains("--check-private-labels")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf: root.appendingPathComponent("reservation.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["action"] as? String == "traverse-private-labels"
        let archiveDragCase = ProcessInfo.processInfo.arguments.contains("--check-archive-member-drag")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf: root.appendingPathComponent("reservation.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["action"] as? String == "traverse-archive-member-drag"
        let archiveOrderCase = ProcessInfo.processInfo.arguments.contains("--check-archive-sorting")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf: root.appendingPathComponent("reservation.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["action"] as? String == "traverse-archive-sorting"
        let browserTaskCase = ProcessInfo.processInfo.arguments.contains("--check-browser-tasks")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf: root.appendingPathComponent("reservation.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["action"] as? String == "traverse-browser-tasks"
        let headerHoverCase = ProcessInfo.processInfo.arguments.contains("--check-header-hover")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString:root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf:root.appendingPathComponent("reservation.json")))
                .flatMap {try? JSONSerialization.jsonObject(with:$0)as?[String:Any]})?["action"]as?String == "traverse-header-hover"
        let propertiesStorageCase = ProcessInfo.processInfo.arguments.contains("--check-properties-storage")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString:root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf:root.appendingPathComponent("reservation.json")))
                .flatMap {try? JSONSerialization.jsonObject(with:$0)as?[String:Any]})?["action"]as?String == "traverse-properties-storage"
        let folderOpenerCase = ProcessInfo.processInfo.arguments.contains("--check-folder-opener")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString:root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf:root.appendingPathComponent("reservation.json")))
                .flatMap {try? JSONSerialization.jsonObject(with:$0)as?[String:Any]})?["action"]as?String == "traverse-folder-opener"
        let archiveBytesCase = ProcessInfo.processInfo.arguments.contains("--check-archive-byte-preview")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString:root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf:root.appendingPathComponent("reservation.json")))
                .flatMap {try? JSONSerialization.jsonObject(with:$0)as?[String:Any]})?["action"]as?String == "traverse-archive-bytes-ui"
        let helpCase = ProcessInfo.processInfo.arguments.contains("--check-help-diagnostics")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString:root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf:root.appendingPathComponent("reservation.json")))
                .flatMap {try? JSONSerialization.jsonObject(with:$0)as?[String:Any]})?["action"]as?String == "traverse-native-help-diagnostics"
        let testerCase = ProcessInfo.processInfo.arguments.contains("--check-tester-repairs")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf: root.appendingPathComponent("reservation.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["action"] as? String == "traverse-tester-repair-qualification"
        let developmentCase = ProcessInfo.processInfo.arguments.contains("--check-development-motion")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((try? Data(contentsOf: root.appendingPathComponent("reservation.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["packet"] as? String == "traverse-development-v1"
        let folderAction = ((try? Data(contentsOf: root.appendingPathComponent("reservation.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["action"] as? String
        let routedFolderCase = ProcessInfo.processInfo.arguments.contains("--check-sftp-routed-upload")
            && ProcessInfo.processInfo.arguments.contains("--folder-upload") && folderAction == "routed-folder-upload-native"
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString:root.lastPathComponent)?.uuidString == root.lastPathComponent
        let captureTitleCase = ProcessInfo.processInfo.arguments.contains("--check-sftp-folder-upload-preview")
            && ProcessInfo.processInfo.arguments.contains("--profile-sheet") && ProcessInfo.processInfo.arguments.contains("--record-title")
            && folderAction == "routed-folder-upload-review-profile"
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString:root.lastPathComponent)?.uuidString == root.lastPathComponent
        let tarCase = ProcessInfo.processInfo.arguments.contains("--check-tar-archive") && folderAction == "plain-tar-native"
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString:root.lastPathComponent)?.uuidString == root.lastPathComponent
        let zipRenameCase = ProcessInfo.processInfo.arguments.contains("--check-zip-rename-copy")
            && folderAction == "native-zip-rename-copy" && label == "zip-copy-review"
            && ["ZIP rename · generated review", "ZIP removal · generated review", "ZIP Add · generated review", "ZIP new folder · generated review"].contains(window.title)
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
        let smbFolderCase = ProcessInfo.processInfo.arguments.contains("--check-smb-folder-download")
            && folderAction == "smb-folder-download-native" && window.title == "SMB folders · generated review"
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString:root.lastPathComponent)?.uuidString == root.lastPathComponent
        let smbGroupCase = ProcessInfo.processInfo.arguments.contains("--check-smb-selected-download")
            && (folderAction == "smb-selected-download-group-native" && label == "smb-group-download"
                || folderAction == "smb-selected-download-group-native-preflight" && label == "smb-group-preflight")
            && window.title == "SMB selected files · generated review"
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
        let sftpActionCase = ProcessInfo.processInfo.arguments.contains("--check-sftp-drop-upload")
            && folderAction == "native-sftp-drop-upload"
            && (label == "sftp-action-history-clear" && window.title == "SFTP file actions · generated review"
                || label == "sftp-connection-status" && window.title == "SFTP group upload · generated review")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
        let smbDestinationCase = ProcessInfo.processInfo.arguments.contains("--check-smb-selected-download")
            && folderAction == "smb-selected-download-ordinary-native"
            && (window.title == "SMB Move · generated review" && label == "smb-move-destination"
                || window.title == "SMB Copy · generated review" && label == "smb-copy-destination")
        let remotePropertiesCase = (ProcessInfo.processInfo.arguments.contains("--check-remote-properties") && folderAction == "remote-item-properties"
            || ProcessInfo.processInfo.arguments.contains("--check-directory-recovery") && folderAction == "native-directory-recovery"
            || ProcessInfo.processInfo.arguments.contains("--check-smb-open-recovery") && folderAction == "smb-directory-recovery-native"
            || ProcessInfo.processInfo.arguments.contains("--check-smb-selected-download") && folderAction == "smb-selected-download-live-native"
            || ProcessInfo.processInfo.arguments.contains("--check-sftp-routed-upload") && ProcessInfo.processInfo.arguments.contains("--folder-upload") && folderAction == "routed-folder-upload-native"
            || ProcessInfo.processInfo.arguments.contains("--check-connection-fields") && folderAction == "native-connection-fields"
            || ProcessInfo.processInfo.arguments.contains("--check-drive-benchmark-native") && folderAction == "native-drive-benchmark"
                && ["drive-benchmark-run", "drive-benchmark-suite-comparison", "drive-benchmark-suite-comparison-reduced",
                    "drive-benchmark-suite-comparison-off", "drive-benchmark-comparison", "drive-benchmark-comparison-size"].contains(label)
            || tarCase || zipRenameCase || smbGroupCase || sftpActionCase || smbDestinationCase)
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString:root.lastPathComponent)?.uuidString == root.lastPathComponent
        let folderDownloadCase = (ProcessInfo.processInfo.arguments.contains("--check-sftp-folder-download") && folderAction == "sftp-native-folder-download"
            || ProcessInfo.processInfo.arguments.contains("--check-sftp-folder-review") && folderAction == "sftp-folder-preview")
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
        let dataClassificationCase = ProcessInfo.processInfo.arguments.contains("--check-data-classification")
            && folderAction == "data-classification-native"
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
        let purposeJourneyCase = ProcessInfo.processInfo.arguments.contains("--check-purpose-journey")
            && folderAction == "purpose-journey-native"
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ["Properties · generated review · purpose journey", "Storage Analysis · generated review · purpose journey"].contains(window.title)
        let folderUploadCase = ProcessInfo.processInfo.arguments.contains("--check-sftp-folder-upload-preview")
            && (folderAction == "folder-upload-preview" || captureTitleCase)
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
        let exclusiveUploadCase = ProcessInfo.processInfo.arguments.contains("--check-sftp-auth-transfer")
            && ProcessInfo.processInfo.arguments.contains("--record-exclusive-upload") && ProcessInfo.processInfo.arguments.contains("--preview-only") && folderAction == "exclusive-upload-preview"
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
        let driveStatusCase = ProcessInfo.processInfo.arguments.contains("--check-drive-storage-status")
            && folderAction == "native-drive-storage-status"
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && window.title == "Drive Details · generated review · storage status"
        let inlineArchiveCase = ProcessInfo.processInfo.arguments.contains("--check-inline-archive-motion")
            && folderAction == "inline-archive-native"
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && window.title == "Archives · generated review · motion audit"
            && ((try? Data(contentsOf: root.appendingPathComponent("inline-admission.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["phase"] as? String == "motion"
        let tarPreviewCase = ProcessInfo.processInfo.arguments.contains("--check-tar-preview-native")
            && folderAction == "tar-preview-native"
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && window.title == "TAR preview · generated review · motion audit"
        let selectionGroupCase = ProcessInfo.processInfo.arguments.contains("--check-selection-group-native")
            && folderAction == "selection-group-native"
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && window.title == "Grouping · generated review · motion audit"
            && ["selection-group-draft", "selection-group-results", "selection-group-new-folder",
                "selection-group-new-folder-return"].contains(label)
        let settingsSidebarCase = ProcessInfo.processInfo.arguments.contains("--check-settings-sidebar")
            && folderAction == "settings-sidebar-v1"
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && window.title == "Settings · generated review · sidebar motion"
            && ["settings-keyboard", "settings-appearance"].contains(label)
            && ((try? Data(contentsOf: root.appendingPathComponent("settings-admission.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["master"] as? String == "46F68181-FA2B-4308-8713-7D518F2FF08C"
        let recordedAnalysisCase = ProcessInfo.processInfo.arguments.contains("--check-analysis-persistence")
            && ProcessInfo.processInfo.arguments.contains("--record-analysis-persistence")
            && folderAction == "native-analysis-persistence"
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && window.title == "Storage Analysis · generated review · retained analysis"
            && label == "analysis-refresh"
        let editorComparisonCase = ProcessInfo.processInfo.arguments.contains("--verify-ui")
            && ProcessInfo.processInfo.arguments.contains("--check-editor-preferences")
            && folderAction == "native-editor-preferences"
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ((window.title == "Compare Changes · generated review"
                 && ["editor-comparison-stack", "editor-comparison-pair"].contains(label))
                || (window.title == "Find in Open Editors · generated review" && label == "editor-open-search-entrance"))
        let helpMotionCase = ProcessInfo.processInfo.arguments.contains("--check-help-motion")
            && folderAction == "help-form-motion-v1"
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && window.title == "Help · generated review · private field motion"
            && ["help-invitation", "help-support", "help-public-updates"].contains(label)
            && ((try? Data(contentsOf: root.appendingPathComponent("help-motion-admission.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["master"] as? String == "46F68181-FA2B-4308-8713-7D518F2FF08C"
        let folderDefaultCase: Bool = {
            guard ProcessInfo.processInfo.arguments.contains("--verify-ui"),
                  ProcessInfo.processInfo.arguments.contains("--check-folder-default-composition"),
                  Bundle.main.bundleIdentifier == "local.macexplorer.development",
                  folderAction == "folder-default-app-composition",
                  root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development"),
                  UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
                  window.title == "Settings · generated review · folder default",
                  window.frame.width == 860, window.frame.height == 692,
                  ["default-owned-100-solid", "default-owned-100-glass", "default-owned-150-solid", "default-owned-150-glass"].contains(label)
            else { return false }
            let admission = ((try? Data(contentsOf: root.appendingPathComponent("folder-default-composition-admission.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            return admission?["master"] as? String == "46F68181-FA2B-4308-8713-7D518F2FF08C"
                && admission?["fakeBackendOnly"] as? Bool == true
                && admission?["liveHandlerQueries"] as? Int == 0
                && admission?["liveAssociationSetters"] as? Int == 0
                && admission?["captureProfile"] as? String == "folder-default-static-dark-v1"
        }()
        guard ["--check-access-patch", "--check-smb-connect-standalone", "--check-smb-browser-ui", "--check-motion-modes", "--check-sftp-trust-standalone", "--check-sftp-live-standalone", "--check-sftp-download-ui"].contains(where: ProcessInfo.processInfo.arguments.contains) || uploadCase || accessCase || commandCase || profileCase || queueCase || searchCase || largestCase || archivePaneCase || archiveSearchCase || privateLabelsCase || archiveDragCase || archiveOrderCase || browserTaskCase || headerHoverCase || propertiesStorageCase || folderOpenerCase || archiveBytesCase || helpCase || testerCase || developmentCase || folderDownloadCase || dataClassificationCase || purposeJourneyCase || exclusiveUploadCase || folderUploadCase || remotePropertiesCase || smbFolderCase || driveStatusCase || inlineArchiveCase || tarCase || tarPreviewCase || selectionGroupCase || settingsSidebarCase || helpMotionCase || folderDefaultCase || recordedAnalysisCase || editorComparisonCase,
              root.path == ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              root.path.hasPrefix(repo.appendingPathComponent(".build/").path + "/"), root.resolvingSymlinksInPath() == root,
              !label.isEmpty, label.utf8.count <= 48, label.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              window.isVisible, window.windowNumber > 0, window.title.contains("generated review"),
              window.frame.width <= (downloadBatchCase ? 1280 : folderDownloadCase || routedFolderCase || captureTitleCase || tarCase || smbFolderCase ? 1280 : browserTaskCase || developmentCase || dataClassificationCase || purposeJourneyCase || exclusiveUploadCase || folderUploadCase || remotePropertiesCase || inlineArchiveCase || tarPreviewCase || selectionGroupCase || settingsSidebarCase || helpMotionCase || editorComparisonCase ? 1152 : downloadCase ? 1024 : 960), window.frame.height <= (downloadBatchCase ? 800 : folderDefaultCase ? 692 : browserTaskCase || developmentCase || folderDownloadCase || dataClassificationCase || purposeJourneyCase || exclusiveUploadCase || folderUploadCase || remotePropertiesCase || smbFolderCase || driveStatusCase || inlineArchiveCase || tarPreviewCase || selectionGroupCase || settingsSidebarCase || helpMotionCase || recordedAnalysisCase || tarCase || editorComparisonCase ? 800 : patchCase || accessCase || helpCase ? 700 : 640) else { throw Failure.scope }
    }

    private func start(window id: CGWindowID, background: CGWindowID?, expectedWidth: Double, expectedHeight: Double,
                       includingChildWindows: Bool, output: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                observeStart(window: id, background: background, expectedWidth: expectedWidth, expectedHeight: expectedHeight,
                    includingChildWindows: includingChildWindows, output: output, attempt: 1, continuation: continuation)
            }
        }
    }
    // A newly ordered window can precede WindowServer's current-process list.
    // Retry only that exact ID/geometry, on this queue, at most fifty times;
    // errors remain terminal. Never enumerate another app or capture a whole display.
    private func observeStart(window id: CGWindowID, background: CGWindowID?, expectedWidth: Double, expectedHeight: Double,
                              includingChildWindows: Bool, output: URL, attempt: Int, continuation: CheckedContinuation<Void, Error>) {
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
                            includingChildWindows: includingChildWindows, output: output, attempt: attempt + 1, continuation: continuation)
                    }
                    return
                }
                let readiness: [String:Any] = ["lookups": attempt,"exactWindowPresent": ownWindow != nil,"geometryMatches": geometryReady,
                    "ownerMatches": ownWindow?.owningApplication?.processID == getpid(),
                    "backgroundRequested": background != nil, "backgroundReady": backgroundReady,
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
                } else if !includingChildWindows {
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
                } else { filter = SCContentFilter(desktopIndependentWindow: window); crop = nil }
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
                if !includingChildWindows { configuration.includeChildWindows = false }
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
