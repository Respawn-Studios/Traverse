import CoreGraphics
import ExplorerCore
import Foundation

/// Render a small image from a guarded local snapshot. The original path never
/// reaches a thumbnail extension, and no derivative files are written.
public enum LocalFileThumbnail {
    static let maximumBytes = Int(ArchiveImagePreview.maximumSourceBytes)
    static let maximumSide = 192

    struct PackageLayout {
        let parts: Set<String>
        let thumbnails: Set<String>
        let mediaType: String?
    }

    public static func supports(_ entry: FileEntry) -> Bool {
        guard entry.kind == .file, !entry.isDataless, entry.url.isFileURL, let size = entry.byteCount,
              size > 0, entry.modifiedAt != nil else { return false }
        if packageLayout(for: entry.name) != nil { return true }
        guard size <= Int64(maximumBytes) else { return false }
        return entry.filenameExtension?.lowercased() == "pdf" || ArchiveImagePreview.supportsFilename(entry.name)
    }

    static func packageLayout(for filename: String) -> PackageLayout? {
        func office(_ mainPart: String) -> PackageLayout {
            .init(parts: ["[Content_Types].xml", "_rels/.rels", mainPart],
                  thumbnails: ["docProps/thumbnail.png", "docProps/thumbnail.jpeg", "docProps/thumbnail.jpg"], mediaType: nil)
        }
        func openDocument(_ subtype: String) -> PackageLayout {
            .init(parts: ["content.xml", "META-INF/manifest.xml"], thumbnails: ["Thumbnails/thumbnail.png"],
                  mediaType: "application/vnd.oasis.opendocument.\(subtype)")
        }
        switch (filename as NSString).pathExtension.lowercased() {
        case "docx": return office("word/document.xml")
        case "xlsx": return office("xl/workbook.xml")
        case "pptx": return office("ppt/presentation.xml")
        case "odt": return openDocument("text")
        case "ods": return openDocument("spreadsheet")
        case "odp": return openDocument("presentation")
        default: return nil
        }
    }

    /// Only the package directory and one common embedded raster thumbnail
    /// are read. Document parts, relationships and external targets are never opened.
    static func packageImage(_ source: PinnedLocalFileSource, layout: PackageLayout, check: () throws -> Void) throws -> CGImage? {
        var present = Set<String>()
        var selected: ZIPPayloadRecord?, typeRecord: ZIPPayloadRecord?
        let archiveLimit = 1 << 20, imageLimit: UInt64 = 512 << 10
        func reader(_ offset: UInt64, _ count: Int) throws -> Data {
            try source.read(offset, count, maximum: archiveLimit, check: check)
        }
        let limits = ZIPReadLimits(members: 4_096, nodes: 8_192, centralBytes: archiveLimit,
            nameBytes: archiveLimit, searchBytes: archiveLimit)
        _ = try ZIPMetadataParser.parse(length: UInt64(source.observed.size), limits: limits, capture: { member in
            if layout.parts.contains(member.name), member.kind == .file { present.insert(member.name) }
            if layout.mediaType != nil, member.name == "mimetype" {
                guard typeRecord == nil else { throw ZIPArchiveFailure.malformed }
                typeRecord = member
            }
            guard layout.thumbnails.contains(member.name) else { return }
            guard selected == nil else { throw ZIPArchiveFailure.malformed }
            selected = member
        }, cancelled: {
            do { try check(); return false } catch { return true }
        }, read: reader)
        guard layout.parts == present, let selected, selected.kind == .file,
              selected.logical > 0, selected.logical <= imageLimit else { return nil }
        let expected = layout.mediaType.map { Data($0.utf8) }
        var requested = [selected]
        if let expected {
            guard let typeRecord, typeRecord.kind == .file, typeRecord.method == 0,
                  typeRecord.logical == UInt64(expected.count), typeRecord.packed == typeRecord.logical else { return nil }
            requested.append(typeRecord)
        }
        let totalLimit = imageLimit + UInt64(expected?.count ?? 0)
        let bounds = ZIPContentLimits(files: requested.count, nodes: requested.count, memberBytes: imageLimit,
            jobBytes: totalLimit, packedBytes: totalLimit, expansionRatio: 512)
        let verified = try ZIPContentVerifier.prepare(requested, limits: bounds, check: check, read: reader)
        func contents(_ extent: ZIPPayloadExtent) throws -> Data {
            let record = extent.record
            var bytes = Data()
            bytes.reserveCapacity(Int(record.logical))
            try ZIPContentDecoder.check(method: record.method, packed: record.packed, logical: record.logical,
                expectedCRC: record.crc, check: check, read: { try reader(extent.payload + $0, $1) }, decoded: { _ in },
                consume: { bytes.append(contentsOf: $0) })
            return bytes
        }
        if let expected {
            guard let type = verified.extents.first(where: { $0.record.name == "mimetype" }),
                  try contents(type) == expected else { return nil }
        }
        guard let preview = verified.extents.first(where: { $0.record.name == selected.name }) else { return nil }
        return try ArchiveImagePreview.decode(contents(preview), filename: selected.name, maximumSide: maximumSide, check: check).image
    }

    static func render(_ bytes: Data, filename: String, check: () throws -> Void) throws -> CGImage? {
        try check()
        guard bytes.count <= maximumBytes else { return nil }
        let image: CGImage?
        if (filename as NSString).pathExtension.lowercased() == "pdf" {
            image = pdfPage(bytes)
        } else {
            image = try ArchiveImagePreview.decode(bytes, filename: filename, maximumSide: maximumSide, check: check).image
        }
        try check()
        return image
    }

    private static func pdfPage(_ bytes: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: bytes as CFData), let document = CGPDFDocument(provider),
              !document.isEncrypted || document.isUnlocked, let page = document.page(at: 1) else { return nil }
        let bounds = page.getBoxRect(.cropBox)
        let rotates = page.rotationAngle % 180 != 0
        let dimensions = rotates ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        guard dimensions.width.isFinite, dimensions.height.isFinite, dimensions.width > 0, dimensions.height > 0 else { return nil }
        let factor = CGFloat(maximumSide) / max(dimensions.width, dimensions.height)
        guard factor.isFinite else { return nil }
        let width = Int(max(1, min(CGFloat(maximumSide), (dimensions.width * factor).rounded())))
        let height = Int(max(1, min(CGFloat(maximumSide), (dimensions.height * factor).rounded())))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(target)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
