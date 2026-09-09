import AppKit
import SwiftUI

/// Kweku's settings, in a window rather than in the right-click menu.
///
/// The menu had grown to 28 items, of which 15 were configuration you touch
/// once: two API keys, a city, a licence field, and five YouTube channels that
/// were menu rows pretending to be a list. A context menu is for what you do
/// *now*; none of that qualified. Worse, the menu had no cost function — every
/// feature could append itself for free, so it grew without anyone deciding it
/// should. This window is where new settings land instead.
///
/// A submenu was the cheaper fix and is deliberately not what this is: see
/// `564f778`, where a submenu inside this context menu dropped clicks and had
/// to be flattened back out. Nesting was tried and it does not work here.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    public static let shared = SettingsWindowController()

    private var window: NSWindow?

    /// Show the window, or raise it if it is already up.
    ///
    /// Kweku is an `LSUIElement` accessory, so it is never the active app on
    /// its own. Without the explicit activate the window orders in *behind*
    /// whatever you were using and silently refuses to take a keystroke, which
    /// for a panel that is mostly text fields reads as "settings are broken".
    public func show(weather: WeatherHub,
                     live: LiveSessionController,
                     agents: AgentWatchHub,
                     youtube: YouTubeHub) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = SettingsView(weather: weather, live: live,
                                agents: agents, youtube: youtube)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 344),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Kweku Settings"
        // The controller owns the lifetime, not AppKit: closing releases our
        // reference in `windowWillClose` and the next open builds a fresh one.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.delegate = self
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - Text field

/// `EditableTextField` in SwiftUI clothing.
///
/// SwiftUI's own `TextField` is not usable here. AppKit implements ⌘V as a
/// *menu* key equivalent, and an `LSUIElement` app has no menu bar to dispatch
/// it to — so paste silently does nothing. Every field in this window is a
/// credential or an URL you paste rather than type, which would make a plain
/// `TextField` worse than useless. `EditableTextField` already solves this for
/// the alerts; this wraps it rather than solving it twice.
struct EditableField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var secure = false
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = secure ? EditableSecureTextField() : EditableTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: EditableField
        init(_ parent: EditableField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        @objc func submit() { parent.onSubmit?() }
    }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject private var weather: WeatherHub
    @ObservedObject private var live: LiveSessionController
    @ObservedObject private var agents: AgentWatchHub
    @ObservedObject private var youtube: YouTubeHub
    /// Observed separately: the channel list and API key live on the store, and
    /// a change there does not republish through the hub.
    @ObservedObject private var store: YouTubeStore

    @State private var city = ""
    @State private var geminiKey = ""
    @State private var youtubeKey = ""
    @State private var newChannel = ""
    @State private var note = ""

    init(weather: WeatherHub, live: LiveSessionController,
         agents: AgentWatchHub, youtube: YouTubeHub) {
        _weather = ObservedObject(wrappedValue: weather)
        _live = ObservedObject(wrappedValue: live)
        _agents = ObservedObject(wrappedValue: agents)
        _youtube = ObservedObject(wrappedValue: youtube)
        _store = ObservedObject(wrappedValue: youtube.store)
    }

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            liveTab.tabItem { Label("Live", systemImage: "waveform") }
            youtubeTab.tabItem { Label("YouTube", systemImage: "play.rectangle") }
            agentsTab.tabItem { Label("Agents", systemImage: "cube") }
        }
        .frame(width: 470, height: 344)
        .padding(.top, 8)
    }

    // MARK: Tabs

    private var general: some View {
        pane {
            row("Weather city") {
                EditableField(text: $city, placeholder: weather.manualCityName ?? "e.g. Grand Rapids",
                              onSubmit: setCity)
                Button("Set", action: setCity).disabled(trimmed(city).isEmpty)
            }
            row("Licence key") {
                EditableField(text: .constant(""), placeholder: "Not activated")
                    .disabled(true)
            }
            hint(weather.manualCityName.map { "Weather is pinned to \($0)." }
                 ?? "Without a city, Kweku asks CoreLocation for one.")
        }
    }

    private var liveTab: some View {
        pane {
            row("Gemini API key") {
                EditableField(text: $geminiKey,
                              placeholder: LiveSessionController.apiKey == nil ? "AIza…" : "••••••••••••",
                              secure: true, onSubmit: saveGeminiKey)
                Button("Save", action: saveGeminiKey).disabled(trimmed(geminiKey).isEmpty)
            }
            row("Stored data") {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Forget Conversations") {
                        live.forgetConversations()
                        note = "Conversations forgotten"
                    }
                    Button("Forget Screen History") {
                        live.forgetScreenHistory()
                        note = "Screen history forgotten"
                    }
                }
            }
            hint("Used only for Kweku Live (voice + screen). Stored in app preferences.")
        }
    }

    private var youtubeTab: some View {
        pane {
            row("API key") {
                EditableField(text: $youtubeKey,
                              placeholder: store.apiKey == nil ? "AIza…" : "••••••••••••",
                              secure: true, onSubmit: saveYouTubeKey)
                Button("Save", action: saveYouTubeKey).disabled(trimmed(youtubeKey).isEmpty)
                if store.apiKey != nil {
                    Button("Remove") {
                        store.apiKey = nil
                        youtubeKey = ""
                        note = "YouTube API key removed"
                    }
                }
            }
            row("Channels") {
                VStack(alignment: .leading, spacing: 6) {
                    channelList
                    HStack(spacing: 6) {
                        EditableField(text: $newChannel, placeholder: "youtube.com/@handle",
                                      onSubmit: follow)
                        Button("Follow", action: follow)
                            .disabled(youtube.adding || trimmed(newChannel).isEmpty)
                    }
                }
            }
            // The check is a quiet switch, not a selection: everything listed is
            // followed, and unchecking silences one without forgetting it.
            hint("Checked channels open the notch when they upload. Unchecking keeps the channel and stops the notices.")
        }
    }

    private var channelList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if sortedChannels.isEmpty {
                    Text("Not following anything yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6).padding(.horizontal, 8)
                }
                ForEach(sortedChannels) { channel in
                    HStack(spacing: 6) {
                        Toggle(isOn: Binding(
                            get: { channel.notifies },
                            set: { youtube.setNotifies($0, for: channel.id) }
                        )) {
                            Text(channel.title).font(.system(size: 11.5)).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button {
                            youtube.remove(channel.id)
                            note = "Stopped following \(channel.title)"
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop following")
                    }
                    .padding(.vertical, 3).padding(.horizontal, 8)
                    Divider().opacity(0.4)
                }
            }
        }
        .frame(height: 108)
        .background(Color.black.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var agentsTab: some View {
        pane {
            row("Agent watch") {
                VStack(alignment: .leading, spacing: 5) {
                    Button("Set Up…") { agents.runSetup() }
                    Text(agents.setupDone ? "Configured" : "Not set up")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            row("Handoff") {
                VStack(alignment: .leading, spacing: 5) {
                    Button("Write Today's Handoff") {
                        agents.writeHandoffNow()
                        note = "Writing today's handoff…"
                    }
                    // Fires itself at six; this is the early ask and the retry
                    // when the gateway wasn't up for it.
                    Text("Runs automatically at 18:00.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Chrome

    private func pane<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
            Spacer(minLength: 0)
            if !note.isEmpty {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row<Content: View>(_ label: String,
                                    @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 105)
    }

    // MARK: Actions

    private var sortedChannels: [YouTubeChannel] {
        store.channels.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
    }

    private func setCity() {
        let name = trimmed(city)
        guard !name.isEmpty else { return }
        Task {
            // Name what was resolved rather than saying "done" — typing a city
            // and being told only that it worked leaves you unsure you got the
            // right one.
            if let resolved = await weather.setManualCity(name) {
                note = "Weather set to \(resolved)"
                city = ""
            } else {
                note = "Couldn't find that city"
            }
        }
    }

    private func saveGeminiKey() {
        let key = trimmed(geminiKey)
        guard !key.isEmpty else { return }
        LiveSessionController.storeAPIKey(key)
        geminiKey = ""
        note = "Gemini API key saved"
    }

    private func saveYouTubeKey() {
        let key = trimmed(youtubeKey)
        guard !key.isEmpty else { return }
        store.apiKey = key
        youtubeKey = ""
        note = "YouTube API key saved"
        Task { await youtube.poll() }
    }

    private func follow() {
        let input = trimmed(newChannel)
        guard !input.isEmpty else { return }
        Task {
            if let title = await youtube.addChannel(from: input) {
                note = "Following \(title)"
                newChannel = ""
            } else {
                note = youtube.lastError ?? "Couldn't follow that channel"
            }
        }
    }
}
