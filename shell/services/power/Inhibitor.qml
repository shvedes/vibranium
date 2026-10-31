pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.common
import "../../common/process/CommandSpec.js" as CommandSpec
import "../../common/process/ProcProbe.js" as ProcProbe
import "../../common/text/Format.js" as Format
import "../../common/text/UnitIpc.js" as UnitIpc
// Idle + sleep inhibitor backed by org.freedesktop.login1. The Inhibit()
// call returns a Unix file descriptor — closing it releases the lock —
// so the busctl process must stay alive while the inhibitor is active.
// State is in-memory only (`active`): the menu pill reads this
// singleton directly via Menu.isToggleOn, and the lock itself dies
// with the shell, so a persisted flag could only ever lie.
//
// This singleton also owns the two inhibition registries a consumer has
// to consult. The logind one watches login1 bus signals (PropertiesChanged
// fires on every inhibition-state change) and re-reads ListInhibitors when
// one lands, exposing which apps currently block sleep/lock. The second is
// the screensaver interface on the session bus, which is where a video
// player asks to be left alone: it is a signal stream rather than a
// queryable registry, so it is counted (see the source's own section).
// Consumers (IdleDaemon guards, Lockscreen caffeine notice) read those
// registries instead of tracking our own Caffeine module, so every app
// holding a lock shows up - ours or not.
//
// Child process lifetime is owned here rather than left to a bare
// Process or a detached spawn:
//
//   inhibit  a long-lived registry-owned ProcessJob that holds the
//            login1 descriptor, so it takes no deadline and no retry
//   list     one bounded registry-owned ProcessJob per readback
//   reap     one bounded registry-owned ProcessJob for orphan cleanup
//
// The two bus monitors are the children that cannot be jobs: they stream
// signal lines for the life of the session and a job only reports a
// finished buffer, so they stay owned Processes with a SplitParser. Each
// of the five paths carries a RequestGate generation, so a child or a
// stream callback that outlives the request that started it becomes a
// no-op instead of a race. The generation is always retired before the
// child is stopped, because a cancel reports its terminal transition
// synchronously and that callback has to find a stale generation.
//
// Desired state and held state stay separate. `active` is user intent and
// is what the bus topic, the menu row, and the idle guards read; `held` is
// the local truth about a live child. A child that cannot start (no
// systemd-inhibit, no system bus) leaves the intent alone and reports
// `degraded`, so a lock that is not actually held never reads as an
// active one and never respawns without a bounded backoff.
Singleton {
  id: root

  readonly property string tag: "inhibitor"

  property bool active: false

  // Stepped targets in seconds; 0 is the infinite tail. cycleIndex -1
  // means idle (no lock). remaining counts down for finite targets.
  readonly property var durations: [300, 600, 900, 1800, 0]
  property int cycleIndex: -1
  property int targetSec: 0
  property int remaining: 0
  property double deadlineMs: 0
  readonly property bool infinite: root.active && root.targetSec === 0
  // Fresh-computed copy of the formatted readout for synchronous readers
  // (bus publish): the `formatted` binding below re-evaluates after signal
  // handlers run, so a publish that reads the binding carries the previous
  // tick's text. Computing from the primitives here keeps every publish
  // current, so a target switch paints instantly instead of lagging a tick.
  function currentFormatted() {
    if (!root.active || root.infinite) return ""
    const s = Math.max(0, root.remaining)
    const m = Math.floor(s / 60)
    const r = s % 60
    return m + ":" + Format.pad2(r)  }
  readonly property string formatted: root.currentFormatted()

  // A refusal is a caller mistake rather than a state change: a negative or
  // non-numeric target never reaches the daemon, so a verb that answered
  // "ok" for it would be claiming a lock nobody asked for.
  function start(seconds) {
    const secs = Math.floor(Number(seconds))
    if (!(secs >= 0)) return false
    const idx = root.durations.indexOf(secs)
    root.cycleIndex = idx >= 0 ? idx : (secs === 0 ? 4 : root.cycleIndex)
    root.targetSec = secs
    if (secs === 0) {
      root.remaining = 0
      root.deadlineMs = 0
    } else {
      root.remaining = secs
      root.deadlineMs = Date.now() + secs * 1000
    }
    if (!root.active) {
      root.active = true
      root._applyInhibit()
    }
    // Restart the ticker so the new deadline counts from this exact
    // moment: assigning running=true while already running would keep
    // the old schedule and the first decrement could land early.
    if (secs > 0) tickTimer.restart()
    else tickTimer.stop()
    root._publish()
    _toggleTimer.restart()
    return true
  }

  // `reason` is how an expiry is told from a release. The countdown calls
  // this with "expired" and every other caller takes the default, because a
  // timed lock that ends on its own and a lock the user released are the same
  // two words in `active` and different things to whoever is watching.
  function stop(reason) {
    if (!root.active) return false
    root.active = false
    root.targetSec = 0
    root.remaining = 0
    root.deadlineMs = 0
    tickTimer.running = false
    root._applyInhibit()
    root._publish()
    _toggleTimer.restart()
    return true
  }

  function cycleForward() {
    // Forward from the infinite tail releases the lock instead of
    // wrapping to 5 min: the bar left click doubles as the disable
    // path while infinite is on (middle click still stops from anywhere).
    if (root.active && root.infinite) return root.stop()
    const next = root.active ? (root.cycleIndex + 1) % root.durations.length : 0
    return root.start(root.durations[next])
  }

  function cycleBackward() {
    // Backward from the 5 min head releases the lock instead of wrapping
    // to Infinite: off sits on both ends (forward from Infinite stops,
    // backward from 5 min stops), so neither direction wraps past it.
    if (root.active && root.cycleIndex <= 0) return root.stop()
    const next = root.active ? (root.cycleIndex - 1 + root.durations.length) % root.durations.length : root.durations.length - 1
    return root.start(root.durations[next])
  }

  function toggle() {
    if (root.active) return root.stop()
    const idx = root.cycleIndex >= 0 ? root.cycleIndex : 0
    return root.start(root.durations[idx])
  }

  function isActive(): bool {
    return root.active
  }

  // Authoritative guards: local intent (synchronous) OR a foreign
  // block lock from either registry. Idle timers consult these, never
  // the raw lists, so a toggle or a dead child never opens a window.
  //
  // A media player asking the screensaver interface to stand down is a
  // block lock for both actions: a video player holds that inhibit for
  // the length of the video, and the point of the request is that the
  // session stays untouched until playback ends.
  function sleepBlocked() {
    if (root.active || root.screenSaverBlocked) return true
    return root.sleepBlockers.length > 0
  }
  function idleBlocked() {
    if (root.active || root.screenSaverBlocked) return true
    return root.idleBlockers.length > 0
  }

  // Bar-module mirror surface: the features/bar/modules/Caffeine module
  // re-sources its state from this topic (Bus.latest replays it on
  // creation, so a late-loading module is correct on frame one). The
  // shell.statusbar.caffeineEnabled visibility toggle is NOT part of the
  // payload - the module binds it reactively from Settings, so a toggle
  // while caffeine is active updates the icon immediately.
  function _publish() {
    Bus.publish("inhibitor.bus", {
      active: root.active,
      remaining: root.remaining,
      targetSec: root.targetSec,
      infinite: root.infinite,
      formatted: root.currentFormatted()
    })
  }
  onActiveChanged: root._publish()
  onRemainingChanged: root._publish()
  onTargetSecChanged: root._publish()

  // --- IPC ---

  IpcHandler {
    target: "inhibitor"
    function help(command: string): string {
      return UnitIpc.help("inhibitor", "Inhibitor", "caffeine-style idle + sleep inhibit", [
        { name: "isActive", help: "is an inhibit active?" },
        { name: "toggle", help: "engage/release the inhibit" },
        { name: "start", help: "(seconds, 0 = infinite) start a timed inhibit" },
        { name: "stop", help: "release the inhibit" },
        { name: "cycleForward", help: "step to the next duration" },
        { name: "cycleBackward", help: "step to the previous duration" },
      ], command)
    }
    function status(): string {
      // The two sources are reported apart: "healthy" is the caffeine
      // lock's own claim, and a dark screensaver source costs a player's
      // inhibit, not that lock.
      return JSON.stringify({
        unit: "inhibitor",
        healthy: !root.inhibitDegraded,
        active: root.active,
        held: root.held,
        registryDegraded: root.registryDegraded,
        screenSaverBlocked: root.screenSaverBlocked,
        screenSaverDegraded: root.screenSaverDegraded
      })
    }
    function ping(): string { return "pong" }
    // No verb acts on its own here. The intent moves in start()/stop(), the one
    // place `active` actually changes, because the three user surfaces do not
    // all arrive through IpcHandler: the bar module calls these same root
    // functions through Registry.call and the menu row calls root.stop()
    // directly from its confirm closure. `error` is still returned for a verb
    // that changed nothing - a stop with no lock, a start with a target that
    // is not a duration.
    function toggle(): string {
      // Always reports: toggle() is stop() when active and start() when not,
      // so there is no outcome in which it leaves the state alone. It calls the
      // two root functions rather than the verbs above, which is why this is
      // one line and not two.
      root.toggle()
      return "ok"
    }
    function start(seconds: string): string {
      if (!root.start(Number(seconds))) return "error"
      return "ok"
    }
    function stop(): string {
      if (!root.stop()) return "error"
      return "ok"
    }
    function cycleForward(): string {
      if (!root.cycleForward()) return "error"
      return "ok"
    }
    function cycleBackward(): string {
      if (!root.cycleBackward()) return "error"
      return "ok"
    }
    function isActive(): bool { return root.isActive() }
  }

  // --- child ownership ---

  // Every asynchronous child is a RequestGate generation plus a
  // registry-owned job. A generation is the only test of currency: a
  // callback that lost its request retires into a no-op instead of
  // racing the request that replaced it. The gate holds no resource of
  // its own, so the generation is retired *before* the child is stopped
  // - cancelling a child reports its terminal transition synchronously
  // and that callback has to find a stale generation.
  readonly property string _gateScope: "inhibitor"
  readonly property string _inhibitKey: "inhibit"
  readonly property string _listKey: "list"
  readonly property string _reapKey: "reap"
  readonly property string _monitorKey: "monitor"
  readonly property string _saKey: "screensaver"

  // Bounded respawn shared by every child that can fail: 1s base, 4x
  // growth, 60s ceiling. A missing binary or a dead bus therefore
  // settles at one attempt a minute instead of spinning, and a recovered
  // child resets the counter so the next failure starts from the fast
  // end again.
  readonly property int _backoffBaseMs: 1000
  readonly property int _backoffCapMs: 60000

  function _backoffMs(fails) {
    return Math.min(root._backoffCapMs, root._backoffBaseMs * Math.pow(4, Math.max(0, fails - 1)))
  }

  function _handle(generation, key) {
    return { id: generation, scope: root._gateScope, key: key }
  }

  // A settled job owns nothing: the registry already released its child
  // and destroys the job itself, so only a live one is cancelled here.
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

  // Liveness of a registry-owned child is its terminal transition: a job the
  // registry has not settled has reported no exit, and a destroyed job cannot
  // be read at all, so an unusable reference reads as no claim rather than as
  // a live child.
  function _jobLive(job) {
    if (job === null || job === undefined) return false
    try {
      return String(job.state) !== "settled"
    } catch (ignored) {
      return false
    }
  }

  // One owned child of `run`, which the caller has already stored. settle
  // is the single terminal callback: the job reports its result, while a
  // command the contract refuses or a job the registry cannot build never
  // spawned and reports nothing, so the caller handles one outcome rather
  // than two. The argv and the bus error are carried in the result and are
  // never written anywhere: an inhibitor holds no secret, but the readback
  // and the lock reason describe the session and have no reader here.
  //
  // A pre-spawn refusal settles with a CODE rather than a bare null, because
  // a bare null is all that would reach the caller: the job's `failed` signal
  // carries why it refused (invalid_argv, an output limit it cannot honour, a
  // spawn that never produced a child) and dropping it on the floor is what
  // made "why was this inhibit refused" unanswerable.
  // The shape is the one every terminal path already hands the callers - a
  // `code` that is not "ok" - so `_listFinished`'s verdict is unchanged and
  // no new branch had to be written for it.
  function _spawn(run, key, spec, settings, settle) {
    const options = Object.assign({}, settings, {
      onFinished: result => settle(result === undefined ? null : result),
      onFailed: reason => settle({
        code: "refused",
        reason: String(reason === undefined || reason === null ? "unknown" : reason),
        refused: true
      })
    })
    if (spec === null || spec === undefined || spec.ok !== true) {
      settle({ code: "refused", reason: "invalid_command", refused: true })
      return false
    }
    let job = null
    try {
      job = ProcessRegistry.start(spec, root._gateScope + ":" + key, options)
    } catch (ignored) {
      job = null
    }
    if (job === null) {
      settle({ code: "refused", reason: "registry_unavailable", refused: true })
      return false
    }
    // A refusal settles the request synchronously, so currency is
    // re-read before the job is recorded as owned by the run.
    if (!RequestGate.current(run.handle)) {
      root._stopJob(job, "stale")
      return false
    }
    run.job = job
    return true
  }

  // --- login1 inhibitor ---

  function _applyInhibit() {
    if (root.active) {
      root._startInhibit()
    } else {
      root._stopInhibit()
    }
  }

  // Local condition of the lock, kept apart from the desired state in
  // `active`:
  //
  //   idle       no child, and none wanted
  //   starting   a child was spawned and is not confirmed yet
  //   held       a live child owns the login1 file descriptor
  //   degraded   a child was wanted and the last attempt failed
  //
  // Leaving `starting` is the one inference in this file: a lock child owns a
  // descriptor for the whole request and reports no exit to confirm it, so a
  // child still running after the confirmation window counts as held. A child
  // that was never spawned cannot report an exit either, which is what the
  // job's own spawn deadline covers. Neither claim is a statement about
  // logind: the registry is the only view of what login1 actually locked.
  property string _inhibitState: "idle"
  property int _inhibitFails: 0
  property var _inhibitRun: null

  // login1 policy, kept in one place because the orphan filter below and
  // the reap pattern both have to name the same lock or a reaped child
  // would not be the row that was identified as an orphan.
  //
  // Idle only, never sleep: an explicit suspend must stay a plain
  // `systemctl suspend` with no bypass flag, and sleep in this list is
  // what would block it. Bypassing would need suspend-ignore-inhibit,
  // which prompts via polkit. The automatic paths stay guarded without
  // it: sleepBlocked() and idleBlocked() read the active intent first,
  // and the registry treats an idle block as a sleep blocker too, since
  // with the idle timers dead the auto-suspend path cannot run either.
  readonly property string _inhibitWhat: "idle"
  readonly property string _inhibitWho: "Vibranium"
  readonly property string _inhibitWhy: "Caffeine mode is active"
  readonly property string _inhibitMode: "block"

  readonly property bool held: root._inhibitState === "held"
  readonly property bool inhibitDegraded: root._inhibitState === "degraded"
  // A lock that could not be taken, or a registry readback that is not
  // current, is degraded: intent is unchanged, so a broken child is
  // visible to a consumer instead of being read as an active lock.
  readonly property bool degraded: root.inhibitDegraded || root.registryDegraded
  readonly property bool registryDegraded: root._listDegraded || root._monitorDegraded
  // The screensaver source is reported apart from the logind registry: a
  // dark session bus costs a player's inhibit, not a caffeine lock, and
  // folding it into `degraded` would put a notice in front of the user
  // about a lock they never asked for.
  readonly property bool screenSaverDegraded: root._saDegraded

  // When the lock was last confirmed held. Zero means the lock was never
  // confirmed.
  property var _heldAt: 0

  // The one writer of `_inhibitState`, so a transition is recorded from the
  // place it happens rather than from each caller that can cause one.
  function _setInhibitState(next: string): void {
    if (root._inhibitState === next) return
    root._inhibitState = next
  }

  // Long-lived by design: the child holds the login1 descriptor until it
  // is killed, so the job carries no deadline and no internal retry. A
  // dead lock is rescheduled here instead, where the desired state and
  // the generation can be checked first, and the respawn waits on a
  // bounded backoff rather than firing on the exit itself.
  function _startInhibit() {
    if (root._inhibitRun !== null) return
    root._retireInhibit("superseded")
    const generation = RequestGate.begin(root._gateScope, root._inhibitKey)
    if (generation === 0) {
      // The gate refused a new generation, so no child was ever asked for.
      root._setInhibitState("degraded")
      return
    }
    const handle = root._handle(generation, root._inhibitKey)
    root._inhibitRun = { handle: handle, job: null }
    root._setInhibitState("starting")
    const spawned = root._spawn(root._inhibitRun, root._inhibitKey, CommandSpec.argv([
      "systemd-inhibit",
      "--what=" + root._inhibitWhat,
      "--who=" + root._inhibitWho,
      "--why=" + root._inhibitWhy,
      "--mode=" + root._inhibitMode,
      "sleep", "infinity"
    ]), {
      timeoutMs: 0,
      maxAttempts: 1,
      spawnWatchdogMs: root._inhibitSpawnWatchMs
    }, result => root._inhibitFinished(handle, result))
    // Only a run that owns a live job can be confirmed: a spawn the spec or
    // the registry refused settles the request inside _spawn, and a timer
    // armed for it would confirm a child that never started.
    if (spawned) _inhibitConfirm.restart()
  }

  function _stopInhibit() {
    _inhibitConfirm.stop()
    _inhibitRetry.stop()
    root._retireInhibit("released")
    root._inhibitFails = 0
    root._setInhibitState("idle")
  }

  // Terminal path of the lock: the generation dies, the run leaves the
  // table, and only a lock that is still wanted schedules the next
  // attempt. The child is gone either way, so the local held claim ends
  // here; a lock that outlived this shell is a registry row instead and
  // is reaped from there.
  //
  // `result` is the child's own terminal record, and carrying it is what
  // turns "the lock is not there" into "the lock is not there BECAUSE". The
  // two are different faults with different fixes: `spawn_failed` is a
  // missing binary or a dead bus on this machine, `nonzero_exit` is logind
  // refusing the lock, and `timeout` is a child that started and never
  // settled.
  function _inhibitFinished(handle, result) {
    if (!RequestGate.current(handle)) return
    RequestGate.invalidate(handle)
    root._inhibitRun = null
    if (!root.active) {
      // The child ended because the lock was asked for no longer, which is
      // the normal release and not a failure. The reason the child carries
      // is still recorded, because `cancelled` and a spontaneous exit are
      // the same state change and only one of them is ours.
      root._setInhibitState("idle")
      return
    }
    root._setInhibitState("degraded")
    root._inhibitFails++
    _inhibitRetry.interval = root._backoffMs(root._inhibitFails)
    _inhibitRetry.restart()
  }

  // Every release of the lock passes here, from the four callers and the
  // teardown alike, so this is the one place the release happens. It reports
  // `held=yes|no` rather than only that a child was killed, because killing a
  // child that never confirmed is the case that looks identical from the
  // outside and means the user never had a lock at all.
  function _retireInhibit(reason) {
    RequestGate.invalidateScope(root._gateScope, root._inhibitKey)
    const run = root._inhibitRun
    if (run === null) return false
    root._inhibitRun = null
    root._heldAt = 0
    root._stopJob(run.job, reason)
    return true
  }

  // --- logind inhibitor registry (dbus) ---
  //
  // Mirror of org.freedesktop.login1.ListInhibitors: rows of
  // {what, who, why, mode}. Refreshed reactively from the login1
  // signal monitor below, plus on every caffeine toggle and on demand
  // (lockscreen show).
  property var inhibitors: []

  // Block-mode locks that keep automatic sleep away: anything covering
  // "sleep" (a real suspend lock) or "idle" (our caffeine lock - with
  // the idle timers dead the auto-suspend path cannot run either).
  // Delay-mode locks (NetworkManager, UPower...) only buy a few seconds
  // before suspend, so they never count here.
  readonly property var sleepBlockers: root.inhibitors.filter(
    i => i.mode === "block" && (i.what.includes("sleep") || i.what.includes("idle")))

  // Block-mode locks covering "idle" - read by the auto-lock guard.
  readonly property var idleBlockers: root.inhibitors.filter(
    i => i.mode === "block" && i.what.includes("idle"))

  property int _listFails: 0
  property bool _listDegraded: false
  property var _listRun: null

  // One-shot busctl readback. --json=short returns
  // {"type":"a(ssssuu)","data":[[[what,who,why,mode,uid,pid],...]]}.
  // Every refresh is its own request: a newer one retires the older
  // generation and its child, so the applied list is never the answer to
  // a superseded question. An explicit refresh (a toggle, the lockscreen)
  // also clears a pending backoff, so user intent never has to wait out a
  // failure window.
  //
  // This is the shell's only read of a persisted-ish thing: there is no cache
  // and no state file (the lock dies with the shell, so a persisted flag could
  // only lie), and the registry is the one round trip whose answer other code
  // depends on.
  function refresh(cause) {
    _listRetry.stop()
    root._retireList("superseded")
    const generation = RequestGate.begin(root._gateScope, root._listKey)
    if (generation === 0) {
      root._degradeList()
      return
    }
    const handle = root._handle(generation, root._listKey)
    const run = { handle: handle, job: null }
    root._listRun = run
    root._spawn(run, root._listKey, CommandSpec.argv([
      "busctl", "call", "--json=short",
      "org.freedesktop.login1", "/org/freedesktop/login1",
      "org.freedesktop.login1.Manager", "ListInhibitors"
    ]), {
      timeoutMs: root._listTimeoutMs
    }, result => root._listFinished(handle, result))
  }

  // Terminal path of a readback. A failed or unparseable answer leaves
  // the previous list standing - a busctl hiccup must not flash the
  // lockscreen notice off and on - and backs the next attempt off. The
  // readback counts as current only once a real list was applied.
  //
  // The reply is never printed. It is every inhibitor on the machine
  // including the pids, and the count is the answer the guards actually
  // act on.
  function _listFinished(handle, result) {
    if (!RequestGate.current(handle)) return
    RequestGate.invalidate(handle)
    root._listRun = null
    if (result === null || result === undefined || result.code !== "ok") {
      root._degradeList()
      return
    }
    const output = result.stdout === undefined || result.stdout === null ? "" : String(result.stdout)
    if (!root._applyList(output)) {
      // A well-formed child whose output is not the pinned shape: the
      // transport worked and the answer is unusable, which is a different
      // fault from a failed readback.
      root._degradeList()
      return
    }
    root._listFails = 0
    root._listDegraded = false
  }

  function _degradeList() {
    // A stale list is not a cosmetic fault: the idle and lockscreen guards
    // read it, so a foreign block lock nobody can see is a session that can
    // be suspended or locked under an app that asked not to be. The
    // previous list is deliberately left standing, so the fault is only
    // visible in `registryDegraded`.
    root._listDegraded = true
    root._listFails++
    _listRetry.interval = root._backoffMs(root._listFails)
    _listRetry.restart()
  }

  function _retireList(reason) {
    RequestGate.invalidateScope(root._gateScope, root._listKey)
    const run = root._listRun
    if (run === null) return false
    root._listRun = null
    root._stopJob(run.job, reason)
    return true
  }

  // Returns whether the reply was applied. A reply that is not the pinned
  // shape is a transport failure, not an empty registry: reporting an
  // empty inhibitor list would drop every foreign lock the guards read.
  function _applyList(output) {
    let rows
    try {
      const reply = JSON.parse(output)
      const data = reply && reply.data
      rows = Array.isArray(data) && data.length > 0 && Array.isArray(data[0])
        ? data[0] : []
    } catch (e) {
      // Transient failure (busctl hiccup, logind gone) - keep the
      // previous list rather than flashing the notice off and on.
      return false
    }
    root.inhibitors = rows.map(r => ({
      what: String(r[0] ?? ""),
      who: String(r[1] ?? ""),
      why: String(r[2] ?? ""),
      mode: String(r[3] ?? "")
    }))
    root._reapOrphans()
    return true
  }

  // Self-heal: if quickshell crashed while caffeine was on, the
  // systemd-inhibit child outlives it and keeps holding the lock while
  // the fresh instance's root.active is false. The registry makes the
  // orphan visible - kill it so the lock always matches in-memory state.
  // No-op (cheap filter) on every normal refresh.
  //
  // Gated on the desired state and never on `held`: while caffeine is
  // wanted, a live child of our own is exactly what the pattern matches,
  // so reaping on the held claim would let a readback kill the lock the
  // user just asked for.
  //
  // The kill is a bounded owned job rather than a detached one, because a
  // detached child outlives the shell and its owner and nothing can
  // report or clean it up afterwards. A reap that fails is not a service
  // failure: the orphan row stays visible and the next readback tries
  // again, so it carries no backoff of its own.
  property var _reapRun: null

  function _reapOrphans() {
    if (root.active) return
    const orphans = root.inhibitors.filter(
      i => i.who === root._inhibitWho && i.why === root._inhibitWhy && i.mode === root._inhibitMode)
    if (orphans.length === 0) return
    root._retireReap("superseded")
    const generation = RequestGate.begin(root._gateScope, root._reapKey)
    if (generation === 0) return
    const handle = root._handle(generation, root._reapKey)
    const run = { handle: handle, job: null }
    root._reapRun = run
    // An orphan is a lock this shell's predecessor took and never gave back,
    // so this is the crash report for a session that ended while caffeine was
    // on. The rows the pattern matched are the whole of what is known: the
    // pids in them are never read here.
    root._spawn(run, root._reapKey, CommandSpec.argv([
      "pkill", "-f", "systemd-inhibit.*" + root._inhibitWho + ".*" + root._inhibitWhy
    ]), {
      timeoutMs: root._reapTimeoutMs
    }, result => {
      // Currency first: a cancelled reap reports synchronously, and
      // without this it would clear the run record of its replacement.
      if (!RequestGate.current(handle)) return
      RequestGate.invalidate(handle)
      root._reapRun = null
    })
  }

  function _retireReap(reason) {
    RequestGate.invalidateScope(root._gateScope, root._reapKey)
    const run = root._reapRun
    if (run === null) return false
    root._reapRun = null
    root._stopJob(run.job, reason)
    return true
  }

  // --- login1 signal monitor ---

  // A long-lived gdbus monitor on the system bus matches login1 signals
  // only (gdbus uses plain match rules, which need no privilege -
  // dbus-monitor's BecomeMonitor path is denied to normal users). Every
  // inhibition-state change fires PropertiesChanged (InhibitorAdded/
  // Removed/PrepareForSleep ride along on the same match); a burst
  // coalesces into one ListInhibitors readback. A 10s poll would cost
  // ~8.6k busctl forks/day for freshness that is still one action
  // behind the event.
  property int _monitorFails: 0
  property bool _monitorDegraded: false
  property var _monitorHandle: null
  property int _monitorTicks: 0

  // This child cannot be a job: the monitor streams signal lines for the
  // life of the session and a job reports a finished buffer, so the
  // owned Process with its SplitParser stays. The generation still owns
  // it - a deliberate stop retires the generation first, so the exit of a
  // child this service killed is never read as a failure to respawn.
  Process {
    id: _monitorProc

    command: ["gdbus", "monitor", "--system", "--dest", "org.freedesktop.login1"]
    stdout: SplitParser {
      onRead: data => {
        // A retired child has no say over the current request.
        if (!RequestGate.current(root._monitorHandle)) return
        // Only genuine signal lines re-arm the coalesce window; the
        // connect banner ("Monitoring signals from...") is ignored.
        if (data.indexOf("/org/freedesktop/login1:") !== 0) return
        root._monitorFails = 0
        root._monitorDegraded = false
        _coalesceTimer.restart()
      }
    }
    stderr: StdioCollector {}
    onExited: {
      root._monitorFailed()
    }
  }

  // `started` is the confirmation the watchdog waits for. `onStarted` is an
  // invokable on the Process type rather than a notifier, so it cannot be a
  // handler and the signal is reached through a Connections element naming the
  // Process as its target. Stopping the watchdog here is what keeps the 1 Hz
  // sample from running for the life of the session; _startMonitor arms it
  // again for every generation, so the spawn window still applies to each one,
  // and a generation that is never confirmed still reaches its deadline.
  Connections {
    target: _monitorProc

    function onStarted() {
      _monitorWatch.stop()
    }
  }

  function _startMonitor() {
    _monitorRespawn.stop()
    root._retireMonitor()
    const generation = RequestGate.begin(root._gateScope, root._monitorKey)
    if (generation === 0) {
      root._monitorDegraded = true
      return
    }
    root._monitorHandle = root._handle(generation, root._monitorKey)
    root._monitorDegraded = false
    root._monitorTicks = 0
    try {
      _monitorProc.running = true
    } catch (ignored) {
      root._monitorDegraded = true
    }
    _monitorWatch.restart()
  }

  function _retireMonitor() {
    _monitorWatch.stop()
    RequestGate.invalidateScope(root._gateScope, root._monitorKey)
    root._monitorHandle = null
    if (!_monitorProc.running) return false
    // SIGTERM only: the Process is a declared child of this singleton, so
    // the object tree destroys it with the singleton right after.
    _monitorProc.running = false
    return true
  }

  // One failure path for both ways a monitor generation loses its child: an
  // exit (bus restart, killed monitor) and a spawn that never produced one
  // (missing gdbus, no system bus). A child that never started reports no
  // exit at all, so without the second way the generation would look live
  // for the rest of the session and the registry would freeze unnoticed.
  // Either way the generation dies, the registry is degraded, and the next
  // attempt waits the capped backoff instead of spinning.
  //
  // `cause` is the caller's own word for which of the two failure ways this
  // was, because the two have different fixes and nothing else separates
  // them: an exit means the bus restarted or the child was killed, and a
  // spawn that never produced one means there is no gdbus or no system bus at
  // all. `_monitorWatch` passes "no-child"; an exit arrives with no argument
  // and is recorded as one.
  function _monitorFailed(cause) {
    if (!RequestGate.current(root._monitorHandle)) return false
    RequestGate.invalidate(root._monitorHandle)
    root._monitorHandle = null
    _monitorWatch.stop()
    root._monitorDegraded = true
    root._monitorFails++
    _monitorRespawn.interval = root._backoffMs(root._monitorFails)
    _monitorRespawn.restart()
    return true
  }

  // Owned-resource detection for the monitor child. Samples before the spawn
  // window only age the generation, so a child that starts slowly is not
  // read as a failure; a live child is a property read per poll interval, and
  // a current generation without one is the same failure an exit reports.
  Timer {
    id: _monitorWatch

    interval: root._monitorPollMs
    repeat: true
    onTriggered: {
      if (!RequestGate.current(root._monitorHandle)) return
      root._monitorTicks++
      if (root._monitorTicks * root._monitorPollMs < root._monitorSpawnWatchMs) return
      if (root._monitorAlive()) return
      root._monitorFailed("no-child")
    }
  }

  // Liveness of the owned child, read the way the job layer probes one: a
  // child that was never spawned reports neither a running flag nor a process
  // id, and neither does one that has already exited. `started` closes the
  // question, so after it this is not consulted again until the next
  // generation restarts the watchdog.
  function _monitorAlive() {
    return ProcProbe.alive(_monitorProc)
  }

  // Bounded respawn of the monitor. The delay is recomputed from the
  // failure count and capped, so a missing gdbus settles at one attempt a
  // minute rather than a tight restart loop.
  Timer {
    id: _monitorRespawn

    interval: 1000
    onTriggered: {
      if (_monitorProc.running) return
      root._startMonitor()
    }
  }

  // Coalesce window: a single logind state change can emit several
  // signals (and dbus-monitor prints one block across multiple lines);
  // the last line re-arms this and exactly one readback follows. Named
  // so no bare interval survives (see the interval-naming rule).
  readonly property int coalesceWindowMs: 250
  Timer {
    id: _coalesceTimer

    interval: root.coalesceWindowMs
    onTriggered: root.refresh()
  }

  // --- screensaver inhibit source (session bus) ---
  //
  // The second inhibit source, beside the login1 registry above:
  // org.freedesktop.ScreenSaver, the interface video players and browsers
  // ask to be left alone during playback. Clients call Inhibit/UnInhibit
  // as method calls, and no service is guaranteed to own the name - so
  // the state here is a counter over that message stream rather than a
  // queryable registry like login1. The match rule carries no type
  // filter on purpose: filtering to signals would hide the method calls
  // browsers actually make, which is how windowed video locked the
  // session.
  //
  // Every drift risks the wrong answer in the safe direction or the
  // unsafe one, so the count is only ever trusted inside one live
  // monitor generation: a respawn or a failure starts from zero, and a
  // generation that never reported anything is "no inhibit" rather than
  // "unknown". A count that never drains is capped by a lease instead -
  // a client that dies without UnInhibit is a known way this interface
  // leaks, and an inhibit that outlives every plausible video must not
  // leave the session unlocked for good.
  readonly property string _saInterface: "org.freedesktop.ScreenSaver"
  readonly property string _saMatch: "interface='" + _saInterface + "'"
  readonly property string _saInMember: "interface=" + _saInterface + "; member=Inhibit"
  readonly property string _saUnMember: "interface=" + _saInterface + "; member=UnInhibit"
  readonly property int _saLeaseMs: 86400000
  property int _screenSaverCount: 0
  readonly property bool screenSaverBlocked: root._screenSaverCount > 0
  property int _saFails: 0
  property bool _saDegraded: false
  property var _saHandle: null
  property int _saTicks: 0

  Process {
    id: _saProc

    // gdbus monitor only works against an owned name (it takes --dest),
    // and owning org.freedesktop.ScreenSaver is exactly what is not
    // guaranteed: a client calls the method whether or not a service
    // answers. dbus-monitor takes the match rule directly, which is why
    // this child is the one monitor in the file that is not gdbus.
    // BecomeMonitor is a privilege the session bus grants a normal user
    // and the system bus does not, which is the reason the login1 monitor
    // above is gdbus instead; a bus that refuses it fails the child, and
    // the source degrades open.
    command: ["dbus-monitor", "--session", root._saMatch]
    stdout: SplitParser {
      onRead: data => root._onScreenSaverLine(data)
    }
    stderr: StdioCollector {}
    onExited: {
      root._saFailed()
    }
  }

  // The screensaver monitor's half of the same pair, for the same reason.
  Connections {
    target: _saProc

    function onStarted() {
      _saWatch.stop()
    }
  }

  // One message header line, in dbus-monitor's shape (a method call from a
  // player, or a signal where a portal forwards one):
  //   ... interface=org.freedesktop.ScreenSaver; member=Inhibit
  // The member token is matched with its separator, not as a substring:
  // "UnInhibit" ends with "Inhibit", so a plain substring test would count
  // every release as a fresh request and the count would only grow.
  //
  // The bus line carries the emitting client's path and arguments, which is a
  // machine-internal identifier and client data respectively, so neither is
  // ever read here. A release that arrives with no matching inhibit clamps at
  // zero rather than going negative.
  function _onScreenSaverLine(data) {
    if (!RequestGate.current(root._saHandle)) return
    if (data.indexOf(root._saInterface) === -1) return
    if (data.indexOf(root._saUnMember) !== -1) {
      root._screenSaverCount = Math.max(0, root._screenSaverCount - 1)
    } else if (data.indexOf(root._saInMember) !== -1) {
      if (root._screenSaverCount === 0) _saLease.restart()
      root._screenSaverCount = root._screenSaverCount + 1
    } else {
      return
    }
    root._saFails = 0
    root._saDegraded = false
  }

  // The lease expired with the count still positive: the stream stopped
  // delivering releases, so the count is dropped rather than believed. A
  // player that died without its UnInhibit would otherwise hold the session
  // awake for 24h.
  function _saLeaseExpired() {
    if (root._screenSaverCount === 0) return
    root._screenSaverCount = 0
  }

  function _startSaMonitor() {
    _saRespawn.stop()
    root._retireSaMonitor()
    const generation = RequestGate.begin(root._gateScope, root._saKey)
    if (generation === 0) {
      root._saDegraded = true
      return
    }
    root._saHandle = root._handle(generation, root._saKey)
    root._saDegraded = false
    root._saTicks = 0
    // A new generation knows nothing about requests made before it, so
    // it starts from an empty count rather than inheriting a stale one.
    root._screenSaverCount = 0
    try {
      _saProc.running = true
    } catch (ignored) {
      root._saDegraded = true
    }
    _saWatch.restart()
  }

  function _retireSaMonitor() {
    _saWatch.stop()
    RequestGate.invalidateScope(root._gateScope, root._saKey)
    root._saHandle = null
    if (!_saProc.running) return false
    // SIGTERM only: the Process is a declared child of this singleton, so
    // the object tree destroys it with the singleton right after.
    _saProc.running = false
    return true
  }

  // Same two failure ways as the login1 monitor: an exit (bus restart,
  // killed child) and a spawn that never produced one. Either way the
  // generation dies and the count is dropped, which reads as "nothing is
  // inhibited" - the pre-existing behavior, and the safe direction for
  // a lock timer. The count being dropped is the number of block locks that
  // just stopped being believed.
  function _saFailed(cause) {
    if (!RequestGate.current(root._saHandle)) return false
    RequestGate.invalidate(root._saHandle)
    root._saHandle = null
    _saWatch.stop()
    _saLease.stop()
    root._screenSaverCount = 0
    root._saDegraded = true
    root._saFails++
    _saRespawn.interval = root._backoffMs(root._saFails)
    _saRespawn.restart()
    return true
  }

  // The screensaver half of the same probe, and `started` closes the question
  // there too: once the watchdog is stopped this is not consulted again until
  // the next generation restarts it.
  function _saAlive() {
    return ProcProbe.alive(_saProc)
  }

  Timer {
    id: _saWatch

    interval: root._monitorPollMs
    repeat: true
    onTriggered: {
      if (!RequestGate.current(root._saHandle)) return
      root._saTicks++
      if (root._saTicks * root._monitorPollMs < root._monitorSpawnWatchMs) return
      if (root._saAlive()) return
      root._saFailed("no-child")
    }
  }

  Timer {
    id: _saRespawn

    interval: 1000
    onTriggered: {
      if (_saProc.running) return
      root._startSaMonitor()
    }
  }

  Timer {
    id: _saLease

    interval: root._saLeaseMs
    repeat: false
    onTriggered: root._saLeaseExpired()
  }

  // Post-toggle follow-up (see start()/stop()).
  Timer {
    id: _toggleTimer
    interval: 300
    onTriggered: root.refresh("toggle")
  }

  // Confirmation window for the lock: a child still running this long after the
  // spawn owns the descriptor, which is the only observation a lease child
  // offers. A child that was never spawned is settled by the job's own spawn
  // deadline instead, so the two windows cannot disagree about which child is
  // live.
  // The window is derived from the spawn watchdog rather than set beside it,
  // so no confirmation can outrun the spawn verdict that precedes it, and the
  // job it confirms is one the watchdog has already cleared as alive.
  //
  // This is the one point in the file where the lock is genuinely held.
  // `_setInhibitState("held")` is what a consumer's `held` binding reads, and
  // `_heldAt` is the stamp the release measures from.
  Timer {
    id: _inhibitConfirm
    interval: root._inhibitConfirmMs
    repeat: false
    onTriggered: {
      const run = root._inhibitRun
      if (run === null || run.job === null) return
      if (!RequestGate.current(run.handle)) return
      if (root._inhibitState !== "starting") return
      if (!root._jobLive(run.job)) return
      root._setInhibitState("held")
      root._heldAt = Date.now()
      root._inhibitFails = 0
    }
  }

  // Bounded respawn of the lock, same shape as the monitor's. A retry
  // that lands while the lock is no longer wanted does nothing, so a
  // toggle during a failure window does not have to wait it out.
  Timer {
    id: _inhibitRetry
    repeat: false
    onTriggered: {
      if (!root.active) return
      if (root._inhibitRun !== null) return
      root._startInhibit()
    }
  }

  // Bounded retry of the readback.
  Timer {
    id: _listRetry
    repeat: false
    onTriggered: root.refresh("retry")
  }

  // Deadlines that only bound a wedged child. The lock has none: it is
  // meant to outlive every timeout in this file.
  readonly property int _inhibitSpawnWatchMs: 2500
  readonly property int _inhibitConfirmMs: root._inhibitSpawnWatchMs + 200
  readonly property int _listTimeoutMs: 5000
  readonly property int _reapTimeoutMs: 2000
  readonly property int _monitorPollMs: 1000
  readonly property int _monitorSpawnWatchMs: 5000

  // Countdown ticker: 1s cadence re-phased to the wall clock on every
  // trigger, so each second paints within ms of its boundary. Oversampling
  // would not do it: a 1s sampler fired off-phase stretches seconds toward
  // double length. Assignment signals only on real change, so the bus still
  // carries one publish per second. Idle for infinite targets.
  //
  // The expiry is the one release path that is not a user action, and it is
  // named as such. Without `reason=expired` a timed lock that ended on its
  // own and a lock the user released by clicking are the same line, and a
  // reader cannot tell a caffeine timer that worked from one that was
  // cancelled by something else. Nothing else in this file logs per tick:
  // the seconds going by are already on the bus.
  Timer {
    id: tickTimer
    interval: 1000
    repeat: true
    running: false
    onTriggered: {
      // Re-phase: the next fire lands on the next whole second no matter
      // how late this one ran, so drift never accumulates.
      tickTimer.interval = 1000 - (Date.now() % 1000)
      if (!root.active || root.infinite) return
      const rem = Math.max(0, Math.ceil((root.deadlineMs - Date.now()) / 1000))
      if (rem <= 0) {
        root.stop("expired")
      } else {
        root.remaining = rem
      }
    }
  }

  // Every owned child stops here. The service is resident and Boot gives
  // it no teardown, so this runs when the shell tears the singleton down:
  // the gate generations die first, so a synchronous cancel cannot
  // re-enter a request that is already retired. The jobs themselves are
  // owned by ProcessRegistry, which destroys each one after its single
  // terminal transition, so cancelling is the whole of what is owed.
  //
  // Teardown is the third way a lock ends without a user action, alongside an
  // expiry and a reap, and it is the one that leaves an orphan behind when it
  // does not happen - which is what _reapOrphans exists to clean up.
  function _shutdown() {
    _inhibitConfirm.stop()
    _inhibitRetry.stop()
    _listRetry.stop()
    _monitorRespawn.stop()
    _monitorWatch.stop()
    _saRespawn.stop()
    _saWatch.stop()
    _saLease.stop()
    _coalesceTimer.stop()
    _toggleTimer.stop()
    tickTimer.stop()
    root._retireInhibit("shutdown")
    root._retireList("shutdown")
    root._retireReap("shutdown")
    root._retireMonitor()
    root._retireSaMonitor()
  }

  // Provider id ownership: ProviderHost hands a record to the host Menu
  // once and refuses a re-registration whose owner is a different object,
  // so a record is only ever replaceable by the object that owns it. This
  // unit owns `caffeine` for as long as it is alive and must release it
  // in its teardown; a refused id would otherwise pin the surface to a
  // dead closure and drop the row's confirm stage.
  function _claimProviderId(id, surface, deferred) {
    if (ProviderHost.registerProvider(id, surface, root)) return true
    ProviderHost.unregisterProvider(id, root)
    if (ProviderHost.registerProvider(id, surface, root)) return true
    // A predecessor that has not finalized yet still holds the id and
    // frees it only from its own teardown, which is itself a deferred
    // step, so a recreated unit gets one late attempt past this turn. The
    // id is bounded and re-entrant: this path can only ever claim a free
    // id, so a late miss is reported and never blocks a live owner.
    if (deferred) {
      DeferredQueue.run(() => { root._claimProviderId(id, surface, false) }, 2, 0, root.tag + " provider retry")
      return false
    }
    return false
  }

  // Menu provider surface: overlays caffeine-row semantics onto the
  // bundle-declared row by id. ProviderHost holds the surface under this
  // unit as owner and replays it when Menu registers as its host, so drain
  // order does not gate the row.
  function _registerMenuProvider() {
    root._claimProviderId("caffeine", {
      sub: () => {
        if (!root.active) return null
        return root.infinite ? "Infinite" : root.formatted + " remaining"
      },
      display: () => {
        if (!root.active) return null
        return root.infinite ? "Infinite" : root.formatted
      },
      widestDisplay: () => "30:00",
      valueActive: () => root.active,
      // While active the row offers the same two-step stop confirmation
      // as the timer: first Enter arms, second Enter releases the lock.
      confirm: () => {
        if (!root.active) return null
        return {
          stages: 2,
          hint: "Press <b>Enter</b> again to stop caffeine",
          armed: "<b><u>Press again to confirm stop</u></b>",
          label: "Stop caffeine",
          action: "caffeineStop"
        }
      },
      runConfirm: () => { root.stop(); return true },
      // Dynamic row icon: the crossing slash renders red while a finite
      // inhibit is active; the infinite tail recolors the whole glyph
      // accent to match the bar module.
      iconAccent: () => root.infinite ? "accent" : (root.active ? "red" : "")
    }, false)
  }

  Component.onCompleted: {
    Registry.offer("inhibitor", {
      title: "Inhibitor",
      description: "caffeine-style idle + lock inhibit",
      verbNames: [
        "isActive",
        "toggle",
        "start",
        "stop",
        "cycleForward",
        "cycleBackward",
        "status",
        "help",
        "ping",
      ]
    })
    Registry.register(root.tag, root)
    root._registerMenuProvider()
    root._startMonitor()
    root._startSaMonitor()
    // "startup", so the first readback is distinguishable from the one a
    // user toggle causes, which is the same child with the same argv.
    root.refresh("startup")
    root._publish()
  }

  Component.onDestruction: {
    // Teardown releases the provider id: the surface closes over this
    // root, so a survivor would keep a dead confirm closure.
    ProviderHost.unregisterProvider("caffeine", root)
    Registry.unregister("inhibitor")
    root._shutdown()
  }
}
