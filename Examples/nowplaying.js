/// <reference path="./notch-api.js" />

function clamp(value) {
  return Math.max(0, Math.min(1, value || 0));
}

/**
 * @param {MediaSnapshot} media
 * @param {boolean} compact
 * @returns {WidgetNode}
 */
function controls(media, compact) {
  var glyph = compact ? 10 : 12;
  var pad = compact ? 5 : 7;
  return hstack([
    button("previous", symbol("backward.fill", { size: glyph, opacity: 0.85 }), { padding: pad }),
    button("playPause", symbol(media.isPlaying ? "pause.fill" : "play.fill", {
      size: compact ? 13 : 16
    }), { padding: compact ? 6 : 8 }),
    button("next", symbol("forward.fill", { size: glyph, opacity: 0.85 }), { padding: pad })
  ], { spacing: compact ? 2 : 4, alignment: "center" });
}

/**
 * @param {MediaSnapshot} media
 * @param {boolean} compact
 * @returns {WidgetNode}
 */
function info(media, compact) {
  return vstack([
    text(media.title, {
      size: compact ? 12 : 14, weight: "semibold", lines: 1, align: "leading", truncate: true
    }),
    text(media.artist || "Unknown Artist", {
      size: compact ? 10 : 11, opacity: 0.55, lines: 1, align: "leading", truncate: true
    })
  ], { spacing: 1, alignment: "leading" });
}

widget({
  name: "Now Playing",
  span: [3, 2],
  refresh: 1,
  padding: 0,
  permissions: { media: true },
  /**
   * @param {RenderContext} ctx
   * @returns {WidgetNode}
   */
  render: function (ctx) {
    var media = notch.media();
    var rows = (ctx && ctx.rows) || 2;
    var columns = (ctx && ctx.columns) || 3;
    var strip = rows < 2;
    var portrait = !strip && columns < 3;

    if (!media) {
      if (strip) {
        return hstack([
          symbol("music.note", { size: 16, opacity: 0.5 }),
          text("Not Playing", { size: 12, opacity: 0.6 })
        ], { spacing: 8, padding: 10, alignment: "center" });
      }
      return vstack([
        symbol("music.note", { size: 20, opacity: 0.5 }),
        text("Not Playing", { size: 12, opacity: 0.6 })
      ], { spacing: 6, padding: 10 });
    }

    if (strip) {
      var row = [artwork({ corner: 8 })];
      if (columns >= 2) row.push(info(media, true));
      if (columns >= 3) {
        row.push(controls(media, true));
      } else if (columns === 2) {
        row.push(button("playPause", symbol(
          media.isPlaying ? "pause.fill" : "play.fill", { size: 13 }
        ), { padding: 6 }));
      }
      return zstack([
        artwork({ blurred: true, fill: true, corner: 14, dim: 0.55 }),
        hstack(row, { spacing: 10, padding: 8, alignment: "center" })
      ]);
    }

    var details = vstack([
      info(media, portrait),
      spacer(portrait ? 8 : 12),
      progress(clamp(media.progress), { height: 3 }),
      spacer(portrait ? 6 : 8),
      controls(media, portrait)
    ], { spacing: 0, alignment: portrait ? "center" : "leading" });

    var cover = artwork({
      corner: portrait ? 10 : 12,
      size: portrait ? (columns >= 2 ? 72 : 52) : 88
    });

    var foreground = portrait
      ? vstack([cover, spacer(8), details], {
          spacing: 0,
          alignment: "center",
          padding: columns >= 2 ? 12 : 8
        })
      : hstack([cover, details], { spacing: 14, padding: 14 });

    return zstack([
      artwork({ blurred: true, fill: true, corner: 14, dim: 0.55 }),
      foreground
    ]);
  },
  /**
   * @param {IslandContext} ctx
   * @returns {IslandClaim | null}
   */
  island: function (ctx) {
    var media = notch.media();
    if (!media) return null;

    var side = (ctx && ctx.side) || 20;
    var hover = !!(ctx && ctx.hover);
    var playing = !!media.isPlaying;
    // Cover and the equaliser fill the content square. Pause/play are a
    // control, not a picture — the same box makes two fat bars look
    // like a billboard.
    var control = Math.round(side * 0.6);
    var right = (!hover && playing)
      ? equaliser({ playing: true, size: side })
      : symbol(playing ? "pause.fill" : "play.fill", {
          size: control,
          fit: true
        });

    return {
      priority: 50,
      action: "playPause",
      left: artwork({ corner: Math.round(side * 0.28), size: side }),
      right: right
    };
  }
});
