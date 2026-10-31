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
  return t.substring(0, m - 3) + "..."
}

// Path titles cut from the FRONT so the discriminating tail survives:
// ".../reports/q3-summary.pdf". Cuts land on a slash when one is near.
// Canonical home of the ClipboardLib truncatePath.
function truncatePath(path, max) {
  const p = String(path)
  const m = max || 48
  if (p.length <= m) return p
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
