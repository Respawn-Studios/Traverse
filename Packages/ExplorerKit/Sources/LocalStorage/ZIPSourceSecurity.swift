import CoreServices
import CryptoKit
import Darwin
import Foundation
@_spi(ArchiveProduction) import FileOperations

/// Source admission and private-output inheritance. Raw security flags remain
/// opaque. This never changes a source, removes quarantine or grants approval.
internal enum ZIPSourceSecurity {
    static func nativeAuthoredWitness(_ descriptor: Int32) throws -> AuthoredZIPSecurityWitness {
        .init(quarantine: try quarantine(descriptor), provenance: try provenance(descriptor))
    }
    /// Held only by a prepared local Create inventory. It never leaves the
    /// process, enters history, or supplies bytes to a produced ZIP.
    struct CreationInputWitness: Equatable, Sendable {
        let quarantine: ExtractionWitness
        let provenance: Data?
        var marked: Bool { quarantine.expectedQuarantineSHA256 != nil }
    }
    static func creationInputWitness(_ descriptor: Int32, url: URL,
                                     allowingNativeMark: Bool) throws -> CreationInputWitness {
        if !allowingNativeMark {
            try requireUnquarantinedAPFS(descriptor, url: url)
            return .init(quarantine: .init(bytes: nil), provenance: nil)
        }
        let quarantine = try extractionWitness(descriptor, url: url,
            allowingInheritance: true)
        let provenance = try provenance(descriptor)
        guard try ZIPSourceSecurity.provenance(descriptor) == provenance else {
            throw ZIPExtractionFailure.quarantinedOrUncertain
        }
        return .init(quarantine: quarantine, provenance: provenance)
    }
    struct DownloadedStageWitness: Equatable, Sendable { fileprivate let mark: Data? }
    /// Capture the just-created private stage before its first body write.
    static func downloadedStageWitness(_ descriptor: Int32) throws -> DownloadedStageWitness {
        .init(mark: try quarantine(descriptor))
    }
    static func requireUnquarantinedAPFS(_ descriptor: Int32, url: URL) throws {
        try requireAPFS(descriptor)
        guard try quarantine(descriptor) == nil else { throw ZIPExtractionFailure.quarantinedOrUncertain }
        let properties = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.quarantinePropertiesKey])
        guard properties.quarantineProperties == nil else { throw ZIPExtractionFailure.quarantinedOrUncertain }
    }
    private static func requireAPFS(_ descriptor: Int32) throws {
        var facts = statfs()
        guard fstatfs(descriptor, &facts) == 0 else { throw ZIPExtractionFailure.unsupportedSource }
        let name = withUnsafePointer(to: &facts.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        guard name == "apfs" else { throw ZIPExtractionFailure.unsupportedSource }
    }

    struct ExtractionWitness: Equatable, Sendable {
        fileprivate let bytes: Data?
        /// The archive's complete raw mark, retained independently of any
        /// later output receipt. Unmarked archives keep their existing policy.
        var expectedQuarantineSHA256: Data? { bytes.map { Data(SHA256.hash(data: $0)) } }
        /// A fresh output may gain OS metadata, but its quarantine must remain
        /// exactly the source mark (including absence) before publication.
        func matchesOutput(_ descriptor: Int32) throws -> Bool {
            try ZIPSourceSecurity.quarantine(descriptor) == bytes
        }
        /// Compare the same output snapshot used for the producer's final
        /// metadata witness, including the absence of a source mark.
        func matchesOutputMark(_ mark: Data?) -> Bool { mark == bytes }
        /// Only fresh private output descriptors are admitted by the producer.
        /// Conflicting OS-assigned metadata is never overwritten or weakened.
        func apply(to descriptor: Int32) throws {
            guard let bytes else { return }
            if let current = try ZIPSourceSecurity.quarantine(descriptor) {
                guard current == bytes else { throw ZIPExtractionFailure.quarantinedOrUncertain }
                return
            }
            guard
                bytes.withUnsafeBytes({
                    fsetxattr(descriptor, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_CREATE)
                }) == 0,
                try ZIPSourceSecurity.quarantine(descriptor) == bytes
            else { throw ZIPExtractionFailure.quarantinedOrUncertain }
        }
        /// A received-file producer can encounter different native sandbox
        /// marks on its owned spool and a fresh private stage in the selected
        /// destination. Only the observed 0086 source / 0082 stage pair with
        /// identical remaining bytes and provenance may be restored to the
        /// complete source mark. If the OS refuses, publication fails closed.
        /// Other archive consumers keep `apply(to:)`.
        func applyToDownloadedFile(from source: Int32, to descriptor: Int32,
            stageAtCreation: DownloadedStageWitness) throws {
            try applyToDownloadedFile(from: source, to: descriptor, stageAtCreation: stageAtCreation,
                readProvenance: ZIPSourceSecurity.provenance)
        }
        #if DEBUG
        func applyToDownloadedFileForQualification(from source: Int32, to descriptor: Int32,
            stageAtCreation: DownloadedStageWitness,
            readProvenance: (Int32) throws -> Data?) throws {
            try applyToDownloadedFile(from: source, to: descriptor, stageAtCreation: stageAtCreation,
                readProvenance: readProvenance)
        }
        #endif
        private func applyToDownloadedFile(from source: Int32, to descriptor: Int32,
            stageAtCreation: DownloadedStageWitness,
            readProvenance: (Int32) throws -> Data?) throws {
            guard let bytes else {
                do { try apply(to: descriptor) }
                catch {
                    FileOperationDiagnostics.receivedFileMetadataFailure(.downloadStageMark)
                    throw error
                }
                return
            }
            let observed: Data?
            do { observed = try ZIPSourceSecurity.quarantine(descriptor) }
            catch {
                FileOperationDiagnostics.receivedFileMetadataFailure(.downloadStageMark)
                throw error
            }
            guard observed == stageAtCreation.mark else {
                FileOperationDiagnostics.receivedFileMetadataFailure(.downloadStageMark)
                throw ZIPExtractionFailure.quarantinedOrUncertain
            }
            guard let current = observed, current != bytes else {
                do { try apply(to: descriptor) }
                catch {
                    FileOperationDiagnostics.receivedFileMetadataFailure(.downloadStageMark)
                    throw error
                }
                return
            }
            guard bytes.starts(with: Data("0086;".utf8)),
                  current.starts(with: Data("0082;".utf8)),
                  current.count == bytes.count,
                  current.dropFirst(5).elementsEqual(bytes.dropFirst(5)) else {
                FileOperationDiagnostics.receivedFileMetadataFailure(.downloadTransitionShape)
                throw ZIPExtractionFailure.quarantinedOrUncertain
            }
            let sourceMark: Data?
            do { sourceMark = try ZIPSourceSecurity.quarantine(source) }
            catch {
                FileOperationDiagnostics.receivedFileMetadataFailure(.downloadSourceMark)
                throw error
            }
            guard sourceMark == bytes else {
                FileOperationDiagnostics.receivedFileMetadataFailure(.downloadSourceMark)
                throw ZIPExtractionFailure.quarantinedOrUncertain
            }
            let sourceProvenance: Data?
            do { sourceProvenance = try readProvenance(source) }
            catch {
                FileOperationDiagnostics.receivedFileMetadataFailure(.downloadSourceProvenance)
                throw error
            }
            guard let provenance = sourceProvenance else {
                FileOperationDiagnostics.receivedFileMetadataFailure(.downloadSourceProvenance)
                throw ZIPExtractionFailure.quarantinedOrUncertain
            }
            let stageProvenance: Data?
            do { stageProvenance = try readProvenance(descriptor) }
            catch {
                FileOperationDiagnostics.receivedFileMetadataFailure(.downloadStageProvenance)
                throw error
            }
            guard stageProvenance == provenance else {
                FileOperationDiagnostics.receivedFileMetadataFailure(.downloadStageProvenance)
                throw ZIPExtractionFailure.quarantinedOrUncertain
            }
            let replaced = bytes.withUnsafeBytes({
                fsetxattr(descriptor, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_REPLACE)
            })
            guard replaced == 0 else {
                let status = errno
                FileOperationDiagnostics.receivedFileMetadataFailure(.downloadMarkReplace, nativeError: status)
                throw ZIPExtractionFailure.quarantinedOrUncertain
            }
            let finalStageMark: Data?
            do { finalStageMark = try ZIPSourceSecurity.quarantine(descriptor) }
            catch {
                FileOperationDiagnostics.receivedFileMetadataFailure(.downloadStageRecheck)
                throw error
            }
            guard finalStageMark == bytes else {
                FileOperationDiagnostics.receivedFileMetadataFailure(.downloadStageRecheck)
                throw ZIPExtractionFailure.quarantinedOrUncertain
            }
            let finalSourceMark: Data?
            do { finalSourceMark = try ZIPSourceSecurity.quarantine(source) }
            catch {
                FileOperationDiagnostics.receivedFileMetadataFailure(.downloadSourceRecheck)
                throw error
            }
            guard finalSourceMark == bytes else {
                FileOperationDiagnostics.receivedFileMetadataFailure(.downloadSourceRecheck)
                throw ZIPExtractionFailure.quarantinedOrUncertain
            }
            let finalSourceProvenance: Data?, finalStageProvenance: Data?
            do {
                finalSourceProvenance = try readProvenance(source)
                finalStageProvenance = try readProvenance(descriptor)
            } catch {
                FileOperationDiagnostics.receivedFileMetadataFailure(.downloadProvenanceRecheck)
                throw error
            }
            guard finalSourceProvenance == provenance, finalStageProvenance == provenance else {
                FileOperationDiagnostics.receivedFileMetadataFailure(.downloadProvenanceRecheck)
                throw ZIPExtractionFailure.quarantinedOrUncertain
            }
        }
    }

    static func extractionWitness(_ descriptor: Int32, url: URL, allowingInheritance: Bool) throws -> ExtractionWitness
    {
        try requireAPFS(descriptor)
        let raw = try quarantine(descriptor)
        // A new URL avoids a cached Foundation resource-value observation.
        let properties = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.quarantinePropertiesKey])
            .quarantineProperties
        if raw == nil {
            guard properties == nil else { throw ZIPExtractionFailure.quarantinedOrUncertain }
        } else {
            guard allowingInheritance, let properties, !properties.isEmpty, properties.count <= 32,
                let agent = properties[kLSQuarantineAgentNameKey as String] as? String, !agent.isEmpty,
                let date = properties[kLSQuarantineTimeStampKey as String] as? Date,
                date.timeIntervalSince1970.isFinite,
                properties.allSatisfy({ key, value in key.utf8.count <= 256 && boundedProperty(value) })
            else {
                throw ZIPExtractionFailure.quarantinedOrUncertain
            }
        }
        guard try quarantine(descriptor) == raw else { throw ZIPExtractionFailure.quarantinedOrUncertain }
        return .init(bytes: raw)
    }
    private static func boundedProperty(_ value: Any) -> Bool {
        switch value {
        case let value as String: value.utf8.count <= 4096
        case let value as URL: value.absoluteString.utf8.count <= 4096
        case let value as Date: value.timeIntervalSince1970.isFinite
        case let value as NSNumber: value.doubleValue.isFinite
        case let value as Data: value.count <= 4096
        default: false
        }
    }
    private static func quarantine(_ descriptor: Int32) throws -> Data? {
        let size = fgetxattr(descriptor, "com.apple.quarantine", nil, 0, 0, 0)
        if size < 0, errno == ENOATTR { return nil }
        guard size > 0, size <= 4096 else { throw ZIPExtractionFailure.quarantinedOrUncertain }
        var bytes = Data(count: size)
        guard
            bytes.withUnsafeMutableBytes({ fgetxattr(descriptor, "com.apple.quarantine", $0.baseAddress, size, 0, 0) })
                == size
        else {
            throw ZIPExtractionFailure.quarantinedOrUncertain
        }
        return bytes
    }
    private static func provenance(_ descriptor: Int32) throws -> Data? {
        let size = fgetxattr(descriptor, "com.apple.provenance", nil, 0, 0, 0)
        if size < 0, errno == ENOATTR { return nil }
        guard size > 0, size <= 4096 else { throw ZIPExtractionFailure.quarantinedOrUncertain }
        var bytes = Data(count: size)
        guard bytes.withUnsafeMutableBytes({
            fgetxattr(descriptor, "com.apple.provenance", $0.baseAddress, size, 0, 0)
        }) == size else { throw ZIPExtractionFailure.quarantinedOrUncertain }
        return bytes
    }
}
