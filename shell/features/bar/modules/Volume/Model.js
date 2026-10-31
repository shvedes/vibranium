.pragma library

.import "../../../../common/theme/DeviceIcons.js" as DeviceIcons

// Helpers for the volume bar module. Not a blind copy of the omarchy
// implementation - same ideas, rewritten for the Vibranium island.

function isPlaybackStream(node) {
  if (!node || !node.isStream) return false
  if (node.isSink === true) return true
  var cls = String(node.type || "")
  return cls.indexOf("Stream/Output/Audio") !== -1
    || cls.indexOf("AudioOutStream") !== -1
    || cls.indexOf("Output") !== -1
}

function isCaptureStream(node) {
  if (!node || !node.isStream) return false
  if (node.isSink === false) return true
  var cls = String(node.type || "")
  return cls.indexOf("Stream/Input/Audio") !== -1
    || cls.indexOf("AudioInStream") !== -1
    || cls.indexOf("Input") !== -1
}

// Playback app rows over a node list, in list order: the island's mixer
// section and the bar tooltip's app count read one function, so the two
// can never disagree about what counts as an app. RowIdentity note from
// the island applies: nothing on a node is a safe key, so this returns
// the nodes themselves, never keyed records. Null-tolerant like
// listSnapshot, but deliberately not Array-gated: tracker-backed lists
// are list-likes, not JS arrays, so the loop reads them by
// length and index.
function playbackStreams(list) {
  if (list === null || list === undefined) return []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var n = list[i]
    if (!n || !n.isStream) continue
    if (!isPlaybackStream(n)) continue
    if (String(n.name || "").indexOf("omarchy_speaker_tuning") === 0) continue
    if (String(n.name || "").indexOf("eq_") === 0) continue
    if (!n.audio) continue
    out.push(n)
  }
  return out
}

function listSnapshot(list) {
  return list && list.slice ? list.slice() : []
}

function nodeProps(node) {
  return node && node.ready && node.properties ? node.properties : {}
}

function friendlyDeviceLabel(text) {
  var label = String(text || "").trim()
  label = label.replace(/^built[- ]?in audio\s+/i, "")
  label = label.replace(/\s+Output$/i, "")
  label = label.replace(/\s+Input$/i, "")
  return label
}

function nodeLabel(node) {
  if (!node) return "Unknown"
  var p = nodeProps(node)
  var nick = friendlyDeviceLabel(node.nickname || node.nick || p["node.nick"] || p["device.profile.description"] || "")
  if (nick) return nick
  return friendlyDeviceLabel(node.description || p["node.description"] || node.name || "Unknown")
}

function sinkDeviceIcon(node) {
  if (!node) return ""
  var p = nodeProps(node)
  // Collect candidate strings in priority order: authoritative
  // form_factor first, then icon_name, then human labels and node name.
  // The match itself is canonicalized in common/theme/DeviceIcons.js.
  function lower(v) { return String(v || "").toLowerCase() }
  return DeviceIcons.iconForFormFactor(
    lower(p["device.form_factor"] || p["device.formFactor"]),
    lower(p["device.icon_name"] || p["device.iconName"] || p["device.icon-name"]),
    lower(node.name),
    lower(node.description || p["node.description"]),
    lower(node.nickname || node.nick || p["node.nick"]),
    lower(p["device.description"]))
}

// Glyph for the volume pill's tooltip row: the sink's device type - a
// headset (mic plus output), plain headphones, or the generic speaker.
// The device glyph stays even while muted: mute state and level live on the
// row below, which already carries the muted mark. The tiered volume glyph
// is deliberately not used here: it is the bar's level display, and the row
// already prints the level as text.
function sinkTooltipIcon(node) {
  if (!node || !node.audio) return "volume-off"
  var device = sinkDeviceIcon(node)
  return device !== "" ? device : "speaker"
}

function rawStreamLabel(node) {
  if (!node) return ""
  var p = nodeProps(node)
  return p["application.name"]
    || node.description
    || p["media.name"]
    || p["node.name"]
    || node.name
    || ""
}

function streamLabel(node) {
  var label = String(rawStreamLabel(node) || "").trim()
  if (label === "") return "Stream"
  // Small friendliness pass: Spotify's stream is often "audio-src"
  // which is not useful - fall back to application name already tried.
  if (label.toLowerCase() === "audio-src") {
    var p = nodeProps(node)
    var alt = String(p["application.name"] || node.name || "").trim()
    if (alt !== "" && alt.toLowerCase() !== "audio-src") return alt
  }
  return label
}

function appIconName(node) {
  var p = nodeProps(node)
  // The same four candidates in the same order as the mixer's, so a
  // stream looks the same in the island and in the mixer. Deliberately
  // no raw node.name fallback (see DeviceIcons): values like
  // "eq_output" have no icon and produce purple checker.
  return DeviceIcons.appIconNameFromProps(function(key) {
    var v = p[key]
    return typeof v === "string" ? v.trim() : ""
  })
}

function outputVolumeName(volume, muted) {
  if (muted) return "Muted"
  var p = Math.round(volume * 100)
  if (p === 0 && volume >= 0) return "Silenced"
  if (p >= 100) return "Loud"
  if (p >= 70) return "High"
  if (p >= 40) return "Medium"
  if (p >= 15) return "Low"
  return "Quiet"
}
