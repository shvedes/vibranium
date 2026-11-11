.pragma library

.import "../../../common/text/StringUtils.js" as SU
.import "../../../common/text/Format.js" as Format

// Metadata for the image viewer: which formats it opens, what colour each
// format family gets, and the strings its status bar prints.
//
// This is a library rather than bindings inside the window for two reasons.
// The format tables have to agree - the folder listing, the status dot and the
// vector path all answer "what is this file" - and one table per question is
// how they stop agreeing. And the status line is string work: it is built and
// read many times per second while a pointer moves, so it belongs in plain
// functions that a binding can call, not in a tree of Text items each holding
// its own conditional expression.

// Extensions the viewer lists and opens. Mirrors the FolderListModel filter
// pairs (lower and upper case), kept as one case-insensitive list so the two
// spellings cannot drift apart.
const EXTENSIONS = ["png", "jpg", "jpeg", "bmp", "gif", "webp",
                    "svg", "svgz", "ico", "tif", "tiff"]

// One row per format, carrying its two facts: the status dot's palette key and
// the media type a clipboard offer advertises for it. They describe the same
// set of formats, so they are stated together rather than as two lists that
// could name different extensions.
//
// The hues are palette keys rather than fixed colours so the dot follows the
// active theme: teal/cyan for PNG, amber for JPEG, purple for GIF, blue for
// WebP, orange/yellow for SVG, neutral for BMP, green for ICO and pink for
// TIFF. The families match what file managers and editors use for the same
// formats; the exact tone is the theme's to decide.
const TYPES = {
  png:  { key: "cyan",   mime: "image/png" },
  jpg:  { key: "orange", mime: "image/jpeg" },
  jpeg: { key: "orange", mime: "image/jpeg" },
  gif:  { key: "purple", mime: "image/gif" },
  webp: { key: "blue",   mime: "image/webp" },
  svg:  { key: "yellow", mime: "image/svg+xml" },
  svgz: { key: "yellow", mime: "image/svg+xml" },
  bmp:  { key: "white",  mime: "image/bmp" },
  ico:  { key: "green",  mime: "image/vnd.microsoft.icon" },
  tif:  { key: "pink",   mime: "image/tiff" },
  tiff: { key: "pink",   mime: "image/tiff" }
}

// The FolderListModel name filter pairs for every extension above.
function nameFilters() {
  const out = []
  for (let i = 0; i < EXTENSIONS.length; i++) {
    out.push("*." + EXTENSIONS[i])
    out.push("*." + EXTENSIONS[i].toUpperCase())
  }
  return out
}

// The palette key for a file's format family, "" for a format with no family
// entry (the status dot then falls back to a neutral tone).
function typeKey(fileName) {
  const type = TYPES[SU.extname(fileName)]
  return type === undefined ? "" : type.key
}

// The media type the file's own bytes are offered under, "" for a format the
// table does not name.
function mimeType(fileName) {
  const type = TYPES[SU.extname(fileName)]
  return type === undefined ? "" : type.mime
}

// "3 / 12": the open file's place in its folder, "" when the listing has not
// produced a row for it yet.
function position(index, count) {
  const i = Number(index)
  const n = Number(count)
  if (!(n > 0) || !(i >= 0)) return ""
  return (i + 1) + " / " + n
}

// "1920 x 1080", "" while the source has not reported its extent.
function dimensions(width, height) {
  const w = Number(width)
  const h = Number(height)
  if (!(w > 0) || !(h > 0)) return ""
  return Math.round(w) + " x " + Math.round(h)
}

// Decode-size buckets for vector rasters: the long side snaps to one of these,
// so a live viewport/zoom binding decodes once per bucket instead of per pixel.
// Capped at 4096 a side to bound the texture (4096x4096 RGBA is ~67MB).
function bucketLong(n) {
  const v = Math.ceil(Number(n) || 0)
  if (v <= 256) return 256
  if (v <= 512) return 512
  if (v <= 1024) return 1024
  if (v <= 2048) return 2048
  return 4096
}

// The status bar's cells after the file name, separated by dots: position,
// resolution, zoom, size. A cell with nothing to say is dropped together with
// its separator, so the line never shows a dot between two blanks. The zoom
// cell is always present - it is the one reading that exists without a folder
// listing - and every list starts with a separator, because the file name cell
// is always the first thing on the line.
function statusItems(index, count, width, height, scale, size) {
  const cells = []

  const at = position(index, count)
  if (at !== "") cells.push({ kind: "meta", text: at })

  const extent = dimensions(width, height)
  if (extent !== "") cells.push({ kind: "meta", text: extent })

  cells.push({ kind: "zoom", text: Format.percent(scale) })

  const bytes = Format.formatBinaryFileSize(size)
  if (bytes !== "") cells.push({ kind: "meta", text: bytes })

  const out = []
  for (let i = 0; i < cells.length; i++) {
    out.push({ kind: "sep", text: "" })
    out.push(cells[i])
  }
  return out
}
