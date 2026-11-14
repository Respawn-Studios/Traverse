#if DEBUG
import AppKit
@_spi(Qualification) import LocalStorage

/// Exact generated namespace only. No personal credential enumeration or reads.
@MainActor enum SMBPasswordVerification {
    static func run(root: URL, phase: String) async throws -> [String: Any] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b10-network-reader"),
              root.resolvingSymlinksInPath() == root, let namespace = UUID(uuidString: root.lastPathComponent),
              namespace.uuidString == root.lastPathComponent, ["first", "reopen", "cleanup"].contains(phase) else {
            throw UIVerification.Failure(message: "Keychain qualification requires its exact generated packet")
        }
        let binding = try SMBCredentialBinding(host: "127.0.0.1", port: 15445, share: "ExplorerQA", account: "generated-only", domain: "")
        let store = SMBPasswordVault.generatedQualification(namespace: namespace)
        let referenceURL = root.appendingPathComponent("evidence/credential-reference.json")
        let reference: SMBCredentialReference
        if phase == "first" {
            reference = SMBCredentialReference(binding: binding)
            // Claim the non-secret reference before the first Keychain mutation.
            try JSONEncoder().encode(reference).write(to: referenceURL, options: .withoutOverwriting)
        } else { reference = try JSONDecoder().decode(SMBCredentialReference.self, from: Data(contentsOf: referenceURL)) }
        do {
            if phase == "cleanup" {
                _ = try await store.remove(reference, binding: binding)
                await store.drain()
                return ["passed": true, "phase": phase, "namespace": namespace.uuidString, "exactGeneratedEntryRemoved": true]
            }
            let passwords = try await Task.detached { try readPrivateInput() }.value
            var checks: [String] = []
            if phase == "first" {
                _ = try await store.save(passwords.0, reference: reference, binding: binding)
                let first = try await store.password(reference, binding: binding)
                try require(equal(first, passwords.0), "Generated Keychain initial round trip differs")
                _ = try await store.save(passwords.1, reference: reference, binding: binding)
                let second = try await store.password(reference, binding: binding)
                try require(equal(second, passwords.1), "Generated Keychain update differs")
                let wrong = try SMBCredentialBinding(host: "127.0.0.1", port: 15446, share: "ExplorerQA", account: "generated-only", domain: "")
                do { _ = try await store.password(reference, binding: wrong); throw UIVerification.Failure(message: "Endpoint mismatch reused a credential") }
                catch SMBPasswordFailure.bindingMismatch { }
                checks = ["Signed-app add/read/update", "Different endpoint refused before Keychain", "Password kept only in private input and owned Keychain entry"]
            } else {
                let reopened = try await store.password(reference, binding: binding)
                try require(equal(reopened, passwords.1), "Generated Keychain reopen differs")
                _ = try await store.remove(reference, binding: binding)
                do { _ = try await store.password(reference, binding: binding); throw UIVerification.Failure(message: "Deleted generated password remains available") }
                catch SMBPasswordFailure.missing { }
                _ = try await store.remove(reference, binding: binding)
                checks = ["Same signed app reopens exact generated entry", "Delete verified by fresh missing read", "Repeated exact deletion is harmless"]
            }
            await store.drain()
            return ["passed": true, "phase": phase, "namespace": namespace.uuidString, "checks": checks,
                    "generatedEntries": 1, "personalCredentialQueries": 0, "backend": "explicit file/login Keychain"]
        } catch {
            await store.drain()
            var cleanup = false
            do { _ = try await store.remove(reference, binding: binding); await store.drain(); cleanup = true } catch { }
            try? JSONSerialization.data(withJSONObject: ["phase": phase, "exactGeneratedCleanupCompleted": cleanup])
                .write(to: root.appendingPathComponent("evidence/keychain-failure-cleanup-\(phase).json"), options: .withoutOverwriting)
            throw error
        }
    }
    private static func equal(_ a: SMBPassword, _ b: SMBPassword) -> Bool { a.withUTF8Bytes { lhs in b.withUTF8Bytes { lhs == $0 } } }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw UIVerification.Failure(message: message) } }
    nonisolated private static func readPrivateInput() throws -> (SMBPassword, SMBPassword) {
        var raw = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 1024), !chunk.isEmpty {
            raw.append(chunk)
            guard raw.count <= 1024 else { throw SMBPasswordFailure.invalidInput }
        }
        guard let text = String(data: raw, encoding: .ascii) else { throw SMBPasswordFailure.invalidInput }
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].isEmpty else { throw SMBPasswordFailure.invalidInput }
        func password(_ hex: Substring) throws -> SMBPassword {
            guard !hex.isEmpty, hex.count <= 256, hex.count % 2 == 0 else { throw SMBPasswordFailure.invalidInput }
            let chars = Array(hex.utf8)
            var bytes = Data()
            for start in stride(from: 0, to: chars.count, by: 2) {
                guard let byte = UInt8(String(decoding: chars[start..<start + 2], as: UTF8.self), radix: 16) else { throw SMBPasswordFailure.invalidInput }
                bytes.append(byte)
            }
            guard let value = String(data: bytes, encoding: .utf8) else { throw SMBPasswordFailure.invalidInput }
            return try SMBPassword(value)
        }
        return (try password(parts[0]), try password(parts[1]))
    }
}
#endif
