/**
 * Fringe widget API — editor typings for globals the host injects.
 *
 * Not a widget. Skipped by the bundle copy and never seeded; JavaScriptCore
 * never evaluates this file. Open any example beside it and `widget`, `notch`,
 * and the builders complete.
 */

// ---------------------------------------------------------------------------
// Contexts
// ---------------------------------------------------------------------------

/**
 * Cell the board actually gave this tile. Follows user resizes, not the
 * declared default.
 * @typedef {[number, number] | { columns: number, rows: number }} Span
 */

/**
 * @typedef {object} RenderContext
 * @property {number} timestamp Unix seconds
 * @property {Span} span
 * @property {number} columns
 * @property {number} rows
 */

/**
 * Host facts `island()` cannot observe itself.
 * @typedef {object} IslandContext
 * @property {number} timestamp Unix seconds
 * @property {boolean} pulse True for a few seconds after MagSafe goes on or off
 * @property {boolean} hover Pointer is over the collapsed island
 * @property {number} side Content square in each wing, in points
 * @property {number} wing Full wing width, in points
 */

/**
 * @typedef {object} IslandClaim
 * @property {number} [priority] Highest enabled claim wins
 * @property {WidgetNode} left
 * @property {WidgetNode} right
 * @property {string} [action] Right-wing click while peeked (`"playPause"`, …)
 */

// ---------------------------------------------------------------------------
// Host
// ---------------------------------------------------------------------------

/**
 * @typedef {object} BatterySnapshot
 * @property {number} level 0–1
 * @property {boolean} charging
 * @property {boolean} charged
 * @property {boolean} ac
 * @property {number} [minutes] Time to full while charging, or to empty on battery
 */

/**
 * @typedef {object} MediaSnapshot
 * @property {string} title
 * @property {string} artist
 * @property {string} album
 * @property {boolean} isPlaying
 * @property {number} duration
 * @property {number} elapsed Interpolated host-side between polls
 * @property {number} progress 0–1, also interpolated
 * @property {boolean} hasArtwork
 */

/**
 * `notch.fetch` never waits. `{ pending: true }` until the body lands, then
 * the widget is asked to render again.
 * @typedef {object} FetchResult
 * @property {boolean} [pending]
 * @property {boolean} [ok]
 * @property {*} [json]
 * @property {string} [text]
 * @property {number} [code]
 * @property {string} [error]
 */

/**
 * @typedef {object} FetchOptions
 * @property {number} [ttl] Cache lifetime in seconds. Default 300.
 */

/**
 * @typedef {object} NotchHost
 * @property {() => number} now Unix timestamp
 * @property {() => (BatterySnapshot | null)} battery `null` on a desktop
 * @property {() => (MediaSnapshot | null)} media `null` when nothing is playing
 * @property {(url: string, options?: FetchOptions) => FetchResult} fetch public https only, ≤512KB
 * @property {(key: string, value: *) => void} store JSON persisted per widget
 * @property {(key: string) => *} load
 * @property {(name: string) => (string | null)} read File in this widget's data folder
 * @property {(name: string, text: string) => (string | null)} write Filename only; `/` and `..` refused
 * @property {(key: string) => *} setting User-facing value, or the script's default
 */

/**
 * @type {NotchHost}
 */
var notch;

/**
 * @typedef {object} ConsoleHost
 * @property {(message: string) => void} log Console.app, `me.hwll.fringe`
 */

/**
 * @type {ConsoleHost}
 */
var console;

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------

/**
 * @typedef {"string" | "number" | "boolean" | "choice"} SettingType
 */

/**
 * @typedef {object} SettingSpec
 * @property {SettingType} type
 * @property {*} [default]
 * @property {string} [label]
 * @property {string[]} [options] Required when `type` is `"choice"`
 */

/**
 * @callback RenderFn
 * @param {RenderContext} ctx
 * @returns {WidgetNode}
 */

/**
 * @callback IslandFn
 * @param {IslandContext} ctx
 * @returns {IslandClaim | null | undefined}
 */

/**
 * @callback ActionFn
 * @param {string} name
 * @returns {void}
 */

/**
 * @typedef {object} WidgetPermissions
 * @property {boolean} [network] `notch.fetch`. Cannot mix with media or battery. Also needs the Settings toggle.
 * @property {boolean} [media] `notch.media`, playback actions, and artwork. Also needs the Settings toggle.
 * @property {boolean} [battery] `notch.battery`. Also needs the Settings toggle.
 */

/**
 * @typedef {object} WidgetDefinition
 * @property {string} name
 * @property {Span} [span] Default cell. `[columns, rows]`. Never points.
 * @property {number} [refresh] Seconds between renders. `0` is static.
 * @property {number} [padding] Inset around the tree. `0` for full-bleed.
 * @property {WidgetPermissions} [permissions] What this file may touch. Default none.
 * @property {Object<string, SettingSpec>} [settings]
 * @property {RenderFn} render
 * @property {IslandFn} [island] Claims the collapsed wings. Return `null` to yield.
 * @property {ActionFn} [onAction] Named actions `button` did not reserve
 */

/**
 * Register this file as a widget. Call it once, at the top level.
 * @type {(definition: WidgetDefinition) => void}
 */
var widget;

// ---------------------------------------------------------------------------
// Nodes
// ---------------------------------------------------------------------------

/**
 * Opaque tree the host draws. Builders below are the only way to make one.
 * @typedef {object} WidgetNode
 * @property {string} type
 */

/**
 * @typedef {"regular" | "medium" | "semibold" | "bold" | string} FontWeight
 * @typedef {"leading" | "center" | "trailing" | string} Alignment
 * @typedef {"mono" | "hierarchical" | "palette" | "multicolor"} SymbolRendering
 * @typedef {"line" | "bars"} ChartKind
 * @typedef {"playPause" | "next" | "previous" | "refresh" | string} ActionName
 */

/**
 * @typedef {object} TextOptions
 * @property {number} [size]
 * @property {FontWeight} [weight]
 * @property {number} [opacity]
 * @property {string} [color] `#rrggbb`, `#rrggbbaa`, or a name like `"orange"`
 * @property {boolean} [monospaced]
 * @property {number} [lines]
 * @property {Alignment} [align] Also stretches the text to the column width
 * @property {boolean} [truncate] Ellipsis instead of shrinking the type
 */

/**
 * @typedef {object} SymbolOptions
 * @property {number} [size] Point size, or occupancy square when `fit`
 * @property {boolean} [fit] Scale the glyph into `size`×`size`. Battery needs this.
 * @property {number} [opacity]
 * @property {string} [color]
 * @property {string} [secondary] Palette layer two
 * @property {string} [tertiary] Palette layer three
 * @property {SymbolRendering} [rendering] Default `"mono"`
 */

/**
 * @typedef {object} ProgressOptions
 * @property {string} [color]
 * @property {number} [height]
 */

/**
 * @typedef {object} StackOptions
 * @property {number} [spacing]
 * @property {Alignment} [alignment]
 * @property {number} [padding]
 */

/**
 * Prefer `dim` over `opacity` for backdrops — fading art towards black
 * drains it to grey, while dimming keeps the hue.
 * @typedef {object} ArtworkOptions
 * @property {boolean} [blurred]
 * @property {number} [corner]
 * @property {number} [opacity]
 * @property {number} [size] Largest square side. Omit to square-fit the height.
 * @property {boolean} [fill] Cover the container on both axes
 * @property {number} [dim] 0–1 darken, keeps hue
 */

/**
 * @typedef {object} ButtonOptions
 * @property {number} [padding] Hit target around the child. Default 6.
 */

/**
 * @typedef {object} ListItem
 * @property {string} title
 * @property {string} [subtitle]
 * @property {string} [symbol] SF Symbol name
 * @property {string} [value]
 * @property {string} [color]
 * @property {string} [secondary]
 * @property {string} [tertiary]
 * @property {SymbolRendering} [rendering]
 */

/**
 * @typedef {object} ChartOptions
 * @property {ChartKind} [kind] Default `"line"`
 * @property {string} [color]
 * @property {number} [height]
 * @property {boolean} [fill]
 */

/**
 * @typedef {object} EqualiserOptions
 * @property {boolean} [playing]
 * @property {number} [size]
 */

/**
 * @type {(value: string | number, opts?: TextOptions) => WidgetNode}
 */
var text;

/**
 * Any SF Symbol.
 * @type {(name: string, opts?: SymbolOptions) => WidgetNode}
 */
var symbol;

/**
 * @type {(value: number, opts?: ProgressOptions) => WidgetNode}
 */
var progress;

/**
 * @type {(length?: number) => WidgetNode}
 */
var spacer;

/**
 * @type {(children: WidgetNode[], opts?: StackOptions) => WidgetNode}
 */
var vstack;

/**
 * @type {(children: WidgetNode[], opts?: StackOptions) => WidgetNode}
 */
var hstack;

/**
 * Front to back. Use for backdrops.
 * @type {(children: WidgetNode[], opts?: StackOptions) => WidgetNode}
 */
var zstack;

/**
 * Current album art, by reference — scripts never carry image bytes.
 * @type {(opts?: ArtworkOptions) => WidgetNode}
 */
var artwork;

/**
 * Named action. `"playPause"` / `"next"` / `"previous"` go to media,
 * `"refresh"` busts this widget's fetch cache, anything else hits `onAction`.
 * @type {(action: ActionName, child: WidgetNode, opts?: ButtonOptions) => WidgetNode}
 */
var button;

/**
 * @type {(items: ListItem[], opts?: object) => WidgetNode}
 */
var list;

/**
 * Values are normalised to the series' own min/max.
 * @type {(values: number[], opts?: ChartOptions) => WidgetNode}
 */
var chart;

/**
 * Now-playing bars. Size is the box they fill.
 * @type {(opts?: EqualiserOptions) => WidgetNode}
 */
var equaliser;
