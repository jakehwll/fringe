# Contributing

Fringe is a macOS notch app built with nothing but Swift Package Manager. No `.xcodeproj`,
no `xcodeproj` generation, no `xcodebuild` — `swift build` compiles the binary and
a shell script lays out the `.app` bundle around it.

The panel sits over the notch, stays invisible until you point at it, then
expands into a floating dark panel. On displays without a physical cutout it
draws a stand-in notch in the same place, so it behaves identically everywhere.

Widget authors should start with [README.md](README.md). This file is for
building, architecture, and the bits of the host that are not the scripting API.

## Requirements

- macOS 14 or later
- A Swift 6 toolchain (`swift --version`). The Command Line Tools are enough —
  Xcode never needs to be opened.

## Build and run

```bash
make run      # release build, bundle, relaunch
make debug    # unoptimised build, same bundle layout
make test     # run the test suite
make install  # copy to /Applications
make stop     # kill the running instance
make clean
```

The bundle lands in `build/Fringe.app`. It runs as an accessory app (no Dock
icon), so quitting happens from its menu bar item.

`swift build` alone produces a bare executable that will misbehave as a GUI app —
always go through `make`, which is what creates `Info.plist` and signs the bundle.

## How the Xcode-free bundling works

`Scripts/build-app.sh` does the three things Xcode would otherwise do for you:

1. `swift build` to produce the executable.
2. Assemble the bundle layout — `Contents/MacOS/Fringe`, `Contents/Info.plist`
   (copied from `Bundle/Info.plist`), `Contents/PkgInfo`.
3. `codesign --sign -` for an ad-hoc signature, which macOS wants before it will
   let the app register a menu bar item and keep window state.

`LSUIElement` in the plist is what suppresses the Dock icon. Set `UNIVERSAL=1` to
get an arm64 + x86_64 binary.

## Layout

```
Bundle/Info.plist              bundle metadata (LSUIElement lives here)
Adapter/                       MediaRemote dylib + Perl helper
Examples/                      bundled widget scripts, seeded on first launch
                               (`notch-api.js` is editor typings, not seeded)
Scripts/build-app.sh           compile + assemble + sign
Sources/Fringe/
  App/                         process lifecycle and menu bar item
  Model/                       configuration, screen measurements, panel state
  Window/                      the NSPanel, its placement, pointer tracking
  Views/                       SwiftUI
  Scripting/                   JS host, widget sandbox, battery
  Media/                       now-playing session and the Perl client
Tests/                         geometry, settings, and the script host
```

`Bundle/` is deliberately not called `Resources/` — nothing in it is a SwiftPM
resource; it is the scaffolding for the `.app` that the build script assembles.

## Geometry, tests and the debug pane

Nearly every visual bug in this app has been a geometry bug: a widget packed
into the wrong cell, a drag landing a row out, a panel a few points too wide.
That maths is all pure functions, so it is tested — `make test` runs in
well under a second and needs no display.

The pieces worth knowing about:

- **`Model/NotchGrid.swift`** — cell measurement, the two-pass packer, and
  the drop/resize snap. Hit-testing a point *truncates* into a cell (a gutter
  still belongs to the tile on its left); dropping a dragged tile *rounds* at
  half a stride, so a tile that has crossed the midpoint of a gutter commits
  to the next cell. Those used to be two copies of the arithmetic in the
  window controller. Widgets the user positioned claim their cell first;
  everything else fills what is left. Without that split a layout can only
  fill from the top-left, which is what would make dragging a widget
  rightwards impossible.
- **`Model/PanelGeometry.swift`** — the single place that knows the panel is
  centred on the screen's midpoint and hung from its top edge, and the only
  place that converts between **screen** coordinates (origin bottom-left, y
  up) and **board** coordinates (origin top-left of the first cell, y down).
  It holds no AppKit types, so it can be tested without a display. It carries
  a `screenPoint(from:)` that nothing calls, purely so the conversion can be
  round-tripped in a test — a transform only ever applied one way is one
  nobody can check.

### The debug pane

Settings has a **Debug** tab showing a `GeometryReport`: screen frame, measured
notch, board size and origin, panel and window rects, and where every widget
landed — including whether it is there because the user pinned it or because
packing put it there. "Copy Diagnostics" dumps the same value as text. The
report is a plain struct, so the tests assert the same numbers the pane shows.

It also lists the raw contents of the preferences domain and flags **any key
this build does not write**. That is not a general nicety, it is a specific
scar: a `simulateNotch` preference was dropped from the UI but stayed in
`UserDefaults`, where it quietly kept replacing the measured cutout with a
hardcoded guess. Every number on screen looked plausible, nothing could be
inspected, and it cost an afternoon of tuning against a value that was not
what it appeared to be.

| File | Role |
| --- | --- |
| `App/FringeApplication.swift` | `@main` entry point; sets accessory activation policy. |
| `App/AppDelegate.swift` | Wires the state, controllers and menu bar item together. |
| `App/StatusItemController.swift` | Menu bar item — the only way to quit a Dock-less app. |
| `App/SettingsWindowController.swift` | Hosts the settings window and its keyboard shortcuts. |
| `Model/NotchSettings.swift` | Preferences (persisted) and fixed layout constants. |
| `Model/NotchGrid.swift` | Cell geometry, widget spans, packing, drop-snap, resize. |
| `Model/PanelGeometry.swift` | Screen ↔ board coordinates; panel placement on a display. |
| `Model/GeometryReport.swift` | The resolved-geometry snapshot the Debug pane renders. |
| `Model/NotchMetrics.swift` | Measures the real notch, or falls back to a simulated one. |
| `Model/NotchState.swift` | Observable collapsed / expanded / pinned state. |
| `Window/NotchPanel.swift` | The borderless `NSPanel` that floats above the menu bar. |
| `Window/NotchWindowController.swift` | Placement, screen changes, and the hover state machine. |
| `Window/MouseTracker.swift` | Global pointer position without any permission prompts. |
| `Views/NotchShape.swift` | The notch silhouette, including the concave top corners. |
| `Views/NotchRootView.swift` | Animates the silhouette between collapsed and expanded. |
| `Views/WidgetGrid.swift` | The grid `Layout`, the `widgetSpan` modifier, tile chrome. |
| `Views/WidgetNodeView.swift` | Draws the tree a script returned. |
| `Views/NotchContentView.swift` | Header band and the widget board. |
| `Views/CompactIslandView.swift` | Collapsed wings, plus the equaliser primitive. |
| `Scripting/IslandClaim.swift` | What `island()` returned, and who won. |
| `Scripting/BatteryMonitor.swift` | MagSafe pulse + low-battery notifications. |
| `Media/NowPlayingController.swift` | Live now-playing session. |
| `Media/MediaRemoteAdapterClient.swift` | Perl helper that actually reads MediaRemote. |
| `Views/SettingsView.swift` | Preference panes (General, Grid, Widgets, Debug). |
| `Model/SettingsPane.swift` | Toolbar tabs and per-pane window size. |
| `Scripting/ScriptRuntime.swift` | One `JSContext` per script: prelude, host API, render. |
| `Scripting/ScriptedWidget.swift` | A loaded `.js` file and its current render tree. |
| `Scripting/ScriptLibrary.swift` | The scripts folder, hot reload, refresh ticker. |
| `Scripting/WidgetNode.swift` | The drawing primitives scripts return. |
| `Scripting/ExampleScripts.swift` | Inventory of bundled examples; the JS is in `Examples/`. |
| `Scripting/PowerSource.swift` | Battery reading behind `notch.battery()`. |

## Now Playing

The player is a widget script like any other — `nowplaying.js`, 3×2 cells by
default, draggable and resizable alongside the rest (including down to 1 row).
There is no native player view and no special case in the board; it earns its
place through the same scripting API everything else uses.

That was a deliberate correction. Keeping it in Swift meant every board feature
came with "except the player": not reorderable, not resizable, absent from the
widget list, hoisted ahead of everything in each layout pass. Extending the API
until the player could be expressed in it was the better trade.

While a track is playing or paused, `nowplaying.js` claims the collapsed
wings: art on the left of the cutout, an equaliser on the right. Hovering
turns the equaliser into play/pause; pause itself shows the play glyph so
the session is still a tap away. `battery.js` claims them instead when
the pack is going flat (≤20% unplugged), or for a few seconds when MagSafe
goes on or off — critical (≤10%) outranks a playing track. Returning `null`
from `island()` is how a widget yields. Notifications at 20% and 10% stay
host-side: a script cannot post a system alert, and MagSafe flipping is
something IOKit sees before any widget does.

### Where the data comes from

There is no public macOS API that can *read* another app's now-playing info —
`MPNowPlayingInfoCenter` is write-only from the playing app. The private
MediaRemote framework behind Control Centre can, and it sees *everything*:
browsers, Podcasts, IINA, anything that registers a session. But recent macOS
gates its metadata call to Apple-signed callers, so calling it directly from
this app returns nothing at all.

The gate is on the calling *process*, not on the code, and `/usr/bin/perl` is
Apple-signed. So the MediaRemote work happens in a small dylib that Perl loads
and runs on our behalf, streaming results back as one JSON object per line.
That trick is [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)'s;
[boring.notch](https://github.com/TheBoredTeam/boring.notch) vendors the binary.
The adapter here is a smaller rewrite, not that framework.

- `Adapter/MediaRemoteAdapter.m` — the dylib. Exports `adapter_get`,
  `adapter_stream`, `adapter_send` and `adapter_test`.
- `Adapter/mediaremote-adapter.pl` — loads it with `DynaLoader` and installs
  the requested symbol as an XSUB.
- `Media/MediaRemoteAdapterClient.swift` — runs the helper and parses stdout.

Perl calls an XSUB with `(interpreter, cv)` and expects it to work the Perl
stack for arguments. The adapter sidesteps that entirely by taking its
parameters from environment variables, which is why it needs no Perl headers
and no XS glue. Artwork is ~100KB of base64, so each payload carries a
fingerprint and the bytes ride along only when that fingerprint changes.

The helper is a child process, not a daemon. It watches for its parent to be
reparented to launchd and exits, so killing the app — even with a signal, which
never runs `applicationWillTerminate` — cannot leave one behind. There is no
Apple Events fallback: if the adapter is missing from the bundle, there is no
now-playing. The client refuses to launch perl unless the script and dylib
resolve inside this `.app` (no symlinks) and the dylib still has a code
signature, so a swapped helper is not loaded into an Apple-signed process.

JavaScriptCore JIT is switched off before the first `JSContext` is created.
Widget scripts build a small node tree; they do not need a JIT, and an
unsandboxed process should not give untrusted JavaScript one.

## Settings

Open them from the gear in the panel's header or from the menu bar item (⌘,).
Four panes: **General** (the measured notch, restore defaults), **Grid**
(columns and rows), **Widgets** (enable, reorder, per-script fields), and
**Debug**. The panel pins itself open while the window is up so every
change previews live. Values persist to `UserDefaults`.

There is no simulated-notch toggle. A display without a cutout gets a
stand-in automatically. `simulateNotch` used to be a preference; it was
dropped from the UI and is now cleared on launch — that is the scar the
Debug pane exists to catch.

`NotchSettings` also holds the layout constants that are *not* exposed — cell
size, flare radius, corner radii, hover delays, content insets, window margins.
They sit alongside the preferences so there is one place to look, and are only
tuned in code.

## Design notes

Worth knowing before you extend it:

**Nothing resizes — only a path animates.** The window is created once at the
full expanded size plus shadow margin and pinned to the top centre of the
display. Inside it, the notch is a path drawn in a canvas that fills the whole
window, and the expand / collapse animation interpolates that path. Animating an
`NSWindow` frame stutters against the window server, and animating a SwiftUI view
frame lets SwiftUI interpolate the origin as well as the size — with a springy
curve the two disagree and the notch visibly peels away from the top of the
screen. Driving the path keeps the top edge at `rect.minY` on every frame.

**The content is always laid out at its expanded size** and clipped by the
silhouette. Sizing it with the body would reflow text on every frame.

**Clicks fall through while collapsed.** Since the window is mostly empty space,
`ignoresMouseEvents` is on until the panel expands.

**Hover is detected globally, not with tracking areas.** A non-activating panel
sitting above the menu bar does not get reliable enter/exit events, so
`MouseTracker` watches the pointer with event monitors plus a slow timer that
reconciles missed transitions. Mouse monitoring needs no accessibility
permission — only keyboard monitoring does.

**Measuring the real notch** uses `NSScreen.auxiliaryTopLeftArea` and
`auxiliaryTopRightArea`: the cutout is the gap between them, and it is as tall as
`safeAreaInsets.top`.

**The settings window needs help that a normal app gets for free.** An accessory
app has no menu bar, so `SettingsWindowController` activates the app explicitly
before showing the window and synthesises ⌘W and Escape with a local key monitor.

**Scripts get a context each.** Separate `JSContext`s stop one script from
clobbering another's globals. A single one-second timer compares file
modification dates to catch edits — editors save in different ways, and
polling dates is more reliable than filesystem events — and asks widgets
that opted into a `refresh` interval to run again. Board `render()` is
skipped while the panel is collapsed. `island()` is skipped for any
script that never defined it, and otherwise follows that same interval
instead of a global one-second poke; MagSafe, hover, and occupancy
changes force an immediate rerun. Scripts run synchronously on the main
thread, so an infinite loop in one will hang the UI.

This leans on `JSContextGroupSetExecutionTimeLimit`, which JavaScriptCore
exports but only declares in a private header, so the symbol is resolved at
runtime. If it is ever missing the app refuses to run scripts at all rather
than running them unguarded — a scripting host with no way to stop a script is
worse than one with no scripts.
