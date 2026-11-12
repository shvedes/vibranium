// Shared device/file icon vocabulary (qs.common.theme).
//
// Single source for the device-row glyph picks: bluetooth class names,
// volume sink form factors, mixer media classes, application icon names,
// and the tiered volume level. Canonical home of Bluetooth deviceIconName,
// Volume sinkDeviceIcon/appIconName, Mixer iconForMediaClass/appIconName,
// Audio volumeIconFor/volumeDimTiersFor and the Notifications/OSD mirrors.
// Pure JS, pragma library, no Qt imports - importable from .js libs and
// QML alike.
.pragma library

// --- tiered volume level --------------------------------------------

// The level at or below which a glyph reads as silence. PipeWire reports
// 0..1 fractions and the shell's own steps land exactly on 0, so the
// threshold only absorbs float dust; it is not a "quiet" band.
var SILENT_LEVEL = 0.01

// Whether a level reads as silence: explicitly muted, or driven to zero.
// This is the glyph's own question - volume-off is the answer for both -
// and it is also the colour's: the red off-mark means "nothing audible",
// which a zero level is whether or not anyone pressed mute. Keep the raw
// `muted` for the controls that must not claim a mute the user never
// performed (a toggle, a "Muted" readout).
function silentFor(volume, muted) {
  let v = Number(volume)
  return muted === true || !isFinite(v) || v <= SILENT_LEVEL
}

// Level icon for a 0..1 volume fraction. Single tiered asset:
// volume-max renders every level through dimTiers below, so this never
// names per-tier files (volume-low/mid ship no SVGs and would paint
// blank). Canonical home of Audio.volumeIconFor and its
// Notifications/OSD mirrors.
function volumeIconFor(volume, muted) {
  return silentFor(volume, muted) ? "volume-off" : "volume-max"
}

// Wave groups kept opaque on the tiered volume-max glyph, same thirds as
// volumeIconFor: 0 = whole glyph, 1 = speaker only, 2 = speaker + inner
// wave, 3 = everything. volume-off has no tiers and gets 0. Canonical
// home of Audio.volumeDimTiersFor and its mirrors.
function volumeDimTiersFor(volume, muted) {
  if (silentFor(volume, muted)) return 0
  let v = Number(volume)
  if (v < 1 / 3) return 1
  if (v < 2 / 3) return 2
  return 3
}

// --- bluetooth device class ------------------------------------------

// Icon stem for a bluetooth device-class string, so each type keeps a
// distinctive glyph instead of the generic bluetooth badge. Empty when
// the class is unknown - callers fall back to the bluetooth icon.
// Canonical home of Bluetooth deviceIconName; takes the class string so
// both the island and the model share one matcher.
function iconForDeviceClass(iconClass) {
  let icon = String(iconClass || "").toLowerCase()
  if (/keyboard/.test(icon)) return "keyboard"
  if (/mous/.test(icon)) return "mice"
  if (/gaming|game|joy/.test(icon)) return "gamepad"
  if (/headset/.test(icon)) return "headset"
  if (/headphon/.test(icon)) return "headphones"
  if (/speaker|audio|multimedia|sound/.test(icon)) return "speaker"
  if (/comput|desktop|laptop|pc/.test(icon)) return "monitor"
  return ""
}

// --- volume sink form factor -----------------------------------------

// Sink device glyph from PipeWire property strings: headset (mic plus
// output), plain headphones, or "" for the generic speaker. Canonical
// home of Volume sinkDeviceIcon. Takes plain strings (already
// lowercased by the caller wrapper) so the matcher is unit-drivable
// without a node object.
function iconForFormFactor(form, icon, name, desc, nick, devDesc) {
  function has(s, sub) { return String(s || "").indexOf(sub) !== -1 }
  if (has(form, "headset") || has(icon, "headset") || has(name, "headset")
    || has(desc, "headset") || has(nick, "headset") || has(devDesc, "headset")) return "headset"
  if (has(form, "headphone") || has(icon, "headphone") || has(name, "headphone")
    || has(desc, "headphone") || has(nick, "headphone") || has(devDesc, "headphone")) return "headphones"
  return ""
}

// --- mixer media class -----------------------------------------------

// The graph's own class names mapped onto the shipped icon set. A class
// nobody matches returns "", so the caller falls through to the node's
// own name rather than to a wrong glyph. Canonical home of Mixer
// iconForMediaClass.
function iconForMediaClass(cls) {
  let c = String(cls)
  if (c === "Stream/Output/Audio") return "music"
  if (c === "Stream/Input/Audio") return "mic-on"
  if (c === "Audio/Sink") return "speaker"
  if (c === "Audio/Source") return "mic-on"
  if (c === "Sink/Input/Audio" || c === "Source/Output/Audio") return "link"
  return ""
}

// --- application icon name -------------------------------------------

// The icon name an APPLICATION chose for its own stream, or "" when it
// named none. Canonical home of the Volume/Mixer appIconName pair, which
// read the same four candidates in the same order so a stream looks the
// same in the island and in the mixer:
//
//   application.icon-name        what the application declared for itself
//   application.iconName         the camel spelling of the same key
//   application.process.binary   the executable, which is what a desktop entry
//                                is keyed on
//   application.name             the last thing that is still an application
//
// Takes a property getter get(key) so both property-map shapes (Volume
// nodeProps, Mixer propText) share one candidate walk. Deliberately does
// NOT fall back to node.name: values like "eq_output" are a filter
// chain's own name, no desktop entry publishes one, and the shell icon
// set's miss renders as a purple checker. "" is the honest answer here,
// and the caller turns it into the generic glyph.
function appIconNameFromProps(get) {
  let keys = ["application.icon-name", "application.iconName",
    "application.process.binary", "application.name"]
  for (let i = 0; i < keys.length; i++) {
    let cand = ""
    try {
      cand = get(keys[i])
    } catch (ignored) {
      cand = ""
    }
    if (typeof cand === "string" && cand.trim() !== "") return cand.trim()
  }
  return ""
}

if (typeof module !== "undefined") {
  module.exports = {
    volumeIconFor: volumeIconFor,
    volumeDimTiersFor: volumeDimTiersFor,
    silentFor: silentFor,
    iconForDeviceClass: iconForDeviceClass,
    iconForFormFactor: iconForFormFactor,
    iconForMediaClass: iconForMediaClass,
    appIconNameFromProps: appIconNameFromProps
  }
}
