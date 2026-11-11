.pragma library

// The spawn probe verdict: whether a summoned card's FIRST laid-out height was
// the box the previous menu left behind rather than the summoned row set's own
// size. Three heights, no panel state - which is what makes the rule askable
// without a shell.
//
//   prevH     the card height while the previous menu was up
//   firstH    the first height this spawn produced, or -1 for none
//   settledH  the height the spawn came to rest at, or -1 for none
//
// A cold card has no previous surface to compare against, so it reports no
// verdict instead of a vacuous pass.

function cold(prevH) {
  return !(prevH >= 0)
}

// Positive means the first frame was TALLER than the resting size, the
// direction a spawn that inherited a longer previous menu drifts.
function drift(firstH, settledH) {
  return (firstH < 0 || settledH < 0) ? -1 : Math.round(firstH - settledH)
}

// A carried box, named as one: the first frame matched the previous menu's
// height while the card went on to settle somewhere else.
function carried(prevH, firstH, settledH) {
  return !cold(prevH) && firstH >= 0 && settledH >= 0
    && Math.abs(firstH - prevH) < 0.5
    && Math.abs(settledH - prevH) >= 0.5
}

function verdict(prevH, firstH, settledH) {
  return {
    cold: cold(prevH),
    prevH: Math.round(prevH),
    firstH: firstH < 0 ? -1 : Math.round(firstH),
    settledH: settledH < 0 ? -1 : Math.round(settledH),
    drift: drift(firstH, settledH),
    carried: carried(prevH, firstH, settledH)
  }
}
