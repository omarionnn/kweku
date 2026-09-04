import AppKit
import SwiftUI

/// Process entry point. Runs as an accessory (`LSUIElement`) app: no Dock
/// icon, no menu bar item — the notch is the entire UI.
public enum NotchlingApp {
    public static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController { viewModel in
            AnyView(NotchContentRoot(viewModel: viewModel))
        }
    }
}
