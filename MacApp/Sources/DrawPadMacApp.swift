import SwiftUI
import PencilKit

@main
struct DrawPadMacApp: App {
    @StateObject private var app = MacAppModel()

    var body: some Scene {
        WindowGroup("DrawPad") {
            MainView()
                .environmentObject(app)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
    }
}
