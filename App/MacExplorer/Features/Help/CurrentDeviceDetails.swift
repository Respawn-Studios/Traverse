import Darwin
import Foundation

/// One explicit snapshot on the report worker queue. No monitoring, environment,
/// device identifiers, host names, user paths or memory contents are collected.
enum CurrentDeviceDetails {
    static let heading = "## Current device info (not crash-time)"

    static func text() -> String {
        let process = ProcessInfo.processInfo
        var lines = [heading, "", "Snapshot taken on request; these values are current, not crash-time measurements.",
                     "CPU: \(cpuFamily())", "Logical processor count: \(process.processorCount)",
                     "Installed RAM: \(memory(process.physicalMemory))"]
        if let resident = residentMemory() { lines.append("Current app resident memory: \(memory(resident))") }
        return lines.joined(separator: "\n")
    }

    private static func cpuFamily() -> String {
        var bytes = [UInt8](repeating: 0, count: 128)
        var length = bytes.count
        let result = bytes.withUnsafeMutableBytes { buffer in
            sysctlbyname("machdep.cpu.brand_string", buffer.baseAddress, &length, nil, 0)
        }
        if result == 0, (1...bytes.count).contains(length) {
            let brand = String(decoding: bytes.prefix(length).prefix { $0 != 0 }, as: UTF8.self)
            // Publish only a coarse known product family, never the raw system string.
            if brand.range(of: #"\AApple M[1-9][0-9]?(?: (?:Pro|Max|Ultra))?\z"#, options: .regularExpression) != nil {
                return brand
            }
            if brand.contains("Intel") { return "Intel" }
        }
        #if arch(arm64)
        return "Apple Silicon (generation unavailable)"
        #elseif arch(x86_64)
        return "Intel or compatible (model unavailable)"
        #else
        return "Unavailable"
        #endif
    }

    private static func residentMemory() -> UInt64? {
        var info = mach_task_basic_info_data_t()
        let capacity = MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }

    private static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
}
