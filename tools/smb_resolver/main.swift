// Credential-free native resolver qualification. No SMB, Keychain or file access.
import Darwin
import Dispatch
import Foundation
import dnssd

private struct Address: Hashable, Sendable {
    let family: Int
    let bytes: Data
    let scope: UInt32
    let interface: UInt32
}

private func hex(_ value: Data) -> String { value.map { String(format: "%02x", $0) }.joined() }
private func hostname(_ value: String) -> String? {
    let input = Array(value.utf8)
    guard !input.isEmpty, input.count <= 506, input.count % 2 == 0,
          input.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
    var data = Data()
    for index in stride(from: 0, to: input.count, by: 2) {
        guard let byte = UInt8(String(decoding: input[index..<index+2], as: UTF8.self), radix: 16) else { return nil }; data.append(byte)
    }
    guard let name = String(data: data, encoding: .ascii), !name.isEmpty else { return nil }
    let parts = name.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.allSatisfy({ part in
        (1...63).contains(part.count) && part.first != "-" && part.last != "-"
            && part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }) else { return nil }
    return name
}

private func initialLine() -> String? {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    var value = Data()
    while ProcessInfo.processInfo.systemUptime < deadline {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        if poll(&descriptor, 1, 50) < 0 { if errno == EINTR { continue }; return nil }
        if descriptor.revents == 0 { continue }
        var byte: UInt8 = 0
        guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
        if byte == 10 { return String(data: value, encoding: .ascii) }
        guard value.count < 768, (32...126).contains(byte) else { return nil }; value.append(byte)
    }
    return nil
}

private final class Lookup: @unchecked Sendable {
    let queue = DispatchQueue(label: "MacExplorer.SMB.Resolve.Native")
    let controls = DispatchQueue(label: "MacExplorer.SMB.Resolve.Control")
    private let lock = NSLock()
    private var cancelled = false
    private let generation: UUID
    private let host: String
    private let mode: String
    private var source: DispatchSourceRead?
    private var reference: DNSServiceRef?
    private var addresses = Set<Address>()
    private var events = 0
    private var settle: UInt64 = 0
    private var terminal = false
    private var submitted = false
    private var deallocated = false
    private var sequence = 0

    init(generation: UUID, host: String, mode: String) { self.generation = generation; self.host = host; self.mode = mode }
    func start() {
        var one: Int32 = 1
        guard setsockopt(STDIN_FILENO, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0,
              fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK) == 0 else { exit(2) }
        let control = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: controls)
        control.setEventHandler { [self] in
            var byte: UInt8 = 0
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count == 0 || count == 1 {
                lock.withLock { cancelled = true }
                let reason = count == 1 && byte != 83 ? "invalid-input" : "stopped"
                queue.async { self.finish(reason) }
            } else if errno != EAGAIN && errno != EINTR {
                lock.withLock { cancelled = true }; queue.async { self.finish("stopped") }
            }
        }
        source = control; control.resume()
        queue.async { self.begin() }
    }
    private func begin() {
        guard !lock.withLock({ cancelled }) else { finish("stopped"); return }
        emit("started")
        #if SMB_RESOLVER_QUALIFICATION
        switch mode {
        case "test-blocked-submit": usleep(5_000_000); finish("failed"); return
        case "test-empty": return
        case "test-null-error":
            callback(flags: 0, interface: 0, error: DNSServiceErrorType(kDNSServiceErr_Unknown), address: nil); return
        case "test-overflow":
            for index in 1...17 { record(Address(family: 4, bytes: Data([127, 0, 0, UInt8(index)]), scope: 0, interface: 1), add: true) }
            finish("resolved"); return
        case "test-scope":
            var value = sockaddr_in6(); value.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            value.sin6_family = sa_family_t(AF_INET6); value.sin6_scope_id = 3
            _ = "fe80::1".withCString { inet_pton(AF_INET6, $0, &value.sin6_addr) }
            withUnsafePointer(to: &value) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    callback(flags: DNSServiceFlags(kDNSServiceFlagsAdd), interface: 3, error: 0, address: $0)
                }
            }
            finish("resolved"); return
        case "test-remove":
            let item = Address(family: 4, bytes: Data([127,0,0,1]), scope: 0, interface: 1)
            record(item, add: true); record(item, add: true); record(item, add: false); finish("failed"); return
        default: break
        }
        #endif
        guard mode == "native" else { finish("invalid-input"); return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = host.withCString { DNSServiceGetAddrInfo(&reference, 0, 0,
            DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6), $0, addressCallback, context) }
        submitted = result == kDNSServiceErr_NoError
        guard result == kDNSServiceErr_NoError, let reference else { finish("daemon-error"); return }
        guard !lock.withLock({ cancelled }) else { finish("stopped"); return }
        guard DNSServiceSetDispatchQueue(reference, queue) == kDNSServiceErr_NoError else { finish("daemon-error"); return }
        queue.asyncAfter(deadline: .now() + 10) { self.finish("deadline") }
    }
    func callback(flags: DNSServiceFlags, interface: UInt32, error: DNSServiceErrorType, address: UnsafePointer<sockaddr>?) {
        guard !terminal else { return }
        // On a callback error, every other C parameter is undefined.
        guard error == kDNSServiceErr_NoError else { events += 1; finish("daemon-error"); return }
        guard let address else { finish("invalid-address"); return }
        let item: Address
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            guard Int(address.pointee.sa_len) >= MemoryLayout<sockaddr_in>.size else { finish("invalid-address"); return }
            var value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            item = Address(family: 4, bytes: withUnsafeBytes(of: &value) { Data($0) }, scope: 0, interface: interface)
        case AF_INET6:
            guard Int(address.pointee.sa_len) >= MemoryLayout<sockaddr_in6>.size else { finish("invalid-address"); return }
            let value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee
            var raw = value.sin6_addr
            let bytes = withUnsafeBytes(of: &raw) { Data($0) }
            let linkLocal = bytes.count == 16 && bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
            let scope = value.sin6_scope_id == 0 && linkLocal ? interface : value.sin6_scope_id
            guard !linkLocal || scope > 0 && scope < 0xffff_fff0 else { finish("invalid-address"); return }
            item = Address(family: 6, bytes: bytes, scope: scope, interface: interface)
        default: finish("invalid-address"); return
        }
        record(item, add: flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0)
        guard !terminal else { return }
        settle += 1; let token = settle
        if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 {
            // MoreComing is batch state, never a promise of global DNS EOF.
            // Freeze a finite observation after a quiet interval instead.
            queue.asyncAfter(deadline: .now() + .milliseconds(120)) {
                if self.settle == token && !self.addresses.isEmpty { self.finish("resolved") }
            }
        }
    }
    private func record(_ item: Address, add: Bool) {
        guard !terminal else { return }
        events += 1
        guard events <= 256 else { finish("limit"); return }
        if add { addresses.insert(item) } else { addresses.remove(item) }
        if addresses.count > 16 { finish("limit") }
    }
    private func emit(_ payload: String) {
        let data = Data("MEXDNS1 \(generation.uuidString) \(sequence) \(payload)\n".utf8)
        guard data.count <= 1024 else { exit(4) }; sequence += 1
        let count = data.withUnsafeBytes { Darwin.send(STDIN_FILENO, $0.baseAddress, $0.count, MSG_DONTWAIT) }
        if count != data.count { exit(4) }
    }
    private func finish(_ result: String) {
        guard !terminal else { return }; terminal = true
        let result = lock.withLock({ cancelled }) ? "stopped" : result
        if let reference { DNSServiceRefDeallocate(reference); self.reference = nil; deallocated = true }
        source?.cancel()
        if result == "resolved" {
            for item in addresses.sorted(by: { ($0.family, hex($0.bytes), $0.scope, $0.interface) < ($1.family, hex($1.bytes), $1.scope, $1.interface) }) {
                emit("address \(item.family) \(hex(item.bytes)) \(item.scope) \(item.interface)")
            }
        }
        emit("done \(result) \(result == "resolved" ? addresses.count : 0) \(events) \(submitted ? 1 : 0) \(deallocated ? 1 : 0)")
        // The parent confirms actual process exit. This receipt does not claim
        // the shared resolver daemon or DNS-SD's hidden dispatch source drained.
        exit(0)
    }
}

private func addressCallback(_ reference: DNSServiceRef?, _ flags: DNSServiceFlags, _ interface: UInt32,
    _ error: DNSServiceErrorType, _ hostname: UnsafePointer<CChar>?, _ address: UnsafePointer<sockaddr>?,
    _ ttl: UInt32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<Lookup>.fromOpaque(context).takeUnretainedValue().callback(flags: flags, interface: interface, error: error, address: address)
}

guard CommandLine.arguments.count == 1, let line = initialLine() else { exit(2) }
let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
guard fields.count == 5, fields[0] == "MEXDNS1", fields[1] == "START",
      let generation = UUID(uuidString: fields[2]), generation.uuidString == fields[2],
      generation.uuidString != "00000000-0000-0000-0000-000000000000", let host = hostname(fields[3]) else { exit(2) }
private let lookup = Lookup(generation: generation, host: host, mode: fields[4])
lookup.start()
withExtendedLifetime(lookup) { dispatchMain() }
