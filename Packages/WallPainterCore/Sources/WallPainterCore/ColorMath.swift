import Foundation

/// sRGB <-> linear conversion through lookup tables (hot loops call these per pixel).
public enum ColorMath {
    public static let toLinear: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    static let encodeSteps = 4096
    static let toSRGB: [UInt8] = (0..<encodeSteps).map { i in
        let c = Float(i) / Float(encodeSteps - 1)
        let s = c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
        return UInt8(min(255, max(0, s * 255 + 0.5)))
    }

    @inline(__always)
    public static func encode(_ linear: Float) -> UInt8 {
        let clamped = min(max(linear, 0), 1)
        return toSRGB[Int(clamped * Float(encodeSteps - 1) + 0.5)]
    }

    /// Relative luminance (Rec. 709) of linear RGB.
    @inline(__always)
    public static func luminance(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
