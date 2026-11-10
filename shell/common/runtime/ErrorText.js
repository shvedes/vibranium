.pragma library

// A caught exception as the one-line text the runtime singletons report.
//
// SurfaceClaim, DeferredQueue and UnitGate each catch consumer code and
// publish what it threw. The rule was written out three times: a string is
// already text, an object with a message is that message, and anything else
// is stringified. A value whose toString() itself throws must not take the
// reporter down with it, so the fallback is the caller's - each registry
// names its own ("Unknown unit error") rather than sharing one wording.
function message(error, fallback) {
  const none = typeof fallback === "string" ? fallback : "Unknown error"
  try {
    if (typeof error === "string") return error
    if (error && typeof error.message === "string") return error.message
    return String(error)
  } catch (ignored) {
    return none
  }
}
