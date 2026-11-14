import Foundation

/// Incremental D1 framing. The synchronous consumer appends bytes before ACK;
/// no chunk queue or lossy UI stream stands between the socket and the spool.
struct SMBDownloadFrames {
    let maximumFrameBytes: Int
    init(maximumFrameBytes: Int = SMBDownloadConversation.maximumFrameBytes) { self.maximumFrameBytes = maximumFrameBytes }
    private var buffer = Data()
    private var length: Int?
    private var failed = false
    var isEmpty: Bool { buffer.isEmpty && length == nil }
    mutating func append(_ input: Data, consume: (Data) throws -> Void) throws {
        do {
            guard !failed, input.count <= 32768 else { throw SMBDirectoryFailure.invalidOutput }
            for byte in input {
                buffer.append(byte)
                if length == nil, buffer.count == 4 {
                    let size = buffer.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    guard size > 0, size <= maximumFrameBytes else { throw SMBDirectoryFailure.invalidOutput }
                    length = Int(size); buffer.removeAll(keepingCapacity: true)
                } else if let length, buffer.count == length {
                    let payload = buffer; buffer.removeAll(keepingCapacity: true); self.length = nil
                    try consume(payload)
                }
                guard buffer.count <= maximumFrameBytes else { throw SMBDirectoryFailure.invalidOutput }
            }
        } catch { failed = true; throw error }
    }
}
