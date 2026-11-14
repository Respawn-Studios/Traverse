#if DEBUG
import Darwin
import Dispatch

/// Read-only telemetry for generated qualification. The kernel's footprint
/// lifetime peak and RSS are different counters and are never substituted.
struct NativeMemoryObservation: Sendable {
    enum Failure: Error { case unavailable, unsupportedReply, invalidMeasurement }
    let footprintBytes: UInt64
    let peakFootprintBytes: UInt64
    let peakRSSBytes: UInt64
    let returnedWords: UInt32
    let monotonicNanoseconds: UInt64

    static var capacity: Int { MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size }
    static func requiredBytes() throws -> Int {
        guard MemoryLayout<task_vm_info_data_t>.size.isMultiple(of: MemoryLayout<integer_t>.size),
              let current = MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint),
              let peak = MemoryLayout<task_vm_info_data_t>.offset(of: \.ledger_phys_footprint_peak),
              current <= Int.max - MemoryLayout<mach_vm_size_t>.size,
              peak <= Int.max - MemoryLayout<Int64>.size else { throw Failure.unsupportedReply }
        return max(current + MemoryLayout<mach_vm_size_t>.size, peak + MemoryLayout<Int64>.size)
    }
    static func decode(_ info: task_vm_info_data_t, status: kern_return_t, words: mach_msg_type_number_t) throws -> (UInt64, UInt64) {
        guard status == KERN_SUCCESS else { throw Failure.unavailable }
        guard UInt64(words) <= UInt64(capacity), UInt64(words) * UInt64(MemoryLayout<integer_t>.size) >= UInt64(try requiredBytes()) else {
            throw Failure.unsupportedReply
        }
        guard info.phys_footprint > 0, info.ledger_phys_footprint_peak > 0,
              UInt64(info.ledger_phys_footprint_peak) >= info.phys_footprint else { throw Failure.invalidMeasurement }
        return (info.phys_footprint, UInt64(info.ledger_phys_footprint_peak))
    }
    static func read() throws -> Self {
        var info = task_vm_info_data_t()
        guard capacity > 0, capacity <= Int(UInt32.max) else { throw Failure.unsupportedReply }
        var words = mach_msg_type_number_t(capacity)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &words)
            }
        }
        let (current, peak) = try decode(info, status: status, words: words)
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 else { throw Failure.unavailable }
        return .init(footprintBytes: current, peakFootprintBytes: peak, peakRSSBytes: UInt64(usage.ru_maxrss),
            returnedWords: words, monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
    var fields: [String: UInt64] {
        ["footprintBytes": footprintBytes, "peakFootprintBytes": peakFootprintBytes, "peakRSSBytes": peakRSSBytes,
         "returnedWords": UInt64(returnedWords), "sdkCapacityWords": UInt64(Self.capacity), "monotonicNanoseconds": monotonicNanoseconds]
    }
}
#endif
