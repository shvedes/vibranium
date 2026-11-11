.pragma library

// A filesystem path as a `file://` URI.
//
// One encodeURIComponent per segment, so spaces, "#" and non-ASCII survive a
// trip through a shell-free consumer. An empty path and the filesystem root
// both serialize as the canonical triple-slash form.
//
// The two callers differ on two edge cases, so both are named here rather than
// folded into one accidental answer:
//
//   keepExisting  an input that is already a file URI passes through instead
//                 of having its scheme treated as a path segment.
//   blankNull     a missing path reads as empty rather than as the string
//                 "undefined"/"null".
//
// Clipboard addresses stored paths (the stringified answer is part of its
// persisted contract); the capture helper builds offers from values it has
// already resolved, so a missing one is an empty root.
function toUri(path, options) {
  const opts = options || {}
  const value = opts.blankNull === true ? String(path ?? "") : String(path)
  if (opts.keepExisting === true && value.startsWith("file://")) return value
  const parts = value.split("/")
  let out = ""
  for (let i = 0; i < parts.length; i++) {
    if (parts[i] === "") continue
    out += "/" + encodeURIComponent(parts[i])
  }
  return "file://" + (out === "" ? "/" : out)
}
