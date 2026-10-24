.pragma library

.import "../../../../common/text/Format.js" as Format
.import "../../../../common/text/StringUtils.js" as SU
.import "../../../../common/collections/DeviceList.js" as DeviceList

// Pure helpers for the Network bar module: signal tiers, metric
// formatting, throughput deltas and wifi row sorting.
// No Qt imports - deterministic and unit-drivable, like SettingsLib.js.

// Arc groups kept opaque on the wifi-3 glyph for a 0..1 strength, one
// threshold per 25% of range: 1 = dot only, 2 = dot + inner arc,
// 3 = + middle arc, 4 = everything. A strength below 25% still draws
// the dot, so the lowest tier is 1.
function strengthDimTiers(strength) {
  var s = Number(strength)
  if (!isFinite(s)) s = 0
  if (s < 0.25) return 1
  if (s < 0.5) return 2
  if (s < 0.75) return 3
  return 4
}

// Parse the poll's key<TAB>value lines into an object.
function parseStats(raw) {
  var out = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "") continue
    var idx = line.indexOf("\t")
    if (idx === -1) continue
    out[line.substring(0, idx)] = line.substring(idx + 1).trim()
  }
  return out
}

// Byte counters -> rate (bytes/sec) via deltas between successive samples.
// The first sample after a switch (or after open) has no baseline and must
// not manufacture a spike.
function throughputState(previous, sample, now) {
  var prev = previous || {}
  var rx = parseFloat(sample.rx_bytes || "0")
  var tx = parseFloat(sample.tx_bytes || "0")
  var iface = sample.iface || ""
  var prevTime = Number(prev.prevSampleTime || 0)

  if (iface === "" || iface !== (prev.prevIface || "") || prevTime === 0) {
    return {
      prevIface: iface,
      prevRxBytes: rx,
      prevTxBytes: tx,
      prevSampleTime: now,
      downloadRate: 0,
      uploadRate: 0
    }
  }

  var dt = now - prevTime
  var down = 0
  var up = 0
  if (dt > 0) {
    down = Math.max(0, (rx - Number(prev.prevRxBytes || 0)) / dt)
    up = Math.max(0, (tx - Number(prev.prevTxBytes || 0)) / dt)
  }

  return {
    prevIface: iface,
    prevRxBytes: rx,
    prevTxBytes: tx,
    prevSampleTime: now,
    downloadRate: down,
    uploadRate: up
  }
}

function formatBytes(bytes) {
  return Format.formatBytes(bytes)
}

function formatRate(bytesPerSec) {
  return Format.formatByteRate(bytesPerSec)
}

// Human label for a WifiSecurityType enum value (ordered by its numeric
// value in Quickshell.Networking). Quickshell exposes no per-network MAC/
// BSSID (only the radio's `device.address`), so the subtext pairs the
// signal percentage with the security type instead.
var SECURITY_LABELS = [
  "WPA3-Enterprise", // Wpa3SuiteB192
  "WPA3", // Sae
  "WPA2-Enterprise", // Wpa2Eap
  "WPA2", // Wpa2Psk
  "WPA-Enterprise", // WpaEap
  "WPA", // WpaPsk
  "WEP", // StaticWep
  "WEP", // DynamicWep
  "LEAP", // Leap
  "OWE", // Owe
  "Open", // Open
  "Secured" // Unknown
]

function securityLabel(security) {
  var s = parseInt(security, 10)
  if (!isFinite(s) || s < 0 || s >= SECURITY_LABELS.length) return "Secured"
  return SECURITY_LABELS[s]
}

// Subtext for a network row: signal percentage, the security type, and,
// for a remembered network that is not the active one, a trailing saved
// marker - all dot-separated in the subtext tone. A remembered network is
// still the same row whether it is up or down, so the marker rides here
// rather than swapping the title suffix beside the name.
function subtextFor(row) {
  var r = row || {}
  var sig = Number(r.signal)
  if (!isFinite(sig)) sig = 0
  sig = Math.max(0, Math.min(100, Math.round(sig)))
  var label = r.securityLabel ? r.securityLabel : "Open"
  var out = sig + "% signal \u00b7 " + label
  if (r.known && !r.connected) out += " \u00b7 saved"
  return out
}

function isOutOfReach(network) {
  var n = network || {}
  var signal = Number(n.signalStrength)
  return !!n.known && !n.connected && (!isFinite(signal) || signal <= 0)
}

// Primitive snapshot of a WifiNetwork - list models must not hold live
// QObject wrappers (NetworkManager churn can destroy them mid-incubation).
// openSecurity/oweSecurity are the WifiSecurityType enums from QML.
function wifiRow(network, openSecurity, oweSecurity) {
  if (!network) return null
  var signal = Math.round((network.signalStrength || 0) * 100)
  return {
    connected: !!network.connected,
    known: !!network.known,
    outOfReach: isOutOfReach(network),
    ssid: network.name || "",
    signal: signal,
    secured: requiresCredentials(network.security, openSecurity, oweSecurity),
    securityLabel: securityLabel(network.security)
  }
}

// Human text for a failed connect, given the ConnectionFailReason enum
// values as a plain object (pure JS, node-testable). freshSecrets is true
// when the attempt ran on a just-typed passphrase: NM reports a rejected
// typed secret as NoSecrets as often as WifiAuthTimeout, so either reason
// reads as "wrong password", never "passphrase required".
function failureReasonText(reason, reasons, freshSecrets) {
  var r = reasons || {}
  if (freshSecrets === true && (reason === r.NoSecrets || reason === r.WifiAuthTimeout)) return "Wrong password"
  if (reason === r.NoSecrets) return "Passphrase required"
  if (reason === r.WifiAuthTimeout) return "Wrong password"
  if (reason === r.WifiNetworkLost) return "Network lost"
  if (reason === r.WifiClientDisconnected) return "Disconnected"
  if (reason === r.WifiClientFailed) return "Connection failed"
  return "Failed to connect"
}

// Wrong-password cleanup: a passphrase submit creates the NM profile at
// activation time, so a rejected secret would otherwise persist and every
// retry would autoconnect with the wrong password instead of re-prompting.
// Discard only fresh secrets on definitive credential failures (wrong
// password / no secrets): timeouts and drops say nothing about the secret
// (slow DHCP authenticates fine), and a previously saved profile is never
// deleted - its owner retypes or forgets it by hand.
function shouldDiscardSecrets(actionKind, freshSecrets, reason, reasons) {
  if (actionKind !== "connect" || freshSecrets !== true) return false
  var r = reasons || {}
  return reason === r.WifiAuthTimeout || reason === r.NoSecrets
}

// Connected first, then known, then by signal strength.
function sortWifiRows(rows) {
  var nets = Array.isArray(rows) ? rows.slice() : []
  nets.sort(function(a, b) {
    if (a.connected !== b.connected) return a.connected ? -1 : 1
    if (a.known !== b.known) return a.known ? -1 : 1
    return (Number(b.signal) || 0) - (Number(a.signal) || 0)
  })
  return nets
}

// Shallow equality over the snapshot fields wifiRow produces. The poll
// rebuilds a fresh array every tick; assigning it unconditionally resets
// the ListView model and recreates every delegate (focus loss, scroll
// pursuit). Skip the assignment when nothing visible changed.
function wifiRowsEqual(a, b) {
  var x = Array.isArray(a) ? a : []
  var y = Array.isArray(b) ? b : []
  if (x.length !== y.length) return false
  for (var i = 0; i < x.length; i++) {
    var r = x[i] || {}
    var s = y[i] || {}
    if (r.ssid !== s.ssid) return false
    if (!!r.connected !== !!s.connected) return false
    if (!!r.known !== !!s.known) return false
    if (!!r.outOfReach !== !!s.outOfReach) return false
    if (!!r.secured !== !!s.secured) return false
    if ((Number(r.signal) || 0) !== (Number(s.signal) || 0)) return false
    if ((r.securityLabel || "") !== (s.securityLabel || "")) return false
    if ((r.section || "") !== (s.section || "")) return false
  }
  return true
}

// Section title for a sorted row: the first row opens "KNOWN NETWORKS"
// (or "OTHER NETWORKS" when nothing is known), and any known->other
// transition opens "OTHER NETWORKS".
function sectionTitleFor(index, rows) {
  return DeviceList.sectionTitleFor(index, rows, function(row, prev, i) {
    if (!row.known) {
      if (i === 0 || (prev && prev.known)) return "OTHER NETWORKS"
      return ""
    }
    if (i === 0 || !prev || !prev.known) return "KNOWN NETWORKS"
    return ""
  })
}

// Viewport cap for the island's single wifi list: the content height,
// at most one page of rows. Single argument - there is no divider row left
// to sniff for.
function wifiListViewportHeight(contentHeight) {
  var content = Number(contentHeight)
  if (!isFinite(content) || content <= 0) return 0
  return Math.min(content, 250)
}

// Stable key for a display row: the ssid under its namespace. The key is
// never empty - a missing row still keys - and the "ssid:" prefix keeps the
// shape the model diff was written against.
function wifiDisplayKey(row) {
  return "ssid:" + String((row && row.ssid) || "")
}

// Whole wifi display-model derivation, as one pure step: the caller
// snapshots live networks into `rows` (that walk touches the backend, so
// it stays in the island) and hands them here together with the PREVIOUS
// result of this same function. Returns the next result plus the change
// flags the island needs to decide what to write and whether to arm the
// slide.
//
// One source of truth: `prev` is the exact object this function returned
// last time, so the gates below cannot drift from the arrays the island
// reads. The island must hand the whole object back untouched - the gates
// read `prev.sorted`/`prev.known`/`prev.other`, so a caller that
// reconstructs a partial prev from its own properties would silently
// decide "everything changed" on every poll and recreate every delegate.
//
// The section label is carried forward so every row in a group shares it:
// sectionTitleFor returns "" on continuations, and ListView turns a "" into
// its own blank section header - a phantom gap.
function deriveWifiState(prev, rows) {
  var p = prev || {}
  var sorted = sortWifiRows(Array.isArray(rows) ? rows : [])

  var currentSection = ""
  for (var i = 0; i < sorted.length; i++) {
    var t = sectionTitleFor(i, sorted)
    if (t !== "") currentSection = t
    sorted[i].section = currentSection
  }

  var prevSorted = Array.isArray(p.sorted) ? p.sorted : []
  var prevKnown = Array.isArray(p.known) ? p.known : []
  var prevOther = Array.isArray(p.other) ? p.other : []

  var known = []
  var other = []
  for (var j = 0; j < sorted.length; j++) {
    if (sorted[j].known) known.push(sorted[j])
    else other.push(sorted[j])
  }

  // Slide gate: the known set GREW (a promotion), keyed on ssid because the
  // poll rebuilds the row objects. A null-prototype map, so an SSID that
  // happens to be spelled "constructor" or "__proto__" reads as absent
  // instead of resolving to an inherited Object member.
  var oldKnown = Object.create(null)
  for (var o = 0; o < prevKnown.length; o++) {
    if (prevKnown[o]) oldKnown[prevKnown[o].ssid] = true
  }
  var grew = false
  for (var q = 0; q < known.length; q++) {
    if (!oldKnown[known[q].ssid]) { grew = true; break }
  }

  return {
    sorted: sorted,
    known: known,
    other: other,
    display: sorted.slice(),
    changed: !wifiRowsEqual(prevSorted, sorted),
    knownChanged: !wifiRowsEqual(prevKnown, known),
    otherChanged: !wifiRowsEqual(prevOther, other),
    grew: grew
  }
}

// Wrong-password toast: urgent but expiring. The row banner owns the
// persistence (it stands until the island reopens or the network connects),
// so this card only pings - same tag every time, so repeat failures replace
// rather than stack. No --print-id: there is no recovery to close.
function authFailureArgv(ssid) {
  const name = escapeHtml(ssid).trim()
  const body = name !== ""
    ? "The password for <b>" + name + "</b> was incorrect."
    : "The password was incorrect."
  return ["notify-send", "-a", "Vibranium", "-u", "critical",
    "-t", "8000",
    "-n", "lock",
    "-h", "string:x-vb-tag:vb-network-auth",
    "Wrong password", body]
}

// Open / OWE encrypt without credentials; every other (or unknown) type
// requires a passphrase before connecting.
function requiresCredentials(security, openSecurity, oweSecurity) {
  return security !== openSecurity && security !== oweSecurity
}

// The poll's raw sample -> the metrics the island renders, as one
// pure step. `now` is passed in (seconds, like the omarchy reference) so
// the rate is a pure function of its inputs and the caller keeps the clock.
//
// A reply with no `iface` means no active route: the link is down, rates
// read "--", and the throughput baseline is DROPPED so the next connect
// does not manufacture a spike off a stale interval. The cumulative
// counters carry forward - they are the boot-to-now totals and stay
// meaningful across a drop.
function deriveStats(prev, raw, now) {
  var p = prev || {}
  var s = parseStats(raw)
  var carryRx = Number(p.totalRxBytes) || 0
  var carryTx = Number(p.totalTxBytes) || 0

  if (!s.iface) {
    return {
      hasStats: false,
      downloadRate: 0,
      uploadRate: 0,
      totalRxBytes: carryRx,
      totalTxBytes: carryTx,
      prevThroughput: null
    }
  }

  var t = Number(now)
  if (!isFinite(t)) t = 0
  var tp = throughputState(p.prevThroughput, s, t)
  return {
    hasStats: true,
    downloadRate: tp.downloadRate,
    uploadRate: tp.uploadRate,
    // A sample that omits a counter keeps the last one rather than
    // reporting a false zero for a counter nobody read this tick.
    totalRxBytes: s.rx_bytes !== undefined ? (parseFloat(s.rx_bytes) || 0) : carryRx,
    totalTxBytes: s.tx_bytes !== undefined ? (parseFloat(s.tx_bytes) || 0) : carryTx,
    prevThroughput: tp
  }
}

// NM settings map -> the three profile toggles, or `null` when the map
// cannot back the section (empty, missing a connection/ipv4/ipv6 section,
// or a section of the wrong shape). `null` is the fail-closed answer: the
// caller hides the section rather than showing three defaults that are
// not the backend's state.
//
// Only these three keys are read. The map may carry credentials for a
// saved profile; nothing here copies, logs or forwards any field beyond
// the three booleans, so the DTO cannot leak a secret into the view.
function profileToggles(map) {
  var m = (map && typeof map === "object") ? map : null
  var conn = (m && m.connection && typeof m.connection === "object") ? m.connection : null
  var v4 = (m && m.ipv4 && typeof m.ipv4 === "object") ? m.ipv4 : null
  var v6 = (m && m.ipv6 && typeof m.ipv6 === "object") ? m.ipv6 : null
  if (!conn || !v4 || !v6) return null
  return {
    autoconnect: conn.autoconnect !== false,
    ipv4: v4.method !== "disabled",
    ipv6: v6.method !== "disabled"
  }
}

// Toggle key -> the settings patch handed to NMSettings.write(). A patch
// is the only place the section NAME ("ipv4" not "IP4") and the on/off
// vocabulary ("auto" / "disabled") are spelled, so it is a pure transform
// rather than four inline object literals in the click path. Returns null
// for a key this section does not own, and the caller writes nothing.
//
// Note the asymmetry, which is backend behavior rather than policy here:
// autoconnect takes effect on the next activation immediately, while an
// ip-method flip is persisted and applied by NM on the NEXT activation -
// re-applying it live would bounce the active link.
function profilePatch(key, on) {
  if (key === "autoconnect") return { connection: { autoconnect: !!on } }
  if (key === "ipv4") return { ipv4: { method: on ? "auto" : "disabled" } }
  if (key === "ipv6") return { ipv6: { method: on ? "auto" : "disabled" } }
  return null
}

// Escape for RichText labels: SSIDs are arbitrary bytes and must never
// break out of the markup.
//
// NOT StringUtils.styledMarkup, though that is the shared home for the same
// three replacements. styledMarkup is a formatter for text that is ALREADY
// markup: it deliberately restores &lt;b&gt; to a live <b> and turns a
// newline into <br>, because its callers pass styled bodies. This is the
// inverse contract - an SSID is hostile input and every tag in it must
// survive as text - so adopting it would let a network called `<b>x</b>`
// render as a bold x. The shared three replacements and this function agree
// on every non-markup input and disagree on exactly those two cases.
// Escape for RichText labels, canonicalized in StringUtils.escapeHtml.
// The inverse contract documented below is why this stays a wrapper over
// the SHARED three replacements rather than over styledMarkup.
function escapeHtml(s) {
  return SU.escapeHtml(s)
}

// Verdict word for the connected-row suffix: the watcher's linkNote in
// lowercase prose. Anything else - including none yet - reads as no
// suffix rather than a word nobody wrote.
function linkNoteText(note) {
  if (note === "portal") return "login required"
  if (note === "offline") return "no internet"
  if (note === "metered") return "metered"
  if (note === "configuring") return "configuring..."
  return ""
}

// Primary row line: the SSID, with a watcher verdict (if any) riding
// beside it ("SSID • login required", dot-separated, lowercase). The
// connected state itself is carried by the accent-coloured icon, so no
// "connected" word is repeated here. One Text keeps the suffix glued to
// the name through elision; the name is escaped, the dot painted in
// dotHex (subtext) and the word in its own ink. Anything not connected
// is the bare name - a remembered network says so in the subtext instead
// (see subtextFor), so the title never swaps suffixes.
//
// A connected row can carry the verdict after a single dot: the watcher's
// linkNote rendered in noteHex, silent when the verdict is empty or
// unknown.
function ssidWithStatus(ssid, connected, accentHex, dotHex, note, noteHex) {
  const safe = escapeHtml(ssid)
  const dot = dotHex === undefined || dotHex === null || dotHex === "" ? accentHex : dotHex
  if (connected) {
    const word = linkNoteText(note)
    if (word !== "") {
      const ink = noteHex === undefined || noteHex === null || noteHex === "" ? dot : noteHex
      return safe + ' <font color="' + dot + '">•</font> <font color="' + ink + '">' + word + '</font>'
    }
    return safe
  }
  return safe
}

// Fixed speedtest meter stops in Mbps: every run starts capped at 100 and
// steps up the moment a sample outgrows the cap, so the scale is always a
// labeled round number instead of a jittery auto-peak.
var SPEED_SCALE_STOPS = [100, 500, 1000, 2500, 5000, 10000]

// First stop: every run opens capped here. A function (not the var
// itself) because QML only sees top-level functions of an imported
// script, never its vars - `Model.SPEED_SCALE_STOPS` would be undefined
// at runtime while node tests keep passing through module.exports.
function initialSpeedScale() {
  return SPEED_SCALE_STOPS[0]
}

// Grow `scale` to the first stop that still contains `value`. Never
// shrinks mid-run; overshoot past the last stop pins there (the bar
// clamps at full instead).
function stepSpeedScale(scale, value) {
  var stops = SPEED_SCALE_STOPS
  var s = Number(scale)
  if (!isFinite(s) || s <= 0) s = stops[0]
  var v = Number(value)
  if (!isFinite(v)) v = 0
  var out = s
  for (var i = 0; i < stops.length; i++) {
    if (stops[i] < s) continue
    out = stops[i]
    if (v <= stops[i]) break
  }
  return out
}

// Scale cap caption: plain Mbps below a gigabit, compact Gbps above.
function speedScaleLabel(mbps) {
  var n = Number(mbps)
  if (!isFinite(n) || n <= 0) n = SPEED_SCALE_STOPS[0]
  if (n < 1000) return String(Math.round(n)) + " Mbps"
  var g = n / 1000
  return (g % 1 === 0 ? String(g) : g.toFixed(1)) + " Gbps"
}

// Parses vb-network-qr output: a "meta\t<iface>\t<security>\t<ssid>"
// header, then a square 0/1 module matrix. The SSID sits last so it may
// contain tabs. A malformed matrix returns empty rather than rendering a
// code that cannot scan.
function parseQrOutput(raw) {
  var lines = String(raw || "").trim().split(/\r?\n/).filter(function(line) { return line !== "" })
  var meta = { iface: "", security: "", ssid: "" }
  if (lines.length > 0 && lines[0].indexOf("meta\t") === 0) {
    var fields = lines.shift().split("\t")
    meta.iface = fields[1] || ""
    meta.security = fields[2] || ""
    meta.ssid = fields.slice(3).join("\t")
  }
  return { meta: meta, matrix: parseQrMatrix(lines) }
}

function parseQrMatrix(lines) {
  if (lines.length === 0) return { rows: [], size: 0 }
  var size = lines[0].length
  if (size !== lines.length) return { rows: [], size: 0 }
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].length !== size || !/^[01]+$/.test(lines[i])) return { rows: [], size: 0 }
  }
  return { rows: lines, size: size }
}

if (typeof module !== "undefined") {
  module.exports = {
    strengthDimTiers: strengthDimTiers,
    parseStats: parseStats,
    throughputState: throughputState,
    deriveStats: deriveStats,
    formatBytes: formatBytes,
    formatRate: formatRate,
    subtextFor: subtextFor,
    securityLabel: securityLabel,
    isOutOfReach: isOutOfReach,
    wifiRow: wifiRow,
    profileToggles: profileToggles,
    profilePatch: profilePatch,
    sortWifiRows: sortWifiRows,
    wifiRowsEqual: wifiRowsEqual,
    escapeHtml: escapeHtml,
    ssidWithStatus: ssidWithStatus,
    linkNoteText: linkNoteText,
    failureReasonText: failureReasonText,
    shouldDiscardSecrets: shouldDiscardSecrets,
    authFailureArgv: authFailureArgv,
    speedScaleStops: SPEED_SCALE_STOPS,
    initialSpeedScale: initialSpeedScale,
    stepSpeedScale: stepSpeedScale,
    speedScaleLabel: speedScaleLabel,
    parseQrOutput: parseQrOutput,
    parseQrMatrix: parseQrMatrix,
    sectionTitleFor: sectionTitleFor,
    deriveWifiState: deriveWifiState,
    wifiListViewportHeight: wifiListViewportHeight,
    wifiDisplayKey: wifiDisplayKey,
    requiresCredentials: requiresCredentials
  }
}
