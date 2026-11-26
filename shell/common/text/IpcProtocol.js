// Wire framing, request validation, grammar matching and result adapters.
//
// Pure `.pragma library`, no Qt and no QML references. The same rules run in
// the router (server side) and are exercised from node without an engine.
//
// A `v1:` token is compact ASCII JSON. Every non-ASCII UTF-16 code unit is
// written as \uXXXX, so bytes, cells and characters cannot be confused by a
// transport that happens to parse JSON-aware arguments.
.pragma library

var VERSION = 1
var PREFIX = "v1:"
var MAX_REQUEST_BYTES = 48 * 1024
var MAX_WORDS = 128
var MAX_REPLY_BYTES = 24 * 1024
var MAX_SNAPSHOT_BYTES = 4 * 1024 * 1024
var MAX_SNAPSHOTS = 8
var SNAPSHOT_TTL_MS = 10000
var PAGE_ITEMS = 24
var MAX_SAFE = 9007199254740991

// Result renderers the client understands. `help` carries the canonical
// descriptor shape and is laid out by the help renderer, not as a record.
var OUTPUT_KINDS = ["none", "text", "bool", "number", "record", "table", "help", "value", "lines", "boottime", "boottimeline"]

var ERRORS = {
  usage: 2, "unknown-target": 2, "unknown-command": 2, "invalid-argument": 2,
  empty: 1, "not-found": 1, "invalid-index": 1, unsupported: 1, unavailable: 1,
  busy: 1, stale: 1, refused: 1, backend: 1,
  timeout: 1, oversize: 1, internal: 1
}

// --- framing ---------------------------------------------------------------

function asciiJson(value) {
  var text = JSON.stringify(value, function (_key, v) {
    if (typeof v === "number" && !isFinite(v)) return undefined
    return v
  })
  if (typeof text !== "string") return ""
  var out = ""
  for (var i = 0; i < text.length; i++) {
    var c = text.charCodeAt(i)
    // Escape each UTF-16 code unit separately, including lone surrogates.
    out += c > 127 ? "\\u" + ("0000" + c.toString(16)).slice(-4) : text.charAt(i)
  }
  return out
}

function encode(value) { return PREFIX + asciiJson(value) }

// Strict: one prefix, one JSON object, no trailing bytes. `null`, arrays and
// scalars are not envelopes.
function decode(text) {
  if (typeof text !== "string") return null
  var s = text
  if (s.charAt(s.length - 1) === "\n") s = s.slice(0, -1)
  if (s.slice(0, PREFIX.length) !== PREFIX) return null
  var body = s.slice(PREFIX.length)
  if (body === "" || body.charAt(0) !== "{" || body.charAt(body.length - 1) !== "}") return null
  try {
    var v = JSON.parse(body)
  } catch (e) {
    return null
  }
  if (!v || typeof v !== "object" || Array.isArray(v)) return null
  return v
}

function asciiBytes(text) {
  // Every caller measures an asciiJson-encoded envelope, so one code unit is
  // one byte. Raw text with non-ASCII is not a valid wire frame at all.
  return text.length
}

// --- request validation ----------------------------------------------------

function fail(code, message) {
  var out = { ok: false, error: code }
  if (message) out.message = message
  return out
}

function isStringArray(a) {
  if (!Array.isArray(a)) return false
  for (var i = 0; i < a.length; i++) {
    if (typeof a[i] !== "string") return false
    if (a[i].indexOf("\u0000") >= 0) return false
  }
  return true
}

function hasOnly(obj, keys) {
  var actual = Object.keys(obj)
  for (var i = 0; i < actual.length; i++) {
    if (keys.indexOf(actual[i]) < 0) return false
  }
  return true
}

// `describe`: {v:1,kind:"index"|"help",path:[...]} or {v:1,kind:"next",cursor}
// `invoke`:   {v:1,kind:"call",argv:[...],literalFrom:null|int} or next.
function validateRequest(kind, request) {
  if (!request || typeof request !== "object" || Array.isArray(request)) return fail("invalid-argument")
  if (request.v !== VERSION) return fail("invalid-argument")
  if (request.kind === "next") {
    if (!hasOnly(request, ["v", "kind", "cursor"])) return fail("invalid-argument")
    if (typeof request.cursor !== "string" || request.cursor === "") return fail("invalid-argument")
    return { ok: true, kind: "next", cursor: request.cursor }
  }
  if (kind === "describe") {
    if (request.kind === "index") {
      if (!hasOnly(request, ["v", "kind"])) return fail("invalid-argument")
      return { ok: true, kind: "index", path: [] }
    }
    if (request.kind === "help") {
      if (!hasOnly(request, ["v", "kind", "path"])) return fail("invalid-argument")
      if (!isStringArray(request.path)) return fail("invalid-argument")
      return { ok: true, kind: "help", path: request.path.slice() }
    }
    return fail("invalid-argument")
  }
  if (kind === "invoke") {
    if (request.kind !== "call") return fail("invalid-argument")
    if (!hasOnly(request, ["v", "kind", "argv", "literalFrom"])) return fail("invalid-argument")
    if (!isStringArray(request.argv)) return fail("invalid-argument")
    if (request.argv.length > MAX_WORDS) return fail("oversize")
    var lf = request.literalFrom
    if (lf !== null && lf !== undefined) {
      if (typeof lf !== "number" || lf % 1 !== 0 || lf < 0 || lf > request.argv.length) {
        return fail("invalid-argument")
      }
    }
    lf = lf === undefined ? null : lf
    return { ok: true, kind: "call", argv: request.argv.slice(), literalFrom: lf }
  }
  return fail("invalid-argument")
}

function ok(data, format) {
  var frame = { v: VERSION, ok: true, data: data }
  if (format) frame.format = format
  return frame
}
function error(code, message) {
  return { v: VERSION, ok: false, error: { code: code, message: String(message || code) } }
}

// --- grammar ---------------------------------------------------------------

function isWordRecord(w) {
  return w !== null && typeof w === "object" && !Array.isArray(w) && typeof w.name === "string"
}
function isOptional(w) {
  return w !== null && typeof w === "object" && !Array.isArray(w) && Array.isArray(w.optional)
}
function isFlags(w) {
  return w !== null && typeof w === "object" && !Array.isArray(w) && Array.isArray(w.flags)
}

// Compile a row's `words` into a sequence of literal / argument / optional
// steps. Rejects a repeat that is not last, an unnamed argument, an unknown
// type, an enum without values and malformed records. Literals may appear in
// any position; matching tests literal steps before placeholders at the same
// position, so a fixed keyword is never captured by a placeholder.
function compile(words) {
  if (!Array.isArray(words)) return fail("invalid-argument")
  var seq = []
  for (var i = 0; i < words.length; i++) {
    var w = words[i]
    if (typeof w === "string") {
      seq.push({ kind: "literal", word: w })
      continue
    }
    if (isOptional(w)) {
      var inner = compile(w.optional)
      if (!inner.ok) return inner
      seq.push({ kind: "optional", steps: inner.seq })
      continue
    }
    if (isFlags(w)) {
      var accepted = []
      for (var f = 0; f < w.flags.length; f++) {
        if (typeof w.flags[f] !== "string" || w.flags[f] === "") return fail("invalid-argument")
        accepted.push(w.flags[f])
      }
      seq.push({ kind: "flags", words: accepted })
      continue
    }
    if (!isWordRecord(w) || w.name === "") return fail("invalid-argument")
    if (typeof w.type !== "string" || ["string", "enum", "bool", "int", "number", "json", "ref"].indexOf(w.type) < 0) {
      return fail("invalid-argument")
    }
    if (w.type === "enum" && !Array.isArray(w.values)) return fail("invalid-argument")
    if (w.repeat && i !== words.length - 1) return fail("invalid-argument")
    seq.push({ kind: "argument", spec: w })
  }
  return { ok: true, seq: seq }
}

function decimalInt(text, spec) {
  if (typeof text !== "string" || !/^[0-9]+$/.test(text)) return fail("invalid-argument")
  var n = Number(text)
  if (!isFinite(n) || n > MAX_SAFE || n % 1 !== 0) return fail("invalid-argument")
  if (spec.min !== undefined && n < spec.min) return fail("invalid-argument")
  if (spec.max !== undefined && n > spec.max) return fail("invalid-argument")
  return { ok: true, value: n }
}

function typedValue(text, spec) {
  switch (spec.type) {
  case "string":
    return { ok: true, value: text }
  case "ref":
    if (text === "") return fail("invalid-argument")
    return { ok: true, value: text }
  case "enum":
    if (spec.values.indexOf(text) < 0) return fail("invalid-argument")
    return { ok: true, value: text }
  case "bool":
    if (text === "true") return { ok: true, value: true }
    if (text === "false") return { ok: true, value: false }
    return fail("invalid-argument")
  case "int":
    return decimalInt(text, spec)
  case "number":
    if (!/^-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/.test(text)) return fail("invalid-argument")
    var f = Number(text)
    if (!isFinite(f)) return fail("invalid-argument")
    if (spec.min !== undefined && f < spec.min) return fail("invalid-argument")
    if (spec.max !== undefined && f > spec.max) return fail("invalid-argument")
    return { ok: true, value: f }
  case "json":
    if (text === "" && spec.allowEmptyString) return { ok: true, value: "" }
    try {
      return { ok: true, value: JSON.parse(text) }
    } catch (e) {
      return fail("invalid-argument")
    }
  default:
    return fail("invalid-argument")
  }
}

// Recursive matcher: a complete match only, optional groups may be taken or
// skipped, and a repeat consumes all remaining words. Fixed literals are
// tested before placeholders because compile() keeps them in that order.
function matchSteps(steps, argv, index, args, tokens) {
  if (steps.length === 0) {
    if (index !== argv.length) return fail("usage")
    return { ok: true, args: args, tokens: tokens, at: index }
  }
  var step = steps[0]
  var rest = steps.slice(1)
  if (step.kind === "literal") {
    if (index >= argv.length || argv[index] !== step.word) return fail("usage")
    return matchSteps(rest, argv, index + 1, args, tokens)
  }
  if (step.kind === "optional") {
    var taken = matchSteps(step.steps, argv, index, args, tokens)
    if (taken.ok) {
      var after = matchSteps(rest, argv, taken.at, taken.args, taken.tokens)
      if (after.ok) return after
    }
    return matchSteps(rest, argv, index, args, tokens)
  }
  // A flags step consumes any run of accepted keywords in any order. The
  // caller sees the concrete spellings in `args.flags`; a repeated keyword
  // is harmless and still list-ordered.
  if (step.kind === "flags") {
    var found = []
    var at = index
    while (at < argv.length && step.words.indexOf(argv[at]) >= 0) {
      found.push(argv[at])
      at++
    }
    var nextArgs = {}
    var nextTokens = {}
    var argKeys = Object.keys(args)
    for (var ak = 0; ak < argKeys.length; ak++) {
      nextArgs[argKeys[ak]] = args[argKeys[ak]]
      nextTokens[argKeys[ak]] = tokens[argKeys[ak]]
    }
    nextArgs.flags = found
    nextTokens.flags = found.slice()
    return matchSteps(rest, argv, at, nextArgs, nextTokens)
  }
  var spec = step.spec
  if (spec.repeat) {
    for (var j = index; j < argv.length; j++) {
      var v = typedValue(argv[j], spec)
      // Retain which typed step failed: the router uses it to separate a
      // bad token on a named row from a grammar-shape miss.
      if (!v.ok) return { ok: false, error: v.error, badType: spec.type, badName: spec.name }
    }
    var repArgs = {}
    var repTokens = {}
    var repKeys = Object.keys(args)
    for (var rk = 0; rk < repKeys.length; rk++) {
      repArgs[repKeys[rk]] = args[repKeys[rk]]
      repTokens[repKeys[rk]] = tokens[repKeys[rk]]
    }
    repArgs[spec.name] = argv.slice(index)
    repTokens[spec.name] = argv.slice(index)
    return { ok: true, args: repArgs, tokens: repTokens, at: argv.length }
  }
  if (index >= argv.length) {
    if (spec.optional) return matchSteps(rest, argv, index, args, tokens)
    return fail("usage")
  }
  var val = typedValue(argv[index], spec)
  if (!val.ok) return { ok: false, error: val.error, badType: spec.type, badName: spec.name }
  var nextArgs = {}
  var nextTokens = {}
  var keys = Object.keys(args)
  for (var k = 0; k < keys.length; k++) nextArgs[keys[k]] = args[keys[k]]
  for (var m = 0; m < keys.length; m++) nextTokens[keys[m]] = tokens[keys[m]]
  nextArgs[spec.name] = val.value
  nextTokens[spec.name] = argv[index]
  return matchSteps(rest, argv, index + 1, nextArgs, nextTokens)
}

function match(words, argv) {
  if (!isStringArray(argv)) return fail("invalid-argument")
  return matchCompiled(compile(words), argv)
}

// argv has already been checked by match() or the router's envelope validator.
function matchCompiled(c, argv) {
  if (!c.ok) return c
  var r = matchSteps(c.seq, argv, 0, {}, {})
  if (!r.ok) return r
  return { ok: true, args: r.args, tokens: r.tokens }
}

// Build usage from `words`, never the reverse.
function usage(words) {
  var parts = []
  for (var i = 0; i < words.length; i++) {
    var w = words[i]
    if (typeof w === "string") {
      parts.push(w)
    } else if (isOptional(w)) {
      var inner = []
      for (var j = 0; j < w.optional.length; j++) {
        var ow = w.optional[j]
        inner.push(isWordRecord(ow) ? "<" + ow.name + ">" : String(ow))
      }
      parts.push("[" + inner.join(" ") + "]")
    } else if (isFlags(w)) {
      parts.push("[" + w.flags.join("|") + "]")
    } else if (isWordRecord(w)) {
      var atom = "<" + w.name + ">"
      if (w.repeat) atom = "[<" + w.name + ">...]"
      else if (w.optional) atom = "[" + atom + "]"
      parts.push(atom)
    }
  }
  return parts.join(" ")
}

// --- result adapters -------------------------------------------------------

function actionError(text, exceptions) {
  var s = String(text === undefined || text === null ? "" : text)
  if (exceptions) {
    for (var key in exceptions) {
      if (Object.prototype.hasOwnProperty.call(exceptions, key) && s === key) return exceptions[key]
    }
  }
  var low = s.toLowerCase()
  if (low === "confirmation_required") return "refused"
  if (low === "failed") return "backend"
  if (low === "vm") return "unsupported"
  if (low === "error" || low.indexOf("error:") === 0) return "invalid-argument"
  if (low === "refused" || low.indexOf("refused:") === 0) return "refused"
  if (low === "disabled") return "unavailable"
  if (low === "unavailable" || low.indexOf("unavailable:") === 0) return "unavailable"
  if (low === "loading" || low === "busy") return "busy"
  return ""
}

// Owner tokens are deliberate diagnostics, not accidental exception text.
// Strip the machine prefix so the CLI can print the human reason after the
// error code instead of a generic "unexpected owner reply".
function actionMessage(text, code) {
  var s = String(text === undefined || text === null ? "" : text).trim()
  var low = s.toLowerCase()
  if (low === "error") return "action failed"
  if (low === "failed") return "action failed"
  if (low === "vm") return "not supported in a VM"
  if (low === "confirmation_required") return "confirmation required"
  if (low.indexOf("error:") === 0) return s.slice(6).trim()
  if (low.indexOf("refused:") === 0) return s.slice(8).trim()
  if (low.indexOf("unavailable:") === 0) return s.slice(12).trim()
  return s || code
}

// `reply.kind` values: json, settings-get, text, bool, count, lines, action,
// none. Returns {ok, data} where `data` is absent for silence.
function adapt(reply, value, row) {
  var kind = reply && reply.kind ? reply.kind : "text"
  var text = typeof value === "string" ? value : value === undefined || value === null ? "" : String(value)
  if (kind === "none") return { ok: true }
  if (kind === "action") {
    // An action is an order: success is the exit status, never a label. The
    // adapter still surfaces refusals, so a destructive verb that did not run
    // is a failure rather than a silent success.
    var code = actionError(text, reply.exceptions)
    if (code) return fail(code, actionMessage(text, code))
    return { ok: true }
  }
  if (kind === "json" || kind === "settings-get") {
    try {
      var parsed = JSON.parse(text)
    } catch (e) {
      return fail("internal")
    }
    if ((kind === "settings-get" || reply.rejectErrorField) && parsed && typeof parsed === "object"
        && !Array.isArray(parsed) && Object.prototype.hasOwnProperty.call(parsed, "error")) {
      return fail("not-found")
    }
    return { ok: true, data: parsed }
  }
  if (kind === "text") return { ok: true, data: text }
  if (kind === "bool") {
    if (text === "true") return { ok: true, data: true }
    if (text === "false") return { ok: true, data: false }
    return fail("internal")
  }
  if (kind === "count") {
    var m = /^ok:\s*(-?[0-9]+)$/.exec(text)
    if (!m) return fail("internal")
    return { ok: true, data: Number(m[1]) }
  }
  if (kind === "lines") {
    if (text === "") return { ok: true, data: [] }
    return { ok: true, data: text.split("\n") }
  }
  return fail("internal")
}

// Result type descriptors used by the renderer. A row may declare alternate
// shapes; the owner picks one at result creation by returning `format`.
function formatOf(row, data) {
  var out = row && row.output ? row.output : { kind: "value" }
  var f = { kind: OUTPUT_KINDS.indexOf(out.kind) >= 0 ? out.kind : "value" }
  if (out.columns) f.columns = out.columns
  if (out.fields) f.fields = out.fields
  if (row && row.formats) {
    for (var i = 0; i < row.formats.length; i++) {
      var alt = row.formats[i]
      var altKind = OUTPUT_KINDS.indexOf(alt.kind) >= 0 ? alt.kind : "value"
      if (alt.when === "array" && Array.isArray(data)) f = { kind: altKind, columns: alt.columns, fields: alt.fields }
      if (alt.when === "object" && data && typeof data === "object" && !Array.isArray(data)) {
        f = { kind: altKind, columns: alt.columns, fields: alt.fields }
      }
    }
  }
  return f
}

// --- page cursors ----------------------------------------------------------

function cursor(incarnation, sequence) { return incarnation + "." + sequence }

function parseCursor(text, incarnation) {
  if (typeof text !== "string") return null
  var dot = text.lastIndexOf(".")
  if (dot <= 0) return null
  var prefix = text.slice(0, dot)
  var seq = text.slice(dot + 1)
  if (prefix !== incarnation || !/^[0-9]+$/.test(seq)) return null
  var n = Number(seq)
  if (!isFinite(n) || n > MAX_SAFE) return null
  return n
}

// A page is one reply frame: items plus optional identical meta.
function page(items, meta, nextCursor) {
  var p = { v: VERSION, ok: true, data: { items: items } }
  if (meta !== undefined && meta !== null) p.data.meta = meta
  if (nextCursor) p.next = { cursor: nextCursor }
  return p
}
