import AppKit

/// Capture bounded visible content without asking native material containers to
/// render into a bitmap. Their backdrop stays live throughout a transition.
@MainActor enum NativeForegroundSnapshot {
    private static let maximumPixels: CGFloat = 8_000_000

    static func fits(_ sizes: [NSSize], scale: CGFloat) -> Bool {
        !sizes.isEmpty && sizes.reduce(0) { $0 + pixels(for: $1, scale: scale) } <= maximumPixels
    }

    private static func pixels(for size: NSSize, scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0, size.width > 0, size.height > 0 else { return .infinity }
        return ceil(size.width * scale) * ceil(size.height * scale)
    }

    static func capture(in parent: NSView, views: [NSView]) -> NSImage? {
        let scale = parent.window?.backingScaleFactor ?? 1, size = parent.bounds.size
        guard size.width > 1, size.height > 1, fits([size], scale: scale),
              let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
                pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        canvas.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        context.cgContext.clear(CGRect(origin: .zero, size: size))
        var pixels: CGFloat = 0
        for item in views.prefix(256) where item.window === parent.window && item.isDescendant(of: parent)
            && !item.isHiddenOrHasHiddenAncestor {
            let target = item.convert(item.visibleRect, to: parent).intersection(parent.bounds)
            guard !target.isEmpty else { continue }
            let local = item.convert(target, from: parent)
            pixels += Self.pixels(for: local.size, scale: scale)
            guard pixels <= maximumPixels else { return nil }
            guard let bitmap = item.bitmapImageRepForCachingDisplay(in: local) else { continue }
            item.effectiveAppearance.performAsCurrentDrawingAppearance { item.cacheDisplay(in: local, to: bitmap) }
            let part = NSImage(size: local.size); part.addRepresentation(bitmap)
            NSGraphicsContext.current = context
            // The bitmap has a bottom-left origin even when a native split's
            // coordinate system is flipped for row layout.
            let destination = NSRect(x: target.minX - parent.bounds.minX,
                y: parent.isFlipped ? parent.bounds.maxY - target.maxY : target.minY - parent.bounds.minY,
                width: target.width, height: target.height)
            part.draw(in: destination,
                from: NSRect(origin: .zero, size: local.size), operation: .sourceOver, fraction: 1,
                respectFlipped: false, hints: nil)
        }
        context.flushGraphics()
        let image = NSImage(size: size); image.addRepresentation(canvas)
        return image
    }
}
