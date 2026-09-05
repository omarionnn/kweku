import AppKit
import SwiftUI

/// Process entry point. Runs as an accessory (`LSUIElement`) app: no Dock
/// icon, no menu bar item — the notch is the entire UI.
public enum KwekuApp {
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
        Self.migrateLegacyDefaults()
        controller = NotchController { viewModel in
            AnyView(NotchContentRoot(viewModel: viewModel))
        }
    }

    /// One-shot copy of settings from the pre-rebrand defaults domain.
    static func migrateLegacyDefaults() {
        let std = UserDefaults.standard
        guard !std.bool(forKey: "kwekuMigrated"),
              let old = UserDefaults(suiteName: "com.charlie.app") else { return }
        for key in ["geminiApiKey", "geminiLiveModel", "nookMode",
                    "weatherManualCity", "weatherLastSnapshot"] {
            if std.object(forKey: key) == nil, let value = old.object(forKey: key) {
                std.set(value, forKey: key)
            }
        }
        std.set(true, forKey: "kwekuMigrated")
    }
}
