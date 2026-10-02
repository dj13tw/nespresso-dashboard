import Foundation

/// Edge-preserving smoothing (He et al., "Guided Image Filtering") with a grayscale guide.
/// Used to snap the coarse AI mask onto the real edges of furniture, frames and corners.
public enum GuidedFilter {
    public static func apply(guide: [Float], input: [Float], width: Int, height: Int,
                             radius: Int, epsilon: Float) -> [Float] {
        let n = width * height
        precondition(guide.count == n && input.count == n)
        let meanI = boxMean(guide, width: width, height: height, radius: radius)
        let meanP = boxMean(input, width: width, height: height, radius: radius)
        var ip = [Float](repeating: 0, count: n)
        var ii = [Float](repeating: 0, count: n)
        for i in 0..<n {
            ip[i] = guide[i] * input[i]
            ii[i] = guide[i] * guide[i]
        }
        let corrIP = boxMean(ip, width: width, height: height, radius: radius)
        let corrII = boxMean(ii, width: width, height: height, radius: radius)

        var a = ip, b = ii  // reuse buffers
        for i in 0..<n {
            let variance = corrII[i] - meanI[i] * meanI[i]
            let covariance = corrIP[i] - meanI[i] * meanP[i]
            a[i] = covariance / (variance + epsilon)
            b[i] = meanP[i] - a[i] * meanI[i]
        }
        let meanA = boxMean(a, width: width, height: height, radius: radius)
        let meanB = boxMean(b, width: width, height: height, radius: radius)
        var out = meanA
        for i in 0..<n {
            out[i] = meanA[i] * guide[i] + meanB[i]
        }
        return out
    }

    /// Mean over a (2r+1)x(2r+1) window, shrinking at the borders.
    /// Separable running sums in Double: exact enough and O(1) per pixel regardless of radius.
    public static func boxMean(_ src: [Float], width w: Int, height h: Int, radius r: Int) -> [Float] {
        precondition(src.count == w * h)
        if r <= 0 { return src }
        var horizontal = [Float](repeating: 0, count: w * h)
        var out = [Float](repeating: 0, count: w * h)

        src.withUnsafeBufferPointer { s in
            horizontal.withUnsafeMutableBufferPointer { t in
                parallelRows(h) { y in
                    let row = y * w
                    var sum = 0.0
                    for x in 0...min(r, w - 1) { sum += Double(s[row + x]) }
                    for x in 0..<w {
                        let lo = x - r, hi = x + r
                        let count = min(hi, w - 1) - max(lo, 0) + 1
                        t[row + x] = Float(sum / Double(count))
                        if hi + 1 < w { sum += Double(s[row + hi + 1]) }
                        if lo >= 0 { sum -= Double(s[row + lo]) }
                    }
                }
            }
        }

        // Vertical pass walks rows in order (cache friendly) with one running sum per column,
        // split into column bands for parallelism.
        horizontal.withUnsafeBufferPointer { t in
            out.withUnsafeMutableBufferPointer { o in
                let bands = min(w, max(1, ProcessInfo.processInfo.activeProcessorCount * 2))
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    let x0 = w * band / bands, x1 = w * (band + 1) / bands
                    var sums = [Double](repeating: 0, count: x1 - x0)
                    for y in 0...min(r, h - 1) {
                        for x in x0..<x1 { sums[x - x0] += Double(t[y * w + x]) }
                    }
                    for y in 0..<h {
                        let lo = y - r, hi = y + r
                        let count = Double(min(hi, h - 1) - max(lo, 0) + 1)
                        for x in x0..<x1 {
                            o[y * w + x] = Float(sums[x - x0] / count)
                        }
                        if hi + 1 < h {
                            for x in x0..<x1 { sums[x - x0] += Double(t[(hi + 1) * w + x]) }
                        }
                        if lo >= 0 {
                            for x in x0..<x1 { sums[x - x0] -= Double(t[lo * w + x]) }
                        }
                    }
                }
            }
        }
        return out
    }
}
