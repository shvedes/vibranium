#!/bin/bash
# Suite: batch C gateway grammar in a live offscreen Quickshell.
#
# The probe registers stub owners for the bar, clipboard and emoji picker and
# drives the real IpcRouter with v1 envelopes. No feature singleton is
# constructed, no desktop shell starts and no clipboard is written.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "ipc-c-routing" "bar/clipboard/emoji grammar, fixed keywords and ownership in IpcRouter"
require_qs
require_tools grep

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/ipc-c-routing.qml" 30; then
  t_no "the probe reached ##DONE##" "probe did not finish. $(qp_out)"
  t_summary
  exit $?
fi
if qp_probe_ran "probe.error"; then
  t_no "the probe ran without throwing" "$(qp_get probe.error)"
  t_summary
  exit $?
fi
t_ok "the probe ran without throwing"

t_section "registration"
t_eq "bar registers" "true" "$(qp_get register.bar)"
t_eq "clipboard registers" "true" "$(qp_get register.clipboard)"
t_eq "emojiPicker registers" "true" "$(qp_get register.emojiPicker)"

t_section "bar grammar"
t_eq "a root verb reaches its owner" '1' "$(qp_get bar.enable.calls)"
t_eq "a root verb is silent" 'null' "$(qp_get bar.enable)"
t_eq "option set passes a typed JSON value" \
  '{"MODULE":"weather","KEY":"ShowTemp","JSON":true}' "$(qp_get bar.opt.set.args)"
t_eq "option set is silent" 'null' "$(qp_get bar.opt.set)"
t_eq "fixed opt list wins over the KEY placeholder" 'ok' "$(qp_get bar.opt.list.code)"
t_eq "fixed opt list reaches its owner" '"fixed"' "$(qp_get bar.opt.list)"
t_eq "an explicit screen is passed as a named argument" \
  '{"MODULE":"clock","OUTPUT":"HDMI-A-1"}' "$(qp_get bar.island.screen)"
t_eq "a named trigger validates its enum" \
  '{"MODULE":"battery","NAME":"flashCharge"}' "$(qp_get bar.trigger)"
t_eq "an unknown trigger names its label" '"invalid-argument"' "$(qp_get bar.trigger.bad)"
t_eq "injected status uses the owner projection" '{"outputs":["HDMI-A-1"]}' "$(qp_get bar.status)"
t_eq "injected ping is pong" "pong" "$(qp_get bar.ping)"
t_contains "module branch help is described" "options" "$(qp_get bar.help.branch)"

t_section "clipboard grammar"
t_eq "copy entry passes the bucket and index" \
  '{"BUCKET":"regular","INDEX":"0"}' "$(qp_get clip.copy.args)"
t_eq "copy entry is silent" 'null' "$(qp_get clip.copy)"
t_eq "an unknown bucket names its label" '"invalid-argument"' "$(qp_get clip.copy.bucket)"
t_eq "list rows are projected by the owner" '["projected"]' "$(qp_get clip.list)"
t_eq "status carries copyBusy" '{"copyBusy":false}' "$(qp_get clip.status)"
t_eq "client-owned copy cannot execute in the router" "unsupported" "$(qp_get clip.clientRoute)"

t_section "emoji grammar"
t_eq "copy accepts a Unicode ref" '{"ID":"😀"}' "$(qp_get emoji.copy.args)"
t_eq "copy is silent" 'null' "$(qp_get emoji.copy)"
t_eq "status reports readiness" \
  '{"open":false,"catalogReady":true}' "$(qp_get emoji.status)"
t_eq "help lists commands" "true" "$(qp_get emoji.help)"

t_section "lifecycle"
t_eq "bar unregisters by identity" "true" "$(qp_get unregister.bar)"
t_eq "clipboard unregisters by identity" "true" "$(qp_get unregister.clip)"
t_eq "emojiPicker unregisters by identity" "true" "$(qp_get unregister.emoji)"
t_eq "an unregistered owner is unavailable" "unavailable" "$(qp_get bar.afterUnregister)"
t_eq "every observation was printed" "true" "$(qp_get probe.complete)"

t_summary
