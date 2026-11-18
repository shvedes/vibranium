#!/bin/bash
# Suite: list-follow-curve - keyboard follow keeps the centre on a held key.
#
# Keyboard follow uses a fast-start curve so a held arrow or tab, which
# re-arms the tween on every repeat, keeps the cursor centred. Reveal seats
# cross a large distance and keep the gentle curve. Every List.qml consumer -
# menu, launcher and Pass - shares the policy.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "list-follow-curve" "keyboard follow and reveal pick their own easing"

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/list-follow-curve.qml" 20; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
else
  t_ok "the probe reached ##DONE##"
fi

t_eq "the probe ran without throwing" "none" "$(qp_get probe.error)"
t_eq "the probe completed every phase" "true" "$(qp_get completed)"

t_section "the curve follows the seat, not the list"

out="$(qp_get curve.outCubic)"
inout="$(qp_get curve.inOutCubic)"

t_eq "a follow seat uses the fast-start curve" "$out" "$(qp_get curve.follow)"
t_eq "a reveal seat uses the gentle curve" "$inout" "$(qp_get curve.reveal)"
t_ne "the two curves really differ" "$out" "$inout"

t_summary
