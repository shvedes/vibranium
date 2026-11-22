#!/bin/bash
# Suite: the AnnotationActions demand latch, headless.
#
# The probe imports the real qs.common singleton and drives it with stub hooks,
# so no compositor, screen or annotation controller is needed. It pins the
# terminal-vs-not-ready distinction: a throw or a missing answer must stay
# retryable, a terminal answer must carry a reason, and a readiness edge must
# retire the denial without weakening bind()'s same-hook idempotence.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "annotation-actions" "not-ready is retryable; a readiness edge retires a terminal denial"

require_qs
trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/annotation-actions.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_section "the probe ran against the real singleton"
qp_assert "the probe ran without throwing" "probe.error" ""

t_section "a throw or a silent answer is not ready, not terminal"
qp_assert "a thrown hook carries a retryable reason" "throw.reason" "threw"
qp_assert "the first demand calls a throwing hook once" "throw.first.calls" "1"
qp_assert "a later demand retries it instead of latching" "throw.second.calls" "2"
qp_assert "a missing answer carries its own reason" "silent.reason" "no_answer"
qp_assert "a missing answer is retried too" "silent.second.calls" "2"
qp_assert "an explicit pending keeps its reason" "pending.reason" "pending"
qp_assert "pending is retried" "pending.calls" "2"

t_section "a terminal answer latches with a reason"
qp_assert "the terminal refusal carries a reason" "terminal.reason" "failed"
qp_assert "the latched refusal carries the same reason" "terminal.latched.reason" "failed"
qp_assert "a latched hook is called only once" "terminal.calls" "1"

t_section "bind idempotence survives the denial"
qp_assert "re-binding the same hook does not retry" "bind.same.calls" "1"

t_section "a readiness edge retires the denial"
qp_assert "the next demand calls the hook again" "edge.calls" "2"
qp_assert "a request after the edge opens" "edge.ok" "true"
qp_assert "and carries the opened code" "edge.code" "opened"

t_section "a different hook still resets the verdict"
qp_assert "a new hook is called on demand" "bind.different.calls" "1"
qp_assert "its not-ready answer is retryable" "bind.different.reason" "pending"

t_summary
