# Contributing

Widget authors: [README.md](README.md). This file is how to build the host.

## Requirements

- macOS 14+
- Swift 6 (`swift --version`). Command Line Tools are enough.

## Build

```bash
make run      # release, bundle, relaunch
make debug    # unoptimised
make test
make lint
make install  # copy to /Applications
make stop
make clean
```

The bundle lands in `build/Fringe.app`. No Dock icon — quit from the menu bar.

Always go through `make`. `swift build` alone produces a bare executable that
will misbehave as a GUI app. `Scripts/build-app.sh` compiles, lays out the
bundle, and ad-hoc signs it. Set `UNIVERSAL=1` for arm64 + x86_64.

## Layout

```
Adapter/          MediaRemote dylib + Perl helper
Bundle/           Info.plist (LSUIElement lives here)
Examples/         bundled widgets (`notch-api.js` is typings, not seeded)
Scripts/          compile + assemble + sign
Sources/Fringe/
  App/            lifecycle, menu bar, settings window
  Model/          settings, grid, panel geometry
  Window/         NSPanel, placement, pointer tracking
  Views/          SwiftUI
  Scripting/      JS host, sandbox, battery
  Media/          now-playing session + Perl client
Tests/
```

## Notes

**The window never resizes.** It is created at the expanded size. Expand /
collapse interpolates the notch path inside that window. Animating an
`NSWindow` frame stutters; animating a SwiftUI frame peels the notch off the
top of the screen.

**Content is always laid out expanded** and clipped by the silhouette.

**Hover is global**, not tracking areas. A non-activating panel above the
menu bar does not get reliable enter/exit events.

**One `JSContext` per script.** JavaScriptCore's execution time limit is
resolved at runtime; if the symbol is missing, scripts do not run at all.
JIT is off.

**Now playing** has no public read API. The private MediaRemote framework
is gated to Apple-signed processes, so a small dylib runs inside
`/usr/bin/perl` and streams JSON on stdout. The helper is a child, not a
daemon, and exits if its parent dies. Trick from
[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter);
the code here is a smaller rewrite. If the adapter is missing, widgets still
run — the island just has nothing to claim.

Settings has a **Debug** pane with the resolved geometry and a dump of the
preferences domain (including keys this build does not write).
