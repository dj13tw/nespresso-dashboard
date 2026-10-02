import XCTest
@testable import WallPainterCore

final class ColorTests: XCTestCase {
    func testHexRoundTrip() {
        XCTAssertEqual(RGB(hex: "#6F8F8A"), RGB(r: 0x6F, g: 0x8F, b: 0x8A))
        XCTAssertEqual(RGB(hex: "a0b1c2")?.hex, "#A0B1C2")
        XCTAssertNil(RGB(hex: "#12345"))
        XCTAssertNil(RGB(hex: "zzzzzz"))
    }

    func testSRGBRoundTrip() {
        for v in 0...255 {
            XCTAssertEqual(Int(ColorMath.encode(ColorMath.toLinear[v])), v, "value \(v)")
        }
    }
}

final class GuidedFilterTests: XCTestCase {
    func testBoxMeanMatchesBruteForce() {
        let w = 13, h = 9, r = 2
        let src = (0..<(w * h)).map { Float(($0 * 37) % 11) }
        let fast = GuidedFilter.boxMean(src, width: w, height: h, radius: r)
        for y in 0..<h {
            for x in 0..<w {
                var sum: Float = 0, n: Float = 0
                for yy in max(0, y - r)...min(h - 1, y + r) {
                    for xx in max(0, x - r)...min(w - 1, x + r) {
                        sum += src[yy * w + xx]
                        n += 1
                    }
                }
                XCTAssertEqual(fast[y * w + x], sum / n, accuracy: 1e-4)
            }
        }
    }

    func testSnapsBlurryMaskToGuideEdge() {
        // Guide: dark left half, bright right half. Input: a ramp that is unsure about the edge.
        let w = 40, h = 10
        var guide = [Float](repeating: 0, count: w * h)
        var input = guide
        for y in 0..<h {
            for x in 0..<w {
                guide[y * w + x] = x < 20 ? 0.1 : 0.9
                input[y * w + x] = min(1, max(0, Float(x - 10) / 20))
            }
        }
        let out = GuidedFilter.apply(guide: guide, input: input, width: w, height: h, radius: 4, epsilon: 1e-4)
        let row = 5 * w
        XCTAssertLessThan(out[row + 17], 0.35, "left of the edge should stay low")
        XCTAssertGreaterThan(out[row + 22], 0.65, "right of the edge should jump high")
    }
}

final class RefinerTests: XCTestCase {
    func testBilinearMatchesHalfPixelConvention() {
        let src: [Float] = [0, 1]
        let out = MaskRefiner.resizeBilinear(src, width: 2, height: 1, toWidth: 4, toHeight: 1)
        XCTAssertEqual(out, [0, 0.25, 0.75, 1])
    }

    func testRefineProducesFullSizeMatte() {
        let image = RGBAImage(width: 64, height: 48, fill: RGB(r: 200, g: 200, b: 200))
        let prob = [Float](repeating: 0.9, count: 16 * 12)
        let matte = MaskRefiner.refine(probability: prob, probabilityWidth: 16, probabilityHeight: 12, image: image)
        XCTAssertEqual(matte.width, 64)
        XCTAssertEqual(matte.height, 48)
        XCTAssertEqual(matte.coverage, 1, accuracy: 1e-6)
    }
}

final class RecolorerTests: XCTestCase {
    /// Left half is a lit wall, right half the same wall in shadow; a sofa pixel sits outside the matte.
    private func scene() -> (RGBAImage, Matte) {
        var image = RGBAImage(width: 4, height: 1, fill: RGB(r: 230, g: 230, b: 230))
        let shadow: [UInt8] = [115, 115, 115]
        for (k, v) in shadow.enumerated() { image.pixels[1 * 4 + k] = v }
        for (k, v) in [UInt8(120), 60, 30].enumerated() { image.pixels[3 * 4 + k] = v }
        let matte = Matte(width: 4, height: 1, values: [255, 255, 255, 0])
        return (image, matte)
    }

    func testKeepsUnmaskedPixels() {
        let (image, matte) = scene()
        let out = Recolorer(image: image).render(matte: matte, color: RGB(r: 40, g: 90, b: 160))
        XCTAssertEqual(out.color(x: 3, y: 0), image.color(x: 3, y: 0))
    }

    func testAppliesHueAndKeepsShading() {
        let (image, matte) = scene()
        let out = Recolorer(image: image).render(matte: matte, color: RGB(r: 40, g: 90, b: 160))
        let lit = out.color(x: 0, y: 0), shade = out.color(x: 1, y: 0)
        XCTAssertGreaterThan(lit.b, lit.r, "takes on the blue paint")
        XCTAssertGreaterThan(shade.b, shade.r)
        XCTAssertLessThan(Int(shade.b), Int(lit.b) - 40, "shadow stays darker than the lit area")
    }

    func testAverageWallShowsChosenColor() {
        let image = RGBAImage(width: 3, height: 3, fill: RGB(r: 180, g: 180, b: 180))
        let matte = Matte(width: 3, height: 3, value: 255)
        let target = RGB(r: 111, g: 143, b: 138)
        let out = Recolorer(image: image).render(matte: matte, color: target)
        let c = out.color(x: 1, y: 1)
        XCTAssertEqual(Int(c.r), Int(target.r), accuracy: 1)
        XCTAssertEqual(Int(c.g), Int(target.g), accuracy: 1)
        XCTAssertEqual(Int(c.b), Int(target.b), accuracy: 1)
    }

    func testEmptyMatteRendersOriginal() {
        let (image, _) = scene()
        let out = Recolorer(image: image).render(matte: Matte(width: 4, height: 1), color: RGB(r: 0, g: 0, b: 255))
        XCTAssertEqual(out, image)
    }
}

final class BrushTests: XCTestCase {
    func testAddThenErase() {
        var matte = Matte(width: 50, height: 50)
        matte.stroke(from: (10, 25), to: (40, 25), radius: 5, adding: true)
        XCTAssertEqual(matte.values[25 * 50 + 25], 255)
        XCTAssertEqual(matte.values[5 * 50 + 25], 0)
        matte.stamp(x: 25, y: 25, radius: 5, adding: false)
        XCTAssertEqual(matte.values[25 * 50 + 25], 0)
        XCTAssertEqual(matte.values[25 * 50 + 12], 255, "erasing one spot leaves the rest")
    }

    func testStampClipsAtBorders() {
        var matte = Matte(width: 10, height: 10)
        matte.stamp(x: -2, y: 0, radius: 4, adding: true)
        matte.stamp(x: 100, y: 100, radius: 4, adding: true)
        XCTAssertGreaterThan(matte.values[0], 200, "brush centered off-canvas still reaches the edge")
        XCTAssertEqual(matte.values[99], 0)
    }
}

final class MagicWandTests: XCTestCase {
    /// A wall with a lighting gradient, split by a dark door frame, with a red sofa block.
    private func room() -> RGBAImage {
        let w = 120, h = 80
        var image = RGBAImage(width: w, height: h, fill: RGB(r: 0, g: 0, b: 0))
        for y in 0..<h {
            for x in 0..<w {
                let shade = 150 + x * 80 / w  // gentle left-to-right light falloff
                var c = RGB(r: UInt8(shade), g: UInt8(shade - 8), b: UInt8(shade - 20))
                if (58...61).contains(x) { c = RGB(r: 50, g: 40, b: 30) }  // frame
                if y > 55 && (10...45).contains(x) { c = RGB(r: 170, g: 40, b: 40) }  // sofa
                let i = (y * w + x) * 4
                image.pixels[i] = c.r; image.pixels[i + 1] = c.g; image.pixels[i + 2] = c.b
            }
        }
        return image
    }

    func testSelectsShadedWallButNotSofaOrAcrossFrame() {
        let image = room()
        let matte = MagicWand(image: image, workingSize: 120).select(x: 20, y: 20)
        func v(_ x: Int, _ y: Int) -> UInt8 { matte.values[y * image.width + x] }
        XCTAssertEqual(v(20, 20), 255)
        XCTAssertEqual(v(50, 10), 255, "follows the gradient across the wall")
        XCTAssertEqual(v(25, 70), 0, "skips the sofa")
        XCTAssertEqual(v(100, 20), 0, "stops at the frame")
    }

    func testOutOfBoundsSeedSelectsNothing() {
        let image = room()
        XCTAssertEqual(MagicWand(image: image).select(x: -1, y: 5).coverage, 0)
    }
}
