# Kweku

**Kweku is my coding colleague.** It lives in the MacBook notch and works
alongside me all day — watching the agents I have running, telling me when one
needs a decision, reading what's on my screen and handing a broken build straight
to a coding agent, keeping my music and my sessions a glance away. It started as a
face in the notch and turned into the teammate I actually reach for while I build.

I'm keeping it on GitHub to track how it grows and to share what I use every day.

<!-- A screenshot/gif of the notch in action lives well here. -->

---

## How I use it, day to day

- I usually have a few coding agents going. Kweku watches them for me: when one
  finishes it tells me what it actually changed, and when one is stuck waiting on
  my call, its eyes turn into exclamation marks so I notice without babysitting a
  terminal. A click jumps me straight to the session that wants me.
- When something breaks on screen, I don't retype the error — I hit the command
  line in the notch and "fix what's on screen," and Kweku reads the foreground
  window and hands the failure to an agent.
- When I want to think out loud, `⌥⌘K` starts a voice + screen-vision session, so
  I can talk through a problem and have it act on what I'm looking at.
- Music runs all day, so Spotify sits in the notch as a Dynamic-Island — album
  art, scrubber, transport — and the little creature rides along next to it. Open
  it while agents are running and the agent panel stacks right under the music.
- Files I want to hold onto go on the shelf by dragging them at the notch; weather
  and system stats are a scroll away when I want them.

## Kweku itself

A menu-bar (`LSUIElement`) app — no Dock icon, no window, it just lives in the
notch. Scroll over the notch to cycle what it shows.

- **The face.** Genuinely reactive: eyes track the cursor, it leans into a
  sideways drag, narrows its eyes while a tool runs, wears an ember while an agent
  works, drifts violet motes while one is thinking, throws up exclamation eyes when
  an agent is waiting on me, puts on shades when the camera turns on, and lip-syncs
  during a voice session. It also reads charging and caps-lock off the system.

- **Agent watch.** A socket server tracks my running sessions (omp / OpenClaw /
  Claude) with a per-session identity line, flips the face to "waiting" when one
  needs me, and a "pit crew" reports what each finished agent changed.

- **Spotify island.** Album art on the left, the creature in the right wing —
  music and the critter at once. Hovering opens a full card tinted with an accent
  pulled off the cover; open while agents run and the agent panel stacks below.

- **Live session.** Voice + focused-window vision (Gemini Live) with tool dispatch
  into a coding-agent gateway. `⌥⌘K` toggles it from anywhere; captions hang under
  the notch.

- **Command line.** Type at Kweku instead of talking to it. It isn't a mode you
  can scroll to and get stuck in — it's summoned, and the notch goes back to
  whatever it was showing when you're done. Hovering the critter (or the music
  island) hangs a one-line `ask Kweku` prompt under the notch; `⌥Space` from any
  app skips that and grows the full panel out of the cutout with the caret
  already blinking — the critter slides into the right wing as it opens. Escape,
  or a click anywhere else, hands the keyboard and the front app back. Chips
  above the field name
  what it's looking at, whether the screen is riding along, and where ⏎ goes;
  `↑` recalls, a ghost completion finishes the command you ran before, and a
  pasted stack trace grows the field instead of scrolling sideways. An answer
  comes with verbs — copy, run again, hand it to the agent in the repo, open
  the session it became — and a typed command shows up in the agent panel like
  any other session. "Fix what's on screen" still reads the foreground window
  and hands the failure to a coding agent.

- **Shelf, weather, stats.** Drag files onto the notch to stash and retrieve them;
  local weather (Open-Meteo + CoreLocation) and a system-stats panel are two more
  scroll-to modes.

On a Mac without a physical notch it draws a synthetic pill under the menu bar.

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
and re-asks for permissions once. The header of `Sources/Kweku/main.swift` tells
the whole story.

## Layout

- `Sources/Kweku/` — the inert frozen host; finds the dylib and jumps in.
- `Sources/KwekuKit/` — everything that does the work, one directory per concern:
  `Creature/`, `Music/`, `AgentWatch/`, `Live/`, `Command/`, `Shelf/`, `Weather/`,
  `Sensors/`, `NotchWindow/`, `App/`.
- `Tests/KwekuTests/` — pure-logic checks (geometry, playback clock, palette,
  gateway protocol, …) run via `swift run KwekuTests`. Layout is eyeballed on the
  real notch rather than unit-tested.
