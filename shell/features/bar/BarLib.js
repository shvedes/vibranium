.pragma library

// Local Bar library: pure helpers behind the bar's "owned module" API.
// No Qt state here - the owned-module list stays reactive in Bar.qml and
// these functions return fresh descriptors (or null) so Bar can decide
// whether to adopt them.
//
// A service that wants its own bar indicator claims a slot with
// Bar.ownModule({ id, zone, component }). The bar hosts the placement and
// window contract; the service controls the module's substance (content,
// visibility) itself. The bar never needs to know what the module is.

const ZONES = ["left", "center", "right"]

// Coerce a zone string; dynamic indicators default to the right zone,
// away from the static time/workspaces that occupy left and center.
function normZone(zone) {
  return ZONES.indexOf(zone) >= 0 ? zone : "right"
}

// Remove an owned descriptor by id. Returns the new list, or null when no
// such id is present (so a stray release is a harmless no-op).
function removeOwned(owned, id) {
  const next = owned.filter(m => m.id !== id)
  return next.length === owned.length ? null : next
}

// --- module groups ---
// A group is a unit that occupies exactly one layout slot (its key id) but
// renders several member modules together. Members are never placed in the
// layout individually - only the group id is - so a group is dragged and
// moved as a whole and nothing can be pulled out from inside it.

// Group key id -> ordered member module ids.
function groupMembers(groups, id) {
  const m = groups ? groups[id] : undefined
  return Array.isArray(m) ? m : []
}

function isGroup(groups, id) {
  return groupMembers(groups, id).length > 0
}

// True when `id` occupies a slot in `layout`, in any zone. The walk is
// array-guarded per zone, so a zone holding anything but a list is skipped
// rather than indexed.
function slotPresent(layout, id) {
  if (!layout) return false
  for (const zone in layout) {
    const list = layout[zone]
    if (Array.isArray(list) && list.indexOf(id) >= 0) return true
  }
  return false
}

// A module is "visible" when it holds its own slot or is a member of a
// group that does. Lets a member module ask about the bundle it belongs to
// (e.g. the tray's expansion trigger is the group it shares) without
// knowing the group's composition.
function moduleVisible(layout, groups, id) {
  if (slotPresent(layout, id)) return true
  for (const gid in groups)
    if (slotPresent(layout, gid) && groupMembers(groups, gid).indexOf(id) >= 0)
      return true
  return false
}

// The boot-entrance expectation: every module the rendered layout shows,
// with group keys expanded to their members (a group key renders its
// members, never itself). Deduped, in first-seen order. The bar's entrance
// gate waits until each of these has reported Ready, then releases all
// slots together into one slidefade.
function entranceExpectedIds(layout, groups) {
  const out = []
  const seen = {}
  if (!layout) return out
  for (const zone in layout) {
    const list = layout[zone]
    if (!Array.isArray(list)) continue
    for (let i = 0; i < list.length; i++) {
      const slot = list[i]
      const members = groups ? groups[slot] : undefined
      if (Array.isArray(members)) {
        for (let m = 0; m < members.length; m++) {
          const kind = members[m]
          if (seen[kind] === undefined) {
            seen[kind] = true
            out.push(kind)
          }
        }
      } else {
        if (seen[slot] === undefined) {
          seen[slot] = true
          out.push(slot)
        }
      }
    }
  }
  return out
}

// Pull pinned ids to the end of their pinned zone: a pinned slot always
// resolves to its corner, whatever the input file says. Removes the id from
// every zone, then appends it to its pinned zone - `include` gates that
// final append for read-side passes that must not materialize disabled
// slots. Mutates `layout` (both callers build a fresh object).
function pinSlots(layout, pinned, zones, include) {
  for (const id in pinned) {
    const pinnedZone = pinned[id]
    if (zones.indexOf(pinnedZone) < 0) continue
    for (let i = 0; i < zones.length; i++) {
      const list = layout[zones[i]]
      const at = list.indexOf(id)
      if (at >= 0) list.splice(at, 1)
    }
    if (!include || include(id)) layout[pinnedZone].push(id)
  }
  return layout
}

// --- slot placement rules ---
// A newly-known id lands immediately before the first zone element that
// matches, else it is appended: `matches` is the whole rule, and the two
// rules below differ only in what they test. Both mutate the list in place
// and return it (every caller passes a fresh slice), so neither can reach
// the caller's own array.
function insertBefore(list, matches, id) {
  for (let i = 0; i < list.length; i++)
    if (matches(list[i], i)) {
      list.splice(i, 0, id)
      return list
    }
  list.push(id)
  return list
}

// The owned-module rule: `matches` is a membership test against the
// controller's id -> pinned-zone map `pinned`, so any value counts as a pin
// and an undefined one is not. A pinned slot is a wall at the zone end, so
// this keeps owned indicators ahead of the corner without displacing
// anything the user dragged.
function insertBeforePin(list, pinned, id) {
  return insertBefore(list, e => pinned[e] !== undefined, id)
}

// The static-module rule: `anchor` is the controller's _placeBefore answer
// for `id`, resolved to its index up front so an empty/absent anchor
// resolves to none and the insert appends.
function insertBeforeAnchor(list, anchor, id) {
  const at = anchor ? list.indexOf(anchor) : -1
  return insertBefore(list, (e, i) => i === at, id)
}

// --- the single layout option ---
//
// `normalizeLayout` is the bar's write-path layout policy: one
// { left, center, right, disabled } option in which the zones hold every
// known standalone slot (plus registered owned ids) exactly once, group
// members never appear, and `disabled` is the dumb off list for toggleable
// static slots only.
//
// The registry stays with the caller. `isStandalone`, `isOwned` and the
// `permanent` / `alwaysOn` / `stale` / `pinned` inputs are the controller's
// facts about its own slots - this function never learns a module's id, and
// never decides what one renders. `stale` holds ids the registry no longer
// serves and must be dropped on write; the caller documents why each is
// stale. Returns the normalized option, or null when `raw` is not an object.
function normalizeLayout(raw, zones, isStandalone, isOwned, permanent, alwaysOn, stale, pinned) {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return null
  const out = { left: [], center: [], right: [], disabled: [] }
  const seen = {}
  for (const zone of zones) {
    const list = raw[zone]
    if (!Array.isArray(list)) continue
    for (const id of list) {
      if (typeof id !== "string" || id === "") continue
      // A stale id is dropped on every write so an upgraded layout heals
      // silently instead of leaking a dead entry.
      if (stale.indexOf(id) >= 0) continue
      if (seen[id] !== undefined) continue
      if (!isStandalone(id) && !isOwned(id)) continue
      seen[id] = true
      out[zone].push(id)
    }
  }
  const dis = Array.isArray(raw.disabled) ? raw.disabled : []
  for (const id of dis) {
    if (typeof id !== "string" || id === "") continue
    if (out.disabled.indexOf(id) >= 0) continue
    if (!isStandalone(id) || isOwned(id)) continue
    if (permanent[id] !== undefined || alwaysOn.indexOf(id) >= 0) continue
    out.disabled.push(id)
  }
  // Enforce pins: every pinned id is pulled to the end of its pinned zone
  // (and out of any other zone), so a hand-edited or stale file cannot place
  // a pinned slot anywhere but its corner.
  pinSlots({ left: out.left, center: out.center, right: out.right }, pinned, zones)
  return out
}

// --- the render filter ---
//
// The one derivation from the persisted option to the layout the bar
// actually renders: zones minus `disabled`, owned ids always passing, stale
// ids that no registry slot resolves dropped, pins re-applied. `hasSlot` and
// `isOwned` are the controller's registry lookups, injected so this stays
// policy over a row and not a second copy of the registry.
//
// Key insertion order is the caller's `zones` order, which the signature
// (JSON.stringify of this object) is sensitive to.
//
// `positions` is read as absent-tolerant because a `var` binding derived from
// the settings store is `undefined` until QML has evaluated it, and the
// caller's own change handlers run before that evaluation lands: the store
// notifies `storedLayout` first, the handler derives the layout, and
// `positions` is still unset. Reading an unset `positions` as "nothing known
// yet" is the truthful answer and the next change notification re-runs this
// with the real value, so the bar is never blanked by the gap.
function renderLayout(positions, disabled, zones, pinned, hasSlot, isOwned) {
  const out = {}
  for (const zone of zones) out[zone] = []
  const pos = positions || {}
  for (const zone of zones) {
    const list = pos[zone] || []
    for (let i = 0; i < list.length; i++) {
      const id = list[i]
      if (!hasSlot(id)) continue
      if (isOwned(id) || disabled.indexOf(id) < 0) out[zone].push(id)
    }
  }
  pinSlots(out, pinned, zones, id => isOwned(id) || disabled.indexOf(id) < 0)
  return out
}

// Pure helper to place an entry into a zone's layout array. `from` and `to`
// are indexes within the original array for `to` the final position (0..n-1).
function reorder(list, from, to) {
  const next = list.slice()
  if (from < 0 || from >= next.length) return next
  if (to < 0) to = 0
  if (to >= next.length) to = next.length - 1
  if (from === to) return next
  const item = next.splice(from, 1)[0]
  next.splice(to, 0, item)
  return next
}

// Choose the insertion target for a horizontally-dragged slot.
//
// `slots`  - same-zone static slots as [{ x, width, index }], in row coords.
// `fromIndex` - index of the dragged slot within that array.
// `x`          - pointer x in the same row coordinates.
//
// Returns { to, x } where `to` is the final array index (pass to reorder)
// and `x` the gap line the drop marker should sit on. Same-zone drags pass
// the dragged slot's own index (it is skipped); cross-zone drops pass
// slots.length (the dragged id lives in another zone, so nothing is
// skipped and every gap 0..n is a candidate).
function dropTarget(slots, fromIndex, x) {
  let best = null
  let bestDist = Infinity
  for (let i = 0; i < slots.length; i++) {
    if (i === fromIndex) continue
    const left = Number(slots[i].x) || 0
    const right = left + (Number(slots[i].width) || 0)
    const base = i < fromIndex ? i : i - 1
    // If dragged into `base` territory the final index shifts: inserting
    // before original slot i lands at `base`, after it at `base + 1`.
    tryConsider(base, left)
    tryConsider(base + 1, right)
  }
  function tryConsider(to, gapX) {
    const dist = Math.abs(gapX - x)
    // Strict < keeps the first gap when the pointer bisects two equal
    // neighbours, so a drop between B and C always reads as one position.
    if (dist < bestDist) {
      best = { to: to, x: gapX }
      bestDist = dist
    }
  }
  // Single-slot zone (or pointer past every edge): fall back to clamping.
  if (best === null) return { to: fromIndex, x: x }
  return best
}

// Compute the persisted zone layout for a same-zone drop: `full` is the
// zone's complete id list (enabled and disabled, from the stored option),
// `ordered` is the zone's reorderable enabled slot ids in their final,
// user-chosen order, and `displayIds` is the filtered (rendered) order that
// defines the working set - movable = displayed and not fixed. `isPinned`
// and `isFixed` are the controller's own answers.
//
// The same-zone sibling of crossDropPositions. Zones are rebuilt from
// `ordered` so disabled modules keep their exact gaps and fixed slots keep
// their place; pinned ids are skipped entirely, because the write re-pins
// them to their zone end and no drag can displace them. Movable ids left
// over (newly enabled and absent from `full`) append after the dragged
// block.
//
// Returns { list, changed }: `list` is the new zone (fresh array, `full`
// untouched) and `changed` is false when the drop resolved to exactly the
// order already persisted, so the caller can skip the write.
function rebuildZoneOrder(full, ordered, displayIds, isPinned, isFixed) {
  const movable = {}
  for (let i = 0; i < displayIds.length; i++)
    if (!isFixed(displayIds[i])) movable[displayIds[i]] = true
  const next = []
  let oi = 0
  for (let i = 0; i < full.length; i++) {
    const id = full[i]
    if (isPinned(id)) continue
    if (isFixed(id)) next.push(id)
    else if (movable[id] && oi < ordered.length) next.push(ordered[oi++])
    else next.push(id)
  }
  for (; oi < ordered.length; oi++) next.push(ordered[oi])
  // Compare against the unpinned full list; pinned placement is enforced by
  // normalizeLayout on the write.
  let same = true
  let di = 0
  for (let i = 0; i < full.length; i++) {
    if (isPinned(full[i])) continue
    if (di >= next.length || next[di] !== full[i]) {
      same = false
      break
    }
    di++
  }
  return { list: next, changed: !(same && di === next.length) }
}

// Compute the persisted zone layout after dropping `id` from `fromRegion`
// into `toRegion` at movable position `toIndex` (index into the target's
// enabled, non-fixed display order, as produced by dropTarget over the
// target's movable slots with fromIndex = slots.length).
//
// `cur` is { left, center, right } arrays holding every known slot of the
// zone (enabled and disabled); `displayIds` is the target zone's current
// enabled order. `isFixed` answers Bar.isFixedSlot. Returns the new
// { left, center, right } (fresh arrays, input untouched) or null when the
// move is invalid. Disabled modules keep their exact gaps; the dragged id
// lands before the movable currently at `toIndex` (or after the last
// movable when dropped past the end - ahead of any trailing pin wall,
// which the positions write re-pins anyway).
function crossDropPositions(cur, displayIds, isFixed, id, fromRegion, toRegion, toIndex) {
  if (typeof id !== "string" || id === "") return null
  if (!cur || !Array.isArray(cur[fromRegion]) || !Array.isArray(cur[toRegion])) return null
  if (fromRegion === toRegion) return null
  if (cur[fromRegion].indexOf(id) < 0) return null
  const display = Array.isArray(displayIds) ? displayIds : []
  if (display.indexOf(id) >= 0) return null
  let movables = 0
  for (let i = 0; i < display.length; i++)
    if (!isFixed(display[i])) movables++
  const at = Math.max(0, Math.min(toIndex, movables))
  const next = {
    left: cur.left.slice(),
    center: cur.center.slice(),
    right: cur.right.slice()
  }
  next[fromRegion] = next[fromRegion].filter(s => s !== id)
  // Defensive: a duplicated id in the target collapses to the drop point.
  const full = next[toRegion].filter(s => s !== id)
  const inDisplay = {}
  for (const d of display) inDisplay[d] = true
  // Movable = non-fixed AND displayed; disabled slots are invisible walls
  // that keep their gaps.
  let seen = 0
  let insertAt = -1
  for (let i = 0; i < full.length; i++) {
    const sid = full[i]
    if (isFixed(sid) || !inDisplay[sid]) continue
    if (seen === at) {
      insertAt = i
      break
    }
    seen++
  }
  if (insertAt < 0) {
    // Past the end: right after the last movable (pins trail by
    // construction; the write re-pins them regardless).
    insertAt = full.length
    for (let i = full.length - 1; i >= 0; i--) {
      const sid = full[i]
      if (!isFixed(sid) && inDisplay[sid]) {
        insertAt = i + 1
        break
      }
    }
  }
  full.splice(insertAt, 0, id)
  next[toRegion] = full
  return next
}

// Hysteresis variant for an active drag: the candidate only flips once
// the pointer crosses 24px past the midline, so riding the midline
// never oscillates the preview slabs.
function positionCandidateHeld(y, screenH, current) {
  if (!isFinite(y) || !isFinite(screenH) || screenH <= 0) return current
  const band = 24
  if (current === "top" && y > screenH / 2 + band) return "bottom"
  if (current === "bottom" && y < screenH / 2 - band) return "top"
  if (current !== "top" && current !== "bottom") return y <= screenH / 2 ? "top" : "bottom"
  return current
}