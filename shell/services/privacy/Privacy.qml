pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.common
import qs.services as Core
import "../../common/process/CommandSpec.js" as CommandSpec
import "../../common/text/UnitIpc.js" as UnitIpc
import "PrivacyLib.js" as PrivacyLib

// Privacy service - single source of truth for capture indicators (mic,
// camera, screenshare). Owns the per-app usage ledger, the severed-link
// access toggles, the refusal toasts and the tooltip/island view models; the
// bar module and the lockscreen dots are thin views over this state, so
// neither duplicates PipeWire code.
//
// Where the PipeWire state comes from: the shell's one state owner,
// audio/PipeWireState, holds the trackers behind the default devices, the
// capture-stream list, the node set, the link list and the default source's
// link groups. The node set and the link groups are views of one global
// graph, and the node-set tracker and the default-source link tracker are
// owned by the neutral shared mechanism that owner builds on, so a tracker
// of this service's own would be a subscription on state somebody else
// already holds. What this service keeps is the part that is not the
// tracker's: which node is a capture, which stream belongs to which app, and
// when a link may be cut and restored. The raw sets and the link-group count
// arrive from the owner; every filter below is the same, so the same nodes
// get the same classification and the same verdicts.
//
// Detection notes (verified against the live graph): PwNode.type is an
// enum bitmask (use PwNodeType flags, never string matching), and video
// nodes are never flagged isStream. Deliberately PipeWire-only: apps
// opening /dev/video* directly never enter the graph and stay dark.
//
// What the library holds and what this file holds: PrivacyLib owns the pure
// halves - the argv of all three PipeWire commands, the pw-dump result
// parsing, the gate key digest, the severed/dump redaction policy and the
// ledger/island/tooltip projections - and this file keeps the call plus
// everything with a lifetime: the RequestGate generation per (app,key) pair,
// the ProcessRegistry jobs and their timeouts, the watchdog, the severed map
// itself, the classification predicates (QML functions of this file; no suite
// under tests/shell/suites/ drives them) and the IPC surface.
//
// The redaction bound for every surface in this file, and the strictest
// part of it: no pw-dump body, no node id, no link quad, no port, and no
// raw application.name reaches any of them - the app name that does appear
// is `_shortApp(app)`, the same 48-character bound the toast gets, because
// an app name is client data. The rule is stated in one line: never print
// PipeWire client data, and it applies to all of them with the force it
// applies to the IPC reply.
Singleton {
  id: root

  readonly property string tag: "privacy"

  // Raw graph state from the shell's one PipeWire state owner: the node set
  // whole (this service applies its own capture/video filters to it), the raw
  // link list, and the default source. `links` needs no tracker of its own -
  // PwLink.source, .target and .id are documented as available on an unbound
  // object, and only PwLink.state is not (nothing here reads it).
  // qmllint disable unresolved-type missing-property
  // (the singleton line for PipeWireState in shell/services/qmldir is spec
  // 09's registration; until it is in, qmllint cannot resolve the type. The
  // disable covers those two rules for these three lines only.)
  readonly property var nodes: Core.PipeWireState.nodes
  readonly property var links: Core.PipeWireState.links
  readonly property var source: Core.PipeWireState.source
  // qmllint enable unresolved-type missing-property

  // Audio capture streams, mirrored from the microphone module's Model
  // (isCaptureStream): any app holding the mic shows the green dot.
  readonly property var captureStreams: {
    var list = []
    for (var i = 0; i < root.nodes.length; i++) {
      var n = root.nodes[i]
      if (!n || !n.isStream) continue
      if (n.isSink) continue
      if (String(n.name || "").indexOf("omarchy_speaker_tuning") === 0) continue
      if (!n.audio) continue
      if (!root._isCaptureStream(n)) continue
      list.push(n)
    }
    return list
  }

  // Attribution twin of captureStreams for "<app> is using microphone":
  // also counts sink-side input streams (an app's Mic/Aux tap receives
  // from the source instead of sourcing), which detection must ignore.
  readonly property var micAttrStreams: {
    var list = []
    for (var i = 0; i < root.nodes.length; i++) {
      var n = root.nodes[i]
      if (!n || !n.isStream) continue
      if (!n.audio) continue
      if (!root._isCaptureStream(n)) continue
      list.push(n)
    }
    return list
  }

  // Any link touching a node id (direction-agnostic).
  readonly property var linkedIds: {
    var ids = {}
    for (var l = 0; l < root.links.length; l++) {
      var lk = root.links[l]
      if (!lk) continue
      if (lk.source) ids[lk.source.id] = true
      if (lk.target) ids[lk.target.id] = true
    }
    return ids
  }

  function _isVideo(n) {
    if (!n) return false
    if ((Number(n.type || 0) & PwNodeType.Video) !== 0) return true
    var pr = root._nodeProps(n)
    if (String(pr["media.class"] || "").indexOf("Video") !== -1) return true
    var role = String(pr["media.role"] || "").toLowerCase()
    return role === "screen" || role === "camera"
  }

  // Video nodes that are not audio legs: streams, camera devices and
  // portal sources alike (QS never flags video as isStream, so that
  // predicate must not be used here).
  readonly property var videoNodes: {
    var list = []
    for (var j = 0; j < root.nodes.length; j++) {
      var m = root.nodes[j]
      if (!m || m.audio) continue
      if (!root._isVideo(m)) continue
      list.push(m)
    }
    return list
  }

  // Portal screencast sources: Video nodes owned by the desktop portal
  // (xdg-desktop-portal-*, xdpw, screencopy). These exist only for the
  // lifetime of a capture session (xdph-streaming-*); camera devices never
  // match. Tested with PwNodeType flags (QS reports e.g. VideoSource=10,
  // never a media.class string).
  function _isShareSource(n) {
    if (!n || !root._isVideo(n)) return false
    var nm = String(n.name || "").toLowerCase()
    if (nm.indexOf("xdg-desktop-portal") !== -1
      || nm.indexOf("xdpw") !== -1
      || nm.indexOf("screencopy") !== -1
      || nm.indexOf("screencast") !== -1) return true
    var media = String(root._nodeProps(n)["media.name"] || "").toLowerCase()
    return media.indexOf("xdph-streaming") !== -1
      || media.indexOf("screencast") !== -1
  }

  readonly property var shareSources: {
    var list = []
    for (var i = 0; i < root.videoNodes.length; i++) {
      if (root._isShareSource(root.videoNodes[i])) list.push(root.videoNodes[i])
    }
    return list
  }

  // Ids of share sources that currently feed something (touched by ≥1
  // link). A session nobody consumes is not a sharing indicator.
  readonly property var liveShareSourceIds: {
    var ids = {}
    for (var l = 0; l < root.links.length; l++) {
      var lk = root.links[l]
      if (!lk) continue
      var s = lk.source
      var t = lk.target
      for (var k = 0; k < root.shareSources.length; k++) {
        var src = root.shareSources[k]
        if (!src) continue
        if ((s && s.id === src.id) || (t && t.id === src.id)) ids[src.id] = true
      }
    }
    return ids
  }

  readonly property bool shareSourceLive: Object.keys(root.liveShareSourceIds).length > 0

  // --- screen shares ------------------------------------------------
  //
  // A screen share is not one event. Three distinct facts, and collapsing them
  // is how "my share indicator is on but nothing is being shared" happens:
  //
  //   shareSources        a portal screencast SOURCE exists. The portal creates
  //                       one when the user picks what to share, and it can sit
  //                       there unconsumed.
  //   shareSourceLive     one of those sources is actually FEEDING something,
  //                       which is a link fact, not a node fact. A session
  //                       nobody consumes is not a sharing indicator - the
  //                       existing comment above `liveShareSourceIds` says so.
  //   the app             who is sharing. That is `application.name` on the
  //                       node, which the redaction contract forbids raw and
  //                       permits only through `_shortApp`.
  //
  // A source that appears and never goes live is a real state a user can be
  // in, so the two booleans are kept apart rather than collapsed.
  //
  // This is the whole of "reacts to a new screenshare". There is no xdg-portal
  // API to read: Quickshell 0.3.1 ships no ScreenCast service, and PwNode
  // exposes `audio` but no video member at all, so a share is only ever
  // observable as the video nodes above. Anything richer would mean shelling out
  // to the portal, which this file deliberately does not do.
  property int _shareSourcesSeen: -1
  property int _shareLiveSeen: -1

  onShareSourcesChanged: {
    const n = root.shareSources.length
    // -1 is "never seen", so the first observation is a start rather than a
    // no-op: the sources are already there when this file constructs, because
    // the service syncs before any consumer exists.
    if (root._shareSourcesSeen !== -1 && n === root._shareSourcesSeen) return
    root._shareSourcesSeen = n
  }

  onShareSourceLiveChanged: {
    const live = root.shareSourceLive
    if (root._shareLiveSeen !== -1 && live === root._shareLiveSeen) return
    root._shareLiveSeen = live
  }

  // A capture client arriving or leaving. This is the OBS case, and it is a
  // different shape from a device appearing: a device is a node the graph owns,
  // while a capture client is an ordinary stream that happens to be consuming a
  // source.
  //
  // The list is deduplicated BY APP rather than by node, because "OBS opened
  // three streams" is one event.
  property string _captureAppsSeen: ""

  onCaptureStreamsChanged: root._reportMicApps()

  // The set last reported, joined into one key so a re-evaluation that changed
  // nothing is one equality test rather than a diff.
  function _reportMicApps() {
    const key = root._captureApps().join(",")
    if (key === root._captureAppsSeen) return
    root._captureAppsSeen = key
  }

  // Distinct bounded app names among the capture streams. Attribution is
  // application.name alone; a stream that names nothing is skipped.
  function _captureApps() {
    var seen = {}
    var out = []
    for (var i = 0; i < root.captureStreams.length; i++) {
      const props = root._nodeProps(root.captureStreams[i])
      const name = root._shortApp(String(props["application.name"] || ""))
      if (name === "" || seen[name] === true) continue
      seen[name] = true
      out.push(name)
    }
    out.sort()
    return out
  }

  // Screenshare subset of the video nodes (see _isShareStream): portal
  // sources themselves are covered by shareSourceLive and excluded here.
  readonly property var shareStreams: {
    var list = []
    for (var k = 0; k < root.videoNodes.length; k++) {
      var n = root.videoNodes[k]
      if (root._isShareSource(n)) continue
      if (root._isShareStream(n)) list.push(n)
    }
    return list
  }

  // Camera: role-tagged streams, linked camera devices (a device with
  // links is streaming; dormant ones stay dark) and linked video nodes
  // that sharing did not claim.
  readonly property var camStreams: {
    var list = []
    for (var l = 0; l < root.videoNodes.length; l++) {
      var m = root.videoNodes[l]
      if (root._isShareSource(m)) continue
      if (root._isShareStream(m)) continue
      var role = String(root._nodeProps(m)["media.role"] || "").toLowerCase()
      if (role === "camera") {
        list.push(m)
        continue
      }
      if (root.linkedIds[m.id]) list.push(m)
    }
    return list
  }

  // Mic-in-use mirrors the microphone module: any capture link on the
  // default source, or any active capture stream at all. Camera is
  // PipeWire-only by design: apps opening /dev/video* directly (Discord
  // + OBS virtual camera) never enter the graph, and polling for them
  // costs more than the dot is worth - they stay dark, honestly.
  //
  // The capture-link half is the owner's non-monitor link-group count for the
  // default source, read from the one shared link tracker the bar's volume
  // module also reads. Those are documented as deduplicated non-monitor
  // topology, so "is anything consuming the mic" is a topology question and
  // the answer is the number of link groups on that node.
  // qmllint disable unresolved-type missing-property
  readonly property bool micOn: Core.PipeWireState.sourceLinkCount > 0
    || root.captureStreams.length > 0
  // qmllint enable unresolved-type missing-property
  readonly property bool camOn: root.camStreams.length > 0
  readonly property bool shareOn: root.shareSourceLive || root.shareStreams.length > 0
  readonly property bool active: root.micOn || root.camOn || root.shareOn

  // --- capture transitions, reported once each ---
  //
  // The three booleans above say THAT something is using a target; neither
  // they nor the streams behind them say WHO, so the name is read out of the
  // stream lists at the moment the boolean moves. A plain
  // `Connections` on the booleans would report "started using mic" with no app
  // in it, which is the half of the sentence a reader needs.
  //
  // The name goes through `_shortApp()`, the same 48-character bound the toast
  // takes: it is client-controlled text off a PipeWire node, and this service's
  // own rule is that no surface shows one whole. No node id, no link quad and
  // no `pw-dump` text is reachable from here either - none of it is kept.
  property var _streamApps: ({})

  function _appsUsing(list) {
    const out = ({})
    for (let i = 0; i < list.length; i++) {
      const n = list[i]
      if (!n) continue
      const key = root._shortApp(String(n.name || ""))
      if (key === "" || key === "unknown") continue
      out[key] = true
    }
    return out
  }

  function _reportTransition(kind, label, before, after, pool) {
    if (root._streamApps === undefined) return
    const names = Object.keys(after)
    for (let i = 0; i < names.length; i++) {
      if (before[names[i]] === true) continue
      Log.info(names[i] + " started using " + label)
      root._traceTransition(kind, label, names[i], "started", pool, before, after)
    }
    const gone = Object.keys(before)
    for (let i = 0; i < gone.length; i++) {
      if (after[gone[i]] === true) continue
      Log.info(gone[i] + " stopped using " + label)
      root._traceTransition(kind, label, gone[i], "stopped", pool, before, after)
    }
  }

  // The half of the transition the INFO line cannot carry, and the part a reader
  // needs before trusting it.
  //
  // The target KEY rather than its label: `cam` reads `camera` above, and the
  // key is the name the boolean, the severed map and every island row are keyed
  // by, so a reader chasing one of those wants the key and not the word.
  //
  // Then the target's stream count, and how many of those streams the one name
  // stands for. The app set is a set of NAMES, so two nodes publishing one
  // `application.name` are one line forever, and the node ids that would
  // separate them are exactly what this file's redaction forbids. A reader who
  // took the name count for a client count is wrong by precisely this number,
  // which is why it is stated rather than left to be inferred from a stream count
  // nobody can see: `discord started using mic` and three Discord streams are
  // the same sentence here, deliberately.
  //
  // The counts are the whole diff rather than this name alone, because one
  // boolean can move several names in a single evaluation and a per-line count
  // would double-report the same transition. Both maps arrive whole rather than
  // pre-sized, because the gate below is what decides whether either is read at
  // all, and a length measured out here would be built for every transition on a
  // log level that will never show it.
  function _traceTransition(kind, label, name, verb, pool, before, after) {
    const d = Log.at()
    if (!d.allows("debug")) return
    let behind = 0
    for (let i = 0; i < pool.length; i++) {
      const n = pool[i]
      if (!n) continue
      if (root._shortApp(String(n.name || "")) === name) behind++
    }
    d.debug(name + " " + verb + " using " + label + " [" + kind + "]: "
      + behind + " of " + pool.length + " streams, names "
      + Object.keys(before).length + " -> " + Object.keys(after).length
      + ", collapsed " + (behind > 1))
  }

  function _syncStreams() {
    const before = root._streamApps
    const mic = root._appsUsing(root.captureStreams)
    const cam = root._appsUsing(root.camStreams)
    root._reportTransition("mic", "mic", before.mic || ({}), mic, root.captureStreams)
    root._reportTransition("cam", "camera", before.cam || ({}), cam, root.camStreams)
    root._streamApps = { mic: mic, cam: cam }
  }

  Connections {
    target: root
    ignoreUnknownSignals: true
    function onMicOnChanged() { root._syncStreams() }
    function onCamOnChanged() { root._syncStreams() }
  }

  // Severed access map: "app\ntarget" -> {links: [[outNode, outPort,
  // inNode, inPort]]}. Set on cut, kept while the target stays unlinked,
  // auto-inert once links reappear (external renegotiation heals the
  // display without any bookkeeping writes).
  property var severed: ({})

  // Effective cut state for display: remembered AND currently unlinkless.
  // The rule is the library's, this is the service's state it reads.
  function _isSevered(app, key, liveLinkIds) {
    return PrivacyLib.isSevered(root.severed, root._slot(app, key), liveLinkIds)
  }

  // Link ids touching a node, for the cut step.
  function _linkIdsForNode(node) {
    const out = []
    if (!node) return out
    for (let l = 0; l < root.links.length; l++) {
      const lk = root.links[l]
      if (!lk) continue
      if ((lk.source && lk.source.id === node.id)
        || (lk.target && lk.target.id === node.id)) out.push(lk.id)
    }
    return out
  }

  // Stream nodes of one app-slot, for cut targeting.
  function _nodesFor(app, key) {
    const pool = key === "mic" ? root.micAttrStreams
      : key === "cam" ? root.camStreams : root.shareStreams
    const out = []
    for (let i = 0; i < pool.length; i++)
      if (root._appName(pool[i]) === app) out.push(pool[i])
    return out
  }

  // Island action dispatch: per-node access toggle. Connected ->
  // snapshot the exact link endpoints, cut the links, remember for
  // resume. Severed -> re-link the remembered endpoints (the entry stays
  // until links reappear, so a failed restore keeps showing cut instead
  // of lying connected).
  function _toggleTarget(app, key) {
    if (root._isSevered(app, key, root._linkIdsForNodes(root._nodesFor(app, key))))
      return root._restoreSevered(app, key)
    return root._snapshotAndCut(app, key)
  }

  function _linkIdsForNodes(nodes) {
    const out = []
    for (let i = 0; i < nodes.length; i++) {
      const ids = root._linkIdsForNode(nodes[i])
      for (let j = 0; j < ids.length; j++)
        if (out.indexOf(ids[j]) < 0) out.push(ids[j])
    }
    return out
  }

  function _restoreSevered(app, key) {
    const slot = root._slot(app, key)
    const entry = root.severed[slot]
    if (!entry || !entry.links || entry.links.length === 0) {
      // Nothing was remembered to re-link (the cut landed on a target that
      // was already unlinked), so there is no restore to perform: the mark is
      // dropped and the click is reported instead of quietly doing nothing.
      const next = Object.assign({}, root.severed)
      delete next[slot]
      root.severed = next
      root._refuse(app, key, "nothing_to_restore")
      return "error"
    }
    // Exact object ids, not "node:port" names: apps name every stream
    // alike (OBS names all of them "obs"), and pw-link resolves a name
    // spec by first match - a mic relink once landed in Desktop Audio.
    // The remembered mark is not dropped here: it stays while the target is
    // unlinked, so a restore that never lands keeps reading cut instead of
    // lying connected.
    const quads = entry.links.slice()
    const ids = []
    for (let i = 0; i < quads.length; i++)
      for (let j = 0; j < quads[i].length; j++) ids.push(quads[i][j])
    const record = root._openOperation(app, key, ids)
    if (record === null) return "error"
    if (root._beginPhase(record, "restore", quads.length) === null) {
      root._retire(record, "unusable_phase")
      return "error"
    }
    for (let i = 0; i < quads.length; i++) {
      const quad = quads[i]
      root._spawnPhaseCommand(record, "restore",
        CommandSpec.argv(PrivacyLib.relinkArgv(quad)))
    }
    return "ok"
  }

  // Cut and restore are pipelines of child processes, so each one runs under
  // a RequestGate generation for its own (app,key) pair, named by a bounded
  // digest of that pair. The generation is the only test of currency: a
  // callback whose pair was superseded, cancelled or timed out must not touch
  // the severed map, the cut, or the watchdog, so two toggles of one row
  // cannot interleave while different rows keep independent pipelines. The
  // gate holds no resource of its own, so a request that must also stop a
  // child stops it at its own ownership site and then retires the generation.
  readonly property string _gateScope: "privacy"
  // pw-dump answers from the daemon in milliseconds; a window this wide only
  // bounds a wedged graph, and a missed snapshot is not a late one.
  readonly property int _dumpTimeoutMs: 5000
  readonly property int _cmdTimeoutMs: 5000

  // Pipeline bookkeeping, keyed by slot: the phase, the children still to
  // report, whether one of them failed, and the children themselves. The
  // operation record that callbacks capture is immutable and carries the
  // handle, the slot, app, key and ids; the run holds only the counters, so a
  // callback that lost its pair finds a stale handle and never reaches a run.
  property var _runs: ({})

  // Slot of one (app,key) pair. The severed map and the run table key on this
  // string, so a pipeline and its mark always name one pair; the gate never
  // reads it, only a bounded digest of it (see _gateKey).
  function _slot(app, key) {
    return PrivacyLib.slotKey(app, key)
  }

  // Gate key of one pair: the scope's own prefix plus a fixed-width digest of
  // the slot. RequestGate refuses a label longer than its own 128-character
  // limit and answers a refused begin() with 0, so a gate key built from the
  // slot would let any client that sets an over-long PipeWire application name
  // refuse the user's own cut, every time, silently. The key is therefore 18
  // characters for an app name of any length, and the gate stores the digest,
  // never the app name.
  function _gateKey(slot) {
    return "p:" + PrivacyLib.gateDigest(slot)
  }

  // Starts the operation of a pair. The previous generation of the pair dies
  // before its children are stopped, so a callback racing the cancel already
  // sees a stale handle. A refused generation is not a live request, so the
  // toggle is refused instead of run ungated - and the refusal is reported,
  // because a click that changes no link must not look like one that did.
  function _openOperation(app, key, ids) {
    const slot = root._slot(app, key)
    root._abandon(slot, "superseded")
    const gateKey = root._gateKey(slot)
    const generation = RequestGate.begin(root._gateScope, gateKey)
    if (generation === 0) {
      root._refuse(app, key, "gate_refused")
      return null
    }
    const runs = Object.assign({}, root._runs)
    runs[slot] = { phase: "dump", pending: 0, failed: false, jobs: [] }
    root._runs = runs
    return Object.freeze({
      handle: Object.freeze({
        id: generation, scope: root._gateScope, key: gateKey
      }),
      slot: slot,
      app: app,
      key: key,
      ids: Object.freeze(ids.slice())
    })
  }

  // Retires the live generation of a pair and stops whatever it still owns.
  // The handle goes first: cancelling a child reports its terminal transition
  // synchronously, and that callback must already find a stale generation.
  function _abandon(slot, reason) {
    RequestGate.invalidateScope(root._gateScope, root._gateKey(slot))
    const run = root._runs[slot]
    if (run !== undefined) {
      const jobs = run.jobs.slice()
      for (let i = 0; i < jobs.length; i++) root._stopJob(jobs[i], reason)
    }
    root._dropRun(slot)
  }

  function _close(slot) {
    RequestGate.invalidateScope(root._gateScope, root._gateKey(slot))
    root._dropRun(slot)
  }

  function _dropRun(slot) {
    if (root._runs[slot] === undefined) return
    const next = Object.assign({}, root._runs)
    delete next[slot]
    root._runs = next
  }

  // Terminal path of the whole operation, whatever the outcome: the
  // generation dies, the record leaves the table, and the children the
  // operation still listed are already reported.
  function _retire(record, reason) {
    if (!RequestGate.current(record.handle)) return
    root._abandon(record.slot, reason)
  }

  function _beginPhase(record, phase, pending) {
    if (!RequestGate.current(record.handle)) return null
    const run = root._runs[record.slot]
    if (run === undefined) return null
    run.phase = phase
    run.pending = pending
    run.failed = false
    return run
  }

  // Every child is a registry-owned job: one terminal transition, its output
  // in the result, and a deadline that terminates the child instead of
  // leaving it parented forever. The callbacks know only the captured record,
  // so a child that starts after its pair was abandoned is stopped where it
  // stands. A command the contract refuses, or one the registry cannot build,
  // never spawns and reports through the refusal callback.
  function _spawn(record, spec, timeoutMs, onResult, onRefused) {
    if (spec === null || spec === undefined || spec.ok !== true) {
      onRefused("invalid_command")
      return false
    }
    let job = null
    try {
      job = ProcessRegistry.start(spec, root._gateScope, {
        timeoutMs: timeoutMs,
        onFinished: onResult,
        onFailed: onRefused
      })
    } catch (ignored) {
      job = null
    }
    if (job === null) {
      onRefused("unusable_command")
      return false
    }
    if (!RequestGate.current(record.handle)) {
      root._stopJob(job, "stale")
      return false
    }
    const run = root._runs[record.slot]
    if (run === undefined) {
      root._stopJob(job, "stale")
      return false
    }
    run.jobs.push(job)
    return true
  }

  // A settled job owns nothing: the registry released its child and destroys
  // the job itself, so only a live one is cancelled here. Cancelling runs the
  // terminal path, which stops the child and lets the registry dispose of the
  // job.
  function _stopJob(job, reason) {
    if (job === null || job === undefined) return
    try {
      if (String(job.state) === "settled") return
    } catch (ignored) {
      return
    }
    try {
      job.cancel(reason)
    } catch (ignored) {
      return
    }
  }

  function _jobSucceeded(result) {
    if (result === null || result === undefined) return false
    return String(result.code) === "ok" && Number(result.exitCode) === 0
      && result.timedOut !== true && result.cancelled !== true
      && result.destroyed !== true
  }

  // Stable code of the last refused or unlanded operation, or "" (also read
  // by the privacy IPC status). A refusal is never a silent no-op: the user
  // asked for a link to change, and if no child runs or none of them lands,
  // the row has to say so out loud instead of quietly reading connected.
  property string _refusal: ""

  function _refuse(app, key, code) {
    root._refusal = String(code)
    const short = root._shortApp(app)
    root._notify(short, key, PrivacyLib.refusalText(code))
  }

  // A record reports its own refusal only while its generation is still the
  // live one, so a pair the user already superseded with a newer click cannot
  // announce a failure that a running generation is about to replace.
  function _refuseRecord(record, code) {
    if (!RequestGate.current(record.handle)) return
    root._refuse(record.app, record.key, code)
  }

  // Toast for a privacy operation that did not land. The body carries the
  // pair and one reason: no link quad, node id, pw-dump text or other graph
  // state reaches a notification.
  function _notify(appName, key, reason) {
    const body = appName + " (" + PrivacyLib.targetMeta(key).label.toLowerCase() + "): " + reason
    // A capture that stayed live is worth urgency the plain toasts do not
    // carry.
    Exec.run(["notify-send", "-u", "critical", "-r", "1", "-a", "Vibranium",
      "Privacy", body])
  }

  // An app name is client data and can be arbitrarily long, so a name that
  // reaches a toast is cut to a readable length there; the ledger, the island
  // and the cut keep the whole string. This 48-character bound is the shell's
  // privacy bound on a client-supplied name and every surface that shows one
  // takes it.
  readonly property int _notifyAppLimit: 48

  function _shortApp(app) {
    return PrivacyLib.shortApp(app, root._notifyAppLimit)
  }

  // One argv child of a command phase. The id travels as an argument, so no
  // shell source is built and no id can be read as syntax. A refusal counts
  // as a failure like any other, because the pair told the graph to change
  // and it did not.
  function _spawnPhaseCommand(record, phase, spec) {
    root._spawn(record, spec, root._cmdTimeoutMs,
      (result) => root._countCommand(record, phase, root._jobSucceeded(result)),
      () => root._countCommand(record, phase, false))
  }

  // Snapshot live link endpoints via one pw-dump, then cut. QS links
  // carry no ports, and names are unusable as restore handles (streams
  // can share one node.name), so the exact node/port id quads from
  // pw-dump are what gets remembered for the restore.
  function _snapshotAndCut(app, key) {
    const nodes = root._nodesFor(app, key)
    const ids = root._linkIdsForNodes(nodes)
    if (ids.length === 0) {
      // Nothing linked (already torn down externally): remember the bare
      // state so the row still reads cut.
      const next = Object.assign({}, root.severed)
      next[root._slot(app, key)] = { links: [] }
      root.severed = next
      // It is a cut that had nothing to cut, not a failure: the mark is what
      // the user asked for, and the later restore reports `nothing_to_restore`
      // off it.
      return "ok"
    }
    const record = root._openOperation(app, key, ids)
    if (record === null) return "error"
    const started = root._spawn(record, CommandSpec.argv(PrivacyLib.dumpArgv()),
      root._dumpTimeoutMs,
      (result) => root._onDumpSettled(record, result),
      (reason) => root._onDumpRefused(record, reason))
    return started ? "ok" : "error"
  }

  // A snapshot child the contract or the registry refused never started, so
  // the click asked for a cut that no child will perform: the mark is left
  // exactly as it was (no remembered endpoint set exists either way) and the
  // refusal is reported. The report waits on the currency check inside
  // _refuseRecord, so a pair that lost its generation first stays quiet.
  function _onDumpRefused(record, reason) {
    root._refuseRecord(record, "snapshot_refused")
    root._retire(record, "dump_refused:" + String(reason))
  }

  // Terminal path of a snapshot child that ran. A child that failed or timed
  // out still cuts: the ids came from the live graph and a live straggler must
  // not survive the click, and remembering no endpoint quad is what a restore
  // later reports as having nothing to restore. The dump is graph state, not a
  // secret, and it leaves here by no surface: it is read for the endpoints
  // of this pair and dropped.
  function _onDumpSettled(record, result) {
    if (!RequestGate.current(record.handle)) return
    const links = root._jobSucceeded(result)
      ? PrivacyLib.linkQuads(String(result.stdout || ""), record.ids) : []
    const next = Object.assign({}, root.severed)
    next[record.slot] = { links: links }
    root.severed = next
    root._cutByIds(record)
  }

  // The children of a phase are one operation, so the watchdog is armed once
  // the last of them has reported and at least one failed, instead of on
  // whichever child happened to exit last.
  function _cutByIds(record) {
    const clean = PrivacyLib.cleanLinkIds(record.ids)
    if (clean.length === 0) {
      root._retire(record, "nothing_to_cut")
      return
    }
    if (root._beginPhase(record, "cut", clean.length) === null) {
      root._retire(record, "unusable_phase")
      return
    }
    for (let i = 0; i < clean.length; i++) {
      root._spawnPhaseCommand(record, "cut",
        CommandSpec.argv(PrivacyLib.unlinkArgv(clean[i])))
    }
  }

  // Counts one child of the phase and closes the operation when the last one
  // has reported, so the watchdog sees the whole verdict of the pair instead
  // of whichever child happened to exit last.
  function _countCommand(record, phase, succeeded) {
    if (!RequestGate.current(record.handle)) return
    const slot = record.slot
    const run = root._runs[slot]
    if (run === undefined || run.phase !== phase) return
    run.pending--
    if (!succeeded) run.failed = true
    if (run.pending > 0) return
    const failed = run.failed
    root._close(slot)
    if (!failed) return
    root._watchSevered(record.app, record.key, phase)
  }

  // Post-action watchdog (single shot, rearmed per action): 1.5s after a
  // cut, links still present mean the daemon refused or the session
  // manager relinked - say so and drop the mark instead of pretending.
  // 1.5s after a restore with nothing back, say that too (the mark
  // stays: still cut, honestly shown).
  //
  // Each watch is one record rather than a joined key: an app name is client
  // data and may carry the separator a joined key is split on, which would
  // hand the verdict to a pair the operation never belonged to.
  property var _watches: []

  Timer {
    id: watchTimer

    interval: 1500
    repeat: false

    onTriggered: {
      const watches = root._watches
      root._watches = []
      for (let i = 0; i < watches.length; i++) {
        const w = watches[i]
        const live = root._linkIdsForNodes(root._nodesFor(w.app, w.key)).length
        if (w.mode === "cut" && live > 0) {
          // The graph still carries the link, so the cut did not take: the
          // mark goes and the row reads connected again, which is what the
          // graph says, and the toast says the cut never landed.
          const next = Object.assign({}, root.severed)
          delete next[root._slot(w.app, w.key)]
          root.severed = next
          root._notify(root._shortApp(w.app), w.key, "still linked after the cut")
        } else if (w.mode === "restore" && live === 0) {
          // Nothing came back. The mark stays, so the row keeps reading cut
          // instead of claiming a live link it does not have, and the toast
          // says why the restore stayed quiet.
          root._notify(root._shortApp(w.app), w.key, "did not come back")
        }
      }
    }
  }

  // One watch per pair and mode, and re-arming replaces the earlier watch of
  // that pair instead of queueing a second verdict behind it.
  function _watchSevered(app, key, mode) {
    const next = root._watches.filter(
      w => !(w.app === app && w.key === key && w.mode === mode))
    next.push({ app: app, key: key, mode: mode })
    root._watches = next
    watchTimer.restart()
  }

  // Teardown: every pair loses its generation and every child it still owns is
  // terminated, so a late callback finds a stale handle and returns instead of
  // writing to a half torn down service. The job object goes with it: the
  // terminal path stops the child, and the registry's deferred dispose may
  // never run while the engine tears the tree down.
  function _shutdown() {
    const slots = Object.keys(root._runs)
    for (let i = 0; i < slots.length; i++) {
      const run = root._runs[slots[i]]
      if (run === undefined) continue
      const owned = run.jobs.slice()
      RequestGate.invalidateScope(root._gateScope, root._gateKey(slots[i]))
      for (let j = 0; j < owned.length; j++) {
        root._stopJob(owned[j], "destroyed")
        try {
          owned[j].destroy()
        } catch (ignored) {
          continue
        }
      }
    }
    root._runs = ({})
    watchTimer.stop()
    root._watches = []
  }

  function _nodeProps(node) {
    return (node && node.ready && node.properties) ? node.properties : {}
  }

  // Audio capture is the AudioInStream flag, and the mask must match exactly:
  // AudioOutStream (Audio|Stream|Sink) shares the Audio and Stream bits, so a
  // `& !== 0` test reads ordinary playback as microphone capture. The isSink
  // guard above stays for the case the bitmask cannot express: micAttrStreams
  // walks sink-side streams too, and an app's Mic/Aux tap is an AudioInStream
  // that receives from the source instead of sourcing it.
  function _isCaptureStream(node) {
    if (!node || !node.isStream) return false
    if (node.isSink === false) return true
    return (Number(node.type || 0) & PwNodeType.AudioInStream) === PwNodeType.AudioInStream
  }

  function _haystack(node) {
    var parts = []
    if (node) {
      parts.push(node.name)
      parts.push(node.description)
      parts.push(node.nickname)
      var props = root._nodeProps(node)
      parts.push(props["application.name"])
      parts.push(props["media.name"])
      parts.push(props["media.role"])
      parts.push(props["media.category"])
      parts.push(props["node.name"])
      parts.push(props["stream.name"])
      parts.push(props["media.class"])
    }
    return parts.join(" ").toLowerCase()
  }

  // The peer on the other end of a link touching `stream`, when that peer
  // is a live share source - i.e. this stream drinks from a screencast.
  function _streamShareSource(stream) {
    if (!stream) return null
    for (var l = 0; l < root.links.length; l++) {
      var lk = root.links[l]
      if (!lk) continue
      var s = lk.source
      var t = lk.target
      var other = null
      if (s && s.id === stream.id) other = t
      else if (t && t.id === stream.id) other = s
      if (other && root.liveShareSourceIds[other.id]) return other
    }
    return null
  }

  function _shareSourceIdSet() {
    var set = {}
    for (var i = 0; i < root.shareSources.length; i++)
      if (root.shareSources[i]) set[root.shareSources[i].id] = true
    return set
  }

  function _isShareStream(node) {
    if (!node) return false
    // 1. Explicit role tag (WebRTC/Chromium convention).
    var props = root._nodeProps(node)
    var role = String(props["media.role"] || "").toLowerCase()
    if (role.indexOf("screen") !== -1) return true
    if (role.indexOf("camera") !== -1) return false
    // 2. Pinned to a portal source (node.target / driver id).
    var target = String(props["node.target"] || "")
    if (target !== "" && root._shareSourceIdSet()[target]) return true
    // 3. Linked to a live portal screencast source (covers bare "Discord"
    // style streams with no telling description).
    if (root._streamShareSource(node) !== null) return true
    // 4. Keyword fallback over the node identity.
    var hay = root._haystack(node)
    if (hay === "" || hay.trim() === "") return false
    var keys = ["screen", "share", "screencast", "portal", "xdpw", "xdph",
      "display", "monitor", "window capture", "screencopy", "wlr-"]
    for (var i = 0; i < keys.length; i++) {
      if (hay.indexOf(keys[i]) !== -1) return true
    }
    return false
  }

  // Raw app name shared by tooltip and island, trimmed only.
  // Well-known lowercase brands keep their acronym shape
  // ("obs" -> "OBS"); everything else renders exactly as reported,
  // never force-capitalized ("discord" stays "discord").
  readonly property var _brandOverrides: ({ obs: "OBS", vlc: "VLC" })

  function _prettyApp(raw) {
    var s = String(raw ?? "").trim()
    if (s === "") return ""
    var ov = root._brandOverrides[s.toLowerCase()]
    if (ov !== undefined) return ov
    return s
  }

  // Display name of the app behind a node: process binary first (audio
  // nodes report generic engine names like "WEBRTC VoiceEngine" as the
  // application name), then progressively less specific identities.
  function _appName(node) {
    if (!node) return "Unknown"
    var pr = root._nodeProps(node)
    var cands = [pr["application.process.binary"], pr["application.name"],
      node.name, pr["media.name"], node.description, node.nickname]
    for (var i = 0; i < cands.length; i++) {
      var s = root._prettyApp(cands[i])
      if (s !== "") return s
    }
    return "Unknown"
  }

  // Hex color for a palette key, for the tooltip's app-name spans. The
  // markup assembly is the library's; the theme lookup is this file's, so
  // the library holds no QML type.
  function _solidColor(colorKey) {
    return String(Ui.solid(colorKey))
  }

  // Icon for an app name: shell asset first, then the desktop theme
  // with a per-kind generic fallback (never the purple checker).
  function _iconForName(name, fallback) {
    var s = String(name ?? "").trim()
    if (s === "") return ""
    var lower = s.toLowerCase()
    var themed = Icons.url(lower)
    if (themed !== "") return themed
    themed = Icons.url(s)
    if (themed !== "") return themed
    return Quickshell.iconPath(lower, fallback)
  }

  // Icon for an island row: the node's own icon hints first, then the
  // resolved app name.
  function _iconSource(node, fallback) {
    var pr = root._nodeProps(node)
    var name = String(pr["application.icon-name"]
      || pr["application.process.binary"] || "").trim()
    if (name !== "") {
      const hit = root._iconForName(name, "")
      if (hit !== "") return hit
    }
    return root._iconForName(root._appName(node), fallback)
  }

  // Technical bits per node for the island: the media class rides next
  // to the app title, the window title (when it isn't just the app name
  // again) plus the Pipewire object id land in the subtext.
  function _classText(node) {
    if (!node) return ""
    return String(root._nodeProps(node)["media.class"] || "").trim()
  }

  function _titleText(node, app) {
    if (!node) return ""
    var pr = root._nodeProps(node)
    var parts = []
    var name = String(pr["media.name"] || "").trim()
    if (name !== "" && name.toLowerCase() !== String(app ?? "").toLowerCase())
      parts.push(name)
    return parts.join(" • ")
  }

  // Target metadata, the island lines and the tooltip markup live in
  // PrivacyLib: the island and the tooltip are the only readers of the ledger
  // and neither owns a theme or a graph handle, so the projection belongs
  // beside them. See the two library sections the header names.

  // One row per active node, already resolved: the app name behind it, the
  // two text bits the island shows, the icon and the live link ids. The fold
  // that turns rows into per-app entries is the library's; this function is
  // only the read of the live graph that a fold cannot do itself.
  function _ledgerRows() {
    const rows = []
    for (let i = 0; i < root.shareStreams.length; i++) {
      const n = root.shareStreams[i]
      const app = root._appName(n)
      rows.push({ app: app, kind: "share", classText: root._classText(n),
        titleText: root._titleText(n, app),
        icon: root._iconSource(n, "video-display"),
        linkIds: root._linkIdsForNode(n) })
    }
    for (let i = 0; i < root.camStreams.length; i++) {
      const n = root.camStreams[i]
      const app = root._appName(n)
      rows.push({ app: app, kind: "cam", classText: root._classText(n),
        titleText: root._titleText(n, app),
        icon: root._iconSource(n, "camera-video"),
        linkIds: root._linkIdsForNode(n) })
    }
    for (let i = 0; i < root.micAttrStreams.length; i++) {
      const n = root.micAttrStreams[i]
      const app = root._appName(n)
      rows.push({ app: app, kind: "mic", classText: root._classText(n),
        titleText: root._titleText(n, app),
        icon: root._iconSource(n, "audio-input-microphone"),
        linkIds: root._linkIdsForNode(n) })
    }
    return rows
  }

  // Per-app usage ledger: app -> {app, icon, targets, line1, line2}.
  readonly property var appEntries:
    PrivacyLib.ledger(root._ledgerRows(), root.severed)

  // Island model and tooltip: the two published projections, each a library
  // call over the ledger. The lit set is this file's state, the theme lookup
  // is this file's, and nothing here rebuilds a row.
  readonly property var _litTargets: ({
    mic: root.micOn,
    cam: root.camOn,
    share: root.shareOn
  })

  readonly property var islandRows:
    PrivacyLib.islandRows(root.appEntries, root._litTargets)

  // Tooltip rows for the bar bubble: one icon-led row per app per lit
  // target, assembled in PrivacyLib like the island rows above. The app
  // name span resolves through the theme lookup here (a .js file holds
  // no QML types); the verb stays the host foreground.
  readonly property var tooltipRows:
    PrivacyLib.tooltipRows(root.appEntries, root._litTargets, root.severed,
      root._solidColor)

  Component.onCompleted: {
    Registry.offer("privacy", {
      title: "Privacy indicators",
      description: "mic/camera/screenshare capture state",
      verbNames: [
        "status",
        "help",
        "ping",
      ]
    })
    Registry.register("privacy", root)
  }
  Component.onDestruction: {
    Registry.unregister("privacy")
    root._shutdown()
  }

  IpcHandler {
    target: "privacy"
    function help(command: string): string {
      return UnitIpc.help("privacy", "Privacy indicators", "mic/camera/screenshare capture state", [
        { name: "status", help: "mic/cam/share/active snapshot" },
      ], command)
    }
    function ping(): string { return "pong" }
    function status(): string {
      return JSON.stringify({
        mic: root.micOn,
        cam: root.camOn,
        share: root.shareOn,
        active: root.active,
        refused: root._refusal
      })
    }
  }
}
