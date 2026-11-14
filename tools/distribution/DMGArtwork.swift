import AppKit
import Foundation
guard CommandLine.arguments.count == 2 else { fatalError("Output PNG required") }
// Keep Finder's logical 640 × 420 layout, with a crisp two-times backing image.
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 840,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: 640, height: 420)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
// The bitmap's logical size already gives this context its Retina transform.
let bounds = NSRect(x: 0, y: 0, width: 640, height: 420)
NSGradient(colors: [NSColor(red:0.055,green:0.065,blue:0.12,alpha:1),
    NSColor(red:0.19,green:0.17,blue:0.31,alpha:1)])!.draw(in:bounds,angle:28)
func glow(_ center: NSPoint, _ radius: CGFloat, _ color: NSColor) {
    NSGradient(starting: color, ending: color.withAlphaComponent(0))!.draw(
        fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}
glow(NSPoint(x: 80, y: 350), 420, NSColor(red:0.39,green:0.42,blue:0.72,alpha:0.28))
glow(NSPoint(x: 575, y: 80), 370, NSColor(red:0.43,green:0.31,blue:0.69,alpha:0.21))
let surface = NSBezierPath(roundedRect: NSRect(x: 18, y: 18, width: 604, height: 384), xRadius: 28, yRadius: 28)
NSColor(white: 1, alpha: 0.025).setFill(); surface.fill()
NSColor(white: 1, alpha: 0.11).setStroke(); surface.lineWidth = 0.75; surface.stroke()
func label(_ text:String, _ size:CGFloat, _ y:CGFloat, _ color:NSColor, _ weight:NSFont.Weight = .regular) {
    let attrs:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color]
    let value = text as NSString
    let width = value.size(withAttributes:attrs).width
    value.draw(at:NSPoint(x:(640-width)/2,y:y),withAttributes:attrs)
}
let white = NSColor(red:0.96,green:0.96,blue:1,alpha:1)
let lavender = NSColor(red:0.76,green:0.76,blue:0.93,alpha:1)
label("Welcome to Traverse",27,346,white,.semibold)
label("Your files. In full view.",12,322,lavender)
for (index, x) in [94.0,384.0].enumerated() {
    let card=NSBezierPath(roundedRect:NSRect(x:x,y:119,width:162,height:175),xRadius:27,yRadius:27)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
    shadow.shadowBlurRadius = 18; shadow.shadowOffset = NSSize(width: 0, height: -6); shadow.set()
    NSColor(white:1,alpha:0.055).setFill();card.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting:NSColor(white:1,alpha:0.045),ending:NSColor(white:1,alpha:0))!.draw(in:card,angle:90)
    NSColor(red:0.84,green:0.85,blue:1,alpha:0.22).setStroke();card.lineWidth=0.75;card.stroke()
    // Finder chooses its own label ink for a picture background. Give the
    // actual native filenames a light inset rather than drawing duplicate text.
    let labelPlate = NSBezierPath(roundedRect: NSRect(x: x + 24, y: 138, width: 114, height: 27),
        xRadius: 11, yRadius: 11)
    NSColor(red:0.82,green:0.83,blue:0.94,alpha:0.76).setFill(); labelPlate.fill()
    let step = NSBezierPath(ovalIn: NSRect(x: x + 12, y: 259, width: 22, height: 22))
    NSColor(white: 1, alpha: 0.07).setFill(); step.fill()
    let attrs: [NSAttributedString.Key:Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: lavender]
    (String(index + 1) as NSString).draw(at: NSPoint(x: x + 19.6, y: 263.5), withAttributes: attrs)
}
let arrow=NSBezierPath();arrow.move(to:NSPoint(x:282,y:218));arrow.line(to:NSPoint(x:358,y:218));arrow.move(to:NSPoint(x:347,y:229));arrow.line(to:NSPoint(x:358,y:218));arrow.line(to:NSPoint(x:347,y:207));arrow.lineCapStyle = .round;arrow.lineJoinStyle = .round;arrow.lineWidth=2.25;lavender.withAlphaComponent(0.85).setStroke();arrow.stroke()
label("Drag to Applications",18,77,white,.semibold)
label("Then open Traverse from Applications to get started.",11,53,lavender)
label("PRIVATE BETA   ·   APPLE SILICON   ·   macOS 15+",9,31,lavender.withAlphaComponent(0.75),.medium)
NSGraphicsContext.restoreGraphicsState()
let data = bitmap.representation(using:.png,properties:[:])!
try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]),options:.withoutOverwriting)
