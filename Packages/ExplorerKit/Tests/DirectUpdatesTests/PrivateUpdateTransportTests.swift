import Foundation
@testable import DirectUpdates
import Testing

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TRAVERSE_UPDATE_TEST_PORT"] != nil))
struct PrivateUpdateTransportTests {
    @Test func actualRequestsRejectRedirectsAndDrainCancelledWork() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["TRAVERSE_UPDATE_TEST_PORT"].flatMap(Int.init))
        let endpoint = try PrivateUpdateEndpoint.loopback(port:port)
        try PrivateUpdateTransport.configureForTests(endpoint)
        defer { try? PrivateUpdateTransport.configureForTests(.production) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PrivateUpdateTransport.self]
        let session = URLSession(configuration:config)
        defer { session.invalidateAndCancel() }
        func request(_ scenario: String) -> URLRequest {
            var value = URLRequest(url:endpoint.feed)
            value.setValue(PrivateUpdateTransport.markerValue,forHTTPHeaderField:PrivateUpdateTransport.marker)
            value.setValue(try! PrivateUpdateInvitation("Generated-only-update-invitation").authorization,forHTTPHeaderField:"Authorization")
            value.setValue(scenario,forHTTPHeaderField:"X-Generated-Scenario")
            return value
        }
        let data = try await session.data(for:request("success")).0
        #expect(data == Data("Generated signed-feed transport control".utf8))
        let download = try await session.download(for:request("success"))
        #expect(try Data(contentsOf:download.0) == data)
        for (mode,code) in [("redirect",3),("unauthorized",2),("oversized",4),("stream-overflow",4),("rate-limited",8),("service-busy",5)] {
            do { _ = try await session.data(for:request(mode)); Issue.record("Transport accepted \(mode)") }
            catch {
                print("GENERATED_UPDATE_FAILURE \(mode) \((error as NSError).code)")
                #expect((error as NSError).domain == "Traverse.PrivateUpdate")
                #expect((error as NSError).code == code, "Expected failure mapping for \(mode)")
            }
        }
        let probe = UpdateResponseProbe()
        let stalled = URLSession(configuration:config,delegate:probe,delegateQueue:nil)
        defer { stalled.invalidateAndCancel() }
        let pending = stalled.dataTask(with:request("stall")); pending.resume()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !probe.receivedResponse && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for:.milliseconds(5))
        }
        #expect(probe.receivedResponse && PrivateUpdateTransport.activeRequests >= 1)
        #expect(await PrivateUpdateTransport.closeAndDrain())
        let completedDeadline = ProcessInfo.processInfo.systemUptime + 3
        while !probe.completed && ProcessInfo.processInfo.systemUptime < completedDeadline { try await Task.sleep(for:.milliseconds(5)) }
        #expect(probe.completed && probe.failureCode == 6)
        #expect(PrivateUpdateTransport.activeRequests == 0)
        PrivateUpdateTransport.resume()
        // Sparkle creates a default native session. Qualify its standard
        // Authorization handling independently; no custom password header.
        let ordinary = URLSession(configuration:.ephemeral)
        defer { ordinary.invalidateAndCancel() }
        var redirected = request("platform-redirect")
        redirected.setValue(nil,forHTTPHeaderField:PrivateUpdateTransport.marker)
        _ = try await ordinary.data(for:redirected)
    }
}

private final class UpdateResponseProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var received = false, ended = false
    private var code: Int?
    var receivedResponse: Bool { lock.withLock { received } }
    var completed: Bool { lock.withLock { ended } }
    var failureCode: Int? { lock.withLock { code } }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.withLock { received = true }; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock { ended = true; code = (error as NSError?)?.code }
    }
}
