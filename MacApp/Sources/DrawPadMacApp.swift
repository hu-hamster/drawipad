import SwiftUI
import PencilKit
import AppKit

@main
struct DrawPadMacApp: App {
    @StateObject private var app = MacAppModel()

    init() {
        // Debug builds move around inside DerivedData and LaunchServices can
        // keep showing the generic placeholder in the Dock.  Set the bundled
        // icon explicitly so the running app always uses the current artwork.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup("DrawPad") {
            MainView()
                .environmentObject(app)
        }
        .windowToolbarStyle(.unified)
    }
}
