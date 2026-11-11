.pragma library

.import "../../../../common/math/Color.js" as Color

// The picker's stored-history shapes: the dedupe key a record is matched by,
// the formats map the store accepts, and the parser that turns the persisted
// document back into records. The color channel layer itself lives in
// common/math/Color.js; this file only owns what is specific to history rows,
// so the module that renders them imports the canonical color table directly.

// The identity two records share when they name the same color, alpha and
// serialization format. Rounded alpha keeps a float that differs only past
// three decimals from minting a second entry.
function recordKey(rec) {
  const f = rec && typeof rec.fmt === "string" ? rec.fmt : "hex"
  return String(rec && rec.color || "")
    + "|" + Color.clampAlpha(rec && rec.alpha).toFixed(3) + "|" + f
}

// The format map a record may carry: only known format names with a
// non-empty spelling survive.
function sanitizeFormats(raw) {
  const out = {}
  if (!raw || typeof raw !== "object") return out
  for (let k = 0; k < Color.FORMATS.length; k++) {
    const v = raw[Color.FORMATS[k]]
    if (typeof v === "string" && v !== "") out[Color.FORMATS[k]] = v
  }
  return out
}

// The persisted history document as records. Accepts the wrapped
// { data: [...] } envelope, a bare array, or one JSON object per line, and
// drops every entry whose color does not parse.
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
