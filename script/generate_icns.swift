import Foundation
import ImageIO

enum ICNSGenerationError: LocalizedError {
    case invalidArguments
    case unreadableImage(String)
    case cannotCreateDestination(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "usage: generate_icns.swift <iconset-directory> <output.icns>"
        case .unreadableImage(let path):
            return "cannot read icon image: \(path)"
        case .cannotCreateDestination(let path):
            return "cannot create ICNS destination: \(path)"
        }
    }
}

private struct IconRepresentation {
    let type: String
    let fileName: String
    let pixelSize: Int
}

private let representations = [
    IconRepresentation(type: "icp4", fileName: "icon_16x16.png", pixelSize: 16),
    IconRepresentation(type: "ic11", fileName: "icon_16x16@2x.png", pixelSize: 32),
    IconRepresentation(type: "icp5", fileName: "icon_32x32.png", pixelSize: 32),
    IconRepresentation(type: "ic12", fileName: "icon_32x32@2x.png", pixelSize: 64),
    IconRepresentation(type: "ic07", fileName: "icon_128x128.png", pixelSize: 128),
    IconRepresentation(type: "ic13", fileName: "icon_128x128@2x.png", pixelSize: 256),
    IconRepresentation(type: "ic08", fileName: "icon_256x256.png", pixelSize: 256),
    IconRepresentation(type: "ic14", fileName: "icon_256x256@2x.png", pixelSize: 512),
    IconRepresentation(type: "ic09", fileName: "icon_512x512.png", pixelSize: 512),
    IconRepresentation(type: "ic10", fileName: "icon_512x512@2x.png", pixelSize: 1024)
]

func generateICNS(iconsetDirectory: URL, outputURL: URL) throws {
    var output = Data("icns".utf8)
    output.appendBigEndian(0)

    for representation in representations {
        let imageURL = iconsetDirectory.appending(path: representation.fileName)
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ICNSGenerationError.unreadableImage(imageURL.path)
        }
        guard image.width == representation.pixelSize,
              image.height == representation.pixelSize
        else {
            throw ICNSGenerationError.unreadableImage(imageURL.path)
        }

        let pngData = try Data(contentsOf: imageURL)
        output.append(Data(representation.type.utf8))
        output.appendBigEndian(UInt32(pngData.count + 8))
        output.append(pngData)
    }

    output.replaceBigEndian(UInt32(output.count), at: 4)
    do {
        try output.write(to: outputURL, options: .atomic)
    } catch {
        throw ICNSGenerationError.cannotCreateDestination(outputURL.path)
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func replaceBigEndian(_ value: UInt32, at offset: Int) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { bytes in
            replaceSubrange(offset..<(offset + MemoryLayout<UInt32>.size), with: bytes)
        }
    }
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw ICNSGenerationError.invalidArguments
    }

    let iconsetDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
    try generateICNS(iconsetDirectory: iconsetDirectory, outputURL: outputURL)
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
