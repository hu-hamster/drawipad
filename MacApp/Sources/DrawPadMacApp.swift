import SwiftUI
import PencilKit

@main
struct DrawPadMacApp: App {
    @StateObject private var app = MacAppModel()

    var body: some Scene {
        WindowGroup("DrawPad") {
            MainView()
                .environmentObject(app)
        }
        .windowToolbarStyle(.unified)
    }
}
