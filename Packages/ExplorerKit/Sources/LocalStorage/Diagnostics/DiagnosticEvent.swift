import Foundation
import ExplorerCore

/// Closed vocabulary: callers cannot accidentally pass a path, query or password
/// as an action, stage, result or error description.
public enum DiagnosticAction: String, Codable, Sendable, CaseIterable {
    case application, shutdown, help, diagnostics, updates, releaseNotes, support, control
    case browse, back, forward, up, thisMac, home, refresh, selection, sort, filter, search, searchOpen
    case newTab, closeTab, switchTab, duplicateTab, reorderTab, reopenTab, splitPane, closePane, focusPane
    case profile, folderView, pin, drag, drop, preview, quickLook, open, openWith, reveal, share
    case fileOperation, copy, cut, paste, move, duplicate, newFolder, rename, batchRename, trash, undo, recovery, cleanup, queue
    case folderAccess, privacy, onboarding, tutorial, settings, shortcuts, appearance, motion
    case analysis, analysisQuery, analyzeSelection, scanStop, driveOverview, driveDetails, driveProtection, driveBenchmark, driveHealth, eject
    case privateNames, privateSearch, relink, removeAccess, forget, importNames, exportNames
    case archiveBrowse, archiveCheck, archivePreview, archiveExtract, archiveCreate, archiveSearch
    case connect, disconnect, remoteBrowse, remoteDownload, remoteUpload, credentials, hostKey
    case historyGap
}

public enum DiagnosticPhase: String, Codable, Sendable, CaseIterable {
    case requested, dispatched, admitted, preparing, reading, resolving, authenticating, transferring
    case verifying, committing, presenting, waiting, draining, restarting, cleaning, retaining, finished
    case completed, partial, cancelled, blocked, failed, paused, resumed, interrupted, gap
}
public enum DiagnosticLevel: String, Codable, Sendable { case information, warning, error }
public enum DiagnosticErrorDomain: String, Codable, Sendable {
    case operation, access, cocoa, posix, sqlite, network, scanner, archive, privateStore, updater, diagnostics, sparkle, security, benchmark, unknown
}

public struct DiagnosticErrorCode: Codable, Sendable, Equatable {
    public let domain: DiagnosticErrorDomain
    public let code: Int64
    public init(domain: DiagnosticErrorDomain, code: Int64) { self.domain = domain; self.code = code }
}

public struct DiagnosticBuild: Codable, Sendable, Equatable {
    public let version: String
    public let number: UInt64
    public init(version: String, number: UInt64) throws {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard version.utf8.count <= 32, (1...3).contains(parts.count), number > 0,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 6 && $0.utf8.allSatisfy { (48...57).contains($0) } }) else {
            throw DiagnosticHistoryFailure.invalidInput
        }
        self.version = version; self.number = number
    }
    var isValid: Bool { (try? Self(version: version, number: number)) != nil }
}

public struct DiagnosticEvent: Codable, Sendable, Identifiable, Equatable {
    public let schema: Int
    public let id: UUID
    public let session: UUID
    public let trace: UUID
    public let action: DiagnosticAction
    public let phase: DiagnosticPhase
    public let level: DiagnosticLevel
    public let utcMilliseconds: Int64
    public let uptimeNanoseconds: UInt64
    public let count: UInt64?
    public let durationMilliseconds: UInt64?
    public let error: DiagnosticErrorCode?
    public let build: DiagnosticBuild?
    public let command: BrowserCommand?
    public let ordinal: UInt64?
    public let relatedTrace: UUID?
    public let context: DiagnosticContext?
    public let causes: [DiagnosticErrorCode]?
    public let runtime: DiagnosticRuntime?

    public init(session: UUID, trace: UUID, action: DiagnosticAction, phase: DiagnosticPhase,
                level: DiagnosticLevel = .information, count: UInt64? = nil,
                durationMilliseconds: UInt64? = nil, error: DiagnosticErrorCode? = nil,
                build: DiagnosticBuild? = nil, command: BrowserCommand? = nil,
                ordinal: UInt64? = nil, relatedTrace: UUID? = nil,
                context: DiagnosticContext? = nil, causes: [DiagnosticErrorCode]? = nil, runtime: DiagnosticRuntime? = nil,
                now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        schema = 1; id = UUID(); self.session = session; self.trace = trace
        self.action = action; self.phase = phase; self.level = level
        utcMilliseconds = Self.milliseconds(now)
        uptimeNanoseconds = uptime.isFinite && uptime >= 0 && uptime < 1_000_000_000
            ? UInt64(uptime * 1_000_000_000) : 0
        self.count = count; self.durationMilliseconds = durationMilliseconds; self.error = error
        self.build = build
        self.command = command
        self.ordinal = ordinal; self.relatedTrace = relatedTrace
        self.context = context; self.causes = causes.map { Array($0.prefix(3)) }; self.runtime = runtime
    }

    static func milliseconds(_ date: Date) -> Int64 {
        let value = date.timeIntervalSince1970 * 1000
        return value.isFinite && value >= 0 && value < Double(Int64.max) ? Int64(value) : 0
    }
    var isValid: Bool {
        schema == 1 && utcMilliseconds >= 0 && (build == nil || build?.isValid == true)
            && (context == nil || context?.isValid == true) && (causes?.count ?? 0) <= 3
    }
}

public enum DiagnosticHistoryFailure: Error, Sendable, Equatable {
    case unavailable, busy, changed, incompatible, invalidInput, capacity, io(Int32)
}

public struct DiagnosticHistoryStatus: Sendable {
    public let recording: Bool
    public let pending: Int
    public let dropped: UInt64
    public let failure: DiagnosticHistoryFailure?
}

/// Scope for reviewing or exporting this app's already-retained technical logs.
public enum DiagnosticLogScope: Sendable, Equatable {
    case all
    /// Includes the selected trace and retained tasks linked to it in either direction.
    case operation(UUID)
}

/// Opaque, store-bound position. A caller cannot substitute a pathname.
public struct DiagnosticHistoryCursor: Sendable {
    let owner: UUID
    let segment: UInt64
    let before: Int
}
public struct DiagnosticHistoryPage: Sendable {
    public let events: [DiagnosticEvent]
    public let next: DiagnosticHistoryCursor?
    public let incomplete: Bool
}

public struct DiagnosticHistoryLimits: Sendable {
    public let bytes: Int
    public let segmentBytes: Int
    public let pendingEvents: Int
    public let retentionSeconds: TimeInterval
    public init(bytes: Int = 64 << 20, segmentBytes: Int = 2 << 20,
                pendingEvents: Int = 4096, retentionSeconds: TimeInterval = 14 * 86400) throws {
        guard ((64 << 10)...(64 << 20)).contains(bytes), ((8 << 10)...(2 << 20)).contains(segmentBytes),
              segmentBytes <= bytes / 2, (1...4096).contains(pendingEvents),
              retentionSeconds.isFinite, (1...14 * 86400).contains(retentionSeconds) else {
            throw DiagnosticHistoryFailure.invalidInput
        }
        self.bytes = bytes; self.segmentBytes = segmentBytes
        self.pendingEvents = pendingEvents; self.retentionSeconds = retentionSeconds
    }
}
