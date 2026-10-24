// Probe: the real UnitGate singleton driven with a synthetic catalog.
//
// UnitGate is the boot lifecycle state machine: it registers units, builds
// them in dependency order, tracks readiness, refcounts construction leases
// and bounds retries. None of that needs the real shell, so this probe hands
// UnitGate a catalog it controls and observes the transitions.
//
// The shell's own 45-unit catalog is a declarative literal, so it is checked
// statically by suites/static/boot-catalog-test.sh rather than by
// constructing Boot here - instantiating Boot would start the shell.
//
// UnitGate is a singleton with no unregister, so every id in this probe is
// uniquely prefixed. Groups that assert the shell-level verdict register
// `essential` units and run last, because `_shellState()` reads every
// essential record ever registered.

import QtQuick
import Quickshell
import qs.common

Item {
  id: probe
  width: 1
  height: 1

  // A value containing a newline is escaped so one KV stays one line and the
  // parser never sees a split record.
  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }
  function show(key, value) { kv(key, JSON.stringify(value)) }

  // A minimal valid descriptor. Tests override one field at a time so a
  // rejection always names the field that caused it.
  function unit(id, deps, opts) {
    const o = opts || {}
    return {
      criticality: o.criticality !== undefined ? o.criticality : "optional",
      activation: o.activation !== undefined ? o.activation : "resident",
      dependencies: deps || [],
      resolver: o.resolver || function() { o.onConstruct && o.onConstruct() },
      ready: o.ready,
      teardown: o.teardown,
      retry: o.retry !== undefined ? o.retry : { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    }
  }

  Component.onCompleted: {
    try {
      run()
    } catch (e) {
      kv("probe.error", "" + (e && e.message ? e.message : e))
    }
    console.log("##DONE##")
  }

  function run() {
    kv("gate.exists", typeof UnitGate)
    kv("gate.initial.state.unknown", String(UnitGate.state("nope")))
    show("gate.initial.states", UnitGate.states())

    registrationContract()
    ensureContract()
    readinessContract()
    leaseRefcounting()
    dependencyOrdering()
    retryBounded()
    graphValidation()
    shellVerdict()
  }

  // ---------------------------------------------------------------------
  // register() rejects anything that would make the graph undecidable.
  // ---------------------------------------------------------------------
  function registrationContract() {
    const base = function (id, deps, opts) { return UnitGate.register(id, unit(id, deps, opts)) }

    kv("reg.ok.simple", base("r1", []))
    kv("reg.duplicate", base("r1", []))
    kv("reg.emptyId", base("", []))
    kv("reg.blankId", base("   ", []))
    kv("reg.nonStringId", base(7, []))
    kv("reg.nullId", base(null, []))

    kv("reg.criticality.bad", base("r2", [], { criticality: "maybe" }))
    kv("reg.criticality.essential", base("r3", [], { criticality: "essential" }))
    kv("reg.criticality.optional", base("r4", [], { criticality: "optional" }))

    // The gate accepts six activation modes. `settings` is the one the shell
    // README's table does not list, so it is probed explicitly.
    for (const mode of ["eager", "resident", "settings", "first_use", "gated_compat", "facade"]) {
      kv("reg.activation." + mode, base("ra-" + mode, [], { activation: mode }))
    }
    kv("reg.activation.unknown", base("r5", [], { activation: "lazy" }))

    kv("reg.deps.notArray", base("r6", "paths"))
    kv("reg.deps.selfReference", base("r7", ["r7"]))
    kv("reg.deps.badId", base("r8", [7]))
    kv("reg.deps.blankId", base("r9", ["  "]))
    kv("reg.deps.danglingAllowed", base("r10", ["does-not-exist"]))

    // A resolver is mandatory. Written raw, because `unit()` substitutes a
    // default and would hide the case under test.
    kv("reg.resolver.missing", UnitGate.register("r11", {
      criticality: "optional",
      activation: "resident",
      dependencies: [],
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    }))
    kv("reg.resolver.null", UnitGate.register("r11b", {
      criticality: "optional",
      activation: "resident",
      dependencies: [],
      resolver: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    }))
    kv("reg.resolver.notFunction", base("r12", [], { resolver: "nope" }))
    kv("reg.ready.notFunction", base("r13", [], { ready: "nope" }))
    kv("reg.teardown.notFunction", base("r14", [], { teardown: "nope" }))
    kv("reg.teardown.nullAccepted", base("r15", [], { teardown: null }))
    kv("reg.ready.nullAccepted", base("r16", [], { ready: null }))

    // retry policy is mandatory, so this one descriptor is written raw: the
    // `unit()` helper substitutes a default for an absent retry and would
    // hide exactly the case under test.
    kv("reg.retry.absent", UnitGate.register("r17", {
      criticality: "optional",
      activation: "resident",
      dependencies: [],
      resolver: function() {}
    }))
    kv("reg.retry.undefined", UnitGate.register("r17b", {
      criticality: "optional",
      activation: "resident",
      dependencies: [],
      resolver: function() {},
      retry: undefined
    }))
    kv("reg.retry.null", base("r18", [], { retry: null }))
    kv("reg.retry.array", base("r19", [], { retry: [] }))
    kv("reg.retry.maxAttempts.negative", base("r20", [], { retry: { maxAttempts: -1, backoffMs: 0, maxBackoffMs: 1000 } }))
    kv("reg.retry.maxAttempts.fraction", base("r21", [], { retry: { maxAttempts: 1.5, backoffMs: 0, maxBackoffMs: 1000 } }))
    kv("reg.retry.maxAttempts.nan", base("r22", [], { retry: { maxAttempts: NaN, backoffMs: 0, maxBackoffMs: 1000 } }))
    kv("reg.retry.maxAttempts.string", base("r23", [], { retry: { maxAttempts: "3", backoffMs: 0, maxBackoffMs: 1000 } }))
    kv("reg.retry.maxAttempts.absent", UnitGate.register("r23b", {
      criticality: "optional",
      activation: "resident",
      dependencies: [],
      resolver: function() {},
      retry: { backoffMs: 0, maxBackoffMs: 1000 }
    }))
    kv("reg.retry.backoff.absent", UnitGate.register("r24b", {
      criticality: "optional",
      activation: "resident",
      dependencies: [],
      resolver: function() {},
      retry: { maxAttempts: 1, maxBackoffMs: 1000 }
    }))
    kv("reg.retry.maxBackoff.absent", UnitGate.register("r25b", {
      criticality: "optional",
      activation: "resident",
      dependencies: [],
      resolver: function() {},
      retry: { maxAttempts: 1, backoffMs: 0 }
    }))
    kv("reg.retry.backoff.negative", base("r24", [], { retry: { maxAttempts: 1, backoffMs: -1, maxBackoffMs: 1000 } }))
    kv("reg.retry.backoff.infinity", base("r25", [], { retry: { maxAttempts: 1, backoffMs: Infinity, maxBackoffMs: 1000 } }))
    kv("reg.retry.maxBackoff.zero", base("r26", [], { retry: { maxAttempts: 1, backoffMs: 0, maxBackoffMs: 0 } }))
    kv("reg.retry.maxBackoff.negative", base("r27", [], { retry: { maxAttempts: 1, backoffMs: 0, maxBackoffMs: -5 } }))
    kv("reg.retry.maxBackoff.nan", base("r27b", [], { retry: { maxAttempts: 1, backoffMs: 0, maxBackoffMs: NaN } }))
    kv("reg.retry.zeroAttemptsAllowed", base("r28", [], { retry: { maxAttempts: 0, backoffMs: 100, maxBackoffMs: 1000 } }))

    kv("reg.descriptor.null", UnitGate.register("r29", null))
    kv("reg.descriptor.array", UnitGate.register("r30", []))
    kv("reg.descriptor.string", UnitGate.register("r31", "nope"))

    // The record a good registration produces.
    show("reg.publicRecord.r1", UnitGate.state("r1"))
    show("reg.publicRecord.ra-facade", UnitGate.state("ra-facade"))
  }

  // ---------------------------------------------------------------------
  // ensure() codes its refusals rather than throwing.
  // ---------------------------------------------------------------------
  function ensureContract() {
    show("ensure.unknownUnit", UnitGate.ensure("never-registered", "owner"))
    show("ensure.invalidOwner.empty", UnitGate.ensure("r1", ""))
    show("ensure.invalidOwner.blank", UnitGate.ensure("r1", "   "))
    show("ensure.invalidOwner.null", UnitGate.ensure("r1", null))
    show("ensure.invalidOwner.number", UnitGate.ensure("r1", 3))
    show("ensure.lease.isObject", typeof UnitGate.ensure("r1", "e1").lease)
    kv("ensure.lease.hasToken", typeof UnitGate.ensure("r1", "e1").lease === "object")
    kv("ensure.sameOwner.sameToken", UnitGate.ensure("r1", "e1").lease === UnitGate.ensure("r1", "e1").lease)
    kv("ensure.otherOwner.otherToken", UnitGate.ensure("r1", "e1").lease !== UnitGate.ensure("r1", "e2").lease)
    show("ensure.state.afterReady", UnitGate.ensure("r1", "e1"))
  }

  // ---------------------------------------------------------------------
  // A ready() predicate gates the starting -> ready promotion, and
  // refresh() is what performs it.
  // ---------------------------------------------------------------------
  function readinessContract() {
    let ready = false
    UnitGate.register("s1", unit("s1", [], { ready: function() { return ready } }))
    kv("ready.starting.state", UnitGate.ensure("s1", "o").state)
    kv("ready.starting.health", UnitGate.state("s1").health)
    kv("ready.refreshWhileNotReady", UnitGate.refresh("s1"))
    kv("ready.stillStarting", UnitGate.state("s1").state === "starting")
    ready = true
    kv("ready.refreshPromotes", UnitGate.refresh("s1"))
    kv("ready.state", UnitGate.state("s1").state)
    kv("ready.health", UnitGate.state("s1").health)
    kv("ready.refreshWhenAlreadyReady", UnitGate.refresh("s1"))
    kv("ready.refreshUnknownUnit", UnitGate.refresh("no-such-unit"))

    // No ready predicate at all means ready as soon as the resolver returns.
    UnitGate.register("s2", unit("s2", []))
    kv("ready.noPredicate.state", UnitGate.ensure("s2", "o").state)

    // A resolver that throws fails the unit and records the message.
    UnitGate.register("s3", unit("s3", [], {
      resolver: function() { throw new Error("constructor exploded") }
    }))
    show("ready.resolverThrows.result", UnitGate.ensure("s3", "o"))
    kv("ready.resolverThrows.state", UnitGate.state("s3").state)
    kv("ready.resolverThrows.health", UnitGate.state("s3").health)
    kv("ready.resolverThrows.lastError", UnitGate.state("s3").lastError)
    kv("ready.resolverThrows.constructionMsIsNumber", typeof UnitGate.state("s3").constructionMs === "number")

    // A ready() that throws fails the unit too.
    UnitGate.register("s4", unit("s4", [], {
      ready: function() { throw new Error("predicate exploded") }
    }))
    UnitGate.ensure("s4", "o")
    kv("ready.predicateThrows.state", UnitGate.state("s4").state)
    kv("ready.predicateThrows.lastError", UnitGate.state("s4").lastError)

    // A string throw is captured verbatim, an Error via .message.
    UnitGate.register("s5", unit("s5", [], { resolver: function() { throw "bare string failure" } }))
    UnitGate.ensure("s5", "o")
    kv("ready.stringThrow.lastError", UnitGate.state("s5").lastError)
  }

  // ---------------------------------------------------------------------
  // Leases are refcounted, and an on-demand unit stops when the last
  // holder lets go.
  // ---------------------------------------------------------------------
  function leaseRefcounting() {
    UnitGate.register("l1", unit("l1", []))
    const a = UnitGate.ensure("l1", "la").lease
    kv("lease.ownerCount.oneOwner", UnitGate.state("l1").ownerCount)
    kv("lease.retainedCount.one", UnitGate.state("l1").retainedCount)
    kv("lease.retain", UnitGate.retain(a))
    kv("lease.retainedCount.two", UnitGate.state("l1").retainedCount)
    kv("lease.ownerCount.stillOne", UnitGate.state("l1").ownerCount)
    kv("lease.release.first", UnitGate.release(a))
    kv("lease.retainedCount.backToOne", UnitGate.state("l1").retainedCount)
    kv("lease.stillReady", UnitGate.state("l1").state)
    kv("lease.release.final", UnitGate.release(a))
    kv("lease.retainedCount.zero", UnitGate.state("l1").retainedCount)

    // A resident unit survives its last release; a first_use unit does not.
    kv("lease.resident.staysReady", UnitGate.state("l1").state)

    UnitGate.register("l2", unit("l2", [], { activation: "first_use" }))
    const b = UnitGate.ensure("l2", "lb").lease
    kv("lease.firstUse.readyWhileHeld", UnitGate.state("l2").state)
    UnitGate.release(b)
    kv("lease.firstUse.stoppedOnRelease", UnitGate.state("l2").state)
    kv("lease.firstUse.healthAfterStop", UnitGate.state("l2").health)

    // Re-ensuring a stopped on-demand unit restarts it.
    kv("lease.firstUse.restartsOnReensure", UnitGate.ensure("l2", "lb").state)

    // The three on-demand modes stop on release; eager/resident do not.
    for (const mode of ["eager", "resident", "settings", "gated_compat", "facade"]) {
      const id = "ld-" + mode
      UnitGate.register(id, unit(id, [], { activation: mode }))
      const lease = UnitGate.ensure(id, "od-" + mode).lease
      const before = UnitGate.state(id).state
      UnitGate.release(lease)
      kv("lease.onDemand." + mode + ".afterRelease", UnitGate.state(id).state)
      kv("lease.onDemand." + mode + ".wasReady", before)
    }

    // Teardown runs on the way down, once, and never on a unit without one.
    let teardowns = 0
    UnitGate.register("l3", unit("l3", [], {
      activation: "first_use",
      teardown: function() { teardowns++ }
    }))
    const c = UnitGate.ensure("l3", "lc").lease
    UnitGate.retain(c)
    UnitGate.release(c)
    kv("lease.teardown.notWhileRetained", teardowns)
    UnitGate.release(c)
    kv("lease.teardown.once", teardowns)
    UnitGate.ensure("l3", "lc")
    const d = UnitGate.ensure("l3", "lc").lease
    UnitGate.release(d)
    kv("lease.teardown.againOnRestart", teardowns)

    // A teardown that throws must not escape the release.
    UnitGate.register("l4", unit("l4", [], {
      activation: "first_use",
      teardown: function() { throw new Error("teardown exploded") }
    }))
    const e = UnitGate.ensure("l4", "ld").lease
    kv("lease.teardown.throws.releaseStillSucceeds", UnitGate.release(e))
    kv("lease.teardown.throws.state", UnitGate.state("l4").state)

    // releaseOwner drops every lease an owner holds, in one call.
    UnitGate.register("l5", unit("l5", []))
    UnitGate.register("l6", unit("l6", []))
    UnitGate.ensure("l5", "bulk")
    UnitGate.ensure("l6", "bulk")
    UnitGate.ensure("l5", "other")
    kv("releaseOwner.count", UnitGate.releaseOwner("bulk"))
    kv("releaseOwner.l5.ownersLeft", UnitGate.state("l5").ownerCount)
    kv("releaseOwner.unknownOwner", UnitGate.releaseOwner("nobody"))
    kv("releaseOwner.invalidOwner", UnitGate.releaseOwner(""))
    UnitGate.releaseOwner("other")
    UnitGate.releaseOwner("ld-eager"); UnitGate.releaseOwner("ld-resident")
    UnitGate.releaseOwner("ld-settings"); UnitGate.releaseOwner("ld-gated_compat")
    UnitGate.releaseOwner("ld-facade"); UnitGate.releaseOwner("l2"); UnitGate.releaseOwner("l3")
    UnitGate.releaseOwner("lc"); UnitGate.releaseOwner("ld")
  }

  // ---------------------------------------------------------------------
  // A unit whose dependencies are not ready is blocked, not built, and
  // unblocks once they are.
  // ---------------------------------------------------------------------
  function dependencyOrdering() {
    let depReady = false
    UnitGate.register("d-base", unit("d-base", [], { ready: function() { return depReady } }))
    UnitGate.register("d-mid", unit("d-mid", ["d-base"]))
    UnitGate.register("d-leaf", unit("d-leaf", ["d-mid"]))

    show("dep.leafBeforeBase", UnitGate.ensure("d-leaf", "o"))
    kv("dep.leafBlocked", UnitGate.state("d-leaf").state)
    kv("dep.leafHealth", UnitGate.state("d-leaf").health)
    kv("dep.leaf.lastError", "[" + UnitGate.state("d-leaf").lastError + "]")
    kv("dep.midBeforeBase", UnitGate.ensure("d-mid", "o").state)

    depReady = true
    UnitGate.ensure("d-base", "o")
    UnitGate.refresh("d-base")
    kv("dep.baseReady", UnitGate.state("d-base").state)

    // The gate does not cascade: bringing the base up does not re-drive the
    // units that were blocked behind it, so a dependant stays blocked until
    // it is ensured again. This is why the boot catalog has to be drained in
    // dependency order and re-drained, not merely started once - and it is
    // why the README's "essential 13, in dependency order" is load-bearing.
    kv("dep.cascade.leafStillBlocked", UnitGate.state("d-leaf").state)
    kv("dep.cascade.midStillBlocked", UnitGate.state("d-mid").state)

    // Re-ensuring in order unblocks each link in turn.
    kv("dep.cascade.midOk", UnitGate.ensure("d-mid", "o").ok)
    kv("dep.cascade.midState", UnitGate.state("d-mid").state)
    kv("dep.cascade.leafOk", UnitGate.ensure("d-leaf", "o").ok)
    kv("dep.cascade.leafState", UnitGate.state("d-leaf").state)
    kv("dep.cascade.allReady", UnitGate.state("d-leaf").state === "ready" && UnitGate.state("d-mid").state === "ready")

    // A missing dependency blocks, it does not throw.
    UnitGate.register("d-dangling", unit("d-dangling", ["not-a-unit"]))
    show("dep.dangling", UnitGate.ensure("d-dangling", "o"))
    UnitGate.releaseOwner("o")
  }

  // ---------------------------------------------------------------------
  // Retry is bounded: a unit that cannot become ready is a permanent
  // condition, not something to spin on.
  // ---------------------------------------------------------------------
  function retryBounded() {
    let attempts = 0
    UnitGate.register("t1", unit("t1", [], {
      retry: { maxAttempts: 3, backoffMs: 0, maxBackoffMs: 1000 },
      resolver: function() { attempts++ }
    }))
    UnitGate.ensure("t1", "t1owner")
    kv("retry.healthy.state", UnitGate.state("t1").state)
    kv("retry.healthy.retryDue", UnitGate.retryDue("t1"))
    kv("retry.healthy.retryRefused", UnitGate.retry("t1"))
    kv("retry.healthy.constructions", attempts)

    // A unit with maxAttempts 0 is built exactly once and never retried: a
    // permanent condition, not something to spin on.
    UnitGate.register("t1b", unit("t1b", [], {
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 },
      resolver: function() { throw new Error("never works") }
    }))
    UnitGate.ensure("t1b", "t1owner")
    kv("retry.maxAttemptsZero.state", UnitGate.state("t1b").state)
    kv("retry.maxAttemptsZero.due", UnitGate.retryDue("t1b"))
    kv("retry.maxAttemptsZero.retryRefused", UnitGate.retry("t1b"))
    kv("retry.maxAttemptsZero.nextRetryMs", UnitGate.state("t1b").nextRetryMs)

    // A failing unit with a real budget. retry() returns false here because
    // the unit failed again, but it did consume one attempt - so the budget
    // is what bounds the loop, not the return value.
    UnitGate.register("t2", unit("t2", [], {
      retry: { maxAttempts: 2, backoffMs: 0, maxBackoffMs: 1000 },
      ready: function() { throw new Error("not yet") }
    }))
    UnitGate.ensure("t2", "t2owner")
    kv("retry.failing.state", UnitGate.state("t2").state)
    kv("retry.failing.retryCount.initial", UnitGate.state("t2").retryCount)
    kv("retry.failing.dueWithZeroBackoff", UnitGate.retryDue("t2"))
    kv("retry.failing.retryAttemptReturn", UnitGate.retry("t2"))
    kv("retry.failing.retryCount.afterOne", UnitGate.state("t2").retryCount)
    kv("retry.failing.stillFailing", UnitGate.state("t2").state)
    kv("retry.failing.dueAgain", UnitGate.retryDue("t2"))
    UnitGate.retry("t2")
    kv("retry.failing.exhausted.retryCount", UnitGate.state("t2").retryCount)
    kv("retry.failing.exhausted.retryRefused", UnitGate.retry("t2"))
    kv("retry.failing.exhausted.due", UnitGate.retryDue("t2"))
    kv("retry.failing.exhausted.nextRetryMs", UnitGate.state("t2").nextRetryMs)
    kv("retry.failing.exhausted.constructionsBound", UnitGate.state("t2").retryCount <= 2)

    // A retry that now succeeds brings the unit up.
    let fixed = false
    UnitGate.register("t2b", unit("t2b", [], {
      retry: { maxAttempts: 3, backoffMs: 0, maxBackoffMs: 1000 },
      ready: function() { if (!fixed) throw new Error("not yet"); return true }
    }))
    UnitGate.ensure("t2b", "t2owner")
    kv("retry.recovers.beforeFix", UnitGate.state("t2b").state)
    fixed = true
    kv("retry.recovers.retryAccepted", UnitGate.retry("t2b"))
    kv("retry.recovers.state", UnitGate.state("t2b").state)
    kv("retry.recovers.health", UnitGate.state("t2b").health)
    kv("retry.recovers.retryCountReset", UnitGate.state("t2b").retryCount)

    // A backoff in the future is not due yet, and retry() refuses it.
    UnitGate.register("t3", unit("t3", [], {
      retry: { maxAttempts: 5, backoffMs: 60000, maxBackoffMs: 120000 },
      ready: function() { throw new Error("still failing") }
    }))
    UnitGate.ensure("t3", "t3owner")
    kv("retry.backoff.isDue", UnitGate.retryDue("t3"))
    kv("retry.backoff.retryRefused", UnitGate.retry("t3"))
    kv("retry.backoff.nextRetryInFuture", UnitGate.state("t3").nextRetryMs > Date.now())

    // retry() only applies to a failed unit, and only while a holder exists:
    // a failure nobody is waiting on must not keep a construction budget
    // alive in the background.
    UnitGate.register("t4", unit("t4", [], { retry: { maxAttempts: 3, backoffMs: 0, maxBackoffMs: 1000 } }))
    kv("retry.unensured.notDue", UnitGate.retryDue("t4"))
    UnitGate.ensure("t4", "t4owner")
    kv("retry.ready.retryRefused", UnitGate.retry("t4"))
    kv("retry.unknownUnit", UnitGate.retry("no-such-unit"))
    kv("retry.unknownUnit.due", UnitGate.retryDue("no-such-unit"))

    // A holder that lets go and comes back finds the unit still due.
    UnitGate.register("t6", unit("t6", [], {
      retry: { maxAttempts: 3, backoffMs: 0, maxBackoffMs: 1000 },
      ready: function() { throw new Error("failing") }
    }))
    UnitGate.ensure("t6", "t6owner")
    UnitGate.releaseOwner("t6owner")
    kv("retry.holderReleased.owners", UnitGate.state("t6").ownerCount)
    kv("retry.holderReacquired.isDue", UnitGate.retryDue("t6"))
    // retry() reports whether the unit came up, not whether the attempt was
    // allowed; a unit that fails again returns false and still burns one.
    kv("retry.holderReacquired.retryAttemptReturn", UnitGate.retry("t6"))
    kv("retry.holderReacquired.stillFailed", UnitGate.state("t6").state)

    // Backoff doubling is capped by maxBackoffMs.
    UnitGate.register("t7", unit("t7", [], {
      retry: { maxAttempts: 10, backoffMs: 1000, maxBackoffMs: 2000 },
      ready: function() { throw new Error("failing") }
    }))
    UnitGate.ensure("t7", "t7owner")
    const firstDelay = UnitGate.state("t7").nextRetryMs - Date.now()
    UnitGate.retry("t7")
    const secondDelay = UnitGate.state("t7").nextRetryMs - Date.now()
    kv("retry.backoff.cappedAtMax", secondDelay <= 2000)
    kv("retry.backoff.firstWithinCap", firstDelay <= 2000)
    UnitGate.releaseOwner("t1owner"); UnitGate.releaseOwner("t2owner")
    UnitGate.releaseOwner("t3owner"); UnitGate.releaseOwner("t4owner")
    UnitGate.releaseOwner("t6owner")
    UnitGate.releaseOwner("t7owner")
  }

  // ---------------------------------------------------------------------
  // validateGraph() is what makes the catalog's undecidable order a
  // reported error rather than a startup that never finishes.
  //
  // The gate is a singleton, so validateGraph() always reports every record
  // ever registered - including the deliberately dangling ones other groups
  // left behind. Each case below therefore asserts about its OWN id prefix
  // rather than about the whole result, which is what stops one group's
  // fixtures from deciding another group's verdict.
  // ---------------------------------------------------------------------
  function cyclesMentioning(report, prefix) {
    return report.cycles.filter((cycle) => cycle.some((id) => id.indexOf(prefix) === 0))
  }
  function missingMentioning(report, prefix) {
    return report.missing.filter((id) => id.indexOf(prefix) === 0)
  }

  function graphValidation() {
    // A clean chain among fresh ids: no cycle and no missing id of its own.
    UnitGate.register("ga1", unit("ga1", []))
    UnitGate.register("ga2", unit("ga2", ["ga1"]))
    UnitGate.register("ga3", unit("ga3", ["ga2"]))
    const chain = UnitGate.validateGraph()
    kv("graph.chain.noOwnCycle", cyclesMentioning(chain, "ga").length === 0)
    kv("graph.chain.noOwnMissing", missingMentioning(chain, "ga").length === 0)
    show("graph.chain.fullReport", chain)

    // A dangling dependency is reported by name, once, however many units
    // point at it.
    UnitGate.register("gb1", unit("gb1", ["gb-absent"]))
    UnitGate.register("gb2", unit("gb2", ["gb-absent"]))
    const missing = UnitGate.validateGraph()
    show("graph.missing", missingMentioning(missing, "gb"))
    kv("graph.missing.deduplicated", missingMentioning(missing, "gb").length === 1)
    kv("graph.missing.invalid", missing.valid === false)

    // A two-node cycle is reported closed, naming the entry point twice.
    UnitGate.register("gc1", unit("gc1", ["gc2"]))
    UnitGate.register("gc2", unit("gc2", ["gc1"]))
    const two = UnitGate.validateGraph()
    show("graph.cycle2", cyclesMentioning(two, "gc"))
    kv("graph.cycle2.reportedOnce", cyclesMentioning(two, "gc").length === 1)
    kv("graph.cycle2.closed", JSON.stringify(cyclesMentioning(two, "gc")[0]) === JSON.stringify(["gc1", "gc2", "gc1"]))

    // A three-node cycle is reported whole, not truncated at the first repeat.
    UnitGate.register("gd1", unit("gd1", ["gd2"]))
    UnitGate.register("gd2", unit("gd2", ["gd3"]))
    UnitGate.register("gd3", unit("gd3", ["gd1"]))
    const three = UnitGate.validateGraph()
    show("graph.cycle3", cyclesMentioning(three, "gd"))
    kv("graph.cycle3.whole", cyclesMentioning(three, "gd")[0].length === 4)
    kv("graph.cycle3.invalid", three.valid === false)

    // A diamond is a DAG, not a cycle: two units sharing a dependency must
    // not be mistaken for a loop.
    UnitGate.register("ge1", unit("ge1", []))
    UnitGate.register("ge2", unit("ge2", ["ge1"]))
    UnitGate.register("ge3", unit("ge3", ["ge1"]))
    UnitGate.register("ge4", unit("ge4", ["ge2", "ge3"]))
    const diamond = UnitGate.validateGraph()
    kv("graph.diamond.noOwnCycle", cyclesMentioning(diamond, "ge").length === 0)
    kv("graph.diamond.noOwnMissing", missingMentioning(diamond, "ge").length === 0)

    // A self-referencing dependency is refused at registration, so the graph
    // walk never has to defend against one.
    kv("graph.selfDepRejectedAtRegistration", UnitGate.register("gf1", unit("gf1", ["gf1"])))
  }

  // ---------------------------------------------------------------------
  // _shellState() is the verdict: an essential unit that failed or stopped
  // takes the whole shell with it. Run last - every essential record ever
  // registered counts.
  // ---------------------------------------------------------------------
  function shellVerdict() {
    // The registration group left one essential unit (r3) registered and
    // never started, so the verdict cannot be read as "nothing essential is
    // up" until that is settled. Satisfying it first is what makes the rest
    // of this group a real assertion rather than an accident of fixture
    // ordering.
    show("shell.units.count", Object.keys(UnitGate.states().units).length)
    show("shell.withStrayUnstartedEssential", UnitGate.states().shell)
    UnitGate.ensure("r3", "shellowner")
    show("shell.afterStraySettled", UnitGate.states().shell)

    // No essential unit is running yet: the shell is coming up, not broken.
    UnitGate.register("e1", unit("e1", [], { criticality: "essential" }))
    UnitGate.register("e2", unit("e2", ["e1"], { criticality: "essential" }))
    show("shell.unstartedEssential", UnitGate.states().shell)

    // An essential unit that is constructed but not ready holds the shell at
    // starting rather than declaring it degraded.
    let e2Ready = false
    UnitGate.register("e2b", unit("e2b", [], {
      criticality: "essential",
      ready: function() { return e2Ready }
    }))
    UnitGate.ensure("e2b", "shellowner")
    show("shell.essentialStarting", UnitGate.states().shell)
    e2Ready = true
    UnitGate.refresh("e2b")

    UnitGate.ensure("e1", "shellowner")
    UnitGate.ensure("e2", "shellowner")
    show("shell.allEssentialReady", UnitGate.states().shell)

    // An optional unit that fails is isolated: the shell verdict is unchanged.
    UnitGate.register("o-fail", unit("o-fail", [], {
      criticality: "optional",
      resolver: function() { throw new Error("optional exploded") }
    }))
    UnitGate.ensure("o-fail", "shellowner")
    show("shell.afterOptionalFailure", UnitGate.states().shell)
    kv("shell.optionalFailed.ownState", UnitGate.state("o-fail").state)
    kv("shell.optionalFailed.isolated", UnitGate.states().shell.state === "ready")

    // A failing essential unit takes the whole shell with it - that is the
    // difference between a degraded shell and a half-drawn one.
    UnitGate.register("e3", unit("e3", [], {
      criticality: "essential",
      resolver: function() { throw new Error("essential exploded") }
    }))
    UnitGate.ensure("e3", "shellowner")
    show("shell.essentialFailed", UnitGate.states().shell)
    kv("shell.essentialFailed.unitState", UnitGate.state("e3").state)

    // An essential unit that stops is as terminal as one that fails.
    UnitGate.register("e4", unit("e4", [], { criticality: "essential", activation: "first_use" }))
    UnitGate.ensure("e4", "shellowner")
    kv("shell.essentialReadyBeforeStop", UnitGate.state("e4").state)
    UnitGate.releaseOwner("shellowner")
    kv("shell.essentialStoppedState", UnitGate.state("e4").state)
    show("shell.afterEssentialStop", UnitGate.states().shell)
  }
}
