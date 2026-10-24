// The level vocabulary and the grammar of a logging spec.
//
// A spec answers two questions and nothing else: which levels are on, and
// which scope subtrees are silenced or pinned to their own level. It arrives
// as one comma-separated string - `VIBRANIUM_SHELL_LOG`, and there is no
// second source to reconcile it against - and `parseSpec` and `resolve` are
// its two halves.
//
// The level set is CATEGORICAL, not a threshold. `debug` does not imply
// `info`, and that is the whole reason `VIBRANIUM_SHELL_LOG=debug` and
// `debug,info` are two different asks rather than one ask and a synonym: the
// first is "show me what the deep code is doing, and stop narrating the
// shell's lifecycle", the second is "show me both". So naming a verbose
// level enables exactly that level, and `error`/`warn` are the floor every
// spec carries unless it is `off` or excludes them with `-error` / `-warn`.
// The floor is ordered among itself (`warn` implies `error`) because those
// two are one band - something is wrong - while the verbose levels are not.
//
// Precedence, most specific first:
//
//   1. a `-<scope>` term matches the scope or any dot-descendant -> silent;
//   2. otherwise the longest matching `<scope>=<level>` override wins, so
//      `bar=warn,bar.archUpdates=trace` splits the subtree at the deeper key;
//   3. otherwise the global level set applies.
//
// Nothing here throws. A term the grammar does not recognise is collected in
// `warnings` and dropped: a logger that refuses to emit because of a typo in
// an environment variable turns a cosmetic mistake into a silent subsystem,
// and the caller has no way to report it - reporting it needs the logger.
//
// The one ambiguity that survives is a bare term that is not a level, which is
// read as a scope. That is what `<scope>` meaning "only that scope" costs, and
// it is the right way round: a misspelled level selects a scope nobody owns and
// logs nothing, where warning on every bare term would refuse every real scope
// name.
.pragma library

.import "LogScope.js" as Scope

// Most severe first. The order is the documentation of what "more verbose"
// means and is what `describe` renders.
var LEVELS = ["error", "warn", "info", "debug", "trace"]
// The three a caller opts into by name. The other two are the floor.
var VERBOSE = ["info", "debug", "trace"]
var FLOOR = ["error", "warn"]
var OFF = "off"
var DEFAULT_LEVEL = "info"
// Terms that turn the global set off rather than naming a level in it.
var SILENT = ["off", "none", "silent", "quiet"]
var WILDCARD = "*"

// Spellings accepted for a level, keyed by the lowercased input. Short forms
// are deliberately absent: a one-letter term is indistinguishable from a scope
// called `d`, and a spec whose meaning depends on that is a spec nobody can
// read. `off` is not here - it is a spec-only term, not a level in the set.
var LEVEL_ALIASES = {
  "error": "error",
  "err": "error",
  "warn": "warn",
  "warning": "warn",
  "info": "info",
  "debug": "debug",
  "trace": "trace",
  "tracing": "trace"
}

// A shared frozen empty set, returned wherever a scope resolves to silence.
// Every caller reads it, none writes it.
var EMPTY = Object.freeze({})

// normalizeLevel(value) -> the canonical level name, "off", or null.
//
// null means "not a level at all", which is a different answer from "off":
// an unrecognized term in the spec is a warning, while `off` is a request.
// Callers must not collapse the two.
function normalizeLevel(value) {
  if (typeof value !== "string") return null
  const key = value.trim().toLowerCase()
  if (key === "") return null
  if (Object.prototype.hasOwnProperty.call(LEVEL_ALIASES, key)) return LEVEL_ALIASES[key]
  if (SILENT.indexOf(key) >= 0) return OFF
  return null
}

// baseLevels(name) -> the set a level name expands to.
//
// A name is a band, and a band carries everything more severe in it:
//
//   off -> {}                    error -> {error}
//   warn -> {error, warn}        info  -> {error, warn, info}
//   debug -> {error, warn, debug}
//   trace -> {error, warn, trace}
//
// The one step that is not monotonic is debug, and that is the whole point of
// the vocabulary: it names the deep-code records and not the lifecycle ones,
// which is why `debug` and `debug,info` are different asks. A spec's set is
// the union of this over every level it named, which is what makes `error`
// mean errors alone and `debug` mean errors, warnings and debug.
function baseLevels(name) {
  const level = normalizeLevel(name)
  const canonical = level === null ? DEFAULT_LEVEL : level
  const set = {}
  if (canonical === OFF) return set
  set[FLOOR[0]] = true
  if (canonical === "error") return set
  set[FLOOR[1]] = true
  if (VERBOSE.indexOf(canonical) < 0) return set
  set[canonical] = true
  return set
}

// unionLevels(names) -> the set a spec's named levels add up to.
function unionLevels(names) {
  const set = {}
  const keys = Object.keys(names)
  for (let i = 0; i < keys.length; i++) {
    const expanded = baseLevels(keys[i])
    for (const key in expanded) set[key] = true
  }
  return set
}

// isScopeName(value) -> true for a dotted scope identifier.
//
// Deliberately stricter than a string check: the term ends up as an object
// key that selects log output, so a term carrying whitespace, a slash or a
// glob is a mistake worth reporting rather than a scope nobody will match.
function isScopeName(value) {
  return typeof value === "string" &&
    /^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)*$/.test(value)
}

// warning(parsed, text) - record one term the grammar could not use.
function warning(parsed, text) {
  if (parsed.warnings.length < 32) parsed.warnings.push(text)
  else if (parsed.warnings.length === 32) parsed.warnings.push("... further terms dropped")
}

// parseSpec(text) -> { levels, off, dropped, overrides, silenced, bare, warnings }
//
// `levels` is null when the spec named no level at all, which is the signal
// that the base level from settings still decides it. A bare scope term
// (`clipboard`) is not a level selection either: it empties the global set
// and pins that subtree to the base level, which only `resolve` can apply
// because only it knows the base level.
//
// Every key in `overrides` and `silenced` is lowercased here, so the lookup
// in levelsFor never has to normalize and the case-insensitive matching is
// decided in one place.
function parseSpec(text) {
  const parsed = {
    levels: null,
    off: false,
    dropped: {},
    overrides: {},
    silenced: {},
    labels: {},
    bare: [],
    // Whether a non-empty spec string was read at all. `resolve` needs this
    // rather than a null `levels`, because `clipboard` and `off` both leave
    // `levels` null while being a spec, and only the first of those is a
    // configuration the settings must not touch.
    live: false,
    warnings: []
  }
  if (typeof text !== "string") return parsed
  const trimmed = text.trim()
  if (trimmed === "") return parsed
  parsed.live = true

  const named = {}
  let namedAny = false
  const terms = trimmed.split(",")
  for (let i = 0; i < terms.length; i++) {
    const term = terms[i].trim()
    if (term === "") continue

    // <scope>=<level>, the override form. Split on the FIRST `=` so a level
    // is never re-read out of a scope name.
    const eq = term.indexOf("=")
    if (eq > 0) {
      const scope = term.slice(0, eq).trim()
      const raw = term.slice(eq + 1).trim()
      const level = normalizeLevel(raw)
      if (!isScopeName(scope)) {
        warning(parsed, "term '" + term + "' is not a scope=level pair")
        continue
      }
      if (level === null) {
        warning(parsed, "term '" + term + "' names no known level")
        continue
      }
      const key = scope.toLowerCase()
      parsed.overrides[key] = level
      parsed.labels[key] = scope
      continue
    }
    if (eq === 0) {
      warning(parsed, "term '" + term + "' has no scope before '='")
      continue
    }

    // -<level> removes one level, -<scope> silences one subtree. Levels are
    // tested first: a scope is never spelled like a level, so the order only
    // decides which of two impossible readings wins.
    if (term.charAt(0) === "-") {
      const body = term.slice(1).trim()
      if (body === "") {
        warning(parsed, "term '" + term + "' is empty after '-'")
        continue
      }
      const level = normalizeLevel(body)
      if (level !== null && level !== OFF) {
        parsed.dropped[level] = true
        continue
      }
      if (!isScopeName(body)) {
        warning(parsed, "term '" + term + "' is neither a level nor a scope")
        continue
      }
      const key = body.toLowerCase()
      parsed.silenced[key] = true
      parsed.labels[key] = body
      continue
    }

    // Checked before normalizeLevel on purpose: `off` normalizes to "off",
    // which is a spec directive and never a member of the level set.
    if (SILENT.indexOf(term.toLowerCase()) >= 0) {
      parsed.off = true
      continue
    }

    // `*` names every band rather than the widest one. `trace` is the widest
    // band but it is not every band - it excludes info and debug by
    // construction - so expanding `*` to it would silently mean "no info and
    // no debug", which is the opposite of what `*` reads as.
    if (term === WILDCARD) {
      for (let l = 0; l < LEVELS.length; l++) named[LEVELS[l]] = true
      namedAny = true
      continue
    }

    const level = normalizeLevel(term)
    if (level !== null && level !== OFF) {
      named[level] = true
      namedAny = true
      continue
    }

    if (!isScopeName(term)) {
      warning(parsed, "term '" + term + "' is not a level or a scope")
      continue
    }
    parsed.bare.push(term)
  }

  // A spec that named levels replaces the base selection rather than adding
  // to it; `debug` has to be able to turn info OFF, which is the whole
  // reason it exists.
  if (namedAny) parsed.levels = named
  return parsed
}

// resolve(parsed, baseLevel) -> the frozen configuration a gate reads.
//
// `baseLevel` is the level to use when the spec names none. It is NOT a second
// source: it is a default, and the only caller passes nothing and so gets
// DEFAULT_LEVEL. There is no settings-side per-scope map to merge against,
// so there is no merge rule to predict: one source, one resolution.
//
// Scope keys are folded to lowercase so two spellings of one scope cannot
// both be live with different levels and leave the winner to object-key
// order. `labels` keeps the spelling the user actually wrote, because the
// configuration is echoed back in `status` and in the startup line and
// `bar.archupdates` is not what they typed.
function resolve(parsed, baseLevel) {
  const spec = parsed && typeof parsed === "object" ? parsed : parseSpec(null)
  const base = normalizeLevel(baseLevel)
  const baseName = base === null ? DEFAULT_LEVEL : base

  const levels = spec.levels !== null && spec.levels !== undefined
    ? unionLevels(spec.levels)
    : baseLevels(baseName)
  if (spec.off) {
    for (const key in levels) delete levels[key]
  }
  if (spec.dropped) {
    for (const key in spec.dropped) delete levels[key]
  }

  const warnings = (spec.warnings || []).slice()
  const overrides = ({})
  const silenced = ({})
  const labels = ({})
  for (const key in spec.overrides) {
    overrides[key] = spec.overrides[key]
    labels[key] = spec.labels[key] !== undefined ? spec.labels[key] : key
  }

  // A bare scope term is `only this`: the global set empties and the subtree
  // is pinned to the base level. An explicit override for the same scope was
  // already written above and wins, so `clipboard,clipboard=trace` is the
  // long way of saying what `clipboard=trace` says in one term.
  const bare = spec.bare || []
  if (bare.length > 0) {
    for (const key in levels) delete levels[key]
    for (let i = 0; i < bare.length; i++) {
      const key = bare[i].toLowerCase()
      if (!Object.prototype.hasOwnProperty.call(overrides, key)) {
        overrides[key] = baseName
        labels[key] = bare[i]
      }
    }
  }

  for (const key in spec.silenced) {
    silenced[key] = true
    labels[key] = spec.labels[key] !== undefined ? spec.labels[key] : key
  }

  return {
    levels: levels,
    overrides: overrides,
    silenced: silenced,
    labels: labels,
    warnings: warnings,
    baseLevel: baseName
  }
}

// levelsFor(resolved, scope) -> the level set that applies to one scope.
//
// The three returned sets are shared objects owned by `resolved` and must be
// treated as read-only: a per-scope memo in the caller holds onto them, and
// the point of resolving once per configuration change is that nothing
// rewrites them per message.
function levelsFor(resolved, scope) {
  if (!resolved) return baseLevels(DEFAULT_LEVEL)
  const key = typeof scope === "string" ? scope.toLowerCase() : ""
  if (Scope.mostSpecificMatch(resolved.silenced, key) !== null) return EMPTY
  // A scope term ADDS a band rather than pinning the scope to it, so
  // `warn,pass.passController=debug` is "everything at warn, and the pass
  // controller also at debug". Pinning would make the most useful DEBUG spec
  // inexpressible: `scope=info,scope=debug` would take only the last term, so
  // a scope could never hold INFO and DEBUG together and there would be no way
  // to widen one subtree without widening or narrowing all of them.
  //
  // The whole covering chain applies, least specific first, because each term
  // builds on what it inherits. `off` still silences: it empties the set at
  // that point in the chain, so `bar=off` silences the subtree and a deeper
  // `bar.archUpdates=debug` can still re-enable it - the same "a descendant
  // may re-enable its parent" property the longest-wins rule gave.
  //
  // The cost, stated rather than hidden: a scope term cannot REMOVE a band
  // the base allows. Narrowing is `off` or a `-scope` exclusion.
  const chain = Scope.matchingChain(resolved.overrides, key)
  if (chain.length === 0) return resolved.levels
  const out = Object.assign({}, resolved.levels)
  for (let i = 0; i < chain.length; i++) {
    const added = baseLevels(resolved.overrides[chain[i]])
    if (Object.keys(added).length === 0) {
      for (const existing in out) delete out[existing]
      continue
    }
    Object.assign(out, added)
  }
  return out
}

// allows(resolved, scope, level) -> whether one record would be emitted.
function allows(resolved, scope, level) {
  return levelsFor(resolved, scope)[level] === true
}

// stringify(value) -> the printed form of one message part.
//
// Objects and arrays are expanded rather than left as `[object Object]`,
// because DEBUG is where the caller prints the data it has and a log line
// that refuses to hold it makes the level pointless. Nothing is truncated:
// a caller that has too much to print has a bug in what it chose to print,
// and a silent cut would hide it. A value JSON.stringify refuses - a cycle,
// or a QML object that is not a value type - degrades to String(value)
// rather than taking the message with it.
function stringify(value) {
  if (typeof value === "string") return value
  if (value === null) return "null"
  if (value === undefined) return "undefined"
  const kind = typeof value
  if (kind === "number" || kind === "boolean") return String(value)
  if (kind === "function") return "function " + (value.name || "anonymous")
  if (kind === "symbol") return String(value)
  // Duck-typed rather than `instanceof Error`, because a library and the code
  // that calls it can sit in different realms - a node vm context in this
  // suite is one - and an error crossing that boundary is an Error-shaped
  // object with no shared prototype. `instanceof` would silently print it as
  // `{}`, which is the one value a log line must never reduce an error to.
  if (kind === "object" && typeof value.name === "string" &&
      typeof value.message === "string" && typeof value.stack === "string") {
    return value.message === "" ? value.name : value.name + ": " + value.message
  }
  if (Array.isArray(value)) {
    const parts = []
    for (let i = 0; i < value.length; i++) parts.push(stringify(value[i]))
    return "[" + parts.join(", ") + "]"
  }
  if (kind === "object") {
    let text = null
    try {
      text = JSON.stringify(value)
    } catch (error) {
      return String(value)
    }
    // JSON.stringify answers undefined for a value it cannot represent, and
    // undefined.toLowerCase() would throw on the next line of the pipeline.
    return typeof text === "string" ? text : String(value)
  }
  return String(value)
}

// join(parts) -> the message, with every part space-separated.
function join(parts) {
  if (!Array.isArray(parts) || parts.length === 0) return ""
  const parts2 = []
  for (let i = 0; i < parts.length; i++) parts2.push(stringify(parts[i]))
  return parts2.join(" ")
}

// The bound a summarised string is cut to. 48 is the bound this tree already
// uses for the one client-controlled string it lets reach a user-visible
// surface (`Privacy._notifyAppLimit`), reused here so "bounded in the shell"
// means one number rather than a per-caller habit.
var SUMMARY_LIMIT = 48

// summarize(value) -> the bounded form of a value, for a line that has to name
// what changed without printing what it changed into.
//
// The rule is deliberately blunt: a scalar small enough to read is printed, a
// string is cut at SUMMARY_LIMIT with its real length kept so the reader can
// see that it WAS cut, and a container is reduced to its shape. No object is
// ever walked and no array is ever joined, because a settings value can be a
// thirty-field bar layout or an `env.*` projection carrying a pasted token -
// and printing one whole is how that ends up in a log.
//
// `stringify` is the right function for a DEBUG line that is deliberately
// dumping data and the wrong one here: it expands objects and arrays on
// purpose, which is exactly what this must not do.
function summarize(value) {
  if (value === null) return "null"
  if (value === undefined) return "undefined"
  const kind = typeof value
  if (kind === "boolean" || kind === "number") return String(value)
  if (kind === "string") {
    // The reported length is the character count, not the byte count, so a cut
    // multi-byte string reports a number a reader can compare against what they
    // typed.
    if (value.length <= SUMMARY_LIMIT) return value
    return value.slice(0, SUMMARY_LIMIT) + "…(" + value.length + ")"
  }
  if (kind === "function") return "function"
  if (kind === "symbol") return String(value)
  if (Array.isArray(value)) return "array[" + value.length + "]"
  if (kind === "object") {
    const keys = Object.keys(value)
    return "object{" + keys.length + "}"
  }
  return String(value)
}

// levelList(set) -> the set's members, most severe first, for display.
function levelList(set) {
  const out = []
  for (let i = 0; i < LEVELS.length; i++) {
    if (set && set[LEVELS[i]] === true) out.push(LEVELS[i])
  }
  return out
}

// describe(resolved) -> the resolved configuration as plain data, for `status`
// and for a human reading the log after a surprise.
function describe(resolved) {
  if (!resolved) return null
  const overrides = ({})
  const overrideKeys = Object.keys(resolved.overrides)
  for (let i = 0; i < overrideKeys.length; i++) {
    overrides[label(resolved, overrideKeys[i])] = resolved.overrides[overrideKeys[i]]
  }
  const silencedKeys = Object.keys(resolved.silenced).sort()
  const silenced = []
  for (let i = 0; i < silencedKeys.length; i++) silenced.push(label(resolved, silencedKeys[i]))
  return {
    baseLevel: resolved.baseLevel,
    levels: levelList(resolved.levels),
    overrides: overrides,
    silenced: silenced,
    warnings: resolved.warnings ? resolved.warnings.slice() : []
  }
}

// label(resolved, key) -> the scope spelled the way its author wrote it.
function label(resolved, key) {
  return resolved.labels && resolved.labels[key] !== undefined ? resolved.labels[key] : key
}

// grammar() -> the spec syntax, as the `help` command renders it.
function grammar() {
  return [
    "terms are comma separated",
    "  <level>          turn one level on (error warn info debug trace)",
    "  -<level>         turn one level off, from whatever is on",
    "  -<scope>         silence a scope and everything under it",
    "  <scope>=<level>  pin a scope subtree to a level, repeatable",
    "  <scope>          only that scope, at the base level",
    "  off|none|silent  empty the global set; overrides still win",
    "  *                every level",
    "",
    "error and warn are the floor: naming a verbose level never silences",
    "them, and never re-enables one that was not asked for. Levels are a",
    "set, not a threshold, so debug does not imply info."
  ].join("\n")
}