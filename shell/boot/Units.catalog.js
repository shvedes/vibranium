.pragma library

// Phase 3 ordered catalog: data-only port of Boot.qml's pre-extraction
// `readonly property var _catalog` literal (52 rows, declaration order).
// `provider` is derived from the pre-extraction resolver site of each id:
//   floor    -> Boot.qml _resolveDescriptor cases (including wallpaper)
//   demand   -> Boot.qml demand-driven annotation loader (annotations)
//   bar      -> Boot.qml _mountBarRuntime (bar)
//   services -> BootServices.qml resolve(id) cases
//   features -> BootLate.qml resolve(id) cases
// hasReady/hasTeardown record whether the old literal declared a function
// for that member; absence changes UnitGate semantics and must survive.
// No closures, no provider imports, no log prose, no durations, no clock.

var catalog = [
  {
    id: "log",
    provider: "floor",
    phase: "floor",
    activation: "eager",
    criticality: "essential",
    dependencies: [],
    retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 },
    hasReady: true,
    hasTeardown: false
  },
  {
    id: "paths",
    provider: "floor",
    phase: "floor",
    activation: "eager",
    criticality: "essential",
    dependencies: [],
    retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 },
    hasReady: true,
    hasTeardown: false
  },
  {
    id: "watch",
    provider: "floor",
    phase: "floor",
    activation: "eager",
    criticality: "essential",
    dependencies: ["paths"],
    retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 },
    hasReady: true,
    hasTeardown: false
  },
  {
    id: "settings",
    provider: "floor",
    phase: "floor",
    activation: "eager",
    criticality: "essential",
    dependencies: ["paths", "watch"],
    retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 },
    hasReady: true,
    hasTeardown: false
  },
  {
    id: "hyprlandSettings",
    provider: "floor",
    phase: "floor",
    activation: "eager",
    criticality: "essential",
    dependencies: ["settings"],
    retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 },
    hasReady: true,
    hasTeardown: false
  },
  {
    id: "miscSettings",
    provider: "floor",
    phase: "floor",
    activation: "eager",
    criticality: "essential",
    dependencies: ["settings"],
    retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 },
    hasReady: true,
    hasTeardown: false
  },
  {
    id: "systemFont",
    provider: "floor",
    phase: "floor",
    activation: "eager",
    criticality: "essential",
    dependencies: ["settings"],
    retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "theme",
    provider: "floor",
    phase: "floor",
    activation: "eager",
    criticality: "essential",
    dependencies: ["settings"],
    retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "ui",
    provider: "floor",
    phase: "floor",
    activation: "eager",
    criticality: "essential",
    dependencies: ["settings", "theme"],
    retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "icons",
    provider: "floor",
    phase: "floor",
    activation: "eager",
    criticality: "essential",
    dependencies: ["settings", "theme"],
    retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 },
    hasReady: true,
    hasTeardown: false
  },
  {
    id: "exec",
    provider: "floor",
    phase: "floor",
    activation: "eager",
    criticality: "essential",
    dependencies: ["paths"],
    retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "state",
    provider: "floor",
    phase: "floor",
    activation: "eager",
    criticality: "essential",
    dependencies: ["paths"],
    retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "idleDaemon",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "inhibitor",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "session",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "essential",
    dependencies: ["settings", "state", "watch"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "lockscreen",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "essential",
    dependencies: ["settings", "session", "state", "watch", "theme"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "wallpaper",
    provider: "floor",
    phase: "visual",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "theme", "paths", "state", "watch", "ui"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "clipboard",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "privacy",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "bar",
    provider: "bar",
    phase: "visual",
    activation: "first_use",
    criticality: "optional",
    dependencies: ["settings", "theme", "ui", "state", "watch"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: true,
    hasTeardown: true
  },
  {
    id: "osd",
    provider: "features",
    phase: "entrance",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "theme", "ui", "state"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "notifications",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "theme", "ui", "state", "privacy"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: true,
    hasTeardown: false
  },
  {
    id: "menu",
    provider: "features",
    phase: "deferred",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch", "ui"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "audio",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "mediaArt",
    provider: "services",
    phase: "deferred",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch", "audio"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "keyboard",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "app",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: true,
    hasTeardown: false
  },
  {
    id: "appLauncher",
    provider: "features",
    phase: "early",
    activation: "facade",
    criticality: "optional",
    dependencies: ["settings", "state", "watch", "paths"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: true,
    hasTeardown: true
  },
  {
    id: "timer",
    provider: "services",
    phase: "entrance",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "recording",
    provider: "services",
    phase: "entrance",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "update",
    provider: "services",
    phase: "entrance",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "paths", "state", "watch"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "polkit",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "theme", "ui", "state", "watch", "session"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "emojiPicker",
    provider: "features",
    phase: "deferred",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "keybindings",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "themePicker",
    provider: "features",
    phase: "deferred",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch", "theme"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "themeRemover",
    provider: "features",
    phase: "deferred",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch", "theme"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "cursorPicker",
    provider: "features",
    phase: "deferred",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch", "theme"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "wallpaperPicker",
    provider: "features",
    phase: "deferred",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch", "paths", "theme"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "fontPicker",
    provider: "features",
    phase: "deferred",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch", "theme", "menu"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "pass",
    provider: "features",
    phase: "early",
    activation: "facade",
    criticality: "optional",
    dependencies: ["settings", "state", "watch", "paths"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: true,
    hasTeardown: true
  },
  {
    id: "audioMixer",
    provider: "features",
    phase: "early",
    activation: "facade",
    criticality: "optional",
    dependencies: ["settings", "state", "watch", "paths"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: true,
    hasTeardown: true
  },
  {
    id: "imageViewer",
    provider: "features",
    phase: "early",
    activation: "facade",
    criticality: "optional",
    dependencies: ["settings", "state", "watch", "paths"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: true,
    hasTeardown: true
  },
  {
    id: "annotations",
    provider: "demand",
    phase: "first_use",
    activation: "first_use",
    criticality: "optional",
    dependencies: ["settings", "state", "watch", "paths"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: true,
    hasTeardown: true
  },
  {
    id: "systemUpdates",
    provider: "services",
    phase: "on_demand",
    activation: "gated_compat",
    criticality: "optional",
    dependencies: ["settings", "state", "watch", "paths"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "powerProfile",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch", "paths"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "printers",
    provider: "services",
    phase: "on_demand",
    activation: "gated_compat",
    criticality: "optional",
    dependencies: ["settings", "state", "watch", "paths"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "powerPolicy",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch", "paths", "powerProfile"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "batteryAlert",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch", "paths"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "connectivity",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["state", "watch", "paths"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "screenshots",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "paths", "state", "watch"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: true,
    hasTeardown: false
  },
  {
    id: "tools",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "paths"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "powerMenu",
    provider: "features",
    phase: "deferred",
    activation: "resident",
    criticality: "optional",
    dependencies: ["settings", "state", "watch", "menu", "session"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  }
]

// Pure helpers: no validation, no side effects, no wall clock, no environment.
function rows() { return catalog }

function byId(id) {
  for (var i = 0; i < catalog.length; i++) {
    if (catalog[i].id === id) return catalog[i]
  }
  return null
}

// Canonical JSON: object keys sorted recursively, arrays kept in declared
// order, so the digest is independent of object key insertion order.
function _canonical(value) {
  if (value === null || typeof value !== "object") return JSON.stringify(value)
  if (Array.isArray(value)) {
    var parts = []
    for (var i = 0; i < value.length; i++) parts.push(_canonical(value[i]))
    return "[" + parts.join(",") + "]"
  }
  var keys = []
  for (var key in value) {
    if (Object.prototype.hasOwnProperty.call(value, key)) keys.push(key)
  }
  keys.sort()
  var fields = []
  for (var j = 0; j < keys.length; j++) {
    fields.push(JSON.stringify(keys[j]) + ":" + _canonical(value[keys[j]]))
  }
  return "{" + fields.join(",") + "}"
}

// FNV-1a, 32-bit, fixed eight-digit lowercase hex.
function _fnv1a(text) {
  var hash = 0x811c9dc5
  for (var i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i)
    hash = Math.imul(hash, 0x01000193) >>> 0
  }
  var hex = hash.toString(16)
  while (hex.length < 8) hex = "0" + hex
  return hex
}

// Digest over the ordered effective descriptors: all data fields, the full
// retry record, the declared dependency order and the presence flags.
function digest() {
  var effective = []
  for (var i = 0; i < catalog.length; i++) {
    var row = catalog[i]
    effective.push({
      id: row.id,
      provider: row.provider,
      phase: row.phase,
      activation: row.activation,
      criticality: row.criticality,
      dependencies: row.dependencies.slice(),
      retry: {
        maxAttempts: row.retry.maxAttempts,
        backoffMs: row.retry.backoffMs,
        maxBackoffMs: row.retry.maxBackoffMs
      },
      hasReady: row.hasReady === true,
      hasTeardown: row.hasTeardown === true
    })
  }
  return _fnv1a(_canonical(effective))
}
