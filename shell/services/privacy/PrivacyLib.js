// Pure privacy derivations: the process boundary (argv, pw-dump result
// parsing, the gate digest) and the model projections the tooltip, the
// island and the notification text are rendered from.
//
// No Qt imports, no QML state, no command, no graph handle. Every function
// takes what it needs and returns a value, and Privacy.qml keeps the call,
// so the process object, the RequestGate generation, the watchdog and the
// PipeWire subscriptions all stay in the controller.
//
// The library owns four vocabularies, in this order:
//
//   1. The process boundary. A PipeWire cut is three commands: snapshot the
//      live link endpoints with one pw-dump, cut with pw-link -d, restore
//      with pw-cli create-link. Only the argv construction and the dump
//      parsing are here; CommandSpec validates the argv and ProcessRegistry
//      owns the child, both in the controller. The endpoint quads are
//      resolved from pw-dump by node and port id because names cannot be the
//      restore handle: pw-link resolves "node:port" by first match and
//      streams routinely share one node.name (OBS names every stream "obs"),
//      so a name spec can re-link the wrong twin node entirely.
//
//   4. The shell loopback ("Hear my voice"). A source -> sink device route
//      leaves no stream node behind, so the dot would light with an empty
//      ledger. The topology predicates and the synthetic ledger row live
//      here so the rule is unit-tested; the controller only adapts its
//      PwLink objects into id pairs and resolves the row icon.
//
//   2. The redaction policy. gateDigest() is fixed-width on purpose:
//      RequestGate refuses a label longer than its 128-character limit and
//      answers a refused begin() with 0, so a key built from the slot would
//      let any client that sets an over-long PipeWire application name refuse
//      the user's own cut, every time, silently. The gate also stores the
//      digest, never the app name. refusalText() is a closed table: a toast
//      carries a reason, never a node id, a link quad or pw-dump text.
//      shortApp() is the same boundary on the one client-controlled string
//      that does reach a notification.
//
//   3. The projections. The per-app ledger, the island model and the tooltip
//      markup are derivations of already-classified rows, so they live here
//      rather than in the controller's property bodies. The only injected
//      dependency is colorOf(), the theme lookup the controller owns: a
//      library that resolved a colour itself would be a QML type in a .js
//      file.
.pragma library

.import "../../common/text/StringUtils.js" as SU

// --- process boundary -------------------------------------------------------

// One pw-dump answers the daemon in milliseconds; the timeout that bounds a
// wedged graph belongs to the caller, which owns the child.
function dumpArgv() {
  return ["pw-dump"]
}

// A link id is a graph number, so it travels as its own argv element and no
// shell source is built from it.
function unlinkArgv(linkId) {
  return ["pw-link", "-d", String(linkId)]
}

// Exact endpoint quads back, in the order create-link documents. linger keeps
// the restored link alive past this command's own exit, so a link that did
// land is not torn down with the shell that made it.
function relinkArgv(quad) {
  return ["pw-cli", "create-link", String(quad[0]), String(quad[1]),
    String(quad[2]), String(quad[3]), '{ "object.linger": true }']
}

// Link ids for one cut, numbers only and deduplicated: pw-dump reports a
// link once, but the caller collects ids from per-node lookups, and a
// non-numeric or repeated id would spawn a child that cannot succeed.
function cleanLinkIds(ids) {
  const clean = []
  for (let i = 0; i < ids.length; i++) {
    const n = Number(ids[i])
    if (!isNaN(n) && clean.indexOf(n) < 0) clean.push(n)
  }
  return clean
}

// pw-dump text -> [outNodeId, outPortId, inNodeId, inPortId] quads for the
// wanted link ids. The dump is graph state, not a secret: it is read here for
// this pair's endpoints and dropped, and nothing derived from the text other
// than these four numbers is kept. Anything unparseable, non-array, not a
// Link, not wanted, or missing an endpoint resolves to no quad, which the
// restore reports as having nothing to relink rather than guessing.
function linkQuads(text, linkIds) {
  let dump
  try {
    dump = JSON.parse(text)
  } catch (e) {
    return []
  }
  if (!Array.isArray(dump)) return []
  const want = {}
  for (let i = 0; i < linkIds.length; i++) want[Number(linkIds[i])] = true
  const links = []
  for (let i = 0; i < dump.length; i++) {
    const o = dump[i] || {}
    if (o.type !== "PipeWire:Interface:Link" || want[Number(o.id)] !== true) continue
    const info = o.info || {}
    const on = Number(info["output-node-id"])
    const op = Number(info["output-port-id"])
    const inn = Number(info["input-node-id"])
    const ip = Number(info["input-port-id"])
    if (isNaN(on) || isNaN(op) || isNaN(inn) || isNaN(ip)) continue
    links.push([on, op, inn, ip])
  }
  return links
}

// Fixed-width hex: the gate stores the digest, never the app name, so its key
// length does not depend on the value it was derived from.
function _hex(value) {
  const s = (value >>> 0).toString(16)
  return "00000000".substring(s.length) + s
}

// Gate key of one pair, as the 16-character digest the caller prefixes. Two
// 32-bit digests with different seeds and multipliers are concatenated, so
// the key does not hinge on one word of a chosen name. The width is
// independent of the input: an app name of any length derives the same 16
// characters, so no client name can push the key past the gate's own limit.
function gateDigest(slot) {
  const s = String(slot)
  let a = 2166136261
  let b = 1013904223
  for (let i = 0; i < s.length; i++) {
    const code = s.charCodeAt(i)
    a = Math.imul(a ^ code, 16777619) >>> 0
    b = Math.imul(b ^ (code + i), 2654435761) >>> 0
  }
  return _hex(a) + _hex(b)
}

// --- redaction policy -------------------------------------------------------

// Slot of one (app,key) pair. The severed map and the run table key on this
// string, so a pipeline and its mark always name one pair; the gate reads
// only a digest of it. The newline separator is what keeps a client-chosen
// app name that carries one from naming a second pair.
function slotKey(app, key) {
  return app + "\n" + key
}

// Effective cut state: remembered AND currently unlinkless. A remembered mark
// whose links have reappeared is inert, so external renegotiation heals the
// display without any bookkeeping writes.
function isSevered(severed, slot, liveLinkIds) {
  if (severed[slot] === undefined) return false
  return (liveLinkIds || []).length === 0
}

// The reason a privacy operation did not land, as the user reads it. A closed
// table plus the code the caller already holds: a refusal is a code, never a
// node id, a link quad, a path or any other graph state.
function refusalText(code) {
  if (code === "gate_refused") return "refused before anything ran"
  if (code === "snapshot_refused") return "link snapshot failed"
  if (code === "nothing_to_restore") return "nothing to restore"
  return String(code)
}

// An app name is client data and can be arbitrarily long, so the one copy
// that reaches a toast is cut to a readable length here; the ledger, the
// island and the cut keep the whole string.
function shortApp(app, limit) {
  const s = String(app ?? "")
  return s.length > limit ? s.substring(0, limit) + "..." : s
}

// --- projection vocabulary --------------------------------------------------

// Target metadata shared by dots, tooltip and island: the dot color and the
// island glyph per target kind. The icon is a shell asset name, not a path.
function targetMeta(kind) {
  if (kind === "mic") return { key: "mic", icon: "mic-on", colorKey: "green", label: "Microphone" }
  if (kind === "cam") return { key: "cam", icon: "camera", colorKey: "purple", label: "Camera" }
  return { key: "share", icon: "screen-capture", colorKey: "orange", label: "Screen share" }
}

// The island runs app names through markup, so every name that reaches it
// is escaped first. Only the three markup characters matter in rich text;
// a node name is the untrusted input here. (The tooltip needs no escaping:
// it renders PlainText rows.)
function _escape(s) {
  return SU.escapeHtml(s)
}

// Title line: just the app name. Target identity lives in the bar dots and
// the row's icon stack; a media-kind badge here only repeats them.
function _line1(app) {
  return "<b>" + _escape(app) + "</b>"
}

// Subtext: the window titles behind each target, deduplicated in first-seen
// order so two nodes of one app contribute one title.
function _line2(targets) {
  const subs = []
  for (let t = 0; t < targets.length; t++) {
    const s = String(targets[t].titleText ?? "").trim()
    if (s !== "" && subs.indexOf(s) < 0) subs.push(s)
  }
  return subs.join(" • ")
}

// Per-app usage ledger: app -> {app, icon, targets, line1, line2}.
// One entry per app no matter how many of its nodes are active; pipewire
// streams and v4l2 device holds merge into the same entry. The rows arrive
// already classified and already resolved to app names, icons and live link
// ids, in the order the streams are visited (share, cam, mic).
//
// The app index is a null-prototype map: an app name is client data, and
// "constructor" or "__proto__" as a PipeWire application name must read as a
// missing key rather than resolve to an inherited object and throw.
// `linkIds` carries the live link ids; `severed` is the effective cut state
// (remembered + currently unlinkless). `actionable` gates the island button
// and must stay true while severed - a cut target has no live links left by
// definition, and killing the button would strand it with no way back. Mic is
// always actionable (its taps may lag the graph); connected stream targets
// need live links.
function ledger(rows, severed) {
  const byApp = Object.create(null)
  const order = []
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i]
    if (!row) continue
    const app = row.app
    if (!app) continue
    if (!byApp[app]) {
      byApp[app] = { app: app, icon: "", targets: [] }
      order.push(app)
    }
    const e = byApp[app]
    const meta = targetMeta(row.kind)
    let claimed = false
    for (let t = 0; t < e.targets.length; t++) {
      if (e.targets[t].key === meta.key) { claimed = true; break }
    }
    if (claimed) continue
    const live = Array.isArray(row.linkIds) ? row.linkIds : []
    const sev = isSevered(severed, slotKey(app, meta.key), live)
    const act = meta.key === "mic" ? true : (live.length > 0 || sev)
    e.targets.push({
      key: meta.key,
      icon: meta.icon,
      colorKey: meta.colorKey,
      label: meta.label,
      classText: row.classText,
      titleText: row.titleText,
      actionable: act,
      linkIds: live,
      severed: sev
    })
    if (e.icon === "" && row.icon) e.icon = row.icon
  }
  // Targets stack mic -> cam -> share inside each entry; the island lines
  // render from the filtered targets instead.
  const rank = { mic: 0, cam: 1, share: 2 }
  for (let i = 0; i < order.length; i++)
    byApp[order[i]].targets.sort((x, y) => rank[x.key] - rank[y.key])
  return order.map(a => byApp[a])
}

// Island model: only entries with a lit target (a share-only session keeps no
// stale mic rows and vice versa), lines rendered from exactly the shown
// targets.
function islandRows(entries, lit) {
  const out = []
  for (let i = 0; i < entries.length; i++) {
    const e = entries[i]
    const targets = e.targets.filter(t => lit[t.key])
    if (targets.length > 0) {
      out.push({
        app: e.app,
        icon: e.icon,
        targets: targets,
        line1: _line1(e.app),
        line2: _line2(targets)
      })
    }
  }
  return out
}

// Tooltip rows for the bar bubble: one icon-led row per app per lit
// target, in mic/cam/share section order and ledger order within. Rendered
// through the host's shared lines path like every compact tooltip, so the
// bubble insets match by construction. The app name and the verb travel
// as two columns: every verb starts on the widest name, so the verbs align
// in one column. Only the name wears the target color (resolved hex
// through the caller's lookup); the verb stays foreground. Names are
// escaped - the name column is rich text, so an unescaped name would be
// markup. No section dividers: each row names its own verb.
function tooltipRows(entries, lit, severed, colorOf) {
  const verbs = {
    mic: "is using microphone",
    cam: "is using camera",
    share: "is sharing screen",
  }
  const rows = { mic: [], cam: [], share: [] }
  const list = Array.isArray(entries) ? entries : []
  for (let i = 0; i < list.length; i++) {
    const e = list[i]
    if (!e || !Array.isArray(e.targets)) continue
    for (let t = 0; t < e.targets.length; t++) {
      const tg = e.targets[t]
      if (!tg || verbs[tg.key] === undefined || !lit[tg.key]) continue
      // Severed targets read "(paused)": remembered cut, no live links.
      const paused = isSevered(severed, slotKey(e.app, tg.key), tg.linkIds)
        ? " (paused)" : ""
      rows[tg.key].push({
        icon: tg.icon,
        name: "<b><font color=\"" + String(colorOf(tg.colorKey || "accent")) + "\">"
          + _escape(e.app) + "</font></b>",
        markup: true,
        verb: verbs[tg.key] + paused,
      })
    }
  }
  // A live portal session with no classified stream still names itself.
  if (lit.share && rows.share.length === 0)
    rows.share.push({ icon: "screen-capture", text: "Screen sharing" })
  return rows.mic.concat(rows.cam, rows.share)
}

// --- shell loopback ("Hear my voice") ----------------------------------------
//
// The Audio service routes the default source straight into the default
// sink while shell.audio.loopback is on. The mic is live, but the route is
// device-to-device: no stream node exists for the ledger to attribute, so
// the indicator would light with empty island/tooltip projections. These
// helpers name that shape and carry the synthetic row, and the controller
// only adapts PwLink objects into {s, t} id pairs and resolves the icon.
// The row is deliberately NOT actionable: there is no stream to cut, and
// cutting device links would fight the Audio service that owns them, so
// the island renders a plain glyph for it.
function loopbackAppName() {
  return "Hear my voice"
}

function loopbackRow(icon) {
  return {
    app: loopbackAppName(),
    icon: icon || "",
    targets: [{
      key: "mic",
      icon: "mic-on",
      colorKey: "green",
      label: "Microphone",
      classText: "Audio loopback",
      titleText: "Input device to output device",
      actionable: false,
      linkIds: [],
      severed: false
    }]
  }
}

function hasMicTarget(entries) {
  const list = Array.isArray(entries) ? entries : []
  for (let i = 0; i < list.length; i++) {
    const e = list[i]
    if (!e || !Array.isArray(e.targets)) continue
    for (let j = 0; j < e.targets.length; j++) {
      if (e.targets[j] && e.targets[j].key === "mic") return true
    }
  }
  return false
}

function _loopId(v) {
  if (v === null || v === undefined) return ""
  if (typeof v === "number") {
    if (!isFinite(v) || v < 0) return ""
    return String(Math.round(v))
  }
  const s = String(v).trim()
  return /^\d+$/.test(s) ? s.replace(/^0+(?=\d)/, "") || "0" : ""
}

function _loopPair(p) {
  if (!p) return null
  const s = _loopId(p.s !== undefined ? p.s : (p.source !== undefined ? p.source : p[0]))
  const t = _loopId(p.t !== undefined ? p.t : (p.target !== undefined ? p.target : p[1]))
  if (s === "" && t === "") return null
  return { s: s, t: t }
}

// Every raw link touching the source has the sink on the other end, with at
// least one such link. Any other peer - an app capture stream - answers
// false, so a real capture alongside the loopback is never mistaken for it.
// Accepts {s, t}, {source, target} or [s, t] pairs; ids may be numbers or
// numeric strings to tolerate both QML and test callers.
function isLoopbackOnly(pairs, sourceId, sinkId) {
  const src = _loopId(sourceId)
  const snk = _loopId(sinkId)
  if (src === "" || snk === "" || src === snk) return false
  if (!Array.isArray(pairs)) return false
  let found = false
  for (let i = 0; i < pairs.length; i++) {
    const pr = _loopPair(pairs[i])
    if (pr === null) continue
    if (pr.s !== src && pr.t !== src) continue
    found = true
    const peer = pr.s === src ? pr.t : pr.s
    if (peer !== snk) return false
  }
  return found
}

// Same peer test without the liveness requirement: true when no touching
// link contradicts the loopback shape (vacuously true with none). Used as
// the fallback while the link-group tracker already reports busy but the
// raw list has not synced yet.
function allSourcePeersSink(pairs, sourceId, sinkId) {
  const src = _loopId(sourceId)
  const snk = _loopId(sinkId)
  if (src === "" || snk === "" || src === snk) return false
  if (!Array.isArray(pairs)) return false
  for (let i = 0; i < pairs.length; i++) {
    const pr = _loopPair(pairs[i])
    if (pr === null) continue
    if (pr.s !== src && pr.t !== src) continue
    const peer = pr.s === src ? pr.t : pr.s
    if (peer !== snk) return false
  }
  return true
}

// Whether the ledger needs the synthetic loopback row: the setting is on,
// the mic reads busy, no stream row claims it, and the topology matches
// the loopback shape. The tracker/stream counts ride along for the sync
// race where the count moved before the raw list did.
function needsLoopbackRow(args) {
  if (!args || args.loopbackOn !== true || args.micOn !== true) return false
  if (hasMicTarget(args.entries)) return false
  if (isLoopbackOnly(args.pairs, args.sourceId, args.sinkId)) return true
  if (Number(args.captureCount) > 0) return false
  if (Number(args.sourceLinkCount) <= 0) return false
  return allSourcePeersSink(args.pairs, args.sourceId, args.sinkId)
}

// Base ledger plus the synthetic row, unless a mic row (or the row itself)
// is already present. Never duplicates, never steals a real app's claim.
function ensureLoopbackRow(entries, icon) {
  const base = Array.isArray(entries) ? entries.slice() : []
  if (hasMicTarget(base)) return base
  for (let i = 0; i < base.length; i++) {
    if (base[i] && base[i].app === loopbackAppName()) return base
  }
  base.push(loopbackRow(icon))
  return base
}
