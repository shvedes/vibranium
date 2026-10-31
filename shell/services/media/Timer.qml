pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick as QQ
import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import "../../common/process/CommandSpec.js" as CommandSpec
import "../../common/text/UnitIpc.js" as UnitIpc
import "../../common/text/Duration.js" as DurationFmt

// Fully internal countdown timer. No state file, no external helper -
// everything lives in this singleton's memory. The menu's
// value slot reads `formatted` live and the stop action is a dropdown
// confirmation inside the timer row itself.
Singleton {
  id: root

  readonly property string tag: "timer"

  // Public state -----------------------------------------------------------
  property bool active: false
  property bool expired: false
  property int remaining: 0
  property int initial: 0

  // Backend ownership, reported next to the desired state it answers to. A
  // countdown runs on its own clock, so `active` and `expired` stay exactly
  // what the user asked for, while these two say whether the idle block and
  // the alarm child are actually held. They are diagnostic only: neither
  // enters the bus payload, so a degrade transition costs no repaint on the
  // surfaces that mirror the countdown.
  readonly property bool inhibitHeld: root._wantInhibit
    && root._inhibitJob !== null && !root._inhibitUnproven
  readonly property bool inhibitDegraded: root._wantInhibit && !root.inhibitHeld
  readonly property bool alarmHeld: root._wantAlarm
    && root._alarmJob !== null && !root._alarmUnproven
  readonly property bool alarmDegraded: root._wantAlarm && !root.alarmHeld

  // Fresh-computed copy of the formatted readout for synchronous readers
  // (bus publish, IPC status): the `formatted` binding below re-evaluates
  // after signal handlers run, so a publish that reads the binding carries
  // the previous tick's text. Computing from the primitives here keeps
  // every publish current.
  function currentFormatted() {
    if (!root.active && !root.expired) return ""
    if (root.expired) return "Time's up!"
    return root.formatDuration(root.remaining)
  }

  readonly property string formatted: root.currentFormatted()

  // Countdown readout, canonicalized in common/text/Duration.js so the
  // service and any other reader share one spelling.
  function formatDuration(secs) {
    return DurationFmt.formatVerboseDuration(secs)
  }

  // Internal ----------------------------------------------------------------
  // Drift-corrected base for the tick math below; restart on every start.
  ElapsedTimer {
    id: uptime
  }

  // Child process ownership -------------------------------------------------
  // The idle block and the alarm are the only children this service owns, and
  // both are registry jobs under a RequestGate generation of their own pair. A
  // retry, a rearm, and a terminal callback all carry the generation they were
  // started with, so work that outlives its request is a no-op instead of a
  // respawn. That matters most for the case Quickshell 0.3.1 reports worst: a
  // missing executable produces neither `started` nor `exited`, which an
  // unconditional respawn-on-exit loop can only answer by spinning.
  readonly property string _gateScope: "timer"
  readonly property string _inhibitKey: "inhibit"
  readonly property string _alarmKey: "alarm"

  // A job proves its spawn through the same two halves as any other: the
  // watchdog calls an unconfirmed child a failure, and a child that outlives
  // that window under a live generation is the hold confirmed. What the two
  // halves are for is different here, because these are lease children that
  // are meant to run for the whole request rather than exit: the window is not
  // a substitute for a spawn signal, it is the only point at which a long-lived
  // child can be observed at all, and an unconfirmed child is reported as
  // unproven rather than as held. The window only has to outlast fork and exec.
  readonly property int _spawnWindowMs: 1500
  readonly property int _spawnPollMs: 25

  // A sound is a few seconds long, so a minute-long alarm child is wedged on a
  // dead sink: terminating it is what lets the next attempt run.
  readonly property int _alarmTimeoutMs: 60000

  // Backoff. Zero after a clean play keeps the ring cadence (the next sound
  // starts when the previous one ends); a failed attempt starts at the base
  // and doubles per consecutive failure until the ceiling, so a permanently
  // missing executable costs one child per ceiling window instead of a loop.
  readonly property int _inhibitBaseMs: 500
  readonly property int _inhibitMaxMs: 30000
  readonly property int _alarmBaseMs: 750
  readonly property int _alarmMaxMs: 15000

  // An alarm epoch is one short effect: a bounded number of attempts that
  // cannot make a sound is its degraded end state, and the recovery path is
  // the next expiry (or a stop and a fresh start), never a tighter loop. The
  // inhibit is a lease the countdown asked to hold for its whole run, so its
  // retries continue at the ceiling: a hold lost to a transient failure has to
  // come back.
  readonly property int _alarmMaxFails: 5

  // Desired vs held. The want flags are the request, the job fields are the
  // child, and the unproven flags say the child has not yet confirmed itself.
  property bool _wantInhibit: false
  property var _inhibitJob: null
  property var _inhibitHandle: null
  property int _inhibitFails: 0
  property bool _inhibitUnproven: false
  property bool _wantAlarm: false
  property var _alarmJob: null
  property var _alarmHandle: null
  property int _alarmFails: 0
  property bool _alarmUnproven: false

  // systemd-inhibit keeps the idle lock for the life of its child, so the
  // block is a lease: releasing it is killing the child and holding it is a
  // confirmed live child. The command is fixed, takes no user data, produces
  // no output, and has no deadline of its own - the countdown is the deadline.
  function _inhibitArgv() {
    return ["systemd-inhibit", "--what=idle", "--who=Vibranium", "--why=Timer",
      "--mode=block", "sleep", "infinity"]
  }

  // Requests the lease. The previous generation dies before its child is
  // stopped, because a cancel runs the terminal path synchronously and that
  // callback must already see a stale handle. A refused generation is not a
  // live request, so the lease stays unproven instead of being acquired
  // ungated.
  function _setInhibitWant(want) {
    RequestGate.invalidateScope(root._gateScope, root._inhibitKey)
    root._releaseInhibit("superseded")
    root._wantInhibit = want
    if (!want) return
    const generation = RequestGate.begin(root._gateScope, root._inhibitKey)
    root._inhibitFails = 0
    root._inhibitUnproven = true
    if (generation === 0) return
    root._inhibitHandle = Object.freeze({
      id: generation, scope: root._gateScope, key: root._inhibitKey
    })
    root._spawnInhibit()
  }

  function _spawnInhibit() {
    const handle = root._inhibitHandle
    if (handle === null || !root._wantInhibit) return
    if (!RequestGate.current(handle)) return
    const spec = CommandSpec.argv(root._inhibitArgv())
    if (spec.ok !== true) {
      root._onInhibitAttemptEnd(handle)
      return
    }
    let job = null
    try {
      job = ProcessRegistry.start(spec, "timer:inhibit", {
        // One attempt per job: the backoff and the failure count belong to
        // the service, under its own generation, not to the job.
        maxAttempts: 1,
        timeoutMs: 0,
        spawnWatchdogMs: root._spawnWindowMs,
        spawnPollMs: root._spawnPollMs,
        // A refusal and a settled child are the same event to a lease: this
        // attempt produced no confirmed hold.
        onFinished: () => root._onInhibitAttemptEnd(handle),
        onFailed: () => root._onInhibitAttemptEnd(handle)
      })
    } catch (ignored) {
      job = null
    }
    if (job === null) {
      root._onInhibitAttemptEnd(handle)
      return
    }
    if (!RequestGate.current(handle)) {
      root._cancelJob(job, "stale")
      return
    }
    root._inhibitJob = job
    root._inhibitUnproven = true
    inhibitConfirm.restart()
  }

  // The one terminal path of an attempt, whatever ended it: a refusal before
  // any spawn, a nonzero exit, a deadline, and a clean exit are all a lease
  // that is not held, and a lease that is not held has to be re-established.
  // The counter is only reset by a confirmed hold, so a child that keeps
  // dying keeps growing the backoff and can never spin.
  function _onInhibitAttemptEnd(handle) {
    if (handle === null || handle === undefined) return
    if (!RequestGate.current(handle)) return
    root._inhibitJob = null
    inhibitConfirm.stop()
    root._inhibitUnproven = true
    root._inhibitFails++
    root._scheduleInhibitRetry()
  }

  // A child that outlived the spawn window under a live generation is the hold
  // confirmed.
  function _confirmInhibit() {
    const job = root._inhibitJob
    if (job === null) return
    if (root._inhibitHandle === null) return
    if (!RequestGate.current(root._inhibitHandle)) return
    if (String(job.state) === "settled") return
    root._inhibitFails = 0
    root._inhibitUnproven = false
  }

  function _scheduleInhibitRetry() {
    if (!root._wantInhibit) return
    if (root._inhibitHandle === null) return
    if (!RequestGate.current(root._inhibitHandle)) return
    inhibitRetry.interval = root._backoffMs(root._inhibitFails,
      root._inhibitBaseMs, root._inhibitMaxMs)
    inhibitRetry.restart()
  }

  function _releaseInhibit(reason) {
    root._inhibitHandle = null
    inhibitConfirm.stop()
    inhibitRetry.stop()
    const job = root._inhibitJob
    root._inhibitJob = null
    root._inhibitUnproven = false
    if (job !== null) root._cancelJob(job, reason)
  }

  // The alarm sound is a short one-shot child, so the repeat is owned here
  // rather than by a resident process: every attempt is its own registry job
  // under the current generation, and the next attempt is armed by a bounded
  // rearm timer instead of a respawn on exit.
  // Alarm voice. File + volume live here (not inside _alarmArgv) so
  // the Paths.soundThemeFile + shell.timer.volume migration lands on
  // two bindings instead of on the spawn: today both halves are absent
  // (no such Paths member, no such schema key), so the defaults below
  // preserve today's voice byte for byte.
  readonly property string alarmSoundFile: "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga"
  readonly property int alarmVolume: 32500
  function _alarmArgv() {
    return ["paplay", "--volume", String(root.alarmVolume), root.alarmSoundFile]
  }

  function _setAlarmWant(want) {
    RequestGate.invalidateScope(root._gateScope, root._alarmKey)
    root._releaseAlarm("superseded")
    root._wantAlarm = want
    if (!want) return
    const generation = RequestGate.begin(root._gateScope, root._alarmKey)
    root._alarmFails = 0
    root._alarmUnproven = true
    if (generation === 0) return
    root._alarmHandle = Object.freeze({
      id: generation, scope: root._gateScope, key: root._alarmKey
    })
    root._spawnAlarm()
  }

  function _spawnAlarm() {
    const handle = root._alarmHandle
    if (handle === null || !root._wantAlarm) return
    if (!RequestGate.current(handle)) return
    const spec = CommandSpec.argv(root._alarmArgv())
    if (spec.ok !== true) {
      root._onAlarmAttemptEnd(handle, null)
      return
    }
    let job = null
    try {
      job = ProcessRegistry.start(spec, "timer:alarm", {
        maxAttempts: 1,
        timeoutMs: root._alarmTimeoutMs,
        spawnWatchdogMs: root._spawnWindowMs,
        spawnPollMs: root._spawnPollMs,
        onFinished: (result) => root._onAlarmAttemptEnd(handle, result),
        onFailed: () => root._onAlarmAttemptEnd(handle, null)
      })
    } catch (ignored) {
      job = null
    }
    if (job === null) {
      root._onAlarmAttemptEnd(handle, null)
      return
    }
    if (!RequestGate.current(handle)) {
      root._cancelJob(job, "stale")
      return
    }
    root._alarmJob = job
    root._alarmUnproven = true
    alarmConfirm.restart()
  }

  // The one terminal path of an attempt. A sound only counts as played when
  // the child both ended cleanly and outlived the confirmation window: a
  // paplay that returns at once on a dead sink has delivered nothing, and
  // letting it reset the counter would repeat it with no gap at all.
  function _onAlarmAttemptEnd(handle, result) {
    if (handle === null || handle === undefined) return
    if (!RequestGate.current(handle)) return
    root._alarmJob = null
    alarmConfirm.stop()
    if (root._succeeded(result) && !root._alarmUnproven) root._alarmFails = 0
    else root._alarmFails++
    root._scheduleAlarmRearm()
  }

  function _confirmAlarm() {
    const job = root._alarmJob
    if (job === null) return
    if (root._alarmHandle === null) return
    if (!RequestGate.current(root._alarmHandle)) return
    if (String(job.state) === "settled") return
    root._alarmUnproven = false
  }

  function _scheduleAlarmRearm() {
    if (!root._wantAlarm) return
    if (root._alarmHandle === null) return
    if (!RequestGate.current(root._alarmHandle)) return
    if (root._alarmFails > root._alarmMaxFails) {
      // The epoch is spent and stays degraded: the alarm keeps saying its
      // time is up, and a new expiry or a fresh start is the recovery path.
      alarmRearm.stop()
      return
    }
    alarmRearm.interval = root._backoffMs(root._alarmFails,
      root._alarmBaseMs, root._alarmMaxMs)
    alarmRearm.restart()
  }

  function _releaseAlarm(reason) {
    root._alarmHandle = null
    alarmConfirm.stop()
    alarmRearm.stop()
    const job = root._alarmJob
    root._alarmJob = null
    root._alarmUnproven = false
    if (job !== null) root._cancelJob(job, reason)
  }

  // A child counts as delivered only when it ran and ended cleanly: a refused
  // spawn, a nonzero exit, a deadline, and a cancel all mean the effect did
  // not happen.
  function _succeeded(result) {
    if (result === null || result === undefined) return false
    if (result.cancelled === true || result.destroyed === true) return false
    if (result.timedOut === true) return false
    return String(result.code) === "ok" && Number(result.exitCode) === 0
  }

  function _backoffMs(fails, baseMs, maxMs) {
    if (!(fails > 0)) return 0
    const delay = baseMs * Math.pow(2, Math.max(1, Math.floor(fails)) - 1)
    return Math.min(maxMs, Math.max(baseMs, Math.floor(delay)))
  }

  // A settled job owns nothing and the registry destroys it on its own
  // deferred path, so only a live job is cancelled here.
  function _cancelJob(job, reason) {
    if (job === null || job === undefined) return false
    try {
      if (String(job.state) === "settled") return false
    } catch (ignored) {
      return false
    }
    try {
      job.cancel(String(reason))
      return true
    } catch (ignored) {
      return false
    }
  }

  // Teardown: both generations die first so a callback racing the shutdown
  // finds a stale handle, then every child still owned is cancelled and
  // destroyed with its job object, because the registry's deferred dispose may
  // never run while the engine tears the tree down.
  function _shutdown() {
    RequestGate.invalidateScope(root._gateScope, root._inhibitKey)
    RequestGate.invalidateScope(root._gateScope, root._alarmKey)
    const jobs = []
    if (root._inhibitJob !== null) jobs.push(root._inhibitJob)
    if (root._alarmJob !== null) jobs.push(root._alarmJob)
    root._releaseInhibit("destroyed")
    root._releaseAlarm("destroyed")
    root._wantInhibit = false
    root._wantAlarm = false
    tickTimer.stop()
    for (let i = 0; i < jobs.length; i++) {
      root._cancelJob(jobs[i], "destroyed")
      try {
        jobs[i].destroy()
      } catch (ignored) {
        continue
      }
    }
  }

  // Spawn confirmation windows. A job that settled inside the window is left
  // to its own terminal path, which is the failure this window exists to let
  // through.
  QQ.Timer {
    id: inhibitConfirm

    interval: root._spawnWindowMs
    repeat: false
    onTriggered: root._confirmInhibit()
  }

  QQ.Timer {
    id: inhibitRetry

    repeat: false
    onTriggered: root._spawnInhibit()
  }

  QQ.Timer {
    id: alarmConfirm

    interval: root._spawnWindowMs
    repeat: false
    onTriggered: root._confirmAlarm()
  }

  QQ.Timer {
    id: alarmRearm

    repeat: false
    onTriggered: root._spawnAlarm()
  }

  // Public API --------------------------------------------------------------
  function start(seconds) {
    const secs = Math.floor(Number(seconds))
    if (!(secs > 0)) {
      return false
    }
    if (root.active || root.expired) root.stop()
    root.initial = secs
    root.remaining = secs
    uptime.restart()
    root.active = true
    root.expired = false
    root._setInhibitWant(true)
    tickTimer.running = true
    return true
  }

  function startMinutes(minutes) {
    const m = Number(minutes)
    if (!(m > 0)) return false
    return root.start(Math.round(m * 60))
  }

  function stop() {
    if (!root.active && !root.expired) return false
    root.active = false
    root.expired = false
    root.remaining = 0
    root.initial = 0
    tickTimer.running = false
    root._setAlarmWant(false)
    root._setInhibitWant(false)
    return true
  }

  // Bar-module mirror surface: the features/bar/modules/Timer module
  // re-sources its state from this topic (Bus.latest replays it on
  // creation, so a late-loading module is correct on frame one). Ticks
  // once a second while active, which stays well under the bar's
  // low-frequency topic budget.
  function _publish() {
    Bus.publish("timer.bus", {
      active: root.active,
      expired: root.expired,
      remaining: root.remaining,
      initial: root.initial,
      formatted: root.currentFormatted()
    })
  }
  onActiveChanged: root._publish()
  onExpiredChanged: root._publish()
  onRemainingChanged: root._publish()

  function _expire() {
    root.remaining = 0
    root.active = false
    root.expired = true
    tickTimer.running = false
    root._setInhibitWant(false)
    root._setAlarmWant(true)
  }

  // Tick once per second, re-phased to the wall clock on every trigger
  // (see Inhibitor's tickTimer): the remaining readout moves in whole
  // seconds, so a 4x sampler only repainted the same second. Elapsed
  // math stays drift-corrected via the start timestamp; the phase keeps
  // each second painting on its boundary.
  QQ.Timer {
    id: tickTimer
    interval: 1000
    repeat: true
    running: false
    onTriggered: {
      tickTimer.interval = 1000 - (Date.now() % 1000)
      if (!root.active || root.expired) return
      const elapsed = Math.floor(uptime.elapsedMs() / 1000)
      const rem = root.initial - elapsed
      if (rem <= 0) {
        root.remaining = 0
        root._expire()
      } else {
        root.remaining = rem
      }
    }
  }

  // Duration text -> seconds, strict: /^(\d+(?:\.\d+)?)\s*(s|sec|min|m|h)?$/i.
  // A bare number is seconds; s/sec/min/m/h scale it (m is minutes).
  // Anything else answers 0 (invalid) rather than a guess: no prefix
  // match, no substring sniffing. The canonical home this would move to
  // is a time library; until one exists the parser lives here, next to
  // its only caller.
  function parseDuration(text) {
    const m = String(text === undefined || text === null ? "" : text)
      .match(/^(\d+(?:\.\d+)?)\s*(s|sec|min|m|h)?$/i)
    if (m === null) return 0
    const v = Number(m[1])
    if (!(v > 0)) return 0
    const u = String(m[2] === undefined ? "" : m[2]).toLowerCase()
    if (u === "h") return v * 3600
    if (u === "" || u === "s" || u === "sec") return v
    return v * 60
  }

  // IPC ---------------------------------------------------------------------
  IpcHandler {
    target: "timer"
    function help(command: string): string {
      return UnitIpc.help("timer", "Timer", "countdown timer", [
        { name: "start", help: "(seconds) start a timer" },
        { name: "startMinutes", help: "(minutes) start a timer" },
        { name: "stop", help: "stop the timer" },
      ], command)
    }
    function ping(): string { return "pong" }
    function start(seconds: string): string {
      // Strict duration: a bare number is seconds, otherwise one of
      // s/sec/min/m/h (case-insensitive, optional space). Anything else
      // is an error rather than a guess - a prefix match would read
      // "90 s" as 90 minutes.
      const v = root.parseDuration(seconds)
      if (!(v > 0)) return "error: invalid seconds"
      return root.start(Math.round(v)) ? "ok" : "error"
    }
    function startMinutes(mins: string): string {
      const v = Number(mins)
      if (!(v > 0)) return "error: invalid minutes"
      return root.startMinutes(v) ? "ok" : "error"
    }
    function stop(): string { root.stop(); return "ok" }
    function status(): string {
      return JSON.stringify({
        active: root.active,
        expired: root.expired,
        remaining: root.remaining,
        initial: root.initial,
        formatted: root.currentFormatted(),
        inhibitHeld: root.inhibitHeld,
        inhibitDegraded: root.inhibitDegraded,
        alarmHeld: root.alarmHeld,
        alarmDegraded: root.alarmDegraded
      })
    }
  }

  // Provider id ownership: ProviderHost hands a record to the host Menu
  // once and refuses a re-registration whose owner is a different object,
  // so a record is only ever replaceable by the object that owns it. This
  // unit owns `timer` for as long as it is alive and must release it in
  // its teardown; a refused id would otherwise pin the surface to a dead
  // closure and drop the row's confirm stage.
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

  // Menu provider surface: overlays timer-row semantics onto the
  // bundle-declared row by id (live display, active gating, stop flow,
  // minute entry). ProviderHost holds the surface under this unit as owner
  // and replays it when Menu registers as its host, so drain order does not
  // gate the row.
  function _registerMenuProvider() {
    root._claimProviderId("timer", {
      sub: (item) => {
        if (!(root.active || root.expired)) return null
        return root.expired ? "Select to dismiss" : "Select to stop timer"
      },
      display: () => (root.active || root.expired) ? root.formatted : null,
      widestDisplay: () => "Time's up!",
      valueActive: () => root.active,
      numberActive: () => root.active || root.expired,
      confirm: () => {
        if (!(root.active || root.expired)) return null
        return {
          stages: 2,
          hint: root.expired ? "Press <b>Enter</b> again to dismiss" : "Press <b>Enter</b> again to stop the timer",
          armed: root.expired ? "<b><u>Press again to confirm dismissal</u></b>" : "<b><u>Press again to confirm stop</u></b>",
          label: root.expired ? "Dismiss" : "Stop timer",
          action: "timerStop"
        }
      },
      runConfirm: () => { root.stop(); return true },
      runNumber: (item, value) => { root.startMinutes(value); return true }
    }, false)
  }

  Component.onCompleted: {
    Registry.register(root.tag, root)
    root._registerMenuProvider()
    root._publish()
    Registry.offer("timer", {
      title: "Timer",
      description: "countdown timer",
      verbNames: [
        "start",
        "startMinutes",
        "stop",
        "status",
        "help",
        "ping",
      ]
    })
  }

  Component.onDestruction: {
    // Teardown releases the provider id: the surface closes over this
    // root, so a survivor would keep a dead confirm closure.
    ProviderHost.unregisterProvider("timer", root)
    Registry.unregister(root.tag)
    root._shutdown()
  }
}
