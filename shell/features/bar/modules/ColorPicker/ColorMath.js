.pragma library

.import "../../../../common/math/Color.js" as Color

// Thin re-export over common/math/Color.js, the canonical color table.
// The module's chip order, serialization spellings and history shapes
// live there; this file keeps the ColorMath name (and its history-only
// parseHistory/recordKey/sanitizeFormats deltas) so the picker, island
// and history list import unchanged.

var FORMATS = Color.FORMATS

function clamp01(x) { return Color.clamp01(x) }
function clampAlpha(a) { return Color.clampAlpha(a) }
function valid(c) { return Color.valid(c) }
function parse(str) { return Color.parse(str) }
function hsvToRgb(h, s, v) { return Color.hsvToRgb(h, s, v) }
function hslToRgb(h, s, l) { return Color.hslToRgb(h, s, l) }
function rgbToHsv(r, g, b) { return Color.rgbToHsv(r, g, b) }
function rgbToHsl(r, g, b) { return Color.rgbToHsl(r, g, b) }
function _byte(x) { return Color._byte(x) }
function hex6(c) { return Color.hex6(c) }
function hex8(c, a) { return Color.hex8(c, a) }
function rgb(c, a) { return Color.rgb(c, a) }
function rgba(c, a) { return Color.rgba(c, a) }
function hsl(c, a) { return Color.hsl(c, a) }
function hsla(c, a) { return Color.hsla(c, a) }
function hsv(c, a) { return Color.hsv(c, a) }
function hsva(c, a) { return Color.hsva(c, a) }
function format(c, fmt, a) { return Color.format(c, fmt, a) }
function allFormats(c, a) { return Color.allFormats(c, a) }
// The format a color code is written in: the island's field detects the
// spelling the user typed and follows it, so the chip, the field and the
// copy button agree on one format.
function detectFormat(str) { return Color.detectFormat(str) }
function recordKey(rec) {
  const f = rec && typeof rec.fmt === "string" ? rec.fmt : "hex"
  return String(rec && rec.color || "")
    + "|" + Color.clampAlpha(rec && rec.alpha).toFixed(3) + "|" + f
}
function sanitizeFormats(raw) {
  const out = {}
  if (!raw || typeof raw !== "object") return out
  for (let k = 0; k < Color.FORMATS.length; k++) {
    const v = raw[Color.FORMATS[k]]
    if (typeof v === "string" && v !== "") out[Color.FORMATS[k]] = v
  }
  return out
}
function contrastText(c) { return Color.contrastText(c) }
function parseHistory(text) {
  function _recordsFromArray(arr) {
    const out = []
    for (let i = 0; i < arr.length; i++) {
      const rec = _recordFrom(arr[i])
      if (rec !== null) out.push(rec)
    }
    return out
  }
  function _recordFrom(o) {
    if (o === null || typeof o !== "object") return null
    const c = Color.parse(o.color)
    if (c === null) return null
    const a = typeof o.alpha === "number" ? Color.clampAlpha(o.alpha) : 1
    const t = typeof o.timestamp === "number" && isFinite(o.timestamp) ? o.timestamp : 0
    const rec = { color: Color.hex6(c), alpha: a, timestamp: t }
    if (o.formats && typeof o.formats === "object") {
      const fmts = {}
      const names = Color.FORMATS
      for (let k = 0; k < names.length; k++) {
        const v = o.formats[names[k]]
        if (typeof v === "string" && v !== "") fmts[names[k]] = v
      }
      rec.formats = fmts
    }
    if (typeof o.fmt === "string" && Color.FORMATS.indexOf(o.fmt) >= 0) rec.fmt = o.fmt
    return rec
  }
  const s = String(text === undefined || text === null ? "" : text).trim()
  if (s === "") return []
  if (s.charAt(0) === "{") {
    let wrap = null
    try { wrap = JSON.parse(s) } catch (e) { wrap = null }
    if (wrap !== null && typeof wrap === "object" && !Array.isArray(wrap)
      && wrap.data !== undefined) {
      const inner = wrap.data
      if (Array.isArray(inner)) return _recordsFromArray(inner)
      if (inner !== null && typeof inner === "object" && !Array.isArray(inner)
        && Array.isArray(inner.records)) return _recordsFromArray(inner.records)
      return []
    }
  }
  if (s.charAt(0) === "[") {
    let arr = null
    try { arr = JSON.parse(s) } catch (e) { return [] }
    if (!Array.isArray(arr)) return []
    return _recordsFromArray(arr)
  }
  const out = []
  const lines = s.split("\n")
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim()
    if (line === "") continue
    if (line.charAt(0) === "{") {
      let o = null
      try { o = JSON.parse(line) } catch (e) { continue }
      const rec = _recordFrom(o)
      if (rec !== null) out.push(rec)
    } else {
      const c = Color.parse(line)
      if (c === null) continue
      out.push({ color: Color.hex6(c), alpha: c.a, timestamp: 0 })
    }
  }
  return out
}
