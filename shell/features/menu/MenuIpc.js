.pragma library

// Pure projection and guard vocabulary for the menu gateway.
//
// This module knows nothing about QML objects, dialogs, keyboard input or the
// shell runtime. It answers four questions for the owner in Menu.qml:
//
//   1. what a safe public row record looks like (and which fields must never
//      leave the model),
//   2. whether a row and its ancestors may be operated on right now,
//   3. how a typed IPC argument maps onto a row type,
//   4. whether a shell template may receive mutable text from a client.
//
// Keeping those rules here makes them directly testable and, more importantly,
// makes it impossible for a gateway command to invent a different answer from
// the one the UI gives the same row.

.import "MenuLib.js" as MenuLib

// --- result vocabulary -----------------------------------------------------

function ok(data) { return { v: 1, ok: true, data: data } }
function silent() { return { v: 1, ok: true } }
function accepted() { return silent() }
function fail(code, message) {
  return { v: 1, ok: false, error: { code: code, message: String(message || code) } }
}

// --- references ------------------------------------------------------------
// `r<incarnation>.<open>.<pageOrdinal>.<rowOrdinal>`. The incarnation is a
// process/generation prefix from the router; a dot inside it would break the
// four-field grammar, so it is folded into a hyphen.

function ref(incarnation, openGen, pageOrdinal, rowOrdinal) {
  const who = String(incarnation === undefined || incarnation === null ? "" : incarnation)
    .replace(/\./g, "-")
  if (who === "" || !Number.isInteger(openGen) || openGen < 1
    || !Number.isInteger(pageOrdinal) || pageOrdinal < 1
    || !Number.isInteger(rowOrdinal) || rowOrdinal < 0) return null
  return "r" + who + "." + openGen + "." + pageOrdinal + "." + rowOrdinal
}

function parseRef(text) {
  if (typeof text !== "string") return null
  const m = /^r([^.]+)\.(\d+)\.(\d+)\.(\d+)$/.exec(text)
  if (!m) return null
  const openGen = Number(m[2])
  const pageOrdinal = Number(m[3])
  const rowOrdinal = Number(m[4])
  if (!Number.isSafeInteger(openGen) || !Number.isSafeInteger(pageOrdinal)
    || !Number.isSafeInteger(rowOrdinal)) return null
  return {
    incarnation: m[1], open: openGen, page: pageOrdinal, row: rowOrdinal
  }
}

// A ref is live only for the current process generation and the current open
// generation. Retiring a page or a row bumps an ordinal, which makes every ref
// that named the old object miss here without a label or index fallback.
function refMatches(text, incarnation, openGen) {
  const r = parseRef(text)
  if (!r) return null
  if (r.incarnation !== String(incarnation === undefined || incarnation === null
    ? "" : incarnation).replace(/\./g, "-")) return null
  if (r.open !== openGen) return null
  return r
}

// --- guards ----------------------------------------------------------------
// Layout chrome is listed for discovery but has no operations and no ref.
var LAYOUT_TYPES = ["separator", "header", "spacer"]

function isLayoutType(type) {
  return LAYOUT_TYPES.indexOf(String(type)) >= 0
}

function layoutRow(type) { return isLayoutType(type) }

function ordinaryGuard(item, ancestors, blocked) {
  if (!item) return "not-found"
  if (layoutRow(item.type)) return "unsupported"
  const chain = (ancestors || []).concat([item])
  for (let i = 0; i < chain.length; i++) {
    const row = chain[i]
    if (!row) return "not-found"
    if (row.enabled === false) return "refused"
    if (typeof blocked === "function" && blocked(row)) return "refused"
  }
  return null
}

// The row-type matrix. Each action names the types that may receive it;
// `get`, `open`/`close` idempotence and confirmation/flow precedence are the
// owner's business, not this table's.
var ACTION_TYPES = {
  activate: ["action", "submenu", "toggle", "number", "range", "text", "select", "option", "group", "expandable", "result"],
  open: ["submenu", "number", "range", "text", "select", "group", "expandable"],
  close: ["number", "range", "text", "select", "group", "expandable"],
  toggle: ["toggle"],
  set: ["toggle", "number", "range", "text", "select"],
  step: ["number", "range"],
  options: ["select"],
  choose: ["select", "option"],
  info: ["action", "submenu", "toggle", "number", "range", "text", "select", "group", "expandable", "progress"],
  confirm: ["action"],
  flow: ["action", "select", "toggle", "number", "range", "text"],
  delete: ["action", "select", "toggle", "number", "range", "text", "group", "expandable"]
}

function supports(type, action) {
  const list = ACTION_TYPES[action]
  return !!list && list.indexOf(String(type)) >= 0
}

function operationError(type, action) {
  if (!supports(type, action)) return "unsupported"
  return null
}

// --- typed values ----------------------------------------------------------
// A promoted row's primary value type. A select's options may carry numbers;
// that is still a JSON value whichever type the authored option declares, and
// membership is checked by the owner against the same normalized options.
function valueKind(item) {
  if (!item) return ""
  if (item.type === "toggle") return "bool"
  if (item.type === "number" || item.type === "range") return "number"
  if (item.type === "text") return "text"
  if (item.type === "select") return "value"
  return ""
}

function validValue(kind, value) {
  switch (kind) {
  case "bool": return typeof value === "boolean"
  case "number": return typeof value === "number" && isFinite(value)
  case "text": return typeof value === "string"
  case "value": return value === null || ["string", "number", "boolean"].indexOf(typeof value) >= 0
  default: return false
  }
}

// A JSON number for a number/range row may be integral or fractional; the
// owner clamps and quantizes it the way Entry does. Reject a wrong type here,
// before any state is changed.
function valueError(item, value) {
  const kind = valueKind(item)
  return valueErrorForKind(kind, value)
}

function valueErrorForKind(kind, value) {
  let type = String(kind || "")
  if (type === "select") type = "value"
  if (type === "range") type = "number"
  if (["bool", "number", "text", "value"].indexOf(type) < 0) return "unsupported"
  return validValue(type, value) ? null : "invalid-argument"
}

// Select option identity is positional in the resolved model: `o<index>`.
function optionId(index) { return "o" + Number(index) }
function optionIndex(id) {
  if (typeof id !== "string") return -1
  const m = /^o(\d+)$/.exec(id)
  if (!m) return -1
  const n = Number(m[1])
  return Number.isSafeInteger(n) ? n : -1
}

// --- shell templates -------------------------------------------------------
// MenuLib.substitute is intentionally raw for Registry argv. A template that
// is about to reach a shell may only interpolate a value through
// MenuLib.substituteQuoted, and only when every %v is a standalone unquoted
// argv token. This scanner is the recognition rule; a template with a quoted
// slot, an adjacent token or a metacharacter outside quotes is rejected
// before a client value can change any state.

function safeShellTemplate(template) {
  if (typeof template !== "string") return false
  const s = template
  let quote = ""
  let slots = 0
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    // A slot inside either quote style is a shell-literal interpolation: the
    // quoted substitution would embed quotes in the word. Reject it before
    // looking at anything else.
    if (s.slice(i, i + 2) === "%v") {
      if (quote !== "") return false
      const before = i === 0 ? " " : s[i - 1]
      const after = i + 2 === s.length ? " " : s[i + 2]
      if (!/^\s$/.test(before) || !/^\s$/.test(after)) return false
      slots++
      i++
      continue
    }
    if (quote !== "") {
      if (c === "\\" && quote === "\"") { i++; continue }
      if (c === quote) quote = ""
      continue
    }
    if (c === "\n" || c === "\r") return false
    if (c === "\\") return false
    if ("|&;<>()`$".indexOf(c) >= 0) return false
    if (c === "'" || c === "\"") { quote = c; continue }
  }
  if (quote !== "") return false
  // `slots === 0` is a static template: it needs no interpolation and is safe.
  return slots >= 0
}

// The owner calls this only after safeShellTemplate passed. An empty template
// with no slot stays empty; a static template runs unchanged.
function quoteShellValue(template, value) {
  return MenuLib.substituteQuoted(String(template), String(value))
}

// --- protected rows --------------------------------------------------------
// A page boundary that must never be walked by generic menu reads. The native
// `pass copy` route stays a deliberate, separate path.
var PROTECTED_PAGES = ["pass-menu", "pass-vault"]

function isProtectedPage(pageId) {
  return pageId !== null && pageId !== undefined
    && PROTECTED_PAGES.indexOf(String(pageId)) >= 0
}

function envBound(varName) {
  if (typeof varName !== "string" || varName === "") return false
  const parts = varName.split(".")
  for (let i = 0; i < parts.length; i++) {
    const p = parts[i].toLowerCase()
    if (p === "env" || p === "secret" || p === "password"
      || p === "passwd" || p === "credential") return true
  }
  return false
}

function isProtectedRow(item, page, stage) {
  if (!item) return false
  if (item.sensitive === true || item._sensitive === true
    || (stage && stage.sensitive === true)) return true
  if (envBound(item.var)) return true
  if (isProtectedPage(item.pageId || item._pageId || (page ? page.id : ""))) return true
  return false
}

// Secret values are never projected, even in a masked form. A protected row
// reports presence only.
function safeValue(item, state, protectedRow) {
  if (protectedRow || !item || !state) return null
  const v = state.value
  if (v === undefined || v === null) return null
  if (["string", "number", "boolean"].indexOf(typeof v) >= 0) return v
  return null
}

// --- public row projection -------------------------------------------------
// Every table row has the same shape. Chrome carries a null ref and no
// actions; a protected row keeps its metadata but no value or sub fields.
function rowRecord(input) {
  const src = input || {}
  const type = String(src.type || "")
  const chrome = layoutRow(type)
  const actions = chrome || src.protected === true ? [] : (Array.isArray(src.actions) ? src.actions.slice() : [])
  return {
    ref: chrome ? null : (src.ref || null),
    uid: src.uid !== undefined && src.uid !== null ? String(src.uid) : null,
    id: src.id !== undefined && src.id !== null && String(src.id) !== "" ? String(src.id) : null,
    page: src.page !== undefined && src.page !== null ? String(src.page) : null,
    parent: src.parent || null,
    depth: Number(src.depth) || 0,
    type: type,
    label: src.label !== undefined && src.label !== null ? String(src.label) : "",
    available: src.available !== false,
    expanded: src.expanded === true,
    actions: actions
  }
}

function itemDetail(input) {
  const base = rowRecord(input)
  const src = input || {}
  const locked = src.protected === true
  const state = src.state || {}
  const flow = src.flow && typeof src.flow === "object" ? src.flow : null
  const options = Array.isArray(src.options) ? src.options : []
  const confirm = src.confirm && typeof src.confirm === "object" ? src.confirm : null
  const limits = src.type === "number" || src.type === "range"
    ? { min: Number(src.min) || 0, max: Number(src.max) || 0, step: Number(src.step) || 0 }
    : null
  base.value = locked ? null : safeValue(src.item, state, false)
  base.checked = locked ? null : state.checked === true
  base.selected = locked ? null : (src.selected === true)
  base.infoOpen = state.info === true
  base.optionsAvailable = options.length > 0
  base.confirmation = confirm
    ? { kind: String(confirm.kind || "activate"), stages: Number(confirm.stages) || 1,
      stage: Number(state.confirmStage) || 0 }
    : null
  base.flow = flow
    ? { active: flow.active === true, step: Number(flow.index) || 0,
      kind: String(flow.kind || ""), ready: flow.ready === true,
      values: locked ? null : (flow.values || {}) }
    : null
  base.limits = limits
  base.protected = locked
  return base
}

function optionsProjection(options, selected, protectedRow) {
  const out = []
  const list = Array.isArray(options) ? options : []
  for (let i = 0; i < list.length; i++) {
    const o = list[i]
    if (!o || typeof o !== "object") continue
    out.push({
      id: optionId(i),
      label: o.label !== undefined && o.label !== null ? String(o.label) : String(o.value ?? ""),
      value: protectedRow ? null : o.value,
      enabled: o.enabled !== false,
      selected: String(o.value) === String(selected)
    })
  }
  return out
}

function confirmStatus(kind, stage, descriptor) {
  const total = descriptor ? Number(descriptor.stages) || 1 : 0
  return {
    kind: kind ? String(kind) : null,
    stage: Number(stage) || 0,
    total: total
  }
}

function flowStatus(flow, kind, protectedRow) {
  const f = withFlow(flow)
  return {
    active: f.active === true,
    step: f.index,
    kind: String(kind || ""),
    ready: f.ready === true,
    values: protectedRow || !f.active ? null : Object.assign({}, f.values)
  }
}

// Flow records are kept beside item state, not in a second state machine.
function withFlow(flow) {
  const base = { active: false, index: 0, values: {}, visited: [], ready: false,
    draft: { set: false, value: null } }
  if (!flow || typeof flow !== "object") return base
  return {
    active: flow.active === true,
    index: Number(flow.index) || 0,
    values: flow.values && typeof flow.values === "object" ? flow.values : {},
    visited: Array.isArray(flow.visited) ? flow.visited.slice() : [],
    ready: flow.ready === true,
    draft: flow.draft && typeof flow.draft === "object"
      ? { set: flow.draft.set === true, value: flow.draft.value } : base.draft
  }
}

// The row projection when the menu is closed. Kept identical for status and
// current so a script never has to special-case either one.
function closedSnapshot(revision) {
  return {
    open: false, page: null, depth: 0, scope: "none",
    revision: Number(revision) || 0, row: null, pending: false
  }
}

function scopeOf(globalActive, scopedActive) {
  return globalActive ? "global" : scopedActive ? "scoped" : "none"
}

// Guard verdict -> result vocabulary. There is exactly one mapping, so a
// refused row reads the same from every leaf.
function guardResult(code) {
  if (code === null || code === undefined) return null
  if (code === "not-found") return fail("not-found", "row not found")
  if (code === "stale") return fail("stale", "row reference is retired")
  if (code === "unavailable") return fail("unavailable", "menu is closed")
  if (code === "unsupported") return fail("unsupported", "operation not supported")
  if (code === "busy") return fail("busy", "guard or result handoff pending")
  if (code === "protected") return fail("unsupported", "protected row")
  return fail("refused", "row is blocked")
}
