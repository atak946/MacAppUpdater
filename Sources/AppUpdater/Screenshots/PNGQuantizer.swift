import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shrinks opaque screenshots to 8-bit palette PNGs (median-cut palette, Floyd–Steinberg dithering),
/// the same idea as pngquant, which is not available everywhere.
enum PNGQuantizer {
    static let maxColors = 256
    /// Bits kept per channel for the histogram and the nearest-colour cache.
    private static let histogramBits = 5
    private static let histogramShift = 8 - histogramBits
    private static let bucketCount = 1 << (histogramBits * 3)
    /// Share of the quantization error passed on, in percent; below 100 trades a little banding for size.
    static let ditherStrength = 40

    struct Pixels {
        let width: Int
        let height: Int
        /// RGBA, 8 bits per channel, opaque.
        let bytes: [UInt8]
    }

    /// A palette PNG of `image`, or `nil` when it cannot be encoded.
    static func pngData(from image: CGImage) -> Data? {
        guard let pixels = pixels(of: image) else { return nil }
        let palette = medianCutPalette(for: pixels)
        let indices = dither(pixels, palette: palette)
        return encode(indices: indices, palette: palette, width: pixels.width, height: pixels.height)
    }

    static func pixels(of image: CGImage) -> Pixels? {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Pixels(width: width, height: height, bytes: bytes) : nil
    }

    // MARK: Palette

    private struct Bucket {
        let key: Int
        let count: Int
        let red: Int
        let green: Int
        let blue: Int

        func channel(_ index: Int) -> Int {
            switch index {
            case 0: red
            case 1: green
            default: blue
            }
        }
    }

    static func medianCutPalette(for pixels: Pixels) -> [SIMD3<Int>] {
        var counts = [Int](repeating: 0, count: bucketCount)
        var sums = [SIMD3<Int>](repeating: .zero, count: bucketCount)
        var offset = 0
        while offset < pixels.bytes.count {
            let color = SIMD3(Int(pixels.bytes[offset]), Int(pixels.bytes[offset + 1]), Int(pixels.bytes[offset + 2]))
            let key = bucketKey(color)
            counts[key] += 1
            sums[key] &+= color
            offset += 4
        }
        let buckets = counts.indices.filter { counts[$0] > 0 }.map { key in
            Bucket(key: key, count: counts[key], red: key >> 10, green: (key >> 5) & 31, blue: key & 31)
        }
        var boxes = [buckets]
        while boxes.count < maxColors, let index = widestBoxIndex(boxes) {
            let (low, high) = split(boxes[index])
            boxes.replaceSubrange(index...index, with: [low, high])
        }
        return boxes.map { box in
            let total = box.reduce(0) { $0 + $1.count }
            let sum = box.reduce(SIMD3<Int>.zero) { $0 &+ sums[$1.key] }
            return sum / max(total, 1)
        }
    }

    private static func range(of box: [Bucket], channel: Int) -> Int {
        let values = box.map { $0.channel(channel) }
        return (values.max() ?? 0) - (values.min() ?? 0)
    }

    private static func widestBoxIndex(_ boxes: [[Bucket]]) -> Int? {
        let candidates = boxes.indices.filter { boxes[$0].count > 1 }
        return candidates.max { lhs, rhs in
            score(boxes[lhs]) < score(boxes[rhs])
        }
    }

    /// Prefers boxes that are both wide and well populated.
    private static func score(_ box: [Bucket]) -> Int {
        let widest = (0..<3).map { range(of: box, channel: $0) }.max() ?? 0
        let population = box.reduce(0) { $0 + $1.count }
        return widest * Int(Double(population).squareRoot())
    }

    private static func split(_ box: [Bucket]) -> ([Bucket], [Bucket]) {
        let channel = (0..<3).max { range(of: box, channel: $0) < range(of: box, channel: $1) } ?? 0
        let sorted = box.sorted { $0.channel(channel) < $1.channel(channel) }
        let half = sorted.reduce(0) { $0 + $1.count } / 2
        var running = 0
        var cut = 1
        for (index, bucket) in sorted.enumerated() {
            running += bucket.count
            if running >= half {
                cut = min(max(index + 1, 1), sorted.count - 1)
                break
            }
        }
        return (Array(sorted[..<cut]), Array(sorted[cut...]))
    }

    // MARK: Mapping

    private static func bucketKey(_ color: SIMD3<Int>) -> Int {
        (color.x >> histogramShift) << 10 | (color.y >> histogramShift) << 5 | (color.z >> histogramShift)
    }

    private static func nearest(_ color: SIMD3<Int>, in palette: [SIMD3<Int>]) -> Int {
        var best = 0
        var bestDistance = Int.max
        for (index, entry) in palette.enumerated() {
            let delta = entry &- color
            let distance = delta.x * delta.x * 3 + delta.y * delta.y * 4 + delta.z * delta.z * 2
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// Floyd–Steinberg error diffusion, with nearest colours cached per histogram bucket.
    static func dither(_ pixels: Pixels, palette: [SIMD3<Int>]) -> [UInt8] {
        let width = pixels.width
        var cache = [Int](repeating: -1, count: bucketCount)
        var indices = [UInt8](repeating: 0, count: width * pixels.height)
        var current = [SIMD3<Int>](repeating: .zero, count: width + 2)
        var next = [SIMD3<Int>](repeating: .zero, count: width + 2)
        for row in 0..<pixels.height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                let source = SIMD3(Int(pixels.bytes[offset]), Int(pixels.bytes[offset + 1]), Int(pixels.bytes[offset + 2]))
                let wanted = clamp(source &+ current[column + 1] / 16)
                let key = bucketKey(wanted)
                if cache[key] < 0 { cache[key] = nearest(wanted, in: palette) }
                let index = cache[key]
                indices[row * width + column] = UInt8(index)
                let error = (wanted &- palette[index]) &* ditherStrength / 100
                current[column + 2] &+= error &* 7
                next[column] &+= error &* 3
                next[column + 1] &+= error &* 5
                next[column + 2] &+= error
            }
            swap(&current, &next)
            next = [SIMD3<Int>](repeating: .zero, count: width + 2)
        }
        return indices
    }

    private static func clamp(_ color: SIMD3<Int>) -> SIMD3<Int> {
        color.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 255))
    }

    // MARK: Encoding

    private static func encode(indices: [UInt8], palette: [SIMD3<Int>], width: Int, height: Int) -> Data? {
        let table = palette.flatMap { [UInt8($0.x), UInt8($0.y), UInt8($0.z)] }
        guard let base = CGColorSpace(name: CGColorSpace.sRGB),
              let space = CGColorSpace(indexedBaseSpace: base, last: palette.count - 1, colorTable: table),
              let provider = CGDataProvider(data: Data(indices) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
