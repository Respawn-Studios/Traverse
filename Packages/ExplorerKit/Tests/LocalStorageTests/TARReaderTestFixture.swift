import CryptoKit
import Foundation
import Testing
import zlib
@testable import LocalStorage

/// Test callbacks run on the real reader queue. Client work runs outside the
/// lock, and every held read has a bounded release deadline.
final class TARReadTestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var rows = [(String, UInt64, Int)](), mainThread = false
    private var target: String?, holding = false, action: (@Sendable () throws -> Void)?
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    init(holdFirstRead: Bool = false) { if holdFirstRead { target = "metadata"; holding = true } }
    func at(_ stage: String, hold: Bool = false, action: (@Sendable () throws -> Void)? = nil) {
        lock.withLock { target = stage; holding = hold; self.action = action }
    }
    func probe(_ stage: TARArchiveReader.Stage, _ offset: UInt64, _ count: Int) throws {
        let name = String(describing: stage)
        let work: (Bool, (@Sendable () throws -> Void)?) = lock.withLock {
            rows.append((name, offset, count)); mainThread = mainThread || Thread.isMainThread
            guard target == name else { return (false, nil) }
            target = nil; let work = (holding, action); holding = false; action = nil; return work
        }
        if work.0 {
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw TARArchiveFailure.unavailable }
        }
        try work.1?()
    }
    var snapshot: [(String, UInt64, Int)] { lock.withLock { rows } }
    var observations: (reads: [(UInt64, Int)], mainThread: Bool) {
        lock.withLock { (rows.filter { $0.0 == "metadata" }.map { ($0.1, $0.2) }, mainThread) }
    }
    func clear() { lock.withLock { rows.removeAll() } }
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 5) == .success }
}

/// Independent Python tarfile USTAR/PAX/GNU vectors. Zlib only removes their
/// padding from source control; no production archive writer builds these inputs.
enum TARReaderTestFixture {
    enum Variant: String, CaseIterable, Sendable { case ustar, pax, gnu, rootAndLinks, empty, preview, paxSize }
    struct Row: Equatable, Sendable {
        let path: String, kind: String
        let bytes: UInt64, dataOffset: UInt64
    }

    static func bytes(_ variant: Variant = .ustar) throws -> Data {
        let (length, sha256, encoded) = vector(variant)
        let compressed = try #require(Data(base64Encoded: encoded))
        try #require((1...(1 << 20)).contains(length))
        var output = Data(count: length), actual = uLongf(length)
        let result = output.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                uncompress(destination.bindMemory(to: Bytef.self).baseAddress, &actual,
                           source.bindMemory(to: Bytef.self).baseAddress, uLong(compressed.count))
            }
        }
        try #require(result == Z_OK && actual == uLongf(length))
        try #require(SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined() == sha256)
        return output
    }

    static func write(_ bytes: Data) throws -> URL {
        let root = try LocalStorageTestFixtures.directory()
        let source = root.appendingPathComponent("Independent.tar")
        try bytes.write(to: source, options: .withoutOverwriting)
        return source
    }

    static func rows(_ variant: Variant) -> [Row] {
        switch variant {
        case .ustar:
            return [
                .init(path: "Folder", kind: "directory", bytes: 0, dataOffset: 512),
                .init(path: "Folder/Empty", kind: "directory", bytes: 0, dataOffset: 1024),
                .init(path: "Folder/.hidden", kind: "file", bytes: 0, dataOffset: 1536),
                .init(path: "Folder/Member.bin", kind: "file", bytes: 65553, dataOffset: 2048),
                .init(path: "Folder/._opaque", kind: "file", bytes: 36, dataOffset: 68608),
                .init(path: "Note.txt", kind: "file", bytes: 3, dataOffset: 69632)
            ]
        case .pax:
            return [
                .init(path: "Résumé/nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn", kind: "file", bytes: 3, dataOffset: 1536)
            ]
        case .gnu:
            return [
                .init(path: "long-long-long-long-long-long-long-long-long-long-long-long-long-long-long-long-long-long-long-long-long-long-long-long-long-long-long-long-long-long-", kind: "file", bytes: 3, dataOffset: 1536)
            ]
        case .rootAndLinks:
            return [
                .init(path: "Member.txt", kind: "file", bytes: 3, dataOffset: 1024),
                .init(path: "Link", kind: "symbolicLink", bytes: 0, dataOffset: 2048),
                .init(path: "Hard", kind: "hardLink", bytes: 0, dataOffset: 2560),
                .init(path: "Pipe", kind: "special", bytes: 0, dataOffset: 3072)
            ]
        case .empty:
            return [

            ]
        case .preview:
            return [
                .init(path: "Text.txt", kind: "file", bytes: 33, dataOffset: 512),
                .init(path: "Empty", kind: "file", bytes: 0, dataOffset: 1536),
                .init(path: "Maximum", kind: "file", bytes: 262144, dataOffset: 2048),
                .init(path: "TooLarge", kind: "file", bytes: 262145, dataOffset: 264704),
                .init(path: "Bytes", kind: "file", bytes: 256, dataOffset: 527872),
                .init(path: "._opaque", kind: "file", bytes: 6, dataOffset: 528896),
                .init(path: "Folder", kind: "directory", bytes: 0, dataOffset: 529920),
                .init(path: "Sym", kind: "symbolicLink", bytes: 0, dataOffset: 530432),
                .init(path: "Hard", kind: "hardLink", bytes: 0, dataOffset: 530944),
                .init(path: "FIFO", kind: "special", bytes: 0, dataOffset: 531456),
                .init(path: "Invalid0", kind: "file", bytes: 1, dataOffset: 531968),
                .init(path: "Invalid1", kind: "file", bytes: 1, dataOffset: 532992),
                .init(path: "Invalid2", kind: "file", bytes: 1, dataOffset: 534016),
                .init(path: "Invalid3", kind: "file", bytes: 2, dataOffset: 535040),
                .init(path: "Invalid4", kind: "file", bytes: 1, dataOffset: 536064),
                .init(path: "Invalid5", kind: "file", bytes: 3, dataOffset: 537088),
                .init(path: "Invalid6", kind: "file", bytes: 3, dataOffset: 538112),
                .init(path: "Invalid7", kind: "file", bytes: 2, dataOffset: 539136)
            ]
        case .paxSize:
            return [
                .init(path: "Résumé/nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn", kind: "file", bytes: 3, dataOffset: 1536)
            ]
        }
    }

    /// Derive adversarial headers from the independent Note.txt vector, rather
    /// than asking the writer under test to produce a matching interpretation.
    static func member(_ name: String, body: Data = Data("abc".utf8), type: UInt8 = 48) throws -> Data {
        try #require(name.utf8.count <= 100)
        var header = try memberHeader.get()
        header.replaceSubrange(0..<100, with: Data(repeating: 0, count: 100))
        header.replaceSubrange(0..<name.utf8.count, with: name.utf8)
        let size = String(format: "%011llo", UInt64(body.count)) + "\0"
        header.replaceSubrange(124..<136, with: size.utf8)
        header[156] = type
        checksum(&header)
        return header + body + Data(repeating: 0, count: (512 - body.count % 512) % 512)
    }

    static func terminated(_ members: Data) -> Data { members + Data(repeating: 0, count: 1024) }

    static func changingFirstHeader(_ source: Data, _ change: (inout Data) -> Void) -> Data {
        var result = source, header = source.subdata(in: 0..<512)
        change(&header); checksum(&header)
        result.replaceSubrange(0..<512, with: header)
        return result
    }

    private static func checksum(_ header: inout Data) {
        header.replaceSubrange(148..<156, with: Data(repeating: 32, count: 8))
        let sum = header.reduce(0) { $0 + Int($1) }
        header.replaceSubrange(148..<156, with: (String(format: "%06o", sum) + "\0 ").utf8)
    }

    private static let memberHeader: Result<Data, any Error> = Result {
        try bytes().subdata(in: 69_120..<69_632)
    }

    private static func vector(_ variant: Variant) -> (Int, String, String) {
        switch variant {
        case .ustar: return (71680, "ea65e08b4fb877d991bd60bf51c9361446dced7c5b1ff300af384d4ebe1dff0e", "eNrt01eQU2UAhuHYu1iwYI0dULMny0nWriisFZQmdkzIERazScgmCvaOvfdeULGg2HvvvYC9Cxaw93JlhAvHHUfHi2SY2eedyfyZ5OLMky9/azGfi8pNsXoW1GpJpWaftTqf//C+JZkOYvFUrAFVOyqZcu2Rsa5Z65z9+7eXKuOb5pb9k0FzKm3/Bu6fGN2Wy0WF+u2fDsP/s38YNMfigf0btf+AqD0blRPZtkKj92/+85XstH8ySIX2b0QLrds/d/SVj3w4/1pbZ4647MH35olvuc+hF9/39m+rbrbnQRfc/cbPK22824Hn3jHthxXSwypn3frKt937DB57+s0vfrV0sHPhlBufm7Xkhjvtf+J1T3+2WO/tR0+45okZC6/XGh1z1aMfLbD2NtkjL3/o/XnX2GrEYZfc/87vq22+18EX3vPmLytvsvu48+587ccVW3atnn3bq98tFw4pnzHlpa+XSe5SPHXy8190SwzIn3T9M58vvv4Obcdf++Qni/Tcdr9jJz728YLr9Bt51BUPfzDfmn33PfzSB96Nrb7F3odcdO9bv66y6R7jz7/r9Z96bDT8gHNun/r98qmhHWfe8vI3yzYPKp120wtfLtU0sP3kG56ducQGO445YdJTny7aa7tRx139+HR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHT0f6PH1JVqLeZzUbkpMaJYyoytRnV5RlArHYazz1qdzyD467s5nyeDdDKIxYNG/ADVjkqmXHt8F91/VFSIyplKlIv3LZXyUb9iNZuP4uWoPdNW6IjX8U+huaKBxUqUqIyr1PMZ/3n/gz5/v/9BSxiE7n8jymRHugSSJHWx/gBu0YLU")
        case .pax: return (10240, "6b6f50168af5ea943c1c92b547248325a9d785a42ed74d2b05080684d8685916", "eNrt0z0KwkAQQOGpPcWeIDubjYKFxNJScoNVAzaK5AdypZwjFzMqWAgpNyK+r9llmimGl9jEbveh25XhVFYShb5MvZo6//4/524cOTGdzKCtm1CN6+U/Ob82t9CcN8XQ1+1l6O31SxaC+RX5ePU87tEfUa+ybLJ/1Y/+vddlKkbpP7pwOBIBAAAAAAAAAAAAAADAD7sDdUeDWw==")
        case .gnu: return (10240, "26e0f59fe8af3ee3509b3d88bdb591e2b915d4c6f746c135454b53ecd09ef5c7", "eNrt000KgzAQQOE5Si7QZNL4s/UAuYR1UcRioer9tQSELlxarH3fYiZkOzzrrKvis7/Htu9kH5psbb0Gv77Tf1nmXkyUL5iGsX4ZI3/Kusdy/MvhhuA0939HXWTZZv+q4bP/oMHnYpT+d1ffGiIAAAAAAAAAAAAAAAD4YTOq+HrA")
        case .rootAndLinks: return (10240, "4e5d4442150cb26555d9bd8d487546632bed24840f83d567fda8062fedc38df6", "eNrt1UsKwjAUQNG3lGzAfGyTbsGBgluoGqGoVWr9LN/gzCLFSUTwnkkyCGRwSZ42kp1NKu+fazJc3+yDs1NRXr7gcu7rLl0p/0mbRTysYqf7e5+zfyjLkf7Fa39nbVmIsvTPrl6tBf9Lm3nT7vL//+Pvf7B3rgxe1FRr08Zr7Cbb435/vPH+c/Sf1d3m1/qn41aUyz+a6G+WzSn+WH8bKhdEBeY/AAAAAAAAAAAAAHzsAdHiUbA=")
        case .empty: return (10240, "84ff92691f909a05b224e1c56abb4864f01b4f8e3c854e4bb4c7baf1d3f6d652", "eNrtwQENAAAAwqD3T20ON6AAAAAAAAAAAACANwMoAAAB")
        case .preview: return (542720, "8b12c95e1c04f7fa81abd4a26453118aa434897d21d75414e11e51953e0318d0", "eNrt2Hdwk2UcwPHgBsW9Z9y7ZLxJHIiKgqAgKnUPjCRANKUlTTF1gXvvrbgVxYF7b3DvLW7FvfcemKt6auud5x9Jc/bz+ed57k3vnrv88n3zNvXZUrGuWCqGKihSlgyCtrWs/RqJBNE/923XU0EsEQpHQlXQ0lxMF8pHhrqmAdl8vjE8PD1i6qQe3XuPKjbk+zTl07nRvXu17Xv2CPF/1q+hqdha4TP+tf8O+2QqEei/GganS7mGloZOm3/0H+efiqXMvypKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADt1Dc2DkoXRmZDFRQpSwZB21r2tzXato3+ce3366l4KgiFI6EqaGkupgvlI0NdkwIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgA5CdGV9W4vZ5gqfESlLBkHbWtZ+jQR/2f92PZlKRELhSDXegJbmYrpQPrKrfgC6zTTzLLPONvsc3XvMOVfPueeZd775F1hwoYUXWXSxxZdYcqmllwkvu9zyK6y40sqrrLra6musWdcrEo3Fg0Qytdba66zbe70+62+wYd+NNu7Xf5MBAzfdbNDgzYdsseVWQ+u33mbb7bbfYceddt5l2K7p3YZnsiNGjsrtvke+YXRj05hCc7Fl7J6l1r323mff/caN3/+AAw86+JBDDzv8iCOPOvqYY487/oQTTzr5lFNPO/2MMyecdfY55553/gUXXjTx4ksmXXrZ5VdMvvKqq6+59rrrb7jxpptvufW22++48667p0y959777n/gwYcefuTRxx5/4smnnn7m2eeen/bCiy+9/Mqrr73+xvQ333r7nXffe/+DDz/6+JNPP/v8iy+/+vqbb7/7/ocff/r5lxldvf+6YY1N6TEt2c7sv/xqu/5T8VRc/9VQ+elTy/o35jPZQq9Q5/bffp+KJhKhcEL/FTe0taHiZ/zn+Ucj0Wj5/h+rz5aKdcVS0fwrZkC6kKnB+cdi5ef/qPlX/v4/sP+Qmpt/+a8jqVA46f5fcQNHj03nc5lI584/2uH5P5bw/A9V6j9ac/0n9V8N3SSg/1wmVnP9p/RfDeMkoP9cJt65/cc69B+P6r8apozXgP4zQa19/+u/OmZIQP+5TKJz+4937D/QfzVMHz9ZBPpP1lz/fv+vTv/7TxSB/lM19/+//qti2gQNAAAAdAW/Ajns3vc=")
        case .paxSize: return (10240, "5adb37c5b4486a279d67be8a46e29801e117c0107d8dc3413846b3fc0c96086a", "eNrt0z0KwkAQhuGtc4o9QbLZXZQUISktJTdYdUELRfIDwRvlHLmYUcFGUm5EfJ9mPqaZYvjiJE7Kres33h18LYJQL3NTaW3f+blPlU6NkL1YQNe0rp7Oi/+UyeZ087mJUpPJq2uPeTUOTXceh+TyJZHAYqpienYR9tePUq+sne3/RzZG2bWQiv4H53Z7SgAAAAAAAAAAAAAAAPDD7jQrhe4=")
        }
    }
}
