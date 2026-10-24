// Lexical path policy: a candidate is judged against a root by reading
// strings only. No filesystem call, no canonicalization, no shell.
//
// A lexical check proves that a joined path contains no `..` escape and no
// unexpected prefix. It cannot prove anything about the filesystem: a symlink
// inside the root, a component replaced between the check and the open
// (TOCTOU), whether a leaf already exists, atomic creation, or file mode.
// Those need a trusted filesystem helper that resolves the parent and the
// target itself with no-follow semantics. A caller that depends on one of
// them must assert the verified root explicitly, and every result reports
// what a lexical check did not examine in `unverified` and what the shell
// cannot do at all without that helper in `unavailable`.
//
// A request names one operation from a closed list, matched for exact
// equality. A name outside the list is refused before the candidate is read,
// because the gates key on the recursive and private names: an unrecognised
// spelling would otherwise be judged as a request that reaches nothing more
// than one path.
//
// Spaces, quotes, semicolons, backslashes, Unicode, and separators are data.
// They are never rejected and never re-encoded, because a lexical check needs
// no quoting: quoting is a property of the shell, and data that has to be
// quoted has already been concatenated into source upstream. Percent-encoding
// is not decoded here either, so a consumer that decodes a name must check the
// decoded name again.
.pragma library

const LEXICAL = "lexical"
const MODES = ["create", "write", "replace", "read", "rename_dest"]
const RECURSIVE = ["recursive_delete", "recursive_copy", "recursive_move"]
const SECRET = ["secret"]
// The remaining operations name a single path below the root, whether a
// directory to read or one file to remove, so none of them traverses and no
// gate keys on them. A name outside this list is refused rather than read as
// a request that touches only one path: the gates below classify a request by
// its exact operation name, and a spelling they do not recognise would
// otherwise carry a recursive or private request past every one of them.
const SINGLE_PATH = ["theme_dir", "git_list", "wallpaper_source", "leaf_delete"]
const OPERATIONS = RECURSIVE.concat(SECRET).concat(SINGLE_PATH)
const ATOMIC = "atomic"
const UNVERIFIED_ROOT = "unverified_root"
const CONTAINMENT_UNAVAILABLE = "containment_unavailable"

// `mode` names the requested verb and is validated against its list; the
// result carries the module's own LEXICAL marker, not the verb, and it
// decides nothing by itself, because existence, write permission,
// and replacement are not filesystem facts this module can read. `operation`
// is validated against its own list, and the recursive and private names in
// it are the ones the gates read.
// `allowLeaf`/`leafRelative` allow a nested path instead of a single
// segment; `allowExisting` asserts that a leaf which is already there is
// permitted; `relative` requires a relative candidate; `requireCanonical`
// together with `canonicalRoot` is the verified-root claim a recursive or
// secret operation must carry.
//
// `existing` reports the allow-existing assertion, not an observed fact.
function lexical(root, candidate, options) {
  if (!isOptions(options)) return invalid("invalid_options")
  if (options.mode !== undefined && MODES.indexOf(options.mode) < 0) return invalid("invalid_mode")
  if (options.operation !== undefined && !isOperation(options.operation)) return invalid("invalid_operation")

  const base = rootLexical(root, options)
  if (base === null) return invalid("invalid_root")
  const blocked = gates(base, options)
  if (blocked !== null) return blocked

  const target = targetLexical(candidate, options)
  if (target === null) return invalid("invalid_candidate")
  return evaluate(base, target, options)
}

// A capability that names every destination it may touch: one root, a batch of
// candidates, and the verification the caller claims. An empty batch is a
// misuse, and a batch is all-or-nothing so a partial authorization cannot be
// mistaken for a completed one.
function authorize(root, options) {
  if (!isOptions(options)) return invalid("invalid_options")
  if (options.mode !== undefined && MODES.indexOf(options.mode) < 0) return invalid("invalid_mode")
  if (options.operation !== undefined && !isOperation(options.operation)) return invalid("invalid_operation")

  const base = rootLexical(root, options)
  if (base === null) return invalid("invalid_root")
  const blocked = gates(base, options)
  if (blocked !== null) return blocked

  const work = Array.isArray(options.candidates) ? options.candidates : [options.candidate]
  if (work.length === 0) return denied(base, null, options, "no_candidates")

  const results = []
  let code = "ok"
  let failedIndex = -1
  for (let i = 0; i < work.length; i++) {
    const target = targetLexical(work[i], options)
    if (target === null) {
      results.push(invalid("invalid_candidate"))
    } else {
      results.push(evaluate(base, target, options))
    }
    if (results[i].ok !== true && failedIndex < 0) {
      code = results[i].code
      failedIndex = i
    }
  }

  return {
    ok: failedIndex < 0,
    code: code,
    mode: (options && typeof options.mode === "string") ? options.mode : LEXICAL,    operation: operation(options),
    root: base.path,
    rootExists: options.canonicalRoot === true && options.allowExistingRoot === true,
    count: work.length,
    failedIndex: failedIndex,
    results: results,
    canonicalRoot: options.canonicalRoot === true,
    atomic: options.atomic === true,
    secret: SECRET.indexOf(options.operation) >= 0,
    recursive: RECURSIVE.indexOf(options.operation) >= 0,
    unavailable: unavailableList(options),
    unverified: unverifiedList(options)
  }
}

// Refusals that do not depend on the candidate: a verified root that a
// recursive or secret operation needs, and a leaf requirement the allow flags
// do not satisfy. Both entry points validate the operation name before they
// get here, so a recursive or private request cannot reach an exact lookup
// under a spelling it does not recognise.
function gates(base, options) {
  if (options.requireCanonical === true && options.canonicalRoot !== true) {
    return denied(base, null, options, UNVERIFIED_ROOT)
  }
  if (RECURSIVE.indexOf(options.operation) >= 0 && options.canonicalRoot !== true) {
    return denied(base, null, options, UNVERIFIED_ROOT)
  }
  if (SECRET.indexOf(options.operation) >= 0 && options.canonicalRoot !== true) {
    return denied(base, null, options, CONTAINMENT_UNAVAILABLE)
  }
  if (options.allowExisting === true && !isLeaf(options)) return invalid("invalid_options")
  return null
}

// A relative candidate is read below the root. An absolute candidate is read
// at its own place and must carry the root's own segment prefix, so an
// unrelated absolute path is refused rather than silently accepted.
function evaluate(base, target, options) {
  if (options.relative === true && target.absolute) return denied(base, target, options, "absolute_path")

  if (target.absolute) {
    if (!prefixed(target.segments, base.segments)) {
      // A candidate shorter than the root can only point above it; one of the
      // same length or longer beside it.
      const code = target.segments.length < base.segments.length ? "not_below_root" : "escapes_root"
      return denied(base, target, options, code)
    }
    return below(base, target, options, target.segments.length - base.segments.length)
  }
  return below(base, target, options, target.segments.length)
}

function below(base, target, options, depth) {
  if (depth === 0) return denied(base, target, options, "not_below_root")
  if (!isLeaf(options) && depth > 1) return denied(base, target, options, "not_leaf")
  return allowed(base, target, options, depth)
}

// Full path of a target: its own place when absolute, otherwise the root's
// place with the target appended.
function under(base, target) {
  const relative = target.segments.join("/")
  if (target.absolute) return "/" + relative
  if (base.segments.length === 0) return "/" + relative
  return base.path + "/" + relative
}

function prefixed(segments, prefix) {
  for (let i = 0; i < prefix.length; i++) {
    if (segments[i] !== prefix[i]) return false
  }
  return true
}

function allowed(base, target, options, depth) {
  const relative = target.segments.join("/")
  return {
    ok: true,
    code: "ok",
    mode: (options && typeof options.mode === "string") ? options.mode : LEXICAL,    operation: operation(options),
    root: base.path,
    path: under(base, target),
    relative: relative,
    depth: depth,
    canonicalRoot: options.canonicalRoot === true,
    containment: "unverified",
    atomic: options.atomic === true,
    secret: SECRET.indexOf(options.operation) >= 0,
    existing: existingDecision(options),
    unavailable: unavailableList(options),
    unverified: unverifiedList(options)
  }
}

// A root is read as a sequence of literal segments. A trailing separator is
// accepted and dropped, `.` is identity, and `..` pops: popping past the
// beginning is the escape a caller must not perform. A relative root is only
// accepted under an explicit flag, because containment needs a common prefix.
function rootLexical(root, options) {
  if (typeof root !== "string" || root === "") return null
  return segments(root, options.allowRelativeRoot === true)
}

function targetLexical(candidate, options) {
  if (typeof candidate !== "string" || candidate === "") return null
  if (candidate.indexOf("\0") >= 0) return null
  if (options.leafRelative === true) {
    const leaf = singleSegment(candidate)
    return leaf === null ? null : { segments: [leaf], absolute: false }
  }
  return segments(candidate, true)
}

// A root is read relative to the filesystem root unless the caller accepts a
// relative capability root, which cannot anchor containment on its own.
function segments(path, anyForm) {
  const absolute = path.charAt(0) === "/"
  if (!absolute && anyForm !== true) return null

  const out = []
  const parts = path.split("/")
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i]
    if (part === "" || part === ".") continue
    if (part === "..") {
      if (out.length === 0) return null
      out.pop()
      continue
    }
    out.push(part)
  }
  return { segments: out, absolute: absolute, path: absolute ? "/" + out.join("/") : out.join("/") }
}

function singleSegment(value) {
  if (value === "" || value === "." || value === "..") return null
  if (value.indexOf("/") >= 0) return null
  return value
}

function isOptions(options) {
  return options !== null && typeof options === "object" && !Array.isArray(options)
}

// Exact membership, so a near-miss spelling of a recursive or private
// operation is refused rather than judged as a request that reaches only one
// path. A caller that keeps its own copy of the vocabulary reads this instead.
function isOperation(value) {
  return typeof value === "string" && OPERATIONS.indexOf(value) >= 0
}

// The operations the trusted filesystem helper owns, because their damage
// reaches past one leaf or needs a private open. A facade reads this rather
// than carrying a second list that could name an operation the gates here do
// not recognise.
function helperOwned(value) {
  return RECURSIVE.indexOf(value) >= 0 || SECRET.indexOf(value) >= 0
}

function isLeaf(options) {
  return options.allowLeaf === true || options.leafRelative === true
}

function operation(options) {
  return typeof options.operation === "string" ? options.operation : ""
}

function existingDecision(options) {
  return options.allowExisting === true ? "allowed" : "unverified"
}

// Containment needs a verified root, and atomic or secret creation needs the
// helper that owns the open. This module performs neither, so both stay
// listed as unavailable for the caller to resolve elsewhere.
function unavailableList(options) {
  const out = []
  if (options.canonicalRoot !== true) out.push(CONTAINMENT_UNAVAILABLE)
  if (options.atomic === true || SECRET.indexOf(options.operation) >= 0) out.push(ATOMIC)
  return out
}

function unverifiedList(options) {
  const out = ["symlink_escape", "toctou", "existence"]
  if (options.atomic === true) out.push("atomic_creation")
  if (SECRET.indexOf(options.operation) >= 0) out.push("file_mode")
  return out
}

function denied(base, target, options, code) {
  return {
    ok: false,
    code: code,
    mode: (options && typeof options.mode === "string") ? options.mode : LEXICAL,    operation: operation(options),
    root: base === null ? "" : base.path,
    path: target === null ? "" : under(base, target),
    canonicalRoot: options.canonicalRoot === true,
    containment: "unverified",
    atomic: options.atomic === true,
    secret: SECRET.indexOf(options.operation) >= 0,
    unavailable: unavailableList(options),
    unverified: unverifiedList(options)
  }
}

function invalid(code) {
  return { ok: false, code: code }
}
