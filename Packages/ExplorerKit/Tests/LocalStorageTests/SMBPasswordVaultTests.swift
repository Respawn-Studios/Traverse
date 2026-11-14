import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

private final class GeneratedPasswordBackend: SMBPasswordBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var bindings: [String: Data] = [:]
    private var held: String?
    private var failure: SMBPasswordFailure?
    private var calls = 0
    private var mainThread = false
    let gate = DispatchSemaphore(value: 0)
    let events = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    var count: Int { lock.withLock { calls } }
    var usedMainThread: Bool { lock.withLock { mainThread } }
    func holdNext(_ action: String) { lock.withLock { held = action } }
    func failNext(_ error: SMBPasswordFailure) { lock.withLock { failure = error } }
    private func admit(_ action: String) throws {
        let (hold, error) = lock.withLock {
            calls += 1; mainThread = mainThread || Thread.isMainThread
            let hold = held == action
            if hold { held = nil }
            let error = failure; failure = nil
            return (hold, error)
        }
        if hold {
            events.continuation.yield(())
            guard gate.wait(timeout: .now() + 3) == .success else { throw SMBPasswordFailure.unavailable }
        }
        if let error { throw error }
    }
    func read(service: String, reference: SMBCredentialReference) throws -> Data {
        try admit("read")
        return try lock.withLock {
            let key = service + reference.id.uuidString
            guard bindings[key] == reference.bindingDigest, let bytes = values[key] else { throw SMBPasswordFailure.missing }
            return bytes
        }
    }
    func save(service: String, reference: SMBCredentialReference, bytes: Data) throws {
        try admit("save")
        try lock.withLock {
            let key = service + reference.id.uuidString
            if let old = bindings[key], old != reference.bindingDigest { throw SMBPasswordFailure.bindingMismatch }
            values[key] = bytes; bindings[key] = reference.bindingDigest
        }
    }
    func remove(service: String, reference: SMBCredentialReference) throws {
        try admit("remove")
        lock.withLock {
            let key = service + reference.id.uuidString
            if bindings[key] == reference.bindingDigest { values.removeValue(forKey: key); bindings.removeValue(forKey: key) }
        }
    }
}

final class SMBPasswordVaultTests: XCTestCase, @unchecked Sendable {
    private func binding(host: String = "example.invalid", port: UInt16 = 445, share: String = "QA",
                         account: String = "generated", domain: String = "") throws -> SMBCredentialBinding {
        try SMBCredentialBinding(host: host, port: port, share: share, account: account, domain: domain)
    }
    private func vault(_ backend: GeneratedPasswordBackend) -> SMBPasswordVault {
        SMBPasswordVault(service: "generated-only-test", backend: backend)
    }
    #if DEBUG
    func testGeneratedMemoryQualificationUsesExactBindingAndNumericOnlyCounters() async throws {
        let store = SMBPasswordVault.generatedMemoryQualification()
        let base = try binding(), reference = SMBCredentialReference(binding: base)
        _ = try await store.save(SMBPassword("generated-only"), reference: reference, binding: base)
        XCTAssertEqual(store.generatedMemoryQualificationCounts?.saves, 1)
        XCTAssertEqual(store.generatedMemoryQualificationCounts?.retained, 1)
        do { _ = try await store.password(reference, binding: binding(host: "other.invalid")); XCTFail() }
        catch { XCTAssertEqual(error as? SMBPasswordFailure, .bindingMismatch) }
        XCTAssertEqual(store.generatedMemoryQualificationCounts?.reads, 0)
        let recovered = try await store.password(reference, binding: base)
        XCTAssertTrue(recovered.withUTF8Bytes { $0 == Data("generated-only".utf8) })
        _ = try await store.remove(reference, binding: base)
        let counts = store.generatedMemoryQualificationCounts
        XCTAssertEqual(counts?.reads, 1); XCTAssertEqual(counts?.removes, 1)
        XCTAssertEqual(counts?.retained, 0)
    }
    #endif
    func testExactEndpointAccountBindingPreventsCredentialReuseBeforeBackendAccess() async throws {
        let backend = GeneratedPasswordBackend(), store = vault(backend)
        let base = try binding(), reference = SMBCredentialReference(binding: base)
        _ = try await store.save(SMBPassword("generated-only"), reference: reference, binding: base)
        let variants = try [binding(host: "other.invalid"), binding(port: 1445), binding(share: "Other"),
                            binding(account: "other"), binding(domain: "other")]
        for changed in variants {
            do { _ = try await store.password(reference, binding: changed); XCTFail("Unexpected endpoint reuse") }
            catch { XCTAssertEqual(error as? SMBPasswordFailure, .bindingMismatch) }
        }
        XCTAssertEqual(backend.count, 1)
        let password = try await store.password(reference, binding: binding(host: "EXAMPLE.INVALID"))
        XCTAssertTrue(password.withUTF8Bytes { $0 == Data("generated-only".utf8) })
        XCTAssertFalse(backend.usedMainThread)
    }
    func testUpdateDeleteMissingAndDeniedAreTruthful() async throws {
        let backend = GeneratedPasswordBackend(), store = vault(backend)
        let base = try binding(), reference = SMBCredentialReference(binding: base)
        for value in ["first-generated", "second-generated"] {
            _ = try await store.save(SMBPassword(value), reference: reference, binding: base)
            let saved = try await store.password(reference, binding: base)
            XCTAssertTrue(saved.withUTF8Bytes { $0 == Data(value.utf8) })
        }
        backend.failNext(.denied)
        do { _ = try await store.password(reference, binding: base); XCTFail() }
        catch { XCTAssertEqual(error as? SMBPasswordFailure, .denied) }
        _ = try await store.remove(reference, binding: base)
        _ = try await store.remove(reference, binding: base)
        do { _ = try await store.password(reference, binding: base); XCTFail() }
        catch { XCTAssertEqual(error as? SMBPasswordFailure, .missing) }
    }
    func testCancelledReadDrainsWithoutPublishingReturnedSecret() async throws {
        let backend = GeneratedPasswordBackend(), store = vault(backend)
        let base = try binding(), reference = SMBCredentialReference(binding: base)
        _ = try await store.save(SMBPassword("generated-only"), reference: reference, binding: base)
        backend.holdNext("read")
        var entered = backend.events.stream.makeAsyncIterator()
        let reading = Task { try await store.password(reference, binding: base) }
        _ = await entered.next(); reading.cancel(); backend.gate.signal()
        do { _ = try await reading.value; XCTFail("Cancelled read published a secret") }
        catch { XCTAssertEqual(error as? SMBPasswordFailure, .cancelled) }
        await store.drain(); XCTAssertEqual(backend.count, 2)
    }
    func testAdmittedMutationReportsLateCancellationAndPersistsItsActualOutcome() async throws {
        let backend = GeneratedPasswordBackend(), store = vault(backend)
        let base = try binding(), reference = SMBCredentialReference(binding: base)
        backend.holdNext("save")
        var entered = backend.events.stream.makeAsyncIterator()
        let saving = Task { try await store.save(SMBPassword("generated-only"), reference: reference, binding: base) }
        _ = await entered.next(); saving.cancel(); backend.gate.signal()
        let outcome = try await saving.value
        XCTAssertTrue(outcome.completedAfterCancellation)
        let stored = try await store.password(reference, binding: base)
        XCTAssertTrue(stored.withUTF8Bytes { $0 == Data("generated-only".utf8) })
        await store.drain()
    }
    func testAdmissionIsBoundedAndCancelledQueuedReadsNeverReachBackend() async throws {
        let backend = GeneratedPasswordBackend(), store = vault(backend)
        let base = try binding(), reference = SMBCredentialReference(binding: base)
        _ = try await store.save(SMBPassword("generated-only"), reference: reference, binding: base)
        backend.holdNext("read")
        var entered = backend.events.stream.makeAsyncIterator()
        let first = Task { try await store.password(reference, binding: base) }
        _ = await entered.next()
        let queued = (0..<7).map { _ in Task { try await store.password(reference, binding: base) } }
        let deadline = ContinuousClock.now + .seconds(1)
        while store.admittedRequestCount < 8 && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(store.admittedRequestCount, 8)
        do { _ = try await store.password(reference, binding: base); XCTFail("Unbounded Keychain admission") }
        catch { XCTAssertEqual(error as? SMBPasswordFailure, .busy) }
        queued.forEach { $0.cancel() }; backend.gate.signal()
        _ = try await first.value
        for task in queued {
            do { _ = try await task.value; XCTFail("Cancelled queued read reached Keychain") }
            catch { XCTAssertEqual(error as? SMBPasswordFailure, .cancelled) }
        }
        await store.drain()
        XCTAssertEqual(store.admittedRequestCount, 0); XCTAssertEqual(backend.count, 2)
    }
    func testSecretHasRedactedDescriptionsAndNeverAppearsInPersistableReference() throws {
        let password = try SMBPassword("generated-secret-for-control")
        XCTAssertEqual(password.description, "<SMB password>")
        XCTAssertEqual(String(reflecting: password), "<SMB password>")
        let encoded = try JSONEncoder().encode(SMBCredentialReference(binding: binding()))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("generated-secret-for-control"))
        XCTAssertThrowsError(try SMBPassword("")); XCTAssertThrowsError(try SMBPassword(String(repeating: "x", count: 4097)))
    }
}
