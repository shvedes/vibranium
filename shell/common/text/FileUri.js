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
//   bareRoot      an empty path or the filesystem root renders as the bare
//                 scheme instead of the triple-slash form. The directory
//                 pickers compare the field against their own URL, and the
//                 root they would open is no directory at all.
//
// Clipboard addresses stored paths (the stringified answer is part of its
// persisted contract); the capture helper builds offers from values it has
// already resolved, so a missing one is an empty root.
function toUri(path, options) {
  const opts = options || {}
  const value = opts.blankNull === true ? String(path ?? "") : String(path)
  if (opts.keepExisting === true && isFileUri(value)) return value
  const parts = value.split("/")
  let out = ""
  for (let i = 0; i < parts.length; i++) {
    if (parts[i] === "") continue
    out += "/" + encodeURIComponent(parts[i])
  }
  if (out === "") return opts.bareRoot === true ? "file://" : "file:///"
  return "file://" + out
}

// Whether a value names a file URI. The scheme is case-insensitive (RFC 3986),
// so "FILE://" names the same URI as "file://".
function isFileUri(value) {
  return String(value ?? "").substring(0, 7).toLowerCase() === "file://"
}

// The filesystem text a file URI names, exactly as written: scheme dropped, a
// localhost authority discarded, percent-decoded - but the remainder not
// anchored at the root. "" when the value is not a file URI.
//
// A caller that wants the path of a local reference uses fromUri. A caller
// that has to tell an absolute designation from a relative one reads this and
// tests the leading separator itself: `file://-rf` names no local file, and
// anchoring it would invent `/ -rf` instead.
function pathOf(uri) {
  let p = String(uri ?? "")
  if (!isFileUri(p)) return ""
  p = p.substring(7)
  if (p.startsWith("localhost")) {
    const slash = p.indexOf("/")
    p = slash >= 0 ? p.substring(slash) : ""
  }
  try {
    p = decodeURIComponent(p)
  } catch (ignored) {
  }
  return p
}

// A `file://` URI as a filesystem path - the inverse of toUri.
//
// The scheme is dropped, a localhost authority is discarded, and a relative
// remainder is anchored at the root. A `file:` URI with no authority is the
// same local reference in its single-slash spelling, so it decodes too.
//
// Text that carries no file scheme is percent-decoded as it arrives, which is
// what the drop path relies on: it hands over the payload entry whether or
// not it carries the scheme, and a malformed escape must not refuse the drop.
function fromUri(uri) {
  let p = String(uri ?? "")
  if (isFileUri(p)) {
    p = pathOf(p)
    return p !== "" && p[0] !== "/" ? "/" + p : p
  }
  if (p.substring(0, 5).toLowerCase() === "file:") {
    p = p.substring(5)
    if (p !== "" && p[0] !== "/") p = "/" + p
  }
  try {
    p = decodeURIComponent(p)
  } catch (ignored) {
  }
  return p
}
