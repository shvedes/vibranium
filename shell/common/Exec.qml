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
  property var _watched: []
  // Mirrors _watched.length, so a reader can tell how many spawns are still
  // inside their window without reading the list itself.
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

  // A shell notice: the argv the clipboard, pass, screenshot editor and
  // wallpaper picker each spelled out. `options` carries app, replaceId,
  // timeoutMs and urgency; a key left out keeps notify-send's own default
  // rather than inventing one here.
  function notify(summary, body, options) {
    const o = options || {}
    const cmd = ["notify-send", "-a", o.app === undefined ? "Vibranium" : String(o.app)]
    if (o.urgency !== undefined) cmd.push("-u", String(o.urgency))
    if (o.replaceId !== undefined) cmd.push("-r", String(o.replaceId))
    if (o.timeoutMs !== undefined) cmd.push("-t", String(o.timeoutMs))
    cmd.push(String(summary))
    if (body !== undefined && body !== null && String(body) !== "") cmd.push(String(body))
    return root.run(cmd)
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
  //
  // Only a due entry is judged here. A child still inside its window cannot
  // change the verdict a poll would reach - the window ends at a fixed moment -
  // so the sweep runs when a deadline is reached rather than on a cadence, and
  // an entry that is already live is dropped without a probe: its own `exited`
  // is the path that disposes it.
  function _reapWatchdogs() {
    const now = Date.now()
    const kept = []
    for (let i = 0; i < root._watched.length; i++) {
      const watch = root._watched[i]
      if (now < watch.deadline) {
        kept.push(watch)
        continue
      }
      if (root._alive(watch.proc)) continue
      root._dispose(watch.proc)
    }
    root._watched = kept
    root._pending = kept.length
    root._armSpawnWatch()
  }

  // The single deadline for the whole list: armed at the earliest live
  // deadline and re-armed after every sweep, so a spawn costs one wakeup at
  // the moment its window ends instead of a repeating cadence that re-reads a
  // clock for a verdict that cannot have changed yet.
  function _armSpawnWatch() {
    let next = Infinity
    for (let i = 0; i < root._watched.length; i++) {
      if (root._watched[i].deadline < next) next = root._watched[i].deadline
    }
    if (!isFinite(next)) {
      spawnWatch.stop()
      return
    }
    spawnWatch.interval = Math.max(1, next - Date.now())
    spawnWatch.restart()
  }

  function _watch(proc) {
    const watch = { proc: proc, deadline: Date.now() + Math.max(1, root.spawnWatchdogMs) }
    root._watched.push(watch)
    root._pending = root._watched.length
    root._armSpawnWatch()
    return watch
  }

  function _unwatch(watch) {
    const index = root._watched.indexOf(watch)
    if (index < 0) return false
    root._watched.splice(index, 1)
    root._pending = root._watched.length
    root._armSpawnWatch()
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

  // One deadline, set by _armSpawnWatch() from the earliest live window. Not a
  // binding: the deadline moves with the list, and a binding on `_pending`
  // could only restart a cadence, which is the polling this replaces.
  Timer {
    id: spawnWatch
    repeat: false
    onTriggered: root._reapWatchdogs()
  }
}
