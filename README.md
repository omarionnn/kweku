# Kweku

**Omari's personal notch companion.** This is the little tool I keep running all
day on my MacBook while I build things — not a product, not something I support,
just my daily driver. It's tuned to my machine, my keybindings and my workflow,
and it will have sharp edges for anyone else. I'm putting it on GitHub because
it's mine and I like having it here, not because it's meant to be installed by
the world.

It turns the MacBook notch into a live companion: a small creature lives in the
cutout and reacts to what my machine — and the AI coding agents I run — are
doing. Scroll over the notch to cycle what it shows.

<!-- A screenshot/gif of the notch in action lives well here. -->

---

## What it does

A menu-bar (`LSUIElement`) app — no Dock icon, no window, it just lives in the
notch.

- **The creature.** A face in the nook that's genuinely reactive: eyes track the
  cursor, it leans into a sideways drag, narrows its eyes while a tool runs, wears
  an ember while an agent is working, drifts violet motes while one is thinking,
  turns its eyes into exclamation marks when an agent is *waiting on me*, puts on
  shades when the camera turns on, and lip-syncs during a voice session. It also
  reads charging and caps-lock off the system.

- **Spotify, Dynamic-Island style.** When music is playing the notch grows into an
  island — album art on the left, the creature riding in the right wing, so I get
  **music and the critter at once**. Hovering opens a full card: art, scrolling
  title, scrubber and transport, all tinted with an accent pulled off the cover.
  Open it while agents are running and the agent panel stacks underneath —
  **music and agents in one glance.**

- **Agent watch.** A socket server tracks the coding-agent sessions I have going
  (omp / OpenClaw / Claude), surfaces them in a hover panel with a per-session
  identity line, flips the creature to "waiting" eyes when one needs me, and
  click-to-focus jumps me to the right terminal. A "pit crew" reports what a
  finished agent actually changed.

- **Live session.** A voice + screen-vision companion (Gemini Live) — mic, speaker,
  a stream of the focused window, and tool dispatch into a coding-agent gateway.
  `⌥⌘K` starts and stops it from anywhere. Captions hang under the notch.

- **Command line.** Type at Kweku instead of talking to it: a prompt line in the
  notch, a send, and a "fix what's on screen" that reads the foreground window and
  hands the failure straight to a coding agent.

- **Shelf.** Drag files onto the notch to stash them; drag them back out later.
  Persists across launches.

- **Weather & stats.** Two more nook modes — local weather (Open-Meteo +
  CoreLocation, manual-city fallback) and a system-stats panel.

Modes cycle by scrolling over the notch. On a Mac without a physical notch it
draws a synthetic pill under the menu bar instead.

## Build & run

macOS 13+, Xcode command-line tools. No third-party dependencies — pure SwiftUI
and a self-contained logic library.

```sh
make app     # build the library and install it where the host looks
make run     # build + restart the app so new code is actually loaded
make test    # pure-logic tests (they run as a plain executable, not XCTest)
```

The bundle is a **frozen host** that `dlopen`s `KwekuKit.dylib` from
`~/Library/Application Support/Kweku/lib/`. The churning code lives *outside* the
signed bundle on purpose: because Kweku is ad-hoc signed, macOS keys my Screen
Recording / Microphone / Accessibility grants to the bundle's hash, so any change
inside the seal would forget every permission. Rebuilding only the dylib
(`make app`) leaves the hash — and every grant — untouched. Editing `main.swift`,
`Info.plist` or the entitlements needs `make host`, which re-freezes the bundle
and costs one round of re-granting permissions. See the header of
`Sources/Kweku/main.swift` for the full story.

## Layout

- `Sources/Kweku/` — the inert frozen host; finds the dylib and jumps in.
- `Sources/KwekuKit/` — everything that actually does the work, one directory per
  concern: `Creature/`, `Music/`, `AgentWatch/`, `Live/`, `Command/`, `Shelf/`,
  `Weather/`, `Sensors/`, `NotchWindow/`, `App/`.
- `Tests/KwekuTests/` — pure-logic checks (geometry, playback clock, palette,
  gateway protocol, …) run via `swift run KwekuTests`. Layout is deliberately not
  unit-tested; it's eyeballed on the actual notch.

## Status

Personal tool. It changes when I want it to, breaks when I'm mid-experiment, and
comes with no promises. If you found this: hi — it's mine, and it's exactly the
notch I want to look at all day.
