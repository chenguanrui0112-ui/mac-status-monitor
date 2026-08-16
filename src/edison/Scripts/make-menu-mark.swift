import AppKit
import CoreGraphics
import ImageIO
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: make-menu-mark input.png output.png\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL
guard let source = CGImageSourceCreateWithURL(inputURL, nil),
      let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("unable to read image\n", stderr)
    exit(1)
}

let width = sourceImage.width
let height = sourceImage.height
let bytesPerRow = width * 4
var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
guard let context = CGContext(data: &pixels, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fputs("unable to create bitmap\n", stderr)
    exit(1)
}
context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))

for index in stride(from: 0, to: pixels.count, by: 4) {
    let brightness = max(pixels[index], pixels[index + 1], pixels[index + 2])
    if brightness < 60 {
        pixels[index + 3] = 0
    } else {
        pixels[index] = 0
        pixels[index + 1] = 0
        pixels[index + 2] = 0
    }
}

guard let outputImage = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL, "public.png" as CFString, 1, nil) else {
    fputs("unable to encode image\n", stderr)
    exit(1)
}
CGImageDestinationAddImage(destination, outputImage, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("unable to write image\n", stderr)
    exit(1)
}
