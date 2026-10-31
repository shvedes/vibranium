pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import qs.services as Core
import "../../common/text/UnitIpc.js" as UnitIpc
import "../../common/audio/AudioLoopback.js" as Loopback
import "../../common/theme/DeviceIcons.js" as DeviceIcons

// Audio service: volume and microphone policy for the whole shell.
// Binds Pipewire's default sink/source through the one PipeWire state owner
// (audio/PipeWireState) - no wpctl, no bash shims, no child processes, and no
// tracker of its own. Owns step/max/mute policy, the OSD triggers, and the
// `qs ipc call audio ...` surface. The bar widgets and the island delegate
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
    root._fadeDur = Math.min(900, Math.max(150, 150 + 500 * span))
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

  function _readLoopbackPorts(generation) {
    const results = { outputs: null, inputs: null, links: null, pending: 3 }
    const adopt = (key, result) => {
      results[key] = result
      results.pending--
      if (results.pending !== 0) return
      if (generation !== root._loopbackGeneration) {
        root._loopbackBusy = false
        root._scheduleLoopback()
        return
      }
      if (results.outputs?.code !== "ok" || results.inputs?.code !== "ok"
        || results.links?.code !== "ok") {
        root._loopbackBusy = false
        root._loopbackError = "could not read default audio ports or links"
        return
      }
      const plan = Loopback.plan(root._loopbackSourceName, root._loopbackSinkName,
        String(results.outputs.stdout || ""), String(results.inputs.stdout || ""))
      if (plan.error !== "") {
        root._loopbackBusy = false
        root._loopbackError = plan.error
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
      if (generation !== root._loopbackGeneration) {
        root._loopbackBusy = false
        root._scheduleLoopback()
        return
      }
      if (result === null || result === undefined || result.code !== "ok") {
        root._loopbackBusy = false
        root._loopbackError = "could not read current audio links"
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
      root._loopbackBusy = false
      root._loopbackError = connection.error
      return
    }
    root._loopbackRemovals = removals
    root._loopbackCommands = connection.steps
    root._loopbackDesired = desired
    root._sendNextLoopbackRemoval(desired, generation)
  }

  function _sendNextLoopbackRemoval(desired, generation) {
    if (generation !== root._loopbackGeneration) {
      root._loopbackBusy = false
      root._scheduleLoopback()
      return
    }
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
          root._loopbackBusy = false
          root._loopbackError = "pw-link refused to remove the loopback route"
          return
        }
        root._loopbackOwned = Loopback.removeFromOwned(root._loopbackOwned, command)
        ShellState.updateSection("audio", { loopbackPairs: Loopback.persistableRoutes(root._loopbackOwned) })
        root._sendNextLoopbackRemoval(desired, generation)
      }
    })
    if (job === null || job === undefined) {
      root._loopbackBusy = false
      root._loopbackError = "could not start pw-link"
    }
  }

  function _sendNextLoopbackCommand(desired, generation) {
    if (generation !== root._loopbackGeneration) {
      root._loopbackBusy = false
      root._scheduleLoopback()
      return
    }
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
          root._loopbackBusy = false
          root._loopbackError = "pw-link refused to create the loopback route"
          return
        }
        root._loopbackOwned = Loopback.addOwned(root._loopbackOwned, root._loopbackDesired, command)
        ShellState.updateSection("audio", { loopbackPairs: Loopback.persistableRoutes(root._loopbackOwned) })
        root._sendNextLoopbackCommand(desired, generation)
      }
    })
    if (job === null || job === undefined) {
      root._loopbackBusy = false
      root._loopbackError = "could not start pw-link"
    }
  }

  function _finishLoopback(desired, generation) {
    if (generation !== root._loopbackGeneration) {
      root._loopbackBusy = false
      root._scheduleLoopback()
      return
    }
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
    Exec.run(["notify-send", "-a", "Vibranium", "-u", "normal", "-r", "2", "-t", "8000",
      "Audio", what + ": " + reason])
  }

  // --- actions ---

  function setSinkVolume(v) {
    if (!root.sink || !root.sink.audio) return
    root._cancelFade("set-volume")
    root.sink.audio.volume = Math.max(0, Math.min(root.maxVolume, v))
  }

  function setSourceVolume(v) {
    if (!root.source || !root.source.audio) return
    root.source.audio.volume = Math.max(0, Math.min(root.maxSourceVolume, v))
  }

  function adjustSink(delta) {
    if (!root.sink || !root.sink.audio) return
    root._cancelFade("adjust")
    if (root.sink.audio.muted && delta > 0) root.sink.audio.muted = false
    const next = root.sink.audio.volume + delta
    // Clamp like bash: beyond the cap snaps to the cap instead of refusing.
    root.sink.audio.volume = Math.max(0, Math.min(root.maxVolume, next))
    root._showSinkOSD()
  }

  function adjustSource(delta) {
    if (!root.source || !root.source.audio) return
    if (root.source.audio.muted && delta > 0) root.source.audio.muted = false
    const next = root.source.audio.volume + delta
    root.source.audio.volume = Math.max(0, Math.min(root.maxSourceVolume, next))
    root._showSourceOSD()
  }

  function toggleSinkMute() {
    if (!root.sink || !root.sink.audio) return
    root.sink.audio.muted = !root.sink.audio.muted
    root._showSinkOSD()
  }

  function toggleSourceMute() {
    if (!root.source || !root.source.audio) return
    root.source.audio.muted = !root.source.audio.muted
    root._showSourceOSD()
  }

  // Absolute set in percent. 0 also mutes (bash set_volume parity);
  // any other value unmutes.
  function setSinkPercent(pct) {
    const p = Math.round(Number(pct))
    if (!(p >= 0) || !(p <= 200)) return
    if (!root.sink || !root.sink.audio) return
    root._cancelFade("set-percent")
    if (p === 0) {
      root.sink.audio.volume = 0
      root.sink.audio.muted = true
    } else {
      root.sink.audio.volume = Math.min(root.maxVolume, p / 100)
      root.sink.audio.muted = false
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

  function _sinkBar() {
    return Math.max(0, Math.min(100, Math.round(root.sinkVolume / root.maxVolume * 100)))
  }

  function _sourceBar() {
    return Math.max(0, Math.min(100, Math.round(root.sourceVolume / root.maxSourceVolume * 100)))
  }

  function _sinkIcon() {
    return root.volumeIconFor(root.sinkVolume, root.sinkMuted)
  }

  function _showSinkOSD() {
    if (!root.visualFeedback) return
    Registry.call("osd", "show", "volume", root._sinkBar(), "", root._sinkIcon(), root.sinkMuted)
  }

  function _showSourceOSD() {
    if (!root.visualFeedback) return
    Registry.call("osd", "show", "microphone", root._sourceBar(), "",
      root.sourceMuted ? "mic-off" : "mic-on", root.sourceMuted)
  }

  Component.onCompleted: {
    root._loopbackOwned = Loopback.validPairs(ShellState.section("audio")?.loopbackPairs)
    root._loopbackSeeded = true
    Qt.callLater(() => root._scheduleLoopback())
    Registry.offer("audio", {
      title: "Audio",
      description: "volume + microphone with OSD feedback",
      verbNames: [
        "micdown",
        "mictoggle",
        "micup",
        "set",
        "voldown",
        "voltoggle",
        "volup",
        "status",
        "help",
        "ping",
      ]
    })
    Registry.register(root.tag, root)
  }
  Component.onDestruction: {
    ProcessRegistry.cancelOwner(root.loopbackOwner)
    Registry.unregister(root.tag)
  }

  IpcHandler {
    target: "audio"
    function help(command: string): string {
      return UnitIpc.help("audio", "Audio", "volume + microphone with OSD feedback", [
        { name: "micdown", help: "lower mic volume" },
        { name: "mictoggle", help: "mute/unmute mic" },
        { name: "micup", help: "raise mic volume" },
        { name: "set", help: "(value) set volume 0-100" },
        { name: "voldown", help: "lower volume" },
        { name: "voltoggle", help: "mute/unmute output" },
        { name: "volup", help: "raise volume" },
      ], command)
    }
    function ping(): string { return "pong" }

    // Zero-arg verbs: the generic `vb-shell <target> <fn>` passthrough must
    // pass every declared parameter, so external callers read
    // `vb-shell audio volup` with no required args.
    function volup(): string {
      return root._ipcAdjust(true, 1, false)
    }

    function voldown(): string {
      return root._ipcAdjust(true, -1, false)
    }

    function voltoggle(): string {
      root.toggleSinkMute()
      return "ok"
    }

    function micup(): string {
      return root._ipcAdjust(false, 1, false)
    }

    function micdown(): string {
      return root._ipcAdjust(false, -1, false)
    }

    function mictoggle(): string {
      root.toggleSourceMute()
      return "ok"
    }

    // Absolute sink volume in percent (0 also mutes, per bash parity).
    function set(value: string): string {
      const p = Math.round(Number(value))
      if (isNaN(p) || p < 0 || p > 200) return "error: invalid volume"
      root.setSinkPercent(p)
      return "ok"
    }

    function status(): string {
      return JSON.stringify({
        sinkVolume: root.sinkVolume,
        sinkMuted: root.sinkMuted,
        sourceVolume: root.sourceVolume,
        sourceMuted: root.sourceMuted,
        step: root.step,
        maxVolume: root.maxVolume,
        maxSourceVolume: root.maxSourceVolume,
        visualFeedback: root.visualFeedback,
        loopbackEnabled: root.loopbackEnabled,
        loopbackError: root.loopbackError
      })
    }
  }

  // Shared IPC adjust path. `quiet` suppresses the OSD for this call only.
  //
  // A missing device is a refusal and answers "error: no device" to the
  // caller: this is the path a volume keypress and `qs ipc call audio volup`
  // both take, and it is the only one in this file whose failure is a return
  // value rather than a silent no-op.
  function _ipcAdjust(isSink, sign, quiet) {
    const device = isSink ? root.sink : root.source
    if (!device || !device.audio) return "error: no device"
    const d = sign * root.step
    if (isSink) {
      root._cancelFade("ipc-adjust")
      if (root.sinkMuted && sign > 0) root.sink.audio.muted = false
      root.sink.audio.volume = Math.max(0, Math.min(root.maxVolume, root.sinkVolume + d))
      if (!quiet) root._showSinkOSD()
    } else {
      if (root.sourceMuted && sign > 0) root.source.audio.muted = false
      root.source.audio.volume = Math.max(0, Math.min(root.maxSourceVolume, root.sourceVolume + d))
      if (!quiet) root._showSourceOSD()
    }
    return "ok"
  }
}
