.pragma library

.import "../../common/settings/HyprlandEditor.js" as HyprlandEditor
.import "../../common/text/StringUtils.js" as SU

// Pure policy for the connectivity watcher: the NetworkManager D-Bus value
// tables, the argv builders and the portal-URL extraction. No Qt imports -
// deterministic and unit-drivable, like the Network module's Model.js.

// NM_CONNECTIVITY_* from nm-dbus-types.h: 0 is unknown, 1 none, 2 portal,
// 3 limited, 4 full. Only the portal state gates a login: limited still
// routes, so it never asks the user to sign in.
function isPortal(connectivity) {
  return Number(connectivity) === 2
}

function isOnline(connectivity) {
  const c = Number(connectivity)
  return c === 3 || c === 4
}

// Whether the link actually reaches the internet. Strictly narrower than
// isOnline: a `limited` link is up but its check never answered, which from
// the user's side - ping fails - is no internet (an AP with mobile data
// switched off lands exactly here). The island suffix and the offline edge
// both read this, so a dead upstream can never show a plain "connected".
//
// vpnUp is the tunnel half of the verdict: NM's check can stay non-full
// while traffic leaves through a tunnel it does not manage (an out-of-band
// client like AmneziaVPN owns its own tun device, so no NM active
// connection ever appears), and an NM VPN has the same effect on the
// check. A default route through a tunnel device therefore counts as
// internet alongside a full NM reading - but never over a portal, which
// still gates first at every call site.
function hasInternet(connectivity, vpnUp) {
  if (isPortal(connectivity)) return false
  if (vpnUp === true) return true
  return Number(connectivity) === 4
}

// NM_METERED_* from nm-dbus-types.h: 0 unknown, 1 yes, 2 no, 3 guess-yes,
// 4 guess-no. A guess-yes is a yes the backend would not bet on, and for a
// warning that is the right side to err on.
function isMetered(metered) {
  const m = Number(metered)
  return m === 1 || m === 3
}

// True on an unexpected link loss: up before, down now, and not
// explained by the radio going off under a wifi link. Needs a prior
// reading (never fires before boot settled), never fires twice for one
// outage, and never while a card is already up.
//
// The radio clause reads history, not the transition, so it holds no
// matter which signal lands first: a toggle that arrives before the
// device update suppresses at the update, and the reverse order is
// cleaned up by the caller retiring optimistic cards on toggle-off.
// A link drop (no AP / no connected network) is never a "connected network
// with no internet" condition: the offline card answers a network that is up
// but dark, so a full disconnect must stay silent instead of announcing.
function linkLostEdge(prevUp, up, prevWifiUp, wifiOn, hasReading, shown) {
  return false
}

// --- transition policy ---------------------------------------------------
//
// The watcher's decisions as pure steps over explicit state, so synthetic
// sequences can drive them: announce once per episode, withdraw on
// recovery, never flap. The service maps the returned verbs to effects
// and owns nothing else about the decision.

// Portal card: "announce" on entry, "clear" when the link recovered,
// "lost" when it went away instead, null while settled either way.
function portalStep(shown, conn) {
  if (isPortal(conn) && !shown) return "announce"
  if (!isPortal(conn) && shown) return isOnline(conn) ? "clear" : "lost"
  return null
}

// Metered card: "announce" on entry, "retire" when muted while shown,
// "withdraw" on recovery, "rename" when the episode roams, null while
// settled. Muted and unshown is silence, never an announce.
function meteredStep(shown, shownSsid, met, ssid, muted) {
  const on = isMetered(met)
  if (on && !muted && !shown) return "announce"
  if (on && muted && shown) return "retire"
  if (!on && shown) return "withdraw"
  if (on && !muted && shown && ssid !== shownSsid) return "rename"
  return null
}

// Grace before the first verdict on a fresh link: NM needs seconds
// after association to tell "no route yet" from "no internet", and a
// card in that window would flash and retract on every join.
var OFFLINE_GRACE_MS = 5000

// Offline card. linked is the association read, required only on the
// dark-and-unshown path - every other path decides without it, so pass
// null there. nowMs is the caller's clock, linkUpAtMs the association
// moment it last stored. Returns the verb plus the link memory to store:
// online and portal polls imply an association, a dark poll reports what
// it read, and a linkless dark poll is silence that still clears the
// memory so a fresh association announces like a transition.
//
// A fresh link waits out the grace ("defer", and the service re-polls
// when it lapses); a link that was already up when it went dark
// announces at once. Steady dark and shown cards are silence.
function offlineStep(shown, conn, prevConn, prevLinked, linked, linkUpAtMs, nowMs, vpnUp, prevVpnUp) {
  if (!isPortal(conn) && hasInternet(conn, vpnUp)) {
    return shown
      ? { act: "withdraw", prevLinked: true, linkUpAtMs: linkUpAtMs }
      : { act: null, prevLinked: true, linkUpAtMs: linkUpAtMs > 0 ? linkUpAtMs : nowMs }
  }
  if (isPortal(conn)) {
    return { act: null, prevLinked: true, linkUpAtMs: linkUpAtMs > 0 ? linkUpAtMs : nowMs }
  }
  if (shown) return { act: null, prevLinked: prevLinked, linkUpAtMs: linkUpAtMs }
  if (linked !== true) return { act: null, prevLinked: false, linkUpAtMs: 0 }
  const since = linkUpAtMs > 0 ? linkUpAtMs : nowMs
  // A link that was effectively online when it went dark announces: the
  // previous full reading covers the raw case, the previous tunnel the
  // VPN one, so dropping a tunnel still surfaces at once instead of
  // reading as steady-dark silence.
  const fresh = !prevLinked || (!isPortal(prevConn) && hasInternet(prevConn, prevVpnUp))
  if (fresh && nowMs - since >= OFFLINE_GRACE_MS) {
    return { act: "announce", prevLinked: true, linkUpAtMs: since }
  }
  if (fresh) {
    return { act: "defer", prevLinked: prevLinked, linkUpAtMs: since }
  }
  return { act: null, prevLinked: true, linkUpAtMs: since }
}

// Join confirmation verdict: announce once when the associated wifi
// network changes to a new SSID, whatever the verdict says after - the
// portal, offline and metered cards own what follows. boot (unknown
// previous), steady states, drops and roams onto the same name are all
// silence - only a fresh association speaks. Returns the SSID to store
// alongside, so the check stays a pure function of its inputs.
//
// An empty reading while the previous is still unknown is not a drop, it
// is the backend still settling: the service constructs before
// NetworkManager has associated, so the first observations are "".
// Storing "" would turn the boot join ("" -> SSID) into an announced
// transition - the shell congratulating a link it never saw come up.
// Keeping null until a real name lands makes the boot association silent
// like every other unknown-previous case, while a later drop (stored SSID
// -> "") and rejoin ("" -> SSID) still announce.
function connectStep(prevSsid, ssid) {
  const cur = String(ssid || "")
  if (prevSsid === null || prevSsid === undefined) {
    return cur === "" ? { announce: false, ssid: prevSsid } : { announce: false, ssid: cur }
  }
  if (cur === "" || cur === String(prevSsid)) return { announce: false, ssid: cur }
  return { announce: true, ssid: cur }
}

// The island suffix verdict, from the same two readings the cards use:
// "portal" while a login gates the link, "configuring" while the link is
// still being set up, "offline" while the link cannot reach the internet,
// "metered" while a full link is billed, "" otherwise.
// Login gates first: a portal that is also metered still needs the sign-in
// before the billing matters. Setup only softens the dark verdict: a link
// that already answers (full) or gates (portal) reports what it is, never
// "configuring". No reading yet is silence, never a verdict -
// the first poll has not landed and "no internet" would flash on every boot.
function linkNote(connectivity, metered, hasReading, vpnUp, configuring) {
  if (hasReading !== true) return ""
  if (isPortal(connectivity)) return "portal"
  if (!hasInternet(connectivity, vpnUp)) return configuring === true ? "configuring" : "offline"
  if (isMetered(metered)) return "metered"
  return ""
}

// `busctl get-property --json=short` answers {"type":"u","data":2}. -1 when
// the reply is anything else: an unreadable bus is unknown, never a state
// to announce, and the watcher keeps its previous reading instead.
function parseUintProp(stdout) {
  let reply
  try {
    reply = JSON.parse(String(stdout))
  } catch (e) {
    return -1
  }
  if (!reply || typeof reply !== "object") return -1
  const n = Number(reply.data)
  if (!isFinite(n) || n < 0 || Math.floor(n) !== n) return -1
  return n
}

// Same envelope, string payload: {"type":"s","data":"MyWifi"}. "" when the
// reply is anything else - an unreadable name is no name, and the card
// falls back to its generic body.
function parseStringProp(stdout) {
  let reply
  try {
    reply = JSON.parse(String(stdout))
  } catch (e) {
    return ""
  }
  if (!reply || typeof reply !== "object") return ""
  return typeof reply.data === "string" ? reply.data : ""
}

// Same envelope, object-path payload: {"type":"o","data":"/org/..."}.
// "/" is the bus spelling of "no object", which reads as "" here.
function parseObjectPath(stdout) {
  const path = parseStringProp(stdout)
  return path === "/" ? "" : path
}

// Pango escaping for the one hostile input a card body carries: the SSID
// is arbitrary bytes and must survive as text. The daemon renders markup,
// so an unescaped `<b>` in a network name would restyle the card.
function escapeMarkup(s) {
  return SU.escapeHtml(s)
}

// One NM root property read, in the Inhibitor/MediaState shape: `busctl`
// defaults to the system bus, and --json=short is the pinned reply shape
// parseUintProp reads.
function propArgv(prop) {
  return ["busctl", "get-property", "--json=short",
    "org.freedesktop.NetworkManager", "/org/freedesktop/NetworkManager",
    "org.freedesktop.NetworkManager", String(prop)]
}

// Default-route read behind the tunnel half of the verdict: one `ip`
// fork per poll, no bus round trip. parseVpnUp answers whether any of
// those defaults leaves through a tunnel device.
//
// The full table (not just `default`) is listed: WireGuard/OpenVPN-style
// hijacks install 0.0.0.0/1 + 128.0.0.0/1 instead of replacing `default`,
// so a defaults-only read misses exactly the tunnels users actually run
// and the offline card fires under an active VPN.
function vpnRouteArgv() {
  return ["ip", "route", "show"]
}

// Tunnel-device name stem: tun/tap, WireGuard, the out-of-band clients
// (AmneziaWG, tun2socks-style `tun0`), commercial VPN vendors, Cloudflare
// WARP and NetBird. Prefix-anchored so a physical `wlan0`/`enp42s0` never
// matches, and case-insensitive because interface names vary by driver.
var VPN_TUNNEL_RE = /^(tun|tap|wg|wireguard|amnezia|amn|vpn|ppp|tailscale|zt|nebula|utun|ovpn|proton|mullvad|ivpn|vti|xfrm|ipsec|warp|cloudflare|wt|nb|netbird|zerotier)/i

function isTunnelDev(name) {
  return VPN_TUNNEL_RE.test(String(name === undefined || name === null ? "" : name))
}

// True when any default-carrying route leaves through a tunnel device.
// `default` via a tunnel is the NM-VPN shape; 0.0.0.0/1 + 128.0.0.0/1 via
// anything is the WireGuard/OpenVPN hijack shape (a physical network never
// installs /1s, so those count regardless of device name - covering tunnel
// names this file has never heard of). Split-tunnel specifics (10/8 via
// tun0 with the default still physical) intentionally do NOT count: the
// tunnel is up but the internet still rides the physical link. "" (no
// routes, or an unreadable reply) is false: no tunnel carrying traffic,
// so the verdict falls back to the raw NM reading.
function parseVpnUp(stdout) {
  const text = String(stdout === undefined || stdout === null ? "" : stdout)
  const lines = text.split(/\r?\n/)
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim()
    if (line === "") continue
    const dst = line.split(/\s+/)[0]
    const devMatch = /\bdev\s+([^\s]+)/.exec(line)
    if (dst === "default") {
      if (devMatch !== null && isTunnelDev(devMatch[1])) return true
    } else if (dst === "0.0.0.0/1" || dst === "128.0.0.0/1") {
      return true
    }
  }
  return false
}

// The captive-portal page is whatever the connectivity check itself would
// land on: opening NM's own check URI reproduces the portal redirect,
// because a portal intercepts plain HTTP. Read off `NetworkManager
// --print-config` at click time, so an admin-edited URI is honoured and no
// config parse can go stale between the poll and the click.
function resolveUriArgv() {
  return ["NetworkManager", "--print-config"]
}

// First `uri=` under the `[connectivity]` section, "" when absent. Section
// match is case-insensitive and the value sheds one layer of quotes, because
// neither is load-bearing and both occur in the wild.
function parseConnectivityUri(text) {
  // INI line grammar via the shared HyprlandEditor helpers: option_key
  // names the key, option_value_typed unquotes the value. Section walk
  // stays local (connectivity sections, case-insensitive). Non-string
  // scalars stringify, so any scalar is accepted as a value;
  // a `{` block opener is not a value and is skipped.
  const lines = String(text === undefined || text === null ? "" : text).split(/\r?\n/)
  let inSection = false
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim()
    if (line === "" || line.charAt(0) === "#" || line.charAt(0) === ";") continue
    if (line.charAt(0) === "[") {
      inSection = line.toLowerCase() === "[connectivity]"
      continue
    }
    if (!inSection) continue
    const key = HyprlandEditor.option_key(line)
    if (key === null || String(key).toLowerCase() !== "uri") continue
    const raw = HyprlandEditor.option_value_typed(line)
    const value = (typeof raw === "string" ? raw : String(raw === null || raw === undefined ? "" : raw)).trim()
    if (value !== "") return value
  }
  return ""
}

// Android's portal probe: plain HTTP on port 80, which is exactly what a
// portal intercepts. The fallback when NM names no check URI of its own.
var PORTAL_FALLBACK_URL = "http://connectivitycheck.gstatic.com/generate_204"

function portalUrl(uri) {
  const u = String(uri === undefined || uri === null ? "" : uri).trim()
  return u !== "" ? u : PORTAL_FALLBACK_URL
}

function portalFallbackUrl() {
  return PORTAL_FALLBACK_URL
}

// Synchronous adoption tags, the replacement identity the daemon honours
// (a numeric `-r` never stabilises on Quickshell 0.3.x, which answers an
// unknown replaces_id with a fresh id). One tag per watcher state, so the
// portal and metered cards never adopt each other.
var PORTAL_TAG = "vb-connectivity-portal"
var METERED_TAG = "vb-connectivity-metered"
var OFFLINE_TAG = "vb-connectivity-offline"
var METERED_USAGE_TAG = "vb-connectivity-metered-usage"
var GB_BYTES = 1024 * 1024 * 1024
// The portal card: persistent (`-t 0` never expires in this daemon) with
// one action. `-A` implies `--wait`, so the sender blocks and the clicked
// action name arrives on its stdout - that is the whole click channel.
function portalArgv() {
  return ["notify-send", "-a", "Vibranium", "-u", "critical",
    "-t", "0",
    "-h", "string:x-vb-tag:" + PORTAL_TAG,
    "-A", "login=Open login page",
    "Network login required",
    "This network needs a sign-in before you can get online."]
}

// Portal resolved: the same tag with a short expiry adopts the persistent
// card and lets it fade, so no id bookkeeping is needed to withdraw one.
function portalClearArgv() {
  return ["notify-send", "-a", "Vibranium", "-u", "normal",
    "-t", "4000",
    "-h", "string:x-vb-tag:" + PORTAL_TAG,
    "Back online", "Sign-in complete. You are connected."]
}

// Portal episode ended because the link went away rather than forward.
function portalLostArgv() {
  return ["notify-send", "-a", "Vibranium", "-u", "normal",
    "-t", "4000",
    "-h", "string:x-vb-tag:" + PORTAL_TAG,
    "Connection lost", "The sign-in network disconnected."]
}

function meteredArgv(ssid) {
  const name = escapeMarkup(ssid).trim()
  const body = name !== ""
    ? "Large downloads and updates on <b>" + name + "</b> can use up mobile data."
    : "This network is metered. Large downloads and updates can use up mobile data."
  return ["notify-send", "-a", "Vibranium", "-u", "normal",
    "-t", "0",
    "-n", "wifi-3",
    "-h", "string:x-vb-tag:" + METERED_TAG,
    "-A", "ignore=Don't show again",
    "Metered connection", body]
}

// Mute confirmation: the same tag with a short expiry adopts the card the
// click just retired, so the answer is visible and self-cleaning.
function meteredMutedArgv(ssid) {
  const name = escapeMarkup(ssid).trim()
  const body = name !== ""
    ? "You won't be reminded about <b>" + name + "</b> again."
    : "You won't be reminded again."
  return ["notify-send", "-a", "Vibranium", "-u", "normal",
    "-t", "4000",
    "-n", "wifi-3",
    "-h", "string:x-vb-tag:" + METERED_TAG,
    "Metered reminders off", body]
}

// Suppression key for one network. Prefixed: a bare SSID can be any
// string, including "__proto__", which as an object key would set a
// prototype instead of filing - the prefix keeps every name an own key.
function mutedKey(ssid) {
  return "ssid:" + String(ssid === undefined || ssid === null ? "" : ssid)
}

// Whether the cache section mutes metered cards for this network.
function isMuted(section, ssid) {
  const s = section !== null && typeof section === "object" && !Array.isArray(section)
    ? section : null
  if (s === null) return false
  const muted = s.mutedMetered
  if (muted === null || typeof muted !== "object" || Array.isArray(muted)) return false
  return muted[mutedKey(ssid)] === true
}

// Section copy with this network muted. Pure: the service writes the
// result back through ShellCache.
function withMuted(section, ssid) {
  const s = section !== null && typeof section === "object" && !Array.isArray(section)
    ? section : {}
  const muted = s.mutedMetered !== null && typeof s.mutedMetered === "object" && !Array.isArray(s.mutedMetered)
    ? s.mutedMetered : {}
  const nextMuted = Object.assign({}, muted)
  nextMuted[mutedKey(ssid)] = true
  const next = Object.assign({}, s)
  next.mutedMetered = nextMuted
  return next
}

function meteredClearArgv() {
  return ["notify-send", "-a", "Vibranium", "-u", "normal",
    "-t", "4000",
    "-n", "wifi-3",
    "-h", "string:x-vb-tag:" + METERED_TAG,
    "No longer metered", "The current connection is not metered."]
}

// Generic offline card: persistent like the portal and metered ones, so
// a dead link stays visible until it recovers. Same tag so a repeated
// edge replaces rather than stacks, the wifi-off glyph, and no button -
// there is nothing to click through to.
function offlineArgv(ssid) {
  const name = escapeMarkup(ssid).trim()
  const body = name !== ""
    ? "<b>" + name + "</b> is connected but has no internet access."
    : "The current connection has no internet access."
  return ["notify-send", "-a", "Vibranium", "-u", "normal",
    "-t", "0",
    "-n", "wifi-off",
    "-h", "string:x-vb-icon-color:red",
    "-h", "string:x-vb-tag:" + OFFLINE_TAG,
    "-p",
    "No internet connection", body]
}

// Offline resolved: the same tag with a short expiry adopts the card and
// lets it fade.
// Silent withdrawal: the daemon closes by server id, which a `--print-id`
// send reports on its stdout. Fire-and-forget: an unknown or recycled id
// is a failed call and nothing else, so a withdrawal that misses leaves
// the card for manual dismissal rather than trading it for a toast.
function closeArgv(id) {
  return ["busctl", "--user", "call",
    "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
    "org.freedesktop.Notifications", "CloseNotification",
    "u", String(id)]
}

// First stdout line of a `--print-id` send, 0 when it is not a bare id.
// A send that failed carries no card, so 0 doubles as "nothing to close".
function parseNotifId(stdout) {
  const line = String(stdout === undefined || stdout === null ? "" : stdout).split("\n")[0].trim()
  if (!/^[0-9]+$/.test(line)) return 0
  const n = Number(line)
  return isFinite(n) && n > 0 ? n : 0
}

function openUrlArgv(url) {
  return ["xdg-open", String(url)]
}

// Join confirmation: expiring, wifi glyph, named network. Same tag so a
// rapid rejoins replace rather than stack. No episode: the SSID memory
// in the step above is the whole state.
var ONLINE_TAG = "vb-connectivity-online"

function connectArgv(ssid) {
  const name = escapeMarkup(ssid).trim()
  const body = name !== ""
    ? "Connected to <b>" + name + "</b>."
    : "Connected."
  return ["notify-send", "-a", "Vibranium", "-u", "normal",
    "-t", "4000",
    "-n", "wifi-3",
    "-h", "string:x-vb-tag:" + ONLINE_TAG,
    "Connected", body]
}

// Default-route interface: the first `default` line's `dev`, ignoring
// /1 hijack lines that are not defaults.
function usageKey(ssid) {
  return "ssid:" + String(ssid === undefined || ssid === null ? "" : ssid)
}

if (typeof module !== "undefined") {
  module.exports = {
    isPortal: isPortal,
    isOnline: isOnline,
    hasInternet: hasInternet,
    isMetered: isMetered,
    linkLostEdge: linkLostEdge,
    connectStep: connectStep,
    portalStep: portalStep,
    meteredStep: meteredStep,
    offlineStep: offlineStep,
    linkNote: linkNote,
    parseUintProp: parseUintProp,
    parseStringProp: parseStringProp,
    parseObjectPath: parseObjectPath,
    escapeMarkup: escapeMarkup,
    mutedKey: mutedKey,
    isMuted: isMuted,
    withMuted: withMuted,
    propArgv: propArgv,
    vpnRouteArgv: vpnRouteArgv,
    parseVpnUp: parseVpnUp,
    isTunnelDev: isTunnelDev,
    VPN_TUNNEL_RE: VPN_TUNNEL_RE,
    resolveUriArgv: resolveUriArgv,
    parseConnectivityUri: parseConnectivityUri,
    portalUrl: portalUrl,
    portalFallbackUrl: portalFallbackUrl,
    portalArgv: portalArgv,
    portalClearArgv: portalClearArgv,
    portalLostArgv: portalLostArgv,
    meteredArgv: meteredArgv,
    meteredClearArgv: meteredClearArgv,
    meteredMutedArgv: meteredMutedArgv,
    offlineArgv: offlineArgv,
    closeArgv: closeArgv,
    parseNotifId: parseNotifId,
    OFFLINE_GRACE_MS: OFFLINE_GRACE_MS,
    connectArgv: connectArgv,
    openUrlArgv: openUrlArgv,
    ONLINE_TAG: ONLINE_TAG,
    PORTAL_TAG: PORTAL_TAG,
    METERED_TAG: METERED_TAG,
    OFFLINE_TAG: OFFLINE_TAG,
    GB_BYTES: GB_BYTES,
    METERED_USAGE_TAG: METERED_USAGE_TAG,
    usageKey: usageKey,
  }
}
