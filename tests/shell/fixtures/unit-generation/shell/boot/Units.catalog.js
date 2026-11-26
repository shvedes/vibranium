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
    id: "unit01",
    provider: "floor",
    phase: "floor",
    activation: "eager",
    criticality: "essential",
    dependencies: [],
    retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 800 },
    hasReady: true,
    hasTeardown: false
  },
  {
    id: "unit02",
    provider: "floor",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit01"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit03",
    provider: "floor",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit02"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit04",
    provider: "floor",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit03"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit05",
    provider: "floor",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit04"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit06",
    provider: "floor",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit05"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit07",
    provider: "floor",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit06"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit08",
    provider: "floor",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit07"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit09",
    provider: "floor",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit08"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit10",
    provider: "floor",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit09"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit11",
    provider: "floor",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit10"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit12",
    provider: "floor",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit11"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit13",
    provider: "floor",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit12"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit14",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit13"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: true,
    hasTeardown: false
  },
  {
    id: "unit15",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit14"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit16",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit15"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit17",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit16"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit18",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit17"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit19",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit18"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit20",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit19"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit21",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit20"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit22",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit21"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit23",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit22"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit24",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit23"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit25",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit24"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit26",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit25"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit27",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit26"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit28",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit27"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit29",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit28"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit30",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit29"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit31",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit30"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit32",
    provider: "services",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit31"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit33",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit32"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: true,
    hasTeardown: true
  },
  {
    id: "unit34",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit33"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit35",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit34"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit36",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit35"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit37",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit36"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit38",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit37"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit39",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit38"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit40",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit39"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit41",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit40"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit42",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit41"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit43",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit42"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit44",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit43"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit45",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit44"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit46",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit45"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit47",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit46"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit48",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit47"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit49",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit48"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit50",
    provider: "features",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit49"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: false,
    hasTeardown: false
  },
  {
    id: "unit51",
    provider: "bar",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit50"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: true,
    hasTeardown: true
  },
  {
    id: "unit52",
    provider: "demand",
    phase: "early",
    activation: "resident",
    criticality: "optional",
    dependencies: ["unit51"],
    retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
    hasReady: true,
    hasTeardown: true
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
