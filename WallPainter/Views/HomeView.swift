import PhotosUI
import SwiftUI

struct EditorSession: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct HomeView: View {
    @State private var showCamera = false
    @State private var capturedPhoto: UIImage?
    @State private var libraryItem: PhotosPickerItem?
    @State private var session: EditorSession?
    @State private var loadFailed = false

    private let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "paintbrush.pointed.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("牆面換色")
                .font(.largeTitle.bold())
            Text("拍一張室內照片，自動找出牆面，\n保留家具與光影，直接試上新顏色。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()

            Button {
                showCamera = true
            } label: {
                Label("拍照", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!cameraAvailable)

            PhotosPicker(selection: $libraryItem, matching: .images) {
                Label("從相簿選擇", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Text("小技巧：退後一點讓整面牆入鏡，光線均勻、少逆光，效果最好。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .padding(24)
        .fullScreenCover(isPresented: $showCamera, onDismiss: openCapturedPhoto) {
            CameraPicker(onImage: { capturedPhoto = $0 }, onFinish: { showCamera = false })
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $session) { session in
            EditorView(image: session.image)
        }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    session = EditorSession(image: image)
                } else {
                    loadFailed = true
                }
                libraryItem = nil
            }
        }
        .alert("無法讀取這張照片", isPresented: $loadFailed) {
            Button("好", role: .cancel) {}
        }
    }

    private func openCapturedPhoto() {
        guard let photo = capturedPhoto else { return }
        capturedPhoto = nil
        session = EditorSession(image: photo)
    }
}
