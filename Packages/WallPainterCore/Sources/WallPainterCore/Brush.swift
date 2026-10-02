import Foundation

extension Matte {
    /// Stamps a round brush. Inside `hardness * radius` the brush is solid, then it fades out.
    public mutating func stamp(x cx: Float, y cy: Float, radius: Float, adding: Bool, hardness: Float = 0.6) {
        guard radius > 0 else { return }
        let x0 = max(0, Int(cx - radius)), x1 = min(width - 1, Int(cx + radius))
        let y0 = max(0, Int(cy - radius)), y1 = min(height - 1, Int(cy + radius))
        guard x0 <= x1, y0 <= y1 else { return }
        let solid = radius * hardness
        for y in y0...y1 {
            let dy = Float(y) + 0.5 - cy
            for x in x0...x1 {
                let dx = Float(x) + 0.5 - cx
                let d = (dx * dx + dy * dy).squareRoot()
                if d >= radius { continue }
                let strength = d <= solid ? 1 : (radius - d) / (radius - solid)
                let i = y * width + x
                let level = UInt8(strength * 255 + 0.5)
                if adding {
                    values[i] = Swift.max(values[i], level)
                } else {
                    values[i] = Swift.min(values[i], 255 - level)
                }
            }
        }
    }

    /// Stamps along a segment, spaced closely enough that the stroke looks continuous.
    public mutating func stroke(from a: (x: Float, y: Float), to b: (x: Float, y: Float),
                                radius: Float, adding: Bool, hardness: Float = 0.6) {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        let steps = Swift.max(1, Int(length / Swift.max(1, radius * 0.25)))
        for s in 1...steps {
            let t = Float(s) / Float(steps)
            stamp(x: a.x + dx * t, y: a.y + dy * t, radius: radius, adding: adding, hardness: hardness)
        }
    }
}
