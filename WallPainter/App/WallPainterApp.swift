import SwiftUI

@main
struct WallPainterApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
                .onAppear { WallDetector.shared.preload() }
        }
    }
}
