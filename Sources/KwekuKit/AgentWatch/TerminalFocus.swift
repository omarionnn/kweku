import AppKit
import ApplicationServices

/// Click-to-focus: from a session's pid, walk up the process tree to the
/// owning terminal app, then raise the specific window via Accessibility.
///
/// Accessibility permission is requested lazily — only the first time the
/// user actually clicks — and we degrade to plain app activation if denied.
public enum TerminalFocus {

    // MARK: - Pure walk (unit-tested with injected closures)

    /// Walk parent pids until one is a regular GUI app. `maxDepth` bounds
    /// against cycles.
    public static func owningApp(from pid: Int32,
                                 parent: (Int32) -> Int32?,
                                 isApp: (Int32) -> Bool,
                                 maxDepth: Int = 24) -> Int32? {
        var current = pid
        for _ in 0..<maxDepth {
            if isApp(current) { return current }
            guard let next = parent(current), next > 1, next != current else { return nil }
            current = next
        }
        return nil
    }

    // MARK: - System adapters

    /// Real parent pid via sysctl KERN_PROC_PID.
    static func realParent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    static func isRegularApp(_ pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
    }

    // MARK: - Focus

    /// Raise the terminal window owning `session`. Returns false when no
    /// owning app could be found.
    @MainActor
    @discardableResult
    public static func focus(session: AgentSession) -> Bool {
        guard let appPid = owningApp(from: session.pid,
                                     parent: realParent(of:),
                                     isApp: isRegularApp(_:)),
              let app = NSRunningApplication(processIdentifier: appPid)
        else { return false }

        // Lazy Accessibility request — fires the system prompt only now,
        // on the user's first actual click.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            raiseBestWindow(appPid: appPid, cwd: session.cwd)
        }
        // With or without AX, bring the app forward (graceful degrade).
        app.activate()
        return true
    }

    /// Raise the app window whose title mentions the session's directory;
    /// falls back to the app's first window.
    private static func raiseBestWindow(appPid: Int32, cwd: String) {
        let axApp = AXUIElementCreateApplication(appPid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty
        else { return }

        let needle = (cwd as NSString).lastPathComponent.lowercased()
        var best = windows[0]
        if !needle.isEmpty {
            for win in windows {
                var t: AnyObject?
                if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &t) == .success,
                   let title = (t as? String)?.lowercased(), title.contains(needle) {
                    best = win
                    break
                }
            }
        }
        AXUIElementPerformAction(best, kAXRaiseAction as CFString)
        var focused: AnyObject = kCFBooleanTrue
        AXUIElementSetAttributeValue(best, kAXMainAttribute as CFString, focused)
        _ = focused
    }
}
