import Foundation

/// Repaints the matted area with a new color while keeping the photo's light and shadow.
///
/// Each wall pixel becomes `target * (pixel luminance / average wall luminance)` in linear RGB,
/// so the average wall shows the chosen color and shading, gradients and texture carry over.
public final class Recolorer: @unchecked Sendable {  // immutable after init
    public let image: RGBAImage
    private let luminance: [Float]

    public init(image: RGBAImage) {
        self.image = image
        var lum = [Float](repeating: 0, count: image.pixelCount)
        let lut = ColorMath.toLinear
        image.pixels.withUnsafeBufferPointer { p in
            lum.withUnsafeMutableBufferPointer { l in
                parallelRows(image.height) { y in
                    for x in 0..<image.width {
                        let i = y * image.width + x
                        l[i] = ColorMath.luminance(lut[Int(p[i * 4])], lut[Int(p[i * 4 + 1])], lut[Int(p[i * 4 + 2])])
                    }
                }
            }
        }
        luminance = lum
    }

    /// Matte-weighted mean luminance of the wall, or nil when nothing is selected.
    public func wallLuminance(_ matte: Matte) -> Float? {
        precondition(matte.width == image.width && matte.height == image.height)
        var weighted = 0.0, total = 0.0
        for i in 0..<luminance.count where matte.values[i] > 0 {
            let a = Double(matte.values[i])
            weighted += Double(luminance[i]) * a
            total += a
        }
        return total > 0 ? Float(weighted / total) : nil
    }

    /// - Parameters:
    ///   - highlight: tint the painted area so it stays visible while editing the mask,
    ///     even when the new color is close to the old one.
    ///   - referenceLuminance: pass a cached `wallLuminance(matte)` to skip recomputing it.
    public func render(matte: Matte, color: RGB, highlight: Bool = false,
                       referenceLuminance: Float? = nil) -> RGBAImage {
        precondition(matte.width == image.width && matte.height == image.height)
        let reference = referenceLuminance ?? wallLuminance(matte) ?? 0.5
        let lut = ColorMath.toLinear
        let scale = 1 / max(reference, 1e-4)
        let tr = lut[Int(color.r)] * scale, tg = lut[Int(color.g)] * scale, tb = lut[Int(color.b)] * scale
        let width = image.width

        var out = image.pixels
        out.withUnsafeMutableBufferPointer { o in
            matte.values.withUnsafeBufferPointer { m in
                luminance.withUnsafeBufferPointer { l in
                    parallelRows(image.height) { y in
                        for x in 0..<width {
                            let i = y * width + x
                            let a = Int(m[i])
                            if a == 0 { continue }
                            let s = l[i]
                            var r = Int(ColorMath.encode(tr * s))
                            var g = Int(ColorMath.encode(tg * s))
                            var b = Int(ColorMath.encode(tb * s))
                            if highlight {
                                // 35% magenta, a color nobody paints a wall, so coverage is obvious.
                                r = (r * 65 + 255 * 35) / 100
                                g = (g * 65) / 100
                                b = (b * 65 + 200 * 35) / 100
                            }
                            let p = i * 4
                            if a == 255 {
                                o[p] = UInt8(r); o[p + 1] = UInt8(g); o[p + 2] = UInt8(b)
                            } else {
                                let ia = 255 - a
                                o[p] = UInt8((Int(o[p]) * ia + r * a + 127) / 255)
                                o[p + 1] = UInt8((Int(o[p + 1]) * ia + g * a + 127) / 255)
                                o[p + 2] = UInt8((Int(o[p + 2]) * ia + b * a + 127) / 255)
                            }
                        }
                    }
                }
            }
        }
        return RGBAImage(width: width, height: image.height, pixels: out)
    }
}
