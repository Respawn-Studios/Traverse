#if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION && !MAC_EXPLORER_DISTRIBUTION
import AppKit
import CoreFoundation
import CryptoKit
import Darwin
import ExplorerCore
import FileOperations
@_spi(Qualification) import LocalStorage

// Source-only qualification entry. Main must independently verify the complete
// source/build/signed image and write the private binding and admission markers.
// This in-process check binds those reviewed values to the CURRENT process;
// marker possession alone is not a source-equivalence or signature proof.
private struct GateBEntryFailure: Error, Sendable { let stage: String }

private enum GateBEntryAdmissionIO {
    static let base = DevelopmentFixturePaths.cases
    static let master = "887B77DA-8583-42B1-9055-32B91A60641F"
    static let sourceCase = "15349F93-703A-4F64-8E63-4D4254E9B315"
    static let backendCase = "CD042DC6-2953-498D-8968-F953D0F75332"
    static let entryCase = "7746682D-50C7-49E8-97F8-1CD2E24A9A01"
    static let runnerSHA256 = "853d4c528898dd7e1fa33c689fe0937ec257c23314e13a516ab29b8a0b78750c"
    static let fixtureSHA256 = "05664d3ee117d901b6c5ab9f02d9e35ca6a95cfb4c246bf0acb5eb4ec39f2516"
    static let backendManifestSHA256 = "87f751f7421d1f11496a4d91950c82dffc06ef5fe388086642eb057d5f3374e6"
    static let maximumBytes: UInt64 = 64 << 20
    static let maximumEntries: UInt64 = 1024
    struct Facts: Sendable, Equatable {
        let root: URL, image: URL, imageSHA256: String, manifestSHA256: String
        let rootDevice: UInt64, rootInode: UInt64
    }
    private static func fail(_ stage: String) -> GateBEntryFailure { .init(stage: stage) }
    private static func hex(_ value: Any?) -> String? {
        guard let value = value as? String, value.count == 64,
              value.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return value
    }
    private static func number(_ value: Any?) -> UInt64? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.int64Value >= 0,
              value.stringValue == String(value.uint64Value) else { return nil }
        return value.uint64Value
    }
    private static func approved(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }
    private static func stable(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid
            && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink
            && a.st_size == b.st_size && a.st_blocks == b.st_blocks
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
            && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
            && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func read(_ parent: Int32, _ name: String) throws -> Data {
        let names: Set<String> = ["reservation.json", "gateb-admission.json",
            "gate-b-app-admission.json", "gate-b-source-image-binding.json"]
        guard names.contains(name) else { throw fail("admission-marker-name") }
        var named = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_mode & S_IFMT == S_IFREG, named.st_uid == geteuid(),
              named.st_mode & 0o7777 == 0o600, named.st_nlink == 1,
              named.st_size > 0, named.st_size <= 16 << 10 else {
            throw fail("admission-marker-private-bound")
        }
        let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw fail("admission-marker-open") }
        defer { Darwin.close(fd) }
        var opened = stat(), after = stat(), current = stat()
        guard fstat(fd, &opened) == 0, stable(named, opened) else {
            throw fail("admission-marker-replaced")
        }
        var bytes = Data(count: Int(opened.st_size)), offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes {
                pread(fd, $0.baseAddress!.advanced(by: offset), remaining, off_t(offset))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw fail("admission-marker-read") }
            offset += count
        }
        guard fstat(fd, &after) == 0,
              fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              stable(opened, after), stable(after, current) else {
            throw fail("admission-marker-changed")
        }
        return bytes
    }
    private static func object(_ bytes: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw fail("admission-json")
        }
        return value
    }
    private static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static func imageDigest(_ image: URL) throws -> String {
        let fd = open(image.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw fail("admission-image-open") }
        defer { Darwin.close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & 0o7777 == 0o755,
              before.st_size > 0, before.st_size <= 192 << 20 else {
            throw fail("admission-image-private-bound")
        }
        var digest = SHA256(), offset: off_t = 0
        while offset < before.st_size {
            var buffer = Data(count: min(1 << 20, Int(before.st_size - offset)))
            let count = buffer.withUnsafeMutableBytes {
                pread(fd, $0.baseAddress, $0.count, offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw fail("admission-image-read") }
            digest.update(data: buffer.prefix(count))
            offset += off_t(count)
        }
        guard fstat(fd, &after) == 0, stable(before, after) else {
            throw fail("admission-image-changed")
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func load() throws -> Facts {
        let args = CommandLine.arguments, env = ProcessInfo.processInfo.environment
        guard args.count == 3, args[1] == "--verify-ui",
              args[2] == "--check-security-remote-close",
              !env.keys.contains(where: { $0.hasPrefix("TRAVERSE_GATEB_CHILD_") }),
              let raw = env["MAC_EXPLORER_TEST_ROOT"],
              Bundle.main.bundleIdentifier == "local.macexplorer.development",
              Bundle.main.object(forInfoDictionaryKey: "TraverseVerificationOnly") as? Bool == true,
              Bundle.main.object(forInfoDictionaryKey: "TraverseGateBQualificationOnly") as? Bool == true,
              let image = Bundle.main.executableURL, image.isFileURL,
              image.path.hasPrefix(base.path + "/"),
              image.resolvingSymlinksInPath() == image else {
            throw fail("admission-process-entry")
        }
        let root = URL(fileURLWithPath: raw, isDirectory: true)
        guard root.path == raw, root == root.standardizedFileURL,
              root.resolvingSymlinksInPath() == root,
              root.deletingLastPathComponent() == base,
              let id = UUID(uuidString: root.lastPathComponent),
              id.uuidString == root.lastPathComponent,
              ![sourceCase, backendCase, entryCase].contains(id.uuidString) else {
            throw fail("admission-case-scope")
        }
        // Observe the actual executing process, not merely its bundle metadata.
        var process = proc_bsdinfo()
        let processBytes = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &process,
            Int32(MemoryLayout<proc_bsdinfo>.size))
        var processPath = [CChar](repeating: 0, count: 4096)
        let processPathBytes = processPath.withUnsafeMutableBytes {
            proc_pidpath(getpid(), $0.baseAddress, UInt32($0.count))
        }
        guard processBytes == Int32(MemoryLayout<proc_bsdinfo>.size),
              process.pbi_pid == UInt32(getpid()), process.pbi_uid == geteuid(),
              processPathBytes > 0, processPathBytes < Int32(processPath.count),
              processPath.withUnsafeBufferPointer({ String(cString: $0.baseAddress!) }) == image.path else {
            throw fail("admission-current-process-image")
        }
        var named = stat(), opened = stat(), after = stat(), current = stat()
        guard lstat(root.path, &named) == 0, named.st_mode & S_IFMT == S_IFDIR,
              named.st_uid == geteuid(), named.st_mode & 0o7777 == 0o700 else {
            throw fail("admission-case-private-root")
        }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw fail("admission-case-open") }
        defer { Darwin.close(fd) }
        guard fstat(fd, &opened) == 0, stable(named, opened) else {
            throw fail("admission-case-replaced")
        }
        let reservation = try object(read(fd, "reservation.json"))
        let child = try object(read(fd, "gateb-admission.json"))
        let app = try object(read(fd, "gate-b-app-admission.json"))
        let bindingBytes = try read(fd, "gate-b-source-image-binding.json")
        let binding = try object(bindingBytes)
        let bindingSHA256 = sha256(bindingBytes)
        let childKeys: Set<String> = ["format", "caseUUID", "runtimeApproved",
            "reviewedExecutablePath", "reviewedExecutableSHA256", "rootDevice",
            "rootInode", "rootUID", "rootMode", "maximumLogicalBytes",
            "maximumAllocatedBytes", "maximumEntries", "maximumSeconds",
            "maximumRSSMiB", "maximumPinChildSeconds", "maximumRemoveChildSeconds"]
        let appKeys: Set<String> = ["schema", "caseUUID", "sourceCase", "sourceImageManifestSHA256",
            "runtimeApproved", "reviewedExecutablePath", "reviewedExecutableSHA256",
            "rootDevice", "rootInode", "rootUID", "rootMode", "maximumLogicalBytes",
            "maximumAllocatedBytes", "maximumEntries", "maximumSeconds", "maximumRSSMiB"]
        let bindingKeys: Set<String> = ["format", "sourceCase", "runnerSHA256",
            "fixtureFactorySHA256", "backendCase", "backendManifestSHA256",
            "entryCase", "entryPacketManifestSHA256", "buildSourceReceiptSHA256",
            "imagePreparationReceiptSHA256", "codeEquivalenceReceiptSHA256",
            "reviewedExecutablePath", "reviewedExecutableSHA256"]
        guard Set(reservation.keys) == Set(["packet", "action", "master"]),
              reservation["packet"] as? String == "traverse-development-v1",
              reservation["action"] as? String == "gateb-application-runtime-v1",
              reservation["master"] as? String == master,
              Set(child.keys) == childKeys, Set(app.keys) == appKeys,
              Set(binding.keys) == bindingKeys,
              child["format"] as? String == "traverse-gateb-child-admission-v1",
              app["schema"] as? String == "traverse.gateb.native-close.v1",
              binding["format"] as? String == "traverse-gateb-source-image-binding-v1",
              child["caseUUID"] as? String == id.uuidString,
              app["caseUUID"] as? String == id.uuidString,
              approved(child["runtimeApproved"]), approved(app["runtimeApproved"]),
              child["reviewedExecutablePath"] as? String == image.path,
              app["reviewedExecutablePath"] as? String == image.path,
              binding["reviewedExecutablePath"] as? String == image.path,
              let imageSHA256 = hex(child["reviewedExecutableSHA256"]),
              app["reviewedExecutableSHA256"] as? String == imageSHA256,
              binding["reviewedExecutableSHA256"] as? String == imageSHA256,
              number(child["rootDevice"]) == UInt64(truncatingIfNeeded: opened.st_dev),
              number(app["rootDevice"]) == UInt64(truncatingIfNeeded: opened.st_dev),
              number(child["rootInode"]) == UInt64(opened.st_ino),
              number(app["rootInode"]) == UInt64(opened.st_ino),
              number(child["rootUID"]) == UInt64(geteuid()),
              number(app["rootUID"]) == UInt64(geteuid()),
              number(child["rootMode"]) == 0o700, number(app["rootMode"]) == 0o700,
              number(child["maximumLogicalBytes"]) == maximumBytes,
              number(child["maximumAllocatedBytes"]) == maximumBytes,
              number(app["maximumLogicalBytes"]) == maximumBytes,
              number(app["maximumAllocatedBytes"]) == maximumBytes,
              number(child["maximumEntries"]) == maximumEntries,
              number(app["maximumEntries"]) == maximumEntries,
              number(child["maximumSeconds"]) == 120,
              number(app["maximumSeconds"]) == 120,
              number(child["maximumRSSMiB"]) == 384,
              number(app["maximumRSSMiB"]) == 384,
              number(child["maximumPinChildSeconds"]) == 5,
              number(child["maximumRemoveChildSeconds"]) == 12,
              app["sourceCase"] as? String == sourceCase,
              app["sourceImageManifestSHA256"] as? String == bindingSHA256,
              binding["sourceCase"] as? String == sourceCase,
              binding["runnerSHA256"] as? String == runnerSHA256,
              binding["fixtureFactorySHA256"] as? String == fixtureSHA256,
              binding["backendCase"] as? String == backendCase,
              binding["backendManifestSHA256"] as? String == backendManifestSHA256,
              binding["entryCase"] as? String == entryCase,
              hex(binding["entryPacketManifestSHA256"]) != nil,
              hex(binding["buildSourceReceiptSHA256"]) != nil,
              hex(binding["imagePreparationReceiptSHA256"]) != nil,
              hex(binding["codeEquivalenceReceiptSHA256"]) != nil,
              try imageDigest(image) == imageSHA256,
              fstat(fd, &after) == 0, lstat(root.path, &current) == 0,
              stable(opened, after), stable(after, current) else {
            throw fail("admission-case-image-or-source-binding")
        }
        return .init(root: root, image: image, imageSHA256: imageSHA256,
            manifestSHA256: bindingSHA256,
            rootDevice: UInt64(truncatingIfNeeded: opened.st_dev), rootInode: UInt64(opened.st_ino))
    }
}

@MainActor private final class GateBReviewedEntryImageOwner: GateBReviewedEntryImageAdmission {
    let generatedCaseURL: URL, sourceImageManifestSHA256: String
    private let facts: GateBEntryAdmissionIO.Facts
    private init(_ facts: GateBEntryAdmissionIO.Facts) {
        self.facts = facts
        generatedCaseURL = facts.root
        sourceImageManifestSHA256 = facts.manifestSHA256
    }
    static func admit() async throws -> GateBReviewedEntryImageOwner {
        guard !RemoteTextEditorFeature.ordinaryEnabled else {
            throw GateBEntryFailure(stage: "ordinary-remote-editor-enabled")
        }
        let facts = try await Task.detached(priority: .userInitiated) {
            try GateBEntryAdmissionIO.load()
        }.value
        return .init(facts)
    }
    func requireCurrentEntryAndImage() async throws {
        guard !RemoteTextEditorFeature.ordinaryEnabled else {
            throw GateBEntryFailure(stage: "ordinary-remote-editor-enabled")
        }
        let current = try await Task.detached(priority: .userInitiated) {
            try GateBEntryAdmissionIO.load()
        }.value
        guard current == facts else { throw GateBEntryFailure(stage: "admission-entry-changed") }
    }
}

@MainActor enum GateBApplicationEntryVerification {
    private static func closedStage(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.count <= 96,
              value.allSatisfy({ "abcdefghijklmnopqrstuvwxyz0123456789-".contains($0) }) else {
            return "runner-stage-unavailable"
        }
        return value
    }
    private static func resultFields(_ result: GateBApplicationResult) -> (String, String, [String: Any]) {
        let allowed = Set(["saved", "refused", "threw", "publishedNeedsReload", "uncertain"])
        let allowedCleanup = Set([
            "owned-failure-hold-release-incomplete", "actual-backend-drain-incomplete",
            "actual-app-fixture-drain-incomplete", "actual-backend-owner-still-pending",
            "cannot-dispose-generated-surface-with-live-remote-owner",
            "generated-native-surface-disposal-incomplete",
            "actual-final-resource-observation-unavailable",
            "final-native-close-callback-count"
        ])
        let runnerStage = result.failureStage.map { closedStage($0) } ?? "none"
        let cleanupStages = result.cleanupFailureStages
        guard cleanupStages.count <= 5, Set(cleanupStages).count == cleanupStages.count,
              cleanupStages.allSatisfy(allowedCleanup.contains),
              runnerStage == "none" || runnerStage == closedStage(runnerStage), (0...8).contains(result.nativeCloseAtFirstPinDrain),
              (0...8).contains(result.nativeCloseCallbacks),
              (0...64).contains(result.inputEvents),
              (0...2).contains(result.copyPublishEntries),
              result.copyResults.count <= 2, result.copyResults.allSatisfy(allowed.contains),
              result.checks.count <= 6 else {
            return ("FAILED", "invalid-runner-receipt", [:])
        }
        let fields: [String: Any] = ["nativeCloseAtFirstPinDrain": result.nativeCloseAtFirstPinDrain,
            "nativeCloseCallbacks": result.nativeCloseCallbacks,
            "inputEvents": result.inputEvents, "copyPublishEntries": result.copyPublishEntries,
            "copyResults": result.copyResults, "checksCount": result.checks.count,
            "removal": result.removal?.rawValue ?? "none",
            "runnerStage": runnerStage, "cleanupStages": cleanupStages]
        if result.status == "PASS" {
            guard runnerStage == "none", cleanupStages.isEmpty, result.checks.count == 6,
                  result.nativeCloseAtFirstPinDrain == 1,
                  (2...8).contains(result.nativeCloseCallbacks), result.inputEvents == 0,
                  result.copyPublishEntries == 2, result.copyResults.count == 2,
                  ["saved", "refused", "threw"].contains(result.copyResults[0]),
                  result.copyResults[1] == "saved", result.removal != nil else {
                return ("FAILED", "invalid-passing-runner-receipt", fields)
            }
            return ("PASS", "none", fields)
        }
        // The first runner refusal is primary; independent cleanup failures
        // remain in fixed, bounded fields even when later admission drifts.
        let primary = runnerStage != "none" ? runnerStage :
            (cleanupStages.first ?? "runner-stage-unavailable")
        return ("FAILED", primary, fields)
    }
    static func run() async {
        var status = "FAILED", stage = "admission-refused"
        var fields: [String: Any] = [:]
        var bindingSHA256 = "none"
        do {
            let admission = try await GateBReviewedEntryImageOwner.admit()
            // The reviewed native menu control requires a foreground key window.
            NSApplication.shared.activate(ignoringOtherApps: true)
            bindingSHA256 = admission.sourceImageManifestSHA256
            stage = "backend-factory-refused"
            let backend = try await GateBGeneratedBackendFactory.make(validatedEntry: admission)
            do {
                // This generated unsandboxed case supplies no bookmark lease;
                // retaining an empty lifetime does not synthesize OS access.
                let fixture = try await GateBApplicationFixtureFactory.make(
                    validatedEntry: admission, retainingGeneratedAccess: FileAccessLifetimes(leases: []))
                // The reviewed runner joins BOTH returned owners on every
                // success and failure. Do not manufacture a nil dependency.
                let receipt = await GateBApplicationVerification.run(backend: backend, fixture: fixture)
                (status, stage, fields) = resultFields(receipt)
                do { try await admission.requireCurrentEntryAndImage() }
                catch { status = "FAILED"; stage = "post-run-admission-drift" }
            } catch {
                stage = "fixture-factory-refused"
                // The fixture factory owns its partial cleanup. This returned
                // backend is still ours and must be joined independently.
                do { try await backend.closeAndDrain() }
                catch { stage = "backend-drain-after-fixture-refusal-incomplete" }
            }
        } catch let failure as GateBEntryFailure { stage = failure.stage }
        catch let failure as GateBGeneratedFailure { stage = closedStage(failure.stage) }
        catch let failure as GateBGeneratedAdapterFailure { stage = closedStage(failure.stage) }
        catch { /* The selected closed stage already names the failed boundary. */ }
        let output: [String: Any] = ["format": "traverse-gateb-app-entry-v2",
            "status": status, "stage": stage, "sourceCase": GateBEntryAdmissionIO.sourceCase,
            "backendCase": GateBEntryAdmissionIO.backendCase,
            "entryCase": GateBEntryAdmissionIO.entryCase,
            "sourceImageManifestSHA256": bindingSHA256,
            "ordinaryRemoteEditing": RemoteTextEditorFeature.ordinaryEnabled,
            "externalProcessDrain": "NOT EXERCISED BY APP",
            "observations": fields]
        guard let bytes = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]),
              bytes.count <= 4096, let line = String(data: bytes, encoding: .utf8) else {
            fputs("TRAVERSE_GATEB_CLOSED_OUTPUT_REFUSED\n", stderr)
            Darwin.exit(71)
        }
        print(line)
        fflush(stdout)
        Darwin.exit(status == "PASS" ? 0 : 71)
    }
}
#endif
