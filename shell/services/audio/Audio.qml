pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.common
import qs.services as Core
import "../../common/text/IpcCatalog.js" as Catalog
import "../../common/audio/AudioNodeKind.js" as Kind
import "../../common/audio/AudioLoopback.js" as Loopback
import "../../common/theme/DeviceIcons.js" as DeviceIcons
import "../../common/math/Range.js" as Range
import "AudioIpc.js" as Ipc

// Audio service: volume and microphone policy for the whole shell.
// Binds Pipewire's default sink/source through the one PipeWire state owner
// (audio/PipeWireState) - no wpctl, no bash shims, no child processes, and no
// tracker of its own. Owns step/max/mute policy, the OSD triggers, and the
// `vb-shell audio ...` gateway surface. The bar widgets and the island delegate
// here; external callers go through IPC.
//
// Where the device state comes from: PipeWireState holds the two
// PwObjectTrackers (one per default device), the volume/mute reads they keep
// alive, the peak monitor and the link-group observation the privacy service
// reads. The devices are the same objects, reached through the owner; every
// policy below - step, caps, boost fade, OSD, IPC surface - is here.
Singleton {
  id: root

  readonly property string tag: "audio"

  // --- settings (reactive via Settings.rev inside Settings.value) ---

  readonly property real step: {
    const v = Settings.value("shell.volume.step")
    return typeof v === "number" && v > 0 ? v / 100 : 0.05
  }
  readonly property real maxVolume: {
    const v = Settings.value("shell.volume.allowAboveHundred")
    return v === true ? 2.0 : 1.0
  }
  readonly property real maxSourceVolume: {
    const v = Settings.value("shell.volume.micAllowAboveHundred")
    return v === true ? 2.0 : 1.0
  }
  readonly property bool visualFeedback: Settings.value("shell.volume.visualFeedback") !== false
  readonly property bool loopbackEnabled: Settings.value("shell.audio.loopback") === true
  readonly property string loopbackError: root._loopbackError
  property string _loopbackError: ""
  // The failure already shown to the user, so a reconcile that keeps failing
  // does not keep reporting the same failure. Cleared when the loopback
  // succeeds, so a later failure is reported again.
  property string _loopbackReported: ""
  property bool _loopbackBusy: false
  property bool _loopbackQueued: false
  property bool _loopbackSeeded: false
  property var _loopbackOwned: []
  property var _loopbackCommands: []
  property var _loopbackRemovals: []
  property var _loopbackDesired: []
  property int _loopbackGeneration: 0
  property string _loopbackLinkText: ""
  readonly property int loopbackTimeoutMs: 5000
  readonly property string loopbackOwner: "audio:loopback"
  readonly property var _loopbackSource: Core.PipeWireState.source
  readonly property var _loopbackSink: Core.PipeWireState.sink
  readonly property string _loopbackSourceId: Loopback.nodeId(root._loopbackSource)
  readonly property string _loopbackSinkId: Loopback.nodeId(root._loopbackSink)
  readonly property string _loopbackSourceName: Loopback.nodeName(root._loopbackSource)
  readonly property string _loopbackSinkName: Loopback.nodeName(root._loopbackSink)

  // Boost toggled off while the sink sits above 100%: glide down to the
  // cap instead of snapping (or lingering boosted until the next volume
  // keypress). Boost toggled back on: glide up to the previously saved
  // boosted level. Silent (no OSD): the toggle wasn't a volume action.
  // Only ever lowers on the way down, only ever raises on the way up.
  onMaxVolumeChanged: {
    const increased = root.maxVolume > root._prevMax
    root._prevMax = root.maxVolume
    if (!root.sink || !root.sink.audio) return
    if (root.sink.audio.volume > root.maxVolume) {
      root._onBoostDisabled()
    } else if (increased) {
      root._onBoostEnabled()
    }
  }

  // Previous cap, so the change handler knows the direction: disabling
  // must never raise the volume, enabling must never lower it.
  property real _prevMax: 1.0

  // Mic boost needs no fade channel: disabling above the cap snaps
  // the source back to it (the sink glide above stays untouched).
  onMaxSourceVolumeChanged: {
    if (root.source && root.source.audio && root.source.audio.volume > root.maxSourceVolume)
      root.source.audio.volume = root.maxSourceVolume
  }

  // In-memory mirror of the boost state file (the pre-fade boosted
  // volume). The file outlives shell restarts; this avoids a disk read
  // on the common toggle-off/toggle-on round trip.
  property real _savedBoost: 0

  // --- pipewire nodes ---
  //
  // The shell's ONE PipeWire state owner holds the trackers and publishes the
  // devices; this service keeps only the policy that acts on them. The
  // published device is null until the graph and the node itself are ready
  // (pre-ready objects are documented as incomplete), which every read and
  // write below already survives: a null device is a state this file has
  // always handled.
  // qmllint disable unresolved-type missing-property
  // (the singleton line for PipeWireState in shell/services/qmldir is
  // spec 09's registration; until it is in, qmllint cannot resolve the type
  // and reports every member of it as missing. The disable covers those two
  // rules for these two lines only and can go with the registration.)
  readonly property var sink: Core.PipeWireState.sink
  readonly property var source: Core.PipeWireState.source
  // qmllint enable unresolved-type missing-property

  // --- read-only state for bindings ---

  readonly property real sinkVolume: root.sink && root.sink.audio ? root.sink.audio.volume : 0
  readonly property bool sinkMuted: root.sink && root.sink.audio ? root.sink.audio.muted : false
  readonly property real sourceVolume: root.source && root.source.audio ? root.source.audio.volume : 0
  readonly property bool sourceMuted: root.source && root.source.audio ? root.source.audio.muted : false
  // Nothing audible: the explicit mute, or a level driven to zero. The
  // glyph's red off-mark reads this; the mute verbs, the toggles and the
  // "Muted" readouts keep the raw flags above, because a level the user
  // turned down is not a mute anyone performed.
  readonly property bool sinkSilent: DeviceIcons.silentFor(root.sinkVolume, root.sinkMuted)
  readonly property bool sourceSilent: DeviceIcons.silentFor(root.sourceVolume, root.sourceMuted)

  // --- mute transitions ---
  //
  // A sink and a source are the only two mute transitions a session produces,
  // and they are what a reader needs to answer "why is there no sound".
  //
  // Observed from the published state, not from the write that asks for it:
  // the two toggles, the island's own icons, the percent setter and a delta
  // keypress all land on these properties, and a write the backend refuses
  // raises no change, so a transition is only seen for one that landed.
  //
  // The device rides along with the value in a single observation because the
  // two signals are independent: a switch to a device that comes up already
  // muted moves both, and comparing the value alone would read the switch as a
  // mute. A different node re-seeds rather than reporting - a device that
  // arrives muted is a device fact, not a mute anyone performed.
  readonly property var _sinkMuteState: ({ node: root.sink, muted: root.sinkMuted })
  readonly property var _sourceMuteState: ({ node: root.source, muted: root.sourceMuted })
  // null until the device's first sighting; the handlers below are the seed.
  property var _sinkMuteSeen: null
  property var _sourceMuteSeen: null

  on_SinkMuteStateChanged: {
    root._sinkMuteSeen = root._muteTransition(root._sinkMuteSeen, root._sinkMuteState)
  }

  on_SourceMuteStateChanged: {
    root._sourceMuteSeen = root._muteTransition(root._sourceMuteSeen, root._sourceMuteState)
  }

  // A transition is one device carrying a different value. The node object is
  // the identity: the numeric PipeWire id the neutral mechanism keys its
  // trackers on is graph state, and the shell's redaction contract forbids
  // naming it on any surface.
  function _muteTransition(seen, now) {
    const event = seen !== null && seen.node === now.node && seen.muted !== now.muted
    return { node: now.node, muted: now.muted, event: event }
  }

  // --- boost fade ---

  // Current glide state. _fadeFrom/_fadeTo are real sink volumes; the
  // duration scales with their distance so a 200%->100% drop glides
  // longer than a 120%->100% one.
  property bool _fading: false
  property real _fadeFrom: 0
  property real _fadeTo: 0
  property double _fadeStart: 0
  property real _fadeDur: 300

  // Boost turned off with the sink above the cap: remember the boosted
  // level (memory + state file) BEFORE gliding, then fade down to it.
  function _onBoostDisabled() {
    const audio = root.sink && root.sink.audio
    if (!audio) return
    const cur = audio.volume
    if (cur <= root.maxVolume) return
    root._savedBoost = cur
    root._writeBoostFile(cur)
    root._boostFadeReason = "boost-disabled"
    root._fadeVolumeTo(root.maxVolume)
  }

  // Boost turned back on: glide up to the remembered boosted level, if
  // it still sits above the current volume. Same curve as the way down,
  // mirrored (the interpolation below is symmetric in its endpoints).
  function _onBoostEnabled() {
    const audio = root.sink && root.sink.audio
    if (!audio) return
    let target = root._savedBoost
    if (!(target > 0)) target = root._readBoostFile()
    // Boost re-enabled with nothing remembered: the glide cannot run, so a
    // boost toggle appears to do nothing.
    if (!(target > 0)) return
    target = Math.min(target, root.maxVolume)
    if (target <= audio.volume + 0.005) return
    root._boostFadeReason = "boost-enabled"
    root._fadeVolumeTo(target)
  }

  // Start a glide from the live volume to `target`. Near-zero spans snap.
  function _fadeVolumeTo(target) {
    if (!root.sink || !root.sink.audio) return
    const from = root.sink.audio.volume
    const span = Math.abs(target - from)
    if (span < 0.005) {
      root.sink.audio.volume = target
      return
    }
    root._fadeFrom = from
    root._fadeTo = target
    root._fadeStart = Date.now()
    root._fadeDur = Range.clamp(150 + 500 * span, 150, 900)
    root._fading = true
    root._boostFadeReason = ""
    fadeTimer.restart()
  }

  // Why the current glide is running. A fade has exactly two causes - boost
  // turned off (glide DOWN to the cap) and boost turned on (glide UP to the
  // remembered level).
  property string _boostFadeReason: ""

  function _cancelFade(why) {
    if (!root._fading) return
    root._fading = false
    fadeTimer.stop()
    root._boostFadeReason = ""
  }

  // One fade step. Loudness is logarithmic, so a linear amplitude ramp
  // would dive fast then crawl - interpolate in the log domain with a
  // smootherstep ease on the progress instead, which reads as a steady
  // glide. Near-silence clamps at 0.01 for the log math; the final step
  // lands exactly on target.
  function _fadeTick() {
    if (!root.sink || !root.sink.audio) {
      root._cancelFade("sink-gone")
      return
    }
    let p = (Date.now() - root._fadeStart) / Math.max(1, root._fadeDur)
    if (p >= 1) {
      root.sink.audio.volume = root._fadeTo
      root._cancelFade("landed")
      return
    }
    if (p < 0) p = 0
    const e = p * p * p * (p * (p * 6 - 15) + 10)
    const lo = Math.log(Math.max(0.01, root._fadeFrom))
    const hi = Math.log(Math.max(0.01, root._fadeTo))
    root.sink.audio.volume = Math.exp(lo + (hi - lo) * e)
  }

  // Persist the pre-fade boosted volume before gliding down, so the
  // matching fade-up can restore it (even across shell restarts).
  // Lives in the unified shell-owned cache ($VIBRANIUM_CACHE/shell.json,
  // "audio" section) - debounced atomic write, no processes involved.
  function _writeBoostFile(v) {
    ShellCache.setSection("audio", { boostedVolume: v })
  }

  // Read back the saved boosted level; 0 when absent or invalid.
  function _readBoostFile() {
    const v = ShellCache.number("audio", "boostedVolume", 0)
    if (isFinite(v) && v > 1.0 && v <= 2.0) return v
    return 0
  }

  // Volume glide tick, named (~60fps): the fade interpolates per tick,
  // so the cadence is the frame rate, not a poll.
  readonly property int fadeTickMs: 16
  Timer {
    id: fadeTimer

    interval: root.fadeTickMs
    repeat: true
    onTriggered: root._fadeTick()
  }

  // A new sink (device switch) carries its own level: drop any glide
  // aimed at the old device and clamp hard when above the cap. The clamp is a
  // write the user did not ask for, so it happens before anything else that
  // might still be holding the old device's target.
  onSinkChanged: {
    root._cancelFade("device-switch")
    if (root.sink && root.sink.audio && root.sink.audio.volume > root.maxVolume) {
      root.sink.audio.volume = root.maxVolume
    }
  }

  onLoopbackEnabledChanged: {
    root._loopbackGeneration++
    root._scheduleLoopback()
  }
  on_LoopbackSourceChanged: {
    root._loopbackGeneration++
    root._scheduleLoopback()
  }
  on_LoopbackSinkChanged: {
    root._loopbackGeneration++
    root._scheduleLoopback()
  }

  // The loopback's failure is the one outcome of the "Hear my voice" switch
  // the user cannot see: the value is accepted, the route is not created, and
  // the switch stays on, so nothing says the effect never happened. The
  // reason is reported where the user can see it - the log scope and a card -
  // and once per distinct failure, because the reconcile re-runs on every
  // device change and a pw-link that keeps failing must not keep pinging.
  on_LoopbackErrorChanged: {
    // The raw property, not the `loopbackError` alias: the alias is a
    // binding, and inside a change handler it still holds the value from
    // before the write. Two failures in the same turn would then report the
    // first one's reason instead of the one that is current.
    const reason = root._loopbackError
    if (reason === "") {
      root._loopbackReported = ""
      return
    }
    Log.error("loopback: " + reason)
    if (reason === root._loopbackReported) return
    root._loopbackReported = reason
    root._notifyLoopbackFailure(reason)
  }

  function _scheduleLoopback() {
    if (root._loopbackQueued) return
    root._loopbackQueued = true
    Qt.callLater(() => {
      root._loopbackQueued = false
      root._reconcileLoopback()
    })
  }

  function _reconcileLoopback() {
    if (!root._loopbackSeeded || root._loopbackBusy) return
    root._loopbackBusy = true
    const generation = ++root._loopbackGeneration
    root._loopbackDesired = []
    if (root.loopbackEnabled && root._loopbackSourceId !== ""
      && root._loopbackSinkId !== "" && root._loopbackSourceName !== ""
      && root._loopbackSinkName !== "") {
      root._readLoopbackPorts(generation)
      return
    }
    root._reconcileLinks([], generation)
  }

  // A reconcile stage whose generation was superseded parks the loop and asks
  // for another pass. Every async stage exits through this rule.
  function _loopbackSuperseded(generation) {
    if (generation === root._loopbackGeneration) return false
    root._loopbackBusy = false
    root._scheduleLoopback()
    return true
  }

  // The common failure exit for the loopback loop.
  function _loopbackFail(reason) {
    root._loopbackBusy = false
    root._loopbackError = reason
  }

  function _readLoopbackPorts(generation) {
    const results = { outputs: null, inputs: null, links: null, pending: 3 }
    const adopt = (key, result) => {
      results[key] = result
      results.pending--
      if (results.pending !== 0) return
      if (root._loopbackSuperseded(generation)) return
      if (results.outputs?.code !== "ok" || results.inputs?.code !== "ok"
        || results.links?.code !== "ok") {
        root._loopbackFail("could not read default audio ports or links")
        return
      }
      const plan = Loopback.plan(root._loopbackSourceName, root._loopbackSinkName,
        String(results.outputs.stdout || ""), String(results.inputs.stdout || ""))
      if (plan.error !== "") {
        root._loopbackFail(plan.error)
        return
      }
      const graphLinks = Loopback.identifyLinks(
        Loopback.parseLinks(String(results.links.stdout || "")), Core.PipeWireState.nodes)
      root._loopbackLinkText = String(results.links.stdout || "")
      const desired = root.loopbackEnabled
        ? Loopback.routesForDefault(plan.pairs, root._loopbackSourceId, root._loopbackSinkId)
        : []
      const owned = Loopback.reidentify(root._loopbackOwned, graphLinks,
        root._loopbackSourceId, root._loopbackSinkId)
      const adopted = Loopback.adoptExisting(graphLinks, desired, owned)
      const removed = Loopback.removalSteps(graphLinks, adopted, desired)
      const connect = { steps: Loopback.connectionSteps(graphLinks, adopted, desired), error: "" }
      root._loopbackOwned = adopted
      ShellState.updateSection("audio", { loopbackPairs: Loopback.persistableRoutes(adopted) })
      root._runLoopbackCommands(removed, connect, desired, generation)
    }
    root._readLoopback(["pw-link", "-o"], result => adopt("outputs", result))
    root._readLoopback(["pw-link", "-i"], result => adopt("inputs", result))
    root._readLoopback(["pw-link", "-l", "-I"], result => adopt("links", result))
  }

  function _reconcileLinks(desired) {
    root._loopbackBusy = true
    root._loopbackGeneration++
    const generation = root._loopbackGeneration
    root._readLoopback(["pw-link", "-l", "-I"], result => {
      if (root._loopbackSuperseded(generation)) return
      if (result === null || result === undefined || result.code !== "ok") {
        root._loopbackFail("could not read current audio links")
        return
      }
      const links = Loopback.identifyLinks(
        Loopback.parseLinks(String(result.stdout || "")), Core.PipeWireState.nodes)
      root._loopbackLinkText = String(result.stdout || "")
      const owned = Loopback.reidentify(root._loopbackOwned, links,
        root._loopbackSourceId, root._loopbackSinkId)
      root._loopbackOwned = owned
      ShellState.updateSection("audio", { loopbackPairs: Loopback.persistableRoutes(owned) })
      const removals = Loopback.removalSteps(links, owned, desired)
      root._runLoopbackCommands(removals, { steps: [], error: "" }, desired, generation)
    })
  }

  function _readLoopback(argv, done) {
    const job = Exec.runJob(argv, root.loopbackOwner, {
      timeoutMs: root.loopbackTimeoutMs,
      maxAttempts: 1,
      onFinished: result => done(result)
    })
    if (job === null || job === undefined) done(null)
  }

  function _runLoopbackCommands(removals, connection, desired, generation) {
    if (connection.error !== "") {
      root._loopbackFail(connection.error)
      return
    }
    root._loopbackRemovals = removals
    root._loopbackCommands = connection.steps
    root._loopbackDesired = desired
    root._sendNextLoopbackRemoval(desired, generation)
  }

  function _sendNextLoopbackRemoval(desired, generation) {
    if (root._loopbackSuperseded(generation)) return
    if (root._loopbackRemovals.length === 0) {
      root._sendNextLoopbackCommand(desired, generation)
      return
    }
    const command = root._loopbackRemovals[0]
    root._loopbackRemovals = root._loopbackRemovals.slice(1)
    const job = Exec.runJob(command.argv, root.loopbackOwner, {
      timeoutMs: root.loopbackTimeoutMs,
      maxAttempts: 1,
      onFinished: result => {
        if (result === null || result === undefined || result.code !== "ok") {
          root._loopbackFail("pw-link refused to remove the loopback route")
          return
        }
        root._loopbackOwned = Loopback.removeFromOwned(root._loopbackOwned, command)
        ShellState.updateSection("audio", { loopbackPairs: Loopback.persistableRoutes(root._loopbackOwned) })
        root._sendNextLoopbackRemoval(desired, generation)
      }
    })
    if (job === null || job === undefined) root._loopbackFail("could not start pw-link")
  }

  function _sendNextLoopbackCommand(desired, generation) {
    if (root._loopbackSuperseded(generation)) return
    if (root._loopbackCommands.length === 0) {
      root._finishLoopback(desired, generation)
      return
    }
    const command = root._loopbackCommands[0]
    root._loopbackCommands = root._loopbackCommands.slice(1)
    const job = Exec.runJob(command.argv, root.loopbackOwner, {
      timeoutMs: root.loopbackTimeoutMs,
      maxAttempts: 1,
      onFinished: result => {
        if (result === null || result === undefined || result.code !== "ok") {
          root._loopbackFail("pw-link refused to create the loopback route")
          return
        }
        root._loopbackOwned = Loopback.addOwned(root._loopbackOwned, root._loopbackDesired, command)
        ShellState.updateSection("audio", { loopbackPairs: Loopback.persistableRoutes(root._loopbackOwned) })
        root._sendNextLoopbackCommand(desired, generation)
      }
    })
    if (job === null || job === undefined) root._loopbackFail("could not start pw-link")
  }

  function _finishLoopback(desired, generation) {
    if (root._loopbackSuperseded(generation)) return
    root._loopbackBusy = false
    root._loopbackError = ""
    ShellState.updateSection("audio", { loopbackPairs: Loopback.persistableRoutes(root._loopbackOwned) })
  }

  // The card for a loopback that did not land. The reason is the whole body:
  // the user turned a switch on and nothing happened, and the reason is what
  // they need to act on. The card carries a replace id so a failure that
  // repeats replaces the one before it instead of stacking a second copy.
  function _notifyLoopbackFailure(reason) {
    const what = root.loopbackEnabled ? "Hear my voice" : "Audio loopback"
    Exec.notify("Audio", what + ": " + reason,
      { urgency: "normal", replaceId: 2, timeoutMs: 8000 })
  }

  // --- actions ------------------------------------------------------------
  //
  // One owner per default-device fact. Every user-facing write of a sink or
  // source level lands on setSinkVolume/setSourceVolume, and every write of
  // a mute flag lands on setSinkMuted/setSourceMuted. The island sliders call
  // the level setters directly so a drag stays synchronous - one node write
  // per pointer move, no IPC hop - and the verbs below add OSD on top.
  //
  // Cancelling a boost fade is part of setSinkVolume, not a caller's job: a
  // fade tick arriving after a drag would otherwise glide away from the level
  // the user just chose (XPLAT-2). The mute-lift rule lives here too, so a
  // step or a drag whose result is above zero is always a request to hear the
  // device. A result of exactly zero keeps the current mute, which is what
  // slider-to-zero has always done.
  function setSinkVolume(v) {
    if (!root.sink || !root.sink.audio) return
    root._cancelFade("slider")
    const next = Range.clamp(Number(v), 0, root.maxVolume)
    if (!isFinite(next)) return
    if (root.sink.audio.muted && next > 0) root.setSinkMuted(false)
    root.sink.audio.volume = next
  }

  function setSourceVolume(v) {
    if (!root.source || !root.source.audio) return
    const next = Range.clamp(Number(v), 0, root.maxSourceVolume)
    if (!isFinite(next)) return
    if (root.source.audio.muted && next > 0) root.setSourceMuted(false)
    root.source.audio.volume = next
  }

  function setSinkMuted(muted) {
    if (!root.sink || !root.sink.audio) return
    root.sink.audio.muted = !!muted
  }

  function setSourceMuted(muted) {
    if (!root.source || !root.source.audio) return
    root.source.audio.muted = !!muted
  }

  function adjustSink(delta) {
    if (!root.sink || !root.sink.audio) return
    // Clamp like bash: beyond the cap snaps to the cap instead of refusing.
    // A step that leaves the level above zero lifts the mute, whichever way
    // the step went: a decrease from a muted device is as much a request to
    // hear it as an increase is.
    root.setSinkVolume(root.sink.audio.volume + delta)
    root._showSinkOSD()
  }

  function adjustSource(delta) {
    if (!root.source || !root.source.audio) return
    root.setSourceVolume(root.source.audio.volume + delta)
    root._showSourceOSD()
  }

  function toggleSinkMute() {
    if (!root.sink || !root.sink.audio) return
    root.setSinkMuted(!root.sink.audio.muted)
    root._showSinkOSD()
  }

  function toggleSourceMute() {
    if (!root.source || !root.source.audio) return
    root.setSourceMuted(!root.source.audio.muted)
    root._showSourceOSD()
  }

  // Absolute set in percent. 0 also mutes (bash set_volume parity);
  // any other value unmutes. The mute-at-zero is deliberate and stays here:
  // setSinkVolume(0) from the slider keeps the existing mute, while this verb
  // explicitly mutes - both render the same off glyph (Q11).
  function setSinkPercent(pct) {
    const p = Math.round(Number(pct))
    if (!(p >= 0) || !(p <= 200)) return
    if (!root.sink || !root.sink.audio) return
    if (p === 0) {
      root.setSinkVolume(0)
      root.setSinkMuted(true)
    } else {
      root.setSinkVolume(p / 100)
    }
    root._showSinkOSD()
  }

  // --- OSD ---

  // Level icon for a 0..1 volume fraction, canonicalized in
  // common/theme/DeviceIcons.js. Single tiered asset: volume-max
  // renders every level through dimTiers below, so this never names
  // per-tier files (volume-low/mid ship no SVGs and would paint blank).
  // Central helper so the bar module, both islands and the OSD resolve
  // through here instead of hand-rolling their own splits.
  function volumeIconFor(volume, muted) {
    return DeviceIcons.volumeIconFor(volume, muted)
  }

  // Wave groups kept opaque on the tiered volume-max glyph,
  // canonicalized in common/theme/DeviceIcons.js: 0 = whole glyph,
  // 1 = speaker only, 2 = speaker + inner wave, 3 = everything.
  // volume-off has no tiers and gets 0.
  function volumeDimTiersFor(volume, muted) {
    return DeviceIcons.volumeDimTiersFor(volume, muted)
  }

  // Whether a level reads as silence (muted or at zero). Canonical in
  // common/theme/DeviceIcons.js; consumers color the off glyph with it
  // and keep the raw mute flag for their own readouts and toggles.
  function silentFor(volume, muted) {
    return DeviceIcons.silentFor(volume, muted)
  }

  function _sinkBar() {
    return Range.clamp(Math.round(root.sinkVolume / root.maxVolume * 100), 0, 100)
  }

  function _sourceBar() {
    return Range.clamp(Math.round(root.sourceVolume / root.maxSourceVolume * 100), 0, 100)
  }

  function _sinkIcon() {
    return root.volumeIconFor(root.sinkVolume, root.sinkMuted)
  }

  function _showSinkOSD() {
    if (!root.visualFeedback) return
    // The last argument is the OSD's "nothing audible" half: the off-mark
    // goes red and the meter reads empty. A level at zero is that state
    // even when the sink is not muted, and the fill is already zero then.
    Registry.call("osd", "show", "volume", root._sinkBar(), "", root._sinkIcon(), root.sinkSilent)
  }

  function _showSourceOSD() {
    if (!root.visualFeedback) return
    Registry.call("osd", "show", "microphone", root._sourceBar(), "",
      root.sourceMuted ? "mic-off" : "mic-on", root.sourceSilent)
  }

  // --- the audio gateway --------------------------------------------------
  // Every row below is a typed gateway command registered with IpcRouter.
  // No human-readable reply is parsed, no PipeWire id or property dump is
  // published, and no tracker, window or wpctl child is created by a read.

  function _ok(data, format) {
    const frame = { v: 1, ok: true }
    if (data !== undefined) frame.data = data
    if (format) frame.format = format
    return frame
  }
  function _error(code, message) {
    return { v: 1, ok: false, error: { code: code, message: message } }
  }

  // Opaque live references. A QML identity Map mints `n<incarnation>.<seq>`
  // per object; the reverse index resolves only currently live objects. A
  // ref from an earlier shell generation cannot match, and an object that
  // left the graph is removed on the shared set's change.
  property var _refs: new Map()
  property var _byRef: Object.create(null)
  property int _refSeq: 0
  readonly property var nodes: Core.PipeWireState.nodes
  readonly property bool graphReady: Core.PipeWireState.graphReady

  function _reconcileRefs() {
    const live = new Map()
    const byRef = Object.create(null)
    const list = root.nodes || []
    for (let i = 0; i < list.length; i++) {
      const node = list[i]
      if (node === null || node === undefined) continue
      let ref = root._refs.get(node)
      if (typeof ref !== "string") {
        root._refSeq++
        ref = "n" + IpcRouter.incarnation + "." + root._refSeq
      }
      live.set(node, ref)
      byRef[ref] = node
    }
    root._refs = live
    root._byRef = byRef
    // A route whose object just left the graph has no live destination.
    if (root._routeSlot !== null && !live.has(root._routeSlot.node)) {
      root._finishRoute(false, "not-found")
    }
  }

  Connections {
    target: Core.PipeWireState
    function onNodesChanged() { root._reconcileRefs() }
  }

  function _refOf(node) {
    const ref = root._refs.get(node)
    return typeof ref === "string" ? ref : ""
  }

  // Resolve one ref against the live set. `kind` may be null for "any audio
  // node"; `stream` restricts to application streams; `device` to devices.
  function _resolve(ref, kind, stream, device) {
    if (!root.graphReady) return { error: "unavailable" }
    if (typeof ref !== "string" || ref === "") return { error: "invalid-argument" }
    const node = root._byRef[ref]
    if (node === null || node === undefined || !root._refs.has(node)) return { error: "not-found" }
    const actual = Kind.classify(node)
    if (actual === null || !Kind.isDeviceKind(actual) && !Kind.isStreamKind(actual)) {
      return { error: "invalid-argument" }
    }
    if (kind !== null && actual !== kind) return { error: "invalid-argument" }
    if (stream === true && (!Kind.isStreamKind(actual) || !Kind.isApplicationStream(node))) {
      return { error: "invalid-argument" }
    }
    if (device === true && !Kind.isDeviceKind(actual)) return { error: "invalid-argument" }
    let audio = null
    try { audio = node.audio } catch (ignored) { audio = null }
    if (!audio) return { error: "invalid-argument" }
    return { node: node, kind: actual, audio: audio }
  }

  function _table(rows, columns) {
    return _ok(rows, { kind: "table", columns: columns })
  }

  function _devicesTable(isSink) {
    if (!root.graphReady) return _error("unavailable", "graph not ready")
    root._reconcileRefs()
    const rows = []
    const wanted = isSink ? "outputDevice" : "inputDevice"
    const effective = isSink ? root.sink : root.source
    const configured = isSink ? Pipewire.preferredDefaultAudioSink : Pipewire.preferredDefaultAudioSource
    const list = root.nodes || []
    for (let i = 0; i < list.length; i++) {
      const node = list[i]
      if (!node || !node.audio) continue
      const kind = Kind.classify(node)
      if (kind !== wanted) continue
      const row = Ipc.deviceRow(node, root._refOf(node), kind,
        node === effective, node === configured)
      if (row !== null) rows.push(row)
    }
    return _table(Ipc.sortRows(rows), [
      { key: "id", heading: "ID" }, { key: "name", heading: "Name" },
      { key: "direction", heading: "Direction" }, { key: "virtual", heading: "Virtual" },
      { key: "monitor", heading: "Monitor" }, { key: "default", heading: "Default" },
      { key: "configuredDefault", heading: "Configured" },
      { key: "percent", heading: "Percent" }, { key: "muted", heading: "Muted" }
    ])
  }

  function _appsTable() {
    if (!root.graphReady) return _error("unavailable", "graph not ready")
    root._reconcileRefs()
    const rows = []
    const list = root.nodes || []
    for (let i = 0; i < list.length; i++) {
      const node = list[i]
      if (!node || !node.audio || !Kind.isApplicationStream(node)) continue
      const kind = Kind.classify(node)
      const row = Ipc.appRow(node, root._refOf(node), kind)
      if (row !== null) rows.push(row)
    }
    return _table(Ipc.sortRows(rows), [
      { key: "id", heading: "ID" }, { key: "name", heading: "Name" },
      { key: "app", heading: "App" }, { key: "direction", heading: "Direction" },
      { key: "percent", heading: "Percent" }, { key: "muted", heading: "Muted" }
    ])
  }

  function _adjust(isSink, sign, stepArg) {
    const frac = Ipc.stepFraction(stepArg, root.step)
    if (frac === null) return _error("invalid-argument", "step must be 1-200")
    const device = isSink ? root.sink : root.source
    if (!device || !device.audio) return _error("unavailable", "device not ready")
    const answer = root._ipcAdjust(isSink, sign, false, frac)
    if (answer !== "ok") return _error("unavailable", "device not ready")
    return _ok()
  }

  // Read-only level projection: the default device's own audio object is
  // read through the existing level adapter. No write, no OSD and no
  // controller demand.
  function _getLevel(isSink) {
    const device = isSink ? root.sink : root.source
    if (!device || !device.audio) return _error("unavailable", "device not ready")
    return _ok(Ipc.levelOf(device), { kind: "record" })
  }

  function _toggleMute(isSink) {
    const device = isSink ? root.sink : root.source
    if (!device || !device.audio) return _error("unavailable", "device not ready")
    if (isSink) root.toggleSinkMute()
    else root.toggleSourceMute()
    return _ok()
  }

  // Absolute percent. The source branch mirrors setSinkPercent: its own cap,
  // its own unmute-on-positive and its own OSD, and it never touches the sink.
  function _setPercent(isSink, n) {
    const p = Math.round(Number(n))
    if (!isFinite(p) || p < 0 || p > 200) return _error("invalid-argument", "level must be 0-200")
    const device = isSink ? root.sink : root.source
    if (!device || !device.audio) return _error("unavailable", "device not ready")
    if (isSink) {
      root.setSinkVolume(Range.clamp(p / 100, 0, root.maxVolume))
      if (p === 0) root.setSinkMuted(true)
      else if (device.audio.muted) root.setSinkMuted(false)
      root._showSinkOSD()
    } else {
      root.setSourceVolume(Range.clamp(p / 100, 0, root.maxSourceVolume))
      if (p === 0) root.setSourceMuted(true)
      else if (device.audio.muted) root.setSourceMuted(false)
      root._showSourceOSD()
    }
    return _ok()
  }

  function _setDefault(isSink, ref) {
    const found = _resolve(ref, isSink ? "outputDevice" : "inputDevice", false, true)
    if (found.error) return _error(found.error, "device not usable")
    const pref = isSink ? Pipewire.preferredDefaultAudioSink : Pipewire.preferredDefaultAudioSource
    if (pref === found.node) return _ok()
    const changed = isSink
      ? Core.PipeWireState.setDefaultSink(found.node)
      : Core.PipeWireState.setDefaultSource(found.node)
    if (!changed) return _error("unavailable", "default device could not be set")
    return _ok()
  }

  function _streamSet(ref, n, mute) {
    const found = _resolve(ref, null, true, false)
    if (found.error) return _error(found.error, "stream not usable")
    if (mute === null) {
      const p = Math.round(Number(n))
      if (!isFinite(p) || p < 0 || p > 150) return _error("invalid-argument", "level must be 0-150")
      // The slider's own rule: clamp to 150%, lift mute on a positive write,
      // and keep an explicit mute at zero.
      Kind.applyVolume(found.audio, p / 100, 1.5)
    } else {
      found.audio.muted = mute === true
    }
    return _ok()
  }

  // --- one outstanding route slot ---
  property var _routeSlot: null
  property var _routeHistory: []
  property int _routeSeq: 0
  readonly property int routeTerminalLimit: 8
  readonly property int routeTerminalTtlMs: 60000
  readonly property int routeDeadlineMs: 12000

  Timer {
    id: routeDeadline
    interval: root.routeDeadlineMs
    repeat: false
    onTriggered: {
      if (root._routeSlot !== null) root._finishRoute(false, "timeout")
    }
  }

  function _finishRoute(ok, code) {
    const slot = root._routeSlot
    if (slot === null) return
    root._routeSlot = null
    routeDeadline.stop()
    const now = Date.now()
    const rows = root._routeHistory.filter(function (r) {
      return now - r.at < root.routeTerminalTtlMs
    })
    rows.unshift({ id: slot.id, state: ok === true ? "done" : "failed",
      code: ok === true ? null : (code || "backend"), at: now })
    root._routeHistory = rows.slice(0, root.routeTerminalLimit)
  }

  function _streamRoute(ref, deviceRef, verbose) {
    if (root._routeSlot !== null) return _error("busy", "a route is already pending")
    const found = _resolve(ref, null, true, false)
    if (found.error) return _error(found.error, "stream not usable")
    const target = _resolve(deviceRef, null, false, true)
    if (target.error) return _error(target.error, "device not usable")
    const capture = found.kind === "captureStream"
    const needed = capture ? "inputDevice" : "outputDevice"
    if (target.kind !== needed) return _error("invalid-argument", "wrong device direction")
    if (Kind.monitor(target.node)) return _error("invalid-argument", "monitor is not a route target")
    // The UI's own move and a routing read in flight both mean the slot may
    // not start yet. Ask the facade before accepting anything.
    const busy = Registry.call("audioMixer", "routeBusy")
    if (busy === true) return _error("busy", "mixer routing is busy")

    root._routeSeq++
    const id = "r" + IpcRouter.incarnation + "." + root._routeSeq
    root._routeSlot = { id: id, node: found.node, device: target.node, at: Date.now() }
    routeDeadline.restart()
    let accepted = false
    try {
      // One fixed in-process call: the method name and the callback below are
      // constants in this file; neither comes from client argv.
      accepted = Registry.call("audioMixer", "routeFromIpc",
        found.node, target.node, capture, function (ok) {
          if (root._routeSlot === null || root._routeSlot.id !== id) return
          root._finishRoute(ok === true, ok === true ? null : "backend")
        }) === true
    } catch (e) {
      accepted = false
    }
    if (!accepted) {
      root._finishRoute(false, "unavailable")
      return _error("unavailable", "mixer refused the route")
    }
    // The request id used to be minted and dropped, leaving no way to poll the
    // one outstanding slot. It is published only on request so the ordinary
    // order stays silent.
    return verbose === true
      ? _ok({ state: "accepted", requestId: id }, { kind: "record" })
      : _ok()
  }

  function _routeStatus(request) {
    if (typeof request !== "string") return _error("invalid-argument", "request id required")
    if (root._routeSlot !== null && root._routeSlot.id === request) {
      return _ok({ state: "pending", code: null }, { kind: "record" })
    }
    for (let i = 0; i < root._routeHistory.length; i++) {
      if (root._routeHistory[i].id === request) {
        const r = root._routeHistory[i]
        return _ok({ state: r.state, code: r.code }, { kind: "record" })
      }
    }
    return _error("not-found", "unknown route request")
  }

  function _status() {
    return _ok(Ipc.statusFields(root.sinkVolume, root.sinkMuted,
      root.sourceVolume, root.sourceMuted, root.step, root.maxVolume,
      root.maxSourceVolume, root.visualFeedback, root.loopbackEnabled,
      root.loopbackError, root.graphReady,
      root._refOf(root.sink), root._refOf(root.source)), { kind: "record" })
  }

  Component.onCompleted: {
    root._loopbackOwned = Loopback.validPairs(ShellState.section("audio")?.loopbackPairs)
    root._loopbackSeeded = true
    Qt.callLater(() => root._scheduleLoopback())
    // A shell reload has no live route requests; terminal history is memory.
    root._routeHistory = []
    root._routeSlot = null
    root._reconcileRefs()
    Registry.offer("audio", {
      title: "Audio",
      description: "Control volume and microphone levels",
      verbNames: Catalog.topLevelVerbs("audio")
    })
    Registry.register(root.tag, root)
    IpcRouter.register("audio", root, {
      "audio.volume.up": function (a) { return root._adjust(true, 1, a.N) },
      "audio.volume.down": function (a) { return root._adjust(true, -1, a.N) },
      "audio.volume.toggle": function () { return root._toggleMute(true) },
      "audio.volume.get": function () { return root._getLevel(true) },
      "audio.microphone.up": function (a) { return root._adjust(false, 1, a.N) },
      "audio.microphone.down": function (a) { return root._adjust(false, -1, a.N) },
      "audio.microphone.toggle": function () { return root._toggleMute(false) },
      "audio.microphone.get": function () { return root._getLevel(false) },
      "audio.volume.set": function (a) { return root._setPercent(true, a.N) },
      "audio.microphone.set": function (a) { return root._setPercent(false, a.N) },
      "audio.sink.list": function () { return root._devicesTable(true) },
      "audio.source.list": function () { return root._devicesTable(false) },
      "audio.sink.set": function (a) { return root._setDefault(true, a.ID) },
      "audio.source.set": function (a) { return root._setDefault(false, a.ID) },
      "audio.stream.list": function () { return root._appsTable() },
      "audio.stream.set": function (a) { return root._streamSet(a.ID, a.N, null) },
      "audio.stream.mute": function (a) { return root._streamSet(a.ID, null, a.BOOL) },
      "audio.stream.route": function (a, c) {
        return root._streamRoute(a.ID, a.DEVICE, c.words.indexOf("verbose") >= 0)
      },
      "audio.stream.route-status": function (a) { return root._routeStatus(a.REQUEST) },
      "audio.status": function () { return root._status() },
      "audio.ping": function () { return _ok("pong", { kind: "text" }) }
    })
  }
  Component.onDestruction: {
    IpcRouter.unregister("audio", root)
    ProcessRegistry.cancelOwner(root.loopbackOwner)
    Registry.unregister(root.tag)
  }

  // Shared adjust path. `quiet` suppresses the OSD for this call only, and an
  // explicit step (a validated fraction) overrides the configured one without
  // changing that setting. The gateway validates the `step` keyword before
  // arriving here; a missing device is still a refusal.
  //
  // The rule belongs to adjustSink/adjustSource. This function only translates
  // the device check and the verb's verdict; even the quiet branch calls the
  // same primitive, without OSD, instead of restating clamp/mute/fade here.
  function _ipcAdjust(isSink, sign, quiet, explicitStep) {
    const device = isSink ? root.sink : root.source
    if (!device || !device.audio) return "error: no device"
    const amount = explicitStep === undefined || explicitStep === null ? root.step : explicitStep
    const d = sign * amount
    if (isSink) {
      if (quiet) root.setSinkVolume(root.sinkVolume + d)
      else root.adjustSink(d)
    } else {
      if (quiet) root.setSourceVolume(root.sourceVolume + d)
      else root.adjustSource(d)
    }
    return "ok"
  }
}
