.pragma library

// Classification and labeling of a PipeWire audio node, shared by the mixer
// (which draws the node) and the audio service (which publishes typed IPC
// rows). One copy of the rules means a row the IPC surface calls a "playback
// stream" is the same row the Apps tab lists, and a shell peak tap filtered
// out of the UI is also absent from `audio apps`.
//
// Pure: no Qt, no QML object references, no host object. A node is a value
// with a property map and two boolean flags; an accessor that throws answers
// "absent" rather than taking a binding or an IPC reply down with it.
.import "../math/Range.js" as Range

var SHELL_OWN_NAME = "quickshell"
var CAPTURE_CLASS = "Stream/Input/Audio"

function text(value) {
  if (typeof value !== "string") return ""
  return value.trim()
}

function props(node) {
  if (node === null || node === undefined) return ({})
  try {
    const p = node.properties
    if (p !== null && typeof p === "object") return p
  } catch (ignored) {
    return ({})
  }
  return ({})
}

function propText(node, key) {
  const p = props(node)
  if (!Object.prototype.hasOwnProperty.call(p, key)) return ""
  return text(p[key])
}

function nodeName(node) {
  if (node === null || node === undefined) return ""
  try {
    return text(node.name)
  } catch (ignored) {
    return ""
  }
}

// The decimal PipeWire node id as its join key, or "" for an unkeyable node.
// Kept local so a common helper has no edge into a feature layer; the mixer's
// NodeKey.js stays the canonical copy for its own graph joins.
function nodeKey(node) {
  if (node === null || node === undefined) return ""
  let id = null
  try { id = node.id } catch (ignored) { return "" }
  if (typeof id === "string") return /^\d+$/.test(id.trim()) ? id.trim() : ""
  if (typeof id !== "number" || !isFinite(id) || id < 0) return ""
  return String(Math.round(id))
}

// What a node is, from the two booleans the API documents and nothing else.
// `type` is a flags value and a string/number reading of it is not a
// classification. null is a real answer: drop the node rather than guess a
// row that would write a level onto the wrong object.
function classify(node) {
  if (node === null || node === undefined) return null
  let sink = null
  let stream = null
  try {
    sink = node.isSink
    stream = node.isStream
  } catch (ignored) {
    return null
  }
  if (typeof sink !== "boolean" || typeof stream !== "boolean") return null
  if (sink === true) return stream === true ? "playbackStream" : "outputDevice"
  return stream === true ? "captureStream" : "inputDevice"
}

function isStreamKind(kind) {
  return kind === "playbackStream" || kind === "captureStream"
}

function isDeviceKind(kind) {
  return kind === "outputDevice" || kind === "inputDevice"
}

function kindColorKey(kind) {
  if (kind === "playbackStream") return "green"
  if (kind === "captureStream") return "red"
  if (kind === "outputDevice") return "blue"
  if (kind === "inputDevice") return "yellow"
  return "foreground_1"
}

function isMonitorLeg(sourceKind, targetKind) {
  if (sourceKind === "inputDevice") return targetKind === "outputDevice"
  if (sourceKind === "outputDevice") return targetKind === "inputDevice"
  return false
}

// A source monitor is a node whose name ends in ".monitor". This is a
// property of the name the graph published, never a node this shell builds.
function isMonitorName(name) {
  return text(name).slice(-8) === ".monitor"
}

function monitor(node) { return isMonitorName(nodeName(node)) }

// `media.class` containing "/Virtual" or `node.virtual` being true (either
// the boolean or the string "true") marks a virtual device. Real and virtual
// devices are both listed; the flag distinguishes them without naming a
// path or a property dump.
function virtual(node) {
  const cls = propText(node, "media.class")
  if (cls.indexOf("/Virtual") >= 0) return true
  let v = null
  try { v = node.virtual } catch (ignored) { v = null }
  if (v === true) return true
  const pv = props(node)
  if (Object.prototype.hasOwnProperty.call(pv, "node.virtual")) {
    const raw = pv["node.virtual"]
    return raw === true || (typeof raw === "string" && raw.trim().toLowerCase() === "true")
  }
  return false
}

function isShellOwnName(name) {
  const n = text(name).toLowerCase()
  if (n === "") return false
  if (n === SHELL_OWN_NAME) return true
  return n.indexOf(SHELL_OWN_NAME + ".") === 0
    || n.indexOf(SHELL_OWN_NAME + "-") === 0
    || n.indexOf(SHELL_OWN_NAME + "_") === 0
}

// The shell's own peak taps are streams named after the shell that belong to
// no application, or carry the capture class. An application's own capture
// stream has the same class and is kept, so the class alone is never the
// test.
function isShellTap(node) {
  if (!isShellOwnName(nodeName(node))) return false
  if (propText(node, "application.name") === "") return true
  return propText(node, "media.class") === CAPTURE_CLASS
}

// The positive form used by the Apps tab and by `audio apps`: a stream is an
// application stream unless it is one of our own taps. A stream without an
// `application.name` is NOT automatically a shell tap.
function isApplicationStream(node) { return !isShellTap(node) }

// The mixer's label precedence: nickname, description, media name, node
// name. The numeric PipeWire id is never a label.
function label(node) {
  if (node === null || node === undefined) return ""
  let nick = ""
  let desc = ""
  try {
    nick = text(node.nickname)
    desc = text(node.description)
  } catch (ignored) {
    return ""
  }
  if (nick !== "") return nick
  if (desc !== "") return desc
  const media = propText(node, "media.name")
  if (media !== "") return media
  return text(node.name)
}

// `application.name` when the stream publishes one, else null: a stream
// without it still gets a row, and the row says "no app" honestly.
function appNameOrNull(node) {
  const app = propText(node, "application.name")
  return app === "" ? null : app
}

// Fallback order for the secondary line, kept for the mixer's own use.
function appName(node) {
  const app = propText(node, "application.name")
  if (app !== "") return app
  const media = propText(node, "media.name")
  if (media !== "") return media
  return label(node)
}

function nodeAudio(node) {
  if (node === null || node === undefined) return null
  return node.audio === undefined ? null : node.audio
}

function nodeVolume(node) {
  const audio = nodeAudio(node)
  return audio === null ? 0 : Number(audio.volume) || 0
}

function nodeMuted(node) {
  const audio = nodeAudio(node)
  return audio !== null && audio.muted === true
}

function percent(volume) {
  const v = Number(volume)
  if (!isFinite(v)) return 0
  return Math.round(v * 100)
}

// The stream slider's rule, shared by the UI and `audio stream <ID> set`:
// clamp to the row's ceiling and unmute only on a deliberate non-zero write.
// At zero an explicit mute is preserved, unlike an absolute device set.
function applyVolume(audio, value, maximum) {
  if (audio === null || audio === undefined) return false
  audio.volume = Range.clamp(Number(value), 0, Number(maximum))
  if (Number(value) > 0 && audio.muted) audio.muted = false
  return true
}
