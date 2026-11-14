import Foundation

public enum TARTextPreviewFailure: Error, Equatable, Sendable {
    case unsupported, tooLarge, notText, limitReached
}

/// An exact ephemeral catalog choice, never offsets, a URL or access authority.
public struct TARTextPreviewSelection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    internal let binding:TARSourceBinding,record:TARRecord
    public var displayName:String{record.path.split(separator:"/").last.map(String.init) ?? "TAR preview"}
    public var description:String{"Selected TAR preview member"}
    public var debugDescription:String{description}
}

/// Complete observed bytes. TAR has no per-member content checksum to verify.
public struct TARTextPreview: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumUTF8Bytes:UInt64 = 256 << 10
    public let text:String,utf8Bytes:UInt64
    public var description:String{"TAR text preview (\(utf8Bytes) UTF-8 bytes)"}
    public var debugDescription:String{description}
    internal static func decode(_ bytes:Data,check:()throws->Void)throws->Self {
        try check()
        guard UInt64(bytes.count)<=maximumUTF8Bytes else{throw TARTextPreviewFailure.tooLarge}
        guard let text=String(data:bytes,encoding:.utf8) else{throw TARTextPreviewFailure.notText}
        for scalar in text.unicodeScalars {
            try check();let value=scalar.value
            guard (value>=32 || [9,10,13].contains(value)), !(0x7f...0x9f).contains(value),
                  ![0x061c,0x200e,0x200f].contains(value), !(0x202a...0x202e).contains(value),
                  !(0x2066...0x2069).contains(value) else{throw TARTextPreviewFailure.notText}
        }
        try check();return .init(text:text,utf8Bytes:UInt64(bytes.count))
    }
}

public struct TARBytePreview: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumBytes=TARTextPreview.maximumUTF8Bytes
    public let hexadecimalText:String,byteCount:UInt64
    public var description:String{"TAR byte preview (\(byteCount) bytes)"}
    public var debugDescription:String{description}
    /// The same inert 16-byte ASCII layout used by ZIP, without ZIP CRC claims.
    internal static func render(_ bytes:Data,check:()throws->Void)throws->String {
        guard UInt64(bytes.count)<=maximumBytes else{throw TARTextPreviewFailure.tooLarge}
        try check();let digits=Array("0123456789ABCDEF".utf8),values=[UInt8](bytes)
        var output=[UInt8]();output.reserveCapacity(((values.count+15)/16)*78)
        for offset in stride(from:0,to:values.count,by:16) {
            try check()
            for shift in stride(from:28,through:0,by:-4){output.append(digits[(offset>>shift)&15])}
            output.append(contentsOf:[32,32]);let count=min(16,values.count-offset)
            for column in 0..<16 {
                if column>0{output.append(32)}
                if column<count{let byte=values[offset+column];output.append(digits[Int(byte>>4)]);output.append(digits[Int(byte&15)])}
                else{output.append(contentsOf:[32,32])}
            }
            output.append(contentsOf:[32,32,124])
            for column in 0..<16 {
                if column<count{let byte=values[offset+column];output.append((32...126).contains(byte) ? byte:46)}
                else{output.append(32)}
            }
            output.append(contentsOf:[124,10])
        }
        try check();return String(decoding:output,as:UTF8.self)
    }
}

internal struct TARTextPreviewLimits: Sendable {
    var seconds: Double = 5
    var maximumBytes = TARTextPreview.maximumUTF8Bytes
    static let image = Self(seconds: 8, maximumBytes: ArchiveImagePreview.maximumSourceBytes)
}

internal enum TARTextPreviewReader {
    static func readChecked<Output>(_ selection:TARTextPreviewSelection,excluding roots:[URL],limits:TARReadLimits,
        previewLimits:TARTextPreviewLimits,check cancellation:@escaping()throws->Void,
        probe:(@Sendable(TARArchiveReader.Stage,UInt64,Int)throws->Void)?,
        transform:(Data,()throws->Void)throws->Output)throws->Output {
        let began=ProcessInfo.processInfo.systemUptime
        func check()throws{
            try cancellation()
            guard ProcessInfo.processInfo.systemUptime-began<previewLimits.seconds else{throw TARTextPreviewFailure.limitReached}
        }
        try check()
        let source=try PinnedLocalFileSource(selection.binding.source,excluding:roots)
        let compressed=selection.binding.compressed
        func validateSource()throws {
            try check()
            guard source.observed==selection.binding.stamp else{throw TARArchiveFailure.changed}
            if let compressed {
                guard compressed.original.source==source.url,
                      compressed.original.stamp==source.observed,
                      (try? compressed.original.security.reobserve(source))==compressed.original.security else{
                    throw TARArchiveFailure.changed
                }
                try compressed.validate()
            }
            try source.validate();try check()
        }
        func validateMetadata()throws {
            try validateSource()
            let parsed:TARParsedDirectory
            if let compressed {
                var preparedLimits=limits;preparedLimits.sourceBytes=TARCompressedDecoder.maximumBytes
                parsed=try TARMetadataParser.parse(length:compressed.decodedBytes,limits:preparedLimits,
                    check:check,read:{offset,count in
                        let bytes=try compressed.read(offset,count,check:check)
                        try probe?(.metadata,offset,count);return bytes
                    })
            } else {
                parsed=try TARSourceCatalog.parse(source,limits:limits,check:check,
                    didRead:{try probe?(.metadata,$0,$1)})
            }
            let record=selection.record
            guard parsed.witness==selection.binding.witness else{throw TARArchiveFailure.changed}
            var matches=0
            for candidate in parsed.records {
                try check()
                if candidate.ordinal==record.ordinal {
                    guard candidate.kind==record.kind,candidate.bytes==record.bytes,
                          candidate.headerOffset==record.headerOffset,candidate.dataOffset==record.dataOffset,
                          candidate.path.utf8.elementsEqual(record.path.utf8) else{throw TARArchiveFailure.changed}
                    matches+=1
                }
            }
            guard matches==1 else{throw TARArchiveFailure.changed}
            try validateSource()
        }
        do {
            try validateSource()
            try probe?(.opened,0,0);try validateMetadata()
            let result:Result<Output,Error> = Result {
                let record=selection.record,length=compressed?.decodedBytes ?? UInt64(source.observed.size)
                guard record.kind == .file else{throw TARTextPreviewFailure.unsupported}
                guard record.bytes<=previewLimits.maximumBytes else{throw TARTextPreviewFailure.tooLarge}
                guard record.dataOffset<=length,record.bytes<=length-record.dataOffset else{throw TARArchiveFailure.changed}
                try compressed?.verifyDigest(check:check)
                try probe?(.previewing,record.dataOffset,0);try check()
                var bytes=Data();bytes.reserveCapacity(Int(record.bytes));var offset:UInt64=0
                while offset<record.bytes {
                    let count=Int(min(65_536,record.bytes-offset))
                    let chunk:Data
                    if let compressed { chunk=try compressed.read(record.dataOffset+offset,count,check:check) }
                    else { chunk=try source.read(record.dataOffset+offset,count,maximum:65_536,check:check) }
                    try probe?(.previewPayload,record.dataOffset+offset,count)
                    bytes.append(chunk);offset+=UInt64(count)
                }
                try check();try probe?(.previewTransform,0,0)
                return try transform(bytes,check)
            }
            try probe?(.previewFinalMetadata,0,0);try validateMetadata()
            try probe?(.previewComplete,0,0);try validateSource()
            return try result.get()
        } catch {
            // Failed transforms pass the final metadata check above. Failures
            // during either metadata pass still validate the actual source.
            try validateSource();throw error
        }
    }
}
