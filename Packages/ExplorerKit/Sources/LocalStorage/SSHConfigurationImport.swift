import CryptoKit
import Darwin
import Foundation
import SSHConfiguration

public struct SSHConfigurationImport: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let configuration: SSHConfiguration
    public let profiles: [SSHProfileSummary]
    fileprivate let selected: URL, authority: URL?, sshDirectory: URL
    fileprivate let observations: [String: Observation]
    fileprivate struct Observation: Sendable, Equatable { let stamp: SSHSelectedFileStamp, digest: Data }
    public var description: String { "<imported SSH profiles>" }
    public var debugDescription: String { description }
}

/// One import/revalidation at a time. Cancellation waits for the actual bounded
/// reader to return and release its scope/descriptors; no abandoned file task.
public actor SSHConfigurationReader {
    private let queue = DispatchQueue(label: "Traverse.SSH.Configuration", qos: .utility)
    private let hooks: SSHSelectedAccessHooks
    private var busy = false
    public init() { hooks = .init() }
    init(hooks: SSHSelectedAccessHooks) { self.hooks = hooks }

    public func load(selected: URL, authorizedDirectory: URL?, userSSHDirectory: URL,
                     defaultUser: String? = nil) async throws -> SSHConfigurationImport {
        guard !busy else { throw SSHSelectedFileFailure.busy }; busy = true; defer { busy = false }
        let cancellation = SSHReadCancellation(), hooks = hooks, queue = queue
        return try await withTaskCancellationHandler {
            if Task.isCancelled { cancellation.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try Self.read(selected: selected, authority: authorizedDirectory, sshDirectory: userSSHDirectory,
                                      defaultUser: defaultUser, hooks: hooks, check: {
                            if cancellation.cancelled { throw SSHSelectedFileFailure.stopped }
                        })
                    })
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    public func revalidate(_ snapshot: SSHConfigurationImport, defaultUser: String? = nil) async throws {
        let fresh = try await load(selected: snapshot.selected, authorizedDirectory: snapshot.authority,
                                   userSSHDirectory: snapshot.sshDirectory, defaultUser: defaultUser)
        guard fresh.observations == snapshot.observations else { throw SSHSelectedFileFailure.changed }
    }

    private static func read(selected: URL, authority: URL?, sshDirectory: URL, defaultUser: String?,
                             hooks: SSHSelectedAccessHooks, check: () throws -> Void) throws -> SSHConfigurationImport {
        try check()
        let selection = try SSHSelectedFile.path(selected), base = try SSHSelectedFile.path(sshDirectory)
        let allowed = try authority.map(SSHSelectedFile.path)
        if let allowed, !selection.hasPrefix(allowed == "/" ? "/" : allowed + "/") { throw SSHSelectedFileFailure.invalidSelection }
        let access = authority ?? selected, active = hooks.start(access)
        defer { if active { hooks.stop(access) } }
        let anchor = try authority.map(SSHSelectedFile.directory)
        defer { if let anchor { close(anchor) } }
        func relative(_ path: String) throws -> String {
            guard let allowed, path.hasPrefix(allowed == "/" ? "/" : allowed + "/") else { throw SSHSelectedFileFailure.unavailable }
            return String(path.dropFirst(allowed == "/" ? 1 : allowed.count + 1))
        }
        var documents: [SSHConfigurationDocument] = [], observations: [String: SSHConfigurationImport.Observation] = [:]
        var paths: [String: String] = [:], total = 0, examined = 0
        func add(_ path: String) throws -> String {
            if let id = paths[path] { return id }
            guard documents.count < 32 else { throw SSHSelectedFileFailure.capacity }
            let fd: Int32
            if let anchor { fd = try SSHSelectedFile.openRelative(relative(path), root: anchor) }
            else {
                guard path == selection else { throw SSHSelectedFileFailure.unavailable }
                fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
                guard fd >= 0 else { throw SSHSelectedFileFailure.unavailable }
            }
            defer { close(fd) }
            let (data, stamp) = try SSHSelectedFile.read(fd, maximum: 256 << 10, privateKey: false, check: check)
            guard total <= (1 << 20) - data.count else { throw SSHSelectedFileFailure.capacity }; total += data.count
            let id = "document-\(documents.count)"
            observations[path] = .init(stamp: stamp, digest: Data(SHA256.hash(data: data)))
            documents.append(.init(id: id, bytes: data)); paths[path] = id; return id
        }
        let root = try add(selection)
        var bindings: [SSHIncludeResolution] = [], handled = Set<String>()
        while true {
            try check()
            let parsed = try SSHConfiguration(documents: documents, root: root, includes: bindings)
            let pending = parsed.includeRequests.filter { !handled.contains($0.document + ":" + String($0.line)) }
            guard !pending.isEmpty else {
                let profiles = try parsed.profiles(defaultUser: defaultUser)
                try check()
                return .init(configuration: parsed, profiles: profiles, selected: selected,
                             authority: authority, sshDirectory: sshDirectory, observations: observations)
            }
            for request in pending {
                guard handled.count < 256 else { throw SSHSelectedFileFailure.capacity }
                handled.insert(request.document + ":" + String(request.line))
                do {
                    guard let anchor else { throw SSHSelectedFileFailure.unavailable }
                    var ids: [String] = []
                    for pattern in request.patterns {
                        try check()
                        // Include token/environment expansion is not assumed.
                        guard !pattern.contains("%"), !pattern.contains("$"), !pattern.utf8.contains(0) else { throw SSHSelectedFileFailure.unsupported }
                        let absolute: String
                        if pattern.hasPrefix("~/") { absolute = (base as NSString).deletingLastPathComponent + String(pattern.dropFirst()) }
                        else if pattern.hasPrefix("~") { throw SSHSelectedFileFailure.unsupported }
                        else { absolute = pattern.hasPrefix("/") ? pattern : base + "/" + pattern }
                        let components = try relative(absolute).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                        guard components.count <= 32, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else { throw SSHSelectedFileFailure.invalidSelection }
                        var candidates = [String]()
                        func expand(_ prefix: String, _ index: Int) throws {
                            try check(); guard candidates.count <= 32 else { throw SSHSelectedFileFailure.capacity }
                            if index == components.count { candidates.append(prefix); return }
                            let pattern = components[index]
                            if !pattern.contains("*"), !pattern.contains("?"), !pattern.contains("[") {
                                try expand(prefix.isEmpty ? pattern : prefix + "/" + pattern, index + 1); return
                            }
                            let fd = prefix.isEmpty ? dup(anchor) : try SSHSelectedFile.openRelative(prefix, root: anchor, directory: true)
                            guard fd >= 0, let stream = fdopendir(fd) else { if fd >= 0 { close(fd) }; throw SSHSelectedFileFailure.unavailable }
                            defer { closedir(stream) }
                            var names: [String] = []
                            while true {
                                try check(); errno = 0
                                guard let entry = readdir(stream) else { guard errno == 0 else { throw SSHSelectedFileFailure.unavailable }; break }
                                examined += 1; guard examined <= 4096 else { throw SSHSelectedFileFailure.capacity }
                                let bytes = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: UInt8.self, capacity: 1024) { pointer -> [UInt8] in
                                    Array(UnsafeBufferPointer(start: pointer, count: Int(entry.pointee.d_namlen)))
                                } }
                                guard let name = String(bytes: bytes, encoding: .utf8) else { throw SSHSelectedFileFailure.unsupported }
                                if name == "." || name == ".." { continue }
                                if fnmatch(pattern, name, FNM_PERIOD) == 0 { names.append(name) }
                            }
                            for name in names.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                                try expand(prefix.isEmpty ? name : prefix + "/" + name, index + 1)
                            }
                        }
                        try expand("", 0)
                        for candidate in candidates.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                            let path = (allowed! == "/" ? "" : allowed!) + "/" + candidate
                            let id = try add(path); if !ids.contains(id) { ids.append(id) }
                        }
                    }
                    bindings.append(.init(document: request.document, line: request.line, state: .complete(ids)))
                } catch SSHSelectedFileFailure.stopped { throw SSHSelectedFileFailure.stopped }
                catch SSHSelectedFileFailure.capacity { throw SSHSelectedFileFailure.capacity }
                catch { bindings.append(.init(document: request.document, line: request.line, state: .unavailable)) }
            }
        }
    }
}
