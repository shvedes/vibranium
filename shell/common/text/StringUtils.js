// Shared string helpers: JSONC stripping, shell quoting and markup.
//
// Single source for the three historically duplicated helpers in
// SettingsLib / MenuLib / LauncherLib and the launcher plugins, and the
// home of the link treatment a rich text body is drawn with.
// Pure JS, pragma library, no Qt imports - unit-testable and importable
// from any .js module via `.import "StringUtils.js" as SU`.
.pragma library

function stripJsonc(raw) {
  return String(raw || "")
    .replace(/^[ \t]*\/\/[^\n]*(\n|$)/gm, "")
    .replace(/,(\s*[}\]])/g, "$1")
}

function shellQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'"
}

// Directory part of a path, "" when the path carries none. A leading
// "/name" is a root-level entry with no directory of its own, and a bare
// name has none either; the caller decides what that absence means.
// Canonical home of the menu's pathDirname.
function dirname(path) {
  const p = String(path ?? "")
  const i = p.lastIndexOf("/")
  return i > 0 ? p.substring(0, i) : ""
}

// Parent directory with the filesystem root kept distinct: "/name" answers
// "/" rather than the "" dirname() gives for an entry whose directory is the
// root itself. A bare name has no parent and answers "".
function parentDir(path) {
  const p = String(path ?? "")
  const i = p.lastIndexOf("/")
  if (i < 0) return ""
  return i === 0 ? "/" : p.substring(0, i)
}

// Last path segment, "" when the path ends in a separator (the same answer
// the split("/").pop() idiom gives). A path with no separator is its own
// basename.
function basename(path) {
  const p = String(path ?? "")
  const i = p.lastIndexOf("/")
  return p.substring(i + 1)
}

// Lowercased extension of a path, without the dot, "" when it has none.
// A dot in a directory is not an extension, and a leading dot in the name
// is one - the full-path contract FileIcons, ImageExts and the image viewer
// share (".png" -> "png").
function extname(path) {
  const p = String(path ?? "")
  const slash = p.lastIndexOf("/")
  const dot = p.lastIndexOf(".")
  if (dot <= slash || dot < 0) return ""
  return p.substring(dot + 1).toLowerCase()
}

// Path with its lowercased final extension removed, dot included, or the
// path itself when it carries none. Uses the same dot rule as extname(),
// so a dot in a directory is not an extension.
function stem(path) {
  const p = String(path ?? "")
  const slash = p.lastIndexOf("/")
  const dot = p.lastIndexOf(".")
  if (dot <= slash || dot < 0) return p
  return p.substring(0, dot)
}

// Join a directory and an entry name with exactly one separator. An empty
// directory names the entry itself, so a vault root and a child share one
// spelling.
function joinPath(dir, name) {
  const d = String(dir ?? "")
  const n = String(name ?? "")
  if (d === "") return n
  return d.endsWith("/") ? d + n : d + "/" + n
}

// A leading "~" or "~/" expanded against `home`.
//
// Only the whole-home and home-prefix forms expand; "~user" is not a lookup
// this shell performs. Missing home leaves the text as it stands, so the
// caller decides what an unresolvable home means - the file opener refuses
// the candidate, a clipboard row keeps the text it was copied with.
function expandHome(text, home) {
  const p = String(text ?? "")
  const h = String(home ?? "")
  if (h === "") return p
  if (p === "~") return h
  if (p.startsWith("~/")) return h + p.substring(1)
  return p
}

// One path or file-name segment made safe to join onto a directory: every
// character outside the portable set becomes "_". The wall-clock sanitizer
// keeps "." and "-" so an extension survives; a separator cannot, because a
// remote name must stay a single leaf under the destination directory.
//
// Canonical home of the wallpaper drop's _sanitizeBase and the per-screen
// file-name segment the bar view builds.
function sanitizeSegment(name) {
  return String(name ?? "").replace(/[^A-Za-z0-9._-]/g, "_")
}

// An identifier usable as a registry/claim key: a string with something other
// than whitespace in it. The registries reject everything else, and stating
// that once keeps "empty" and "blank" from being two different answers.
function isNonEmptyId(value) {
  return typeof value === "string" && value.trim() !== ""
}

// True when `path` is a strict descendant of `dir`. A trailing separator on
// `dir` is tolerated, and "/" is the filesystem root rather than a prefix of
// "//".
function isUnder(path, dir) {
  const p = String(path ?? "")
  const d = String(dir ?? "")
  if (d === "") return p !== ""
  const base = d.endsWith("/") ? d : d + "/"
  return p.length > base.length && p.startsWith(base)
}

// True when `path` is `dir` itself or a strict descendant.
function isAtOrUnder(path, dir) {
  return String(path ?? "") === String(dir ?? "") || isUnder(path, dir)
}

function styledMarkup(text) {
  const s = String(text ?? "")
  if (s === "") return ""
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/&lt;(\/?)(b|i|u)&gt;/gi, "<$1$2>")
    .replace(/\n/g, "<br>")
}

// Escape for RichText labels: hostile input that must never break out of
// the markup. NOT styledMarkup - that is a formatter for text that is
// ALREADY markup (it restores &lt;b&gt; to a live <b>), while this is the
// inverse contract where every tag survives as text. Canonical home of
// the Network Model.js escapeHtml; the two agree on every non-markup
// input and disagree on exactly the markup cases.
function escapeHtml(s) {
  return String(s === undefined || s === null ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// Text titles collapse whitespace and cap length, keeping the head -
// the reader already knows how their sentence started. Canonical home of
// the ClipboardLib truncateText.
function truncateText(s, max) {
  const t = String(s).replace(/\s+/g, " ").trim()
  const m = max || 80
  if (t.length <= m) return t
  // Below the ellipsis budget the cut is the cap itself: "..." is three
  // characters and would make a short request longer than asked for.
  if (m <= 3) return t.substring(0, Math.max(0, m))
  return t.substring(0, m - 3) + "..."
}

// Path titles cut from the FRONT so the discriminating tail survives:
// ".../reports/q3-summary.pdf". Cuts land on a slash when one is near.
// Canonical home of the ClipboardLib truncatePath.
function truncatePath(path, max) {
  const p = String(path)
  const m = max || 48
  if (p.length <= m) return p
  // Below the ellipsis budget there is no room for the marker, so the tail
  // is the whole answer rather than a string three characters over the cap.
  if (m <= 3) return p.substring(Math.max(0, p.length - Math.max(0, m)))
  const keep = m - 3 // room for the leading "..."
  const tail = p.substring(p.length - keep)
  const slash = tail.indexOf("/")
  if (slash > 0 && slash < 8) return "..." + tail.substring(slash)
  return "..." + tail
}

// The HTML entities a markup can carry, decoded.
//
// The named ones that turn up in a URL and the numeric form. A name outside
// the table is left as it is: the text reports the href of the anchor under
// the pointer already decoded, so a markup carrying an entity this table
// does not know is a markup whose link cannot be matched to the pointer -
// and decoding it by some other rule would make the two disagree.
var ENTITIES = ({
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: "\u00a0"
})

// A numeric entity's character, or the entity itself when the number is not
// one a character can be.
function codePoint(n, raw) {
  if (!isFinite(n) || n < 0 || n > 0x10ffff) return raw
  return String.fromCodePoint(n)
}

function decodeEntities(s) {
  return String(s ?? "")
    .replace(/&#x([0-9a-fA-F]+);/gi, (m, hex) => codePoint(parseInt(hex, 16), m))
    .replace(/&#(\d+);/g, (m, dec) => codePoint(parseInt(dec, 10), m))
    .replace(/&(amp|lt|gt|quot|apos|nbsp);/g, (m, name) => ENTITIES[name])
}

// An anchor element: the opening tag, the text, the closing tag.
//
// The opening tag is captured whole, so a rewrite keeps the sender's own
// attributes and their quoting. The attribute run lets a quoted value hold a
// ">", which a plain "not a >" run would cut the tag short on.
var ANCHOR_RE = /(<a\b(?:[^>"']|"[^"]*"|'[^']*')*>)([\s\S]*?)(<\/a\s*>)/gi

// The href an anchor tag points at, decoded, or "" when it points at
// nothing.
//
// The value is read out of the tag's own text rather than through a parser:
// a body is a sender's markup, not a document, and the only question asked
// of it is which anchor points where.
//
// The decode is not optional. The text reports the DECODED href of the
// anchor under the pointer - the parser resolves &amp; before the anchor is
// stored - so a markup that spells its query separator &amp; has to be
// decoded the same way, or the two never match and the link under the
// pointer is not the link that is marked.
function anchorHref(tag) {
  const m = /\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/i.exec(tag)
  if (!m) return ""
  const raw = m[1] !== undefined ? m[1] : (m[2] !== undefined ? m[2] : m[3])
  return decodeEntities(raw)
}

// The markup with the anchor that points at `href` underlined.
//
// Every anchor with that href is underlined, not only the first: two
// anchors can point at the same place, and the href alone does not say
// which of them the pointer is on, so underlining the first one would mark
// the wrong one as often as not.
//
// An anchor with no text of its own is left alone - there is nothing to
// underline, and an empty <u> would only add a pair of tags.
function underlineAnchor(markup, href) {
  const body = String(markup ?? "")
  const target = String(href ?? "")
  if (body === "" || target === "") return body
  return body.replace(ANCHOR_RE, (match, open, label, close) => {
    if (label === "") return match
    if (anchorHref(open) !== target) return match
    return open + "<u>" + label + "</u>" + close
  })
}

// The markup a rich text body is drawn from, with the shell's link
// treatment on it.
//
// `color` is what the anchors are painted in, and `hovered` is the href of
// the link under the pointer - "" when the pointer is on none of them.
//
// The treatment is a stylesheet in front of the sender's markup rather than
// a rewrite of every anchor in it: the sheet reaches the anchors the sender
// wrote and the ones they did not, and the underline is a decoration on the
// hovered run, so no part of the text moves when the pointer arrives.
//
// The sheet comes FIRST because the parser reads the rules as it walks the
// markup: a rule behind an anchor does not reach that anchor.
function linkMarkup(markup, color, hovered) {
  const body = String(markup ?? "")
  const tone = String(color ?? "").trim()
  const rules = ["a { text-decoration: none; }"]
  if (tone !== "") rules.push("a { color: " + tone + "; }")
  const sheet = "<style>" + rules.join(" ") + "</style>"
  const target = String(hovered ?? "")
  if (target === "") return sheet + body
  return sheet + underlineAnchor(body, target)
}
