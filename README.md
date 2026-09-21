# Fringe

Hover the Mac notch; it expands into a panel of JavaScript widgets.

The panel sits over the cutout and stays out of the way until you point at
it. Widgets are `.js` files — drop one in and it shows up. Network and media
stay off until you allow them in Settings; bundled examples are pre-granted.
On a display without a notch it draws a stand-in in the same place, so it
behaves the same everywhere.

## Run it

Requires **macOS 14** or later and a **Swift 6** toolchain. The Command Line
Tools are enough; Xcode never needs to be opened.

```bash
make run
```

That compiles a release `.app`, ad-hoc signs it, and launches it. There is
no Dock icon — quit from the menu bar item. `make test`, `make install`,
and how the host is put together are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Now playing

There is no public macOS API that can *read* another app's now-playing
info. Fringe gets it from the private MediaRemote framework, running
inside `/usr/bin/perl` because that process is Apple-signed and the gate
is on the caller, not the code. The rest of the app does not depend on
that helper: if it is missing, or Apple tightens the gate, widgets still
run and the island just has nothing to claim. The perl-process trick is
[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)'s;
the helper in this tree is a smaller rewrite.

The adapter and why it is a child process, not a daemon, are in
[CONTRIBUTING.md](CONTRIBUTING.md#now-playing).

## Widgets

The panel is a grid of square cells, and widgets are JavaScript files in:

```
~/Library/Application Support/Fringe/Widgets/
```

The examples in `Examples/` are copied there on first run, and any one you
delete is restored individually — seeding is per file, so an example you have
edited is never overwritten. Scripts reload automatically about a second after
you save, so you can leave the panel open and edit. Host globals (`widget`,
`notch`, the builders) are typed in `Examples/notch-api.js` — it is not a
widget and is not copied into the scripts folder.

A widget registers itself and returns a tree of drawing primitives:

```js
widget({
  name: "Battery",
  span: [1, 1],        // columns × rows, never points
  refresh: 30,         // seconds; 0 is static — see cadence below
  permissions: { battery: true },
  render: function (ctx) {
    // ctx.columns / ctx.rows is the cell the user resized to,
    // not necessarily the declared span above.
    var power = notch.battery();
    return vstack([
      symbol(power.charging ? "bolt.fill" : "battery.100percent", { size: 15 }),
      text(Math.round(power.level * 100) + "%", { size: 17, weight: "medium" }),
      progress(power.level, { color: "#30d158" })
    ], { spacing: 5 });
  },
  // Optional. Claims the collapsed wings. Follows `refresh`,
  // plus an immediate rerun when MagSafe or hover actually changes.
  // Return null to leave the wings to someone else.
  island: function (ctx) {
    var power = notch.battery();
    if (!power || power.level > 0.2) return null;
    var percent = Math.round(power.level * 100);
    return {
      priority: 20,
      left: symbol("battery.25percent", { size: ctx.side * 0.9 }),
      right: text(percent + "%", { size: ctx.side * 0.62, monospaced: true })
    };
  }
});
```

### The execution budget

Scripts are user-authored and run on the main thread, so a `while (true)` in
any one of them would take the whole app down — panel, menu bar, media island.
JavaScript cannot be interrupted from the outside once it is running, so the
only real defence is a watchdog inside the engine.

Every entry into JavaScript is capped: **100ms for a render, 500ms for a
load**. Building a node tree costs well under a millisecond, so this is
generous by orders of magnitude, and a runaway script becomes a dropped frame
rather than a hang.

A render may overrun **three times** before the widget is stopped for good. One
strike is too strict — a render can lose its slice on a busy machine and come
back fine — while three is still bounded at 300ms total, and a genuine
runaway always spends all three. A successful render resets the count. A load
that overruns fails immediately, since there is no later attempt that could go
better.

A stopped widget shows why on its tile and in the settings list, and comes back
as soon as you save the file. Scripts that are merely slow are left alone, but
log a warning once, because they will stutter every animation on screen.

### Builders

| Builder | Notes |
| --- | --- |
| `text(value, opts)` | `size`, `weight`, `opacity`, `color`, `monospaced` |
| `symbol(name, opts)` | Any SF Symbol. `rendering`: `mono` (default), `hierarchical`, `palette`, `multicolor`. `palette` takes `color`, `secondary`, `tertiary`. |
| `progress(value, opts)` | 0–1, `color` |
| `artwork(opts)` | Current album art — see below |
| `spacer()` | |
| `vstack` / `hstack` / `zstack` | `spacing`, `alignment`; `zstack` layers front to back |
| `button(action, child)` | Named action. `"playPause"` / `"next"` / `"previous"` go to media, `"refresh"` busts that widget's fetch cache, anything else hits optional `onAction(name)` |
| `list(items)` | Rows of `{ title, subtitle?, symbol?, value? }` |
| `chart(values, opts)` | Sparkline (`kind: "line"`, default) or `kind: "bars"`. `fill`, `color`, `height` |
| `equaliser(opts)` | Now-playing bars. `playing`, `size` |

Colours are `#rrggbb`, `#rrggbbaa`, or a name like `"orange"`.

`artwork` asks the host for the current cover rather than carrying image bytes
across the bridge, so a blurred backdrop costs nothing per frame. It takes
`size` for a fixed square, `fill` to cover its container, `corner`, `opacity`
and `dim`. Prefer `dim` over `opacity` for backdrops — fading art towards black
drains it to grey, while dimming keeps the hue. The host only supplies artwork
to a widget that has been granted `media`.

### Host calls

`render` cannot wait. Every host call returns immediately, which is what keeps
the 100ms watchdog honest. The function is called with
`{ timestamp, span, columns, rows }` — `span` is `[columns, rows]` of the
cell the tile currently occupies, which follows user resizes rather than the
declared default.

| Call | Returns |
| --- | --- |
| `notch.now()` | Unix timestamp |
| `notch.battery()` | `{ level, charging, charged, ac, minutes? }` or `null` |
| `notch.media()` | Now-playing snapshot, or `null` |
| `notch.fetch(url, { ttl })` | `{ pending: true }`, `{ ok, json, code }`, or `{ ok: false, error }` |
| `notch.store(key, value)` / `notch.load(key)` | JSON persisted per widget, survives reloads |
| `notch.read(name)` / `notch.write(name, text)` | Files in that widget's data folder only |
| `notch.setting(key)` | A user-facing setting, or the script's default |
| `console.log(msg)` | Console.app, `me.hwll.fringe` |

`notch.fetch` is https-only, public-internet-only (no loopback, LAN,
`*.local`, or IPv6 embeddings of those), capped at 512KB, and cached. The
connected peer is checked after DNS as well as before, so a name cannot
rebind to the LAN between the two lookups. A script that needs
a network body asks for it and renders a loading state until the cache fills;
the widget is asked to render again when the response lands. `ttl` is seconds
(default 300, max 86400). Stale entries are returned while a refresh is in
flight.

A widget declares `permissions` for what it may touch. **Network and local
secrets cannot share a file** — that is what stops a gist from reading
now-playing and posting it out. Isolated contexts already stop two widgets
from merging afterwards. Declaration is not authorisation: a dropped gist
that asks for `network` or `media` is inert until you flip the matching
toggle in Settings. Bundled examples are pre-granted so first launch still
works. Replacing a script with another of the same filename that asks for a
different capability set wipes that widget's data folder, so a network gist
cannot inherit a media widget's store.

| Permission | Host |
| --- | --- |
| `network` | `notch.fetch` |
| `media` | `notch.media`, play/pause |
| `battery` | `notch.battery` |

Omit the field for none of them. Declaring `network` together with `media`
or `battery` is a load error. Clock and Hello declare nothing.

`notch.read` / `notch.write` take a filename, not a path. A slash or `..` is
refused. The files live under `~/Library/Application Support/Fringe/WidgetData/`.

`notch.media()` returns `null` when nothing is playing, otherwise `title`,
`artist`, `album`, `isPlaying`, `duration`, `elapsed`, `progress` and
`hasArtwork`. Elapsed and progress are interpolated host-side, so a script
polling once a second still gets a scrubber that advances smoothly.

`notch.battery()` is `null` on a desktop. Otherwise `level` is 0–1,
`charging` / `charged` / `ac` are booleans, and `minutes` is time to full
while charging or to empty on battery — omitted while IOKit is still
estimating.

### Collapsed wings

`render()` draws a board tile. `island(ctx)` claims the two wings that grow
out of the hardware notch while the panel is collapsed. It is the one
script entry that still runs when the board is asleep, and only scripts
that define it are entered — a static tile like `hello.js` does no work
at all while the panel is shut.

### Update cadence

`refresh` is the one knob. The collapsed island uses the same interval
rather than poking every script once a second:

| `refresh` | Board (panel open) | Island (panel collapsed) |
| --- | --- | --- |
| `0` | Render once | Host events only (MagSafe, hover, media, occupancy) |
| `5`+ | Every *n* seconds | Same interval, plus those host events |
| `1` | Every second | Every second, plus host events |

`nowplaying.js` is live because a track can change while you are not looking.
`battery.js` is slower because a percent barely moves. Omit `island` and the
widget sleeps whenever the panel is closed, which is why `hello.js` can be
`refresh: 0` and cost nothing on the tick.

Host events (MagSafe, hover, a track starting or stopping) still rerun
`island()` immediately, so a live widget does not wait out its interval
just to show a pause glyph.

Return `null` (or omit the function) to stay off the island. Otherwise:

```js
{
  priority: 50,            // highest enabled claim wins
  left: artwork({ corner: 6 }),
  right: equaliser({ playing: true, size: ctx.side }),
  action: "playPause"      // optional; right-wing click while peeked
}
```

`ctx` is `{ timestamp, pulse, hover, side, wing }`. `pulse` is true for a
few seconds after MagSafe goes on or off. `side` is the content square in
each wing, `wing` the full wing width. `nowplaying.js` and `battery.js` are
the worked examples; disable either in Settings and it stops claiming.

The host still posts "Battery Low" / "Battery Critical". Scripts cannot.

### Settings a user can edit

A widget declares fields next to its name. The Widgets pane draws a control
for each one, and `notch.setting` reads the current value:

```js
widget({
  name: "Weather",
  settings: {
    city: { type: "string", default: "Sydney", label: "City" },
    units: { type: "choice", options: ["C", "F"], default: "C", label: "Units" }
  },
  render: function () {
    var city = notch.setting("city");
    // ...
  }
});
```

`type` is `string`, `number`, `boolean`, or `choice`.

## License

[MIT](LICENSE).