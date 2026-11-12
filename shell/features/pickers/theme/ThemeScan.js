.pragma library
.import "../../../common/math/Color.js" as Color

// Shared reads for the theme surfaces. The picker and the remover are two
// singletons in one feature: the picker turns colors.list into the preview
// palette, while the remover reads a directory's display name and swatches.
// Keeping the parsers here means both sides read colors.list the same way.

// Display name from a directory name: strip the packaging affixes first (a
// clone dir is often vibranium-theme-foo), then capitalize what is left.
function displayName(folder) {
  let clean = String(folder)
  clean = clean.replace("vibranium-theme-", "").replace("-vibranium-theme", "")
  clean = clean.replace("theme-vibranium-", "").replace("-theme-vibranium", "")
  return capWords(clean)
}

// "catppuccin-mocha" -> "Catppuccin Mocha". Empty segments drop rather than
// producing a leading or doubled space.
function capWords(s) {
  const parts = String(s).split("-")
  let out = ""
  for (let i = 0; i < parts.length; i++) {
    const p = parts[i]
    if (p === "") continue
    if (out !== "") out += " "
    out += p.charAt(0).toUpperCase() + p.slice(1).toLowerCase()
  }
  return out
}

// The seven accent keys a theme file may declare, in the order they are
// read. Anything else in the file is not part of the palette: the keys are
// the file's contract, and a stray hex in a comment would otherwise become
// a swatch.
const PALETTE_KEYS = ["red", "green", "blue", "yellow", "orange", "cyan", "purple"]

// Every KEY = "#rrggbb" pair a theme file declares, keyed by name. The
// swatch reader below only keeps the accents the row paints; the preview
// needs the background and foreground too, because the skeleton is drawn in
// the theme's own two anchors rather than on top of the live shell palette.
// Blank lines and `#` comments are skipped, as is any line with no `=`.
function extractColors(text) {
  const out = {}
  if (!text) return out
  const lines = String(text).split("\n")
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i].trim()
    if (line === "" || line.charCodeAt(0) === 35) continue
    const eq = line.indexOf("=")
    if (eq < 0) continue
    const key = line.substring(0, eq).trim().toLowerCase()
    if (key === "") continue
    const m = line.substring(eq + 1).match(/#[0-9a-fA-F]{6}/)
    if (m) out[key] = m[0].toLowerCase()
  }
  return out
}

// The palette one skeleton preview paints with. It mirrors the generated
// qs.json's ramp: background_1/2/3 are the background walked toward the
// foreground in three steps, and foreground_1 is the foreground walked back
// toward the background. A light theme therefore gets darker cards and a
// dark theme lighter ones from the same rule. Missing leaves fall back to
// neutral dark values, so a malformed palette still renders a skeleton
// instead of throwing.
function preview(colors, isLight) {
  const c = colors && typeof colors === "object" ? colors : {}
  const bg = c.background || (isLight ? "#faf4ed" : "#141414")
  const fg = c.foreground || (isLight ? "#464261" : "#dfdfdf")
  const leaf = (key, fallback) => c[key] || fallback
  return {
    bg: bg,
    sunken: mix(bg, fg, 0.03),
    raised: mix(bg, fg, 0.06),
    panel: mix(bg, fg, 0.12),
    edge: mix(bg, fg, 0.18),
    // One step brighter than the hairline used inside surfaces: this is the
    // frame colour that has to separate a window from the wallpaper.
    windowEdge: mix(bg, fg, 0.28),
    fg: fg,
    muted: mix(fg, bg, 0.42),
    faint: mix(fg, bg, 0.66),
    accent: leaf("accent", "#cba6f7"),
    red: leaf("red", "#f38ba8"),
    green: leaf("green", "#a6e3a1"),
    yellow: leaf("yellow", "#f9e2af"),
    blue: leaf("blue", "#89b4fa"),
    cyan: leaf("cyan", "#94e2d5"),
    orange: leaf("orange", "#eba0ac"),
    purple: leaf("purple", "#cba6f7"),
    light: isLight === true
  }
}

function mix(a, b, t) {
  const out = Color.mix(a, b, t)
  return out === "" ? a : out
}

// The swatches a theme file declares, lowercase, at most one per key.
// Blank lines and `#` comments are skipped, as is any line with no `=`.
function extractPalette(text) {
  if (!text) return []
  const want = {}
  for (let i = 0; i < PALETTE_KEYS.length; i++) want[PALETTE_KEYS[i]] = 1
  const lines = text.split("\n")
  const out = []
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i].trim()
    if (line === "" || line.charCodeAt(0) === 35) continue
    const eq = line.indexOf("=")
    if (eq < 0) continue
    const key = line.substring(0, eq).trim()
    if (!want[key]) continue
    const m = line.match(/#[0-9a-fA-F]{6}/)
    if (m) out.push(m[0].toLowerCase())
    if (out.length >= PALETTE_KEYS.length) break
  }
  return out
}
