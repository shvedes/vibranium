// Pure-JS settings engine: JSONC stripping, schema parsing, merge +
// validation, bash env rendering and menu bundle generation.
//
// No Qt imports - everything here is deterministic and unit-drivable.
// The schema lives in a directory, $VIBRANIUM/default/vibranium/settings/:
// per-domain JSONC files (shell/, env/, hypr/, misc/) plus _index.jsonc
// root chrome. Directory decides namespace: shell/* holds only shell.*,
// env/* only bare UPPER_SNAKE, hypr/* only hypr.*, misc/* only misc.*.
// A lone APP_LAUNCHER_ALWAYS_FOCUS rides the App launcher page in
// shell/11-launcher.jsonc, PLAYER_FADE_DURATION rides the media page,
// and misc.cursorTheme and misc.cursorSize ride
// the General page as documented cross-namespace exceptions.
//
//   {
//     "title": "Settings",        // root page title (optional)
//     "pages": [                  // "sections" alias kept
//       {
//         "label": "Recording",   // page title / submenu label
//         "desc": "...",          // ctrl-i only, never rendered inline
//         "icon": "recording",   // submenu icon (optional)
//         "showItemCount": true,  // inline "N options" under the label
//         "options": [ { "key": "RECORDING_FPS", ... } ],
//         "items": [ ...raw menu items appended after generated rows... ]
//       }
//     ]
//   }
//
// Pages are uniform menu pages. The file uses one type only - no parent/
// child split. `pages` and `sections` are aliases. The generated
// bundle is pages directly; a synthetic "settings" index is prepended when
// no explicit page with id "settings" exists. Top-level `title` configures
// that index.
//
// A `width` key is accepted on either level and sizes nothing: a card is as
// wide as the rows it shows (MenuPanel measures them), so the generated
// pages carry no width of their own.
//
// Options are keyed by a single `key` field. Dotted keys are shell paths
// (`shell.wallpaper.enabled`) stored under userData.shell; bare keys are
// bash vars (`RECORDING_FPS`) stored under userData.options and projected
// into settings.env. `var`/`id` remain as compat shims.
//
// Conditional visibility: an option may declare
//   "showIf": { "key": "OTHER_KEY", "eq": value }
//   "showIf": [ { "key": "X", "eq": v }, { "key": "Y", "in": [v1, v2] } ]
// Keys AND together, arrays mean any-of, chains resolve transitively with
// cycle safety. UI-only - hidden options keep their value and stay
// projected into the env file. `var` inside showIf kept as shim.
.pragma library

.import "../text/StringUtils.js" as SU

// Canonical helpers live in StringUtils.js; call SU.* directly.

// Re-exported for the three stores, which reach this library as `SL` and
// read the catalog index through it. The canonical home is still
// StringUtils.js; this is the same one-line re-export MenuLib.js and
// LauncherLib.js carry, and without it every store's index read is a
// TypeError that the catch below turns into a store with no options.
function stripJsonc(raw) { return SU.stripJsonc(raw) }

const TYPES = {
  bool: true,
  int: true,
  float: true,
  string: true,
  // First-class bar-zone layout (e.g. shell.statusbar.layout): object
  // with array zones, validated by validateLayout below.
  layout: true,
  // First-class idle timer list (e.g. shell.idle.timers): validated by
  // validateIdleTimers below, never by shallow passthrough.
  timers: true
}

const VISIBILITY = { visible: true, hidden: true, internal: true }

// The one cross-namespace exception: an env key riding its shell page.
const SHELL_CROSS_OK = { APP_LAUNCHER_ALWAYS_FOCUS: true, PLAYER_FADE_DURATION: true, "misc.cursorTheme": true, "misc.cursorSize": true }

// --- schema parsing ---

// Shell keys are absolute configuration paths under the shell
// namespace: "shell.wallpaper.enabled", "shell.launcher.sortMethod".
// Bare keys are bash vars. Hypr keys are hyprland file-backed options
// ("hypr.input.sensitivity") handled by HyprlandSettings. Misc keys are
// cursor/browser file-backed options handled by MiscSettings.
const SHELL_ID_RE = /^shell(\.[A-Za-z0-9_-]+)+$/
const HYPR_ID_RE = /^hypr(\.[A-Za-z0-9_-]+)+$/
const MISC_ID_RE = /^misc(\.[A-Za-z0-9_-]+)+$/

// Normalize one raw showIf (key/eq/neq/in shapes from the catalog file)
// into the internal var/op/arg list conditionsMet evaluates. Returns
// { norm: [...] } (norm null when empty) or { error }. Shared by options
// and raw custom items so both get identical visibility semantics.
function normalizeShowIf(raw) {
  if (raw === undefined || raw === null) return { norm: null }
  const list = Array.isArray(raw) ? raw : [raw]
  const norm = []
  for (let c = 0; c < list.length; c++) {
    const cond = list[c]
    if (!cond || typeof cond !== "object" || Array.isArray(cond)) {
      return { error: "condition is not an object" }
    }
    const condKey = typeof cond.key === "string" && cond.key !== "" ? cond.key
      : typeof cond.var === "string" ? cond.var : ""
    if (condKey === "") {
      return { error: "condition missing \"key\"" }
    }
    cond.var = condKey // normalize to var field for internal use
    const hasEq = cond.eq !== undefined
    const hasNeq = cond.neq !== undefined
    const hasIn = cond.in !== undefined
    const ops = (hasEq ? 1 : 0) + (hasNeq ? 1 : 0) + (hasIn ? 1 : 0)
    if (ops !== 1) {
      return { error: "condition needs exactly one of eq | neq | in" }
    }
    const scalar = v => v === true || v === false || typeof v === "number" || typeof v === "string"
    if (hasIn) {
      if (!Array.isArray(cond.in) || cond.in.length === 0 || !cond.in.every(scalar)) {
        return { error: "\"in\" needs a non-empty array of scalars" }
      }
      norm.push({ var: cond.var, op: "in", arg: cond.in.slice() })
    } else if (hasEq) {
      if (!scalar(cond.eq)) { return { error: "\"eq\" needs a scalar" } }
      norm.push({ var: cond.var, op: "eq", arg: cond.eq })
    } else {
      if (!scalar(cond.neq)) { return { error: "\"neq\" needs a scalar" } }
      norm.push({ var: cond.var, op: "neq", arg: cond.neq })
    }
  }
  return { norm: norm.length > 0 ? norm : null }
}

  // Validate a staged-flow descriptor: non-empty array of steps, each with
  // kind select|number|range|text. Select steps need a non-empty options
  // array of {label, value}; number/range steps accept optional min/max/
  // step/unit (defaults inherit the option's own validated fields at
  // build time); text steps accept optional placeholder/initialText.
  // skipUnless (string) marks a conditional stage skipped unless stage 0
  // picked that value - the only branching vocabulary steps get.
  // Returns {value} (deep copy) or {error}.
  function normalizeFlow(raw, key) {
    if (!Array.isArray(raw) || raw.length === 0)
      return { error: key + ": flow must be a non-empty array of steps" }
    if (raw.length > 4)
      return { error: key + ": flow holds at most 4 stages" }
    const out = []
    for (let i = 0; i < raw.length; i++) {
      const s = raw[i]
      if (!s || typeof s !== "object" || Array.isArray(s))
        return { error: key + ": flow step " + i + " is not an object" }
      const kind = s.kind
      if (kind !== "select" && kind !== "number" && kind !== "range" && kind !== "text")
        return { error: key + ": flow step " + i + " needs kind select|number|range|text" }
      const step = { kind: kind }
      if (typeof s.placeholder === "string" && s.placeholder !== "")
        step.placeholder = s.placeholder
      if (typeof s.skipUnless === "string" && s.skipUnless !== "")
        step.skipUnless = s.skipUnless
      // Per-stage narration: rendered live by Entry while the step shows
      // (sub even when "" to blank the base line under an accent tail).
      if (typeof s.sub === "string") step.sub = s.sub
      if (typeof s.subAccent === "string" && s.subAccent !== "") step.subAccent = s.subAccent
      if (typeof s.subLead === "string" && s.subLead !== "") step.subLead = s.subLead
      if (typeof s.desc === "string") step.desc = s.desc
      if (kind === "select") {
        if (!Array.isArray(s.options) || s.options.length === 0)
          return { error: key + ": flow select step " + i + " needs non-empty options" }
        const opts = []
        for (let o = 0; o < s.options.length; o++) {
          const so = s.options[o]
          if (!so || typeof so !== "object")
            return { error: key + ": flow select step " + i + " option " + o + " is not an object" }
          if (typeof so.value !== "string" && typeof so.value !== "number")
            return { error: key + ": flow select step " + i + " option " + o + " needs a value" }
          opts.push({
            label: typeof so.label === "string" && so.label !== ""
              ? so.label : String(so.value),
            value: so.value
          })
        }
        step.options = opts
      } else if (kind === "number" || kind === "range") {
        if (s.min !== undefined) {
          if (typeof s.min !== "number" || !isFinite(s.min))
            return { error: key + ": flow number step " + i + " min must be a number" }
          step.min = s.min
        }
        if (s.max !== undefined) {
          if (typeof s.max !== "number" || !isFinite(s.max))
            return { error: key + ": flow number step " + i + " max must be a number" }
          step.max = s.max
        }
        if (step.min !== undefined && step.max !== undefined && step.min >= step.max)
          return { error: key + ": flow number step " + i + " min must be < max" }
        if (s.step !== undefined) {
          if (typeof s.step !== "number" || !(s.step > 0))
            return { error: key + ": flow number step " + i + " step must be > 0" }
          step.step = s.step
        }
        if (typeof s.unit === "string" && s.unit !== "") step.unit = s.unit
      }
      out.push(step)
    }
    return { value: out }
  }

// Normalize one raw option object. Returns {opt} or {error}.
// fileNamespace ("shell"|"env"|"hypr"|"misc") asserts directory-equals-
// namespace; omit it (single-file path) to skip the assertion.
function parseOption(raw, fileNamespace) {
  if (!raw || typeof raw !== "object") return { error: "option is not an object" }

  // Unified key: `key` is canonical, `var`/`id` are compat shims.
  let rawKey = ""
  if (typeof raw.key === "string" && raw.key !== "") rawKey = raw.key
  else if (typeof raw.var === "string" && raw.var !== "") {
    rawKey = raw.var
  } else if (typeof raw.id === "string" && raw.id !== "") {
    rawKey = raw.id
  }
  if (rawKey === "") return { error: "option needs \"key\" (or compat \"var\"/\"id\")" }
  const key = rawKey

  // Hyprland backend detection: explicit `hypr` object or key prefix hypr.
  let isHypr = false
  let hyprMeta = null
  if (raw.hypr !== undefined && raw.hypr !== null) {
    if (typeof raw.hypr !== "object" || Array.isArray(raw.hypr))
      return { error: key + ": hypr must be an object" }
    isHypr = true
  } else if (HYPR_ID_RE.test(key)) {
    isHypr = true
    // Implicit hypr from key prefix - synthesize minimal meta
    raw.hypr = {}
  }

  if (isHypr) {
    // Validate hypr binding
    const h = raw.hypr
    let kind = typeof h.kind === "string" && h.kind !== "" ? h.kind : "option"
    const allowedKinds = { option: true, smartGaps: true, animPreset: true }
    if (!allowedKinds[kind]) return { error: key + ": hypr.kind must be option|smartGaps|animPreset" }
    let file = typeof h.file === "string" ? h.file : ""
    // smartGaps and animPreset have default files if not supplied
    if (file === "") {
      if (kind === "smartGaps") file = "$XDG_CONFIG_HOME/hypr/hyprland.conf.d/smart-gaps.lua"
      else if (kind === "animPreset") file = "$XDG_CONFIG_HOME/hypr/hyprland.conf.d/animations.lua"
      else return { error: key + ": hypr.file must be a non-empty string" }
    }
    let hyprPath = null
    if (h.path !== undefined) {
      if (Array.isArray(h.path)) {
        hyprPath = h.path.slice()
        for (let i = 0; i < hyprPath.length; i++)
          if (typeof hyprPath[i] !== "string" || hyprPath[i] === "")
            return { error: key + ": hypr.path array must contain non-empty strings" }
        if (hyprPath.length === 0) return { error: key + ": hypr.path must not be empty" }
      } else if (typeof h.path === "string" && h.path !== "") {
        hyprPath = h.path.split(":")
      } else return { error: key + ": hypr.path must be string or array" }
    } else if (typeof h.ctl === "string" && h.ctl !== "") {
      hyprPath = h.ctl.split(".")
    } else if (kind === "option") {
      // Derive path from key: strip "hypr." prefix
      if (!HYPR_ID_RE.test(key)) return { error: key + ": hypr option key must be hypr.*" }
      hyprPath = key.slice(5).split(".")
    }
    let ctl = typeof h.ctl === "string" && h.ctl !== "" ? h.ctl : (hyprPath ? hyprPath.join(".") : "")
    if (kind === "option" && (!hyprPath || hyprPath.length === 0 || ctl === ""))
      return { error: key + ": hypr option needs path/ctl" }
    if (!HYPR_ID_RE.test(key))
      return { error: key + ": hypr key must be hypr.* (e.g. hypr.input.sensitivity)" }
    hyprMeta = { file: file, path: hyprPath, ctl: ctl, kind: kind }
  }

  const isMisc = MISC_ID_RE.test(key)
  const isEnv = !isHypr && !isMisc && key.indexOf(".") < 0
  // Compat: explicit env:false on a bare key is rejected - bare keys are always env
  if (!isEnv && !isHypr && !isMisc && raw.env === true) return { error: key + ": dotted keys cannot have env:true" }

  if (!isHypr && !isMisc && !isEnv && !SHELL_ID_RE.test(key))
    return { error: key + ": shell key must be a full dotted path starting with \"shell.\" (pages are UI-only)" }

  // Directory decides namespace: the option key must match the file it
  // was loaded from, except the documented shell-page riders
  // (APP_LAUNCHER_ALWAYS_FOCUS on the launcher page,
  // PLAYER_FADE_DURATION on the media page, misc.cursorTheme and
  // misc.cursorSize on the General page).
  if (typeof fileNamespace === "string" && fileNamespace !== "") {
    const actual = isHypr ? "hypr" : (isMisc ? "misc" : (isEnv ? "env" : "shell"))
    if (actual !== fileNamespace && !(fileNamespace === "shell" && SHELL_CROSS_OK[key]))
      return { error: key + ": namespace mismatch - " + actual + " option in " + fileNamespace + " file" }
  }
  const type = (() => {
    const t = typeof raw.type === "string" ? raw.type : ""
    // Accepted spellings: generic object/array become first-class
    // layout/timers, so a catalog written in the old shape keeps parsing
    // with an identical runtime shape.
    if (t === "object" || t === "array") {
      return t === "object" ? "layout" : "timers"
    }
    return t
  })()
  if (!TYPES[type]) return { error: key + ": unknown type '" + type + "'" }
  // Env vars are scope-prefixed WITHOUT the VIBRANIUM_ prefix (the runtime
  // namespace is implied): RECORDING_FPS, GLOBAL_SEARCH_ENGINE, ...
  if (isEnv) {
    if (key.indexOf("VIBRANIUM_") === 0)
      return { error: key + ": drop the VIBRANIUM_ prefix - it is implied" }
    if (!/^[A-Z][A-Z0-9_]*$/.test(key))
      return { error: key + ": env vars must be UPPER_SNAKE_CASE" }
  }

  let min, max
  if (raw.range !== undefined && raw.range !== null) {
    if (Array.isArray(raw.range) && raw.range.length === 2
      && typeof raw.range[0] === "number" && typeof raw.range[1] === "number") {
      if (raw.range[0] >= raw.range[1]) return { error: key + ": range min must be < max" }
      min = raw.range[0]
      max = raw.range[1]
    } else if (typeof raw.range === "object"
      && typeof raw.range.min === "number" && typeof raw.range.max === "number") {
      if (!(raw.range.min < raw.range.max)) return { error: key + ": range min must be < max" }
      min = raw.range.min
      max = raw.range.max
    } else return { error: key + ": range must be {min,max}" }
  }
  if (min !== undefined && type === "bool") return { error: key + ": range not allowed on bool" }

  let values = []
  if (Array.isArray(raw.values)) {
    if (type === "string") values = raw.values.filter(v => typeof v === "string" && v !== "")
    else if (type === "int" || type === "float") values = raw.values.filter(v => typeof v === "number" && isFinite(v))
    else values = raw.values.filter(v => typeof v === "string" && v !== "")
  }

  // Conditional visibility against other options' values. Accepted shapes:
  //
  //   "showIf": { "key": "X", "eq": true }                    one condition (var alias kept)
  //   "showIf": [ { "key": "X", "eq": true },
  //               { "key": "Y", "in": ["a", "b"] } ]          ANDed list
  //
  // Operators: eq | neq | in. Conditions over shell-only options use their
  // full canonical path ("shell.lockscreen.blurPower") as key. UI-only:
  // hidden options keep their value and stay projected into the env file.
  // For conditions on external reality (paths, processes) use
  // "when"/"disabled" instead - those run through the batched bash guard
  // pipeline.
  let showIf = null
  if (raw.showIf !== undefined && raw.showIf !== null) {
    const res = normalizeShowIf(raw.showIf)
    if (res.error) return { error: key + ": malformed showIf - " + res.error }
    showIf = res.norm
  }

  // External-reality conditions on options are structured `requires`
  // ({chassis} and/or {binary}); free bash survives only on raw `items`
  // (actions), which keep `when` verbatim. An option `when` from an
  // older catalog translates with a warning, then lint rejects it.
  let requires = null
  if (raw.requires !== undefined && raw.requires !== null) {
    if (typeof raw.requires !== "object" || Array.isArray(raw.requires))
      return { error: key + ": requires must be an object" }
    const rq = {}
    if (raw.requires.chassis !== undefined) {
      if (typeof raw.requires.chassis !== "string" || raw.requires.chassis.trim() === "")
        return { error: key + ": requires.chassis must be non-empty string" }
      rq.chassis = raw.requires.chassis.trim()
    }
    if (raw.requires.binary !== undefined) {
      if (typeof raw.requires.binary !== "string" || raw.requires.binary.trim() === "")
        return { error: key + ": requires.binary must be non-empty string" }
      rq.binary = raw.requires.binary.trim()
    }
    if (Object.keys(rq).length === 0) return { error: key + ": requires needs at least chassis or binary" }
    requires = rq
  } else if (raw.when !== undefined || raw.disabled !== undefined) {
    const w = typeof raw.when === "string" ? raw.when.trim() : ""
    if (w !== "") {
      if (w.indexOf("wiremix") >= 0) requires = { binary: "wiremix" }
      else if (w.indexOf("CHASSIS_TYPE") >= 0 && w.indexOf("laptop") >= 0) requires = { chassis: "laptop" }
      else if (w.indexOf("CHASSIS_TYPE") >= 0 && w.indexOf("!= vm") >= 0) requires = { chassis: "!vm" }
      else return { error: key + ": when not translatable - use requires" }
    }
  }

  // Staged input flow (spec 41): ordered steps rendered one at a time in
  // a single expansion (see MenuLib flow contract). Passthrough - parsed
  // and validated here, copied onto the menu item in buildItem. Null when
  // absent. Malformed flows are schema errors (fail-soft: option dropped).
  let flow = null
  if (raw.flow !== undefined && raw.flow !== null) {
    const fres = normalizeFlow(raw.flow, key)
    if (fres.error) return { error: fres.error }
    flow = fres.value
  }

  // Visibility taxonomy: visible rows render, hidden rows validate +
  // persist without rendering (click hooks), internal rows do the same
  // for programmatic state (layout, timers) and are never counted or
  // bundled. `hidden` stays as the derived compat flag.
  let visibility = "visible"
  if (typeof raw.visibility === "string" && VISIBILITY[raw.visibility]) visibility = raw.visibility
  else if (raw.hidden === true) visibility = "hidden"
  if (type === "layout" || type === "timers") visibility = "internal"

  const opt = {
    key: key,
    env: isEnv,
    hypr: hyprMeta,
    misc: isMisc,
    id: key,
    type: type,
    label: typeof raw.label === "string" ? raw.label : prettify(key),
    desc: typeof raw.desc === "string" ? raw.desc : "",
    sub: typeof raw.sub === "string" ? raw.sub : "",
    warning: typeof raw.warning === "string" ? raw.warning : "",
    unit: typeof raw.unit === "string" ? raw.unit : "",
    step: typeof raw.step === "number" && raw.step > 0 ? raw.step : 1,
    min: min,
    max: max,
    values: values,
    valueLabels: raw.valueLabels && typeof raw.valueLabels === "object" ? raw.valueLabels : null,
    visibility: visibility,
    hidden: visibility !== "visible",
    showIf: showIf,
    when: "",
    disabled: "",
    requires: requires,
    hook: typeof raw.hook === "string" ? raw.hook : "",
    allowEmpty: raw.allowEmpty === true,
    flow: flow,
    default: raw.default
  }

  const check = validateValue(opt, opt.default)
  if (!check.ok) return { error: key + ": bad default " + JSON.stringify(opt.default) + " (" + check.error + ")" }
  opt.default = check.value
  return { opt: opt }
}

// Deterministic menu page id from a section label. Sections carry no id of
// their own - the label is their identity in the UI and this keeps the
// generated page ids stable across loads.
function sectionPageId(label) {
  const s = String(label).toLowerCase()
    .replace(/&/g, " ")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
  return s !== "" ? s : "section"
}

// Parse one section object (a UI category): label/desc/icon/
// showItemCount metadata, options with full validation, and raw custom menu
// items. Parse errors land in section.errors; offending options are dropped
// (fail-soft). `fallback` names the page when no label is given.
// `pages` alias kept for compat; both produce pages uniformly.
// fileNamespace asserts directory-equals-namespace on every option.
// `width` is accepted and carried but sizes nothing: the card measures its
// own rows (see the header note).
function parseSection(raw, fallback, allowId, fileNamespace) {
  const section = {
    page: "",
    label: "",
    desc: "",
    icon: "",
    width: 0,
    showItemCount: false,
    options: [],
    items: [],
    errors: []
  }

  if (!raw || typeof raw !== "object") {
    section.errors.push("page is not an object")
    section.label = String(fallback)
    section.page = sectionPageId(section.label)
    return section
  }

  if (typeof raw.id === "string" && raw.id !== "" && !allowId)
    section.errors.push("sections have no \"id\" - it is ignored; options own full paths")
  // title is alias for label (single type)
  if (typeof raw.label === "string") section.label = raw.label
  else if (typeof raw.title === "string") section.label = raw.title
  if (section.label === "") section.label = prettify(String(fallback))
  if (allowId && typeof raw.id === "string" && raw.id !== "" && /^[a-z0-9_-]+$/.test(raw.id))
    section.page = raw.id
  else {
    if (allowId && typeof raw.id === "string" && raw.id !== "" )
      section.errors.push("page id must be [a-z0-9_-]")
    section.page = sectionPageId(section.label)
  }
  if (typeof raw.desc === "string") section.desc = raw.desc
  if (typeof raw.icon === "string") section.icon = raw.icon
  if (typeof raw.width === "number" && raw.width > 0) section.width = raw.width
  if (raw.showItemCount !== undefined) {
    if (typeof raw.showItemCount !== "boolean")
      section.errors.push("showItemCount must be a boolean")
    else section.showItemCount = raw.showItemCount
  }
  if (Array.isArray(raw.items)) {
    // Custom items (actions, submenus, ...) may carry showIf conditions
    // with the same semantics as options - normalize them now so menu
    // visibility checks resolve against current values.
    section.items = raw.items.map(it => {
      if (!it || typeof it !== "object" || Array.isArray(it)) return it
      if (it.showIf === undefined || it.showIf === null) return it
      const res = normalizeShowIf(it.showIf)
      if (res.error) {
        section.errors.push("item " + (typeof it.label === "string" ? JSON.stringify(it.label) : "") + ": malformed showIf - " + res.error)
        return Object.assign({}, it, { showIf: null })
      }
      return Object.assign({}, it, { showIf: res.norm })
    })
  }

  const seen = {}
  const list = Array.isArray(raw.options) ? raw.options : []
  for (let i = 0; i < list.length; i++) {
    const res = parseOption(list[i], fileNamespace)
    if (res.error) {
      section.errors.push(res.error)
      continue
    }
    if (seen[res.opt.key]) {
      section.errors.push(res.opt.key + ": duplicate option")
      continue
    }
    seen[res.opt.key] = true
    section.options.push(res.opt)
  }
  return section
}

// Parse the single catalog file: { "pages": [page, ...] } with `sections`
// alias for compat. A bare page object is tolerated for resilience. After
// parsing, showIf references are validated against the full key set -
// unknown or self-referencing vars are pruned with a warning (a condition
// on nothing would silently hide rows forever). Top-level `title` names the
// synthetic "settings" index page.
function parseCatalog(text) {
  const raw = JSON.parse(SU.stripJsonc(text))
  const hasPages = Array.isArray(raw.pages)
  const hasSections = Array.isArray(raw.sections)
  const rawSections = hasPages ? raw.pages : (hasSections ? raw.sections : (Array.isArray(raw) ? raw : [raw]))
  const allowId = hasPages || Array.isArray(raw)
  // Carried for compatibility with catalogs that declare it; no card is
  // sized from it (see the header note).
  const rootWidth = typeof raw.width === "number" && raw.width > 0 ? Math.round(raw.width) : 0
  const rawTitle = typeof raw.title === "string" && raw.title.trim() !== "" ? raw.title.trim()
    : typeof raw.label === "string" && raw.label.trim() !== "" ? raw.label.trim() : ""
  const rootTitle = rawTitle

  const sections = []
  const byKey = {}
  for (let i = 0; i < rawSections.length; i++) {
    const section = parseSection(rawSections[i], "section " + (i + 1), allowId, null)
    sections.push(section)
    for (let o = 0; o < section.options.length; o++) {
      byKey[section.options[o].key] = section.options[o]
    }
  }

  // Derived page ids must stay unique: identical labels get a numeric
  // suffix so navigation never merges two pages.
  const seenPages = {}
  for (let s = 0; s < sections.length; s++) {
    let page = sections[s].page
    let n = 2
    while (seenPages[page] !== undefined) page = sections[s].page + "-" + n++
    seenPages[page] = true
    sections[s].page = page
  }

  pruneShowIf(sections, byKey, true)

  return { sections: sections, byKey: byKey, rootWidth: rootWidth, rootTitle: rootTitle, pages: sections, allowId: allowId }
}

// Reference validation for showIf: every condition var must exist in the
// catalog. Strict mode (single-file catalog) prunes unknown refs
// with a warning - a condition on nothing would silently hide rows
// forever. Directory mode keeps unknown refs: stores scan only their own
// namespace files, but conditions may point at another store's keys
// (shell rows gated on hypr.* values), which the menu resolves per-store
// at runtime. Self-references are always pruned.
function pruneShowIf(sections, byKey, strict) {
  for (let s = 0; s < sections.length; s++) {
    const opts = sections[s].options
    for (let o = 0; o < opts.length; o++) {
      const opt = opts[o]
      if (!opt.showIf) continue
      for (let c = opt.showIf.length - 1; c >= 0; c--) {
        const k = opt.showIf[c].var
        if (k === opt.key) {
          sections[s].errors.push(opt.key + ": showIf references itself - condition dropped")
          opt.showIf.splice(c, 1)
        } else if (strict && byKey[k] === undefined) {
          sections[s].errors.push(opt.key + ": showIf references unknown option '" + k + "' - condition dropped")
          opt.showIf.splice(c, 1)
        }
      }
      if (opt.showIf.length === 0) opt.showIf = null
    }
  }
}

// Parse the directory catalog: one JSONC text per file, each with its
// namespace ("shell"|"env"|"hypr"|"misc"). Root chrome comes from
// _index.jsonc (rootWidth/rootTitle args). Duplicate keys across files
// are a hard error; identical page labels dedupe with a -2 suffix;
// showIf keeps cross-file refs (see pruneShowIf).
function parseCatalogDir(fileTexts, fileNamespaces, rootWidth, rootTitle) {
  const sections = []
  const byKey = {}
  for (let f = 0; f < fileTexts.length; f++) {
    const raw = JSON.parse(SU.stripJsonc(fileTexts[f]))
    const rawSections = Array.isArray(raw.pages) ? raw.pages
      : (Array.isArray(raw.sections) ? raw.sections : (Array.isArray(raw) ? raw : [raw]))
    for (let i = 0; i < rawSections.length; i++) {
      const section = parseSection(rawSections[i], "section " + (i + 1), true, fileNamespaces[f])
      for (let o = 0; o < section.options.length; o++) {
        const k = section.options[o].key
        if (byKey[k] !== undefined) throw new Error("duplicate option across files: " + k)
        byKey[k] = section.options[o]
      }
      sections.push(section)
    }
  }
  const seenPages = {}
  for (let s = 0; s < sections.length; s++) {
    let page = sections[s].page
    let n = 2
    while (seenPages[page] !== undefined) page = sections[s].page + "-" + n++
    seenPages[page] = true
    sections[s].page = page
  }
  pruneShowIf(sections, byKey, false)
  return {
    sections: sections,
    pages: sections,
    byKey: byKey,
    rootWidth: typeof rootWidth === "number" && rootWidth > 0 ? Math.round(rootWidth) : 0,
    rootTitle: typeof rootTitle === "string" ? rootTitle : "",
    allowId: true
  }
}

// Evaluate one normalized showIf list against current values. Entries AND
// together. Transitive: a referenced option that is itself conditionally
// hidden suppresses its dependents. Cycle-safe (a cycle counts as
// satisfied - visibility stays deterministic, no loops).
function conditionsMet(byKey, values, showIf, seen) {
  if (!showIf || showIf.length === 0) return true
  seen = seen || {}
  for (let i = 0; i < showIf.length; i++) {
    const cond = showIf[i]
    const cur = values[cond.var]
    let ok
    if (cond.op === "in") ok = cond.arg.indexOf(cur) >= 0
    else if (cond.op === "neq") ok = cur !== cond.arg
    else ok = cur === cond.arg

    if (ok) {
      const dep = byKey[cond.var]
      if (dep && dep.showIf && !seen[cond.var]) {
        seen[cond.var] = true
        ok = conditionsMet(byKey, values, dep.showIf, seen)
      }
    }
    if (!ok) return false
  }
  return true
}

// --- validation / normalization ---

function _toNumber(v) {
  if (typeof v === "number") return isFinite(v) ? v : NaN
  if (typeof v === "string") {
    const t = v.trim().replace(",", ".")
    if (t === "" || !/^-?[0-9]+(\.[0-9]+)?$/.test(t)) return NaN
    const n = Number(t)
    return isFinite(n) ? n : NaN
  }
  return NaN
}

// First-class bar-zone layout validation. The one structural gate for a
// layout value: object with array zones of deduped non-empty id strings.
// Unknown keys are ignored. Returns {value} (normalized) or {error}.
function validateLayout(v) {
  if (v === null || typeof v !== "object" || Array.isArray(v))
    return { error: "expected an object" }
  const zones = { left: [], center: [], right: [], disabled: [] }
  const names = ["left", "center", "right", "disabled"]
  for (let z = 0; z < names.length; z++) {
    const list = v[names[z]]
    if (list === undefined) continue
    if (!Array.isArray(list)) return { error: "layout." + names[z] + " must be an array" }
    for (let i = 0; i < list.length; i++) {
      const id = list[i]
      if (typeof id !== "string" || id === "")
        return { error: "layout." + names[z] + " must hold non-empty strings" }
      if (zones[names[z]].indexOf(id) < 0) zones[names[z]].push(id)
    }
  }
  return { value: zones }
}

// Validate + normalize one value against an option. Returns {ok,value,error}.
// Accepts lowercase bools (the strings "true"/"false"), comma decimals, leading
// zeros stripped, inclusive range bounds, and exact enum membership. Int and
// float enums additionally use `values` + `valueLabels` (e.g. VRR 0/1/2).
function validateValue(opt, v) {
  switch (opt.type) {
    case "bool": {
      if (v === true) return { ok: true, value: true }
      if (v === false) return { ok: true, value: false }
      if (v === "true") return { ok: true, value: true }
      if (v === "false") return { ok: true, value: false }
      return { ok: false, error: "expected true or false" }
    }
    case "int":
    case "float": {
      const n = _toNumber(v)
      if (isNaN(n)) return { ok: false, error: "expected a number" }
      if (isNaN(n % 1) === false && opt.type === "int" && n % 1 !== 0)
        return { ok: false, error: "expected an integer" }
      if (opt.min !== undefined && n < opt.min) return { ok: false, error: "minimum is " + opt.min }
      if (opt.max !== undefined && n > opt.max) return { ok: false, error: "maximum is " + opt.max }
      if (opt.values && opt.values.length > 0 && opt.values.indexOf(n) < 0)
        return { ok: false, error: "expected one of: " + opt.values.join(", ") }
      return { ok: true, value: n }
    }
    case "string": {
      if (typeof v !== "string") return { ok: false, error: "expected a string" }
      const t = v.trim()
      if (t === "") {
        if (opt.allowEmpty) return { ok: true, value: "" }
        return { ok: false, error: "expected a non-empty string" }
      }
      if (opt.values.length > 0 && opt.values.indexOf(t) < 0)
        return { ok: false, error: "expected one of: " + opt.values.join(", ") }
      return { ok: true, value: t }
    }
    case "layout": {
      const res = validateLayout(v)
      if (res.error) return { ok: false, error: res.error }
      return { ok: true, value: res.value }
    }
    case "timers": {
      const err = validateIdleTimers(v)
      if (err !== "") return { ok: false, error: err }
      return { ok: true, value: v.slice() }
    }
  }
  return { ok: false, error: "unknown type" }
}

// --- idle daemon timers ---

// The declared session effect of a timer row: which inhibitor guards it
// consults before the action runs. "lock" rows are gated by the idle
// blockers, "suspend" rows by the sleep blockers, and a command row only
// when it declares one. A declaration is never inferred from the command
// text - an arbitrary string says nothing about what it does to the
// session - so the closed set below is all a row can claim.
const IDLE_CLASSES = ["", "lock", "suspend"]

// The declared class as written, without coercion: an unknown value is not
// an absent one, and must not be repaired into one.
function declaredIdleClass(r) {
  return r.commandClass === undefined || r.commandClass === null
    ? "" : String(r.commandClass)
}

// Whole-argv-word spellings of the project's own session verbs. A stored
// timer written before the class field existed is reconciled with this
// closed list; the match is on complete words, so `loginctl lock-session`
// and any wrapped or piped variant stay undeclared.
const IDLE_VERB_CLASS = {
  "vb-shell session lock": "lock",
  "vb-shell lockscreen lock": "lock",
  "vb-shell session suspend": "suspend"
}

// Fill an absent class for a row whose command is one of the project's own
// session verbs. Pure and idempotent: a row that declares a class keeps it,
// a row that matches nothing is returned undeclared, and nothing else about
// the row is touched. A malformed list comes back unchanged so the caller
// still sees the validation error rather than a repaired shape.
function normalizeIdleTimers(list) {
  if (!Array.isArray(list)) return list
  let changed = false
  const out = []
  for (let i = 0; i < list.length; i++) {
    const r = list[i]
    if (typeof r !== "object" || r === null || Array.isArray(r)) return list
    if (r.action === "command" && declaredIdleClass(r) === "" && typeof r.command === "string") {
      const found = IDLE_VERB_CLASS[String(r.command).trim()]
      if (found !== undefined) {
        out.push({ minutes: r.minutes, action: r.action, command: r.command, commandClass: found })
        changed = true
        continue
      }
    }
    out.push(r)
  }
  return changed ? out : list
}

// True when a command is one of those whole-argv-word spellings, which the
// read path declares on its own. A timer running one of them cannot be left
// undeclared, so a writer has to say so rather than report a change that the
// next read undoes.
function declaresOwnCommand(command) {
  return typeof command === "string"
    && IDLE_VERB_CLASS[String(command).trim()] !== undefined
}

// Write-path validation for the idle daemon's timer list (the Settings
// store's setIdleTimers and the idle IPC surface both funnel through
// here). Returns "" when `list` is a legal timer list, else an error
// string. Rules: an array of {minutes, action[, command][, commandClass]}
// rows with positive integer minutes, known actions, a known declared class
// when one is present, strictly increasing minutes, and no two timers
// sharing the same action - a second lock/suspend could never fire
// meaningfully, and a repeated command is just a duplicate. Two command
// timers with different commands are distinct actions and may coexist
// (identity is the trimmed command text plus the declared class, so the
// same text declared as a lock and as a suspend are two timers).
function validateIdleTimers(list) {
  if (!Array.isArray(list)) return "timers must be an array"
  const seenMinutes = {}
  const seenActions = {}
  for (let i = 0; i < list.length; i++) {
    const r = list[i]
    if (typeof r !== "object" || r === null || Array.isArray(r))
      return "timer " + (i + 1) + " must be an object"
    const m = r.minutes
    if (typeof m !== "number" || !isFinite(m) || m <= 0 || Math.floor(m) !== m)
      return "timer " + (i + 1) + " minutes must be a positive integer"
    const a = r.action
    if (a !== "lock" && a !== "suspend" && a !== "command")
      return "timer " + (i + 1) + " action must be lock, suspend or command"
    if (a === "command" && typeof r.command !== "string")
      return "timer " + (i + 1) + " command action needs a command string"
    const c = declaredIdleClass(r)
    if (IDLE_CLASSES.indexOf(c) === -1)
      return "timer " + (i + 1) + " commandClass must be lock, suspend or empty"
    if (seenMinutes[m] !== undefined) return "duplicate timer minutes: " + m
    seenMinutes[m] = true
    if (i > 0 && m <= list[i - 1].minutes)
      return "timers must be strictly increasing by minutes"
    const key = a === "command" ? "command:" + c + ":" + String(r.command).trim() : a
    if (seenActions[key] !== undefined)
      return "timer " + (i + 1) + " duplicates the action of timer " + seenActions[key]
    seenActions[key] = i + 1
  }
  return ""
}

// --- resolution (defaults <- user overrides) ---

// Structured deep copy. The composition and the store both hand live
// objects around, so a copy on the way in and on the way out is what
// keeps either side from aliasing the other's state.
function _deepClone(v) {
  if (Array.isArray(v)) {
    const out = new Array(v.length)
    for (let i = 0; i < v.length; i++) out[i] = _deepClone(v[i])
    return out
  }
  if (v !== null && typeof v === "object") {
    const out = {}
    const keys = Object.keys(v)
    for (let i = 0; i < keys.length; i++) out[keys[i]] = _deepClone(v[keys[i]])
    return out
  }
  return v
}

// Read a dotted path (array of segments) inside a nested object.
function readPath(obj, segs) {
  let cur = obj
  for (let i = 0; i < segs.length; i++) {
    if (!cur || typeof cur !== "object") return undefined
    cur = cur[segs[i]]
  }
  return cur
}

// Write a leaf at a dotted path, creating intermediate objects. Returns
// false when an intermediate collides with a non-object.
function writePath(obj, segs, v) {
  let cur = obj
  for (let i = 0; i < segs.length - 1; i++) {
    const next = cur[segs[i]]
    if (next === undefined || next === null || typeof next !== "object") {
      cur[segs[i]] = {}
    } else if (Array.isArray(next)) {
      return false
    }
    cur = cur[segs[i]]
  }
  cur[segs[segs.length - 1]] = v
  return true
}

// Remove the leaf at a dotted path; empty parent objects are pruned so the
// user file stays sparse.
function prunePath(obj, segs) {
  if (segs.length === 0) return
  const parent = readPath(obj, segs.slice(0, -1))
  if (!parent || typeof parent !== "object") return
  delete parent[segs[segs.length - 1]]
  for (let i = segs.length - 2; i >= 0; i--) {
    const p = readPath(obj, segs.slice(0, i + 1))
    if (!p || typeof p !== "object" || Object.keys(p).length > 0) return
    // Prune the now-empty object from ITS parent.
    const gp = readPath(obj, segs.slice(0, i))
    if (!gp || typeof gp !== "object") return
    delete gp[segs[i]]
  }
}

// Walk parsed user data and produce the RAW overrides map keyed
// canonically, unvalidated: env options under userData.options.VAR,
// shell-only options at their full id path inside userData.shell.
// Hypr/misc options are skipped. resolve() is the only place a raw
// override becomes authoritative.
function extractOverrides(schema, userData) {
  const out = {}
  if (!schema || !userData || typeof userData !== "object") return out

  const opts = userData.options
  if (opts && typeof opts === "object") {
    for (const k in opts) {
      if (schema.byKey[k] !== undefined && !schema.byKey[k].hypr && !schema.byKey[k].misc) out[k] = opts[k]
    }
  }
  const shell = userData.shell && typeof userData.shell === "object" ? userData.shell : {}
  for (const key in schema.byKey) {
    const opt = schema.byKey[key]
    if (opt.env || opt.hypr || opt.misc) continue
    // Strip the leading "shell." segment - it IS the namespace object.
    const v = readPath(shell, opt.key.split(".").slice(1))
    if (v !== undefined) out[key] = v
  }
  return out
}

// Full resolution: schema defaults overlaid with the validated overrides.
// A rejected override lands in issues[] and nowhere else - values keeps the
// schema default, validOverrides omits the key entirely, and raw carries
// the parsed source for diagnostics. The store composes its managed view
// from validOverrides only, so an invalid value can never be re-persisted.
function resolve(schema, userData) {
  const values = {}
  const issues = []
  for (const key in schema.byKey) values[key] = schema.byKey[key].default

  const validOverrides = {}
  const rawOverrides = extractOverrides(schema, userData)
  for (const key in rawOverrides) {
    const check = validateValue(schema.byKey[key], rawOverrides[key])
    if (check.ok) {
      values[key] = check.value
      validOverrides[key] = check.value
    } else {
      issues.push(key + ": " + check.error + " - using default")
    }
  }
  return { values: values, validOverrides: validOverrides, issues: issues, raw: userData }
}

// Parse a user settings source. Returns {raw, fault}: `raw` is the parsed
// object, and `fault` is "" or "malformed". An empty or comment-only file is
// an empty source, not a fault. A source that does not parse, or whose root
// is not an object, is reported and never repaired - the caller keeps the
// file and holds its own writes until a later read parses.
function parseUserSource(text) {
  const stripped = SU.stripJsonc(String(text === undefined || text === null ? "" : text))
  if (stripped.trim() === "") return { raw: {}, fault: "" }
  let data
  try {
    data = JSON.parse(stripped)
  } catch (e) {
    return { raw: {}, fault: "malformed" }
  }
  if (data === null || typeof data !== "object" || Array.isArray(data))
    return { raw: {}, fault: "malformed" }
  return { raw: data, fault: "" }
}

// Compose the managed view of the user file: a deep clone of the last
// parsed source with every currently valid managed leaf set from
// `validOverrides`. Env options live under "options", shell options under
// "shell" at their full path; hypr and misc options belong to their own
// stores and never appear here.
//
// A managed leaf with no valid override is pruned only when the schema
// accepts the value the source holds - that is a leaf the store
// intentionally reset to a default. A leaf the schema rejects is left
// exactly as the user wrote it: dropping it would delete their own file
// content, and overwriting it with the default would hide the fault.
// Foreign fields ride through untouched.
//
// Pure: neither argument is mutated, and no object in the result is shared
// with the inputs.
function composeManaged(schema, raw, validOverrides) {
  const out = _deepClone(raw !== null && typeof raw === "object" && !Array.isArray(raw) ? raw : {})
  if (!schema || !schema.byKey) return out
  const ov = validOverrides !== null && typeof validOverrides === "object" ? validOverrides : {}
  for (const key in schema.byKey) {
    const opt = schema.byKey[key]
    if (!opt || opt.hypr || opt.misc) continue
    const segs = opt.env ? ["options", key] : ["shell"].concat(key.split(".").slice(1))
    if (ov[key] !== undefined) {
      writePath(out, segs, _deepClone(ov[key]))
      continue
    }
    const cur = readPath(out, segs)
    if (cur === undefined || !validateValue(opt, cur).ok) continue
    prunePath(out, segs)
  }
  return out
}

// --- store-side pure helpers (delegated to by Settings.qml) ---
//
// Settings.qml is the only owner of settings STATE; these functions own no
// state, hold no default table, open no file and start no process. Each one
// takes the live state as an argument and returns a value or a NEW document,
// which the store then publishes as its own single copy. Nothing here may
// become a second store: a function that needs the schema default, a level
// list, an error string or a fault kind gets it from its caller.
//
//   buildSchema                   schema index + the store's own pages
//   reapplyPending                uncommitted keys survive an external edit
//   valuesEqual                   the "user file holds deviants only" rule
//   changedKeys                   externally flipped keys, for one signal each
//   coerceBool/buildIdleTimerRows write-path validation helpers
//   loadFault                     FileView error code -> source fault
//   rawFlag/rawSectionOf/writeRawSection   raw (non-schema) section access

// Index a parsed catalog into the store's schema shape - the same shape the
// Hyprland and misc stores build inline. `sections` are the already-parsed
// pages; the same array is published as both `sections` and `pages` so one
// parse stays one source. rootWidth/rootTitle pass through as the catalog
// produced them. Returns a NEW schema.
function buildSchema(sections, rootWidth, rootTitle) {
  const secs = Array.isArray(sections) ? sections : []
  const byKey = {}
  for (let i = 0; i < secs.length; i++) {
    const section = secs[i]
    for (let o = 0; o < section.options.length; o++)
      byKey[section.options[o].key] = section.options[o]
  }
  return {
    sections: secs,
    pages: secs,
    byKey: byKey,
    rootWidth: rootWidth,
    rootTitle: rootTitle
  }
}

// Keys committed since the last flush exist only in memory, so an external
// edit must not evict them. Re-stamp them onto the freshly resolved maps:
// `dirty` names the keys, `prev` is the live value map, `byKey` the schema
// index. A key the schema dropped, or one the store had no value for, is
// skipped. Returns new maps - neither argument is mutated.
function reapplyPending(values, validOverrides, byKey, dirty, prev) {
  const nextValues = Object.assign({}, values)
  const nextOverrides = Object.assign({}, validOverrides)
  for (const dk in dirty) {
    if (byKey[dk] === undefined || prev[dk] === undefined) continue
    nextOverrides[dk] = prev[dk]
    nextValues[dk] = prev[dk]
  }
  return { values: nextValues, validOverrides: nextOverrides }
}

// A copy of a settings value with the fields that carry USER CONTENT reduced
// to a yes/no, for any consumer that renders a value for a reader.
//
// The projection exists because a generic value walker cannot know. One that
// walks an object or array to its leaves and prints each is exactly right for
// `shell.statusbar.layout` (a list of module names, where the leaf IS the
// information) and exactly wrong for `shell.idle.timers`, the catalog's one
// array of records: its `command` field is a shell line the user typed, and a
// naive walk of it is how
//
//   +[0].command: "systemctl suspend"
//
// reaches a reader that has no business seeing it. The session daemon - which
// owns those commands - documents the opposite contract for the same data.
//
// So the knowledge lives here, next to the schema it comes from, and every
// call site stays a projection it cannot get wrong. A boolean is still a true
// statement about the row, so the alternative - dropping the field - would say
// LESS and pass a weaker test.
var LOG_REDACT_KEYS = ["command"]

function redactForLog(v) {
  if (v === null || v === undefined) return v
  if (typeof v === "string" || typeof v === "number" || typeof v === "boolean") return v
  if (Array.isArray(v)) {
    const out = []
    for (let i = 0; i < v.length; i++) out.push(redactForLog(v[i]))
    return out
  }
  if (typeof v === "object") {
    const out = {}
    for (const k in v) {
      if (LOG_REDACT_KEYS.indexOf(k) >= 0) {
        out[k] = v[k] === "" ? "unset" : "set"
        continue
      }
      out[k] = redactForLog(v[k])
    }
    return out
  }
  return v
}

// Structural equality for the overlay rule. Scalars compare by identity;
// objects/arrays (layout, idle timers) compare by JSON shape, so a value that
// matches the default is pruned instead of persisted.
function valuesEqual(a, b) {
  if (a === b) return true
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false
  try {
    return JSON.stringify(a) === JSON.stringify(b)
  } catch (e) {
    return false
  }
}

// Externally flipped keys, in the order the previous map enumerates them, so
// the store emits exactly one change per key a reload actually moved. A key
// that is only in `next` is not a flip and is not reported.
function changedKeys(prev, next) {
  const out = []
  for (const key in prev) {
    if (next[key] !== prev[key]) out.push(key)
  }
  return out
}

// The bool coercion the write path accepts: real booleans plus the two string
// spellings validateValue() takes. Returns {ok, value}; the caller owns the
// rejection message, because it names a key.
function coerceBool(v) {
  if (v === true) return { ok: true, value: true }
  if (v === false) return { ok: true, value: false }
  if (v === "true") return { ok: true, value: true }
  if (v === "false") return { ok: true, value: false }
  return { ok: false, value: false }
}

// Build the rows a validated timer list is committed as: minutes + action
// always, the command and its declared class only for a command row. A
// dropped class is a silently ungated timer, so the class is carried through
// the write rather than rebuilt away. Only meaningful for a list that
// validateIdleTimers() already accepted.
function buildIdleTimerRows(list) {
  const clean = []
  for (let i = 0; i < list.length; i++) {
    const row = { minutes: list[i].minutes, action: list[i].action }
    if (row.action === "command") {
      row.command = list[i].command
      row.commandClass = declaredIdleClass(list[i])
    }
    clean.push(row)
  }
  return clean
}

// Classify a blocking read failure. FileViewError 2 (FileNotFound) means
// there is nothing to read yet, which is a normal first boot; every other
// code means the user's content is there and unreadable, which blocks
// persistence until a later read parses. Returns "" or "unreadable".
function loadFault(error) {
  const reason = String(error)
  return reason === "2" || reason === "FileNotFound" ? "" : "unreadable"
}

// A non-schema flag from the raw user file, defaulting to `dflt`. `section`
// is a shell sub-object except for "shell" itself, whose keys sit directly
// under shell. Returns a boolean; anything but `true` reads as false.
function rawFlag(raw, section, key, dflt) {
  const doc = raw || {}
  const shell = doc.shell && typeof doc.shell === "object" ? doc.shell : {}
  const sec = section === "shell" ? shell : (shell[section] && typeof shell[section] === "object" ? shell[section] : {})
  const v = sec[key]
  return v === undefined ? dflt : v === true
}

// A non-schema section of the raw user file, or null when it is absent.
// Compatibility surface: the store returns this LIVE object, so it must not be
// cloned here - callers read it and write through setRawSection instead.
function rawSectionOf(raw, section) {
  const doc = raw || {}
  const shell = doc.shell && typeof doc.shell === "object" ? doc.shell : {}
  const sec = shell[section]
  return sec !== undefined && sec !== null && typeof sec === "object" ? sec : null
}

// Set one leaf of a non-schema section, returning a NEW document. Copies stay
// shallow, so an untouched sibling subtree is still the same object the store
// already held.
function writeRawSection(raw, section, key, v) {
  const doc = raw || {}
  const shell = Object.assign({}, doc.shell && typeof doc.shell === "object" ? doc.shell : {})
  const sec = Object.assign({}, shell[section] && typeof shell[section] === "object" ? shell[section] : {})
  sec[key] = v
  shell[section] = sec
  const next = Object.assign({}, doc)
  next.shell = shell
  return next
}

// --- bash env rendering ---

function formatBashValue(opt, v) {
  switch (opt.type) {
    case "bool":
      return v === true ? "true" : "false"
    case "int":
      return String(Math.round(v))
    case "float": {
      let s = String(v)
      if (s.indexOf("e") >= 0 || s.indexOf("E") >= 0) s = v.toFixed(6)
      return s
    }
    case "string":
      return SU.shellQuote(String(v))  }
  return "''"
}

// Deterministic env file: schema order, only env:true options.
function renderEnv(schema, values) {
  const lines = [
    "# Generated by Vibranium shell. DO NOT EDIT.",
    "# Source of truth: ~/.config/vibranium/settings.json"
  ]
  for (let s = 0; s < schema.sections.length; s++) {
    const section = schema.sections[s]
    let wroteHeader = false
    for (let o = 0; o < section.options.length; o++) {
      const opt = section.options[o]
      if (!opt.env || opt.hypr || opt.misc) continue
      if (!wroteHeader) {
        lines.push("")
        lines.push("# " + section.label)
        wroteHeader = true
      }
      lines.push(opt.key + "=" + formatBashValue(opt, values[opt.key]))
    }
  }
  return lines.join("\n") + "\n"
}

// --- menu bundle generation ---

function prettify(s) {
  return String(s)
    .replace(/[_-]+/g, " ")
    .toLowerCase()
    .replace(/(^| )([a-z])/g, (m, p, c) => p + c.toUpperCase())
}

function enumLabel(opt, v) {
  if (opt.valueLabels && typeof opt.valueLabels[v] === "string") return opt.valueLabels[v]
  return prettify(v)
}

// Build the raw bundle injected into every opened menu: a "settings" root
// page listing all categories that define at least one option, plus one page
// per category with generated rows followed by the file's custom items.
// Uniform pages model: `sections` alias kept, each entry is a page.
// The root page takes the top-level `title` when provided. No page carries
// a width: each card measures the rows it shows. Single menu type - no
// parent/child split.
function buildBundle(schema, values) {
  const src = schema.pages || schema.sections || []
  const pages = []
  const indexItems = []

  // Pages referenced as a submenu target by any other page are CHILDREN:
  // they stay reachable through their parent and are kept out of the
  // top-level Settings index, so a nested catalog (Bar -> Enabled modules
  // -> ...) reads as a clean tree instead of every leaf at the surface.
  const childPages = {}
  for (let c = 0; c < src.length; c++) {
    const side = src[c].items || []
    for (let i = 0; i < side.length; i++) {
      const it = side[i]
      if (it && it.type === "submenu" && typeof it.page === "string" && it.page !== "")
        childPages[it.page] = true
    }
  }

  for (let s = 0; s < src.length; s++) {
    const section = src[s]
    if (visibleItemCount(section, schema.byKey, values) === 0) continue

    const items = []
    for (let o = 0; o < section.options.length; o++) {
      const item = buildItem(section.options[o], values[section.options[o].key])
      if (item) items.push(item)
    }
    for (let i = 0; i < section.items.length; i++) {
      const raw = section.items[i]
      if (!raw || typeof raw !== "object") continue
      // Custom items may declare "after": "<option key>" to sit directly
      // under that generated row instead of appending after all options.
      if (typeof raw.after === "string" && raw.after !== "") {
        const at = items.findIndex(x => x.var === raw.after || x.id === raw.after)
        if (at >= 0) {
          items.splice(at + 1, 0, raw)
          continue
        }
      }
      items.push(raw)
    }

    pages.push({
      id: section.page,
      title: section.label,
      items: items
    })
    const link = {
      type: "submenu",
      label: section.label,
      icon: section.icon,
      page: section.page
    }
    // desc is ctrl-i-only copy; it must never render inline. The count
    // sub line is a separate per-section opt-in and reflects what is
    // visible RIGHT NOW - showIf-hidden options do not count.
    if (section.desc !== "") link.desc = section.desc
    if (section.showItemCount)
      link.sub = itemCountLabel(section, schema.byKey, values)
    // Children (submenu targets) are only reachable via their parent.
    if (!childPages[section.page]) indexItems.push(link)
  }

  const hasExplicitSettings = src.some(p => p.page === "settings")
  if (!hasExplicitSettings) {
    pages.unshift({
      id: "settings",
      title: schema.rootTitle || "Settings",
      items: indexItems
    })
  }
  return { pages: pages }
}

// Currently-visible row count of a section: non-hidden options whose
// showIf passes, plus custom items (separators are chrome, not content).
// Zero means the submenu hides completely - no page, no link, no search
// entries. The caller re-derives this when values change.
function visibleItemCount(section, byKey, values) {
  let n = 0
  for (let o = 0; o < section.options.length; o++) {
    const opt = section.options[o]
    if (opt.hidden) continue
    if (opt.showIf && !conditionsMet(byKey, values, opt.showIf)) continue
    n++
  }
  for (let i = 0; i < section.items.length; i++) {
    const it = section.items[i]
    if (it && it.type !== "separator") n++
  }
  return n
}

// Visible content of a section at the given values: non-hidden options
// whose showIf currently passes, plus custom items (separators are
// chrome, not content). The caller re-derives this when values change so
// the number never drifts from what the section actually shows.
function itemCountLabel(section, byKey, values) {
  let n = 0
  let hasItems = false
  for (let o = 0; o < section.options.length; o++) {
    const opt = section.options[o]
    if (opt.hidden) continue
    if (opt.showIf && !conditionsMet(byKey, values, opt.showIf)) continue
    n++
  }
  for (let i = 0; i < section.items.length; i++) {
    const it = section.items[i]
    if (it && typeof it === "object" && it.type !== "separator") {
      n++
      hasItems = true
    }
  }
  const noun = hasItems ? "item" : "option"
  return n === 1 ? "1 " + noun : n + " " + noun + "s"
}

// One menu row from one option. Type mapping:
//   bool          -> toggle (boolean seed, store persists - no guard expr)
//   string+enum   -> select
//   int/float+enum -> select (numeric labels via valueLabels)
//   int/float+min/max -> range (slider + stepper chips)
//   int/float     -> number
//   free string   -> text
// Hypr options render identically - their var still drives Menu.stateOf
// but persistence routes through HyprlandSettings instead of Settings.
function buildItem(opt, current) {
  if (opt.hidden) return null
  const base = {
    id: opt.key,
    var: opt.key,
    label: opt.label,
    desc: opt.desc || undefined
  }
  if (opt.sub !== "") base.sub = opt.sub
  if (opt.warning !== "") base.warning = opt.warning
  // Store-driven conditions ride as data; bash guards flow through the
  // standard when/disabled pipeline (batched evaluation for free).
  // Structured requires rides alongside showIf; MenuLib emits its guard.
  if (opt.showIf) base.showIf = opt.showIf
  if (opt.when !== "") base.when = opt.when
  if (opt.disabled !== "") base.disabled = opt.disabled
  if (opt.requires) base.requires = opt.requires
  // Staged flow rides every generated row type verbatim; Entry prefers it
  // over the classic single-type rendering when non-null. Bounds not
  // redeclared on a number stage inherit the option's own validated
  // min/max/step/unit so flows stay compact.
  if (opt.flow) {
    const steps = []
    for (let i = 0; i < opt.flow.length; i++) {
      const s = Object.assign({}, opt.flow[i])
      if ((s.kind === "number" || s.kind === "range")) {
        if (s.min === undefined && opt.min !== undefined) s.min = opt.min
        if (s.max === undefined && opt.max !== undefined) s.max = opt.max
        if (s.step === undefined) s.step = opt.step
        if (s.unit === undefined && opt.unit !== "") s.unit = opt.unit
      }
      steps.push(s)
    }
    base.flow = steps
  }

  switch (opt.type) {
    case "bool":
      base.type = "toggle"
      base.checked = current === true
      return base
    case "string":
      if (opt.values.length > 0) {
        base.type = "select"
        base.value = current
        base.options = opt.values.map(v => ({ label: enumLabel(opt, v), value: v }))
        return base
      }
      base.type = "text"
      base.value = String(current)
      return base
    default: {
      // int/float enum -> select
      if (opt.values && opt.values.length > 0) {
        base.type = "select"
        base.value = current
        base.options = opt.values.map(v => ({ label: enumLabel(opt, v), value: v }))
        return base
      }
      const numeric = typeof current === "number" ? current : Number(current)
      base.type = (opt.min !== undefined && opt.max !== undefined) ? "range" : "number"
      base.value = isNaN(numeric) ? opt.default : numeric
      if (opt.min !== undefined) base.min = opt.min
      if (opt.max !== undefined) base.max = opt.max
      base.step = opt.step
      if (opt.unit !== "") base.unit = opt.unit
      return base
    }
  }
}
