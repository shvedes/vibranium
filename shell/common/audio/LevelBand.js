.pragma library

.import "../text/Format.js" as Format

// Severity band for a normalized audio level.
//
// A level is printed as a rounded percent, and the colour a row paints must be
// derived from that same rounded number or the digits and the tone can
// disagree at a threshold. The callers own the thresholds - a device track, a
// stream and the island's readout have different headroom - so both bounds
// arrive as arguments.
//
// "" is the ordinary band, "yellow" is above nominal, "red" is past the point
// even a boosted track calls loud.
function band(volume, yellowFrom, redFrom) {
  const pct = Format.percentInt(volume)
  if (pct >= redFrom) return "red"
  if (pct >= yellowFrom) return "yellow"
  return ""
}
