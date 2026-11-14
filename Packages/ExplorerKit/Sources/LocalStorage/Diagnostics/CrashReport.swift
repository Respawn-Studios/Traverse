import Foundation

/// Shareable crash facts only. Native capture bytes remain in a private store;
/// arbitrary exception messages, registers, process names and file paths do not
/// have a field in this projection. Addresses/UUIDs support offline symbolication.
public struct CrashReport: Codable, Equatable, Sendable, Identifiable {
    public enum Architecture: String, Codable, Sendable { case arm64, x86_64, unknown }
    public enum Signal: String, Codable, Sendable {
        case abort = "SIGABRT", bus = "SIGBUS", segmentation = "SIGSEGV"
        case illegalInstruction = "SIGILL", trap = "SIGTRAP", arithmetic = "SIGFPE"
        case unknown = "Unknown"
    }
    public enum ImageKind: String, Codable, Sendable {
        case application = "Traverse", crashReporter = "CrashReporter", updater = "Sparkle"
        case system = "System image", external = "External image"
    }
    public struct Image: Codable, Equatable, Sendable {
        public let kind: ImageKind
        public let uuid: String?
        public let base: UInt64
        public let size: UInt64
        public init(kind: ImageKind, uuid: String?, base: UInt64, size: UInt64) {
            self.kind = kind; self.uuid = uuid; self.base = base; self.size = size
        }
    }
    public struct Frame: Codable, Equatable, Sendable {
        public let address: UInt64
        public let image: Int?
        public init(address: UInt64, image: Int?) { self.address = address; self.image = image }
    }
    public struct Thread: Codable, Equatable, Sendable {
        public let number: Int
        public let crashed: Bool
        public let frames: [Frame]
        public init(number: Int, crashed: Bool, frames: [Frame]) {
            self.number = number; self.crashed = crashed; self.frames = frames
        }
    }
    public let id: UUID
    public let capturedAt: Date?
    public let version: String?
    public let build: String?
    public let systemVersion: String?
    public let systemBuild: String?
    public let architecture: Architecture
    public let signal: Signal
    public let images: [Image]
    public let threads: [Thread]
    public let truncated: Bool

    public init(id: UUID = UUID(), capturedAt: Date?, version: String?, build: String?,
                systemVersion: String?, systemBuild: String?, architecture: Architecture,
                signal: Signal, images: [Image], threads: [Thread], truncated: Bool = false) throws {
        self.id = id; self.capturedAt = capturedAt; self.version = version; self.build = build
        self.systemVersion = systemVersion; self.systemBuild = systemBuild
        self.architecture = architecture; self.signal = signal; self.images = images
        self.threads = threads; self.truncated = truncated
        try validate()
    }

    public func validate() throws {
        guard Self.numeric(version), Self.numeric(build), Self.numeric(systemVersion),
              systemBuild.map({ !$0.isEmpty && $0.utf8.count <= 32 && $0.utf8.allSatisfy(Self.alphaNumeric) }) ?? true,
              capturedAt.map({ $0.timeIntervalSince1970.isFinite && (0...4_102_444_800).contains($0.timeIntervalSince1970) }) ?? true,
              images.count <= 512, threads.count <= 128,
              threads.allSatisfy({ $0.frames.count <= 512 }),
              threads.reduce(0, { $0 + $1.frames.count }) <= 8192,
              Set(threads.map(\.number)).count == threads.count,
              images.allSatisfy({ image in
                  image.size <= UInt64.max - image.base
                    && (image.uuid.map(Self.validUUID) ?? true)
              }),
              threads.allSatisfy({ thread in
                  (0...65535).contains(thread.number) && thread.frames.count <= 512
                    && thread.frames.allSatisfy { frame in
                        guard let index = frame.image else { return true }
                        guard images.indices.contains(index) else { return false }
                        let image = images[index]
                        return frame.address >= image.base && frame.address - image.base < image.size
                    }
              }) else { throw CrashReportFailure.invalid }
    }

    public func text(includeOtherThreads: Bool = false) throws -> String {
        try validate()
        var lines = ["Traverse Crash Report · v1", "Report: \(id.uuidString)",
                     "App: \(version ?? "Unavailable") (\(build ?? "Unavailable"))",
                     "macOS at capture: \(systemVersion ?? "Unavailable") (\(systemBuild ?? "Unavailable"))",
                     "Architecture: \(architecture.rawValue)", "Signal: \(signal.rawValue)"]
        if let capturedAt { lines.append("Captured: \(ISO8601DateFormatter().string(from: capturedAt))") }
        lines += ["", "## What happened", "", "## Steps to reproduce", "", "## Expected behavior", "", "## Crash trace"]
        let selectedThreads = threads.filter { $0.crashed || includeOtherThreads }
        let referencedImages = Set(selectedThreads.flatMap { $0.frames.compactMap(\.image) })
        var metadata = ["", "## Binary images"]
        for (index, image) in images.enumerated()
            where includeOtherThreads || referencedImages.contains(index) || image.kind == .application {
            metadata.append("image[\(index)] \(image.kind.rawValue) · UUID \(image.uuid ?? "Unavailable") · base 0x\(String(image.base, radix: 16)) · size \(image.size)")
        }
        if !includeOtherThreads {
            metadata.append("Image identities cover the displayed stack and application. Include Other Threads adds the full loaded-image table.")
        }
        metadata += ["", "Registers, memory contents, exception messages and file/process paths are excluded.",
                     "Addresses require the matching release binaries and dSYMs for symbolication."]
        // Keep image identities even when the extended thread list fills the
        // budget; code addresses alone cannot be reliably symbolicated.
        let frameBudget = (256 << 10) - metadata.joined(separator: "\n").utf8.count - 256
        var size = lines.joined(separator: "\n").utf8.count
        var framesOmitted = false
        threadLoop: for thread in selectedThreads {
            let heading = "Thread \(thread.number)" + (thread.crashed ? " (crashed)" : "")
            size += heading.utf8.count + 1
            lines.append(heading)
            for (number, frame) in thread.frames.enumerated() {
                let location: String
                if let index = frame.image {
                    let image = images[index]
                    location = "image[\(index)] \(image.kind.rawValue) + 0x\(String(frame.address - image.base, radix: 16))"
                } else { location = "unmapped" }
                let line = "\(number) 0x\(String(frame.address, radix: 16)) \(location)"
                size += line.utf8.count + 1
                if size >= frameBudget { framesOmitted = true; break threadLoop }
                lines.append(line)
            }
        }
        if framesOmitted { lines.append("Additional frames omitted by the report size limit.") }
        if truncated { lines += ["", "Capture was bounded; some threads, frames or images were omitted."] }
        lines += metadata
        return lines.joined(separator: "\n")
    }

    public func githubIssueTitle() throws -> String {
        try validate()
        return "Crash: Traverse \(version ?? "unknown") (\(build ?? "unknown"))"
    }

    public static func numeric(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.utf8.count <= 32
            && value.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 }
            && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty }
    }
    private static func alphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
    private static func validUUID(_ value: String) -> Bool {
        guard value.utf8.count == 32 || value.utf8.count == 36 else { return false }
        if value.utf8.count == 36 {
            guard UUID(uuidString: value) != nil else { return false }
        } else if value.contains("-") { return false }
        let compact = value.replacingOccurrences(of: "-", with: "")
        return compact.utf8.count == 32 && compact.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
}

public enum CrashReportFailure: Error, Equatable, Sendable { case invalid, capacity, unavailable, busy, changed, io }
