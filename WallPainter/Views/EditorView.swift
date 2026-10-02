import SwiftUI

struct EditorView: View {
    @StateObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var shareImage: UIImage?
    @State private var message: String?

    init(image: UIImage) {
        _model = StateObject(wrappedValue: EditorModel(image: image))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    CanvasView(model: model)
                    statusOverlay
                    if model.phase == .ready {
                        compareButton.padding(12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

                if model.phase == .ready {
                    controls
                }
            }
            .navigationTitle("牆面換色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task { await model.start() }
            .sheet(isPresented: Binding(get: { shareImage != nil }, set: { if !$0 { shareImage = nil } })) {
                if let shareImage {
                    ShareSheet(items: [shareImage]).presentationDetents([.medium, .large])
                }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) {}
            }
            .alert(model.notice ?? "", isPresented: Binding(get: { model.notice != nil },
                                                           set: { if !$0 { model.notice = nil } })) {
                Button("好", role: .cancel) {}
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var statusOverlay: some View {
        switch model.phase {
        case .analyzing:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large).tint(.white)
                Text("正在辨識牆面…").foregroundStyle(.white)
            }
            .padding(24)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let reason):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle)
                Text(reason).multilineTextAlignment(.center)
                Button("關閉") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if model.isWorking {
                ProgressView().controlSize(.large).tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var compareButton: some View {
        Label("按住看原圖", systemImage: model.showOriginal ? "eye.fill" : "eye")
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in model.showOriginal = true }
                    .onEnded { _ in model.showOriginal = false }
            )
            .accessibilityAddTraits(.isButton)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("工具", selection: $model.tool) {
                ForEach(EditTool.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            switch model.tool {
            case .paint:
                PaletteView(selection: $model.color)
            case .add, .erase:
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.tool == .add ? "用手指塗抹沒變色的牆面。" : "塗抹不該上色的地方（家具、天花板）。")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Image(systemName: "circle.fill").font(.system(size: 8))
                        Slider(value: $model.brushSize, in: 12...120)
                        Image(systemName: "circle.fill").font(.system(size: 22))
                    }
                    .foregroundStyle(.secondary)
                }
            case .wand:
                VStack(alignment: .leading, spacing: 4) {
                    Text("點一下漏掉的牆面，會自動選取同色的整片區域。")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Text("範圍").font(.footnote)
                        Slider(value: $model.wandTolerance, in: 0.5...2.5)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("關閉") { dismiss() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .accessibilityLabel("復原")

            Menu {
                Button {
                    Task { await save() }
                } label: {
                    Label("儲存到相簿", systemImage: "square.and.arrow.down")
                }
                Button {
                    Task { shareImage = await model.finalImage() }
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button {
                    model.resetToDetected()
                } label: {
                    Label("還原自動偵測的牆面", systemImage: "wand.and.rays")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(model.phase != .ready)
        }
    }

    private func save() async {
        guard let image = await model.finalImage() else { return }
        do {
            try await PhotoSaver.save(image)
            message = "已儲存到相簿"
        } catch {
            message = error.localizedDescription
        }
    }
}
