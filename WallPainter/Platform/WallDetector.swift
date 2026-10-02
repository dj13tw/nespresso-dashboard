import CoreGraphics
import CoreML
import Foundation
import Vision

/// Output of the on-device SegFormer model, at the model's own resolution (160x160).
struct WallPrediction: Sendable {
    let wall: [Float]
    /// Floor + ceiling probability; the magic wand will not cross it.
    let barrier: [Float]
    let width: Int
    let height: Int
}

enum WallDetectorError: LocalizedError {
    case modelMissing
    case noOutput

    var errorDescription: String? {
        switch self {
        case .modelMissing: "找不到牆面辨識模型（WallSegmenter），請確認專案有包含 Models 資料夾。"
        case .noOutput: "牆面辨識沒有產生結果，請換一張照片再試一次。"
        }
    }
}

/// Runs WallSegmenter.mlpackage (see tools/convert_model.py) through Vision.
final class WallDetector: @unchecked Sendable {  // model access guarded by `lock`
    static let shared = WallDetector()

    private let lock = NSLock()
    private var model: VNCoreMLModel?

    /// Loading compiles the model for the Neural Engine, which takes a few seconds the first time.
    func preload() {
        DispatchQueue.global(qos: .utility).async { _ = try? self.loadModel() }
    }

    func predict(_ image: CGImage) throws -> WallPrediction {
        let request = VNCoreMLRequest(model: try loadModel())
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let observations = request.results as? [VNCoreMLFeatureValueObservation] ?? []

        func output(_ name: String) throws -> MLMultiArray {
            guard let array = observations.first(where: { $0.featureName == name })?.featureValue.multiArrayValue
            else { throw WallDetectorError.noOutput }
            return array
        }
        let wall = try output("wall")
        let barrier = try output("barrier")
        let shape = wall.shape.map(\.intValue)  // [1, 1, H, W]
        guard shape.count >= 2 else { throw WallDetectorError.noOutput }
        return WallPrediction(
            wall: MLShapedArray<Float>(converting: wall).scalars,
            barrier: MLShapedArray<Float>(converting: barrier).scalars,
            width: shape[shape.count - 1],
            height: shape[shape.count - 2]
        )
    }

    private func loadModel() throws -> VNCoreMLModel {
        lock.lock()
        defer { lock.unlock() }
        if let model { return model }
        guard let url = Bundle.main.url(forResource: "WallSegmenter", withExtension: "mlmodelc") else {
            throw WallDetectorError.modelMissing
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let loaded = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: configuration))
        model = loaded
        return loaded
    }
}
