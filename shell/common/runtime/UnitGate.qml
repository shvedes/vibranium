pragma Singleton
import QtQml
import Quickshell
import qs.common
import "ErrorText.js" as ErrorText
import "../text/StringUtils.js" as SU

Singleton {
  id: root

  signal unitChanged(string id)
  signal statesChanged()

  property var _records: []
  // id -> record, kept in sync with _records so _findRecord is O(1) instead
  // of a linear scan over every registered unit. Boot calls _findRecord on
  // every unit event and every dependency cascade, so the scan was O(n^2)
  // across a boot that registers ~50 units.
  property var _recordIndex: ({})
  property var _leases: []
  // Stamped by the first register(), not by a call site, so "total" in a boot
  // figure means the same thing no matter which unit is asked. Epoch millis:
  // the same 32-bit trap as record.startedAtMs applies.
  property var _bootStartedAtMs: 0

  function register(id, descriptor) {
    const record = root._validatedDescriptor(id, descriptor)
    if (record === null) return false
    if (root._bootStartedAtMs === 0) root._bootStartedAtMs = Date.now()
    root._records.push(record)
    const next = Object.assign({}, root._recordIndex)
    next[id] = record
    root._recordIndex = next
    root._changed(record)
    return true
  }

  function ensure(id, owner) {
    if (root._findRecord(id) === null) return { ok: false, code: "unknown_unit" }
    if (!root._validOwner(owner)) return { ok: false, code: "invalid_owner" }

    const record = root._findRecord(id)
    let lease = root._findLease(record, owner)
    if (lease === null) {
      lease = {
        token: {},
        unit: record,
        owner: owner,
        count: 1
      }
      root._leases.push(lease)
    }

    if (record.state === "not_started" || record.state === "stopped" || record.state === "blocked") {
      if (!root._dependenciesReady(record)) {
        root._block(record)
      } else {
        root._activate(record, true)
      }
    }

    root._changed(record)
    return root._ensureResult(record, lease.token)
  }

  function retain(lease) {
    const entry = root._leaseEntry(lease)
    if (entry === null || entry.count <= 0) return false
    entry.count++
    root._changed(entry.unit)
    return true
  }

  function release(lease) {
    const entry = root._leaseEntry(lease)
    if (entry === null || entry.count <= 0) return false
    entry.count--
    if (entry.count > 0) {
      root._changed(entry.unit)
      return true
    }
    const released = root._releaseEntry(entry)
    if (released) root._changed(entry.unit)
    return released
  }

  function releaseOwner(owner) {
    if (!root._validOwner(owner)) return 0
    let removed = 0
    const changed = []
    for (let i = root._leases.length - 1; i >= 0; i--) {
      const entry = root._leases[i]
      if (entry.owner !== owner || entry.count <= 0) continue
      entry.count = 0
      if (root._releaseEntry(entry)) {
        removed++
        changed.push(entry.unit)
      }
    }
    // Through _changed, so a release that moves no record out of its state
    // does not announce one.
    for (let i = 0; i < changed.length; i++) root._changed(changed[i])
    return removed
  }

  function retry(id) {
    const record = root._findRecord(id)
    if (record === null || record.state !== "failed") return false
    if (root._leaseCounts(record).owners === 0) return false
    if (record.retryCount >= record.descriptor.retry.maxAttempts) return false
    if (record.nextRetryMs > Date.now()) return false
    if (!root._dependenciesReady(record)) {
      root._block(record)
      root._changed(record)
      return false
    }
    record.retryCount++
    const activated = root._activate(record, false)
    root._changed(record)
    return activated
  }

  function retryDue(id) {
    const record = root._findRecord(id)
    if (record === null || record.state !== "failed") return false
    if (record.retryCount >= record.descriptor.retry.maxAttempts) return false
    return record.nextRetryMs <= Date.now()
  }

  // When a failed unit is next due, or 0 when it never will be. Boot arms its
  // retry pump from this on every unit event; state() would answer the same
  // question by building a public record and counting leases for every unit in
  // the catalog, which is a per-event walk of the whole boot for one number per
  // unit that usually is not failed at all.
  function retryAt(id) {
    const record = root._findRecord(id)
    if (record === null || record.state !== "failed") return 0
    return record.nextRetryMs
  }

  function state(id) {
    const record = root._findRecord(id)
    return record === null ? null : root._publicRecord(record)
  }

  function states() {
    const units = {}
    for (let i = 0; i < root._records.length; i++) {
      const record = root._records[i]
      Object.defineProperty(units, record.id, {
        configurable: true,
        enumerable: true,
        value: root._publicRecord(record),
        writable: true
      })
    }
    const shellState = root._shellState()
    return {
      shell: {
        state: shellState,
        health: shellState === "ready" ? "healthy" : shellState
      },
      units: units
    }
  }

  // shellState() -> "ready", "starting" or "degraded": the verdict on the
  // whole shell, read without building the snapshot.
  //
  // `states()` carries the same word in its `shell` member, and a caller that
  // wants only the verdict would be building a public record and a lease count
  // for every registered unit to read one string. This walks the records and
  // allocates nothing, which is what makes it answerable on every unit event
  // rather than on a poll.
  function shellState() {
    return root._shellState()
  }

  function refresh(id) {
    const record = root._findRecord(id)
    if (record === null) return false
    const refreshed = root._refreshRecord(record)
    root._changed(record)
    return refreshed
  }

  // One event per transition, not per call. ensure(), refresh(), retain() and
  // release() all end here, and boot calls them in bursts: 52 registrations,
  // then two cascades per eager unit, then one per drain step. Firing on every
  // call made each of those a whole-boot report rebuild and a dependency walk
  // that found nothing it did not already know (Bar.qml documents the same
  // cost from the consumer side). The emitted fields are this record's
  // last-published view; a call that moved none of them has nothing to say.
  function _changed(record) {
    if (record.emittedState === record.state
      && record.emittedHealth === record.health
      && record.emittedError === record.lastError
      && record.emittedRetryCount === record.retryCount) return
    record.emittedState = record.state
    record.emittedHealth = record.health
    record.emittedError = record.lastError
    record.emittedRetryCount = record.retryCount
    root.unitChanged(record.id)
    root.statesChanged()
  }

  function validateGraph() {
    const missing = []
    const cycles = []
    const missingIds = Object.create(null)
    const visitStates = Object.create(null)
    const stackIndexes = Object.create(null)
    const stack = []

    function visit(record) {
      const id = record.id
      visitStates[id] = 1
      stackIndexes[id] = stack.length
      stack.push(id)

      const dependencies = record.descriptor.dependencies
      for (let i = 0; i < dependencies.length; i++) {
        const dependency = dependencies[i]
        const target = root._findRecord(dependency)
        if (target === null) {
          if (missingIds[dependency] !== true) {
            missingIds[dependency] = true
            missing.push(dependency)
          }
          continue
        }

        const visitState = visitStates[dependency] || 0
        if (visitState === 0) {
          visit(target)
        } else if (visitState === 1) {
          const cycle = stack.slice(stackIndexes[dependency])
          cycle.push(dependency)
          cycles.push(cycle)
        }
      }

      stack.pop()
      stackIndexes[id] = undefined
      visitStates[id] = 2
    }

    for (let i = 0; i < root._records.length; i++) {
      if ((visitStates[root._records[i].id] || 0) === 0) visit(root._records[i])
    }

    return {
      valid: missing.length === 0 && cycles.length === 0,
      missing: missing,
      cycles: cycles
    }
  }

  function _validatedDescriptor(id, descriptor) {
    if (!root._validId(id) || root._findRecord(id) !== null) return null
    if (descriptor === null || typeof descriptor !== "object" || Array.isArray(descriptor)) return null
    if (descriptor.criticality !== "essential" && descriptor.criticality !== "optional") return null
    if (["eager", "resident", "settings", "first_use", "gated_compat", "facade"].indexOf(descriptor.activation) < 0) return null
    // The boot phase decides which queue boot drains the unit in. Optional for
    // a self-registering unit (the activation implies the stage), but when it
    // is declared it has to be one boot actually runs.
    const phase = typeof descriptor.phase === "string" ? descriptor.phase : root._defaultPhase(descriptor.activation)
    if (["floor", "visual", "early", "entrance", "deferred", "first_use", "on_demand"].indexOf(phase) < 0) return null
    if (!Array.isArray(descriptor.dependencies)) return null
    for (let i = 0; i < descriptor.dependencies.length; i++) {
      const dependency = descriptor.dependencies[i]
      if (!root._validId(dependency) || dependency === id) return null
    }
    if (typeof descriptor.resolver !== "function") return null
    if (descriptor.ready !== undefined && descriptor.ready !== null && typeof descriptor.ready !== "function") return null
    if (descriptor.teardown !== undefined && descriptor.teardown !== null && typeof descriptor.teardown !== "function") return null
    if (descriptor.retry === null || typeof descriptor.retry !== "object" || Array.isArray(descriptor.retry)) return null
    if (!root._nonNegativeInteger(descriptor.retry.maxAttempts)) return null
    if (!root._nonNegativeFinite(descriptor.retry.backoffMs)) return null
    if (!root._positiveFinite(descriptor.retry.maxBackoffMs)) return null

    return {
      id: id,
      descriptor: {
        criticality: descriptor.criticality,
        activation: descriptor.activation,
        phase: phase,
        dependencies: descriptor.dependencies.slice(),
        resolver: descriptor.resolver,
        ready: typeof descriptor.ready === "function" ? descriptor.ready : null,
        teardown: typeof descriptor.teardown === "function" ? descriptor.teardown : null,
        retry: {
          maxAttempts: descriptor.retry.maxAttempts,
          backoffMs: descriptor.retry.backoffMs,
          maxBackoffMs: descriptor.retry.maxBackoffMs
        }
      },
      state: "not_started",
      health: "unknown",
      // The record's own copy of the two fields the lifecycle lines report.
      // Mirrored rather than read back off the descriptor because the record is
      // what every reader already holds, and a log line that has to reach
      // through a nested object to say something obvious is a line that reads
      // worse than the field it prints.
      criticality: descriptor.criticality,
      dependencies: descriptor.dependencies.length,
      constructionMs: 0,
      readyMs: 0,
      // Boot-relative arrival: from the gate's own start to the moment this
      // unit reached a terminal state. `readyMs` answers "how long did this
      // unit take", which is a different question from "when during the boot
      // did it land" - a unit that is fast but waits on four dependencies is
      // slow overall, and only this figure shows it. 0 means "has not landed",
      // which is how a gated or first-use unit that was never drained reads.
      totalMs: 0,
      lastError: "",
      retryCount: 0,
      nextRetryMs: 0,
      startedAtMs: 0,
      teardownDone: false,
      // What the last emitted event said. See _changed. Seeded with the
      // record's own initial state and health: a registration is not a
      // transition, and leaving these empty made _changed announce all 51
      // registrations of a boot - a unitChanged per unit before a single one
      // had been activated, which boot turns into a dependency walk and a
      // milestone read for an arrival that has not happened.
      emittedState: "not_started",
      emittedHealth: "unknown",
      emittedError: "",
      emittedRetryCount: 0
    }
  }

  function _activate(record, resetRetries) {
    if (resetRetries) {
      record.retryCount = 0
      record.nextRetryMs = 0
    }
    record.state = "starting"
    record.health = "unknown"
    record.constructionMs = 0
    record.readyMs = 0
    record.totalMs = 0
    record.lastError = ""
    record.nextRetryMs = 0
    record.startedAtMs = Date.now()
    record.teardownDone = false

    // A resolver that declines (returns false) could not reach the type it
    // builds: boot stashes that demand for the half that owns it. Treating
    // the decline as a construction marked the unit ready with nothing behind
    // it - the shell reported ready while its lock surface and session verbs
    // did not exist, and the boot table reported "constructed in 0ms" for a
    // constructor that never ran. So a decline leaves the unit unstarted and
    // the demand alive; refresh() is what retries it once the half lands.
    let available = true
    try {
      available = record.descriptor.resolver() !== false
    } catch (error) {
      record.constructionMs = root._elapsedMs(record.startedAtMs)
      root._fail(record, error)
      return false
    }
    record.constructionMs = root._elapsedMs(record.startedAtMs)
    if (!available) {
      root._defer(record)
      return false
    }

    let ready = true
    try {
      if (typeof record.descriptor.ready === "function") ready = record.descriptor.ready()
    } catch (error) {
      root._fail(record, error)
      return false
    }

    if (ready) root._markReady(record)
    return true
  }

  // Milliseconds since `since`, never negative: a clock step backwards is
  // not a negative duration in a timing record.
  function _elapsedMs(since) {
    return Math.max(0, Date.now() - since)
  }

  function _markReady(record) {
    record.state = "ready"
    record.health = "healthy"
    record.lastError = ""
    record.nextRetryMs = 0
    record.readyMs = root._elapsedMs(record.startedAtMs)
    record.totalMs = root._elapsedMs(root._bootStartedAtMs)
    // One of the three arrivals a unit makes, and the EXPECTED one - so it is
    // DEBUG and not INFO. A boot settles 49 units, which is a fixed fifty-odd
    // line block before the shell has drawn anything, and nobody reads
    // "unit p-base ready (essential, 0 dependencies)" unless they are asking
    // what took 400ms. What they read instead is boot's own verdict,
    // `shell ready in 412ms`, and this is the data behind it.
    //
    // The elapsed figures are boot's to print: it reads them off this record
    // where the boot's own arrival order is visible, so the two figures land
    // under the same milestone rather than in two places that can drift.
    Log.debug("unit " + record.id + " ready" + root._lifecycleSuffix(record))
  }

  function _fail(record, error) {
    record.state = "failed"
    record.health = "failed"
    record.lastError = root._errorMessage(error)
    record.readyMs = 0
    // A failure is a terminal arrival too. Leaving totalMs at 0 would read as
    // "never started" in the boot table, which is a different and wrong claim.
    record.totalMs = root._elapsedMs(root._bootStartedAtMs)
    root._teardown(record)
    root._scheduleRetry(record)
    // WARN, not ERROR, and not DEBUG - this is the one arrival that stays above
    // the default, and it earns that twice over.
    //
    // It is the ONLY line that names the failed unit. Boot's shell-level
    // verdict is `shell degraded in 412ms, start catalog/49/14`, which says
    // that an ESSENTIAL unit failed and not which one; and an OPTIONAL unit
    // that fails does not move that verdict at all, so its failure would be
    // reported nowhere else in the tree. Demote this to DEBUG and an optional
    // unit's failure becomes completely silent.
    //
    // Not ERROR because the reader cannot tell an essential failure from an
    // optional one without the criticality the suffix carries, and what a
    // failure costs the WHOLE shell is `_shellState`'s answer rather than this
    // line's. The message is bounded because it is whatever a consumer's throw
    // happened to stringify to.
    Log.warn("unit " + record.id + " failed" + root._lifecycleSuffix(record)
      + ": " + Log.summarize(record.lastError))
  }

  function _scheduleRetry(record) {
    if (record.retryCount >= record.descriptor.retry.maxAttempts) {
      record.nextRetryMs = 0
      return
    }
    const delay = Math.min(
      record.descriptor.retry.maxBackoffMs,
      record.descriptor.retry.backoffMs * Math.pow(2, record.retryCount)
    )
    record.nextRetryMs = Date.now() + delay
  }

  // A declined resolver: nothing was built, so the record carries no
  // construction figure and the unit is unstarted rather than ready. The lease
  // that demanded it is untouched, which is what makes the retry a refresh
  // rather than a second ensure.
  function _defer(record) {
    record.state = "not_started"
    record.health = "unknown"
    record.constructionMs = 0
    record.readyMs = 0
    record.totalMs = 0
    record.lastError = ""
    record.nextRetryMs = 0
    record.startedAtMs = 0
  }

  function _block(record) {
    record.state = "blocked"
    record.health = "unknown"
    record.lastError = ""
    record.nextRetryMs = 0
  }

  function _teardown(record) {
    if (record.teardownDone) return
    record.teardownDone = true
    if (typeof record.descriptor.teardown !== "function") return
    try {
      record.descriptor.teardown()
    } catch (ignored) {
      return
    }
  }

  function _releaseEntry(entry) {
    if (entry.count > 0) return false
    const index = root._leases.indexOf(entry)
    if (index < 0) return false
    root._leases.splice(index, 1)

    const record = entry.unit
    const counts = root._leaseCounts(record)
    if (root._onDemand(record) && counts.owners === 0) {
      if (record.state === "not_started" || record.state === "blocked") {
        root._stop(record, false)
      } else if (record.state === "starting" || record.state === "ready") {
        root._stop(record, true)
      }
    }
    return true
  }

  function _stop(record, teardown) {
    if (teardown) root._teardown(record)
    record.state = "stopped"
    record.health = "unknown"
    record.lastError = ""
    record.nextRetryMs = 0
    // The third arrival, and also an expected one for a facade unit: the boot
    // drain constructs the resident half and hands its lease straight back. So
    // DEBUG, like `ready` - and the reason it is recorded at all rather than
    // left implicit is that a reader who sees one unit arrive and stop knows
    // which half ran and which was deferred. It fires again at teardown, which
    // is a second reason it cannot be a line that prints by default.
    Log.debug("unit " + record.id + " stopped" + root._lifecycleSuffix(record))
  }

  function _refreshRecord(record) {
    // A unit whose resolver declined is owed another attempt: it was demanded
    // while the half that builds it was still loading, and this refresh is the
    // landing. Only a live demand keeps it retryable - an undemanded unit has
    // nothing left to start.
    if (record.state === "not_started") {
      if (root._leaseCounts(record).owners === 0) return false
      if (!root._dependenciesReady(record)) {
        root._block(record)
        return false
      }
      return root._activate(record, false)
    }
    if (record.state !== "starting") return false
    let ready = true
    try {
      if (typeof record.descriptor.ready === "function") ready = record.descriptor.ready()
    } catch (error) {
      root._fail(record, error)
      return false
    }
    if (!ready) return false
    root._markReady(record)
    return true
  }

  function _dependenciesReady(record) {
    for (let i = 0; i < record.descriptor.dependencies.length; i++) {
      const dependency = root._findRecord(record.descriptor.dependencies[i])
      if (dependency === null || dependency.state !== "ready") return false
    }
    return true
  }

  function _ensureResult(record, lease) {
    if (record.state === "blocked") {
      return {
        ok: false,
        state: "blocked",
        code: "dependency_blocked",
        lease: lease
      }
    }
    if (record.state === "failed") return { ok: false, state: "failed", lease: lease }
    return { ok: true, state: record.state, lease: lease }
  }

  function _publicRecord(record) {
    const counts = root._leaseCounts(record)
    return {
      id: record.id,
      criticality: record.descriptor.criticality,
      activation: record.descriptor.activation,
      phase: record.descriptor.phase,
      dependencies: record.descriptor.dependencies.slice(),
      state: record.state,
      health: record.health,
      constructionMs: record.constructionMs,
      readyMs: record.readyMs,
      totalMs: record.totalMs,
      lastError: record.lastError,
      retryCount: record.retryCount,
      nextRetryMs: record.nextRetryMs,
      ownerCount: counts.owners,
      retainedCount: counts.retained
    }
  }

  function _leaseCounts(record) {
    let owners = 0
    let retained = 0
    for (let i = 0; i < root._leases.length; i++) {
      const entry = root._leases[i]
      if (entry.unit !== record || entry.count <= 0) continue
      owners++
      retained += entry.count
    }
    return { owners: owners, retained: retained }
  }

  // A unit carries not_started, blocked, starting, ready, failed or stopped;
  // "starting" is the constructed-but-not-ready state and refresh() is what
  // promotes it, so no per-unit value is ever "degraded". Degraded is the
  // shell verdict: an essential unit that failed or is no longer running
  // takes the whole shell with it, and an essential unit still coming up
  // holds it at starting.
  function _shellState() {
    let starting = false
    for (let i = 0; i < root._records.length; i++) {
      const record = root._records[i]
      if (record.descriptor.criticality !== "essential") continue
      if (record.state === "failed" || record.state === "stopped") return "degraded"
      if (record.state === "not_started" || record.state === "blocked" || record.state === "starting") starting = true
    }
    return starting ? "starting" : "ready"
  }

  function _findRecord(id) {
    return root._recordIndex[id] !== undefined ? root._recordIndex[id] : null
  }

  function _findLease(record, owner) {
    for (let i = 0; i < root._leases.length; i++) {
      const entry = root._leases[i]
      if (entry.unit === record && entry.owner === owner && entry.count > 0) return entry
    }
    return null
  }

  function _leaseEntry(lease) {
    if (lease === null || typeof lease !== "object") return null
    for (let i = 0; i < root._leases.length; i++) {
      if (root._leases[i].token === lease) return root._leases[i]
    }
    return null
  }

  // On demand covers the units whose expensive half is built by whoever asks
  // for it. "facade" belongs here: the boot drain constructs the resident
  // facade, then hands its lease straight back, so the unit is still only
  // running while somebody holds it. Without that, a boot lease would pin
  // ownerCount at 1 and the teardown hook would never run.
  function _onDemand(record) {
    return record.descriptor.activation === "first_use" || record.descriptor.activation === "gated_compat"
    || record.descriptor.activation === "facade"
  }

  // The stage a unit belongs to when the descriptor does not name one. The
  // catalog always names it; this keeps a self-registering unit legal.
  function _defaultPhase(activation) {
    switch (activation) {
      case "eager":        return "floor"
      case "facade":       return "early"
      case "first_use":    return "first_use"
      case "gated_compat": return "on_demand"
      default:             return "entrance"
    }
  }

  function _validId(id) {
    return SU.isNonEmptyId(id)
  }

  function _validOwner(owner) {
    return typeof owner === "string" && owner.trim() !== ""
  }

  function _nonNegativeInteger(value) {
    return typeof value === "number" && isFinite(value) && value >= 0 && Math.floor(value) === value
  }

  function _nonNegativeFinite(value) {
    return typeof value === "number" && isFinite(value) && value >= 0
  }

  function _positiveFinite(value) {
    return typeof value === "number" && isFinite(value) && value > 0
  }

  // The two fields every lifecycle line ends with, read off the record rather
  // than reached through `descriptor`. `criticality` is what a failure of this
  // unit costs the whole shell, and the dependency count is how much of the
  // boot this unit sits downstream of - which are the two questions a reader
  // has when this unit's line is the last thing in a boot log. Both are the
  // record's own mirrored copies, which is what keeps this a concatenation.
  function _lifecycleSuffix(record) {
    return " (" + record.criticality + ", " + record.dependencies + " dependencies)"
  }

  function _errorMessage(error) {
    return ErrorText.message(error, "Unknown unit error")
  }
}
