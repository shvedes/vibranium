// Deriving a log scope from where the call was written.
//
// A scope is the answer to "whose line is this", and it is derived rather
// than passed so that no call site has to name its own owner. `features/` and
// `common/` are stripped - so are `services/` and `boot/`, because a scope
// that keeps its layer for two of the four and drops it for the other two is
// a scope nobody can guess the spelling of. `features/bar/modules/ArchUpdates/
// ArchUpdates.qml` reads as `bar.archUpdates`; `features/clipboard/
// Clipboard.qml` as `clipboard`.
//
// Three rules produce that, and each is load-bearing:
//
//   * anchor on the LAST path segment that names a layer, so the Quickshell
//     resource prefix in front of it (`/qs/features/...`) needs no knowledge
//     of what that prefix is;
//   * drop a `modules` segment, because a bar module is grouped under the
//     bar for layout reasons and is otherwise two levels deep for what is
//     one owner;
//   * collapse `Dir/Dir.qml` to `Dir`, so the file that carries a domain's
//     name does not double it.
//
// A `.js` library is scoped by its own file like anything else
// (`ClipboardLib.js` is `clipboard.clipboardLib`), which is why silencing
// works by subtree: `-clipboard` covers the library because the library is
// under the clipboard. There is deliberately no `Lib`/`Utils` special case -
// one uniform rule is worth more than one shorter scope name.
//
// Scope identity is case-insensitive and hierarchical: `bar` matches `bar`
// and `bar.archUpdates`, and not `barn`. `mostSpecificMatch` resolves the
// overlap, which is what makes `bar=warn,bar.archUpdates=trace` split one
// subtree at the deeper key.
.pragma library

// The top-level directories of the shell. The first, reading backwards from
// the file, that matches one of these starts the scope.
var LAYERS = ["features", "common", "services", "boot"]
// Directories that are presentation grouping rather than ownership.
var SKIP_DIRS = ["modules"]
// Used when a frame names no file at all, which is the case when the engine
// gave no stack trace: one honest owner for an unattributable line beats an
// empty scope nothing can be silenced against.
var FALLBACK = "shell"

// stripLine(text) -> the frame's location without its line number.
//
// Quickshell prints a frame as `name@url:line`. The line is stripped here
// rather than by the caller because a frame with no function name arrives
// without the `@` at all, and then the number is the only thing separating
// the url from its line.
function stripLine(text) {
  const match = /:(\d+)$/.exec(text)
  return match === null ? text : text.slice(0, match.index)
}

// scopeFromFrame(frame) -> a scope, or null when the frame names no file.
//
// The url is taken after the LAST `@`: a function name cannot contain one,
// and a path can, so the last one is the boundary in the common case. The
// layer anchor below means the prefix in front of it is never parsed, so a
// url this function has never seen still resolves.
function scopeFromFrame(frame) {
  if (typeof frame !== "string") return null
  const text = frame.trim()
  if (text === "") return null
  const at = text.lastIndexOf("@")
  const location = at >= 0 ? text.slice(at + 1) : text
  return scopeFromPath(stripLine(location))
}

// scopeFromStack(stack, depth) -> the scope of the frame at `depth`.
//
// `depth` is an index into the stack, not a frame offset: 0 is the function
// that captured the trace, 1 is whoever called it. The index is used exactly
// rather than "the first frame I can parse", because scanning forward would
// walk into a frame inside this directory and report the logger as the owner
// of a line it was only asked to print.
function scopeFromStack(stack, depth) {
  if (typeof stack !== "string" || stack.trim() === "") return FALLBACK
  const frames = stack.split("\n")
  const index = typeof depth === "number" && depth >= 0 ? Math.floor(depth) : 1
  if (index >= frames.length) return FALLBACK
  const scope = scopeFromFrame(frames[index])
  return scope === null ? FALLBACK : scope
}

// scopeFromPath(filePath) -> the scope a file's path names.
function scopeFromPath(filePath) {
  if (typeof filePath !== "string") return FALLBACK
  let text = filePath.trim()
  if (text === "") return FALLBACK
  const scheme = /^[A-Za-z][A-Za-z0-9+.-]*:/.exec(text)
  if (scheme !== null) text = text.slice(scheme[0].length)

  const parts = []
  const raw = text.split("/")
  for (let i = 0; i < raw.length; i++) {
    if (raw[i] !== "" && raw[i] !== ".") parts.push(raw[i])
  }
  if (parts.length === 0) return FALLBACK

  // Anchored on the LAST layer segment: a nested directory may legitimately
  // repeat a layer name (`features/foo/common/`) and the innermost one is the
  // one that owns the file.
  let start = -1
  for (let i = parts.length - 1; i >= 0; i--) {
    if (LAYERS.indexOf(parts[i]) >= 0) {
      start = i + 1
      break
    }
  }
  // No layer segment: the file is the whole scope. `shell.qml` at the shell
  // root is `shell`, which is the answer a reader expects for it.
  if (start < 0) start = parts.length - 1

  const kept = []
  for (let i = start; i < parts.length - 1; i++) {
    if (SKIP_DIRS.indexOf(parts[i]) >= 0) continue
    kept.push(parts[i])
  }
  const stem = stripExtension(parts[parts.length - 1])
  const last = kept.length > 0 ? kept[kept.length - 1] : ""
  if (stem.toLowerCase() !== last.toLowerCase()) kept.push(stem)

  const named = []
  for (let i = 0; i < kept.length; i++) {
    if (kept[i] !== "") named.push(lowerFirst(kept[i]))
  }
  return named.length === 0 ? FALLBACK : named.join(".")
}

// stripExtension(name) -> the file stem, for the two spellings this tree
// uses. A name with no recognised extension is kept whole, so a frame that
// names a directory rather than a file still produces a usable scope.
function stripExtension(name) {
  if (/\.qml$/.test(name)) return name.slice(0, -4)
  if (/\.js$/.test(name)) return name.slice(0, -3)
  return name
}

// lowerFirst(text) -> the scope spelling of one path segment.
//
// A leading run of capitals is an acronym in a mixed-case name and a
// lowercased word otherwise, and the two want opposite treatment:
//
//   ArchUpdates -> archUpdates   (one capital: just a word starting capitalised)
//   OSDView     -> osdView       (a capital run followed by lower case: two words)
//   IPC         -> ipc           (a capital run with nothing after it: one word)
//   ColorPicker -> colorPicker
//
// Lowering only the first character of a run would produce `oSDView`, which is
// not a spelling anybody writes and not the `osdView` the rest of the tree uses
// - so the rule has to look at what follows the run, not just at its length.
function lowerFirst(text) {
  if (text === "") return text
  let run = 0
  while (run < text.length && text[run] >= "A" && text[run] <= "Z") run++
  if (run === 0) return text.charAt(0).toLowerCase() + text.slice(1)
  // A single capital is a word that starts capitalised, not an acronym, and a
  // run with no lower-case letter after it is one word rather than several.
  if (run === 1) return text.charAt(0).toLowerCase() + text.slice(1)
  if (run === text.length) return text.toLowerCase()
  return text.slice(0, run - 1).toLowerCase() + text.slice(run - 1)
}

// matchesKey(scope, key) -> whether a `key` term covers `scope`.
//
// Hierarchical: exact, or a dotted ancestor. The comparison is
// case-insensitive so a hand-written spec does not have to reproduce the
// camelCase the derivation produces.
function matchesKey(scope, key) {
  if (typeof scope !== "string" || typeof key !== "string") return false
  const subject = scope.toLowerCase()
  const wanted = key.toLowerCase()
  return subject === wanted || subject.indexOf(wanted + ".") === 0
}

// mostSpecificMatch(map, scope) -> the value of the longest key in `map` that
// covers `scope`, or null when none does.
//
// Longest wins because that is the only ordering that makes nesting
// expressible: with `bar` and `bar.archUpdates` both present, the deeper key
// has to be the one that decides, or a parent could never be set without
// silently overruling its own child.
function mostSpecificMatch(map, scope) {
  if (!map || typeof map !== "object") return null
  const keys = Object.keys(map)
  let best = null
  for (let i = 0; i < keys.length; i++) {
    if (!matchesKey(scope, keys[i])) continue
    if (best === null || keys[i].length > best.length) best = keys[i]
  }
  return best === null ? null : map[best]
}

// matchingChain(map, scope) -> the keys of `map` that cover `scope`, ordered
// LEAST specific first.
//
// `mostSpecificMatch` answers "which one decides", which is the right question
// when a key PINS a value. It is the wrong question once a key ADDS to what it
// inherits: then every covering key contributes, and the order they apply in is
// part of the answer. Shortest key first is that order, because a longer scope
// is by definition nested under a shorter one and must be applied on top.
//
// This walks the same way the specificity comparison does, so the two cannot
// disagree about what covers a scope.
function matchingChain(map, scope) {
  if (!map || typeof map !== "object") return []
  const keys = Object.keys(map)
  const hits = []
  for (let i = 0; i < keys.length; i++) {
    if (matchesKey(scope, keys[i])) hits.push(keys[i])
  }
  hits.sort((a, b) => a.length - b.length)
  return hits
}