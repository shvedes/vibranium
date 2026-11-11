// Row presentation: staged flows, the shape a row takes at rest, the copy a
// stage overrides, the value slot, and the inline dropdown's geometry.
//
// WHY IT IS ITS OWN MODULE. Everything here is a pure projection over the
// payload a row already carries - no Menu, no QML item, no state store - and
// together they answer one question: what does this row put on screen? MenuLib
// re-exports each entry point, so its callers keep a single import (and the
// suite keeps its one coverage ledger); the file boundary is for the reader who
// wants the presentation rule without the parser and the search index around
// it. The two option-matching functions that call the search scorer
// (exactOptionIndex, bestOptionIndex) deliberately stay in MenuLib, beside the
// scorer they depend on.
.pragma library

// Staged-flow helpers: pure, unit-testable, no Menu import.
function isFlow(item) {
  return !!item && Array.isArray(item.flow) && item.flow.length > 0
}

function flowStep(item, idx) {
  if (!isFlow(item)) return null
  const i = Number(idx) || 0
  if (i < 0 || i >= item.flow.length) return null
  return item.flow[i]
}

function flowCount(item) {
  return isFlow(item) ? item.flow.length : 0
}

// The stage a flow renders next, starting at `from`. A stage carrying
// skipUnless shows only when SOME earlier stage stored its value, never
// stage zero alone, so a select-first flow and an editor-first flow
// share one rule. Unmatched stages are stepped over. The result is an
// index the caller compares against flowCount: at or past the end means
// the flow is done and commits.
function nextFlowIndex(item, from, stored) {
  const count = flowCount(item)
  let next = from
  while (next < count) {
    const step = flowStep(item, next)
    if (step && step.skipUnless !== undefined && step.skipUnless !== "") {
      let match = false
      for (const k in stored) {
        if (String(stored[k]) === String(step.skipUnless)) { match = true; break }
      }
      if (!match) { next++; continue }
    }
    break
  }
  return next
}

// --- row presentation projections ---
//
// What a row PUTS ON SCREEN, as values: the copy a stage overrides, the
// text a value slot shows, the width that slot reserves, the option a
// stored value points at, the number typed into an editor, and the
// geometry of the inline dropdown. All of it is pure over the payload
// the model already carries, so a bundle's rows can be checked without a
// shell. None of it reads Menu, a QML item or the state store: the row
// reads those and hands the answer over.

// The shape a row takes at rest: which second line it spends, if any. THE
// rule - MenuPanel's model-side estimate and Entry's own layout both ask this,
// so the card's height and the row it holds cannot classify a row differently.
//
// `providerSub` is the sub line a provider overlay would draw for this row,
// already resolved by the caller: a provider call is the caller's business
// (this library never reads Menu), and the delegate has that very string in
// hand anyway because it renders it. An empty or non-string provider value is
// "no override", and the row's own copy decides on its own.
//
// ORDER MATTERS. A theme row spends its second line on the swatch strip, so
// "theme" is asked first, whatever copy the row carries; a row with any sub
// copy - provider, declared, leading or trailing accent - is "sub"; a row with
// none is a single title line.
function restKind(item, providerSub) {
  if (!item) return "line"
  if (typeof item.light === "string" && item.light !== "") return "theme"
  if (typeof providerSub === "string" && providerSub !== "") return "sub"
  if (item.sub !== undefined && item.sub !== null && String(item.sub) !== "") return "sub"
  if (typeof item.subLead === "string" && item.subLead !== "") return "sub"
  if (typeof item.subAccent === "string" && item.subAccent !== "") return "sub"
  return "line"
}

// Copy a flow stage declares for itself, or null when it declares none.
// A stage's own string wins while that stage renders - an EMPTY one too,
// which is how a stage deliberately blanks the line - and a collapsed row
// shows the top-level copy. A caller keeps its own copy on null. An
// empty accent is spelled at the call site, because an empty accent and
// no accent render the same and only the caller knows that.
function stageText(expanded, step, key) {
  if (!expanded || !step) return null
  const v = step[key]
  return typeof v === "string" ? v : null
}

// A stage's unit overrides the row's own, trimmed, because a stage
// descriptor carries the literal it wants shown. A stage that declares
// no unit keeps whatever the row declared. (The row's own suffix is
// unitSuffix, above.)
//
// The same rule as unitSuffix once a stage does declare one: an empty unit
// renders nothing, not a lone space, and null declares nothing at all.
function stageUnitSuffix(stageUnit, fallback) {
  if (stageUnit === undefined) return fallback
  const u = String(stageUnit).trim()
  return u === "" ? " " : " " + u
}

// The seed an editor opens with, or null when the caller keeps its own
// seed. A flow stage owns its seed: a text stage carries only what its OWN
// stage stored, so a text stage with nothing stored opens empty and shows
// its placeholder. The row's own value is NOT a fallback here - that value
// belongs to the row's primary kind, which in a number-first flow is the
// minutes, and a command field opening on "15" is a wrong answer, not a
// default.
function stageSeedText(isFlow, kind, stored) {
  if (!isFlow) return null
  if (kind !== "text") return ""
  if (stored === undefined || stored === null) return ""
  const s = String(stored)
  return s === "" ? "" : s
}

// Reading for a numeric slot: the provider's display override when it
// answered one, else the row's own value at the row's own precision. The
// test is `!== null` and not a nullish check because null IS the decline
// hookValue hands back - an override is any non-empty value, uncoerced.
// Bounds and drift are the caller's; nothing here clamps or quantizes.
function numberDisplay(override, value, decimals, suffix) {
  if (override !== null) return override
  return value.toFixed(decimals) + suffix
}

// Width a right-hand value slot reserves. A shared column wins when the
// panel published one (it measures the widest value on the page so little
// bars form one vertical line); a lone row reserves its own measured
// content plus a pad, capped so one long value cannot push the label out
// of the card. `unified` of 0 means no shared column.
function valueSlotW(unified, contentW, pad, cap) {
  if (unified > 0) return unified
  return Math.min(contentW + pad, cap)
}

// Label of the option a stored value points at, or the raw value when no
// option claims it: a value the bundle no longer offers still shows what
// it holds instead of an empty slot. Options come from the bundle, so the
// comparison is strict - a number option never matches a stored string.
//
// An option with no label shows its value, as the options page does for the
// same option; returning the bare `label` printed "undefined" into the slot.
function optionLabelFor(options, value) {
  for (let i = 0; i < options.length; i++) {
    const o = options[i]
    if (o.value === value) return o.label ?? String(o.value)
  }
  return String(value)
}

// Index the dropdown cursor opens on: the option carrying the value, or
// the first option when none does, so Enter-Enter re-picks the stored
// choice without the arrows moving. The comparison is by text, unlike
// optionLabelFor: the cursor has to meet a value that comes back from a
// settings store as a string against an option that declares a number.
function optionSeedIndex(options, value) {
  for (let i = 0; i < options.length; i++) {
    if (String(options[i].value) === String(value)) return i
  }
  return 0
}

// Inline dropdown geometry. A long option list (codec selection) halves
// its height into two columns instead of scrolling forever; a short one
// keeps the single-column look. The fill is column-major, so the linear
// cursor walks top-to-bottom, and Left/Right page a whole column - a
// stride of 0 for a single column, where the key falls through to its
// next binding instead of moving nothing.
function optionColumnCount(count) {
  return count > 6 ? 2 : 1
}

function optionRowCount(count) {
  return count > 6 ? Math.ceil(count / 2) : count
}

function optionColumnStride(count) {
  return count > 6 ? Math.ceil(count / 2) : 0
}

function optionCellCol(index, count) {
  return count > 6 ? Math.floor(index / optionRowCount(count)) : 0
}

function optionCellRow(index, count) {
  return count > 6 ? index % optionRowCount(count) : index
}

// Leading number of editor input: an optional minus, digits, and an
// optional decimal point written either way, because a comma is what a
// locale keyboard types. Trailing junk after the digits is tolerated
// ("12 fps" reads 12); input that does not start with a number yields
// null, and the caller restores the real value rather than committing
// garbage. Callers clamp and quantize the result themselves.
//
// A leading dot (".5") and a plus sign are numbers too, and the typographic
// minus sign (U+2212, what a phone keyboard offers) reads as the minus: each
// of them reads as a number rather than as "not a number".
function leadingNumber(text) {
  const m = /^\s*([-\\u2212]?(?:\d+(?:[.,]\d+)?))/.exec(String(text))
  return m === null ? null : Number(m[1].replace("\u2212", "-").replace(",", "."))
}

