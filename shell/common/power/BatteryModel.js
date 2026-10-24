.pragma library

.import "../text/Format.js" as Format
.import "../text/Duration.js" as DurationFmt

// Pure helpers for the Battery bar module: level thresholds, icon and
// tone selection, device labels/type glyphs and row projections.
// No Qt imports - deterministic and unit-drivable, like the network and
// bluetooth modules' Model.js files.
//
// This is common/power/ rather than the bar module's own directory
// because a services/ unit may not import features/ - the power
// services read battery state too, and one definition of "empty" and
// one level table beat two copies that can drift apart.
//
// Level contract (percentages inclusive):
//   charging            -> battery-charging (bolt in accent green)
//   pct <= 5            -> battery-0 (whole outline in red)
//   pct <= 15           -> battery-1 (pill in orange)
//   pct <= 30           -> battery-2 (pills in yellow)
//   otherwise           -> battery-3 (pills in green)

// UPower reports charge through D-Bus as 0..100, but the Quickshell
// UPowerDevice.percentage property arrives normalized to a 0..1
// fraction (a full device reads 1 while the daemon says 100 - probed
// live over D-Bus). Normalize to 0..100 here so every threshold below
// reads real percent: fractions scale up, anything already above 1
// passes through untouched.
function normalizePct(value) {
  var n = Number(value)
  if (!isFinite(n)) return 100
  return n <= 1 ? n * 100 : n
}

// Level icon for a percentage + charging flag. Percentages arrive
// through normalizePct (Quickshell reports a 0..1 fraction); non-finite
// values read as full - LinePower-style devices never reach here, they
// are filtered by isTrackedType.
function batteryIconFor(percentage, charging) {
  if (charging) return "battery-charging"
  var p = normalizePct(percentage)
  if (p <= 5) return "battery-0"
  if (p <= 15) return "battery-1"
  if (p <= 30) return "battery-2"
  return "battery-3"
}

// Indicator (pill/bolt) accent for a level icon. "" means no accent:
// battery-0 carries no pills (its outline goes red through
// batteryColorFor).
function batteryAccentFor(percentage, charging) {
  if (charging) return "green"
  var p = normalizePct(percentage)
  if (p <= 5) return ""
  if (p <= 15) return "orange"
  if (p <= 30) return "yellow"
  return "green"
}

// Body tone for a level icon. Only battery-0 diverges (whole outline
// red); everything else keeps the theme foreground with the level
// carried by the accent above.
function batteryColorFor(percentage, charging) {
  if (!charging) {
    var p = normalizePct(percentage)
    if (p <= 5) return "red"
  }
  return "foreground_0"
}

// Whether a UPower device type carries a battery worth showing.
// LinePower (the AC adapter) and Unknown never do; every other type -
// the laptop Battery itself plus mice, keyboards, headsets and the rest
// - does. Callers pass the UPowerDeviceType enum members through so this
// stays unit-drivable without Qt imports.
function isTrackedType(type, linePower, unknown) {
  return type !== linePower && type !== unknown
}

// Whether a UPower device state means the charge is going down.
//
// The three states that mean it is NOT are named, and everything else counts:
// Discharging, Empty, PendingDischarge, and Unknown. Unknown is the one that
// decides this function, so it is worth stating why it counts as running down.
//
// UPower only derives a charge state for a device that reports one. A Logitech
// HID++ mouse exposes charging over the wire, so its state is Discharging.
// A Bluetooth HID peripheral - a gamepad, a keyboard, a headset - exposes no
// such property at all, so UPower has nothing to derive from and reports
// Unknown for the entire life of the connection, at every charge level,
// whether the battery is full or flat. Measured on two devices on one machine,
// same daemon, same session:
//
//   Logitech G305      (hidpp)          State 2  Discharging
//   Xbox Wireless Ctrl (bluetooth hid)  State 0  Unknown
//
// Treating Unknown as "not discharging" therefore reads "not discharging" as
// "not running down", which permanently silences every Bluetooth peripheral
// for the whole time it is connected - and the peripherals are the majority of
// the devices this file exists to serve. It is a silent failure: the device is
// watched, it is present, its level is read, and it can never announce.
//
// The direction of the error is what makes this safe. Eligibility only ever
// matters once a device is ALREADY under a threshold, because that is what
// alertFor decides; a device above the threshold is silent either way. So
// counting an unreadable state as running down can cost one alert on a battery
// that did not need one, and skipping it costs every alert on a battery that
// did. Callers pass the UPowerDeviceState enum members through so this stays
// unit-drivable without Qt imports, the same way isTrackedType does.
function isRunningDown(state, charging, fullyCharged, pendingCharge) {
  return state !== charging && state !== fullyCharged && state !== pendingCharge
}

// Human label for a device: the UPower model (e.g. "Logitech G305"),
// falling back to the type string ("Mouse") and then the native path.
function deviceLabel(model, typeString, nativePath) {
  var m = String(model || "").trim()
  if (m !== "") return m
  var t = String(typeString || "").trim()
  if (t !== "") return t
  var n = String(nativePath || "").trim()
  return n === "" ? "Unknown device" : n
}

// Representative glyph stem for a row, chosen from the UPower type
// string (UPowerDeviceType.toString) so each device class keeps a
// distinctive icon. Empty when the class has no shipped glyph -
// callers fall back to the generic bluetooth mark, mirroring the
// bluetooth module's unknown-class fallback.
function deviceIconName(typeString) {
  var t = String(typeString || "").toLowerCase()
  if (/keyboard/.test(t)) return "keyboard"
  if (/mous/.test(t) || /touchpad/.test(t)) return "mice"
  if (/gaming/.test(t)) return "gamepad"
  if (/headset/.test(t)) return "headset"
  if (/headphon/.test(t)) return "headphones"
  if (/speaker|audio/.test(t)) return "speaker"
  if (/monitor/.test(t)) return "monitor"
  if (/computer|battery/.test(t)) return "monitor"
  if (/ups/.test(t)) return "power"
  if (/printer|scanner/.test(t)) return "printer"
  if (/modem|network/.test(t)) return "ethernet"
  return ""
}

// "Fully Charged" -> "Fully charged": UPowerDeviceState.toString
// returns spaced compounds ("Fully Charged", "Pending Charge" - probed
// live), the UI reads them with only the leading word capitalized.
function prettyState(stateString) {
  var s = String(stateString || "").trim()
  if (s === "") return "Unknown"
  var map = {
    Unknown: "Unknown",
    Charging: "Charging",
    Discharging: "Discharging",
    Empty: "Empty",
    FullyCharged: "Fully charged",
    PendingCharge: "Pending charge",
    PendingDischarge: "Pending discharge"
  }
  var squashed = s.replace(/\s+/g, "")
  if (map[squashed] !== undefined) return map[squashed]
  if (map[s] !== undefined) return map[s]
  return squashed.replace(/([a-z])([A-Z])/g, "$1 $2")
}

// Seconds (UPower timeToEmpty/timeToFull) -> "2h 15m" / "40m" / "<1m".
// Canonicalized in common/text/Duration.js. Zero/negative/non-finite
// means "no estimate" and renders as "" so callers can skip the fragment.
function formatDuration(seconds) {
  return DurationFmt.formatDuration(seconds)
}

// Watts (UPower changeRate) -> "8.4 W" / "-2.1 W", canonicalized in
// common/text/Format.js. Zero/non-finite means "no reading" and renders
// as "" so callers can skip the fragment.
function formatRate(watts) {
  return Format.formatWatts(watts)
}

// Secondary row line: "85% - Discharging", extended with whatever else
// UPower reports for the device - charge rate while charging (live),
// time to empty/full, health and energy (peripherals report zeros and
// hide those fragments, laptop batteries show them). Takes one object
// so call sites stay readable.
function rowSubtext(row) {
  var r = row || {}
  var pct = Math.round(Number(r.percentage))
  if (!isFinite(pct)) pct = 0
  var parts = [pct + "%", String(r.stateLabel || "Unknown")]
  var charging = !!r.charging
  if (charging) {
    var rate = formatRate(r.changeRate)
    if (rate !== "") parts.push(rate)
    var full = formatDuration(r.timeToFull)
    if (full !== "") parts.push("Full in " + full)
  } else {
    var left = formatDuration(r.timeToEmpty)
    if (left !== "") parts.push(left + " left")
  }
  var health = Number(r.healthPercentage)
  if (r.healthSupported && isFinite(health) && health > 0) {
    parts.push("Health " + Math.round(health) + "%")
  }
  var energy = Number(r.energy)
  var capacity = Number(r.energyCapacity)
  if (isFinite(energy) && energy > 0 && isFinite(capacity) && capacity > 0) {
    parts.push(energy.toFixed(1) + " / " + capacity.toFixed(1) + " Wh")
  }
  return parts.join(" - ")
}

// Lowest charge first so the critical device tops the island, ties by
// label. Operates on plain row objects ({ percentage, label, ... }),
// never on live QObjects.
function sortRows(rows) {
  var list = Array.isArray(rows) ? rows.slice() : []
  list.sort(function(a, b) {
    var pa = Number(a ? a.percentage : NaN)
    var pb = Number(b ? b.percentage : NaN)
    if (!isFinite(pa)) pa = 100
    if (!isFinite(pb)) pb = 100
    if (pa !== pb) return pa - pb
    return String(a && a.label || "").localeCompare(String(b && b.label || ""))
  })
  return list
}

// Per-device details dropdown: one { label, value } row per UPower
// field that actually carries information - telemetry first (times,
// rate, energy, health), then device facts. Fields a device does not
// report (zero times/energy, unsupported health, empty strings) are
// skipped outright, so peripherals show a short list and laptop
// batteries the full one. Takes one plain object so call sites stay
// readable; never returns null (an empty list renders the "no additional
// information" hint instead).
function detailRows(info) {
  var r = info || {}
  var out = []
  function add(label, value) {
    var v = String(value === undefined || value === null ? "" : value).trim()
    if (v === "") return
    out.push({ label: label, value: v })
  }
  var pct = Math.round(Number(r.percentage))
  add("State", r.stateLabel)
  if (isFinite(pct)) out.push({ label: "Charge", value: pct + "%" })
  var tte = formatDuration(r.timeToEmpty)
  if (tte !== "") out.push({ label: "Time to empty", value: tte })
  var ttf = formatDuration(r.timeToFull)
  if (ttf !== "") out.push({ label: "Time to full", value: ttf })
  var rate = formatRate(r.changeRate)
  if (rate !== "") out.push({ label: "Charge rate", value: rate })
  var energy = Number(r.energy)
  if (isFinite(energy) && energy > 0) out.push({ label: "Energy", value: energy.toFixed(1) + " Wh" })
  var capacity = Number(r.energyCapacity)
  if (isFinite(capacity) && capacity > 0) out.push({ label: "Energy capacity", value: capacity.toFixed(1) + " Wh" })
  var health = Number(r.healthPercentage)
  if (r.healthSupported && isFinite(health) && health > 0)
    out.push({ label: "Health", value: Math.round(health) + "%" })
  add("Type", r.typeLabel)
  if (r.present === true) out.push({ label: "Present", value: "Yes" })
  else if (r.present === false) out.push({ label: "Present", value: "No" })
  if (r.powerSupply === true) out.push({ label: "Power supply", value: "Yes" })
  else if (r.powerSupply === false) out.push({ label: "Power supply", value: "No" })
  if (r.laptopBattery === true) out.push({ label: "Laptop battery", value: "Yes" })
  else if (r.laptopBattery === false) out.push({ label: "Laptop battery", value: "No" })
  add("Native path", r.nativePath)
  add("Icon", r.iconName)
  return out
}

// Bar tooltip rows ({icon, text}, the weather/printers convention): one row
// per device with its class glyph - mice, keyboard, headset, gamepad,
// monitor, printer - and the level glyph when the class has no shipped
// asset, so a row always carries a glyph that says what the device is. The
// level glyph is resolved from the SAME sanitized percentage the text
// prints, so a row can never glyph a level that disagrees with its own
// number. Deliberately just the device, its glyph and the charge - state
// and telemetry live in the island.
function tooltipRows(entries) {
  var list = Array.isArray(entries) ? entries : []
  var rows = []
  for (var i = 0; i < list.length; i++) {
    var e = list[i] || {}
    var pct = Math.round(Number(e.percentage))
    if (!isFinite(pct)) pct = 0
    rows.push({
      icon: deviceIconName(e.typeString) || batteryIconFor(pct, !!e.charging),
      text: String(e.label || "Unknown device") + " - " + pct + "%"
    })
  }
  return rows
}

// Stable key for one device, for the maps a reader keys on: the levels a
// device has already announced, the watcher built for it. nativePath
// first, then the lowercased type string, and "" when neither is a
// non-empty string.
//
// Invariant: the same device always reads as the same key and two
// devices never share one. UPower's UPowerDevice has no `id` property
// and no `busName` property (checked against the installed type
// description, /usr/lib/qt6/qml/Quickshell/Services/UPower/
// quickshell-service-upower.qmltypes), so a key built from either is the
// bare type and every battery in the machine collapses into one entry -
// which is why the native path (/sys/class/power_supply/BAT0,
// /org/bluez/hci0/dev_E3_FA_54_FF_5A_86) is read first. It is trimmed
// because a device with no path at all reports "", and a non-string is
// treated as absent rather than stringified into a key nobody can trace.
function deviceKey(nativePath, typeString) {
  var n = typeof nativePath === "string" ? nativePath.trim() : ""
  if (n !== "") return n
  return typeof typeString === "string" ? typeString.trim().toLowerCase() : ""
}

// The two integer levels an alert service announces at, resolved from
// two raw settings values: { warn: 20, critical: 5 } by default.
//
// Invariant: both come back as integers in 1..100, and critical is
// always strictly below warn. Each input is coerced with Number, rounded,
// clamped into the range, and falls back to its shipped default (20 for
// warn, 5 for critical) when it is blank or does not coerce to a finite
// number. The catalog validates each level's own `range` and cannot
// relate the two to each other, so warn 5 with critical 90 is a setting
// it accepts and no reader can honour - keeping an ordering the service
// can honour is the service's job. The shipped defaults already satisfy
// it, so the uncrossed path returns them unchanged.
function resolveLevels(warnPct, criticalPct) {
  // Coerce one settings value into a level. Blank is a separate case from
  // non-finite because Number("") is 0, which is finite and would clamp
  // up to 1 and read as a deliberate 1% threshold.
  function level(value, fallback) {
    var raw = String(value === undefined || value === null ? "" : value).trim()
    if (raw === "") return fallback
    var n = Number(raw)
    if (!isFinite(n)) return fallback
    return Math.min(100, Math.max(1, Math.round(n)))
  }
  var asked = level(criticalPct, 5)
  var warn = level(warnPct, 20)
  var critical = asked
  if (critical >= warn) critical = warn - 1
  // `warn - 1` left nothing at all, which means warn was 1. Pull warn up
  // to one above the critical level that was asked for rather than let a
  // level fall out of the range the settings page promises; the 100
  // ceiling is the one pair that cannot fit (critical 100), and it lands
  // on 99.
  if (critical < 1) {
    warn = Math.min(100, asked + 1)
    critical = Math.max(1, warn - 1)
  }
  return { warn: warn, critical: critical }
}

// The level a sample has crossed: "critical", "warn" or "" for none.
// Invariant: at most one level comes back, and it is the most urgent one
// crossed - a sample below both thresholds announces the critical one
// only. That is what a shared notify-send replaces-id buys by
// leaving only the last card of a burst on screen; announcing both is
// how a device that dips through two levels at once gets two cards for
// one event. pct goes through normalizePct first because it is the same
// 0..1 fraction UPower reports, so a reader can pass it straight
// through.
function alertFor(pct, levels) {
  var p = normalizePct(pct)
  var l = levels || {}
  if (p <= Number(l.critical)) return "critical"
  if (p <= Number(l.warn)) return "warn"
  return ""
}

// The argv one low battery alert is sent with, for one level of one device:
// notify-send's words and their order, the level icon, the palette key that
// tints the card, the urgency, the timeout and the two sentences.
//
// This lives beside alertFor rather than in the service that posts it because
// the wire format is the contract the notification card actually receives -
// `NotificationsLib.iconColorOf` reads the hint name below and
// `NotificationCard.iconUrl` hands it to Icons.url - so it is a fact two
// readers depend on rather than one caller's private arrangement, and a
// synthetic fleet has to be able to reproduce it byte for byte.
//
// The glyph goes on `-n` (`--app-icon`) and NOT on `-i` (`--icon`), and the
// difference is the whole point of the tone hint. The two land in different
// D-Bus fields, and the card resolves them in a fixed order:
//
//   -i icon     -> `image` field -> shot.image, which the card returns first
//                  and never recolors, because that is the sender's own
//                  artwork
//   -n icon     -> app_icon     -> shot.appIcon, the one leg AppIcons.url
//                  threads the color key into, and the only leg Icons.url
//                  can repaint from the shell's own asset set
//
// Quickshell resolves an `image`-leg name to `image://icon/<name>`, which is an
// XDG icon-theme lookup: the glyph a system theme happens to ship for that
// name, in whatever colour that theme gave it, with the palette hint read into
// snapshot.iconColor and then having no leg to paint. So `-i` produces a card
// that cannot be tinted at all, and it is not a daemon limitation - the daemon
// carries both fields, and the recolourable one is the appIcon leg.
//
// `-i` also resolves to a different ASSET than the bar paints: the bar's
// battery-2 is shell/assets/icons/battery/battery-2.svg recolored through
// Icons.recolor, while `image://icon/battery-2` is whatever the platform theme
// carries. Sending `-n` puts the name through AppIcons.url -> Icons.url, which
// finds the shipped set first and only falls back to the theme when the shell
// does not ship that name.
//
// No replaces-id. The card carries the device label, so one shared id would
// let the second battery of a machine overwrite the first one's alert. The
// pile is bounded elsewhere instead: the daemon keeps eight, and alertFor's
// re-arm rule keeps one device to two cards per discharge cycle.
//
// The charging flag is the literal `false` rather than a read of the device:
// an alert is only ever announced while the device discharges, so the
// charging branch is unreachable and a card can never paint the bolt.
//
// The tone is a palette KEY and not a hex. Icons.url resolves a key against
// the live palette, so a card stays correctly toned across a theme switch.
//
// The percentage rides the summary (title) beside the device label -
// "Keychron K3 - 18%" - so the card states the level it is warning about.
// The same "label - NN%" shape the bar's tooltip rows paint, rounded from
// the same fraction the level icon reads, so the three can never disagree.
// No percentage in the body: the body keeps the level sentence only, so
// the number appears exactly once.
//
// A critical alert asks for no deadline (-t 0), and the shell's own rule
// makes a critical notification persistent whatever timeout it asked for
// (NotificationsLib.timeoutMs): an alert that silently expires is the one
// failure this channel cannot have.
function notifyArgv(level, label, percentage) {
  var critical = String(level) === "critical"
  var tone = critical ? "red" : "orange"
  var pct = Math.round(normalizePct(percentage))
  if (!isFinite(pct)) pct = 100
  return [
    "notify-send",
    "-a", "Vibranium",
    "-n", batteryIconFor(percentage, false),
    "-h", "string:x-vb-icon-color:" + tone,
    "-u", critical ? "critical" : "normal",
    "-t", critical ? "0" : "15000",
    String(label) + " - " + pct + "%",
    critical ? "Battery is critically low" : "Battery is running low"
  ]
}

// The palette key notifyArgv tints a card at this level, named on its own so
// a caller can show or assert the tone without re-deriving it from the
// urgency, which is two facts that happen to agree today.
function alertToneFor(level) {
  return String(level) === "critical" ? "red" : "orange"
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizePct: normalizePct,
    batteryIconFor: batteryIconFor,
    batteryAccentFor: batteryAccentFor,
    batteryColorFor: batteryColorFor,
    isTrackedType: isTrackedType,
    isRunningDown: isRunningDown,
    deviceLabel: deviceLabel,
    deviceIconName: deviceIconName,
    prettyState: prettyState,
    formatDuration: formatDuration,
    formatRate: formatRate,
    rowSubtext: rowSubtext,
    sortRows: sortRows,
    detailRows: detailRows,
    tooltipRows: tooltipRows,
    deviceKey: deviceKey,
    resolveLevels: resolveLevels,
    alertFor: alertFor,
    notifyArgv: notifyArgv,
    alertToneFor: alertToneFor
  }
}
