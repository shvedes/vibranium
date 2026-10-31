// Shared GTK settings.ini parsing (qs.common.settings).
//
// Single home for the cursor theme/size reads duplicated in
// MiscSettings and CursorPicker: one parser, one quote rule, one
// fallback contract. The shell's own cursor-theme.json state stays the
// first source; this file is the shared INI fallback, never the
// primary. Pure JS, pragma library, no Qt imports - unit-tested in
// tests/shell/suites/js/gtk-settings.test.mjs.
.pragma library

// One gtk-3.0/settings.ini -> flat key map. Matches the historical
// reads exactly: the key must open the line (no leading whitespace),
// first occurrence wins, surrounding whitespace trimmed, one optional
// double-quote pair stripped. No section awareness - the historical
// reads never had any, and adding it would change what a stray
// duplicate resolves to.
function parseIni(text) {
  const out = Object.create(null)
  const lines = String(text === undefined || text === null ? "" : text).split("\n")
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (line === "" || line.charAt(0) === " " || line.charAt(0) === "\t" || line.charAt(0) === "#") continue
    const eq = line.indexOf("=")
    if (eq < 0) continue
    const key = line.substring(0, eq).trim()
    if (key === "" || key.indexOf(" ") >= 0 || (key in out)) continue
    let v = line.substring(eq + 1).trim()
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) v = v.slice(1, -1)
    out[key] = v
  }
  return out
}

function _str(map, key) {
  const v = map[key]
  return typeof v === "string" ? v : ""
}

// gtk-cursor-theme-name, or the fallback when absent/empty.
function cursorThemeOf(text, fallback) {
  const v = _str(parseIni(text), "gtk-cursor-theme-name").trim()
  if (v !== "") return v
  return typeof fallback === "string" ? fallback : ""
}

// gtk-cursor-theme-size, or the fallback when absent/unparseable.
function cursorSizeOf(text, fallback) {
  const v = _str(parseIni(text), "gtk-cursor-theme-size").trim()
  const n = parseInt(v, 10)
  if (!isNaN(n)) return n
  return typeof fallback === "number" && isFinite(fallback) ? fallback : 0
}

if (typeof module !== "undefined") {
  module.exports = {
    parseIni: parseIni,
    cursorThemeOf: cursorThemeOf,
    cursorSizeOf: cursorSizeOf
  }
}
