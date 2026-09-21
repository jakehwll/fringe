/// <reference path="./notch-api.js" />

function pad(value) {
  return value < 10 ? "0" + value : String(value);
}

var DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
var MONTHS = ["January", "February", "March", "April", "May", "June",
              "July", "August", "September", "October", "November", "December"];

function localBag(now) {
  return {
    hour: now.getHours(),
    minute: now.getMinutes(),
    second: now.getSeconds(),
    weekday: DAYS[now.getDay()],
    day: now.getDate(),
    month: MONTHS[now.getMonth()]
  };
}

function zonedBag(now, zone) {
  try {
    var fmt = new Intl.DateTimeFormat("en-US", {
      timeZone: zone,
      hour: "numeric",
      minute: "2-digit",
      second: "2-digit",
      hourCycle: "h23",
      weekday: "long",
      day: "numeric",
      month: "long"
    });
    var parts = {};
    fmt.formatToParts(now).forEach(function (part) {
      parts[part.type] = part.value;
    });
    return {
      hour: parseInt(parts.hour, 10),
      minute: parseInt(parts.minute, 10),
      second: parseInt(parts.second, 10),
      weekday: parts.weekday,
      day: parseInt(parts.day, 10),
      month: parts.month,
      zone: zone
    };
  } catch (e) {
    var fallback = localBag(now);
    fallback.zoneError = zone;
    return fallback;
  }
}

function zoneLabel(zone) {
  var bits = String(zone).split("/");
  return bits[bits.length - 1].replace(/_/g, " ");
}

widget({
  name: "Clock",
  span: [2, 1],
  refresh: 1,
  settings: {
    format: { type: "choice", options: ["12h", "24h"], default: "12h", label: "Hours" },
    seconds: { type: "boolean", default: false, label: "Seconds" },
    date: { type: "boolean", default: true, label: "Date" },
    timezone: { type: "string", default: "", label: "Time zone" }
  },
  /**
   * @param {RenderContext} ctx
   * @returns {WidgetNode}
   */
  render: function (ctx) {
    var now = new Date(ctx.timestamp * 1000);
    var zone = String(notch.setting("timezone") || "").trim();
    var bag = zone ? zonedBag(now, zone) : localBag(now);
    var twelve = (notch.setting("format") || "12h") !== "24h";
    var showSeconds = notch.setting("seconds") === true;
    var showDate = notch.setting("date") !== false;

    var hours = bag.hour;
    var suffix = "";
    if (twelve) {
      suffix = hours < 12 ? " AM" : " PM";
      hours = hours % 12 || 12;
    } else {
      hours = pad(hours);
    }

    var clock = hours + ":" + pad(bag.minute);
    if (showSeconds) clock += ":" + pad(bag.second);
    clock += suffix;

    var lines = [
      text(clock, { size: showSeconds ? 22 : 26, weight: "medium", monospaced: true })
    ];

    var detail = [];
    if (showDate) detail.push(bag.weekday + ", " + bag.day + " " + bag.month);
    if (bag.zoneError) detail.push("Unknown zone");
    else if (bag.zone) detail.push(zoneLabel(bag.zone));
    if (detail.length) {
      lines.push(text(detail.join(" · "), {
        size: 10, opacity: 0.5, lines: 1, truncate: true
      }));
    }

    return vstack(lines, { spacing: 2 });
  }
});
