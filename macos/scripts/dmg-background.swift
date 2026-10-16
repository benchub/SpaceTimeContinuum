// Draws the .dmg window background: an arrow pointing from the app to Applications.
// Usage: swift dmg-background.swift out.png
import AppKit

let points = NSSize(width: 660, height: 400)
let scale = 2
guard CommandLine.arguments.count == 2,
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(points.width) * scale, pixelsHigh: Int(points.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: rep)
else {
    FileHandle.standardError.write(Data("usage: dmg-background.swift out.png\n".utf8))
    exit(1)
}
// Declaring the size in points makes the 2x pixels render sharp (144 dpi) in Finder.
rep.size = points

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
ctx.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
NSRect(origin: .zero, size: points).fill()

// Icons sit at y = 200 (from the top) in a 400pt-high window, i.e. y = 200 from the bottom too.
let y: CGFloat = 200
let arrow = NSBezierPath()
arrow.lineWidth = 8
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 260, y: y))
arrow.line(to: NSPoint(x: 395, y: y))
arrow.move(to: NSPoint(x: 365, y: y + 30))
arrow.line(to: NSPoint(x: 400, y: y))
arrow.line(to: NSPoint(x: 365, y: y - 30))
NSColor(calibratedWhite: 0.55, alpha: 1).setStroke()
arrow.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
