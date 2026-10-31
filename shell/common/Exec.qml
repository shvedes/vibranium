pragma Singleton
pragma ComponentBehavior: Bound
// qmllint disable missing-property
// qmllint disable unqualified
import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import "process/ProcProbe.js" as ProcProbe
import "process/CommandSpec.js" as CommandSpec

// Unified process execution: one place for the createObject/destroy pattern
// triplicated in Session, HyprlandSettings, Menu, AppLauncher.
// Usage:
//   Exec.run(["hyprctl", "-q", "reload", "config-only"])
//   Exec.shell("printf idle > \"" + p + "\"") // bash -c wrapper
//   Exec.runJob(["pw-dump"], "privacy:cut", { timeoutMs: 5000 })
//
// run() and shell() are compatibility one-shots that hand back the raw Process,
// so an existing caller keeps its exited handler and its collector text. They
// carry no timeout, retry, or result contract: new stateful consumers use
// runJob(), where ProcessRegistry owns the job lifetime. shell() runs shell
// source, so only fixed trusted command text may pass through it; user data
// belongs in a run() argument.
Singleton {
  id: root

  property int spawnWatchdogMs: 2000
  property int spawnPollMs: 200
  property var _watched: []
  // Mirrors _watched.length so the reap timer can bind to a scalar change.
  property int _pending: 0

  Component {
    id: procComp
    Process {
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
  }

  function run(cmd) {
    if (!cmd || cmd.length === 0) return null
    const proc = procComp.createObject(root, { command: cmd })
    if (!proc) {
      return null
    }
    const watch = root._watch(proc)
    // Deferred so handlers connected after run() still read the collectors.
    proc.exited.connect(() => {
      root._unwatch(watch)
      Qt.callLater(() => root._dispose(proc))
    })
    proc.started.connect(() => root._unwatch(watch))
    proc.running = true
    return proc
  }

  function shell(script) {
    if (!script || String(script).trim() === "") return null
    return root.run(["/bin/bash", "-c", String(script)])
  }

  // Compatibility only: the child escapes shell cleanup and is unobservable,
  // so jobs and the registry never use it.
  function detached(cmd) {
    try {
      Quickshell.execDetached(cmd)
      return true
    } catch (e) {
      return false
    }
  }

  function runJob(command, owner, options) {
    return ProcessRegistry.start(command, owner, options)
  }

  // PATH-resolved argv builders for the prefixes a feature would otherwise
  // spell with absolute paths. Bare names resolve through PATH like any
  // other spawned child - no absolute directory spelling anywhere. Every
  // argv is judged by the CommandSpec allowlist before it runs or is
  // handed out, so a rejected build answers null, never a partial
  // command.
  function rmCmd(paths) {
    const list = Array.isArray(paths) ? paths : [paths]
    if (list.length === 0) return null
    const cmd = ["rm", "-f", "--"]
    for (let i = 0; i < list.length; i++) {
      if (typeof list[i] !== "string" || list[i] === "" || list[i].indexOf("\0") >= 0) return null
      cmd.push(list[i])
    }
    if (!CommandSpec.isAllowedArgv0(cmd[0])) return null
    return cmd
  }

  // rm -f -- <paths>: the one file-removal spelling. Paths are data,
  // never options (the -- separator is fixed).
  function rm(paths) {
    const cmd = root.rmCmd(paths)
    return cmd === null ? null : root.run(cmd)
  }

  // setsid + timeout prefix around a tail argv: ["setsid", "timeout",
  // "<secs>s", ...tail]. The tail head must name an allowlisted
  // binary (magick, sh, cp, ...); secs is whole seconds, 1..86400.
  function setsidTimeoutCmd(argv, secs) {
    const rest = Array.isArray(argv) ? argv.slice() : []
    const s = Math.floor(Number(secs))
    if (!isFinite(s) || s < 1 || s > 86400) return null
    const spec = CommandSpec.prefixedArgv(["setsid", "timeout", s + "s"].concat(rest))
    if (spec.ok !== true) return null
    return spec.argv
  }

  // `started` confirms a spawn, and run() above unwatches on it, so a child
  // still unconfirmed when the window elapses is one Quickshell produced no
  // signal about: a missing executable, a non-executable file, a directory, or
  // an empty argv. There is no error signal to observe that, so the window is
  // the deadline, and this is the only thing that ever destroys those children
  // - most callers attach no `exited` handler, so for them the reap is the whole
  // cleanup path. The liveness probe is one pure function shared with the job
  // layer rather than a second copy of it.
  function _reapWatchdogs() {
    const now = Date.now()
    const pass = root._watched.slice()
    const kept = []
    for (let i = 0; i < pass.length; i++) {
      const watch = pass[i]
      if (root._alive(watch.proc)) {
        continue
      }
      if (now < watch.deadline) {
        kept.push(watch)
        continue
      }
      root._dispose(watch.proc)
    }
    for (let i = 0; i < root._watched.length; i++) {
      const watch = root._watched[i]
      if (pass.indexOf(watch) < 0) kept.push(watch)
    }
    root._watched = kept
    root._pending = kept.length
  }

  function _watch(proc) {
    const watch = { proc: proc, deadline: Date.now() + Math.max(1, root.spawnWatchdogMs) }
    root._watched.push(watch)
    root._pending = root._watched.length
    return watch
  }

  function _unwatch(watch) {
    const index = root._watched.indexOf(watch)
    if (index < 0) return false
    root._watched.splice(index, 1)
    root._pending = root._watched.length
    return true
  }

  function _alive(proc) {
    return ProcProbe.alive(proc)
  }

  function _dispose(proc) {
    try {
      proc.destroy()
    } catch (ignored) {
      return false
    }
    return true
  }

  Timer {
    id: spawnWatch
    interval: Math.max(1, root.spawnPollMs)
    repeat: true
    running: root._pending > 0
    onTriggered: root._reapWatchdogs()
  }
}
