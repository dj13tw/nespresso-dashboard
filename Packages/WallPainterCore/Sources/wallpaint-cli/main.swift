// Runs the app's processing on raw dumps so it can be checked off-device:
//   wallpaint-cli <image.rgba> <width> <height> <prob.f32> <pw> <ph> <#RRGGBB> <out.rgba> <out-mask.u8> [wandX wandY barrier.f32]
// tools/swift_pipeline_check.py produces the inputs from a photo and the Core ML/PyTorch model.
import Foundation
import WallPainterCore

let args = CommandLine.arguments
guard args.count == 10 || args.count == 13,
      let width = Int(args[2]), let height = Int(args[3]),
      let pw = Int(args[5]), let ph = Int(args[6]),
      let color = RGB(hex: args[7]) else {
    FileHandle.standardError.write("usage: wallpaint-cli image.rgba w h prob.f32 pw ph #RRGGBB out.rgba out-mask.u8 [wandX wandY barrier.f32]\n".data(using: .utf8)!)
    exit(2)
}

func read(_ path: String) -> Data { FileManager.default.contents(atPath: path) ?? Data() }

let image = RGBAImage(width: width, height: height, pixels: [UInt8](read(args[1])))
let probability: [Float] = read(args[4]).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

func timed<T>(_ label: String, _ body: () -> T) -> T {
    let start = Date()
    let result = body()
    print(String(format: "%@: %.0f ms", label, Date().timeIntervalSince(start) * 1000))
    return result
}

var matte = timed("refine") {
    MaskRefiner.refine(probability: probability, probabilityWidth: pw, probabilityHeight: ph, image: image)
}
if args.count == 13, let wx = Int(args[10]), let wy = Int(args[11]) {
    let barrier: [Float] = read(args[12]).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let wand = timed("wand setup") {
        MagicWand(image: image, barrier: barrier, barrierWidth: pw, barrierHeight: ph)
    }
    let picked = timed("wand select") { wand.select(x: wx, y: wy) }
    matte.formUnion(picked)
}
let recolorer = timed("recolor setup") { Recolorer(image: image) }
let output = timed("render") { recolorer.render(matte: matte, color: color) }
print(String(format: "coverage %.1f%%", matte.coverage * 100))

_ = FileManager.default.createFile(atPath: args[8], contents: Data(output.pixels))
_ = FileManager.default.createFile(atPath: args[9], contents: Data(matte.values))
