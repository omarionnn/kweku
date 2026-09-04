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

    private static let getScript = """
    tell application id "com.spotify.client"
        set d to (ASCII character 9)
        set s to (player state as text)
        if s is "stopped" then return s
        set t to current track
        return s & d & (name of t) & d & (artist of t) & d & (album of t) & d & (duration of t as text) & d & (player position as text) & d & (artwork url of t) & d & (id of t)
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

    private static func run(_ command: String) {
        guard isRunning() else { return }
        NSAppleScript(source: "tell application id \"\(bundleID)\" to \(command)")?
            .executeAndReturnError(nil)
    }
}
