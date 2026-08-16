import Foundation

func bigEndianBytes(_ value: UInt32) -> Data {
    var bigEndian = value.bigEndian
    return Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    fputs("Usage: make-icns OUTPUT.icns TYPE=IMAGE.png ...\n", stderr)
    exit(2)
}

let output = arguments[0]
var entries = Data()

for argument in arguments.dropFirst() {
    let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2,
          parts[0].utf8.count == 4,
          let type = parts[0].data(using: .ascii) else {
        fputs("Invalid ICNS entry: \(argument)\n", stderr)
        exit(2)
    }

    let imageURL = URL(fileURLWithPath: parts[1])
    let image: Data
    do {
        image = try Data(contentsOf: imageURL)
    } catch {
        fputs("Unable to read \(parts[1])\n", stderr)
        exit(1)
    }

    let entryLength = 8 + image.count
    guard entryLength <= Int(UInt32.max) else {
        fputs("ICNS entry is too large\n", stderr)
        exit(1)
    }
    entries.append(type)
    entries.append(bigEndianBytes(UInt32(entryLength)))
    entries.append(image)
}

let totalLength = 8 + entries.count
guard totalLength <= Int(UInt32.max) else {
    fputs("ICNS file is too large\n", stderr)
    exit(1)
}

var outputData = Data("icns".utf8)
outputData.append(bigEndianBytes(UInt32(totalLength)))
outputData.append(entries)

do {
    try outputData.write(to: URL(fileURLWithPath: output), options: .atomic)
} catch {
    fputs("Unable to write ICNS file\n", stderr)
    exit(1)
}

