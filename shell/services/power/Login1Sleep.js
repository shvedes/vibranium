.pragma library

// gdbus monitor prints a login1 signal as a single line of the form
// "/org/freedesktop/login1: org.freedesktop.login1.Manager PrepareForSleep (true,)".
// The boolean is the only part a consumer needs: it marks the sleep boundary
// that invalidates a lock's grace window, including a sleep shorter than that
// window, which a wall-clock deadline alone cannot see.
function preparingFromLine(line) {
  if (typeof line !== "string") return null
  const prefix = "/org/freedesktop/login1: "
  if (line.indexOf(prefix) !== 0) return null
  const signal = line.slice(prefix.length)
  const name = "org.freedesktop.login1.Manager PrepareForSleep"
  if (signal.indexOf(name) !== 0) return null
  const arg = /\b(true|false)\b/.exec(signal.slice(name.length))
  if (arg === null) return null
  return arg[1] === "true"
}
