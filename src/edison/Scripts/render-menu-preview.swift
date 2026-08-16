import AppKit

let canvas = NSSize(width: 440, height: 180)
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas.width),
    pixelsHigh: Int(canvas.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor(calibratedWhite: 0.015, alpha: 1).setFill()
NSRect(origin: .zero, size: canvas).fill()

let scale: CGFloat = 2.0
let ox: CGFloat = 120
let oy: CGFloat = 5
func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    NSPoint(x: ox + x * scale, y: oy + y * scale)
}

let jersey = NSBezierPath()
jersey.move(to: p(34, 75))
jersey.line(to: p(66, 75))
jersey.line(to: p(78, 67))
jersey.line(to: p(96, 58))
jersey.line(to: p(88, 39))
jersey.line(to: p(73, 45))
jersey.line(to: p(73, 8))
jersey.line(to: p(27, 8))
jersey.line(to: p(27, 45))
jersey.line(to: p(12, 39))
jersey.line(to: p(4, 58))
jersey.line(to: p(22, 67))
jersey.close()
jersey.lineWidth = 6
jersey.lineJoinStyle = .round
NSColor.white.setStroke()
jersey.stroke()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
("10" as NSString).draw(
    in: NSRect(x: ox + 27 * scale, y: oy + 27 * scale, width: 46 * scale, height: 31 * scale),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 25 * scale, weight: .black),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph,
        .kern: -2 * scale
    ]
)

NSGraphicsContext.restoreGraphicsState()
let destination = CommandLine.arguments.dropFirst().first ?? "/private/tmp/edison-menu-preview.png"
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
