import AppKit

/// Talks to the Spotify desktop app via AppleScript. The public route (no
/// MediaRemote): reads state and sends transport commands.
///
/// Never launches Spotify — every call is guarded by a running-app check, so
/// nothing (and no Automation prompt) happens unless Spotify is already open.
enum SpotifyController {
    static let bundleID = "com.spotify.client"

    /// AppleScript error number for "not authorised" (Automation denied).
    private static let notAuthorized = -1743

    enum Fetch: Equatable {
        case ok(NowPlaying)
        case notRunning
        case denied      // user hasn't granted Automation for Spotify
        case failed
    }

    static func isRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// One round trip for everything the island shows.
    ///
    /// The player settings (volume, shuffle, repeat) are read inside a `try`
    /// and default to sane values: they're a nice-to-have, and a Spotify build
    /// that refuses one of the three must not be able to take the whole
    /// now-playing read down with it. The payload keeps its original eight
    /// fields in their original order, so an older reply still parses.
    private static let getScript = """
    tell application id "com.spotify.client"
        set d to (ASCII character 9)
        set s to (player state as text)
        set v to 0
        set sh to false
        set rp to false
        try
            set v to (sound volume as integer)
            set sh to (shuffling as boolean)
            set rp to (repeating as boolean)
        end try
        set tail to d & (v as text) & d & (sh as text) & d & (rp as text)
        if s is "stopped" then return s & d & "" & d & "" & d & "" & d & "0" & d & "0" & d & "" & d & "" & tail
        set t to current track
        return s & d & (name of t) & d & (artist of t) & d & (album of t) & d & (duration of t as text) & d & (player position as text) & d & (artwork url of t) & d & (id of t) & tail
    end tell
    """

    static func fetch() -> Fetch {
        guard isRunning() else { return .notRunning }
        guard let script = NSAppleScript(source: getScript) else { return .failed }
        var error: NSDictionary?
        let out = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            return code == notAuthorized ? .denied : .failed
        }
        guard let raw = out.stringValue else { return .failed }
        return .ok(NowPlaying.parse(raw))
    }

    // MARK: Transport (fire-and-forget; guarded so they never launch Spotify)

    static func playPause() { run("playpause") }
    static func next() { run("next track") }
    static func previous() { run("previous track") }
    static func seek(toSeconds seconds: Double) { run("set player position to \(Int(seconds))") }

    /// Spotify's own output level, 0…100 — not the system volume, so turning
    /// it down here leaves everything else on the machine alone.
    static func setVolume(_ percent: Int) {
        run("set sound volume to \(clampVolume(percent))")
    }

    static func setShuffling(_ on: Bool) { run("set shuffling to \(on)") }
    static func setRepeating(_ on: Bool) { run("set repeating to \(on)") }

    /// Bring Spotify forward on this track's page.
    ///
    /// The URI navigates but does not reliably *raise* the app. Kweku is an
    /// `LSUIElement` living in a `.nonactivatingPanel`, so it is never the
    /// active application, and macOS declines to pull an already-running
    /// handler in front of whatever you are really working in on its behalf.
    /// The URL lands, Spotify changes page behind your windows, and from the
    /// front it looks like the click did nothing.
    ///
    /// So ask twice: `activates` covers the case where Spotify had to be
    /// launched, and the explicit activation covers the far more common one
    /// where it was already running. Raising happens after the open completes,
    /// so the app is on the right page before it comes forward rather than
    /// flashing the previous track on the way.
    static func openTrack(_ trackID: String) {
        guard isRunning(), trackID.hasPrefix("spotify:"),
              let url = URL(string: trackID) else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { raise() }
        }
    }

    /// Pull the running Spotify in front of everything else.
    static func raise() {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?
            .activate(options: [.activateAllWindows])
    }

    /// AppleScript silently clamps out-of-range volumes on some builds and
    /// errors on others; do it here so the behaviour is ours.
    static func clampVolume(_ percent: Int) -> Int { min(100, max(0, percent)) }

    private static func run(_ command: String) {
        guard isRunning() else { return }
        NSAppleScript(source: "tell application id \"\(bundleID)\" to \(command)")?
            .executeAndReturnError(nil)
    }
}
