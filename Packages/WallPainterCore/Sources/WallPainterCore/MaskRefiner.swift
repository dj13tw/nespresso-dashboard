import Foundation

/// Turns a low-resolution probability map into a full-resolution matte that follows image edges.
public enum MaskRefiner {
    public struct Parameters: Sendable {
        /// Guided filter radius as a fraction of the image's longer side.
        public var radiusFraction: Float = 1.0 / 80
        public var epsilon: Float = 1e-3
        /// Probability where the matte starts to fade in, and the width of the fade.
        public var threshold: Float = 0.35
        public var softness: Float = 0.3

        public init() {}
    }

    public static func refine(probability: [Float], probabilityWidth pw: Int, probabilityHeight ph: Int,
                              image: RGBAImage, parameters: Parameters = Parameters()) -> Matte {
        let w = image.width, h = image.height
        let upsampled = resizeBilinear(probability, width: pw, height: ph, toWidth: w, toHeight: h)
        let guide = grayscale(image)
        let radius = max(2, Int((Float(max(w, h)) * parameters.radiusFraction).rounded()))
        let filtered = GuidedFilter.apply(guide: guide, input: upsampled, width: w, height: h,
                                          radius: radius, epsilon: parameters.epsilon)
        return matte(from: filtered, width: w, height: h,
                     threshold: parameters.threshold, softness: parameters.softness)
    }

    /// Smoothstep a soft map into a matte with a thin feathered edge.
    public static func matte(from values: [Float], width: Int, height: Int,
                             threshold: Float, softness: Float) -> Matte {
        var out = [UInt8](repeating: 0, count: values.count)
        for i in values.indices {
            var t = (values[i] - threshold) / softness
            t = min(max(t, 0), 1)
            out[i] = UInt8(t * t * (3 - 2 * t) * 255 + 0.5)
        }
        return Matte(width: width, height: height, values: out)
    }

    /// Gamma-encoded gray in 0...1, which tracks perceived edges better than linear luminance.
    public static func grayscale(_ image: RGBAImage) -> [Float] {
        var out = [Float](repeating: 0, count: image.pixelCount)
        image.pixels.withUnsafeBufferPointer { p in
            for i in 0..<image.pixelCount {
                out[i] = (Float(p[i * 4]) + Float(p[i * 4 + 1]) + Float(p[i * 4 + 2])) / 765
            }
        }
        return out
    }

    /// Bilinear resize with half-pixel centers (matches PyTorch align_corners=False).
    public static func resizeBilinear(_ src: [Float], width sw: Int, height sh: Int,
                                      toWidth dw: Int, toHeight dh: Int) -> [Float] {
        precondition(src.count == sw * sh)
        var out = [Float](repeating: 0, count: dw * dh)
        let sx = Float(sw) / Float(dw), sy = Float(sh) / Float(dh)
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                parallelRows(dh) { y in
                    let fy = max(0, (Float(y) + 0.5) * sy - 0.5)
                    let y0 = min(Int(fy), sh - 1), y1 = min(y0 + 1, sh - 1)
                    let ty = fy - Float(y0)
                    for x in 0..<dw {
                        let fx = max(0, (Float(x) + 0.5) * sx - 0.5)
                        let x0 = min(Int(fx), sw - 1), x1 = min(x0 + 1, sw - 1)
                        let tx = fx - Float(x0)
                        let top = s[y0 * sw + x0] * (1 - tx) + s[y0 * sw + x1] * tx
                        let bottom = s[y1 * sw + x0] * (1 - tx) + s[y1 * sw + x1] * tx
                        o[y * dw + x] = top * (1 - ty) + bottom * ty
                    }
                }
            }
        }
        return out
    }
}
