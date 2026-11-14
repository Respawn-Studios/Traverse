import Foundation

/// App-owned access checks explicitly install this in their configuration.
/// Sparkle uses its own session; registering a protocol globally does not make
/// NSURLSession use it. Framework transport has separate qualification.
public final class PrivateUpdateTransport: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    public static let marker = "X-Traverse-Private-Update"
    public static let markerValue = "v1"
    private static let admission = UpdateTransportAdmission()
    private let state = NSLock()
    private var session: URLSession?
    private var forwardedTask: URLSessionDataTask?
    private var ended = false, notified = false, admitted = false
    private var received = 0, maximum = 0
    fileprivate let admissionID = UUID()

    public override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: marker) == markerValue
    }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    public override func startLoading() {
        guard let url = request.url, Self.admission.endpoint.permits(url), request.httpMethod == "GET",
              request.httpBody == nil, request.httpBodyStream == nil,
              let authorization = request.value(forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("Basic "), authorization.utf8.count <= 1024 else { fail(.invalidInput); return }
        guard Self.admission.begin(self) else { fail(.busy); return }; admitted = true
        maximum = Self.admission.endpoint.maximumBytes(for: url)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = []; config.urlCache = nil; config.httpCookieStorage = nil
        config.urlCredentialStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 300
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        var forwarded = request; forwarded.setValue(nil, forHTTPHeaderField: Self.marker)
        forwarded.setValue("identity", forHTTPHeaderField:"Accept-Encoding")
        forwarded.httpShouldHandleCookies = false
        let task = session.dataTask(with: forwarded)
        let cancelled = state.withLock { () -> Bool in
            self.session = session; self.forwardedTask = task; return ended
        }
        if cancelled { task.cancel(); session.invalidateAndCancel() } else { task.resume() }
    }
    public override func stopLoading() {
        let session = state.withLock { () -> URLSession? in ended = true; return self.session }
        session?.invalidateAndCancel()
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil); fail(.redirected); session.invalidateAndCancel()
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                           didReceive response: URLResponse,
                           completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse,
              let url = response.url, Self.admission.endpoint.permits(url) else {
            fail(.unavailable); completionHandler(.cancel); return
        }
        guard response.statusCode == 200 else {
            fail(response.statusCode == 429 ? .rateLimited : response.statusCode == 503 ? .busy : [401,403].contains(response.statusCode) ? .authentication : .unavailable)
            completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= Int64(maximum) else {
            fail(.capacity); completionHandler(.cancel); return
        }
        guard
              response.value(forHTTPHeaderField:"Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true,
              !state.withLock({ ended }) else {
            fail(.unavailable)
            completionHandler(.cancel); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); completionHandler(.allow)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !state.withLock({ ended }) else { return }
        guard data.count <= maximum - received else { fail(.capacity); session.invalidateAndCancel(); return }
        received += data.count; client?.urlProtocol(self, didLoad: data)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            fail((error as NSError).code == NSURLErrorCancelled ? .cancelled : .unavailable)
        } else {
            let send = state.withLock { () -> Bool in if notified || ended { return false }; notified = true; return true }
            if send { client?.urlProtocolDidFinishLoading(self) }
        }
        session.finishTasksAndInvalidate()
    }
    public func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        let release = state.withLock { () -> Bool in
            self.session = nil; self.forwardedTask = nil
            if admitted { admitted = false; return true }; return false
        }
        if release { Self.admission.finish(admissionID) }
    }
    private func fail(_ failure: PrivateUpdateFailure) {
        let send = state.withLock { () -> Bool in if notified || ended { return false }; notified = true; ended = true; return true }
        let code: Int
        switch failure {
        case .invalidInput: code = 1; case .authentication: code = 2; case .redirected: code = 3
        case .capacity: code = 4; case .busy: code = 5; case .cancelled: code = 6; case .rateLimited: code = 8; default: code = 7
        }
        if send { client?.urlProtocol(self, didFailWithError: NSError(domain: "Traverse.PrivateUpdate", code: code)) }
    }
    public static var activeRequests: Int { admission.active }
    fileprivate func cancelOwned() {
        fail(.cancelled)
        let session = state.withLock { self.session }
        session?.invalidateAndCancel()
    }
    public static func closeAndDrain() async -> Bool {
        admission.close()
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while admission.active > 0 {
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
    public static func resume() { admission.resume() }
    static func configureForTests(_ endpoint: PrivateUpdateEndpoint) throws { try admission.set(endpoint) }
}

private final class UpdateTransportAdmission: @unchecked Sendable {
    private final class Weak { weak var value: PrivateUpdateTransport?; init(_ value: PrivateUpdateTransport) { self.value = value } }
    private let lock = NSLock()
    private var requests: [UUID:Weak] = [:]
    private var closed = false
    private var selected = PrivateUpdateEndpoint.production
    var endpoint: PrivateUpdateEndpoint { lock.withLock { selected } }
    var active: Int { lock.withLock { requests.count } }
    func begin(_ value: PrivateUpdateTransport) -> Bool {
        lock.withLock { if closed || requests.count >= 4 { return false }; requests[value.admissionID] = Weak(value); return true }
    }
    func finish(_ id: UUID) { lock.withLock { _ = requests.removeValue(forKey: id) } }
    func close() {
        let values = lock.withLock { () -> [PrivateUpdateTransport] in closed = true; return requests.values.compactMap(\.value) }
        for value in values { value.cancelOwned() }
    }
    func resume() { lock.withLock { closed = false } }
    func set(_ endpoint: PrivateUpdateEndpoint) throws {
        try lock.withLock { guard requests.isEmpty else { throw PrivateUpdateFailure.busy }; selected = endpoint; closed = false }
    }
}
