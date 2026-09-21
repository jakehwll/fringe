/// <reference path="./notch-api.js" />

// Open-Meteo, no API key. `notch.fetch` never blocks: it returns
// `{ pending: true }` until the response lands, then the widget is
// asked to render again. City and units are user-facing settings.

function wmoSymbol(code) {
  if (code === 0) return "sun.max.fill";
  if (code <= 2) return "cloud.sun.fill";
  if (code === 3) return "cloud.fill";
  if (code <= 48) return "cloud.fog.fill";
  if (code <= 57) return "cloud.drizzle.fill";
  if (code <= 67) return "cloud.rain.fill";
  if (code <= 77) return "cloud.snow.fill";
  if (code <= 82) return "cloud.heavyrain.fill";
  if (code <= 86) return "cloud.snow.fill";
  return "cloud.bolt.rain.fill";
}

function wmoPalette(code) {
  if (code === 0) return { color: "#ffd60a", secondary: "#ff9f0a" };
  if (code <= 2) return { color: "#e8e8ed", secondary: "#ffd60a" };
  if (code === 3) return { color: "#d1d1d6", secondary: "#8e8e93" };
  if (code <= 48) return { color: "#c7c7cc", secondary: "#8e8e93" };
  if (code <= 57) return { color: "#e8e8ed", secondary: "#64d2ff" };
  if (code <= 67) return { color: "#d1d1d6", secondary: "#0a84ff" };
  if (code <= 77) return { color: "#e8e8ed", secondary: "#7ec8ff" };
  if (code <= 82) return { color: "#d1d1d6", secondary: "#0a84ff", tertiary: "#64d2ff" };
  if (code <= 86) return { color: "#e8e8ed", secondary: "#7ec8ff" };
  return { color: "#c7c7cc", secondary: "#ffd60a", tertiary: "#0a84ff" };
}

/**
 * @param {number} code
 * @param {number} size
 * @returns {WidgetNode}
 */
function wxSymbol(code, size) {
  var paint = wmoPalette(code);
  return symbol(wmoSymbol(code), {
    size: size,
    rendering: "palette",
    color: paint.color,
    secondary: paint.secondary,
    tertiary: paint.tertiary
  });
}

/**
 * @param {string} iso
 * @param {number} code
 * @param {number} high
 * @param {number} low
 * @param {string} units
 * @returns {ListItem}
 */
function wmoDay(iso, code, high, low, units) {
  var paint = wmoPalette(code);
  return {
    title: weekday(iso),
    symbol: wmoSymbol(code),
    value: convert(high, units) + " / " + convert(low, units),
    rendering: "palette",
    color: paint.color,
    secondary: paint.secondary,
    tertiary: paint.tertiary
  };
}

function wmoLabel(code) {
  if (code === 0) return "Clear";
  if (code <= 2) return "Partly cloudy";
  if (code === 3) return "Overcast";
  if (code <= 48) return "Fog";
  if (code <= 57) return "Drizzle";
  if (code <= 67) return "Rain";
  if (code <= 77) return "Snow";
  if (code <= 82) return "Showers";
  if (code <= 86) return "Snow showers";
  return "Storms";
}

function weekday(iso) {
  var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  return days[new Date(iso + "T12:00:00").getDay()];
}

function convert(celsius, units) {
  var value = units === "F" ? celsius * 9 / 5 + 32 : celsius;
  return Math.round(value) + "°";
}

/**
 * @param {string} symbolName
 * @param {string} title
 * @param {string} detail
 * @param {boolean} [tiny]
 * @returns {WidgetNode}
 */
function status(symbolName, title, detail, tiny) {
  if (tiny) {
    return vstack([
      symbol(symbolName, { size: 18, opacity: 0.55 }),
      text(title, { size: 11, weight: "medium", lines: 1, truncate: true })
    ], { spacing: 4, padding: 8 });
  }
  return vstack([
    symbol(symbolName, { size: 18, opacity: 0.55 }),
    text(title, { size: 12, weight: "medium" }),
    text(detail, { size: 10, opacity: 0.5, lines: 2 })
  ], { spacing: 4, padding: 8 });
}

/**
 * @param {number[]} values
 * @param {number} height
 * @returns {WidgetNode}
 */
function sparkline(values, height) {
  return chart(values, { height: height, fill: true, color: "#64d2ff" });
}

widget({
  name: "Weather",
  span: [3, 2],
  refresh: 60,
  permissions: { network: true },
  settings: {
    city: { type: "string", default: "Sydney", label: "City" },
    units: { type: "choice", options: ["C", "F"], default: "C", label: "Units" }
  },
  /**
   * @param {RenderContext} ctx
   * @returns {WidgetNode}
   */
  render: function (ctx) {
    var city = notch.setting("city") || "Sydney";
    var units = notch.setting("units") || "C";
    var rows = (ctx && ctx.rows) || 2;
    var columns = (ctx && ctx.columns) || 3;
    var strip = rows < 2;
    var tiny = strip && columns < 2;
    var narrow = !strip && columns < 2;

    var geo = notch.fetch(
      "https://geocoding-api.open-meteo.com/v1/search?name="
        + encodeURIComponent(city) + "&count=1",
      { ttl: 86400 }
    );
    if (geo.pending) return status("location.magnifyingglass", city, "Finding location…", tiny);
    if (!geo.ok) return status("exclamationmark.triangle.fill", city, geo.error || "Lookup failed", tiny);

    var hit = geo.json && geo.json.results && geo.json.results[0];
    if (!hit) return status("mappin.slash", city, "No match", tiny);

    var wx = notch.fetch(
      "https://api.open-meteo.com/v1/forecast"
        + "?latitude=" + hit.latitude
        + "&longitude=" + hit.longitude
        + "&current=temperature_2m,weather_code,wind_speed_10m"
        + "&hourly=temperature_2m"
        + "&daily=weather_code,temperature_2m_max,temperature_2m_min"
        + "&timezone=auto&forecast_days=5",
      { ttl: 600 }
    );
    if (wx.pending) return status("cloud.sun.fill", hit.name, "Loading forecast…", tiny);
    if (!wx.ok) return status("exclamationmark.triangle.fill", hit.name, wx.error || "Forecast failed", tiny);

    var current = wx.json.current || {};
    var daily = wx.json.daily || {};
    var hourly = wx.json.hourly || {};
    var code = current.weather_code || 0;

    var times = hourly.time || [];
    var temps = hourly.temperature_2m || [];
    var start = 0;
    for (var i = 0; i < times.length; i++) {
      if (times[i] >= (current.time || "")) { start = i; break; }
    }
    var spark = temps.slice(start, start + 12);

    var temp = convert(current.temperature_2m, units);

    if (tiny) {
      return vstack([
        wxSymbol(code, 26),
        text(temp, { size: 22, weight: "medium" })
      ], { spacing: 4, padding: 8 });
    }

    if (narrow) {
      return vstack([
        wxSymbol(code, 28),
        text(temp, { size: 26, weight: "medium" }),
        text(wmoLabel(code), { size: 11, opacity: 0.55, lines: 1 }),
        sparkline(spark, 32)
      ], { spacing: 6, padding: 10 });
    }

    var header = strip
      ? hstack([
          wxSymbol(code, 16),
          text(hit.name, { size: 12, weight: "semibold", lines: 1, align: "leading", truncate: true }),
          spacer(),
          text(temp, { size: 20, weight: "medium" })
        ], { spacing: 6, alignment: "center" })
      : hstack([
          wxSymbol(code, 22),
          vstack([
            text(hit.name, { size: 13, weight: "semibold", lines: 1, align: "leading", truncate: true }),
            text(wmoLabel(code), { size: 10, opacity: 0.55, lines: 1, align: "leading" })
          ], { spacing: 1, alignment: "leading" }),
          spacer(),
          text(temp, { size: 26, weight: "medium" })
        ], { spacing: 8, alignment: "center" });

    var stack = [header, sparkline(spark, strip ? 28 : 26)];
    if (!strip) {
      var days = [];
      var labels = daily.time || [];
      for (var d = 0; d < Math.min(4, labels.length); d++) {
        days.push(wmoDay(
          labels[d],
          daily.weather_code[d],
          daily.temperature_2m_max[d],
          daily.temperature_2m_min[d],
          units
        ));
      }
      stack.push(list(days));
    }

    return vstack(stack, {
      spacing: strip ? 4 : 8,
      padding: strip ? 8 : 10,
      alignment: "leading"
    });
  }
});
