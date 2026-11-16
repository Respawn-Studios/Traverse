import AppKit

/// Capture bounded visible content without asking native material containers to
/// render into a bitmap. Their backdrop stays live throughout a transition.
@MainActor enum NativeForegroundSnapshot {
    static func capture(in parent: NSView, views: [NSView]) -> NSImage? {
        let scale = parent.window?.backingScaleFactor ?? 1, size = parent.bounds.size
        guard size.width > 1, size.height > 1, size.width * size.height * scale * scale <= 8_000_000,
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
            pixels += local.width * local.height * scale * scale
            guard pixels <= 8_000_000 else { return nil }
            guard let bitmap = item.bitmapImageRepForCachingDisplay(in: local) else { continue }
            item.effectiveAppearance.performAsCurrentDrawingAppearance { item.cacheDisplay(in: local, to: bitmap) }
            let part = NSImage(size: local.size); part.addRepresentation(bitmap)
            NSGraphicsContext.current = context
            part.draw(in: target.offsetBy(dx: -parent.bounds.minX, dy: -parent.bounds.minY),
                from: NSRect(origin: .zero, size: local.size), operation: .sourceOver, fraction: 1,
                respectFlipped: false, hints: nil)
        }
        context.flushGraphics()
        let image = NSImage(size: size); image.addRepresentation(canvas)
        return image
    }
}
