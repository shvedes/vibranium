.pragma library

// Grid page composition: section headers woven into a flat cell list.
//
// A new section tag starts a fresh row with a full-width header slot followed
// by invisible spacers up to the next column boundary. The pool keeps chrome
// slots identity-stable between recompositions, because the row diff compares
// object identity rather than value - a fresh spacer object per weave would
// read as a replaced row every time.
//
// Pure JS: the caller owns the pool handle and the column count, so startup
// preload can weave with the deterministic count derived from the page
// declaration while the live panel uses its measured grid.

function createPool() {
  return { spacers: [], headers: {} }
}

function spacerAt(pool, i) {
  while (pool.spacers.length <= i) {
    pool.spacers.push({
      type: "spacer",
      uid: "sp#" + pool.spacers.length,
      selectable: false
    })
  }
  return pool.spacers[i]
}

function headerFor(pool, section) {
  if (pool.headers[section] === undefined) {
    pool.headers[section] = {
      type: "header",
      uid: "hdr:" + section,
      label: section,
      selectable: false
    }
  }
  return pool.headers[section]
}

function composeGridRows(pool, items, cols) {
  const c = Math.max(1, Math.floor(Number(cols) || 1))
  const out = []
  let lastSection = null
  const padToRowEnd = () => {
    while (out.length % c !== 0)
      out.push(spacerAt(pool, out.length))
  }
  for (let i = 0; i < items.length; i++) {
    const item = items[i]
    const section = String(item.section ?? "")
    if (section !== "" && section !== lastSection) {
      padToRowEnd()
      out.push(headerFor(pool, section))
      while (out.length % c !== 0)
        out.push(spacerAt(pool, out.length))
      lastSection = section
    }
    out.push(item)
  }
  return out
}
