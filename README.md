# Fringe

Hover the Mac notch; it expands into a panel of JavaScript widgets.

Drop a `.js` file in and it shows up. Network and media stay off until you
allow them in Settings. On a display without a notch it draws a stand-in, so
it behaves the same everywhere.

## Run

macOS 14+, Swift 6. The Command Line Tools are enough.

```bash
make run
```

No Dock icon — quit from the menu bar. Tests, install, and how the host is
put together: [CONTRIBUTING.md](CONTRIBUTING.md).

## Widgets

Scripts live in `~/Library/Application Support/Fringe/Widgets/`. Examples from
`Examples/` are copied on first run; an edited file is never overwritten. Save
and it reloads in about a second.

`Examples/notch-api.js` is editor typings, not a widget. Copy `hello.js` to
start; `battery.js`, `nowplaying.js`, and `weather.js` cover the rest.

```js
widget({
  name: "Battery",
  span: [1, 1],
  refresh: 30,
  permissions: { battery: true },
  render: function (ctx) {
    var power = notch.battery();
    return vstack([
      symbol(power.charging ? "bolt.fill" : "battery.100percent", { size: 15 }),
      text(Math.round(power.level * 100) + "%", { size: 17, weight: "medium" }),
      progress(power.level, { color: "#30d158" })
    ], { spacing: 5 });
  },
  island: function (ctx) {
    var power = notch.battery();
    if (!power || power.level > 0.2) return null;
    return {
      priority: 20,
      left: symbol("battery.25percent", { size: ctx.side * 0.9 }),
      right: text(Math.round(power.level * 100) + "%", {
        size: ctx.side * 0.62,
        monospaced: true
      })
    };
  }
});
```

`render` draws the tile. `island` claims the collapsed wings; return `null`
to yield. Omit it and the widget sleeps while the panel is closed.

`refresh` is seconds between renders (`0` is static). The island uses the
same interval. MagSafe, hover, and media changes rerun `island` immediately.

`ctx` in `render` is `{ timestamp, span, columns, rows }` — the cell the
user resized to, not the declared default. In `island` it is
`{ timestamp, pulse, hover, side, wing }`.

A render that takes more than 100ms (or a load more than 500ms) is stopped.
Three overruns kill the widget until you save the file.

### Builders

| Builder | |
| --- | --- |
| `text(value, opts)` | `size`, `weight`, `opacity`, `color`, `monospaced` |
| `symbol(name, opts)` | SF Symbol. `rendering`: `mono`, `hierarchical`, `palette`, `multicolor` |
| `progress(value, opts)` | 0–1, `color` |
| `artwork(opts)` | Current cover. Needs `media`. Prefer `dim` over `opacity` for backdrops |
| `spacer()` | |
| `vstack` / `hstack` / `zstack` | `spacing`, `alignment` |
| `button(action, child)` | `"playPause"` / `"next"` / `"previous"` / `"refresh"`, or `onAction(name)` |
| `list(items)` | `{ title, subtitle?, symbol?, value? }` |
| `chart(values, opts)` | `kind: "line"` or `"bars"` |
| `equaliser(opts)` | Now-playing bars. `playing`, `size` |

Colours are `#rrggbb`, `#rrggbbaa`, or a name like `"orange"`.

### Host

Every call returns immediately.

| Call | |
| --- | --- |
| `notch.now()` | Unix timestamp |
| `notch.battery()` | `{ level, charging, charged, ac, minutes? }` or `null` |
| `notch.media()` | Now-playing snapshot, or `null` |
| `notch.fetch(url, { ttl })` | `{ pending: true }`, then `{ ok, json, code }` |
| `notch.store(key, value)` / `notch.load(key)` | JSON, per widget |
| `notch.read(name)` / `notch.write(name, text)` | Filename only, that widget's data folder |
| `notch.setting(key)` | A user-facing setting, or the script's default |
| `console.log(msg)` | Console.app, `me.hwll.fringe` |

`notch.fetch` is https, public internet, cached (default ttl 300s). Render a
loading state until the cache fills.

Permissions are declared on the widget and granted in Settings. Bundled
examples are pre-granted. **Network cannot share a file with media or
battery.**

| Permission | Unlocks |
| --- | --- |
| `network` | `notch.fetch` |
| `media` | `notch.media`, playback, artwork |
| `battery` | `notch.battery` |

User-facing settings:

```js
settings: {
  city: { type: "string", default: "Sydney", label: "City" },
  units: { type: "choice", options: ["C", "F"], default: "C", label: "Units" }
}
```

`type` is `string`, `number`, `boolean`, or `choice`.

## License

[MIT](LICENSE).
