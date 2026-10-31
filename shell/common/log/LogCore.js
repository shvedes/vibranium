// The emitter, and the configuration state it gates on.
//
// This is a `.pragma library` rather than part of `Log.qml` because a QML
// singleton is unreachable from a `.pragma library`: a script import must be
// qualified, and a qualified import gives the script its own scope with no
// view of the QML types. Most of the code deep enough to want a DEBUG record
// is a script (`ClipboardLib.js`, `SettingsLib.js`, the launcher plugins), so
// an emitter only QML could reach would be an emitter for the shallow half of
// the tree.
//
// The cost of moving here is that state has to be module-level rather than a
// property, and one library evaluated once per engine is exactly what makes
// that correct: `Log.qml` and a dozen feature scripts reach this file through
// different relative paths and share one evaluation, so there is one resolved
// configuration and one memo no matter how many callers there are. `Log.qml`
// stays the tree's `Log` and owns *when* the configuration is resolved; this
// file owns what it resolves to.
//
// The gate comes before anything is printed, and the trace is captured by the
// caller rather than here, so a suppressed record costs one map read and no
// stack capture at all - which is what keeps a DEBUG line inside a per-frame
// binding free when DEBUG is off.
.pragma library

.import "LogSpec.js" as Spec
.import "LogScope.js" as Scope

// The environment variable that replaces the settings-side configuration.
var ENV_VAR = "VIBRANIUM_SHELL_LOG"

// The index of the calling frame in a trace captured inside `emit`: 0 is
// `emit`, so 2 is the caller. 1 is never the answer - it is whichever method
// forwarded into `emit`, which for the five shorthands below is `info` here and
// for the QML facade is the identically-named method in `Log.qml`. A caller that
// reaches this file directly is therefore at the SAME index as one going through
// the facade, not one closer: the facade's method and this file's shorthand
// occupy the same slot, so the two cancel. `Log.qml` carries its own constant
// because it is named at the use site rather than shared, not because the
// numbers differ.
//
// Nothing in the tree reaches this file directly today: QML uses the `Log`
// singleton and every `.pragma library` here is a pure library with no logging.
// It is exported for a future script caller, and for that caller 2 is the
// script's own function.
var JS_DEPTH = 2

// The prefix that separates a TRACE record from a DEBUG one in the sink. They
// share `console.debug` on purpose - a UI-draw trace must stay out of the
// journal's warning and error bands - so without this the two are the same
// line. Greppable as `qml: <scope>: ~ `.
var TRACE_MARKER = "~ "

// The scope the logger's own records are filed under. Named here because a
// record about the gate is the one record whose scope cannot be derived from a
// call site in a feature file.
var LOG_SCOPE = "log"

var _resolved = null
// scope -> the level set that applies to it. The sets are owned by `_resolved`
// and shared, so this holds one boolean set per distinct scope rather than a
// copy of the rules per scope. It is bounded by the number of files that log,
// and dropped whole on every configure, so it cannot outlive the shell.
var _scopeLevels = ({})
var _scopedLoggers = ({})
var _specText = ""
// Bumped by every configure and read by announce, so a reconfigure is reported
// and a plain read is not. A sequence rather than the resolved object's
// identity because `configure` builds a fresh object every time.
var _sequence = 0
var _announcedSequence = -1

// configure(specText) -> the resolved configuration.
//
// ONE source, and there is no second one to reconcile with. The environment
// variable is the whole configuration; an empty or missing `specText` means
// "not set", which resolves to the built-in default level rather than to a
// gate that is somehow off.
//
// There is no settings store to merge against, and therefore no merge rule
// to predict. That is also why `Log.qml` never names `Settings` and never has
// to defer reading it a tick, so the boot ordering survives.
//
// Returns the resolved object, so a caller that has just configured can read
// what it resolved to without asking again.
function configure(specText) {
  const live = typeof specText === "string" && specText.trim() !== ""
  _specText = live ? specText.trim() : ""
  _resolved = Spec.resolve(Spec.parseSpec(_specText))
  _scopeLevels = ({})
  _sequence++
  announce()
  return _resolved
}

// There is deliberately no `configureDefault()`.
//
// A default installed separately would exist to cover the window between
// construction and the first configuration: records emitted in that window
// would sit on no configuration at all, and during boot is exactly when the
// shell is most likely to be doing something worth reading about. With the
// environment variable as the only source, and it read synchronously in the
// same `Component.onCompleted` that installs the gate, there is no window to
// cover: `configure(spec)` resolves in the turn it is called, so the gate
// and the configuration land together and a single call does the whole job.

// --- reads ------------------------------------------------------------------

// ready() -> whether a configuration exists. The boot catalog's readiness
// predicate reads this; it is an observation, not a literal.
function ready() { return _resolved !== null }

// fromEnv() -> whether the env var is the live configuration. `Log.qml` reads
// this to know that re-reading settings would be pointless, because the env
// spec is immutable for the life of the shell: a shell that changed its own
// log rules halfway through a session would make two halves of one log
// incomparable.
function fromEnv() { return _resolved !== null && _specText !== "" }

function envVar() { return ENV_VAR }

function specText() { return _specText }

function resolved() { return _resolved }

// baseLevel() -> the level the configuration came from when no spec named one.
function baseLevel() {
  return _resolved === null ? Spec.DEFAULT_LEVEL : _resolved.baseLevel
}

// levels() -> the enabled levels of the global set, most severe first.
function levels() {
  if (_resolved === null) return Spec.levelList(Spec.baseLevels(Spec.DEFAULT_LEVEL))
  return Spec.levelList(_resolved.levels)
}

// silenced() -> the silenced scope subtrees, sorted, spelled as their author
// wrote them.
function silenced() {
  if (_resolved === null) return []
  const keys = Object.keys(_resolved.silenced).sort()
  const out = []
  for (let i = 0; i < keys.length; i++) out.push(Spec.label(_resolved, keys[i]))
  return out
}

// overrides() -> scope -> level for the pinned subtrees, spelled as their
// author wrote them.
function overrides() {
  if (_resolved === null) return ({})
  const out = ({})
  const keys = Object.keys(_resolved.overrides)
  for (let i = 0; i < keys.length; i++) out[Spec.label(_resolved, keys[i])] = _resolved.overrides[keys[i]]
  return out
}

// warnings() -> the terms the grammar rejected, in the order it met them.
function warnings() {
  if (_resolved === null || !_resolved.warnings) return []
  return _resolved.warnings.slice()
}

// --- the gate ---------------------------------------------------------------

// levelsFor(scope) -> the level set that applies to one scope. Public so a
// caller can ask a question the memo already answered rather than re-deriving
// it. The returned object is owned by the configuration and is read-only.
function levelsFor(scope) {
  if (_resolved === null) return Spec.levelsFor(null, scope)
  const key = typeof scope === "string" ? scope.toLowerCase() : ""
  let levels = _scopeLevels[key]
  if (levels === undefined) {
    levels = Spec.levelsFor(_resolved, scope)
    _scopeLevels[key] = levels
  }
  return levels
}

// allows(level, scope) -> whether a record would be emitted. A caller wrapping
// expensive work in a debug log asks this first, rather than building a
// payload that is then thrown away.
function allows(level, scope) {
  return levelsFor(scope)[level] === true
}

// --- the emitter ------------------------------------------------------------

// emit(level, parts, scopeName, depth) -> true when the record was printed.
//
// `parts` is the message already split, so one code path serves the QML facade
// and a script. `scopeName` short-circuits derivation for `at()`. `depth` is
// the caller's frame index in the trace, which differs by call path, so it is
// passed rather than guessed.
//
// The trace is captured here rather than by the caller, which costs a V8 stack
// capture on every call including the suppressed ones. That is why the five
// shorthands below exist: a caller that has already established the record
// would print uses one of them and takes the same capture, while `emit` is the
// only entry that accepts a depth and therefore the only one a caller outside
// this file needs.
function emit(level, parts, scopeName, depth) {
  const scope = (scopeName !== undefined && scopeName !== null && scopeName !== "")
    ? scopeName
    : Scope.scopeFromStack(new Error().stack, typeof depth === "number" ? depth : JS_DEPTH)
  if (!allows(level, scope)) return false
  const body = Spec.join(parts)
  const text = body === "" ? scope : scope + ": " + body
  switch (level) {
    case "error": console.error(text); break
    case "warn": console.warn(text); break
    case "info": console.info(text); break
    // TRACE has no Qt counterpart and is emitted at DEBUG's severity. Picking
    // it alone is still exact - the gate is above - and folding the two keeps
    // a UI-draw trace out of the journal's error and warning bands.
    //
    // Folded, not anonymous: both would print `DEBUG qml: <scope>:`, so a
    // trace and a data line were indistinguishable in the sink. The marker
    // makes them separable by grep without adding a level word to every
    // message, which the one rule below forbids for the other four.
    //
    //   DEBUG qml: bar.network: ~ repaint 14ms
    //   DEBUG qml: bar.network: parsed 24 entries
    //
    // AFTER the scope, not before the line: the natural filter is
    // `qml: <scope>:`, and a marker in front of the scope would stop a trace
    // line from matching the scope the reader is filtering on - which is the
    // one workflow DEBUG exists to serve.
    default:
      console.debug(level === "trace"
        ? (body === "" ? scope + ": " + TRACE_MARKER.trim() : scope + ": " + TRACE_MARKER + body)
        : text)
      break
  }
  return true
}

// The five direct shorthands, at JS_DEPTH. A QML caller should use the `Log`
// singleton rather than these: it is the same index either way, but the facade
// is the one that owns the boot-time configuration and the IPC surface.
function info(...parts) { return emit("info", parts, "", JS_DEPTH) }
function warn(...parts) { return emit("warn", parts, "", JS_DEPTH) }
function error(...parts) { return emit("error", parts, "", JS_DEPTH) }
function debug(...parts) { return emit("debug", parts, "", JS_DEPTH) }
function trace(...parts) { return emit("trace", parts, "", JS_DEPTH) }

// at(scopeName) -> a logger that claims a scope instead of deriving one.
//
// The escape hatch for what derivation cannot serve: a script shared by several
// features, or a component that wants its records filed under the domain
// rather than the surface. Memoised per name, so the object is built once
// rather than per message.
function at(scopeName) {
  const key = typeof scopeName === "string" ? scopeName.trim() : ""
  if (key === "") return scoped("")
  let logger = _scopedLoggers[key]
  if (logger === undefined) {
    logger = scoped(key)
    _scopedLoggers[key] = logger
  }
  return logger
}

function scoped(scopeName) {
  const named = typeof scopeName === "string" && scopeName !== ""
  return {
    // allows(level) -> whether this logger would print a record.
    //
    // On the scoped object rather than only on the facade, because the gate has
    // to answer for the SAME scope the emission will use. Asking separately
    // means restating the scope as a string at each call site, and the two can
    // drift - which is how a guard silently starts protecting the wrong scope.
    //
    // The derived form (an empty `scopeName`, i.e. `at()`) costs a stack
    // capture. That is the right trade and not a regression of the "a
    // suppressed record costs one map read" rule: that rule is about `emit`,
    // and this is an explicit caller asking before building a payload, which a
    // capture is far cheaper than. The capture happens in the arrow below, so
    // index 0 is the arrow and 1 is whoever called `allows`.
    allows: (level) => named
      ? allows(level, scopeName)
      : allows(level, Scope.scopeFromStack(new Error().stack, 1)),
    info: (...parts) => emit("info", parts, scopeName, JS_DEPTH),
    warn: (...parts) => emit("warn", parts, scopeName, JS_DEPTH),
    error: (...parts) => emit("error", parts, scopeName, JS_DEPTH),
    debug: (...parts) => emit("debug", parts, scopeName, JS_DEPTH),
    trace: (...parts) => emit("trace", parts, scopeName, JS_DEPTH)
  }
}

// --- reporting --------------------------------------------------------------

// announce() - state what the configuration resolved to, once per configure,
// and only when the env var is what configured it.
//
// A shell narrating its own log settings on every start is noise; a shell
// whose VIBRANIUM_SHELL_LOG silently matched nothing is a debugging session
// that goes nowhere.
//
// Printed through `console` rather than through `emit`, because a warning
// about the configuration cannot be gated by it - that is the one place where
// a level that was switched off would have swallowed its own diagnosis. The
// same applies to the INFO lines: this is a record about the gate, and gating
// it would make `off` indistinguishable from `clipboard` gone wrong.
function announce() {
  if (!fromEnv()) return
  if (_announcedSequence === _sequence) return
  _announcedSequence = _sequence
  console.info("log: " + ENV_VAR + "=" + _specText + " -> " +
    (levels().length === 0 ? "nothing" : levels().join(", ")))
  const off = silenced()
  for (let i = 0; i < off.length; i++) console.info("log: silenced " + off[i])
  const pinned = overrides()
  const keys = Object.keys(pinned)
  for (let i = 0; i < keys.length; i++) console.info("log: " + keys[i] + "=" + pinned[keys[i]])
  const bad = warnings()
  for (let i = 0; i < bad.length; i++) console.warn("log: " + bad[i])
  // Which source produced this configuration. The lines above can list the
  // whole resolved state without saying whether the environment or the
  // settings store decided it, and "my setting is being ignored" is the first
  // question when a level is not what you expected. `announce` returns early
  // when the env var is not live, so this can only ever be the environment.
  //
  // Through `emit` with the `log` scope rather than a bare `console.debug`, so
  // it is a gated record like any other - the configuration source is only
  // interesting to someone who turned the level up to see it.
  emit("debug", ["configuration source " + ENV_VAR + ", settings not consulted"], LOG_SCOPE, 0)
}