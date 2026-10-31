.pragma library

// Pure color parsing/conversion shared by the bar ColorPicker module and
// every other consumer (launcher color plugin via build concat per 06).
//
// Canonical home of the verbatim color triple (ColorMath.js =
// ColorLib.js = plugins/color/main.js). Channels stay normalized in
// [0, 1]; every entry point returns null (or "") on malformed input
// instead of throwing or emitting a CSS string a browser would have to
// reject.

// Supported output formats, in chip order.
var FORMATS = ["hex", "rgb", "rgba", "hsl", "hsla", "hsv", "hsva"]

// --- validation helpers ---

function clamp01(x) {
  const n = Number(x)
  if (!isFinite(n)) return 0
  return n < 0 ? 0 : n > 1 ? 1 : n
}

// Clamp any incoming alpha to [0, 1]; absent or non-numeric is opaque.
function clampAlpha(a) {
  if (a === undefined || a === null) return 1
  const n = Number(a)
  if (!isFinite(n)) return 1
  return n < 0 ? 0 : n > 1 ? 1 : n
}

function valid(c) {
  return c !== null && c !== undefined
    && isFinite(c.r) && isFinite(c.g) && isFinite(c.b)
}

// --- parsing ---

// Parse any supported string into {r, g, b, a} (normalized) or null.
// Accepts #RGB/#RRGGBB/#RRGGBBAA with or without the hash, rgb()/rgba(),
// hsl()/hsla() and hsv()/hsva().
function parse(str) {
  const s = String(str === undefined || str === null ? "" : str).trim()
  if (s === "") return null
  if (s.charAt(0) === "#") return parseHex(s)
  const low = s.toLowerCase()
  if (/^rgba?\s*\(/.test(low)) return parseRgb(s)
  if (/^hsla?\s*\(/.test(low)) return parseHsl(s)
  if (/^hsva?\s*\(/.test(low)) return parseHsv(s)
  // Bare RRGGBB / RRGGBBAA without the leading hash.
  return parseHex(s)
}

function parseHex(s) {
  const h = String(s).trim().replace(/^#+/, "")
  if (!/^[0-9a-fA-F]+$/.test(h)) return null
  let r, g, b, a = 1
  if (h.length === 3 || h.length === 4) {
    r = parseInt(h.charAt(0) + h.charAt(0), 16) / 255
    g = parseInt(h.charAt(1) + h.charAt(1), 16) / 255
    b = parseInt(h.charAt(2) + h.charAt(2), 16) / 255
    if (h.length === 4) a = parseInt(h.charAt(3) + h.charAt(3), 16) / 255
  } else if (h.length === 6 || h.length === 8) {
    r = parseInt(h.substring(0, 2), 16) / 255
    g = parseInt(h.substring(2, 4), 16) / 255
    b = parseInt(h.substring(4, 6), 16) / 255
    if (h.length === 8) a = parseInt(h.substring(6, 8), 16) / 255
  } else {
    return null
  }
  if (!isFinite(r) || !isFinite(g) || !isFinite(b)) return null
  return { r: clamp01(r), g: clamp01(g), b: clamp01(b), a: clamp01(a) }
}

// Split a css function body on commas, spaces and the modern "/" alpha
// separator.
function _parts(inner) {
  const cleaned = String(inner).replace(/\//g, " ").trim()
  if (cleaned === "") return []
  return cleaned.split(/[\s,]+/)
}

// The number of channels in a css function body: three for the plain
// forms, four when an alpha is written out.
function _channelCount(s) {
  const open = s.indexOf("(")
  const close = s.lastIndexOf(")")
  if (open < 0 || close < open) return 0
  return _parts(s.substring(open + 1, close)).length
}

function _channelNum(v) {
  const t = String(v).trim().toLowerCase()
  if (t === "") return -1
  const pct = t.charAt(t.length - 1) === "%"
  const n = parseFloat(pct ? t.substring(0, t.length - 1) : t)
  if (!isFinite(n)) return -1
  return n
}

// One rgb channel (0..255 or a percentage) normalized to [0, 1]; -1 on
// malformed input.
function _chan255(v) {
  const n = _channelNum(v)
  if (n < 0) return -1
  const pct = String(v).trim().charAt(String(v).trim().length - 1) === "%"
  return clamp01(pct ? n / 100 : n / 255)
}

// One hsl/hsv component (percentage or unitless); -1 on malformed input.
function _chanUnit(v) {
  const t = String(v).trim().toLowerCase()
  if (t === "") return -1
  const n = _channelNum(v)
  if (n < 0) return -1
  const pct = t.charAt(t.length - 1) === "%"
  return clamp01(pct ? n / 100 : n > 1 ? n / 100 : n)
}

// One alpha component; -1 on malformed input.
function _chanAlpha(v) {
  const t = String(v).trim().toLowerCase()
  if (t === "") return -1
  const n = _channelNum(v)
  if (n < 0) return -1
  const pct = t.charAt(t.length - 1) === "%"
  return clamp01(pct ? n / 100 : n)
}

// Hue in degrees, "deg" suffix optional; -1 on malformed input.
function _hue(v) {
  const t = String(v).trim().toLowerCase().replace(/deg$/, "")
  const n = parseFloat(t)
  if (!isFinite(n)) return -1
  return n
}

function _alphaOf(parts) {
  if (parts.length !== 4) return 1
  const a = _chanAlpha(parts[3])
  return a < 0 ? -1 : a
}

function parseRgb(s) {
  if (!/^rgba?\s*\(/i.test(s)) return null
  const parts = _parts(s.substring(s.indexOf("(") + 1, s.lastIndexOf(")")))
  if (parts.length !== 3 && parts.length !== 4) return null
  const r = _chan255(parts[0])
  const g = _chan255(parts[1])
  const b = _chan255(parts[2])
  if (r < 0 || g < 0 || b < 0) return null
  const a = _alphaOf(parts)
  if (a < 0) return null
  return { r: r, g: g, b: b, a: a }
}

function parseHsl(s) {
  if (!/^hsla?\s*\(/i.test(s)) return null
  const parts = _parts(s.substring(s.indexOf("(") + 1, s.lastIndexOf(")")))
  if (parts.length !== 3 && parts.length !== 4) return null
  const h = _hue(parts[0])
  const sa = _chanUnit(parts[1])
  const l = _chanUnit(parts[2])
  if (h < 0 || sa < 0 || l < 0) return null
  const a = _alphaOf(parts)
  if (a < 0) return null
  const c = hslToRgb(h, sa, l)
  return c === null ? null : { r: c.r, g: c.g, b: c.b, a: a }
}

function parseHsv(s) {
  if (!/^hsva?\s*\(/i.test(s)) return null
  const parts = _parts(s.substring(s.indexOf("(") + 1, s.lastIndexOf(")")))
  if (parts.length !== 3 && parts.length !== 4) return null
  const h = _hue(parts[0])
  const sa = _chanUnit(parts[1])
  const v = _chanUnit(parts[2])
  if (h < 0 || sa < 0 || v < 0) return null
  const a = _alphaOf(parts)
  if (a < 0) return null
  const c = hsvToRgb(h, sa, v)
  return c === null ? null : { r: c.r, g: c.g, b: c.b, a: a }
}

// --- conversions ---

function hsvToRgb(h, s, v) {
  if (!isFinite(h) || !isFinite(s) || !isFinite(v)) return null
  const hh = ((h % 360) + 360) % 360
  const ss = clamp01(s)
  const vv = clamp01(v)
  const i = Math.floor(hh / 60) % 6
  const f = hh / 60 - Math.floor(hh / 60)
  const p = vv * (1 - ss)
  const q = vv * (1 - f * ss)
  const t = vv * (1 - (1 - f) * ss)
  let r = 0, g = 0, b = 0
  if (i === 0) { r = vv; g = t; b = p }
  else if (i === 1) { r = q; g = vv; b = p }
  else if (i === 2) { r = p; g = vv; b = t }
  else if (i === 3) { r = p; g = q; b = vv }
  else if (i === 4) { r = t; g = p; b = vv }
  else { r = vv; g = p; b = q }
  return { r: r, g: g, b: b, a: 1 }
}

function hslToRgb(h, s, l) {
  if (!isFinite(h) || !isFinite(s) || !isFinite(l)) return null
  const hh = ((h % 360) + 360) % 360
  const ss = clamp01(s)
  const ll = clamp01(l)
  const c = (1 - Math.abs(2 * ll - 1)) * ss
  const x = c * (1 - Math.abs((hh / 60) % 2 - 1))
  const m = ll - c / 2
  let r = 0, g = 0, b = 0
  if (hh < 60) { r = c; g = x }
  else if (hh < 120) { r = x; g = c }
  else if (hh < 180) { g = c; b = x }
  else if (hh < 240) { g = x; b = c }
  else if (hh < 300) { r = x; b = c }
  else { r = c; b = x }
  return { r: clamp01(r + m), g: clamp01(g + m), b: clamp01(b + m), a: 1 }
}

function rgbToHsv(r, g, b) {
  if (!isFinite(r) || !isFinite(g) || !isFinite(b)) return { h: 0, s: 0, v: 0 }
  const max = Math.max(r, g, b)
  const min = Math.min(r, g, b)
  const d = max - min
  let h = 0
  if (d > 0) {
    if (max === r) h = 60 * (((g - b) / d) % 6)
    else if (max === g) h = 60 * ((b - r) / d + 2)
    else h = 60 * ((r - g) / d + 4)
  }
  return {
    h: ((h % 360) + 360) % 360,
    s: max <= 0 ? 0 : clamp01(d / max),
    v: clamp01(max)
  }
}

function rgbToHsl(r, g, b) {
  if (!isFinite(r) || !isFinite(g) || !isFinite(b)) return { h: 0, s: 0, l: 0 }
  const max = Math.max(r, g, b)
  const min = Math.min(r, g, b)
  const l = (max + min) / 2
  const d = max - min
  let h = 0, s = 0
  if (d > 0) {
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min)
    if (max === r) h = 60 * (((g - b) / d) % 6)
    else if (max === g) h = 60 * ((b - r) / d + 2)
    else h = 60 * ((r - g) / d + 4)
  }
  return { h: ((h % 360) + 360) % 360, s: clamp01(s), l: clamp01(l) }
}

// --- blending ---

// Two colors blended into one. `t` is the share of the SECOND color, so
// t = 0 is the first color and t = 1 the second.
//
// The channels are mixed as they are stored - gamma-encoded sRGB, the
// arithmetic CSS color-mix() does by default - because a palette tint of a
// near-black surface is a surface, not a light, and mixing in linear light
// would make the same share read as a different color in every theme.
//
// The result is opaque: the alpha of either color is dropped, because a blend
// of two leaves is a surface and a surface is opaque. "" when either color
// cannot be read, so a caller can tell a failed blend from a black one.
function mix(a, b, t) {
  const ca = parse(a)
  const cb = parse(b)
  if (ca === null || cb === null) return ""
  const k = clamp01(t)
  return hex6({
    r: ca.r + (cb.r - ca.r) * k,
    g: ca.g + (cb.g - ca.g) * k,
    b: ca.b + (cb.b - ca.b) * k,
    a: 1
  })
}

// --- serialization ---

function _byte(x) {
  const h = Math.round(clamp01(x) * 255).toString(16)
  return h.length < 2 ? "0" + h : h
}

// Lowercase #rrggbb, or null when the channels are unusable.
function hex6(c) {
  if (!valid(c)) return null
  return "#" + _byte(c.r) + _byte(c.g) + _byte(c.b)
}

// #RRGGBB, or #RRGGBBAA once the alpha drops below 1.
function hex8(c, a) {
  if (!valid(c)) return null
  const al = clampAlpha(a)
  const base = hex6(c)
  return al >= 1 ? base : base + _byte(al)
}

// The opaque rgb() form cannot carry alpha; a is accepted and dropped so
// every serializer shares one signature.
function rgb(c, a) {
  if (!valid(c)) return null
  return "rgb(" + Math.round(clamp01(c.r) * 255) + ", "
    + Math.round(clamp01(c.g) * 255) + ", "
    + Math.round(clamp01(c.b) * 255) + ")"
}

function rgba(c, a) {
  if (!valid(c)) return null
  return "rgba(" + Math.round(clamp01(c.r) * 255) + ", "
    + Math.round(clamp01(c.g) * 255) + ", "
    + Math.round(clamp01(c.b) * 255) + ", " + clampAlpha(a).toFixed(3) + ")"
}

function hsl(c, a) {
  if (!valid(c)) return null
  const h = rgbToHsl(c.r, c.g, c.b)
  return "hsl(" + Math.round(h.h) + ", " + Math.round(h.s * 100) + "%, "
    + Math.round(h.l * 100) + "%)"
}

function hsla(c, a) {
  if (!valid(c)) return null
  const h = rgbToHsl(c.r, c.g, c.b)
  return "hsla(" + Math.round(h.h) + ", " + Math.round(h.s * 100) + "%, "
    + Math.round(h.l * 100) + "%, " + clampAlpha(a).toFixed(3) + ")"
}

function hsv(c, a) {
  if (!valid(c)) return null
  const h = rgbToHsv(c.r, c.g, c.b)
  return "hsv(" + Math.round(h.h) + ", " + Math.round(h.s * 100) + "%, "
    + Math.round(h.v * 100) + "%)"
}

function hsva(c, a) {
  if (!valid(c)) return null
  const h = rgbToHsv(c.r, c.g, c.b)
  return "hsva(" + Math.round(h.h) + ", " + Math.round(h.s * 100) + "%, "
    + Math.round(h.v * 100) + "%, " + clampAlpha(a).toFixed(3) + ")"
}

// Serialize parsed channels in one of the FORMATS names; null when the
// format is unknown or the channels are unusable.
function format(c, fmt, a) {
  if (!valid(c)) return null
  switch (fmt) {
    case "hex": return hex8(c, a)
    case "rgb": return rgb(c, a)
    case "rgba": return rgba(c, a)
    case "hsl": return hsl(c, a)
    case "hsla": return hsla(c, a)
    case "hsv": return hsv(c, a)
    case "hsva": return hsva(c, a)
  }
  return null
}

// Every supported serialization of c at alpha a, keyed by format name;
// null serializers are skipped.
function allFormats(c, a) {
  const out = {}
  for (let i = 0; i < FORMATS.length; i++) {
    const s = format(c, FORMATS[i], a)
    if (s !== null) out[FORMATS[i]] = s
  }
  return out
}

// The format a color code is written in, or null when the string is not a
// color code at all. The inverse of format(): format() renders a color in
// one of the FORMATS, this names the one a code was typed in, so a picker
// can follow the spelling its user chose.
//
// A four-channel expression is the "a" spelling of its family whether or
// not it was typed that way: rgb(1,2,3,0.5) carries an alpha, and the
// format that can print it back is rgba.
function detectFormat(str) {
  const s = String(str === undefined || str === null ? "" : str).trim()
  if (s === "") return null
  // A spelling that does not parse is not a color code, so it has no
  // format: "rgb(1,2)" is a broken rgb, not an rgb.
  if (parse(s) === null) return null
  if (s.charAt(0) === "#") return "hex"
  const low = s.toLowerCase()
  if (/^rgba?\s*\(/.test(low)) return _channelCount(s) === 4 ? "rgba" : "rgb"
  if (/^hsla?\s*\(/.test(low)) return _channelCount(s) === 4 ? "hsla" : "hsl"
  if (/^hsva?\s*\(/.test(low)) return _channelCount(s) === 4 ? "hsva" : "hsv"
  // A hex code without its hash is a hex code: the parser reads it, and
  // so does this.
  if (/^[0-9a-f]+$/.test(low)) return "hex"
  return null
}



// Integer-channel contrast pick for text on a color swatch.
function contrastText(c) {
  if (!valid(c)) return "#ffffff"
  const r = Math.round(clamp01(c.r) * 255)
  const g = Math.round(clamp01(c.g) * 255)
  const b = Math.round(clamp01(c.b) * 255)
  const lum = (299 * r + 587 * g + 114 * b) / 1000
  return lum > 127 ? "#000000" : "#ffffff"
}

// --- launcher extras (color plugin) ---

// The chip order without the hex the user typed into the input field.
var DISPLAY_FORMATS = []
for (let i = 0; i < FORMATS.length; i++) {
  if (FORMATS[i] !== 'hex') DISPLAY_FORMATS.push(FORMATS[i])
}

function isPotentialColor(q) {
  if (typeof q !== 'string') return false
  const s = q.trim()
  if (s === '') return false
  if (s.charAt(0) === '#') return true
  const low = s.toLowerCase()
  if (/^rgba?\s*\(/.test(low)) return true
  if (/^hsla?\s*\(/.test(low)) return true
  if (/^hsva?\s*\(/.test(low)) return true
  return false
}

function isColorIncomplete(q) {
  function _validChannelPrefix(t) {
    if (t === '') return true
    let u = t
    const pct = u.charAt(u.length - 1) === '%'
    if (pct) u = u.substring(0, u.length - 1)
    if (u === '') return true
    if (!/^[0-9]*\.?[0-9]*$/.test(u)) return false
    return true
  }
  if (typeof q !== 'string') return false
  const s = q.trim()
  if (s === '') return false
  if (s.charAt(0) === '#') {
    const h = s.substring(1).trim()
    if (h === '') return true
    if (!/^[0-9a-fA-F]+$/.test(h)) return false
    const len = h.length
    if (len > 8) return false
    if (len === 3 || len === 4 || len === 6 || len === 8) return false
    return true
  }
  const m = s.match(/^(rgba?|hsla?|hsva?)\s*\(/i)
  if (!m) return false
  const openIdx = s.indexOf('(')
  if (openIdx < 0) return false
  const lastParen = s.lastIndexOf(')')
  if (lastParen !== -1 && lastParen !== s.length - 1) return false
  if ((s.match(/\)/g) || []).length > 1) return false
  const inner = lastParen === -1
    ? s.substring(openIdx + 1)
    : s.substring(openIdx + 1, lastParen)
  const parts = inner.trim() === '' ? [] : inner.split(',')
  const name = m[1].toLowerCase()
  const expected = (name === 'rgba' || name === 'hsla' || name === 'hsva') ? 4 : 3
  if (parts.length > expected) return false
  for (let i = 0; i < parts.length; i++) {
    if (!_validChannelPrefix(parts[i].trim())) return false
  }
  if (parse(s) !== null) return false
  return true
}

function tryColor(q) {
  if (typeof q !== 'string') return null
  const input = q.trim()
  if (input === '') return null
  if (!isPotentialColor(input)) return null
  const c = parse(input)
  if (c === null) return null
  const alpha = clampAlpha(c.a)
  const formats = []
  for (let i = 0; i < DISPLAY_FORMATS.length; i++) {
    const fmt = DISPLAY_FORMATS[i]
    const text = format(c, fmt, alpha)
    if (text !== null) formats.push({ fmt: fmt, text: text })
  }
  return {
    formats: formats,
    hex: hex6(c),
    edge: contrastText(c),
    input: input,
    alpha: alpha,
  }
}
