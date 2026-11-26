.pragma library

// Pure metadata and result vocabulary for the bar's public gateway.
//
// This module is data only: no Qt, no QML object references, no closures held
// in the tables. It answers three questions for Bar.qml:
//
//   1. what a shipped module id is called and whether it can own an island,
//   2. which persisted setting suffixes belong to that id,
//   3. what a gateway reply looks like on the wire.
//
// The ids are the REAL layout ids from Bar.qml's registry, not filenames. An
// owned service extends this table through Bar.ownModule(spec) with its own
// prettyName/description/hasIsland; the defaults below are for late owners
// that do not supply them.

function ok(data) { return { v: 1, ok: true, data: data } }
function silent() { return { v: 1, ok: true } }
function accepted() { return silent() }
function fail(code, message) {
  return { v: 1, ok: false, error: { code: code, message: String(message || code) } }
}

// --- shipped module metadata ------------------------------------------------

var metadata = {
  workspaces: { prettyName: "Workspaces", description: "Switch and inspect workspaces", hasIsland: false },
  privacy: { prettyName: "Privacy", description: "Show active capture indicators", hasIsland: true },
  clock: { prettyName: "Clock", description: "Local time and calendar", hasIsland: true },
  weather: { prettyName: "Weather", description: "Current conditions and forecast", hasIsland: true },
  keyboardLayout: { prettyName: "Keyboard layout", description: "Active input layout", hasIsland: false },
  bluetooth: { prettyName: "Bluetooth", description: "Nearby and connected devices", hasIsland: true },
  battery: { prettyName: "Battery", description: "Power and charge state", hasIsland: true },
  network: { prettyName: "Network", description: "Connectivity and transfer state", hasIsland: true },
  printers: { prettyName: "Printers", description: "Printer and queue status", hasIsland: true },
  powerProfile: { prettyName: "Power profile", description: "Select the active power profile", hasIsland: false },
  systemUpdates: { prettyName: "Arch updates", description: "Available system updates", hasIsland: true },
  colorPicker: { prettyName: "Color picker", description: "Pick colors and revisit samples", hasIsland: true },
  nightLight: { prettyName: "Night light", description: "Toggle warm color temperature", hasIsland: false },
  nowPlaying: { prettyName: "Now playing", description: "Media controls and track info", hasIsland: true },
  volume: { prettyName: "Volume", description: "Output and microphone levels", hasIsland: true },
  session: { prettyName: "Session", description: "Open the session power menu", hasIsland: false },
  tray: { prettyName: "System tray", description: "Status notifier items", hasIsland: false },
  downloader: { prettyName: "Downloader", description: "Download queue and progress", hasIsland: true },
  readingMode: { prettyName: "Reading mode", description: "Active reading-mode indicator", hasIsland: false },
  recording: { prettyName: "Recording", description: "Screen recording indicator", hasIsland: false },
  timer: { prettyName: "Timer", description: "Countdown indicator", hasIsland: false },
  caffeine: { prettyName: "Caffeine", description: "Idle and sleep inhibit indicator", hasIsland: false },
  update: { prettyName: "Update", description: "Running update indicator", hasIsland: false }
}

// A group uses its own id as the display name and never owns an island.
function groupMetadata(id) {
  return { prettyName: id, description: "Bar module group", hasIsland: false }
}

function ownedMetadata(spec) {
  return {
    prettyName: typeof spec.prettyName === "string" && spec.prettyName !== "" ? spec.prettyName : "",
    description: typeof spec.description === "string" && spec.description !== "" ? spec.description : "Owned bar indicator",
    hasIsland: spec.hasIsland === true
  }
}

function defaults(id) {
  return { prettyName: id, description: "Owned bar indicator", hasIsland: false }
}

function recordFor(id, table, isGroup) {
  const own = table && table[id] !== undefined ? table[id] : null
  if (own !== null && own !== undefined) return own
  if (isGroup === true) return groupMetadata(id)
  return defaults(id)
}

// --- persisted option keys --------------------------------------------------
// These are SUFFIXES appended to `shell.statusbar.` + the module id. The
// spelling is case-sensitive; no other QML property is a public option.

var options = {
  workspaces: ["RightClick"],
  network: ["RightClick", "MiddleClick"],
  bluetooth: ["RightClick", "MiddleClick"],
  tray: ["RightClick"],
  session: ["RightClick"],
  keyboardLayout: ["LeftClick", "RightClick"],
  readingMode: ["LeftClick"],
  update: ["LeftClick"],
  battery: ["Percent"],
  nowPlaying: ["Title", "Flash"],
  recording: ["Elapsed"],
  volume: ["ShowMic", "Percent", "RightClick", "MiddleClick", "MicRightClick", "MicMiddleClick"],
  clock: ["Seconds", "SecondsTooltip", "FullDate", "MoonPhase", "RightClick"],
  weather: ["ShowTemp", "Flash", "Unit", "RefreshMinutes", "Verbose", "MiddleClick"],
  systemUpdates: ["HeavyWarning"],
  nightLight: ["Temperature"]
}

function optionKeys(id, table) {
  const own = table && table[id] !== undefined ? table[id] : undefined
  const keys = own !== undefined ? own : options[id]
  return Array.isArray(keys) ? keys.slice() : []
}

function settingKey(id, suffix) { return "shell.statusbar." + id + suffix }

// The trigger names are a fixed allowlist: no dynamic method/property string
// is ever built from a caller's word.
var triggers = {
  nowPlaying: ["flashTrack"],
  weather: ["flashTemperature"],
  network: ["flashConnection"],
  bluetooth: ["flashDevice"],
  battery: ["flashCharge"]
}

function triggerNames(id) {
  return Array.isArray(triggers[id]) ? triggers[id].slice() : []
}

// Stable snapshot projection: one record per configured slot, in the column
// order the catalog publishes.
function listRecord(id, meta, enabled, visible) {
  return {
    id: id,
    prettyName: meta.prettyName,
    description: meta.description,
    enabled: enabled === true,
    visible: visible === true
  }
}
