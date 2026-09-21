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

/**
 * @param {number} percent
 * @param {boolean} plugged
 * @param {boolean} charged
 * @param {string} [colour]
 * @param {number} size
 * @returns {WidgetNode}
 */
function icon(percent, plugged, charged, colour, size) {
  if (plugged && (charged || percent > 85)) {
    return symbol("battery.100percent.bolt", {
      size: size, opacity: 0.9, color: colour || "#30d158"
    });
  }
  var battery = symbol(glyph(percent), {
    size: size, opacity: 0.9, color: colour
  });
  if (!plugged) return battery;
  return hstack([
    battery,
    symbol("bolt.fill", {
      size: Math.round(size * 0.7),
      color: colour || "#30d158"
    })
  ], { spacing: 3, alignment: "center" });
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
 * @param {number} percent
 * @param {string | undefined} colour
 * @param {number} size
 * @returns {WidgetNode}
 */
function figure(percent, colour, size) {
  return text(percent + "%", {
    size: size,
    weight: "medium",
    color: colour
  });
}

/**
 * @param {string} label
 * @returns {WidgetNode}
 */
function caption(label) {
  return text(label, { size: 11, opacity: 0.55, lines: 1, truncate: true });
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
        text("No battery", { size: 11, opacity: 0.5 })
      ], { spacing: 6 });
    }

    var percent = state.percent;
    var plugged = state.plugged;
    var colour = state.colour;
    var power = state.power;
    var showPercent = notch.setting("percent") !== false;
    var showTime = notch.setting("time") !== false;
    var minutes = showTime ? duration(power.minutes) : null;
    var label = status(power, minutes, percent, state.low);
    var columns = (ctx && ctx.columns) || 1;
    var rows = (ctx && ctx.rows) || 1;
    var wide = columns >= 2;
    var tall = rows >= 2;
    var bar = progress(power.level, { color: colour, height: 4 });
    var note = caption(label);
    var mark = icon(percent, plugged, power.charged, colour, tall ? 26 : 22);
    var number = showPercent ? figure(percent, colour, wide || tall ? 22 : 20) : null;

    // 1×1: the bolt is the state. A caption like "Almost full" just
    // narrates the glyph and crowds the cell — skip it here.
    if (!wide && !tall) {
      var compact = [mark];
      if (number) compact.push(number);
      compact.push(spacer(), bar);
      return vstack(compact, { spacing: 6 });
    }

    if (wide) {
      var copy = [];
      if (number) copy.push(number);
      copy.push(note);
      var body = number
        ? hstack([
            mark,
            vstack(copy, { spacing: 3, alignment: "leading" })
          ], { spacing: 10, alignment: "center" })
        : hstack([mark, note], { spacing: 10, alignment: "center" });
      return vstack([body, spacer(), bar], { spacing: 0 });
    }

    var stack = [mark];
    if (number) stack.push(number);
    stack.push(note, spacer(), bar);
    return vstack(stack, { spacing: 8 });
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
    var power = state.power;
    var critical = !plugged && percent <= 10;
    var goingFlat = !plugged && percent <= state.low;
    var pulse = !!(ctx && ctx.pulse);
    if (!critical && !goingFlat && !pulse) return null;

    var colour = state.colour;
    var side = (ctx && ctx.side) || 20;
    var mark = (plugged && (power.charged || percent > 85))
      ? "battery.100percent.bolt"
      : glyph(percent);
    // Same class of mark as play/pause — a glyph in the wing, not the
    // album-art square. `fit` keeps the wide battery inside that box.
    var markSize = Math.round(side * 0.85);
    return {
      priority: critical ? 100 : pulse ? 80 : 20,
      left: symbol(mark, { size: markSize, fit: true, color: colour }),
      right: text(percent + "%", {
        size: Math.round(side * 0.62),
        weight: "semibold",
        monospaced: true,
        lines: 1,
        color: colour
      })
    };
  }
});
