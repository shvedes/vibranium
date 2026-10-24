#!/bin/bash
# Suite: UnitGate - the boot lifecycle state machine, observed through a live
# Quickshell.
#
# The probe (suites/qml/probes/unitgate.qml) drives the real singleton with a
# synthetic catalog and prints one key per observation. This file turns those
# keys into assertions.
#
# Headless: QT_QPA_PLATFORM=offscreen, and the probe runs as an ordinary Item
# with no window, so nothing needs a compositor. qp_run kills the process as
# soon as the probe prints ##DONE##, which is why the whole suite is fast.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "unitgate" "boot lifecycle: register, ensure, leases, retry, graph, shell verdict"
require_qs

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/unitgate.qml" 25; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_not_empty "the probe produced observations" "$(qp_get gate.exists)"

t_section "the gate is reachable and starts empty"
t_eq "the singleton is constructed" "object" "$(qp_get gate.exists)"
t_eq "state() of an unregistered id is null" "null" "$(qp_get gate.initial.state.unknown)"
t_eq "states() starts with no units" '{"shell":{"state":"ready","health":"healthy"},"units":{}}' "$(qp_get gate.initial.states)"

t_section "register() accepts a well-formed descriptor"
t_eq "a minimal unit registers" "true" "$(qp_get reg.ok.simple)"
t_eq "criticality essential is accepted" "true" "$(qp_get reg.criticality.essential)"
t_eq "criticality optional is accepted" "true" "$(qp_get reg.criticality.optional)"
t_eq "maxAttempts 0 is a legal policy" "true" "$(qp_get reg.retry.zeroAttemptsAllowed)"
t_eq "a null teardown is accepted" "true" "$(qp_get reg.teardown.nullAccepted)"
t_eq "a null ready predicate is accepted" "true" "$(qp_get reg.ready.nullAccepted)"
t_eq "a dependency on an unregistered id is allowed at registration" "true" "$(qp_get reg.deps.danglingAllowed)"

t_section "register() refuses a descriptor that makes the graph undecidable"
t_eq "a duplicate id" "false" "$(qp_get reg.duplicate)"
t_eq "an empty id" "false" "$(qp_get reg.emptyId)"
t_eq "a whitespace-only id" "false" "$(qp_get reg.blankId)"
t_eq "a non-string id" "false" "$(qp_get reg.nonStringId)"
t_eq "a null id" "false" "$(qp_get reg.nullId)"
t_eq "an unknown criticality" "false" "$(qp_get reg.criticality.bad)"
t_eq "an unknown activation mode" "false" "$(qp_get reg.activation.unknown)"
t_eq "dependencies that are not an array" "false" "$(qp_get reg.deps.notArray)"
t_eq "a self-referencing dependency" "false" "$(qp_get reg.deps.selfReference)"
t_eq "a non-string dependency id" "false" "$(qp_get reg.deps.badId)"
t_eq "a blank dependency id" "false" "$(qp_get reg.deps.blankId)"
t_eq "a missing resolver" "false" "$(qp_get reg.resolver.missing)"
t_eq "a null resolver" "false" "$(qp_get reg.resolver.null)"
t_eq "a non-function resolver" "false" "$(qp_get reg.resolver.notFunction)"
t_eq "a non-function ready predicate" "false" "$(qp_get reg.ready.notFunction)"
t_eq "a non-function teardown" "false" "$(qp_get reg.teardown.notFunction)"
t_eq "a null descriptor" "false" "$(qp_get reg.descriptor.null)"
t_eq "an array descriptor" "false" "$(qp_get reg.descriptor.array)"
t_eq "a string descriptor" "false" "$(qp_get reg.descriptor.string)"

t_section "the retry policy is mandatory and bounded"
t_eq "a descriptor with no retry key" "false" "$(qp_get reg.retry.absent)"
t_eq "an explicit undefined retry" "false" "$(qp_get reg.retry.undefined)"
t_eq "a null retry" "false" "$(qp_get reg.retry.null)"
t_eq "an array retry" "false" "$(qp_get reg.retry.array)"
t_eq "a negative maxAttempts" "false" "$(qp_get reg.retry.maxAttempts.negative)"
t_eq "a fractional maxAttempts" "false" "$(qp_get reg.retry.maxAttempts.fraction)"
t_eq "a NaN maxAttempts" "false" "$(qp_get reg.retry.maxAttempts.nan)"
t_eq "a string maxAttempts" "false" "$(qp_get reg.retry.maxAttempts.string)"
t_eq "a missing maxAttempts" "false" "$(qp_get reg.retry.maxAttempts.absent)"
t_eq "a missing backoffMs" "false" "$(qp_get reg.retry.backoff.absent)"
t_eq "a missing maxBackoffMs" "false" "$(qp_get reg.retry.maxBackoff.absent)"
t_eq "a negative backoffMs" "false" "$(qp_get reg.retry.backoff.negative)"
t_eq "an infinite backoffMs" "false" "$(qp_get reg.retry.backoff.infinity)"
t_eq "a zero maxBackoffMs" "false" "$(qp_get reg.retry.maxBackoff.zero)"
t_eq "a negative maxBackoffMs" "false" "$(qp_get reg.retry.maxBackoff.negative)"
t_eq "a NaN maxBackoffMs" "false" "$(qp_get reg.retry.maxBackoff.nan)"

t_section "the six activation modes are the whole vocabulary"
t_eq "eager" "true" "$(qp_get reg.activation.eager)"
t_eq "resident" "true" "$(qp_get reg.activation.resident)"
t_eq "settings" "true" "$(qp_get reg.activation.settings)"
t_eq "first_use" "true" "$(qp_get reg.activation.first_use)"
t_eq "gated_compat" "true" "$(qp_get reg.activation.gated_compat)"
t_eq "facade" "true" "$(qp_get reg.activation.facade)"
# The gate accepts six activation modes and boot/README.md's table lists all
# six. Five of them are in use by the catalog and `settings` is not, so the
# table is wider than the catalog. Recorded here so the difference is visible
# from the suite rather than only from the source.
t_note "the gate accepts a sixth activation mode, settings, which no descriptor in the boot catalog declares"

t_section "the record a registration produces"
t_eq "a fresh unit starts not_started" "not_started" "$(sed -n 's/.*"state":"\([a-z_]*\)".*/\1/p' <<<"$(qp_get reg.publicRecord.r1)" | head -1)"
t_eq "its health is unknown" "unknown" "$(sed -n 's/.*"health":"\([a-z]*\)".*/\1/p' <<<"$(qp_get reg.publicRecord.r1)" | head -1)"
t_eq "it has no owners" "0" "$(sed -n 's/.*"ownerCount":\([0-9]*\).*/\1/p' <<<"$(qp_get reg.publicRecord.r1)")"
t_eq "it echoes its dependencies" "[]" "$(sed -n 's/.*"dependencies":\(\[[^]]*\]\).*/\1/p' <<<"$(qp_get reg.publicRecord.r1)")"

t_section "ensure() codes its refusals"
t_eq "an unregistered unit" '{"ok":false,"code":"unknown_unit"}' "$(qp_get ensure.unknownUnit)"
t_eq "an empty owner" '{"ok":false,"code":"invalid_owner"}' "$(qp_get ensure.invalidOwner.empty)"
t_eq "a whitespace-only owner" '{"ok":false,"code":"invalid_owner"}' "$(qp_get ensure.invalidOwner.blank)"
t_eq "a null owner" '{"ok":false,"code":"invalid_owner"}' "$(qp_get ensure.invalidOwner.null)"
t_eq "a numeric owner" '{"ok":false,"code":"invalid_owner"}' "$(qp_get ensure.invalidOwner.number)"
t_eq "one owner gets one lease token" "true" "$(qp_get ensure.lease.hasToken)"
t_eq "the same owner reuses its token" "true" "$(qp_get ensure.sameOwner.sameToken)"
t_eq "a different owner gets a different token" "true" "$(qp_get ensure.otherOwner.otherToken)"

t_section "a ready predicate gates the starting -> ready promotion"
t_eq "an unsatisfied predicate leaves the unit starting" "starting" "$(qp_get ready.starting.state)"
t_eq "and its health unknown" "unknown" "$(qp_get ready.starting.health)"
t_eq "refresh() is a no-op while not ready" "false" "$(qp_get ready.refreshWhileNotReady)"
t_eq "the unit is still starting" "true" "$(qp_get ready.stillStarting)"
t_eq "refresh() promotes once the predicate is satisfied" "true" "$(qp_get ready.refreshPromotes)"
t_eq "the state is ready" "ready" "$(qp_get ready.state)"
t_eq "the health is healthy" "healthy" "$(qp_get ready.health)"
t_eq "refresh() on an already-ready unit is a no-op" "false" "$(qp_get ready.refreshWhenAlreadyReady)"
t_eq "refresh() on an unknown unit" "false" "$(qp_get ready.refreshUnknownUnit)"
t_eq "no predicate means ready as soon as the resolver returns" "ready" "$(qp_get ready.noPredicate.state)"

t_section "a throwing resolver or predicate fails the unit and is recorded"
t_eq "the ensure result" '{"ok":false,"state":"failed","lease":{}}' "$(qp_get ready.resolverThrows.result)"
t_eq "the state" "failed" "$(qp_get ready.resolverThrows.state)"
t_eq "the health" "failed" "$(qp_get ready.resolverThrows.health)"
t_eq "the message is captured" "constructor exploded" "$(qp_get ready.resolverThrows.lastError)"
t_eq "constructionMs is measured" "true" "$(qp_get ready.resolverThrows.constructionMsIsNumber)"
t_eq "a throwing predicate fails the unit" "failed" "$(qp_get ready.predicateThrows.state)"
t_eq "with its own message" "predicate exploded" "$(qp_get ready.predicateThrows.lastError)"
t_eq "a string throw is captured verbatim" "bare string failure" "$(qp_get ready.stringThrow.lastError)"

t_section "leases are refcounted"
t_eq "one owner" "1" "$(qp_get lease.ownerCount.oneOwner)"
t_eq "one hold" "1" "$(qp_get lease.retainedCount.one)"
t_eq "retain() succeeds" "true" "$(qp_get lease.retain)"
t_eq "two holds, still one owner" "2|1" "$(qp_get lease.retainedCount.two)|$(qp_get lease.ownerCount.stillOne)"
t_eq "the first release only decrements" "true|1|ready" "$(qp_get lease.release.first)|$(qp_get lease.retainedCount.backToOne)|$(qp_get lease.stillReady)"
t_eq "the last release drops the lease" "true|0" "$(qp_get lease.release.final)|$(qp_get lease.retainedCount.zero)"
t_eq "a resident unit survives its last release" "ready" "$(qp_get lease.resident.staysReady)"

t_section "on-demand units stop when the last holder lets go"
t_eq "a first_use unit is ready while held" "ready" "$(qp_get lease.firstUse.readyWhileHeld)"
t_eq "and stopped once released" "stopped" "$(qp_get lease.firstUse.stoppedOnRelease)"
t_eq "with its health reset" "unknown" "$(qp_get lease.firstUse.healthAfterStop)"
t_eq "re-ensuring restarts it" "ready" "$(qp_get lease.firstUse.restartsOnReensure)"
t_eq "eager survives release" "ready" "$(qp_get lease.onDemand.eager.afterRelease)"
t_eq "resident survives release" "ready" "$(qp_get lease.onDemand.resident.afterRelease)"
t_eq "settings survives release" "ready" "$(qp_get lease.onDemand.settings.afterRelease)"
t_eq "gated_compat stops on release" "stopped" "$(qp_get lease.onDemand.gated_compat.afterRelease)"
t_eq "facade stops on release" "stopped" "$(qp_get lease.onDemand.facade.afterRelease)"

t_section "teardown runs once on the way down and a throwing teardown is contained"
t_eq "not while a hold remains" "0" "$(qp_get lease.teardown.notWhileRetained)"
t_eq "once when the last hold goes" "1" "$(qp_get lease.teardown.once)"
t_eq "again after a restart" "2" "$(qp_get lease.teardown.againOnRestart)"
t_eq "a throwing teardown does not escape release" "true" "$(qp_get lease.teardown.throws.releaseStillSucceeds)"
t_eq "and the unit still reaches stopped" "stopped" "$(qp_get lease.teardown.throws.state)"

t_section "releaseOwner drops every lease an owner holds"
t_eq "the count it reports" "2" "$(qp_get releaseOwner.count)"
t_eq "leaving the other owner's hold intact" "1" "$(qp_get releaseOwner.l5.ownersLeft)"
t_eq "an unknown owner releases nothing" "0" "$(qp_get releaseOwner.unknownOwner)"
t_eq "an invalid owner releases nothing" "0" "$(qp_get releaseOwner.invalidOwner)"

t_section "a unit whose dependency is not ready is blocked, not built"
t_eq "ensure reports dependency_blocked" '{"ok":false,"state":"blocked","code":"dependency_blocked","lease":{}}' "$(qp_get dep.leafBeforeBase)"
t_eq "the state is blocked" "blocked" "$(qp_get dep.leafBlocked)"
t_eq "its health stays unknown" "unknown" "$(qp_get dep.leafHealth)"
t_eq "and no error is recorded" "[]" "$(qp_get dep.leaf.lastError)"
t_eq "the middle of the chain is blocked too" "blocked" "$(qp_get dep.midBeforeBase)"
t_eq "a missing dependency blocks rather than throwing" '{"ok":false,"state":"blocked","code":"dependency_blocked","lease":{}}' "$(qp_get dep.dangling)"

t_section "bringing a dependency up does not cascade"
# A real property of the gate, and the reason the boot catalog must be
# drained in dependency order and re-drained: unblocking a base does not
# re-drive the units that were blocked behind it.
t_eq "the base reaches ready" "ready" "$(qp_get dep.baseReady)"
t_eq "but the leaf stays blocked" "blocked" "$(qp_get dep.cascade.leafStillBlocked)"
t_eq "and so does the middle" "blocked" "$(qp_get dep.cascade.midStillBlocked)"
t_eq "re-ensuring the middle unblocks it" "true|ready" "$(qp_get dep.cascade.midOk)|$(qp_get dep.cascade.midState)"
t_eq "then the leaf follows" "true|ready" "$(qp_get dep.cascade.leafOk)|$(qp_get dep.cascade.leafState)"
t_eq "the whole chain is up" "true" "$(qp_get dep.cascade.allReady)"

t_section "a healthy unit is never retried"
t_eq "its state" "ready" "$(qp_get retry.healthy.state)"
t_eq "retryDue is false" "false" "$(qp_get retry.healthy.retryDue)"
t_eq "retry() refuses it" "false" "$(qp_get retry.healthy.retryRefused)"
t_eq "it was constructed exactly once" "1" "$(qp_get retry.healthy.constructions)"

t_section "a permanent failure is a permanent condition, not a spin"
t_eq "maxAttempts 0 leaves the unit failed" "failed" "$(qp_get retry.maxAttemptsZero.state)"
t_eq "with no retry due" "false" "$(qp_get retry.maxAttemptsZero.due)"
t_eq "and retry() refused" "false" "$(qp_get retry.maxAttemptsZero.retryRefused)"
t_eq "and no retry scheduled" "0" "$(qp_get retry.maxAttemptsZero.nextRetryMs)"

t_section "a bounded budget bounds the loop"
t_eq "the unit is failed" "failed" "$(qp_get retry.failing.state)"
t_eq "no attempt spent yet" "0" "$(qp_get retry.failing.retryCount.initial)"
t_eq "a zero backoff makes it due at once" "true" "$(qp_get retry.failing.dueWithZeroBackoff)"
t_eq "retry() reports the unit did not come up" "false" "$(qp_get retry.failing.retryAttemptReturn)"
t_eq "but it did spend an attempt" "1" "$(qp_get retry.failing.retryCount.afterOne)"
t_eq "and it is still failed" "failed" "$(qp_get retry.failing.stillFailing)"
t_eq "and due again with budget left" "true" "$(qp_get retry.failing.dueAgain)"
t_eq "the budget stops at maxAttempts" "2" "$(qp_get retry.failing.exhausted.retryCount)"
t_eq "and no further retry is due" "false" "$(qp_get retry.failing.exhausted.due)"
t_eq "and retry() is refused" "false" "$(qp_get retry.failing.exhausted.retryRefused)"
t_eq "and the schedule is cleared rather than left in the future" "0" "$(qp_get retry.failing.exhausted.nextRetryMs)"

t_section "a retry that succeeds brings the unit up"
t_eq "failed before the fix" "failed" "$(qp_get retry.recovers.beforeFix)"
t_eq "retry() is accepted" "true" "$(qp_get retry.recovers.retryAccepted)"
t_eq "the unit is ready" "ready" "$(qp_get retry.recovers.state)"
t_eq "and healthy" "healthy" "$(qp_get retry.recovers.health)"
# The counter is not reset by a successful retry: only a fresh ensure() with
# resetRetries clears it, so the budget still bounds the unit's whole life.
t_eq "the attempt is still counted" "1" "$(qp_get retry.recovers.retryCountReset)"

t_section "a backoff in the future is not due"
t_eq "retryDue is false" "false" "$(qp_get retry.backoff.isDue)"
t_eq "retry() refuses it" "false" "$(qp_get retry.backoff.retryRefused)"
t_eq "the next attempt is scheduled ahead of now" "true" "$(qp_get retry.backoff.nextRetryInFuture)"

t_section "retry() only applies to a failed unit that somebody holds"
t_eq "an unensured unit is not due" "false" "$(qp_get retry.unensured.notDue)"
t_eq "a ready unit is refused" "false" "$(qp_get retry.ready.retryRefused)"
t_eq "an unknown unit" "false" "$(qp_get retry.unknownUnit)"
t_eq "an unknown unit is not due" "false" "$(qp_get retry.unknownUnit.due)"
t_eq "a released holder leaves no owners" "0" "$(qp_get retry.holderReleased.owners)"
t_eq "re-acquiring makes it due again" "true" "$(qp_get retry.holderReacquired.isDue)"
t_eq "the attempt runs but the unit fails again" "false|failed" "$(qp_get retry.holderReacquired.retryAttemptReturn)|$(qp_get retry.holderReacquired.stillFailed)"

t_section "backoff doubling is capped by maxBackoffMs"
t_eq "the first delay is within the cap" "true" "$(qp_get retry.backoff.firstWithinCap)"
t_eq "the second delay is within the cap" "true" "$(qp_get retry.backoff.cappedAtMax)"

t_section "validateGraph reports the catalog's undecidable order"
t_eq "a chain has no cycle of its own" "true" "$(qp_get graph.chain.noOwnCycle)"
t_eq "a chain has no missing dependency of its own" "true" "$(qp_get graph.chain.noOwnMissing)"
t_eq "a dangling dependency is named" '["gb-absent"]' "$(qp_get graph.missing)"
t_eq "and reported once however many units name it" "true" "$(qp_get graph.missing.deduplicated)"
t_eq "which makes the graph invalid" "true" "$(qp_get graph.missing.invalid)"
t_eq "a two-node cycle is closed" '[["gc1","gc2","gc1"]]' "$(qp_get graph.cycle2)"
t_eq "and reported once" "true" "$(qp_get graph.cycle2.reportedOnce)"
t_eq "a three-node cycle is reported whole" "true" "$(qp_get graph.cycle3.whole)"
t_eq "and invalidates the graph" "true" "$(qp_get graph.cycle3.invalid)"
t_eq "a diamond is not a cycle" "true" "$(qp_get graph.diamond.noOwnCycle)"
t_eq "and names nothing missing" "true" "$(qp_get graph.diamond.noOwnMissing)"
t_eq "a self-referencing dependency never reaches the walk" "false" "$(qp_get graph.selfDepRejectedAtRegistration)"

t_section "the shell verdict: an essential unit takes the shell with it"
t_eq "with a stray unstarted essential unit the shell is starting" '{"state":"starting","health":"starting"}' "$(qp_get shell.withStrayUnstartedEssential)"
t_eq "once it settles the shell is ready" '{"state":"ready","health":"healthy"}' "$(qp_get shell.afterStraySettled)"
t_eq "an unstarted essential unit holds it at starting" '{"state":"starting","health":"starting"}' "$(qp_get shell.unstartedEssential)"
t_eq "a constructed-but-not-ready essential unit too" '{"state":"starting","health":"starting"}' "$(qp_get shell.essentialStarting)"
t_eq "all essential units ready" '{"state":"ready","health":"healthy"}' "$(qp_get shell.allEssentialReady)"
t_eq "a failing optional unit is isolated" "failed" "$(qp_get shell.optionalFailed.ownState)"
t_eq "and the shell verdict is unchanged" "true" "$(qp_get shell.optionalFailed.isolated)"
t_eq "a failing essential unit degrades the shell" '{"state":"degraded","health":"degraded"}' "$(qp_get shell.essentialFailed)"
t_eq "and the unit itself is failed" "failed" "$(qp_get shell.essentialFailed.unitState)"
t_eq "a stopped essential unit is as terminal as a failed one" "ready|stopped" "$(qp_get shell.essentialReadyBeforeStop)|$(qp_get shell.essentialStoppedState)"
t_eq "and degrades the shell" '{"state":"degraded","health":"degraded"}' "$(qp_get shell.afterEssentialStop)"

t_summary
