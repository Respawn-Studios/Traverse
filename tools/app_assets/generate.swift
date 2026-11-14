import AppKit
import ImageIO

// Original, reproducible vector artwork for development/beta identification.
// No final product name, third-party artwork, downloaded font or model asset.
private func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
}
private let white = color(1, 1, 1), ice = color(0.62, 0.91, 1)
private func gradient(_ c: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let values = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    c.drawLinearGradient(values, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
private func panel(_ c: CGContext, _ rect: CGRect, radius: CGFloat, colors: [CGColor], stroke: CGFloat = 0.45) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    c.saveGState()
    c.addPath(path); c.clip()
    gradient(c, colors, from: .init(x: rect.minX, y: rect.maxY), to: .init(x: rect.maxX, y: rect.minY))
    c.restoreGState()
    c.addPath(path); c.setStrokeColor(color(1, 1, 1, stroke)); c.setLineWidth(2); c.strokePath()
}
private func folder(_ c: CGContext) {
    c.saveGState()
    c.setShadow(offset: .init(width: 0, height: -18), blur: 28, color: color(0.02, 0.02, 0.12, 0.42))
    panel(c, .init(x: 201, y: 304, width: 622, height: 412), radius: 44,
        colors: [color(0.61, 0.78, 1), color(0.25, 0.43, 0.89)])
    c.restoreGState()
    panel(c, .init(x: 217, y: 648, width: 250, height: 115), radius: 29,
        colors: [color(0.66, 0.79, 1), color(0.41, 0.58, 0.96)])
    // A shallow inset suggests the opening without microscopic detail.
    panel(c, .init(x: 222, y: 585, width: 581, height: 83), radius: 23,
        colors: [color(0.07, 0.13, 0.40), color(0.20, 0.30, 0.66)], stroke: 0.15)
    panel(c, .init(x: 179, y: 254, width: 666, height: 397), radius: 47,
        colors: [color(0.50, 0.70, 1, 0.96), color(0.31, 0.46, 0.84, 0.94)])
    c.setStrokeColor(color(1, 1, 1, 0.18)); c.setLineWidth(2)
    c.move(to: .init(x: 218, y: 286)); c.addLine(to: .init(x: 805, y: 286)); c.strokePath()
}
private func compass(_ c: CGContext) {
    c.saveGState()
    c.translateBy(x: 512, y: 461)
    c.setShadow(offset: .init(width: 0, height: -8), blur: 15, color: color(0.03, 0.10, 0.32, 0.32))
    panel(c, .init(x: -119, y: -119, width: 238, height: 238), radius: 119,
        colors: [color(0.89, 0.97, 1, 0.96), color(0.50, 0.71, 0.98, 0.90)])
    c.setShadow(offset: .zero, blur: 0)
    c.rotate(by: -.pi / 6)
    let north = CGMutablePath()
    north.move(to: .init(x: 0, y: 101)); north.addLine(to: .init(x: -45, y: -4)); north.addLine(to: .init(x: 45, y: -4)); north.closeSubpath()
    c.addPath(north); c.setFillColor(color(0.23, 0.21, 0.62)); c.fillPath()
    let south = CGMutablePath()
    south.move(to: .init(x: 0, y: -101)); south.addLine(to: .init(x: -45, y: 4)); south.addLine(to: .init(x: 45, y: 4)); south.closeSubpath()
    c.addPath(south); c.setFillColor(white); c.fillPath()
    c.setFillColor(color(0.70, 0.92, 1)); c.fillEllipse(in: .init(x: -15, y: -15, width: 30, height: 30))
    c.restoreGState()
}
private func panes(_ c: CGContext) {
    c.saveGState()
    c.setShadow(offset: .init(width: 0, height: -22), blur: 32, color: color(0.02, 0.02, 0.12, 0.45))
    panel(c, .init(x: 158, y: 238, width: 708, height: 548), radius: 50,
        colors: [color(0.90, 0.95, 1), color(0.52, 0.66, 0.93)])
    c.restoreGState()
    panel(c, .init(x: 183, y: 263, width: 216, height: 431), radius: 25,
        colors: [color(0.17, 0.27, 0.58), color(0.20, 0.25, 0.57)], stroke: 0.15)
    for index in 0..<4 {
        panel(c, .init(x: 213, y: 615 - CGFloat(index) * 80, width: 153, height: 35), radius: 12,
            colors: [color(0.71, 0.86, 1, index == 0 ? 0.95 : 0.36), color(0.63, 0.73, 1, 0.32)], stroke: 0)
    }
    for index in 0..<3 {
        let y = 591 - CGFloat(index) * 115
        panel(c, .init(x: 448, y: y, width: 73, height: 78), radius: 15,
            colors: [white, ice], stroke: 0.8)
        panel(c, .init(x: 552, y: y + 34, width: 239 - CGFloat(index) * 25, height: 16), radius: 8,
            colors: [color(0.20, 0.28, 0.56, 0.80), color(0.27, 0.34, 0.64, 0.65)], stroke: 0)
    }
    for x: CGFloat in [211, 247, 283] {
        c.setFillColor(color(0.30, 0.40, 0.69, 0.75)); c.fillEllipse(in: .init(x: x, y: 729, width: 17, height: 17))
    }
}
private func route(_ c: CGContext) {
    folder(c)
    c.saveGState()
    c.setStrokeColor(color(0.91, 0.98, 1)); c.setLineWidth(27); c.setLineCap(.round); c.setLineJoin(.round)
    c.move(to: .init(x: 330, y: 399)); c.addLine(to: .init(x: 440, y: 510)); c.addLine(to: .init(x: 563, y: 406)); c.addLine(to: .init(x: 696, y: 540)); c.strokePath()
    c.setFillColor(color(0.25, 0.25, 0.68)); c.fillEllipse(in: .init(x: 289, y: 358, width: 82, height: 82))
    c.setFillColor(white); c.fillEllipse(in: .init(x: 665, y: 509, width: 62, height: 62))
    c.restoreGState()
}
private func render(size: Int, variant: String) -> CGImage {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setAllowsAntialiasing(true)
    c.scaleBy(x: CGFloat(size)/1024, y: CGFloat(size)/1024)
    c.saveGState()
    c.setShadow(offset: .init(width: 0, height: -10), blur: 18, color: color(0, 0, 0, 0.25))
    panel(c, .init(x: 61, y: 61, width: 902, height: 902), radius: 198,
        colors: [color(0.50, 0.38, 0.94), color(0.12, 0.23, 0.58)], stroke: 0.34)
    c.restoreGState()
    if variant == "B" { panes(c) }
    else if variant == "C" { route(c) }
    else { folder(c); compass(c) }
    return c.makeImage()!
}
private func write(_ image: CGImage, to url: URL) throws {
    guard !FileManager().fileExists(atPath: url.path),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw CocoaError(.fileWriteFileExists)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}
let arguments = CommandLine.arguments
guard arguments.count == 2 else { fatalError("Use one admitted output directory") }
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
guard output.resolvingSymlinksInPath() == output, output.lastPathComponent == "assets" else {
    fatalError("Expected nonredirected assets directory")
}
for variant in ["A", "B", "C"] {
    try write(render(size: 1024, variant: variant), to: output.appendingPathComponent("Candidate-" + variant + ".png"))
}
let set = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager().createDirectory(at: set, withIntermediateDirectories: false)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try write(render(size: size*scale, variant: "A"), to: set.appendingPathComponent(name))
    }
}
print("Generated original A/B/C previews and selected A iconset")
