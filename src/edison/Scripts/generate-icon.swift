import AppKit

let canvasSize = NSSize(width: 1024, height: 1024)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Unable to create icon bitmap\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
defer { NSGraphicsContext.restoreGraphicsState() }

NSColor.clear.setFill()
NSRect(origin: .zero, size: canvasSize).fill()

let tileRect = NSRect(x: 72, y: 72, width: 880, height: 880)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 210, yRadius: 210)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
shadow.shadowBlurRadius = 34
shadow.shadowOffset = NSSize(width: 0, height: -24)
shadow.set()
NSGradient(
    starting: NSColor(calibratedWhite: 0.97, alpha: 1),
    ending: NSColor(calibratedWhite: 0.78, alpha: 1)
)?.draw(in: tile, angle: -45)
NSGraphicsContext.current?.restoreGraphicsState()

let highlight = NSBezierPath(roundedRect: tileRect.insetBy(dx: 20, dy: 20), xRadius: 192, yRadius: 192)
NSColor.white.withAlphaComponent(0.68).setStroke()
highlight.lineWidth = 8
highlight.stroke()

let jersey = NSBezierPath()
jersey.move(to: NSPoint(x: 371, y: 758))
jersey.line(to: NSPoint(x: 653, y: 758))
jersey.line(to: NSPoint(x: 756, y: 706))
jersey.line(to: NSPoint(x: 932, y: 595))
jersey.line(to: NSPoint(x: 854, y: 371))
jersey.line(to: NSPoint(x: 702, y: 442))
jersey.line(to: NSPoint(x: 702, y: 253))
jersey.line(to: NSPoint(x: 322, y: 253))
jersey.line(to: NSPoint(x: 322, y: 442))
jersey.line(to: NSPoint(x: 170, y: 371))
jersey.line(to: NSPoint(x: 92, y: 595))
jersey.line(to: NSPoint(x: 268, y: 706))
jersey.close()
jersey.lineWidth = 34
jersey.lineJoinStyle = .round
jersey.lineCapStyle = .round
NSColor(calibratedWhite: 0.09, alpha: 1).setStroke()
jersey.stroke()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 210, weight: .bold),
    .foregroundColor: NSColor(calibratedWhite: 0.09, alpha: 1),
    .paragraphStyle: paragraph,
    .kern: -18
]
("10" as NSString).draw(in: NSRect(x: 342, y: 358, width: 340, height: 230), withAttributes: attributes)

context.flushGraphics()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Unable to render icon\n", stderr)
    exit(1)
}

let destination = CommandLine.arguments.dropFirst().first ?? "/private/tmp/edison-AppIcon.png"
try png.write(to: URL(fileURLWithPath: destination), options: .atomic)
