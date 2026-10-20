import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let icons: [(String, Int)] = [
    ("icon_16x16@1x.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32@1x.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128@1x.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256@1x.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512@1x.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, pixels) in icons {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Bitmap unavailable") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    cg.setFillColor(NSColor.clear.cgColor)
    cg.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    let tile = NSBezierPath(roundedRect: CGRect(x: 72, y: 72, width: 880, height: 880), xRadius: 192, yRadius: 192)
    NSColor(calibratedRed: 0.065, green: 0.100, blue: 0.165, alpha: 1).setFill()
    tile.fill()

    cg.setStrokeColor(NSColor(calibratedRed: 0.19, green: 0.31, blue: 0.43, alpha: 1).cgColor)
    cg.setLineWidth(22)
    cg.strokeEllipse(in: CGRect(x: 241, y: 241, width: 542, height: 542))
    cg.setStrokeColor(NSColor(calibratedRed: 0.20, green: 0.89, blue: 0.82, alpha: 1).cgColor)
    cg.setLineWidth(36)
    cg.setLineCap(.round)
    cg.addArc(center: CGPoint(x: 512, y: 512), radius: 271, startAngle: .pi * 0.18, endAngle: .pi * 0.89, clockwise: false)
    cg.strokePath()

    let mark = NSBezierPath()
    mark.move(to: CGPoint(x: 335, y: 650))
    mark.line(to: CGPoint(x: 648, y: 650))
    mark.line(to: CGPoint(x: 376, y: 374))
    mark.line(to: CGPoint(x: 692, y: 374))
    mark.lineWidth = 78
    mark.lineCapStyle = .round
    mark.lineJoinStyle = .round
    NSColor.white.setStroke()
    mark.stroke()

    cg.setFillColor(NSColor(calibratedRed: 0.20, green: 0.89, blue: 0.82, alpha: 1).cgColor)
    cg.fillEllipse(in: CGRect(x: 677, y: 690, width: 62, height: 62))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG unavailable") }
    try data.write(to: outputDirectory.appendingPathComponent(name))
}
