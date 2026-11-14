#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// Generated, signed-app integration only. This is not an ordinary Connect path.
@MainActor enum SMBAuthenticatedVerification {
    // The owner authorized one service namespace, not a new one for every case.
    private static let namespace = UUID(uuidString: "5A2FE3FA-68B5-4B8E-AD37-F5E0567FAD98")!

    static func run(root: URL, run: Int, settings: BrowserSettings) async throws -> [String: Any] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b10-network-reader")
            && root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && (0..<16).contains(run), "Authenticated review requires its exact generated packet")
        let evidence = root.appendingPathComponent("evidence")
        let planURL = evidence.appendingPathComponent(String(format: "auth-plan-%02d.json", run))
        let data = try await Task.detached { try Data(contentsOf: planURL) }.value
        guard data.count < 4096, let plan = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let action = plan["action"], ["save", "reopen", "signed", "authentication", "denied", "stop", "disconnect", "deadline", "cleanup"].contains(action),
              plan["namespace"] == namespace.uuidString else { throw UIVerification.Failure(message: "Unadmitted authenticated review plan") }
        let vault = SMBPasswordVault.generatedQualification(namespace: namespace)
        let binding = try SMBCredentialBinding(host: "127.0.0.1", port: 15445, share: "ExplorerQA", account: "nobody", domain: "")
        let referenceURL = evidence.appendingPathComponent("auth-credential-reference.json")
        if action == "cleanup" {
            let raw = try await Task.detached { try Data(contentsOf: referenceURL) }.value
            try require(raw.count < 4096, "Generated cleanup reference exceeds its bound")
            let saved = try JSONDecoder().decode(SMBCredentialReference.self, from: raw)
            _ = try await vault.remove(saved, binding: binding)
            try await requireMissing(vault, reference: saved, binding: binding); await vault.drain()
            return ["passed": true, "action": action, "removedGeneratedPassword": true,
                "personalCredentialQueries": 0, "networkAttempts": 0]
        }
        var reference: SMBCredentialReference?
        let password: SMBPassword
        if action == "reopen" {
            let raw = try await Task.detached { try Data(contentsOf: referenceURL) }.value
            try require(raw.count < 4096, "Generated credential reference exceeds its bound")
            let saved = try JSONDecoder().decode(SMBCredentialReference.self, from: raw)
            reference = saved; password = try await vault.password(saved, binding: binding)
        } else { password = try await Task.detached { try readPrivatePassword() }.value }

        let rows = SMBGeneratedRows()
        let status = NSTextField(labelWithString: "Connecting to generated SMB share…")
        status.font = .systemFont(ofSize: 12, weight: .medium)
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 620, height: 320))
        scroll.hasVerticalScroller = true; scroll.documentView = rows.table
        let stack = NSStackView(views: [status, scroll]); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 10; stack.edgeInsets = .init(top: 12, left: 12, bottom: 12, right: 12)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 660, height: 380),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Encrypted SMB · generated signed review"; window.isReleasedWhenClosed = false
        let content = NSViewController(); content.view = stack; window.contentViewController = content
        ToolWindowChrome.install(in: window, settings: settings)
        window.setContentSize(.init(width: 660, height: 380)); window.contentView?.layoutSubtreeIfNeeded()
        window.setFrameOrigin(.init(x: -12000, y: -12000)); window.orderFront(nil)
        defer { window.close() }
        let activity = FileActivityGate(maximumActivities: 1)
        let began = ProcessInfo.processInfo.systemUptime
        var held: SMBWorkerSession?, closed: SMBWorkerCloseResult?
        var counts: [Int] = [], actualSecurity: SMBWorkerSecurity?
        var savedPassword = false, removedPassword = false
        let operation = Task { @MainActor () -> String in
            do {
                let session = try await SMBWorkerSession.connectGeneratedAuthenticated(bundleURL: Bundle.main.bundleURL,
                    activity: activity, password: password, policy: action == "signed" ? .signedCompatibility : .encrypted,
                    share: action == "denied" ? .denied : .standard)
                held = session; actualSecurity = session.security
                status.stringValue = actualSecurity == .encrypted ? "Encrypted SMB3.1.1 · Read only" : "Signed SMB3.1.1 · Read only"
                counts.append(try await session.readGeneratedDirectory { page in
                    Task { @MainActor in
                        guard session.allowsPublication(page.readID) else { return }; rows.append(page)
                    }
                })
                if ["save", "reopen", "signed"].contains(action) {
                    try await wait { rows.entries.count == 3 }
                    try require(Set(rows.entries.map(\.name)) == ["Read me.txt", "Café 文件.txt", "Folder"], "Generated root rows differ")
                    counts.append(try await session.readGeneratedDirectory(nested: true) { page in
                        Task { @MainActor in
                            guard session.allowsPublication(page.readID) else { return }; rows.append(page)
                        }
                    })
                    try await wait { rows.entries.count == 5 }
                    let files = Dictionary(uniqueKeysWithValues: rows.entries.filter { !$0.isDirectory }.map { ($0.name, $0.logicalBytes) })
                    try require(files == ["Read me.txt": 44, "Café 文件.txt": 128, "Nested note.txt": 22]
                        && Set(rows.entries.filter(\.isDirectory).map(\.name)) == ["Folder", "Empty folder"], "Generated metadata or folder kind differs")
                    if action == "save" {
                        let value = SMBCredentialReference(binding: binding)
                        let raw = try JSONEncoder().encode(value)
                        // Record exact deletion authority before admitting the owned Keychain mutation.
                        try await Task.detached { try raw.write(to: referenceURL, options: .withoutOverwriting) }.value
                        reference = value
                        _ = try await vault.save(password, reference: value, binding: binding); savedPassword = true
                    } else if action == "reopen", let reference {
                        _ = try await vault.remove(reference, binding: binding)
                        try await requireMissing(vault, reference: reference, binding: binding); removedPassword = true
                    }
                }
                closed = await session.close(); return "complete"
            } catch let failure as SMBWorkerFailure {
                if let held { closed = await held.close() }; return failure.rawValue
            } catch {
                if let held { closed = await held.close() }; return "unexpected"
            }
        }
        if action == "stop" {
            let marker = evidence.appendingPathComponent(String(format: "auth-ready-%02d.json", run))
            for _ in 0..<1500 {
                if await Task.detached(operation: { FileManager.default.fileExists(atPath: marker.path) }).value { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            operation.cancel()
        }
        let outcome = await operation.value
        await vault.drain()
        let expected = ["save": "complete", "reopen": "complete", "signed": "complete", "authentication": "authentication",
            "denied": "denied", "stop": "stopped", "disconnect": "remote", "deadline": "deadline"][action]
        do {
            try require(outcome == expected, "Authenticated native outcome differs: \(outcome)")
            try require(activity.activeCount == 0, "Authenticated native worker lifetime did not drain")
            if let closed {
                try require(closed.actualExit && closed.localDrainProved && !closed.forcedContainment,
                    "Authenticated native close required containment or failed to join")
                guard let facts = closed.diagnostics else { throw UIVerification.Failure(message: "Authenticated terminal evidence missing") }
                try require(facts.joined == 4 && facts.pending == 0 && facts.tasks == 0 && facts.commands.count == 19
                    && [7,8,9,10,11,15,16,17,18].allSatisfy { facts.commands[$0] == 0 }, "Metadata/lifetime command contract differs")
                if ["stop", "disconnect", "deadline"].contains(action) {
                    try require(facts.commands[14] >= 1 && rows.entries.isEmpty && counts.isEmpty,
                        "Encrypted interruption did not reach an unpublished directory query")
                }
            } else {
                try require(["authentication", "denied"].contains(action) && rows.entries.isEmpty,
                    "Native connection disappeared without an expected authenticated failure")
            }
            if ["save", "reopen", "signed"].contains(action) {
                try require(counts == [3, 2], "Authenticated native sequential page accounting differs")
                try require(actualSecurity == (action == "signed" ? .signed : .encrypted), "Native security state differs")
                try require((rows.firstDisplay ?? began + 2) - began < 1, "Authenticated native first display exceeded one second")
                if action == "save" { try await UIVerification.snapshot(window, to: evidence.appendingPathComponent("native-auth.png")) }
            }
        } catch {
            if let reference {
                _ = try? await vault.remove(reference, binding: binding); await vault.drain()
                let cleanup = (try? await requireMissing(vault, reference: reference, binding: binding)) != nil
                try? JSONSerialization.data(withJSONObject: ["exactGeneratedEntryRemoved": cleanup])
                    .write(to: evidence.appendingPathComponent(String(format: "auth-keychain-cleanup-%02d.json", run)), options: .withoutOverwriting)
            }
            throw error
        }
        var report: [String: Any] = ["passed": true, "action": action, "outcome": outcome, "readCounts": counts,
            "displayedRows": rows.entries.count, "firstNativeDisplayMilliseconds": rows.firstDisplay.map { ($0 - began) * 1000 } ?? -1,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began, "activityAfterActualExit": activity.activeCount,
            "security": actualSecurity?.rawValue ?? "not connected", "savedGeneratedPassword": savedPassword,
            "removedGeneratedPassword": removedPassword, "personalCredentialQueries": 0]
        if let closed, let facts = closed.diagnostics {
            report["worker"] = ["actualExit": closed.actualExit, "localDrainProved": closed.localDrainProved,
                "forcedContainment": closed.forcedContainment, "outcome": facts.outcome, "joined": facts.joined,
                "pending": facts.pending, "tasks": facts.tasks, "observed": facts.observed,
                "drainMicroseconds": facts.drainMicroseconds, "commands": facts.commands] as [String: Any]
        } else { report["connectFailureDrain"] = "Failed connect returned after its module lifetime drained; proxy separately verifies socket EOF" }
        return report
    }

    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw UIVerification.Failure(message: message) }
    }
    private static func requireMissing(_ store: SMBPasswordVault, reference: SMBCredentialReference, binding: SMBCredentialBinding) async throws {
        do { _ = try await store.password(reference, binding: binding); throw UIVerification.Failure(message: "Deleted generated password remains") }
        catch SMBPasswordFailure.missing { }
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw UIVerification.Failure(message: "Authenticated native pages did not settle")
    }
    nonisolated static func readPrivatePassword() throws -> SMBPassword {
        var raw = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 512), !chunk.isEmpty {
            raw.append(chunk); guard raw.count <= 257 else { throw SMBPasswordFailure.invalidInput }
        }
        guard raw.last == 10 else { throw SMBPasswordFailure.invalidInput }; raw.removeLast()
        guard !raw.isEmpty, raw.count % 2 == 0, raw.count <= 256,
              raw.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw SMBPasswordFailure.invalidInput }
        let hex = Array(raw); var bytes = Data()
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let byte = UInt8(String(decoding: hex[index..<index+2], as: UTF8.self), radix: 16) else { throw SMBPasswordFailure.invalidInput }
            bytes.append(byte)
        }
        guard let value = String(data: bytes, encoding: .utf8) else { throw SMBPasswordFailure.invalidInput }
        return try SMBPassword(value)
    }
}
#endif
