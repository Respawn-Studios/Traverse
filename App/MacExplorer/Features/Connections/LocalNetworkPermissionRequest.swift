import Combine
import Darwin
import Foundation

/// Apple's TN3179 best-effort alert trigger. No packet is sent, no server is
/// discovered, and neither a socket result nor a completed attempt proves a
/// permission decision. All address handling stays in this utility task.
enum LocalNetworkAlertTrigger {
    static func perform() -> Int {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return 0 }
        defer { freeifaddrs(first) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        var visited = 0, attempts = 0
        while let entry = current, visited < 256, attempts < 16, !Task.isCancelled {
            current = entry.pointee.ifa_next; visited += 1
            guard entry.pointee.ifa_flags & UInt32(IFF_BROADCAST) != 0,
                  let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET6),
                  Int(address.pointee.sa_len) >= MemoryLayout<sockaddr_in6>.size else { continue }
            let original = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee
            let isLinkLocal = withUnsafeBytes(of: original.sin6_addr) { bytes in
                bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
            }
            guard isLinkLocal else { continue }
            for _ in 0..<2 where attempts < 16 && !Task.isCancelled {
                var target = original
                target.sin6_port = in_port_t(9).bigEndian
                withUnsafeMutableBytes(of: &target.sin6_addr) { bytes in
                    arc4random_buf(bytes.baseAddress!.advanced(by: 8), 8)
                }
                let descriptor = socket(AF_INET6, SOCK_DGRAM, 0)
                guard descriptor >= 0 else { continue }
                // Our extra bound: never wait for network completion. There is
                // no send/receive, retry, DNS, Bonjour, or private-data probe.
                let flags = fcntl(descriptor, F_GETFL)
                let descriptorFlags = fcntl(descriptor, F_GETFD)
                if flags >= 0, descriptorFlags >= 0,
                   fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0,
                   fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) >= 0 {
                    withUnsafePointer(to: &target) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                            _ = Darwin.connect(descriptor, address, socklen_t(MemoryLayout<sockaddr_in6>.size))
                        }
                    }
                    attempts += 1
                }
                _ = Darwin.close(descriptor)
            }
        }
        return attempts
    }
}

@MainActor final class LocalNetworkPermissionRequest: ObservableObject {
    @Published private(set) var requesting = false
    @Published private(set) var notice = ""
    private var task: Task<Void, Never>?
    private let trigger: @Sendable () -> Int
    init(trigger: @escaping @Sendable () -> Int = LocalNetworkAlertTrigger.perform) { self.trigger = trigger }
    func request() {
        guard task == nil else { return }
        requesting = true; notice = "Follow the macOS alert if one appears."
        let trigger = trigger
        task = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { trigger() }
            let attempts = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self else { return }
            defer { self.requesting = false; self.task = nil }
            guard !Task.isCancelled else { self.notice = ""; return }
            notice = attempts > 0
                ? "If macOS showed an alert, choose Allow to use nearby servers. If no alert appeared, review Local Network in System Settings; access may already be decided."
                : "A request could not be started on the current network. You can connect to a server later or review Local Network in System Settings."
        }
    }
    func cancel() { task?.cancel() }
    #if DEBUG
    func drainForVerification() async { await task?.value }
    #endif
}
