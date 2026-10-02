import Foundation

/// 8-bit RGBA pixels, row-major, alpha ignored (photos are opaque).
public struct RGBAImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: RGB) {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = fill.r
            pixels[i * 4 + 1] = fill.g
            pixels[i * 4 + 2] = fill.b
        }
        self.init(width: width, height: height, pixels: pixels)
    }

    public var pixelCount: Int { width * height }

    public func color(x: Int, y: Int) -> RGB {
        let i = (y * width + x) * 4
        return RGB(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2])
    }

    /// Box-averaged downscale by an integer factor (also removes sensor noise).
    public func downscaled(by factor: Int) -> RGBAImage {
        guard factor > 1 else { return self }
        let w = max(1, width / factor), h = max(1, height / factor)
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let area = factor * factor
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                parallelRows(h) { y in
                    for x in 0..<w {
                        var r = 0, g = 0, b = 0
                        for dy in 0..<factor {
                            var i = ((y * factor + dy) * width + x * factor) * 4
                            for _ in 0..<factor {
                                r += Int(src[i]); g += Int(src[i + 1]); b += Int(src[i + 2])
                                i += 4
                            }
                        }
                        let o = (y * w + x) * 4
                        dst[o] = UInt8(r / area)
                        dst[o + 1] = UInt8(g / area)
                        dst[o + 2] = UInt8(b / area)
                    }
                }
            }
        }
        return RGBAImage(width: w, height: h, pixels: out)
    }
}

/// Per-pixel coverage of the paint, 0 = untouched, 255 = fully painted.
public struct Matte: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var values: [UInt8]

    public init(width: Int, height: Int, values: [UInt8]) {
        precondition(values.count == width * height)
        self.width = width
        self.height = height
        self.values = values
    }

    public init(width: Int, height: Int, value: UInt8 = 0) {
        self.init(width: width, height: height, values: [UInt8](repeating: value, count: width * height))
    }

    /// Fraction of the image that is painted, 0...1.
    public var coverage: Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.reduce(0) { $0 + Int($1) }) / Double(values.count * 255)
    }

    /// Union with another matte of the same size.
    public mutating func formUnion(_ other: Matte) {
        precondition(other.width == width && other.height == height)
        for i in values.indices where other.values[i] > values[i] {
            values[i] = other.values[i]
        }
    }
}

public struct RGB: Hashable, Codable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Accepts "#RRGGBB" or "RRGGBB".
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: UInt8(v >> 16 & 0xFF), g: UInt8(v >> 8 & 0xFF), b: UInt8(v & 0xFF))
    }

    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
}

/// Runs `body` for every row, spread over all cores in contiguous bands.
func parallelRows(_ rows: Int, _ body: (Int) -> Void) {
    let bands = min(rows, max(1, ProcessInfo.processInfo.activeProcessorCount * 4))
    DispatchQueue.concurrentPerform(iterations: bands) { band in
        let start = rows * band / bands
        let end = rows * (band + 1) / bands
        for y in start..<end { body(y) }
    }
}
