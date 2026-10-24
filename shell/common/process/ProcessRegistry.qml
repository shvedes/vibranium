pragma Singleton
pragma ComponentBehavior: Bound
// qmllint disable missing-property
import QtQml
import Quickshell
import qs.common

// Owner-indexed registry of live jobs. A job enters the registry when it is
// created and leaves it exactly once, on its single terminal transition or on
// a cancellation path that drops the entry before requesting that transition,
// so a caller that keeps a job reference never races a removal. Every drop
// destroys the job exactly once, whichever path performs it. startDetached is
// never used here: a detached child would outlive the shell and its owner, and
// Quickshell cannot report or clean it up afterwards.
Singleton {
  id: root

  property int _generation: 0
  property var _jobs: []

  Component {
    id: jobComp
    ProcessJob {}
  }

  // Returns the started job, or null when the command, owner, or options are
  // unusable: a shell-mode spec, a spec or option set carrying environment
  // entries, and an argv that is not a list of strings all refuse here rather
  // than start a job the caller cannot account for. A pre-spawn rejection inside
  // the job still reports through the job's failed signal, so pass
  // options.onFailed when start() can settle synchronously.
  //
  // Single owner: the registry is the only path that creates stateful jobs
  // (jobComp below is the sole factory, and the job refuses to start
  // without the owner issued here). Fire-and-forget children never enter
  // here - they go through Exec.detached, which carries no lifetime to own.
  function start(command, owner, options) {
    const parsed = root._argv(command)
    if (parsed.ok !== true) {
      return null
    }
    if (!root._validOwner(owner)) {
      return null
    }
    const settings = root._settings(options)
    if (settings === null) {
      return null
    }

    const generation = root._generation + 1
    let job = null
    try {
      job = jobComp.createObject(root, root._jobProperties(owner + "#" + generation, generation, parsed.argv, settings, owner))
    } catch (ignored) {
      job = null
    }
    if (job === null) {
      return null
    }

    const entry = { job: job, owner: owner, retained: 1, disposed: false }
    root._generation = generation
    root._jobs.push(entry)

    job.finished.connect((result) => root._onFinished(entry, result))
    job.failed.connect((reason) => root._onFailed(entry, reason))
    if (typeof settings.onFinished === "function") job.finished.connect(settings.onFinished)
    if (typeof settings.onFailed === "function") job.failed.connect(settings.onFailed)
    job.start()
    return job
  }

  function retain(job) {
    const entry = root._entry(job)
    if (entry === null) return false
    entry.retained++
    return true
  }

  // Mirrors UnitGate lease ownership: the last release cancels the job, and
  // releasing an unknown, released, or already settled job is a no-op.
  function release(job) {
    const entry = root._entry(job)
    if (entry === null) return false
    if (entry.retained > 1) {
      entry.retained--
      return true
    }
    return root._cancel(entry, "released")
  }

  function cancelOwner(owner) {
    if (!root._validOwner(owner)) return 0
    let cancelled = 0
    const entries = root._jobs.slice()
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].owner !== owner) continue
      if (root._cancel(entries[i], "owner_cancelled")) cancelled++
    }
    return cancelled
  }

  function cancelAll() {
    let cancelled = 0
    const entries = root._jobs.slice()
    for (let i = 0; i < entries.length; i++) {
      if (root._cancel(entries[i], "registry_cancelled")) cancelled++
    }
    return cancelled
  }

  // Settled jobs are already gone from both, so a terminal result belongs to
  // the job's finished signal rather than to a registry lookup.
  function active() {
    const ids = []
    for (let i = 0; i < root._jobs.length; i++) ids.push(root._jobs[i].job.jobId)
    return ids
  }

  function state(id) {
    const entry = root._entryById(id)
    if (entry === null) return null
    return {
      id: entry.job.jobId,
      generation: entry.job.generation,
      owner: entry.owner,
      state: entry.job.state,
      attempts: entry.job.attempts,
      retained: entry.retained
    }
  }

  // One terminal event with one level per outcome: `ok` and `cancelled` are
  // the contract being met, a failed, timed out or unspawned child is a
  // contract broken, and a `destroyed` job is the cleanup path firing on a
  // job that never settled on its own. The sentence is the same at every
  // level, so grepping a job id still finds all of them.

  // The drop is idempotent, so a terminal signal that arrives after a cancel
  // path already removed the entry neither re-enters the registry nor destroys
  // the job a second time.
  function _onFinished(entry, result) {
    root._forget(entry)
    if (result !== null && result !== undefined && result.destroyed === true) return
    root._disposeEntry(entry)
  }

  function _onFailed(entry, reason) {
    root._forget(entry)
    root._disposeEntry(entry)
  }

  // One destroy per dropped job, whichever path drops it: the terminal handlers
  // and the cancel path both reach disposal, and the per-entry flag keeps the
  // synchronous terminal transition inside cancel() from being counted twice.
  function _disposeEntry(entry) {
    if (entry.disposed === true) return
    entry.disposed = true
    root._dispose(entry.job)
  }

  // Deferred so the emitting job finishes its own terminal path before its
  // object is torn down.
  function _dispose(job) {
    Qt.callLater(() => {
      try {
        job.destroy()
      } catch (ignored) {
        return
      }
    })
  }

  // The entry is dropped before cancel() is asked for its terminal transition,
  // and that transition is reported synchronously, so the job's own finished
  // handler finds nothing left to remove. Disposal belongs to this path; a
  // cancel that throws must not skip it either, because no terminal signal
  // follows a failed call.
  function _cancel(entry, reason) {
    if (!root._forget(entry)) return false
    try {
      entry.job.cancel(reason)
    } finally {
      root._disposeEntry(entry)
    }
    return true
  }

  function _forget(entry) {
    const index = root._jobs.indexOf(entry)
    if (index < 0) return false
    root._jobs.splice(index, 1)
    return true
  }

  function _entry(job) {
    if (job === null || job === undefined) return null
    for (let i = 0; i < root._jobs.length; i++) {
      if (root._jobs[i].job === job) return root._jobs[i]
    }
    return null
  }

  function _entryById(id) {
    if (typeof id !== "string" || id === "") return null
    for (let i = 0; i < root._jobs.length; i++) {
      if (root._jobs[i].job.jobId === id) return root._jobs[i]
    }
    return null
  }

  // A command is an argv array, or a CommandSpec-shaped object carrying one.
  // Any shell form is rejected: data must stay an argument. A spec whose mode
  // is anything but "argv" carries an argv too, so reading the argv alone
  // would run shell source this registry never judged. A spec that carries
  // environment entries is rejected as well: no environment channel reaches
  // the job, so the child would start under an environment the caller did not
  // choose. A command supplied as a QML list is accepted structurally and
  // copied into a JS array.
  //
  // The answer carries the refusal code rather than only a null, because the
  // three ways a command is unusable are three different caller mistakes and
  // `job.refused` is the only record of which one it was. The codes are
  // CommandSpec.js's own.
  function _argv(command) {
    let source = command
    if (source !== null && source !== undefined && typeof source === "object" && !Array.isArray(source)) {
      if (source.mode !== undefined && source.mode !== "argv") return { ok: false, code: "untrusted_shell" }
      if (source.env !== undefined && source.env !== null) return { ok: false, code: "invalid_env" }
      if (source.argv === undefined || source.argv === null) return { ok: false, code: "invalid_argv" }
      source = source.argv
    }
    if (source === null || source === undefined || typeof source !== "object") return { ok: false, code: "invalid_argv" }
    const length = Number(source.length)
    if (!isFinite(length) || length <= 0) return { ok: false, code: "invalid_argv" }
    const argv = []
    for (let i = 0; i < length; i++) {
      if (typeof source[i] !== "string" || source[i] === "") return { ok: false, code: "invalid_argv" }
      argv.push(source[i])
    }
    return { ok: true, code: "ok", argv: argv }
  }

  // An option set that carries environment entries is refused, because the
  // well-typed values forwarded to the job are the only ones a job can
  // honour: entries named here would be dropped, and the child would run
  // under an environment the caller did not choose.
  function _settings(options) {
    if (options === undefined || options === null) return {}
    if (typeof options !== "object" || Array.isArray(options)) return null
    if (options.env !== undefined && options.env !== null) return null
    return options
  }

  // Only well-typed option values are forwarded; a missing or malformed one
  // leaves the job's own default in place. The owner is forwarded as well, so
  // a per-attempt line raised inside the job can name the owner without a
  // registry lookup - a job sitting in retry backoff is in no registry array.
  function _jobProperties(jobId, generation, argv, settings, owner) {
    const properties = { jobId: jobId, generation: generation, argv: argv, owner: owner }
    const numbers = [
      "timeoutMs",
      "maxAttempts",
      "backoffMs",
      "maxBackoffMs",
      "spawnWatchdogMs",
      "spawnPollMs",
      "maxStdoutBytes",
      "maxStderrBytes"
    ]
    for (let i = 0; i < numbers.length; i++) {
      const value = settings[numbers[i]]
      if (typeof value === "number" && isFinite(value)) properties[numbers[i]] = Math.max(0, Math.floor(value))
    }
    if (typeof settings.outputBackend === "string") properties.outputBackend = settings.outputBackend
    if (typeof settings.stdinMode === "string") properties.stdinMode = settings.stdinMode
    if (typeof settings.stdinWriter === "function") properties.stdinWriter = settings.stdinWriter
    if (typeof settings.argvValidator === "function") properties.argvValidator = settings.argvValidator
    return properties
  }

  function _validOwner(owner) {
    return typeof owner === "string" && owner.trim() !== "" && owner.length <= 128
  }

  // A singleton is destroyed before its children, so retained jobs are
  // cancelled here rather than waiting for their own destruction path.
  Component.onDestruction: {
    root.cancelAll()
  }
}
