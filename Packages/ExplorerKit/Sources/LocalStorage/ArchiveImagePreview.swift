import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ArchiveImagePreviewFailure: Error, Sendable { case invalidImage, dimensionsTooLarge }

/// One explicit, bounded raster preview. No pathname, body cache, external
/// preview plug-in or executable content reaches the presentation layer.
public struct ArchiveImagePreview: Sendable {
    public static let maximumSourceBytes: UInt64 = 16 << 20
    internal static let maximumPackedBytes: UInt64 = 24 << 20
    private static let maximumImagePixels = 32_000_000
    private static let maximumPreviewSide = 2_048
    public let image: CGImage
    public let width: Int, height: Int
    public let showsFirstFrame: Bool
    public var isDownsampled: Bool { image.width < width || image.height < height }

    public static func supportsFilename(_ name: String) -> Bool { type(for: name) != nil }

    private static func type(for name: String) -> UTType? {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": .png
        case "jpg", "jpeg": .jpeg
        case "gif": .gif
        case "tif", "tiff": .tiff
        default: nil
        }
    }

    internal static func decode(_ bytes: Data, filename: String, check: () throws -> Void) throws -> Self {
        try check()
        guard bytes.count <= maximumSourceBytes, let expected = type(for: filename),
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source).map({ $0 as String }) == expected.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ArchiveImagePreviewFailure.invalidImage }
        guard width <= 16_384, height <= 16_384, width <= maximumImagePixels / height else {
            throw ArchiveImagePreviewFailure.dimensionsTooLarge
        }
        let frames = CGImageSourceGetCount(source)
        guard frames > 0 else { throw ArchiveImagePreviewFailure.invalidImage }
        try check()
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPreviewSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              thumbnail.width <= maximumPreviewSide, thumbnail.height <= maximumPreviewSide else {
            throw ArchiveImagePreviewFailure.invalidImage
        }
        try check()
        let rotated = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
        return .init(image: thumbnail, width: rotated ? height : width, height: rotated ? width : height,
            showsFirstFrame: frames > 1)
    }
}
