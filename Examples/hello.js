/// <reference path="./notch-api.js" />

// The smallest possible widget. Copy this file to start a new one.
widget({
  name: "Hello",
  span: [1, 1],
  // Static: the tile is built once, and with no island() this
  // script does no work at all while the panel is collapsed.
  refresh: 0,
  render: function () {
    return vstack([
      symbol("hand.wave.fill", { size: 18, opacity: 0.8 }),
      text("Hello", { size: 12 })
    ], { spacing: 6 });
  }
});
