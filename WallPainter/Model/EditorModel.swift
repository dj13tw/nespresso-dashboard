import SwiftUI
import UIKit
import WallPainterCore

enum EditTool: String, CaseIterable, Identifiable {
    case paint, add, erase, wand

    var id: Self { self }

    var title: String {
        switch self {
        case .paint: "配色"
        case .add: "補畫"
        case .erase: "擦除"
        case .wand: "魔術棒"
        }
    }

    var isBrush: Bool { self == .add || self == .erase }
    /// Tools that edit where the paint goes; the painted area is tinted while they are active.
    var editsMask: Bool { self != .paint }
}

/// Holds one photo being repainted: the AI mask, the user's edits, and the rendered preview.
@MainActor
final class EditorModel: ObservableObject {
    enum Phase: Equatable {
        case analyzing
        case ready
        case failed(String)
    }

    /// Photos are processed at this size: sharp on a phone screen, fast enough to repaint live.
    static let workingDimension: CGFloat = 2048
    private static let undoLimit = 10

    @Published private(set) var phase: Phase = .analyzing
    @Published private(set) var rendered: UIImage?
    @Published private(set) var canUndo = false
    @Published private(set) var isWorking = false
    @Published var notice: String?
    @Published var showOriginal = false
    @Published var color = Palette.defaultColor {
        didSet { scheduleRender() }
    }
    @Published var tool: EditTool = .paint {
        didSet { if oldValue.editsMask != tool.editsMask { scheduleRender() } }
    }
    /// Brush diameter in screen points.
    @Published var brushSize: Double = 40
    @Published var wandTolerance: Double = 1

    let original: UIImage
    var imageSize: CGSize { original.size }

    private var recolorer: Recolorer?
    private var prediction: WallPrediction?
    private var wand: MagicWand?
    private var aiMatte: Matte?
    private var matte: Matte?
    private var wallLuminance: Float?
    private var undoStack: [Matte] = []
    private var lastStrokePoint: CGPoint?
    private var renderInFlight = false
    private var renderPending = false

    init(image: UIImage) {
        original = image.normalized(maxDimension: Self.workingDimension)
    }

    // MARK: - Analysis

    func start() async {
        guard phase == .analyzing, recolorer == nil else { return }
        let image = original
        do {
            let (recolorer, prediction, matte) = try await Task.detached(priority: .userInitiated) {
                guard let cgImage = image.cgImage, let pixels = RGBAImage(cgImage: cgImage) else {
                    throw WallDetectorError.noOutput
                }
                let prediction = try WallDetector.shared.predict(cgImage)
                let matte = MaskRefiner.refine(probability: prediction.wall, probabilityWidth: prediction.width,
                                               probabilityHeight: prediction.height, image: pixels)
                return (Recolorer(image: pixels), prediction, matte)
            }.value
            self.recolorer = recolorer
            self.prediction = prediction
            aiMatte = matte
            self.matte = matte
            wallLuminance = recolorer.wallLuminance(matte)
            phase = .ready
            if matte.coverage < 0.01 {
                notice = "沒有偵測到牆面。可以用「補畫」或「魔術棒」自己選要上色的地方。"
            }
            scheduleRender()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Mask editing (points are in image pixels)

    func beginStroke(at point: CGPoint, radius: CGFloat) {
        guard matte != nil else { return }
        pushUndo()
        lastStrokePoint = point
        matte?.stamp(x: Float(point.x), y: Float(point.y), radius: Float(radius), adding: tool == .add)
        scheduleRender()
    }

    func continueStroke(to point: CGPoint, radius: CGFloat) {
        guard let last = lastStrokePoint else { return beginStroke(at: point, radius: radius) }
        matte?.stroke(from: (Float(last.x), Float(last.y)), to: (Float(point.x), Float(point.y)),
                      radius: Float(radius), adding: tool == .add)
        lastStrokePoint = point
        scheduleRender()
    }

    func endStroke() {
        lastStrokePoint = nil
        maskDidChange()
    }

    func selectWithWand(at point: CGPoint) {
        guard let recolorer, matte != nil, !isWorking else { return }
        isWorking = true
        let prediction = prediction
        let existingWand = wand
        let tolerance = Float(wandTolerance)
        Task {
            let (wand, selection) = await Task.detached(priority: .userInitiated) {
                let wand = existingWand ?? MagicWand(image: recolorer.image, barrier: prediction?.barrier,
                                                     barrierWidth: prediction?.width ?? 0,
                                                     barrierHeight: prediction?.height ?? 0)
                return (wand, wand.select(x: Int(point.x), y: Int(point.y), tolerance: tolerance))
            }.value
            self.wand = wand
            isWorking = false
            guard selection.coverage > 0 else {
                notice = "這裡選不到牆面，試試點在牆面較平整的地方，或改用「補畫」。"
                return
            }
            guard var updated = matte else { return }
            updated.formUnion(selection)
            pushUndo()
            matte = updated
            maskDidChange()
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        matte = previous
        canUndo = !undoStack.isEmpty
        maskDidChange()
    }

    func resetToDetected() {
        guard let aiMatte, matte != aiMatte else { return }
        pushUndo()
        matte = aiMatte
        maskDidChange()
    }

    private func pushUndo() {
        guard let matte else { return }
        undoStack.append(matte)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        canUndo = true
    }

    private func maskDidChange() {
        if let matte, let recolorer {
            // Keep the previous reference when the mask is emptied so colors don't jump.
            wallLuminance = recolorer.wallLuminance(matte) ?? wallLuminance
        }
        scheduleRender()
    }

    // MARK: - Rendering

    /// Renders off the main thread; while one render runs, further requests collapse into one.
    private func scheduleRender() {
        guard phase == .ready, let recolorer, let matte else { return }
        if renderInFlight {
            renderPending = true
            return
        }
        renderInFlight = true
        let rgb = color.rgb, highlight = tool.editsMask, luminance = wallLuminance
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                recolorer.render(matte: matte, color: rgb, highlight: highlight,
                                 referenceLuminance: luminance).makeUIImage()
            }.value
            rendered = image
            renderInFlight = false
            if renderPending {
                renderPending = false
                scheduleRender()
            }
        }
    }

    /// The finished photo without the editing tint, for saving and sharing.
    func finalImage() async -> UIImage? {
        guard let recolorer, let matte else { return nil }
        let rgb = color.rgb, luminance = wallLuminance
        return await Task.detached(priority: .userInitiated) {
            recolorer.render(matte: matte, color: rgb, referenceLuminance: luminance).makeUIImage()
        }.value
    }
}
