.pragma library

// The menu's search index and condition index, as pure functions over a
// bundle. Menu.qml owns when they are rebuilt; this module owns what a
// rebuild means.
//
// Both questions are asked on every bundle load, and both have a shape that
// is easy to get wrong by a line - a registration appended twice, a shadowed
// page left in the index, a condition var missed because a page had no
// showIf array. Stating them here lets the menu suite assert the shapes
// without a shell.

// The index a query scans: the bundle's own entries plus every live dynamic
// owner's, with a registered page SHADOWING the bundle page of the same id.
//
// Shadowing is not cosmetic. pageById resolves a dynamic id to the published
// page, so the bundle's rows for that id are entries for a page the id no
// longer names. Keeping both puts the same (pageId, row) pair in the index
// twice - two hits for one row - and the projection's keyed model refuses the
// WHOLE install on a repeated key, so every query that reached such a page
// reads as a dead search bar while the page's own rows stay on screen. The
// Idle page is exactly this case: the schema ships a one-row "idle" page and
// the idle daemon publishes the live timer list under the same id.
//
// Registrations are appended by index rather than spread: a large
// registration is one argument list to push(...), and the engine caps that.
function sectionRows(builtin, registrations, settingsFamily) {
  const regs = registrations !== null && registrations !== undefined
    ? registrations : {}
  const base = Array.isArray(builtin) ? builtin : []
  const merged = []
  // A standalone picker bundle spans only its own rows: injected settings
  // pages would both render foreign rows and answer global search there.
  const shadowing = settingsFamily === true
  for (let i = 0; i < base.length; i++) {
    const row = base[i]
    if (shadowing && row && regs[row.pageId] !== undefined) continue
    merged.push(row)
  }
  if (!shadowing) return merged
  for (const ownerId in regs) {
    const entries = regs[ownerId]
    if (!Array.isArray(entries)) continue
    for (let i = 0; i < entries.length; i++) merged.push(entries[i])
  }
  return merged
}

// The store variables any row's `showIf` names. A variable is collected once
// however many rows gate on it; a bundle that is null, or a page or item that
// carries no showIf, contributes nothing.
function conditionVars(bundle) {
  const vars = {}
  if (!bundle || !Array.isArray(bundle.pages)) return vars
  for (let p = 0; p < bundle.pages.length; p++) {
    const page = bundle.pages[p]
    if (!page || !Array.isArray(page.items)) continue
    for (let i = 0; i < page.items.length; i++) {
      const item = page.items[i]
      const conds = item ? item.showIf : null
      if (!Array.isArray(conds)) continue
      for (let c = 0; c < conds.length; c++) {
        const cond = conds[c]
        if (cond && cond.var !== undefined) vars[cond.var] = true
      }
    }
  }
  return vars
}
