// Pure capture helpers: naming, suffix/mime mapping, clipboard URIs and
// notification copy. No shell access and no feature policy, so the capture
// service and the annotation views can both resolve it from the neutral
// capture library. Quoting delegates to the dependency-free StringUtils.
//
// The rest of this file is the capture path's arithmetic and vocabulary,
// kept in the one neutral home so the service and the region overlay do not
// keep second copies of it:
//   - the DPR chain (qtDpr, compositorScale, grabSourceSize, grabItemSize,
//     sourceSizeMatches): logical selection coordinates are mapped onto
//     physical frame pixels through these, and the two consumers of them
//     read the same numbers rather than each mapping them by hand;
//   - output identity (screenKey, matchScreen, pickFocusedScreen);
//   - the flow sequencing guards the asynchronous capture callbacks are
//     matched against. The guards are pure; the effects they gate stay in
//     the service, which owns the processes, timers and windows.
.pragma library
.import "../text/StringUtils.js" as SU

function _pad(n) {
  return String(n).padStart(2, "0")
}

// Qt's device pixel ratio, floored at 1 when the platform reports nothing
// usable. Used to size a grab target, never to map coordinates.
function qtDpr(value) {
  const q = Number(value)
  return Number.isFinite(q) && q > 0 ? q : 1
}

// The ratio that actually maps logical coordinates to frame pixels: the
// compositor scale for the monitor, falling back to Qt's own DPR. The
// compositor wins whenever it reports one, including 1 - a monitor at
// integer scale 1 on a HiDPI Qt session still has a logical-to-physical
// ratio of 2, and the frame a screencopy reports is the compositor's.
function compositorScale(monitorScale, qtRatio) {
  const s = Number(monitorScale)
  if (Number.isFinite(s) && s > 0) return s
  return qtDpr(qtRatio)
}

// The physical size a grab will read. Qt's sourceSize is the physical
// screencopy frame and is 0 until the first frame lands; the item size
// times the compositor scale is the same number before that.
function grabSourceSize(viewW, viewH, dpr, sourceW, sourceH) {
  return {
    width: sourceW > 0 ? sourceW : Math.round(viewW * dpr),
    height: sourceH > 0 ? sourceH : Math.round(viewH * dpr)
  }
}

// What the source size is expected to be for a window of this size.
// Floored at 1 so a not-yet-configured window compares against 1 instead
// of against 0 and never matches a 0x0 source.
function grabItemSize(viewW, viewH, dpr) {
  return {
    width: Math.max(1, Math.round(viewW * dpr)),
    height: Math.max(1, Math.round(viewH * dpr))
  }
}

// Does the reported source match the expected one? One pixel of slack
// absorbs the compositor rounding its own mode, which is what makes the
// reframe check right at a fractional scale: at 1.25 a 100px window is
// 125 exactly, at 1.5 it is 150, and at a scale Qt rounds but the
// compositor floors, the two can differ by one without the frame being
// soft. Anything past the tolerance is a scaled-down grab.
function sourceSizeMatches(expectedW, expectedH, actualW, actualH, tolerance) {
  const t = Number(tolerance) > 0 ? Number(tolerance) : 1
  return Math.abs(actualW - expectedW) <= t && Math.abs(actualH - expectedH) <= t
}

// Output identity for a PAIR of screens. The serial wins only when BOTH
// sides report one: a screen the compositor has not described yet falls
// back to the connector name together with the other side, because one
// screen's serial alone would be a key the other side cannot produce and
// a hotplug mid-capture would resolve to a stale object. "name:" alone is
// the unusable answer - an unnamed screen with no serial matches nothing.
function screenKey(candidate, other) {
  const aSerial = String(candidate.serialNumber ?? "")
  const bSerial = String(other.serialNumber ?? "")
  if (aSerial !== "" && bSerial !== "") return "serial:" + aSerial + "|" + bSerial
  return "name:" + String(candidate.name ?? "")
}

// The live screen object for a captured one, or null when it is gone.
// Identity is compared before the key so a reconfigured screen resolves
// to its current object, and the mode size is part of the match so a
// resolution change reads as a different screen rather than the old one.
function matchScreen(candidate, screens) {
  if (candidate === null || candidate === undefined) return null
  const list = Array.isArray(screens) ? screens : []
  for (let i = 0; i < list.length; i++) {
    const current = list[i]
    if (current === candidate) return current
    const currentKey = screenKey(current, candidate)
    const otherKey = screenKey(candidate, current)
    if (currentKey !== "name:" && otherKey !== "name:"
      && currentKey === otherKey
      && current.width === candidate.width && current.height === candidate.height) return current
  }
  return null
}

// The focused output, or null. The monitor id is resolved by the caller,
// so this stays a pure walk of the screen list: a screen the compositor
// cannot map is not the focused one.
function pickFocusedScreen(screens, monitorIdOf, wantedId) {
  if (wantedId === null || wantedId === undefined) return null
  if (!Array.isArray(screens) || typeof monitorIdOf !== "function") return null
  for (let i = 0; i < screens.length; i++) {
    const m = monitorIdOf(screens[i])
    if (m !== null && m !== undefined && m.id === wantedId) return screens[i]
  }
  return null
}

// --- capture flow sequencing ---
// The identity an asynchronous capture callback is matched against. Both
// a job id and a flow id are required and both must still be the live
// ones: a callback from a flow that has since been released, or from a
// job a newer one replaced, is dropped instead of running against the
// capture that replaced it. A non-positive id is never live.
function flowLive(id, activeFlow) {
  const n = Number(id)
  return Number.isFinite(n) && n > 0 && n === Number(activeFlow)
}

function jobLive(jobId, activeJob, flowId, activeFlow) {
  const j = Number(jobId)
  const f = Number(flowId)
  if (!Number.isFinite(j) || j <= 0 || !Number.isFinite(f) || f <= 0) return false
  return j === Number(activeJob) && f === Number(activeFlow)
}

// A view request the service is still holding. A released id resolves to
// 0, so this is false for it - which is what keeps a late answer for a
// view that outlived its flow from running against the flow that
// replaced it.
function requestLive(id, current) {
  const n = Number(id)
  return Number.isFinite(n) && n > 0 && n === Number(current)
}

// Region identity, one predicate per branch: the live branch holds a
// grab job, the seeded branch holds a seed file, and both are matched
// against the request the contract is holding. currentSeed is compared
// by identity so an answer for a seed the service already discarded
// cannot be validated against its replacement.
function liveRegionIdentity(live, request, activeFlow) {
  if (live === null || live === undefined) return false
  if (request === null || request === undefined) return false
  const job = Number(live.jobId)
  if (!Number.isFinite(job) || job <= 0) return false
  if (Number(request.jobId) !== job) return false
  return Number(live.flowId) === Number(activeFlow)
}

function seedRegionIdentity(seed, currentSeed, request, activeFlow) {
  if (seed === null || seed === undefined) return false
  if (currentSeed !== seed) return false
  if (request === null || request === undefined) return false
  const job = Number(seed.jobId)
  if (!Number.isFinite(job) || job <= 0) return false
  if (Number(request.jobId) !== job) return false
  if (Number(seed.flowId) !== Number(activeFlow)) return false
  return String(request.url) === String(seed.url)
}

function grabTargetSize(sourceW, sourceH, reportedDpr) {
  const w = Math.max(1, Math.round(Number(sourceW) || 0))
  const h = Math.max(1, Math.round(Number(sourceH) || 0))
  const q = qtDpr(reportedDpr)
  return {
    width: Math.max(1, Math.ceil(w / q)),
    height: Math.max(1, Math.ceil(h / q))
  }
}

// The pixel size grabToImage actually writes for a target. Qt renders the
// target at the window's own effective DPR, so the file is the target
// scaled by it. That ratio is the window's, never Screen's: the two are
// different numbers whenever Qt's own ratio is already folded into the
// window's logical size, and a target divided by the wrong one comes back
// a fraction of the frame - a soft capture, and every selection mapped
// onto a grid smaller than the file it is cut from.
function grabResultSize(targetW, targetH, windowDpr) {
  const q = qtDpr(windowDpr)
  return {
    width: Math.max(1, Math.round((Number(targetW) || 0) * q)),
    height: Math.max(1, Math.round((Number(targetH) || 0) * q))
  }
}

// "2026-09-11_14-22-05": manual Date math, identical shape to the bash
// tool's %(%Y-%m-%d_%H-%M-%S)T. Never toLocaleString (locale-dependent).
function timestamp() {
  const d = new Date()
  return d.getFullYear() + "-" + _pad(d.getMonth() + 1) + "-" + _pad(d.getDate())
    + "_" + _pad(d.getHours()) + "-" + _pad(d.getMinutes()) + "-" + _pad(d.getSeconds())
}

function fileStem() {
  return "screenshot-" + timestamp()
}

// Canvas.save() picks the encoder from the file suffix; "jpg" (not
// "jpeg") is the suffix it checks.
function suffixFor(fileType) {
  return fileType === "jpeg" ? "jpg" : "png"
}

// Decode local FileDialog URLs without treating reserved characters as
// path separators.
function pathFromFileUrl(value) {
  const raw = String(value ?? "")
  if (!raw.startsWith("file://")) return ""
  let path = raw.slice(7)
  if (path.startsWith("localhost/")) path = path.slice("localhost".length)
  try { path = decodeURIComponent(path) } catch (e) { return "" }
  return path
}

function mimeForPath(path) {
  const s = String(path ?? "").toLowerCase()
  if (/\.(jpg|jpeg)$/.test(s)) return "image/jpeg"
  if (/\.webp$/.test(s)) return "image/webp"
  if (/\.bmp$/.test(s)) return "image/bmp"
  if (/\.(tif|tiff)$/.test(s)) return "image/tiff"
  if (/\.svg$/.test(s)) return "image/svg+xml"
  return "image/png"
}

function ensureImageSuffix(path, preferred) {
  const value = String(path ?? "")
  if (/\.(png|jpg|jpeg|webp|bmp|tif|tiff)$/i.test(value)) return value
  return value + "." + suffixFor(preferred)
}

// Single-quote a shell word. Screenshots, runtime and XDG dirs can contain
// spaces; every wl-copy invocation below goes through sh -c redirection.
function sq(s) {
  return SU.shellQuote(s)
}

function fileUri(path) {
  const value = String(path ?? "")
  if (value.startsWith("file://")) return value
  const parts = value.split("/")
  let uri = "file://"
  for (let i = 0; i < parts.length; i++) {
    if (parts[i] === "") continue
    uri += "/" + encodeURIComponent(parts[i])
  }
  return uri === "file://" ? "file:///" : uri
}

// URI-list clipboard offer: paste targets receive a persistent file URI.
// Forking wl-copy lets one-shot callers delete their source only after the
// URI target has been preserved.
function copyImageCmd(path) {
  return ["sh", "-c", "printf '%s\\n' " + sq(fileUri(path)) + " | wl-copy --type text/uri-list"]
}

// Label map identical to the bash tool's notify() case list.
function notifyBody(mode, saved) {
  const label = mode === "region" ? "Selected region" : "Active screen"
  return label + (saved ? " saved to disk" : " captured")
}
