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
    private var captureProbe: ScreenCaptureManager?
    private var captureProbeTimeline: ScreenTimelineStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.migrateLegacyDefaults()
        controller = NotchController { viewModel in
            AnyView(NotchContentRoot(viewModel: viewModel))
        }
        // Diagnostic rig: run the vision capture pipeline alone — no Gemini,
        // no mic — dumping frames via KWEKU_LIVE_DEBUG so focus-following can
        // be verified against real window switches from outside the app.
        // Also switchable via `defaults write com.kweku.app captureProbe -bool YES`,
        // because passing env vars means launching by hand, and a hand-launched
        // app is exactly the variable you're trying to hold still when the
        // question is "does this app have its TCC grant?".
        if ProcessInfo.processInfo.environment["KWEKU_CAPTURE_PROBE"] != nil
            || UserDefaults.standard.bool(forKey: "captureProbe") {
            let probe = ScreenCaptureManager()
            let timeline = ScreenTimelineStore()
            probe.onIssue = { ScreenCaptureManager.dbg("probe issue: \($0)") }
            probe.onAim = { app, title, redacted in
                ScreenCaptureManager.dbg("probe aim app='\(app)' title='\(title)' "
                                         + "redacted=\(redacted)")
            }
            // Exercise the real recording path, so the rig can prove the
            // timeline fills and that redacted windows leave no trace in it.
            probe.onMoment = { app, title, jpeg, redacted in
                timeline.record(app: app, title: title, jpeg: jpeg, redacted: redacted)
            }
            probe.startStreaming { _ in }
            captureProbe = probe
            captureProbeTimeline = timeline
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
