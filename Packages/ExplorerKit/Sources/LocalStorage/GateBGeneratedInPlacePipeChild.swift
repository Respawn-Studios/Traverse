#if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
// Generated offline worker fixture. The App enters this exact child BEFORE
// NSApplication; the parent uses its real SFTPProcessOwner/pipe and bounded
// lifetime. It supplies no SSH, host-security or server proof.
import CryptoKit
import Darwin
import Foundation

/// Fixed qualification-only exit codes. The parent reads these after owned drain.
/// No host, path, body, or exception text enters the App result.
enum GateBInPlaceChildExit {
    static let known: [Int32: String] = [
        71: "child-app-guard-or-unclassified",
        72: "child-arguments", 73: "child-test-root", 74: "child-case-id",
        75: "child-admission-unclassified", 76: "child-admission-root-mismatch",
        77: "child-socket-kind", 78: "child-socket-nonblocking",
        79: "child-wire", 80: "child-deadline", 81: "child-scope",
        82: "child-unexpected",
        100: "child-admission-json",
        101: "child-admission-marker-changed",
        102: "child-admission-marker-kind",
        103: "child-admission-marker-open",
        104: "child-admission-marker-read",
        105: "child-admission-marker-replaced",
        106: "child-admission-work-expired",
        107: "child-case-admission-fields",
        108: "child-case-directory-changed",
        109: "child-case-directory-mode",
        110: "child-case-directory-open",
        111: "child-case-directory-replaced",
        112: "child-case-entry-unsafe",
        113: "child-case-link-or-special",
        114: "child-case-path",
        115: "child-case-resource-limit",
        116: "child-case-root-changed",
        117: "child-case-root-kind",
        118: "child-case-root-open",
        119: "child-case-root-replaced",
        120: "child-deadline-expired-or-extended",
        121: "child-image-changed",
        122: "child-image-kind-or-bound",
        123: "child-image-open",
        124: "child-image-read",
        125: "child-parent-clock",
        126: "child-parent-image-or-case",
        127: "child-parent-input",
        128: "child-parent-release-byte",
        129: "child-parent-release-expired",
        130: "child-parent-release-pipe",
        131: "child-parent-release-poll",
        132: "child-parent-witness",
        133: "child-reviewed-image-root-or-parent",
        134: "child-parent-required-key-missing",
        135: "child-parent-extra-key",
        136: "child-parent-locale",
        137: "child-parent-case",
        138: "child-parent-numeric-parse",
        139: "child-parent-duration",
        140: "child-parent-identity",
        141: "child-parent-birth-range",
    ]
    static func code(for stage: String) -> Int32? {
        known.first(where: { $0.value == stage })?.key
    }
    static func stage(for code: Int32) -> String? { known[code] }
}

@_spi(Qualification) public enum GateBGeneratedInPlacePipeChild {
    public static func runOrExit() -> Never {
        let args = CommandLine.arguments
        guard args.count == 3, args[1] == "--sftp-inplace-v1-pipe-child",
              args[2] == SFTPInPlacePipeScenario.success.rawValue,
              Bundle.main.bundleIdentifier == "local.macexplorer.development",
              Bundle.main.executableURL?.path.contains("/.build/traverse-development/") == true else { exit(72) }
        guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(73) }
        let root = URL(fileURLWithPath: raw, isDirectory: true)
        guard let caseID = UUID(uuidString: root.lastPathComponent),
              caseID.uuidString == root.lastPathComponent else { exit(74) }
        let admission: (root: URL, facts: stat, deadline: TimeInterval)
        do { admission = try GateBGeneratedChildAdmission.requireChild(caseID: caseID,
            maximumSeconds: 60) }
        catch let failure as GateBGeneratedFailure {
            exit(GateBInPlaceChildExit.code(for: failure.stage) ?? 75)
        }
        catch { exit(75) }
        guard admission.root == root else { exit(76) }
        var kind: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(3, SOL_SOCKET, SO_TYPE, &kind, &size) == 0,
              kind == SOCK_STREAM, size == MemoryLayout<Int32>.size else { exit(77) }
        let flags = fcntl(3, F_GETFL)
        guard flags >= 0, fcntl(3, F_SETFL, flags | O_NONBLOCK) == 0 else { exit(78) }
        do { try GeneratedInPlacePipeChild(scenario: .success,
            deadline: admission.deadline).run(); exit(0) }
        catch InPlacePipeFailure.wire { exit(79) }
        catch InPlacePipeFailure.deadline { exit(80) }
        catch InPlacePipeFailure.scope { exit(81) }
        catch { exit(82) }
    }
}

enum InPlacePipeFailure: Error { case scope, wire, deadline }
final class GeneratedInPlacePipeChild {
    private let descriptor: Int32 = 3, scenario: SFTPInPlacePipeScenario
    private var session: UUID?, incoming: UInt64 = 0, outgoing: UInt64 = 0
    private var generation: UUID?, body = Data("before\n".utf8), directory = "/generated"
    private var transfers: UInt8 = 0, fresh: [String: Data] = [:]
    private var baselines: [UUID: UInt64] = [:], preparedFolder: UUID?
    private let processDeadline: TimeInterval
    private var inboundBytes = 0, outboundBytes = 0
    private let uid = UInt32(getuid()), gid = UInt32(getgid())
    init(scenario: SFTPInPlacePipeScenario, deadline: TimeInterval) {
        self.scenario = scenario; processDeadline = deadline
    }
    private func need(_ value: Bool) throws { if !value { throw InPlacePipeFailure.wire } }
    private func read(_ count: Int) throws -> Data {
        var bytes = Data(count: count), offset = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while offset < count {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  ProcessInfo.processInfo.systemUptime < processDeadline else { throw InPlacePipeFailure.deadline }
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 20)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw InPlacePipeFailure.wire }
            if ready == 0 { continue }
            let found = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset) }
            if found < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard found > 0 else { throw InPlacePipeFailure.wire }; offset += found
        }
        return bytes
    }
    private func command() throws -> (UInt8, Data) {
        var size = SFTPCursor(try read(4)); let count = try size.number(4)
        guard (33...65536).contains(count), incoming < 128,
              inboundBytes <= (1 << 20) - 4 - Int(count) else { throw InPlacePipeFailure.wire }
        inboundBytes += 4 + Int(count)
        let bytes = try read(Int(count)); var c = SFTPCursor(bytes)
        try need(try c.take(8) == Data("MEXSFTPM".utf8))
        let actual = try c.token()
        if let session { try need(session == actual) } else { session = actual }
        try need(try c.number(8) == incoming); incoming += 1
        let kind = try c.number(1); return (UInt8(kind), try c.take(bytes.count - 33))
    }
    private func emit(_ kind: UInt8, _ payload: Data = Data()) throws {
        guard let session else { throw InPlacePipeFailure.wire }
        var bytes = try SFTPWire.body(session: session, sequence: outgoing, kind: kind, mode: .inPlaceEditCatalog)
        bytes.append(payload); let frame = try SFTPWire.frame(bytes)
        guard outgoing < 128, frame.count <= 65540,
              outboundBytes <= (1 << 20) - frame.count else { throw InPlacePipeFailure.wire }
        outgoing += 1; outboundBytes += frame.count
        var offset = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while offset < frame.count {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  ProcessInfo.processInfo.systemUptime < processDeadline else { throw InPlacePipeFailure.deadline }
            var item = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&item, 1, 20)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw InPlacePipeFailure.wire }
            if ready == 0 { continue }
            let found = frame.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), frame.count - offset) }
            if found < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard found > 0 else { throw InPlacePipeFailure.wire }; offset += found
        }
    }
    private func end() throws {
        var bytes = Data([0, 0, 1]); SFTPWire.number(1, bytes: 8, into: &bytes)
        SFTPWire.number(0, bytes: 8, into: &bytes); bytes.append(1)
        try emit(107, bytes); _ = shutdown(descriptor, SHUT_WR)
    }
    private func attrs(size: UInt64) -> Data {
        var bytes = Data()
        for (value, count) in [(size, 8), (77, 4), (0o100600, 4), (UInt64(uid), 4), (UInt64(gid), 4)] {
            SFTPWire.number(value, bytes: count, into: &bytes)
        }
        return bytes
    }
    private func snapshot(_ revision: UInt64, complete: Bool) -> Data {
        var bytes = Data()
        for value in [UInt64(1), revision, complete ? (transfers & 2 != 0 ? 2 : 1) : 0, UInt64(0)] { SFTPWire.number(value, bytes: 8, into: &bytes) }
        bytes.append(complete ? 1 : 0); return bytes
    }
    private func first(_ bytes: Data) throws {
        var c = SFTPCursor(bytes)
        try need(try c.text(cap: 253) == "generated.example")
        try need(try c.text(cap: 253) == "127.0.0.1")
        try need(try c.number(2) == 22); try need(try c.number(4) == 0)
        try need(try c.field(cap: 16384).isEmpty)
        _ = try c.text(cap: 8192)
        try need(try c.number(8) == 480 << 20); try need(try c.take(3) == Data([3, 7, 1])); transfers = UInt8(try c.number(1)); try need([UInt8(0), 1, 3, 7, 15].contains(transfers) && c.finished)
        var key = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &key)
        try SFTPWire.field(Data(repeating: 1, count: 32), into: &key)
        var challenge = Data([1]); try SFTPWire.field(Data("generated.example".utf8), into: &challenge)
        SFTPWire.number(22, bytes: 2, into: &challenge); try SFTPWire.field(key, into: &challenge)
        try emit(200, Data([3, 7, 1, transfers]))
        try SFTPWire.field(Data(), into: &challenge); try emit(100, challenge)
    }
    private func readInPlace(_ bytes: Data) throws -> Bool {
        var c = SFTPCursor(bytes); let request = try c.token(), selected = try c.token()
        try need(selected == generation && baselines.count < 2)
        try need(try c.number(8) == 1); try need(try c.number(8) == 1 && c.finished)
        var header = SFTPWire.token(request); header.append(SFTPWire.token(selected)); header.append(attrs(size: UInt64(body.count)))
        try SFTPWire.field(Data("/generated/file.txt".utf8), into: &header); try emit(190, header)
        if !body.isEmpty {
            var chunk = SFTPWire.token(request); SFTPWire.number(0, bytes: 8, into: &chunk)
            try SFTPWire.field(body, into: &chunk); try emit(191, chunk)
        }
        let digest = Data(SHA256.hash(data: body))
        var seal = SFTPWire.token(request); seal.append(digest); SFTPWire.number(UInt64(body.count), bytes: 8, into: &seal)
        try emit(192, seal)
        let reply = try command()
        if reply.0 == 6 { try end(); return false }
        try need(reply.0 == 51 && reply.1 == SFTPWire.token(request) + digest)
        let token = UUID(); baselines[token] = 1
        var admitted = SFTPWire.token(request)
        admitted.append(SFTPWire.token(token)); SFTPWire.number(1, bytes: 8, into: &admitted); admitted.append(digest)
        admitted.append(contentsOf: [1, 1, scenario == .badRWAdmission ? 0 : 1]); try emit(193, admitted); return true
    }
    private func saveInPlace(_ bytes: Data) throws -> Bool {
        var c = SFTPCursor(bytes); let request = try c.token(), token = try c.token(), revision = try c.number(8)
        let editor = try c.token(), size = try c.number(8), digest = try c.take(32)
        try need(c.finished && baselines[token] == revision && size <= 1 << 20); baselines.removeValue(forKey: token)
        let plan = try SFTPInPlaceStep.plan(old: UInt64(body.count), new: size)
        var edited = Data(), offset: UInt64 = 0
        while offset < size {
            let count = min(32768, size - offset); var source = SFTPWire.token(request)
            SFTPWire.number(offset, bytes: 8, into: &source); SFTPWire.number(count, bytes: 4, into: &source); try emit(194, source)
            let reply = try command(); if reply.0 == 6 { try end(); return false }; try need(reply.0 == 53)
            var response = SFTPCursor(reply.1); try need(try response.token() == request); try need(try response.number(8) == offset)
            let part = try response.field(cap: 32768); try need(response.finished && UInt64(part.count) == count); edited.append(part); offset += count
        }
        try need(Data(SHA256.hash(data: edited)) == digest)
        for step in plan {
            var payload = SFTPWire.token(request)
            if scenario == .invalidStep && step.kind == .write {
                SFTPInPlaceStep(sequence: step.sequence, kind: step.kind, offset: step.offset + 1, count: step.count).append(to: &payload)
            } else { step.append(to: &payload) }
            payload.append(digest); try emit(195, payload)
            let reply = try command(); if reply.0 == 6 { try end(); return false }; try need(reply.0 == 54 && reply.1 == payload)
            switch step.kind {
            case .write:
                let endOffset = Int(step.offset) + Int(step.count); if endOffset > body.count { body.append(Data(repeating: 0, count: endOffset - body.count)) }
                body.replaceSubrange(Int(step.offset)..<endOffset, with: edited[Int(step.offset)..<endOffset])
                if scenario == .interruptedWrite {
                    var failure = SFTPWire.token(request); failure.append(contentsOf: [3, step.sequence, step.sequence - 1, 1]); SFTPWire.number(0, bytes: 4, into: &failure)
                    try emit(198, failure); try end(); return false
                }
            case .truncate: body = Data(body.prefix(Int(size)))
            default: break
            }
            var observed = SFTPWire.token(request); step.append(to: &observed); try emit(196, observed)
        }
        try need(body == edited)
        if scenario == .lostSave { try end(); return false }
        let next = UUID(); baselines[next] = revision + 1
        var completed = SFTPWire.token(request); completed.append(SFTPWire.token(scenario == .wrongGeneration ? UUID() : editor)); completed.append(SFTPWire.token(next))
        SFTPWire.number(revision + 1, bytes: 8, into: &completed); SFTPWire.number(size, bytes: 8, into: &completed)
        completed.append(digest); completed.append(attrs(size: size)); completed.append(contentsOf: [UInt8(plan.count), UInt8(plan.count), 1, 1, 1, 1]); try emit(197, completed); return true
    }
    private func folder(_ bytes: Data) throws {
        try need(transfers & 2 != 0 && preparedFolder == nil); var c = SFTPCursor(bytes)
        let request = try c.token(), selected = try c.token(), read = try c.number(8), revision = try c.number(8), observation = try c.number(8)
        try need(c.finished && selected == generation && read == 1 && revision == 1 && observation == 2)
        var started = SFTPWire.token(request); started.append(SFTPWire.token(selected))
        for n in [read, revision, observation] { SFTPWire.number(n, bytes: 8, into: &started) }; try emit(150, started)
        var node = SFTPWire.token(request); SFTPWire.number(0, bytes: 4, into: &node); node.append(contentsOf: [0, 0]); SFTPWire.number(0, bytes: 8, into: &node); SFTPWire.number(77, bytes: 4, into: &node); SFTPWire.number(0o040700, bytes: 4, into: &node); try emit(152, node)
        var complete = SFTPWire.token(request)
        for n in [UInt64(1), 0, 0] { SFTPWire.number(n, bytes: 4, into: &complete) }; SFTPWire.number(0, bytes: 8, into: &complete); SFTPWire.number(0, bytes: 4, into: &complete)
        try emit(153, complete); preparedFolder = request
    }
    private func download(_ bytes: Data) throws -> Bool {
        try need(transfers & 1 != 0); var c = SFTPCursor(bytes); let request = try c.token(), selected = try c.token(), observation = try c.number(8)
        try need(c.finished && selected == generation && observation == 1)
        let contents = directory == "/generated" ? body : Data("other!\n".utf8)
        var header = SFTPWire.token(request); header.append(SFTPWire.token(selected)); SFTPWire.number(observation, bytes: 8, into: &header)
        SFTPWire.number(UInt64(contents.count), bytes: 8, into: &header); SFTPWire.number(77, bytes: 4, into: &header); SFTPWire.number(0o100600, bytes: 4, into: &header)
        try SFTPWire.field(Data("file.txt".utf8), into: &header); try emit(120, header)
        var chunk = SFTPWire.token(request); SFTPWire.number(0, bytes: 8, into: &chunk)
        if scenario == .heldDownload || scenario == .transferEOF {
            try SFTPWire.field(Data(contents.prefix(3)), into: &chunk); try emit(121, chunk)
            if scenario == .heldDownload { let stop = try command(); try need(stop.0 == 6) }; try end(); return false
        }
        try SFTPWire.field(contents, into: &chunk); try emit(121, chunk)
        var complete = SFTPWire.token(request); SFTPWire.number(UInt64(contents.count), bytes: 8, into: &complete); complete.append(contentsOf: [1, 1]); try emit(122, complete); return true
    }
    private func upload(_ bytes: Data) throws -> Bool {
        try need(transfers & 4 != 0); var c = SFTPCursor(bytes)
        let request = try c.token(), selected = try c.token(), revision = try c.number(8), name = try c.text(cap: 255), size = try c.number(8)
        try need(c.finished && selected == generation && revision == 1 && size <= 1 << 20 && name != "file.txt")
        let path = directory + "/" + name; try need(fresh[path] == nil)
        var header = SFTPWire.token(request); header.append(SFTPWire.token(selected)); SFTPWire.number(size, bytes: 8, into: &header)
        try SFTPWire.field(Data(), into: &header); try SFTPWire.field(Data(path.utf8), into: &header); try emit(130, header)
        var contents = Data(), offset: UInt64 = 0
        while offset < size {
            let count = min(32768, size - offset); var source = SFTPWire.token(request); SFTPWire.number(offset, bytes: 8, into: &source); SFTPWire.number(count, bytes: 4, into: &source); try emit(131, source)
            let reply = try command(); if reply.0 == 6 { try end(); return false }; try need(reply.0 == 10)
            var value = SFTPCursor(reply.1); try need(try value.token() == request); try need(try value.number(8) == offset)
            let part = try value.field(cap: 32768); try need(value.finished && part.count == count); contents.append(part); offset += count
        }
        let digest = Data(SHA256.hash(data: contents)); var permission = SFTPWire.token(request); SFTPWire.number(size, bytes: 8, into: &permission); permission.append(digest); try emit(132, permission)
        let reply = try command(); if reply.0 == 6 { try end(); return false }; try need(reply.0 == 11 && reply.1 == SFTPWire.token(request) + digest)
        fresh[path] = contents
        var complete = SFTPWire.token(request); SFTPWire.number(size, bytes: 8, into: &complete); complete.append(digest); complete.append(contentsOf: [1, 1, 1, 1]); try emit(133, complete); return true
    }
    func run() throws {
        defer { Darwin.close(descriptor) }
        while true {
            let (kind, bytes) = try command()
            switch kind {
            case 1: try first(bytes)
            case 2: try emit(101)
            case 3: try emit(102); try emit(109)
            case 30: try need(bytes == Data([1])); try emit(169, Data([1]))
            case 4:
                var c = SFTPCursor(bytes); let id = try c.token(); let path = try c.text(cap: 8192); try need(c.finished && ["/generated", "/elsewhere"].contains(path)); generation = id; self.directory = path
                var directory = SFTPWire.token(id); try SFTPWire.field(Data(path.utf8), into: &directory); directory.append(snapshot(0, complete: false)); try emit(110, directory)
            case 5:
                var c = SFTPCursor(bytes); let id = try c.token(); try need(c.finished && id == generation)
                try emit(111, SFTPWire.token(id) + snapshot(1, complete: true))
            case 7:
                var c = SFTPCursor(bytes)
                let request = try c.token(), selected = try c.token(), revision = try c.number(8)
                let offset = try c.number(8), limit = try c.number(2)
                let sort = try c.number(1), descending = try c.number(1)
                try need(c.finished && selected == generation && directory == "/generated"
                    && revision == 1 && offset == 0 && limit == 256 && sort == 0 && descending == 0)
                var started = SFTPWire.token(request); started.append(SFTPWire.token(selected))
                started.append(snapshot(1, complete: true)); SFTPWire.number(offset, bytes: 8, into: &started)
                try emit(114, started)
                var row = SFTPWire.token(request); SFTPWire.number(1, bytes: 8, into: &row)
                row.append(7)
                SFTPWire.number(UInt64(body.count), bytes: 8, into: &row)
                SFTPWire.number(77, bytes: 4, into: &row)
                SFTPWire.number(0o100600, bytes: 4, into: &row)
                try SFTPWire.field(Data("file.txt".utf8), into: &row)
                try emit(115, row)
                var complete = SFTPWire.token(request); SFTPWire.number(1, bytes: 4, into: &complete)
                try emit(116, complete)
            case 20: try folder(bytes)
            case 22:
                var c = SFTPCursor(bytes); let request = try c.token(); try need(c.finished && request == preparedFolder); preparedFolder = nil; try emit(159, SFTPWire.token(request))
            case 8: if try download(bytes) == false { return }
            case 9: if try upload(bytes) == false { return }
            case 50: if try readInPlace(bytes) == false { return }
            case 52: if try saveInPlace(bytes) == false { return }
            case 58:
                var c = SFTPCursor(bytes); let request = try c.token(), token = try c.token(), revision = try c.number(8)
                try need(c.finished && baselines[token] == revision); baselines.removeValue(forKey: token)
                if scenario == .lostRelease { try end(); return }
                var release = SFTPWire.token(request); release.append(SFTPWire.token(token)); SFTPWire.number(revision, bytes: 8, into: &release); release.append(contentsOf: [1, 1, 1])
                try emit(199, release)
            case 6: try end(); return
            default: throw InPlacePipeFailure.wire
            }
        }
    }
}
#endif
