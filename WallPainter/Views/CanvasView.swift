import SwiftUI

/// Maps between view points and image pixels for an aspect-fit image.
struct FitTransform {
    let rect: CGRect
    /// View points per image pixel.
    let scale: CGFloat

    init(imageSize: CGSize, in container: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0 else {
            rect = .zero
            scale = 1
            return
        }
        scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        rect = CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    func imagePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - rect.minX) / scale, y: (point.y - rect.minY) / scale)
    }
}

/// The photo, plus brush and tap handling while a mask tool is active.
struct CanvasView: View {
    @ObservedObject var model: EditorModel
    @State private var cursor: CGPoint?
    @State private var drawing = false

    var body: some View {
        GeometryReader { geometry in
            let fit = FitTransform(imageSize: model.imageSize, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: displayedImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.rect.width, height: fit.rect.height)
                    .position(x: fit.rect.midX, y: fit.rect.midY)

                if let cursor, model.tool.isBrush {
                    Circle()
                        .strokeBorder(.white, lineWidth: 1.5)
                        .background(Circle().fill(.white.opacity(0.15)))
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .frame(width: model.brushSize, height: model.brushSize)
                        .position(cursor)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(brushGesture(fit), including: model.tool.isBrush ? .all : .subviews)
            .gesture(wandGesture(fit), including: model.tool == .wand ? .all : .subviews)
        }
    }

    private var displayedImage: UIImage {
        model.showOriginal ? model.original : (model.rendered ?? model.original)
    }

    private func brushGesture(_ fit: FitTransform) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                cursor = value.location
                let point = fit.imagePoint(value.location)
                let radius = model.brushSize / 2 / fit.scale
                if drawing {
                    model.continueStroke(to: point, radius: radius)
                } else {
                    drawing = true
                    model.beginStroke(at: point, radius: radius)
                }
            }
            .onEnded { _ in
                drawing = false
                cursor = nil
                model.endStroke()
            }
    }

    private func wandGesture(_ fit: FitTransform) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .local)
            .onEnded { value in
                guard fit.rect.contains(value.location) else { return }
                model.selectWithWand(at: fit.imagePoint(value.location))
            }
    }
}
