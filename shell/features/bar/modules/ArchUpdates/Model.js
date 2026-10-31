.pragma library

// Pure model behind the arch updates island: the package search, the
// official/AUR split, the selection algebra, the per-row projection the
// delegates render, the padded row window and the capped column widths.
//
// No Qt imports, no QML state, no command: every function takes what it
// needs and returns a value, and the island reassigns the property that
// holds it, which is what re-evaluates the bindings. The island keeps
// the module's own constants (the 7-row window, the 14px checkbox, the
// 120px version cap) and passes them in, so this module never owns arch
// chrome policy and never decides what a row looks like.
//
// The AUR tag lives here and only here: the service stamps it, the
// filter, the counts, the selection keys and the row icon all read it
// through these functions.

// The selection map is keyed on "<source>:<name>" and never mutated in
// place - a delegate binding re-evaluates because the island reassigns
// the property, not because the object behind it changed.
var AUR = "aur"
var AUR_PREFIX = "aur:"
var OFFICIAL_PREFIX = "official:"

// A non-object entry (a delegate mid-teardown, a model swap) has no key
// and no source. The guards are why an unguarded read here cannot take
// the shell down with it.
function isAur(pkg) {
  if (!pkg || typeof pkg !== "object") return false
  return String(pkg.source || "") === AUR
}

// Selection key for a package; "" is the "no key" answer a skeleton or
// padding row gets, and the one every caller must drop rather than store.
function selKey(pkg) {
  if (!pkg || typeof pkg !== "object") return ""
  return (isAur(pkg) ? AUR_PREFIX : OFFICIAL_PREFIX) + String(pkg.name || "")
}

// One walk for both per-source totals: every package is either official
// or AUR, so the two always sum to the array length.
function sourceCounts(packages) {
  const pkgs = Array.isArray(packages) ? packages : []
  let official = 0
  let aur = 0
  for (let i = 0; i < pkgs.length; i++) {
    if (isAur(pkgs[i])) aur++
    else official++
  }
  return { official: official, aur: aur }
}

// The heavy-queue threshold: a backlog above this many pending packages is
// worth a red total and the island's warning box. One definition, read by
// the module's tooltip and the island alike, so the alarm and the number
// cannot disagree about what "heavy" means. `enabled` is the settings
// toggle the island gates the warning on; it arrives as an argument so
// this stays a pure function of its inputs.
var HEAVY_QUEUE_MIN = 200

function heavyQueue(packages, enabled) {
  if (!enabled) return false
  return (Array.isArray(packages) ? packages.length : 0) > HEAVY_QUEUE_MIN
}

// Case-insensitive search over the package name and its repository. An
// empty query returns the input array itself, not a copy, so an
// unfiltered island hands the row window the service's array.
function filterPackages(packages, query) {
  const pkgs = Array.isArray(packages) ? packages : []
  const q = String(query).trim().toLowerCase()
  if (q === "") return pkgs
  const out = []
  for (let i = 0; i < pkgs.length; i++) {
    const p = pkgs[i]
    const name = String(p.name || "").toLowerCase()
    const repo = String(p.repository || "").toLowerCase()
    if (name.indexOf(q) >= 0 || repo.indexOf(q) >= 0) out.push(p)
  }
  return out
}

// A padding filler (the blank rows that hold the table's footprint when
// fewer packages than the window) is not a package row. Its absence is
// what tells it apart: a real package always carries a name, and a
// skeleton entry carries neither.
function isFiller(entry) {
  return !entry || typeof entry !== "object" || entry.name === undefined
}

function selectedCount(selected) {
  return Object.keys(selected).length
}

// Membership, not count: a key left over from outside the filter must not
// read as "everything is selected", and an empty filter never does.
function allSelected(filtered, selected) {
  const f = Array.isArray(filtered) ? filtered : []
  if (f.length === 0) return false
  for (let i = 0; i < f.length; i++) if (!selected[selKey(f[i])]) return false
  return true
}

// The names the service is asked to update, split by source. A key with
// no separator or an empty name is dropped: the island never hands the
// service a bare "" to resolve.
function selectedNames(selected) {
  const out = { official: [], aur: [] }
  for (const key in selected) {
    const sep = key.indexOf(":")
    if (sep <= 0) continue
    const name = key.substring(sep + 1)
    if (name === "") continue
    if (key.substring(0, sep) === AUR) out.aur.push(name)
    else out.official.push(name)
  }
  return out
}

function emptySelection() {
  return {}
}

function toggleKey(selected, key) {
  const next = Object.assign({}, selected)
  if (next[key]) delete next[key]
  else next[key] = true
  return next
}

// Extend the selection to every filtered package. Keys outside the
// filter survive, so searching away from a row never drops it.
function selectAll(selected, filtered) {
  const next = Object.assign({}, selected)
  const f = Array.isArray(filtered) ? filtered : []
  for (let i = 0; i < f.length; i++) {
    const k = selKey(f[i])
    if (k !== "") next[k] = true
  }
  return next
}

function toggleAll(selected, allSelectedNow, filtered) {
  if (allSelectedNow) return emptySelection()
  return selectAll(selected, filtered)
}

// The selection trimmed to packages that still exist, or null when
// nothing was stale. null is the "no change" answer: the island then
// leaves the property alone instead of reassigning an equal map and
// re-running every delegate binding for nothing.
function pruneKeys(selected, packages) {
  const pkgs = Array.isArray(packages) ? packages : []
  const live = {}
  for (let i = 0; i < pkgs.length; i++) {
    const p = pkgs[i]
    if (!p || typeof p !== "object") continue
    live[selKey(p)] = true
  }
  let changed = false
  const next = {}
  for (const key in selected)
    if (live[key]) next[key] = true
    else changed = true
  return changed ? next : null
}

// The live rows padded up to the window, so the table always shows a
// full window of rows and its footprint never changes. At or past the
// window the input array is returned as-is: the padding would be dead
// and a copy would churn the list's stableModel for nothing.
function rowWindow(rows, windowSize) {
  const r = Array.isArray(rows) ? rows : []
  if (r.length >= windowSize) return r
  const out = r.slice()
  for (let i = r.length; i < windowSize; i++) out.push({ _filler: true })
  return out
}

// One table row projected into exactly the six fields the delegate
// renders. A blank entry and a padding filler project to the same empty
// view, so the delegate carries one branch instead of testing the model
// entry three times.
function rowView(pkg, selected) {
  if (isFiller(pkg) || pkg._filler === true)
    return { filler: true, key: "", checked: false, aur: false, name: "", candidate: "" }
  const key = selKey(pkg)
  return {
    filler: false,
    key: key,
    checked: selected[key] === true,
    aur: isAur(pkg),
    name: String(pkg.name || ""),
    candidate: String(pkg.candidate || "")
  }
}

// Column widths from the widest measured text. Both columns are capped:
// names and versions are truncated at 128 chars upstream, so unbounded
// content (a git-hash version) can never "fit" a fixed viewport - past
// the caps a row elides (middle for versions, keeping release and hash
// suffix readable) instead of pushing the Version column off-screen
// where no mouse can reach it. The name yields to the version: what the
// viewport has left after the chrome and the version is the name
// budget, floored so the column can never invert.
//
// Every cap arrives as an argument. The numbers are the island's chrome,
// not a table-wide policy.
function columnWidths(nameWidth, verWidth, viewport, rowChrome, caps) {
  const ver = Math.min(Math.max(Math.ceil(verWidth) + caps.verPad, caps.minVer), caps.verCap)
  const name = Math.min(Math.max(Math.ceil(nameWidth), caps.minName),
    Math.max(caps.minName, viewport - rowChrome - ver))
  return { name: name, ver: ver }
}

if (typeof module !== "undefined") {
  module.exports = {
    isAur: isAur,
    selKey: selKey,
    sourceCounts: sourceCounts,
    heavyQueue: heavyQueue,
    HEAVY_QUEUE_MIN: HEAVY_QUEUE_MIN,
    filterPackages: filterPackages,
    isFiller: isFiller,
    selectedCount: selectedCount,
    allSelected: allSelected,
    selectedNames: selectedNames,
    emptySelection: emptySelection,
    toggleKey: toggleKey,
    selectAll: selectAll,
    toggleAll: toggleAll,
    pruneKeys: pruneKeys,
    rowWindow: rowWindow,
    rowView: rowView,
    columnWidths: columnWidths
  }
}
