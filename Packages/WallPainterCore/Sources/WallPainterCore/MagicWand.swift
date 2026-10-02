import Foundation

/// Tap-to-select: grows a region from a seed pixel over a surface of the same paint color.
///
/// Walls are lit unevenly, so the region is grown on chromaticity (hue/saturation, which shading
/// barely changes) against the seed, plus a local step limit so it stops at real edges.
/// It never spreads into areas the model marks as floor or ceiling (the `barrier` map), which
/// otherwise share the wall's color in most rooms.
/// Runs on a downscaled copy (which also removes noise) and refines the result back to full size.
public final class MagicWand: @unchecked Sendable {  // immutable after init
    public let image: RGBAImage
    private let small: RGBAImage
    private let factor: Int
    private let guide: [Float]
    private let blocked: [Bool]

    /// - Parameter barrier: optional low-res floor/ceiling probability (e.g. the model's 160x160 output).
    public init(image: RGBAImage, barrier: [Float]? = nil, barrierWidth: Int = 0, barrierHeight: Int = 0,
                workingSize: Int = 1024) {
        self.image = image
        factor = max(1, Int((Float(max(image.width, image.height)) / Float(workingSize)).rounded(.up)))
        small = image.downscaled(by: factor)
        guide = MaskRefiner.grayscale(image)
        if let barrier, barrierWidth > 0, barrierHeight > 0 {
            blocked = MaskRefiner.resizeBilinear(barrier, width: barrierWidth, height: barrierHeight,
                                                 toWidth: small.width, toHeight: small.height).map { $0 > 0.5 }
        } else {
            blocked = [Bool](repeating: false, count: small.pixelCount)
        }
    }

    /// - Parameters:
    ///   - x, y: seed in full-resolution pixel coordinates.
    ///   - tolerance: 1 is the default; larger grabs more.
    /// - Returns: a full-resolution matte of the selected region (empty if the seed is invalid).
    public func select(x: Int, y: Int, tolerance: Float = 1) -> Matte {
        guard x >= 0, y >= 0, x < image.width, y < image.height else {
            return Matte(width: image.width, height: image.height)
        }
        let w = small.width, h = small.height
        let sx = min(w - 1, x / factor), sy = min(h - 1, y / factor)

        let px = small.pixels
        @inline(__always) func chroma(_ i: Int) -> (Float, Float, Float) {
            let r = Float(px[i * 4]), g = Float(px[i * 4 + 1]), b = Float(px[i * 4 + 2])
            let sum = max(r + g + b, 1)
            return (r / sum, g / sum, sum)
        }

        let seedIndex = sy * w + sx
        let seed = chroma(seedIndex)
        let chromaLimit = 0.018 * tolerance
        let stepLimit = Int(8 * tolerance)
        let minBrightness = seed.2 * 0.35, maxBrightness = seed.2 * 2 + 30

        var selected = [Bool](repeating: false, count: w * h)
        var queue = [seedIndex]
        selected[seedIndex] = true
        var head = 0
        func visit(_ i: Int, _ j: Int) {
            if selected[j] || blocked[j] { return }
            let step = max(abs(Int(px[i * 4]) - Int(px[j * 4])),
                           abs(Int(px[i * 4 + 1]) - Int(px[j * 4 + 1])),
                           abs(Int(px[i * 4 + 2]) - Int(px[j * 4 + 2])))
            if step > stepLimit { return }
            let c = chroma(j)
            if c.2 < minBrightness || c.2 > maxBrightness { return }
            if abs(c.0 - seed.0) > chromaLimit || abs(c.1 - seed.1) > chromaLimit { return }
            selected[j] = true
            queue.append(j)
        }
        while head < queue.count {
            let i = queue[head]
            head += 1
            let x0 = i % w, y0 = i / w
            if x0 > 0 { visit(i, i - 1) }
            if x0 < w - 1 { visit(i, i + 1) }
            if y0 > 0 { visit(i, i - w) }
            if y0 < h - 1 { visit(i, i + w) }
        }

        let soft = selected.map { $0 ? Float(1) : 0 }
        // Close pinholes left by texture before scaling up.
        let closed = GuidedFilter.boxMean(soft, width: w, height: h, radius: 1).map { $0 > 0.4 ? Float(1) : 0 }
        let full = MaskRefiner.resizeBilinear(closed, width: w, height: h,
                                              toWidth: image.width, toHeight: image.height)
        let radius = max(2, max(image.width, image.height) / 300)
        let refined = GuidedFilter.apply(guide: guide, input: full, width: image.width, height: image.height,
                                         radius: radius, epsilon: 1e-3)
        return MaskRefiner.matte(from: refined, width: image.width, height: image.height,
                                 threshold: 0.35, softness: 0.3)
    }
}
