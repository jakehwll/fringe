/// <reference path="./notch-api.js" />

function glyph(percent) {
  return percent <= 10 ? "battery.0percent"
    : percent <= 35 ? "battery.25percent"
    : percent <= 60 ? "battery.50percent"
    : percent <= 85 ? "battery.75percent"
    : "battery.100percent";
}

function tint(percent, plugged, low) {
  if (percent <= low) return "#ff453a";
  if (percent <= low + 15) return "#ff9f0a";
  if (plugged) return "#30d158";
  return undefined;
}

function duration(minutes) {
  if (minutes == null || minutes < 0) return null;
  minutes = Math.round(minutes);
  if (minutes < 60) return minutes + "m";
  var hours = Math.floor(minutes / 60);
  var rest = minutes % 60;
  return rest ? hours + "h " + rest + "m" : hours + "h";
}

/**
 * @param {BatterySnapshot} power
 * @param {string | null} minutes
 * @param {number} percent
 * @param {number} low
 * @returns {string}
 */
function status(power, minutes, percent, low) {
  if (power.charged) return "Charged";
  if (power.charging) return minutes ? "Full in " + minutes : "Charging";
  if (power.ac) return "Plugged in";
  if (percent <= low) return minutes ? "Low · " + minutes : "Low";
  return minutes ? minutes + " left" : "On battery";
}

/**
 * @param {(WidgetNode | null | undefined)[]} nodes
 * @returns {WidgetNode[]}
 */
function filled(nodes) {
  var kept = [];
  for (var i = 0; i < nodes.length; i++) {
    if (nodes[i]) kept.push(nodes[i]);
  }
  return kept;
}

/**
 * One box for every state. The bolt is drawn inside it — a bolt beside
 * the glyph changes width when the charger connects and the percentage
 * slides over. `fit` holds the wide battery symbol in that same box.
 * @param {number} percent
 * @param {boolean} plugged
 * @param {string | undefined} colour
 * @param {number} size
 * @returns {WidgetNode}
 */
function mark(percent, plugged, colour, size) {
  var battery = symbol(glyph(percent), { size: size, fit: true, color: colour });
  if (!plugged) return battery;
  return zstack([
    battery,
    symbol("bolt.fill", { size: Math.round(size * 0.4), color: "#ffffff" })
  ]);
}

/**
 * @returns {{
 *   power: BatterySnapshot,
 *   percent: number,
 *   low: number,
 *   plugged: boolean,
 *   colour: string | undefined
 * } | null}
 */
function snapshot() {
  var power = notch.battery();
  if (!power) return null;
  var percent = Math.round(power.level * 100);
  var low = Number(notch.setting("low"));
  if (!(low >= 0)) low = 20;
  var plugged = !!(power.charging || power.charged || power.ac);
  return {
    power: power,
    percent: percent,
    low: low,
    plugged: plugged,
    colour: tint(percent, plugged, low)
  };
}

widget({
  name: "Battery",
  span: [1, 1],
  refresh: 5,
  permissions: { battery: true },
  settings: {
    percent: { type: "boolean", default: true, label: "Percentage" },
    time: { type: "boolean", default: true, label: "Time remaining" },
    low: { type: "number", default: 20, label: "Low at" }
  },
  /**
   * @param {RenderContext} ctx
   * @returns {WidgetNode}
   */
  render: function (ctx) {
    var state = snapshot();
    if (!state) {
      return vstack([
        symbol("powerplug.fill", { size: 16, opacity: 0.45 }),
        text("No battery", { size: 11, opacity: 0.5, align: "center", lines: 1 })
      ], { spacing: 6 });
    }

    var wide = ((ctx && ctx.columns) || 1) >= 2;
    var tall = ((ctx && ctx.rows) || 1) >= 2;
    // Default cell is 72pt with 8pt of widget padding: 56pt of content.
    // Icon, percentage, and the bar already fill that. The caption only
    // appears once a second column or row exists.
    var align = wide ? "leading" : "center";
    var minutes = notch.setting("time") !== false ? duration(state.power.minutes) : null;

    var badge = mark(state.percent, state.plugged, state.colour, 22);
    var number = notch.setting("percent") === false ? null : text(state.percent + "%", {
      size: 16,
      weight: "medium",
      color: state.colour,
      align: align,
      lines: 1
    });
    var note = (wide || tall) ? text(status(state.power, minutes, state.percent, state.low), {
      size: 11,
      opacity: 0.55,
      align: align,
      lines: 1,
      truncate: true
    }) : null;
    var lines = filled([number, note]);

    var header = wide
      ? hstack(filled([
          badge,
          lines.length ? vstack(lines, { spacing: 1, alignment: "leading" }) : null
        ]), { spacing: 8, alignment: "center" })
      : vstack(filled([badge, number, note]), { spacing: 2, alignment: "center" });

    // Fixed 4pt keeps the bar off the type in a 1-row cell. The flexible
    // spacer takes whatever a taller cell adds, so the bar stays put
    // instead of the whole stack spreading out.
    return vstack([header, spacer(), spacer(4), progress(state.power.level, {
      color: state.colour,
      height: 3
    })], { spacing: 0, alignment: align });
  },
  // Collapsed wings. `null` leaves them to someone else (or empty).
  // Priority is how we steal from now-playing: critical outranks a
  // track, a MagSafe pulse outranks a track, going-flat does not.
  /**
   * @param {IslandContext} ctx
   * @returns {IslandClaim | null}
   */
  island: function (ctx) {
    var state = snapshot();
    if (!state) return null;

    var percent = state.percent;
    var plugged = state.plugged;
    var critical = !plugged && percent <= 10;
    var goingFlat = !plugged && percent <= state.low;
    var pulse = !!(ctx && ctx.pulse);
    if (!critical && !goingFlat && !pulse) return null;

    var side = (ctx && ctx.side) || 20;
    return {
      priority: critical ? 100 : pulse ? 80 : 20,
      left: mark(percent, plugged, state.colour, Math.round(side * 0.85)),
      right: text(percent + "%", {
        size: Math.round(side * 0.62),
        weight: "semibold",
        monospaced: true,
        lines: 1,
        color: state.colour
      })
    };
  }
});
