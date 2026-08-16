import AppKit

guard CommandLine.arguments.count > 1 else { exit(2) }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 700, height: 360)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 700, pixelsHigh: 360,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedWhite: 0.94, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()

let header = NSImage(contentsOfFile: "Sources/EdisonApp/Resources/edison-mark-black.png")!
header.draw(in: NSRect(x: 36, y: 278, width: 42, height: 42), from: .zero, operation: .sourceOver, fraction: 1)
("edison" as NSString).draw(at: NSPoint(x: 92, y: 292), withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.black])
("已运行 2 小时 9 分钟" as NSString).draw(at: NSPoint(x: 92, y: 270), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor])

let card = NSBezierPath(roundedRect: NSRect(x: 22, y: 22, width: 656, height: 220), xRadius: 24, yRadius: 24)
NSColor.white.withAlphaComponent(0.72).setFill(); card.fill()
let airpods = NSImage(systemSymbolName: "airpodspro", accessibilityDescription: nil)!
airpods.draw(in: NSRect(x: 46, y: 190, width: 28, height: 28), from: .zero, operation: .sourceOver, fraction: 1)
("AirPods" as NSString).draw(at: NSPoint(x: 88, y: 194), withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor.black])
("已连接" as NSString).draw(at: NSPoint(x: 574, y: 197), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.secondaryLabelColor])
("AirPods Pro" as NSString).draw(at: NSPoint(x: 46, y: 158), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.secondaryLabelColor])

let entries: [(String, String, Int, CGFloat)] = [("L", "100%", 100, 46), ("R", "98%", 98, 246), ("case", "100%", 100, 446)]
for (name, value, percent, x) in entries {
    NSColor.black.setFill()
    if name == "L" || name == "R" {
        NSBezierPath(ovalIn: NSRect(x: x, y: 112, width: 25, height: 25)).fill()
        (name as NSString).draw(at: NSPoint(x: x + 7, y: 116), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.white])
    } else {
        NSBezierPath(roundedRect: NSRect(x: x, y: 114, width: 25, height: 20), xRadius: 5, yRadius: 5).fill()
        NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: x + 5, y: 122, width: 15, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }
    (value as NSString).draw(at: NSPoint(x: x + 110, y: 117), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .medium), .foregroundColor: NSColor.black])
    NSColor.systemGreen.withAlphaComponent(0.2).setFill(); NSRect(x: x, y: 86, width: 165, height: 12).fill()
    NSColor.systemGreen.setFill(); NSRect(x: x, y: 86, width: 165 * CGFloat(percent) / 100, height: 12).fill()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
