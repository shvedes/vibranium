// Pure policy for the notification daemon: the timeout rule, the progress
// hint, the icon tone hint, the meta line, the clock, and the two orderings
// a pile is built from. No Qt and no Quickshell imports, so every rule here is
// unit-drivable without a QML engine; Notifications.qml owns the objects these
// functions are asked about and nothing in this file owns one.
.pragma library

.import "../../common/text/Format.js" as Format
.import "../../common/text/Clock.js" as ClockFmt
.import "../../common/theme/DeviceIcons.js" as DeviceIcons

// A notification with no deadline at all. The D-Bus `expire_timeout` of 0
// means "never expire", and a critical notification is persistent whatever it
// asked for, so both legs answer with this rather than with a number a Timer
// could use.
const NO_TIMEOUT = 0

// "There is no progress bar", as distinct from "there is a bar at 0%". A
// fraction would make the two the same number, and the card would have to
// guess which one it is looking at.
const NO_PROGRESS = -1

// The pile dock on one side: the bar's own dock, adopted by an open
// island's far edge when the island shares the pile's screen. `barDock` is
// the dock without any island (bar plus one rhythm margin); `sharing` is
// true only for an open island on the same screen; `islandEdge` is the
// island's far edge in pile coordinates (bottom edge for a top dock, top
// edge mirrored through the window height for a bottom dock); `margin` is
// the rhythm between island and pile. The max() is the whole policy: a
// smaller island never pulls the pile up into the bar, and garbage numbers
// fall back to the bar dock rather than parking the pile off screen.
function pileDock(barDock, sharing, islandEdge, margin) {
  const base = Number(barDock)
  const baseOk = isFinite(base) && base >= 0 ? base : 0
  if (sharing !== true) return baseOk
  const edge = Number(islandEdge)
  const gap = Number(margin)
  if (!isFinite(edge) || edge < 0) return baseOk
  const want = edge + (isFinite(gap) && gap > 0 ? gap : 0)
  return want > baseOk ? want : baseOk
}

// Deadline in milliseconds, or 0 for none.
//
// `expireTimeout` is the raw D-Bus `expire_timeout`, in MILLIMECONDS; the
// generated Quickshell documentation calls the field seconds and is wrong,
// and `notify-send -t` is milliseconds too. The order of the legs is the
// policy: urgency wins outright (a critical notification is persistent by
// definition, so its timeout is not a request the daemon can accept), then
// the D-Bus "server default" (-1), then the client's own figure.
function timeoutMs(expireTimeout, isCritical, defaultMs) {
  if (isCritical === true) return NO_TIMEOUT
  const raw = Number(expireTimeout)
  const fallback = Number(defaultMs)
  const server = isFinite(fallback) && fallback > 0 ? fallback : NO_TIMEOUT
  // A value the client never sent is the same leg as -1 rather than a claim
  // that the notification is permanent: silence about the deadline is not a
  // request for no deadline.
  if (!isFinite(raw)) return server
  if (raw < 0) return server
  if (raw === 0) return NO_TIMEOUT
  return raw
}

// The progress fraction in [0, 1], or NO_PROGRESS when the notification
// carries no progress hint.
//
// Both hint spellings are read, `value` first and then `progress`, because
// senders disagree about which one they send and a bar that hides a hint
// that was sent is worse than one that ignores a duplicate. Both are
// FRACTIONS by contract (`notify-send -h double:value:0.4` is 40%), but the
// de-facto volume convention sends PERCENTS (`-h int:value:42`); values
// above 1 are therefore read as percents and scaled down, so a volume
// stream does not clamp to a permanent 100%.
function progressOf(hints) {
  if (!hints || typeof hints !== "object") return NO_PROGRESS
  let raw = hints.value
  if (raw === undefined || raw === null) raw = hints.progress
  if (raw === undefined || raw === null) return NO_PROGRESS
  let n = Number(raw)
  if (!isFinite(n)) return NO_PROGRESS
  // Percent-scale input (e.g. int:value 0-100): scale to a fraction before
  // clamping. Fraction input (0-1) passes through unchanged.
  if (n > 1) n = n / 100
  // Clamped rather than trusted: a sender that streams past 1 must not fill
  // more than the bar, and one that streams below 0 must not run it
  // backwards. The value is still a fraction either way.
  return Math.min(1, Math.max(0, n))
}

// No volume lane: the `vol` snapshot field's answer when the sender sent no
// `x-vb-vol` hint. Kept distinct from the level 0, which is a real
// lane at silence, the same way NO_PROGRESS is distinct from a bar at 0%.
const VOL_NONE = -1

// The volume-lane level in percent, or VOL_NONE when the notification
// carries no volume hint.
//
// `x-vb-vol` is PERCENT-scale (0..100), the unit notify-send speaks
// in (`notify-send -h int:x-vb-vol:42`); unlike progressOf there is
// no fraction leg, so values are clamped, not rescaled - a double 0.5 is
// half a percent, not half the lane. Rounded to an int: the card reserves
// a three-digit percent column and the island tiers read thirds, neither
// of which has anything to say about fractions of a percent. A boolean or
// blank hint is no lane rather than a level, whatever Number() would make
// of it.
function volOf(hints) {
  if (!hints || typeof hints !== "object") return VOL_NONE
  const raw = hints["x-vb-vol"]
  if (typeof raw === "boolean") return VOL_NONE
  if (typeof raw === "string" && raw.trim() === "") return VOL_NONE
  if (raw === undefined || raw === null) return VOL_NONE
  const n = Number(raw)
  if (!isFinite(n)) return VOL_NONE
  return Math.round(Math.min(100, Math.max(0, n)))
}

// Lenient truth test for a hand-set boolean-ish hint: a boolean, a
// nonzero number, or a "true"/"1"/"yes" string (case- and
// space-insensitive). Everything else - including an absent hint - is
// false. One reading so every flag hint below answers the same way.
function isHintTrue(hints, key) {
  if (!hints || typeof hints !== "object") return false
  const raw = hints[key]
  if (typeof raw === "boolean") return raw
  if (typeof raw === "number") return isFinite(raw) && raw !== 0
  if (typeof raw === "string") {
    const s = raw.trim().toLowerCase()
    return s === "true" || s === "1" || s === "yes"
  }
  return false
}

// Whether the volume lane reads muted: the speaker tiers go volume-off and
// the icon takes the red accent, while the lane keeps filling to the level
// - the OSD's own split (OSD._iconFor vs the value it fills with).
function volMutedOf(hints) {
  if (!hints || typeof hints !== "object") return false
  return isHintTrue(hints, "x-vb-vol-muted")
}

// Whether the card hides its meta line (clock + sender) for this
// notification. An OSD-style card - title plus volume lane - has nothing to
// say about when it arrived, so the sender says so per notification
// (`-h boolean:x-vb-hide-meta:true`) instead of the daemon growing
// another global switch with settings UI to house it.
function hideMetaOf(hints) {
  if (!hints || typeof hints !== "object") return false
  return isHintTrue(hints, "x-vb-hide-meta")
}

// Level icon for a 0..1 volume fraction, canonicalized in
// common/theme/DeviceIcons.js so the card, the Audio service and the OSD
// resolve through one table instead of three mirrors.
function volIconFor(frac, muted) {
  return DeviceIcons.volumeIconFor(frac, muted)
}

// Wave groups kept opaque on the tiered volume-max glyph, canonicalized
// in common/theme/DeviceIcons.js for the same reason as volIconFor.
function volDimTiersFor(frac, muted) {
  return DeviceIcons.volumeDimTiersFor(frac, muted)
}

// The palette key the card paints a name-resolved icon in, or "" for the
// tone Icons.url already defaults to. The other hint reader, and shaped like
// it: "" whenever there is nothing to read.
//
// `x-vb-icon-color` is a palette KEY and not a hex because the card
// hands it to Icons.url, which resolves a key against the LIVE palette - so a
// card stays correctly toned across a theme switch, where a hex would be
// frozen to whatever the theme was when the hint was sent. The vocabulary is
// the palette's own keys and nothing rejects a key outside it: Icons.url
// paints whatever Theme.color answers for the key, and for a key the palette
// does not carry that answer is #000000, not the default foreground_0.
//
// The value is a string because the hint is declared as one on the wire
// (`notify-send -h string:x-vb-icon-color:orange`), and anything else
// under that name is not a palette key whatever the sender meant by it.
function iconColorOf(hints) {
  if (!hints || typeof hints !== "object") return ""
  const raw = hints["x-vb-icon-color"]
  if (typeof raw !== "string") return ""
  // Trimmed, so a hint of only whitespace is no tone rather than a key that
  // resolves to nothing.
  return raw.trim()
}



// The synchronous replace tag a notification carries, or "" for none.
//
// The daemon-side replacement a numeric `notify-send -r ID` cannot give:
// Quickshell allocates a fresh server id for every Notify whose replaces_id
// matches nothing live (spec section 1.2 says the reply should echo a
// non-zero replaces_id, Quickshell 0.3.x returns nextId++ instead), so a
// fixed `-r 2` never stabilises - each send creates a new card. A tag does
// not depend on server ids at all: a new notification carrying the same tag
// retires the live card(s) carrying it, atomically, and the timer restarts.
//
// Three names, one meaning. `x-dunst-stack-tag` is the conventional
// stack-tag hint every `notify-send -h string:...` caller can already
// send, `x-canonical-private-synchronous` is the mako/notify-osd alias
// for the same slot, and `x-vb-tag` is the shell's own name for it. The
// first non-empty one wins, so a sender that sets both the standard hint
// and the alias does not key twice. String-only, like iconColorOf: the
// hint is declared as a string on the wire and anything else under these
// names is not a tag.
function replaceTagOf(hints) {
  if (!hints || typeof hints !== "object") return ""
  const keys = ["x-dunst-stack-tag", "x-canonical-private-synchronous", "x-vb-tag"]
  for (let i = 0; i < keys.length; i++) {
    const raw = hints[keys[i]]
    if (typeof raw !== "string") continue
    const tag = raw.trim()
    if (tag !== "") return tag
  }
  return ""
}

// The separator between the two parts of the meta line, and the spaces that
// clear it.
//
// A hyphen, at the line's own size and the line's own colour, because it is a
// separator rather than punctuation: it says the time and the sender are two
// fields of one card, and it has no business being more visible than either of
// them. A glyph given its own size and colour reads as a third thing on the
// line, which is the opposite of what a separator is for - and a mark set off
// the baseline by its own box is not aligned with the words it sits between.
//
// One Text draws the whole line, which is only possible because the separator is
// typographically indistinguishable from the words around it: the card's other
// fields are PlainText, so joining the parts into one string cannot put
// StyledText between a sender's name and the rest.
const META_SEPARATOR = " - "

// The card's meta line as one string: "<time> - from <app>", time first.
//
// The separator is inserted between what is actually there rather than around
// both parts blindly: a notification with no app name keeps the clock alone, one
// with no recorded arrival keeps `from <app>` alone, and neither keeps nothing -
// so no card ever draws a hyphen between two absent halves. The card reads "" as
// "draw no line".
//
// `textFormat: PlainText` on the card means these are literal characters, so
// trimming is what keeps a padded sender name from reading as a wider gap
// around the separator.
function metaLine(clock, appName) {
  const time = String(clock ?? "").trim()
  const app = String(appName ?? "").trim()
  const parts = []
  if (time !== "") parts.push(time)
  if (app !== "") parts.push("from " + app)
  return parts.join(META_SEPARATOR)
}

// The card's clock, canonicalized in common/text/Clock.js so the card
// and the bar clock share one format instead of two that look alike.
function clockLabel(atMs, use12h) {
  return ClockFmt.clockLabel(atMs, use12h)
}

// Two-digit zero padding, canonicalized in common/text/Format.js.
// Declared above its caller because this tree's rule is that a
// declaration comes before its first use, not after it.
function pad2(n) {
  return Format.pad2(n)
}

// The array unchanged. Index 0 is the oldest, which is the order the
// controller stores every notification in, and this function names that
// invariant instead of restating it at each call site.
//
// Not a defensive copy: every caller has just built the array or owns it, and
// a copy per pile read would be an array the shell then has to garbage
// collect on every notification.
function arrivalOrder(entries) {
  return Array.isArray(entries) ? entries : []
}

// Visual top-to-bottom order of the pile.
//
// Docked top, the newest goes at the HEAD: the column starts below the bar
// and grows downward, so the newest is the card nearest the bar and the pile
// reads newest-first. Docked bottom the column grows upward toward the bar, so
// the head is the OLDEST card and the newest sits nearest the bar; that is
// the same array, unreversed, and reversing it there would stack new
// notifications at the wrong end of the pile.
function pileOrder(entries, atTop) {
  const list = Array.isArray(entries) ? entries : []
  if (atTop !== true) return list
  return list.slice().reverse()
}

// Newest first, bounded at `limit`.
//
// A notification whose id is already recorded is overwritten where it stands
// rather than appended: a `-r` replacement is the same notification with new
// content (the D-Bus server updates the object in place and emits nothing),
// so the history has to end up with ONE record of it. Appending would leave
// the old content in the history forever and push the newer record out of the
// bound.
//
// A snapshot carrying a replace tag additionally evicts every OTHER row
// carrying the same tag: a tag replacement arrives as a NEW server id (the
// old card is retired, see Notifications._admit), so id-overwrite alone
// would keep one row per streamed update and a volume drag would fill the
// history. One tag, one row - the tag is the notification's identity for
// history purposes, the server id only its current incarnation.
function pushHistory(history, snapshot, limit) {
  const list = Array.isArray(history) ? history.slice() : []
  const cap = Number(limit)
  const max = isFinite(cap) && cap > 0 ? Math.floor(cap) : 0
  if (!snapshot || typeof snapshot !== "object") return list
  const id = Number(snapshot.id)
  const tag = typeof snapshot.replaceTag === "string" ? snapshot.replaceTag.trim() : ""
  if (tag !== "") {
    for (let i = list.length - 1; i >= 0; i--) {
      const row = list[i]
      if (!row || typeof row !== "object") continue
      if (isFinite(id) && Number(row.id) === id) continue
      const rowTag = typeof row.replaceTag === "string" ? row.replaceTag.trim() : ""
      if (rowTag === tag) list.splice(i, 1)
    }
  }
  const at = isFinite(id) ? list.findIndex(row => Number(row && row.id) === id) : -1
  if (at >= 0) list[at] = snapshot
  else list.unshift(snapshot)
  // Oldest out first: the bound is on how many records are kept, not on how
  // far back they reach, and dropping from the tail is the only end a
  // newest-first list can lose from.
  while (max > 0 && list.length > max) list.pop()
  return list
}