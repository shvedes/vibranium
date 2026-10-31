pragma ComponentBehavior: Bound
import QtQml
import Quickshell.Io
import "ProcProbe.js" as ProcProbe

// One owned one-shot child. Exactly one Quickshell Process exists at a time,
// exactly one terminal transition is reported, and the Process, its collectors,
// the timers, and the callbacks are released on every terminal path.
//
// Limitations of the native Quickshell 0.3.1 contract that this file states
// instead of hiding: StdioCollector has no byte limit, Process has no stdin
// close, Process exposes no process-group handle, and a missing executable
// produces no `exited` at all. Bounded output, stdin EOF, and descendant group
// cleanup therefore need a trusted helper and are not claimed here.
QtObject {
  id: root

  // QML reserves `id` for the object attribute, so the identifier is spelled
  // jobId and reported as `id` in results and registry lookups.
  property string jobId: ""
  // The registry's owner tag, carried onto the job. The registry array is not
  // a substitute: a job waiting out a retry backoff has left no entry behind,
  // and the id alone would leave the owner to be inferred from a string that
  // embeds it.
  property string owner: ""
  property int generation: 0
  property var argv: []
  property int timeoutMs: 0
  property int maxAttempts: 1
  property int backoffMs: 0
  property int maxBackoffMs: 5000
  // Spawn confirmation has two halves: `started` confirms a child, and
  // spawnWatchdogMs is the deadline by which the absence of that confirmation
  // is read as a failure. spawnPollMs is the probe interval driving that
  // deadline, and it matters only on the failure path - a confirmed child
  // stops the probe in _onStarted. Central 100ms cadence shared by every
  // registry job (per-job tunings ride the same watchdog; there are no
  // per-job polling copies).
  property int spawnWatchdogMs: 2000
  property int spawnPollMs: 100
  property int maxStdoutBytes: 0
  property int maxStderrBytes: 0
  property string outputBackend: "collector"
  readonly property bool outputLimitsEnforced: false
  property string stdinMode: "none"
  property var stdinWriter: null
  // Optional seam for the CommandSpec contract: a function(argv) that returns
  // false or { ok: false, code } to reject the job before spawn.
  property var argvValidator: null

  // running covers the whole started lifetime, retry backoff included, until
  // the single terminal transition moves the job to settled.
  readonly property string state: root._state
  readonly property int attempts: root._attempt
  readonly property var result: root._result

  // Emitted exactly once per terminal transition that reached a process; the
  // result carries the stable code.
  signal finished(var result)
  // Emitted instead of finished when a rejection happens before any spawn.
  signal failed(string reason)

  property string _state: "idle"
  property int _attempt: 0
  property var _result: null
  property var _proc: null
  property int _exitCode: -1
  property string _reason: ""
  property bool _timedOut: false
  property bool _cancelled: false
  property bool _destroyed: false
  property bool _settled: false
  property bool _stdinFed: false
  property int _spawnTicks: 0

  // The job is a plain QtObject, so its owned process factory, timers, and
  // connection list are declared through an explicit default property.
  default property list<QtObject> _owned: [
    Component {
      id: procComp
      Process {
        // waitForEnd is off so a terminal path can still report what a killed
        // child produced; the collector still buffers everything it receives.
        stdout: StdioCollector { waitForEnd: false }
        stderr: StdioCollector { waitForEnd: false }
      }
    },

    Timer {
      id: spawnWatch
      interval: Math.max(1, root.spawnPollMs)
      repeat: true
      onTriggered: root._pollSpawn()
    },

    Timer {
      id: deadline
      interval: Math.max(1, root.timeoutMs)
      repeat: false
      onTriggered: root._expire()
    },

    Timer {
      id: backoff
      repeat: false
      onTriggered: root._launch()
    },

    Connections {
      target: root._proc
      ignoreUnknownSignals: true
      function onStarted() { root._onStarted() }
      function onExited(exitCode, exitStatus) { root._onExited(exitCode) }
    }
  ]

  function start() {
    if (root.state !== "idle") return false
    const rejection = root._preflight()
    if (rejection !== "") {
      root._reject(rejection)
      return false
    }
    root._attempt = 0
    root._launch()
    return true
  }

  function writeStdin(data) {
    if (root.stdinMode !== "write-only") return { ok: false, code: "stdin_disabled" }
    if (root._proc === null) return { ok: false, code: "stdin_not_running" }
    try {
      root._proc.write(String(data))
      return { ok: true, code: "written" }
    } catch (ignored) {
      return { ok: false, code: "stdin_write_failed" }
    }
  }

  function cancel(reason) {
    if (root._settled) return false
    root._cancelled = true
    root._reason = String(reason === undefined || reason === null ? "cancelled" : reason)
    root._exitCode = -1
    root._terminate("cancelled")
    return true
  }

  function _preflight() {
    // Registry-path enforcement: the registry always issues an owner
    // (and a jobId) with the job, so a job with no owner was built
    // outside it and refuses to start. Stateful jobs have exactly one
    // owner and one path into existence - ProcessRegistry.start() -
    // and fire-and-forget children go through Exec.detached instead.
    if (typeof root.owner !== "string" || root.owner.trim() === "") return "missing_owner"
    if (root.outputBackend !== "collector") return "unsupported_output_backend"
    if (root.maxStdoutBytes > 0 || root.maxStderrBytes > 0) return "unsupported_output_limit"
    if (root.stdinMode !== "none" && root.stdinMode !== "write-only") return "unsupported_stdin_mode"
    if (!root._validArgv()) return "invalid_argv"
    if (typeof root.argvValidator === "function") {
      let verdict = null
      try {
        verdict = root.argvValidator(root.argv.slice())
      } catch (ignored) {
        return "invalid_argv"
      }
      if (verdict === false) return "invalid_argv"
      if (verdict !== null && typeof verdict === "object" && verdict.ok === false) {
        return typeof verdict.code === "string" && verdict.code !== "" ? verdict.code : "invalid_argv"
      }
    }
    return ""
  }

  // A property populated by createObject holds a QML list rather than a JS
  // array, so the check is structural: array-like, non-empty, string entries.
  function _validArgv() {
    const argv = root.argv
    if (argv === null || argv === undefined || typeof argv !== "object") return false
    const length = Number(argv.length)
    if (!isFinite(length) || length <= 0) return false
    for (let i = 0; i < length; i++) {
      if (typeof argv[i] !== "string" || argv[i] === "") return false
    }
    return true
  }

  function _launch() {
    if (root._settled || root._cancelled || root._destroyed) return
    root._attempt++
    let proc = null
    try {
      proc = procComp.createObject(root, {
        command: root.argv.slice(),
        stdinEnabled: root.stdinMode === "write-only"
      })
    } catch (ignored) {
      proc = null
    }
    if (proc === null) {
      root._exitCode = -1
      root._terminate("spawn_failed")
      return
    }

    root._proc = proc
    root._exitCode = -1
    root._state = "running"
    root._stdinFed = false
    root._spawnTicks = 0
    spawnWatch.restart()
    if (root.timeoutMs > 0) deadline.restart()
    try {
      proc.running = true
    } catch (ignored) {
      root._terminate("spawn_failed")
    }
  }

  function _onStarted() {
    if (root._settled || root._proc === null) return
    spawnWatch.stop()
    root._feedStdin()
  }

  // The other half of spawn confirmation. `started` proves a child was
  // produced and stops this timer; observing that one was NOT produced needs a
  // deadline instead, because Quickshell exposes no error signal and a
  // property poll cannot tell an unresolvable argv[0] from an instant child
  // that has already exited - both read `running=false, processId=null`. So
  // the window is the deadline, and reaching it unconfirmed is the failure.
  function _pollSpawn() {
    if (root._settled || root._proc === null) return
    if (root._alive(root._proc)) {
      spawnWatch.stop()
      root._feedStdin()
      return
    }

    root._spawnTicks++
    const waited = root._spawnTicks * Math.max(1, root.spawnPollMs)
    if (waited < Math.max(1, root.spawnWatchdogMs)) return
    root._exitCode = -1
    if (root._retryable()) {
      root._stopChild()
      root._scheduleRetry()
      return
    }
    root._terminate("spawn_failed")
  }

  function _alive(proc) {
    return ProcProbe.alive(proc)
  }

  // The write channel only accepts data from a running child, so the writer
  // callback runs once the spawn is confirmed and its string result is written.
  function _feedStdin() {
    if (root._stdinFed) return
    root._stdinFed = true
    if (root.stdinMode !== "write-only") return
    if (typeof root.stdinWriter !== "function") return
    let payload = null
    try {
      payload = root.stdinWriter(root)
    } catch (ignored) {
      return
    }
    if (typeof payload === "string") root.writeStdin(payload)
  }

  function _onExited(exitCode) {
    if (root._settled) {
      root._stopChild()
      return
    }
    root._exitCode = Number(exitCode)
    spawnWatch.stop()
    deadline.stop()
    if (Number(exitCode) !== 0 && root._retryable()) {
      root._stopChild()
      root._scheduleRetry()
      return
    }
    root._terminate(Number(exitCode) === 0 ? "ok" : "nonzero_exit")
  }

  function _retryable() {
    if (root._cancelled || root._destroyed) return false
    return root._attempt < Math.max(1, root.maxAttempts)
  }

  // The backoff grows with the number of attempts that already ran; the
  // attempt counter itself moves in _launch so a cancelled wait does not look
  // like a started attempt.
  function _scheduleRetry() {
    spawnWatch.stop()
    deadline.stop()
    const cap = Math.max(0, root.maxBackoffMs)
    const delay = Math.min(cap, Math.max(0, root.backoffMs) * Math.pow(2, Math.max(0, root._attempt - 1)))
    backoff.interval = delay
    backoff.restart()
  }

  function _expire() {
    if (root._settled) return
    root._timedOut = true
    root._exitCode = -1
    root._terminate("timeout")
  }

  function _terminate(code) {
    if (root._settled) return
    root._settled = true
    spawnWatch.stop()
    deadline.stop()
    backoff.stop()

    // This object is the complete terminal record, and its two text fields
    // are exactly the ones no log may carry: a caller gets them on the
    // finished signal, and the registry's `job.settled` reports only the
    // code, the numeric exit status and the attempt count.
    const result = {
      id: root.jobId,
      generation: root.generation,
      exitCode: root._exitCode,
      stdout: root._collectText("stdout"),
      stderr: root._collectText("stderr"),
      timedOut: root._timedOut,
      cancelled: root._cancelled,
      destroyed: root._destroyed,
      truncated: false,
      outputLimitsEnforced: false,
      code: code,
      reason: root._reason
    }

    root._stopChild()
    root._result = result
    root._state = "settled"
    root.finished(result)
  }

  function _reject(reason) {
    if (root._settled) return
    root._settled = true
    backoff.stop()
    root._reason = reason
    root._state = "settled"
    root.failed(reason)
  }

  function _collectText(stream) {
    const proc = root._proc
    if (proc === null) return ""
    try {
      const parser = stream === "stdout" ? proc.stdout : proc.stderr
      if (parser === null || parser === undefined) return ""
      return String(parser.text === undefined ? "" : parser.text)
    } catch (ignored) {
      return ""
    }
  }

  // SIGTERM through running, then destroy: Quickshell tracks the direct child
  // only, so descendants are not part of this contract. Each step is isolated
  // so a failed signal still leaves the Process destroyed.
  function _stopChild() {
    const proc = root._proc
    root._proc = null
    if (proc === null) return
    try {
      if (proc.running === true) proc.running = false
    } catch (ignored) {
      // An unusable child handle must not skip the destroy below.
    }
    try {
      proc.destroy()
    } catch (ignored) {
      return
    }
  }

  Component.onDestruction: {
    if (root._settled) {
      root._stopChild()
      return
    }
    root._destroyed = true
    root._exitCode = -1
    root._reason = "destroyed"
    root._terminate("destroyed")
  }
}
