.pragma library

// Shared reads for the theme pages. The picker and the remover are two
// singletons in one feature that answer the same two questions about a
// theme directory - what to call it, and which swatches it declares - and
// each had its own copy of both. A page that renamed a theme one way and
// the other page another way was a bug waiting for a user to hit the
// second page.

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
