@preconcurrency import CrashReporter
import Darwin
import Foundation
import LocalStorage

/// Queue-confined Objective-C engine. No Swift crash callback, symbol lookup,
/// networking, lifecycle string or user-file body is installed in the handler.
final class NativeCrashCapture {
    private let reporter: PLCrashReporter
    private let store: CrashReportStore
    private let applicationIdentifier: String
    private var recovered = false
    private var pendingDiscardCandidate: CrashReportStore.PendingDiscardCandidate?

    init(store: CrashReportStore, applicationIdentifier: String) throws {
        self.store = store; self.applicationIdentifier = applicationIdentifier
        let directory = try store.prepareEngineDirectory(applicationIdentifier: applicationIdentifier)
        guard let config = PLCrashReporterConfig(signalHandlerType: .mach, symbolicationStrategy: [],
            shouldRegisterUncaughtExceptionHandler: false, basePath: directory.path,
            maxReportBytes: UInt(CrashReportStore.maximumNativeBytes)),
              let reporter = PLCrashReporter(configuration: config) else { throw CrashReportFailure.unavailable }
        self.reporter = reporter
    }

    func recoverPending() throws -> Bool {
        recovered = false
        pendingDiscardCandidate = nil
        var unresolvedNativeLeaf = true
        do {
            guard let pending = try store.readPending(applicationIdentifier: applicationIdentifier) else {
                recovered = true
                return false
            }
            let report = try Self.project(pending.data, expectedIdentifier: applicationIdentifier)
            // Once the native capture is valid, storage capacity, durability
            // and purge failures must keep it intact for later recovery.
            unresolvedNativeLeaf = false
            try store.retain(pending.data, report: report)
            // The native leaf is removed only after durable catalog retention and
            // a fresh descriptor read proves its identity and complete bytes.
            try store.purgePending(pending, applicationIdentifier: applicationIdentifier)
            recovered = true
            return true
        } catch {
            // This creates no prompt and performs no deletion. The worker may
            // later offer an explicit discard only for the fixed observed leaf.
            if unresolvedNativeLeaf {
                pendingDiscardCandidate = try? store.observeUnrecoveredPendingForDiscard(
                    applicationIdentifier: applicationIdentifier)
            }
            throw error
        }
    }

    var hasUnrecoveredPendingDiscardCandidate: Bool { pendingDiscardCandidate != nil }

    /// Called on this capture's worker queue after an explicit user decision.
    /// A failed attempt consumes the observation; recovery remains paused.
    func discardUnrecoveredPending() throws {
        guard !recovered, let candidate = pendingDiscardCandidate else {
            throw CrashReportFailure.unavailable
        }
        pendingDiscardCandidate = nil
        try store.discardUnrecoveredPending(candidate, applicationIdentifier: applicationIdentifier)
    }

    func enable() throws {
        guard recovered else { throw CrashReportFailure.unavailable }
        _ = try store.prepareEngineDirectory(applicationIdentifier: applicationIdentifier)
        guard try store.readPending(applicationIdentifier: applicationIdentifier) == nil else {
            throw CrashReportFailure.changed
        }
        try store.requireCaptureSpace()
        try reporter.enableAndReturnError()
    }

    static var debuggerAttached: Bool {
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, UInt32(name.count), &process, &size, nil, 0) == 0 else { return true }
        return process.kp_proc.p_flag & P_TRACED != 0
    }

    static func project(_ data: Data, expectedIdentifier: String) throws -> CrashReport {
        guard data.count <= CrashReportStore.maximumNativeBytes else { throw CrashReportFailure.capacity }
        let native = try PLCrashReport(data: data)
        guard native.applicationInfo.applicationIdentifier == expectedIdentifier else { throw CrashReportFailure.invalid }
        let nativeImages = (native.images as? [PLCrashReportBinaryImageInfo]) ?? []
        let selectedImages = Array(nativeImages.prefix(512))
        let processPath = native.processInfo?.processPath
        let bundlePrefix = processPath.flatMap { path -> String? in
            guard let range = path.range(of: ".app/Contents/MacOS/", options: .backwards) else { return nil }
            return String(path[..<range.lowerBound]) + ".app/Contents/Frameworks/"
        }
        let images: [CrashReport.Image] = selectedImages.map { image in
            let path = image.imageName ?? ""
            let kind: CrashReport.ImageKind
            if !path.isEmpty && path == processPath { kind = .application }
            else if let bundlePrefix, path.hasPrefix(bundlePrefix + "CrashReporter.framework/") { kind = .crashReporter }
            else if let bundlePrefix, path.hasPrefix(bundlePrefix + "Sparkle.framework/") { kind = .updater }
            else if path.hasPrefix("/System/Library/") || path.hasPrefix("/usr/lib/") { kind = .system }
            else { kind = .external }
            let uuid = image.hasImageUUID ? image.imageUUID : nil
            let safeUUID = uuid.flatMap { UUID(uuidString: $0)?.uuidString ?? ($0.utf8.count == 32 ? $0 : nil) }
            return .init(kind: kind, uuid: safeUUID, base: image.imageBaseAddress, size: image.imageSize)
        }
        let nativeThreads = (native.threads as? [PLCrashReportThreadInfo]) ?? []
        var remaining = 8192
        var truncated = nativeImages.count > images.count || nativeThreads.count > 128
        // Keep the failing thread even when it appears beyond the first 128,
        // and spend the aggregate frame budget on it before other threads.
        let orderedThreads = nativeThreads.filter(\.crashed) + nativeThreads.filter { !$0.crashed }
        let threads: [CrashReport.Thread] = try orderedThreads.prefix(128).map { thread in
            guard (0...65535).contains(thread.threadNumber) else { throw CrashReportFailure.invalid }
            let originalFrames = (thread.stackFrames as? [PLCrashReportStackFrameInfo]) ?? []
            let count = min(512, remaining)
            let frames = originalFrames.prefix(count).map { frame -> CrashReport.Frame in
                let address = frame.instructionPointer
                let image = images.firstIndex { address >= $0.base && address - $0.base < $0.size }
                return .init(address: address, image: image)
            }
            remaining -= frames.count
            truncated = truncated || frames.count < originalFrames.count
            return .init(number: Int(thread.threadNumber), crashed: thread.crashed, frames: frames)
        }
        func version(_ text: String?) -> String? { CrashReport.numeric(text) ? text : nil }
        let type = native.systemInfo.processorInfo.type
        let architecture: CrashReport.Architecture = type == UInt64(CPU_TYPE_ARM64) ? .arm64
            : type == UInt64(CPU_TYPE_X86_64) ? .x86_64 : .unknown
        let systemBuild = native.systemInfo.operatingSystemBuild.flatMap { text -> String? in
            guard !text.isEmpty, text.utf8.count <= 32,
                  text.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
            return text
        }
        let machine = native.machineInfo.map { info in
            let model = info.modelName.flatMap { name -> String? in
                guard name.utf8.count <= 64,
                      name.range(of: #"\A[A-Za-z][A-Za-z0-9]*[0-9],[0-9]+\z"#,
                          options: .regularExpression) != nil else { return nil }
                return name
            }
            func cores(_ count: UInt) -> Int? { (1...4096).contains(count) ? Int(count) : nil }
            return CrashReport.Machine(model: model, physicalCores: cores(info.processorCount),
                logicalCores: cores(info.logicalProcessorCount))
        }
        return try CrashReport(capturedAt: native.systemInfo.timestamp,
            version: version(native.applicationInfo.applicationMarketingVersion),
            build: version(native.applicationInfo.applicationVersion), systemVersion: version(native.systemInfo.operatingSystemVersion),
            systemBuild: systemBuild, architecture: architecture,
            signal: CrashReport.Signal(rawValue: native.signalInfo.name ?? "") ?? .unknown,
            images: images, threads: threads, truncated: truncated, machine: machine)
    }
}
