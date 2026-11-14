import Darwin
import Foundation

/// Pins a sealed app-owned catalog on the existing result read lane. Closing
/// a view cannot release its files while a new scanner is replaying them.
final class AnalysisRefreshBaselineLease: @unchecked Sendable {
    let descriptor: Int32
    let catalogID: UUID
    private let release: @Sendable () -> Void
    private let verification: @Sendable () throws -> Void
    init(descriptor: Int32, catalogID: UUID, verification: @escaping @Sendable () throws -> Void,
         release: @escaping @Sendable () -> Void) {
        self.descriptor = descriptor; self.catalogID = catalogID; self.release = release; self.verification = verification
    }
    func validate() throws { try verification() }
    deinit { close(descriptor); release() }
}

/// One bounded descriptor-only request, unlinked from the new private session
/// before child launch. No source names enter process arguments or diagnostics.
final class AnalysisRefreshInput {
    let baseline: AnalysisRefreshBaselineLease
    let descriptor: Int32
    init(baseline: AnalysisRefreshBaselineLease, dirty: [AnalysisRefreshDirtyDirectory], files: AnalysisStoreFiles) throws {
        guard dirty.count <= 256 else { throw StorageScanFailure.invalidOutput }
        var data = Data("TRVREF2\n".utf8)
        data.append(contentsOf: baseline.catalogID.uuidString.utf8)
        func integer(_ value: Int) { var big = UInt32(value).bigEndian; withUnsafeBytes(of: &big) { data.append(contentsOf: $0) } }
        integer(dirty.count)
        for directory in dirty {
            let path = directory.path
            guard path.count <= 8192, path.isEmpty || path.split(separator: 47, omittingEmptySubsequences: false)
                .allSatisfy({ StoredAnalysisPage.validName(Data($0)) }) else { throw StorageScanFailure.invalidOutput }
            data.append(directory.recursive ? 1 : 0)
            integer(path.count); data.append(path)
        }
        guard data.count <= 65_536 else { throw StorageScanFailure.invalidOutput }
        let name = "refresh-input-" + UUID().uuidString
        let writer = openat(files.parent, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard writer >= 0 else { throw StorageScanFailure.resourceLimit }
        defer { close(writer) }
        let reader = openat(files.parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        var written = stat(), opened = stat(), named = stat()
        guard reader >= 0, fstat(writer, &written) == 0, fstat(reader, &opened) == 0,
              written.st_dev == opened.st_dev, written.st_ino == opened.st_ino,
              fstatat(files.parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == written.st_dev, named.st_ino == written.st_ino,
              unlinkat(files.parent, name, 0) == 0 else {
            if reader >= 0 { close(reader) }
            // Uncertain private preparation remains owned by the result-store
            // recovery guard; never unlink a possibly substituted name here.
            throw StorageScanFailure.changed
        }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(writer, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw StorageScanFailure.resourceLimit }
                    offset += count
                }
            }
        } catch { close(reader); throw error }
        self.baseline = baseline; descriptor = reader
    }
    var descriptors: [(Int32, Int32)] { [(7, baseline.descriptor), (8, descriptor)] }
    deinit { close(descriptor) }
}
