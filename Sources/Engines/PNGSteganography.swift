import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PNGSteganography {
    private static let magic = Data("ZCST01".utf8)
    private static let maxPixels = 40_000_000

    static func containsZeroClickMessage(_ source: URL) throws -> Bool {
        let pixels = try decoded(source).pixels
        let prefixBits = (magic.count + 4) * 8
        var bytes = Data()
        var next: UInt8 = 0
        var bit = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] == 255 {
            for channel in 0..<3 {
                next = (next << 1) | (pixels[offset + channel] & 1)
                bit += 1
                if bit % 8 == 0 { bytes.append(next); next = 0 }
                if bit == prefixBits {
                    guard bytes.starts(with: magic) else { return false }
                    let start = magic.count
                    let length = UInt32(bytes[start]) | (UInt32(bytes[start + 1]) << 8)
                        | (UInt32(bytes[start + 2]) << 16) | (UInt32(bytes[start + 3]) << 24)
                    return length >= 44 && length <= 64 * 1024 + 44
                        && Int(length) * 8 + prefixBits <= pixels.strideCapacity
                }
            }
        }
        return false
    }

    static func hide(_ message: String, password: String, in source: URL, to destination: URL) throws -> URL {
        let payload = try SecureFile.sealMessage(message, password: password)
        var header = magic
        let length = UInt32(payload.count)
        for shift in stride(from: 0, to: 32, by: 8) { header.append(UInt8((length >> shift) & 0xff)) }
        header.append(payload)
        let image = try decoded(source)
        var pixels = image.pixels
        let capacity = pixels.strideCapacity
        guard header.count * 8 <= capacity else {
            throw SatsumaError.invalidInput("Image is too small to hold this message.")
        }
        var bit = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] == 255 {
            for channel in 0..<3 {
                if bit == header.count * 8 { break }
                let value = (header[bit / 8] >> (7 - bit % 8)) & 1
                pixels[offset + channel] = (pixels[offset + channel] & 0xfe) | value
                bit += 1
            }
            if bit == header.count * 8 { break }
        }
        return try OutputWriter.write(to: destination) { staged in
            try encode(pixels, width: image.width, height: image.height, to: staged)
        }
    }

    static func reveal(from source: URL, password: String) throws -> String {
        let image = try decoded(source)
        let pixels = image.pixels
        let headerSize = (magic.count + 4) * 8
        var bytes = Data()
        var next: UInt8 = 0
        var bit = 0
        var targetBits = headerSize
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] == 255 {
            for channel in 0..<3 {
                next = (next << 1) | (pixels[offset + channel] & 1)
                bit += 1
                if bit % 8 == 0 { bytes.append(next); next = 0 }
                if bit == headerSize {
                    guard bytes.starts(with: magic) else { throw SatsumaError.invalidInput("No ZeroClick message is hidden in this PNG.") }
                    let offset = magic.count
                    let length = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                        | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
                    guard length >= 44, length <= 64 * 1024 + 44 else {
                        throw SatsumaError.invalidInput("Hidden message is damaged.")
                    }
                    targetBits = headerSize + Int(length) * 8
                }
                if bit == targetBits {
                    return try SecureFile.openMessage(bytes.dropFirst(magic.count + 4), password: password)
                }
            }
        }
        throw SatsumaError.invalidInput("Hidden message is incomplete.")
    }

    private static func decoded(_ url: URL) throws -> (pixels: [UInt8], width: Int, height: Int) {
        guard FileFormat.detect(url) == .png,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SatsumaError.invalidInput("Choose a readable PNG image.")
        }
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= maxPixels / height else {
            throw SatsumaError.invalidInput("PNG exceeds the 40-megapixel limit.")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let created = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else { throw SatsumaError.invalidInput("Could not decode PNG pixels.") }
        return (pixels, width, height)
    }

    private static func encode(_ pixels: [UInt8], width: Int, height: Int, to destination: URL) throws {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SatsumaError.invalidInput("Could not encode PNG.")
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw SatsumaError.invalidInput("Could not save PNG.") }
    }
}

private extension Collection where Element == UInt8 {
    var strideCapacity: Int {
        var count = 0
        for offset in Swift.stride(from: 0, to: self.count, by: 4) where self[index(startIndex, offsetBy: offset + 3)] == 255 {
            count += 3
        }
        return count
    }
}
