import QtQuick
import Quickshell.Io
import qs.common
import "ProcProbe.js" as ProcProbe

// One supervised streaming child: a long-lived Process whose lines are events.
//
// The shape was spelled out twice in services/power/Inhibitor.qml - once for
// the login1 signal monitor, once for the session bus's ScreenSaver stream -
// and both copies carried the same four moving parts: a RequestGate generation
// so a retired child's lines are dropped, a 1 Hz spawn-window watchdog (a child
// that never started reports no exit at all), a capped respawn so a missing
// binary settles at one attempt a minute instead of spinning, and failure
// accounting. Only the command and the meaning of a line differed, so those are
// the two things this component asks its owner for.
//
// Ownership: the guard owns the child and its generation. start() retires the
// previous generation BEFORE the child is stopped, because cancelling a child
// reports its terminal transition synchronously and that callback has to find a
// stale generation. Lines are emitted only while the generation is current.
//
// Failure has two shapes and one path: an exit (`exit`) and a spawn that never
// produced a child (`no-child`, observed by the watchdog after spawnWatchMs).
// Either way the generation dies, `degraded` rises, the failure count grows and
// a respawn is scheduled at the capped backoff. `spawned` is emitted for every
// new generation so an owner with per-generation state can reset it; a genuine
// line proves the stream works and `noteAlive()` resets the backoff.
Item {
  id: guard

  // The argv, and the RequestGate scope/key this child's generation lives in.
  // The owner supplies both: the same scope can carry other requests (the
  // inhibitor's jobs do), and only the owner knows which key this stream is.
  property var command: []
  property string scope: ""
  property string key: ""

  // 1 Hz liveness sample and the window a child is given to start before a
  // missing one is read as a failure.
  property int pollMs: 1000
  property int spawnWatchMs: 5000

  // Capped respawn: base, 4x growth, ceiling.
  property int backoffBaseMs: 1000
  property int backoffCapMs: 60000

  readonly property bool armed: guard._armed
  // True after a failure and until a line proves the stream works again.
  property bool degraded: false
  property int fails: 0

  signal line(string data)
  signal failed(string cause)
  signal spawned()

  property bool _armed: false
  property var _handle: null
  property int _ticks: 0

  function _backoffMs(f) {
    return Math.min(guard.backoffCapMs,
      Math.max(0, guard.backoffBaseMs * Math.pow(4, Math.max(0, f - 1))))
  }

  function start() {
    retry.stop()
    guard._retire()
    const generation = RequestGate.begin(guard.scope, guard.key)
    if (generation === 0) {
      // The gate refused a new generation, so no child was ever asked for.
      guard.degraded = true
      return
    }
    guard._handle = { id: generation, scope: guard.scope, key: guard.key }
    guard.degraded = false
    guard._ticks = 0
    guard._armed = true
    guard.spawned()
    try {
      proc.running = true
    } catch (ignored) {
      guard.degraded = true
    }
    watch.restart()
  }

  // Deliberate stop: the generation dies first, so the exit this causes is not
  // read as a failure to respawn.
  function stop() {
    guard._armed = false
    watch.stop()
    retry.stop()
    guard._retire()
  }

  // A genuine line proves the stream: the backoff restarts from the fast end
  // and the degraded claim clears.
  function noteAlive() {
    guard.fails = 0
    guard.degraded = false
  }

  function _retire() {
    RequestGate.invalidateScope(guard.scope, guard.key)
    guard._handle = null
    if (!proc.running) return false
    // SIGTERM only: the Process is a declared child of this item, so an owner
    // that destroys the guard destroys it too.
    proc.running = false
    return true
  }

  function _fail(cause) {
    if (!RequestGate.current(guard._handle)) return false
    RequestGate.invalidate(guard._handle)
    guard._handle = null
    guard._armed = false
    watch.stop()
    guard.degraded = true
    guard.fails++
    retry.interval = guard._backoffMs(guard.fails)
    retry.restart()
    guard.failed(cause)
    return true
  }

  Process {
    id: proc

    command: guard.command
    stdout: SplitParser {
      onRead: data => {
        // A retired child has no say over the current request.
        if (!RequestGate.current(guard._handle)) return
        guard.line(data)
      }
    }
    stderr: StdioCollector {}
    onExited: guard._fail("exit")
  }

  // `started` is the confirmation the watchdog waits for. It is an invokable on
  // the Process type rather than a notifier, so the signal is reached through a
  // Connections element naming the Process as its target. Stopping the watch
  // here is what keeps the 1 Hz sample from running for the child's lifetime;
  // start() arms it again for every generation, so the spawn window still
  // applies to each one.
  Connections {
    target: proc

    function onStarted() {
      watch.stop()
    }
  }

  // Samples before the spawn window only age the generation, so a child that
  // starts slowly is not read as a failure; a live child is one property read
  // per interval, and a current generation without one is the same failure an
  // exit reports.
  Timer {
    id: watch

    interval: guard.pollMs
    repeat: true
    onTriggered: {
      if (!RequestGate.current(guard._handle)) return
      guard._ticks++
      if (guard._ticks * guard.pollMs < guard.spawnWatchMs) return
      if (ProcProbe.alive(proc)) return
      guard._fail("no-child")
    }
  }

  Timer {
    id: retry

    interval: 1000
    onTriggered: {
      if (proc.running) return
      guard.start()
    }
  }
}
