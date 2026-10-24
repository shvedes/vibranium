.pragma library

// Pure pile algebra for the bar workspaces module. Everything here answers a
// question the QML cannot answer cheaply on its own: which windows collapse
// into one icon, how wide the resulting pile is, and what to draw when no
// icon could be resolved. No Qt, no Quickshell, no protocol objects: windows
// arrive as plain records and every answer is a number, a string or a fresh
// array, so the whole policy is unit-drivable without a compositor.
//
// The module's three shapes share one geometry vocabulary. Plain and boxes
// use the same fixed two-digit slot width; plain slots sit closer together,
// while boxes touch and use symmetric inner padding.
// Piles on, a slot grows with the apps it holds. All widths and gaps are
// computed here from the same metrics so the strip stays consistent when a
// setting is toggled.

// A pile never shows more than this many icons. Beyond it the remainder
// collapses into a single "+N" chip: a workspace strip that widens without
// bound is the same unusable behaviour the fixed width exists to avoid, and
// the cap is the one place that bound is expressed.
//
// var, not const: a top-level const is not exposed by .pragma library, so
// Model.MAX_ICONS would read undefined in QML.
var MAX_ICONS = 4


// The identity one window groups under, and the one an icon is looked up by,
// are deliberately different. A window's appId is per-app and identical
// across that app's windows, so the exact lower-cased form is the grouping
// key - reducing it further would risk folding two distinct apps together,
// which shows as one app silently standing in for another. Icon lookup is
// the looser problem and gets the looser candidates.
function appKey(appId) {
  return String(appId ?? "").trim().toLowerCase()
}

// Names to try when resolving one app's icon, strongest first.
//
// The full id leads because that is what a window reports and what a
// desktop entry's Icon= most often carries. A reverse-DNS id's last
// component follows, because the icon themes are named for the app and not
// for the domain that registered it: org.telegram.desktop is "telegram" in
// every theme, and the trailing "desktop" is a suffix that carries no name.
// Each candidate is offered in both spellings by the caller, so the set
// stays short and the two case variants are not enumerated here.
function iconCandidates(appId) {
  const id = String(appId ?? "").trim().toLowerCase()
  if (id === "") return []
  const out = [id]
  const trimmed = id.endsWith(".desktop") ? id.slice(0, -7) : id
  const last = trimmed.split(".").filter(p => p.length > 0).pop()
  if (last !== undefined && last !== "" && out.indexOf(last) === -1) out.push(last)
  return out
}

// One entry per distinct app, in the order its first window appeared, each
// carrying how many windows share that identity. The first window of an app
// is the representative: its address is the one a click focuses. `title` is
// carried on the entry and follows the representative, but it is optional -
// a caller that draws no title need not project one, and a projection that
// omitted it would otherwise re-run on every keystroke in any of the
// workspace's windows.
//
// Records arrive as { appId, address, title, activated, urgent }, with every
// field optional. Records with no usable identity are dropped rather than
// collected under an empty key - an unidentifiable window has no icon to
// show and no way to tell it apart from the next one, so a pile of them
// would render as N identical letter tiles. A window with an address but no
// appId keeps its own slot so the workspace still reads as occupied.
function pileItems(records, maxIcons) {
  const cap = maxIcons > 0 ? maxIcons : MAX_ICONS
  const byKey = {}
  const order = []
  for (const rec of records ?? []) {
    if (!rec) continue
    const key = appKey(rec.appId)
    const identity = key !== "" ? key : "addr:" + String(rec.address ?? "")
    if (identity === "addr:") continue
    const existing = byKey[identity]
    if (existing === undefined) {
      const item = {
        key: identity,
        appId: String(rec.appId ?? ""),
        address: String(rec.address ?? ""),
        title: String(rec.title ?? ""),
        count: 1,
        activated: rec.activated === true,
        urgent: rec.urgent === true
      }
      byKey[identity] = item
      order.push(item)
      continue
    }
    existing.count++
    if (rec.urgent === true) existing.urgent = true
    // The representative follows focus: a pile should name the window the
    // user is on, so an activated window takes over the entry it shares.
    if (rec.activated === true && !existing.activated) {
      existing.activated = true
      existing.address = String(rec.address ?? "")
      existing.title = String(rec.title ?? "")
    }
  }
  const overflow = Math.max(0, order.length - cap)
  return { items: overflow > 0 ? order.slice(0, cap) : order, overflow: overflow }
}

// Sizing tokens for one bar. `scale` is the bar's own icon scale
// (Bar.iconScale), so a pile grows with the font preset exactly as the icon
// modules do and the strip never mixes two scales.
//
// The pile icon is deliberately below Bar.iconCanvas: a bar glyph is drawn
// to be read alone at a distance, while a pile icon is one of a row inside a
// 28px-tall pill and competes with its neighbours. A third smaller is what
// keeps three of them legible next to the number.
//
// The returned `gap` is the slot-to-slot spacing and belongs to the strip,
// not to a pile; it is passed in so the plain strip can use its reduced gap,
// boxes can touch, and piles can keep their separate positive spacing without
// metrics() having to know which shape is in play.
function metrics(scale, gap) {
  const s = typeof scale === "number" && isFinite(scale) && scale > 0 ? scale : 1
  return {
    // Between two slots. The plain strip passes its reduced number gap,
    // boxes pass 0 so their backgrounds touch, and piles pass a positive gap
    // because adjacent backgrounds would otherwise read as one slab.
    gap: Math.max(0, gap | 0),
    // Horizontal air inside the pill, each edge.
    pad: Math.round(5 * s),
    // Horizontal air inside NUMBER slots, each edge. Boxes pad like a pill;
    // plain numbers use less air because the padding only separates labels.
    numberPad: Math.max(1, Math.round(2 * s)),
    // The number-to-icons gap, wider than the icon-to-icon gap so the label
    // reads as belonging to the pill rather than to the first icon.
    numGap: Math.max(3, Math.round(5 * s)),
    // Side of one app icon.
    icon: Math.max(8, Math.round(12 * s)),
    // Between two app icons, and between an icon and the overflow chip.
    // A quarter of an icon, not a hair: adjacent app icons have no natural
    // boundary of their own (unlike a bar glyph on transparent background),
    // so a narrow gap reads as one blurred smear rather than as two apps.
    iconGap: Math.max(3, Math.round(3 * s)),
    // The "+N" chip, sized off the icon so it tracks the same scale.
    overflow: Math.max(8, Math.round(11 * s)),
    // The pile's background, as a foreground_0 tint. Both are deliberately
    // faint: the bar sits on a wallpaper, so a strong fill reads as a slab
    // of flat colour and competes with the app icons it is supposed to be
    // framing. The two states differ enough to keep current/occupied legible
    // at a glance without either one going opaque.
    //
    // A tint rather than a palette key: the bar's own background is
    // transparent over the wallpaper, so a solid surface would change hue
    // with whatever is behind it.
    pillFill: 0.06,
    pillFillFocused: 0.13,
    // The boxes shape's resting fill, and the same reasoning as the pile's:
    // a tint of foreground_0, faint enough that the bar still reads as
    // transparent over the wallpaper. Stronger than pillFill because the
    // boxes shape has only two states - filled or empty - and the resting one
    // has to carry the whole "not current" reading on its own, with no
    // occupied tier to sit between.
    boxFill: 0.16,
    // The boxes shape's current fill: a SOLID accent, the one surface in this
    // module that is not a tint. It is the only statement the shape makes
    // about which workspace is current, so it has to be legible rather than
    // faint, and solid is what makes it read as "this one" across a strip of
    // near-invisible ones.
    //
    // Solid accent also means the number on top of it cannot keep its own
    // color: the label resolves against this fill (Ui.contrastOn) rather than
    // assuming the foreground reads on an arbitrary accent.
    boxFocusedFill: "accent",
    // Added to whichever of the two is showing while the cursor is over the
    // pile. An offset rather than a third state, so hover composes with
    // focused and occupied instead of overriding them: the pile you are
    // pointing at always lifts by the same amount and the state underneath
    // still reads. The pill's existing color Behavior glides it, so the lift
    // is a transition rather than a jump.
    pillHover: 0.1
  }
}

// Vertical air inside the pill: the inset above and below the pill's own
// background, so a pile reads as a contained surface rather than as a band
// running the full height of the bar.
//
// This is deliberately NOT a full-height bar: the number-only shape has no
// background at all, so a full-height pill would be a visible slab behind
// the numbers that the module has never drawn. The inset is what makes a
// pile read as a pill, and it is derived from the bar's own height so it
// shrinks with the bar rather than becoming a fixed fraction of it.
function pillHeight(barHeight, s) {
  const scale = typeof s === "number" && isFinite(s) && s > 0 ? s : 1
  const inset = Math.max(2, Math.round(3 * scale))
  return Math.max(8, Math.round(barHeight) - inset * 2)
}

// Corner radius of the pill.
//
// NOT height/2. That is a stadium, and at a 22px pill it rounds the corners
// so far that the shape reads as a lozenge rather than as a workspace chip -
// the number inside stops looking like it sits in a box. A fifth of the pill
// height keeps the corners clearly rounded while the sides and the top and
// bottom edges stay parallel, which is what makes it read as a container
// around its contents.
//
// Derived from the pill height rather than fixed, so it stays proportional
// if the bar height ever stops being constant.
function pillRadius(barHeight, s) {
  return Math.max(3, Math.round(pillHeight(barHeight, s) / 5))
}

// Space between number-only slots. The plain strip uses half its former
// fixed 6px gap; boxes have no margin so their surfaces touch.
function numberGap(boxes) {
  return boxes === true ? 0 : 3
}

// The gap between two piles. Separate from metrics().gap because it is a
// property of the visible shape, not of the bar, so the module picks between
// pile and number spacing rather than metrics() having to know.
function pileGap(s) {
  const scale = typeof s === "number" && isFinite(s) && s > 0 ? s : 1
  return Math.max(3, Math.round(4 * scale))
}

// Width of one pile, in logical pixels.
//
// `numberWidth` is measured by the caller's Text rather than estimated
// here: the label is a real font at a real pixel size, and a table of
// average glyph widths is wrong on both ends - too wide for "1" and too
// narrow for "10" in the same strip. The caller owns the measurement, this
// owns the arithmetic around it.
//
// `count` is how many icons render (already capped by pileItems) and
// `overflow` is the hidden remainder, which costs one chip and one gap.
//
// The number-to-icons gap is charged ONLY when something actually sits after
// the number. Reserving it unconditionally left an empty workspace with a
// few dead pixels on the right of its label, so the number looked off-centre
// in a pill that was exactly as wide as it needed to be.
function pileWidth(count, overflow, numberWidth, m) {
  const shown = Math.max(0, count | 0)
  let w = m.pad * 2 + Math.max(0, numberWidth)
  if (shown > 0) {
    w += m.numGap + shown * m.icon + (shown - 1) * m.iconGap
  }
  if (overflow > 0) {
    if (shown > 0) w += m.iconGap
    w += m.overflow
  }
  return w
}

// Width of one number-only slot, in logical pixels: the caller's two-digit
// width plus the shape's padding on each edge. Boxes pass `pad` (pill air),
// while the plain strip passes `numberPad`.
// Slot-to-slot spacing is independent and comes from numberGap().
//
// A box narrower than its own padding pair is impossible, and a zero or
// negative measurement must not produce a negative width, so both are floored.
function numberBoxWidth(numberWidth, pad) {
  const p = Math.max(0, pad | 0)
  return p * 2 + Math.max(0, numberWidth | 0)
}

