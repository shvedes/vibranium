#!/bin/bash
# Suite: polkit conversation actions and reset tokens, headless.
#
# The real Polkit.qml registers a second authentication agent if imported, and
# PolkitView is a PanelWindow surface, so neither can be constructed offscreen.
# The probe reads both files and evaluates their own function bodies with
# stubbed backend edges, then drives the contract with fake flows that record
# submit/cancel calls. Nothing here attempts a real PAM authentication.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "polkit-flow-contract" "actions use the wired flow; the flash has its own token"

require_qs
trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/polkit-flow-contract.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_section "the slice is the real source"
qp_assert "the probe ran without throwing" "probe.error" ""
qp_assert "the QML source was read" "slice.sourceStatus" "true"
qp_assert "the view source was read" "slice.viewSourceStatus" "true"
qp_assert "every function under test was found" "slice.missingFns" ""
qp_assert "the known alias rewrite is the only one" "slice.rewrites" "svc-alias"

t_section "LCK-2: an action follows the observed flow and obeys the verdict"
qp_assert "submit reaches the wired flow" "submit.onWired" "1"
qp_assert "submit never reaches agent.flow" "submit.onForeign" "0"
qp_assert "no submit follows a refused _apply" "submit.afterRefusedApply" "0"
qp_assert "refused submit does not advance the record" "submit.convSubmits" "1"
qp_assert "no backend submit without a wired flow" "submit.withoutWiredTotal" "0"
qp_assert "no foreign submit without a wired flow" "submit.withoutWiredForeign" "0"
qp_assert "cancel reaches the wired flow" "cancel.onWired" "1"
qp_assert "cancel never reaches agent.flow" "cancel.onForeign" "0"
qp_assert "a retired flow and epoch are refused" "guard.stale" "false"

t_section "LCK-3: beginClose goes through the one funnel"
qp_assert "a refused beginClose leaves conv intact" "beginClose.refusedConvNull" "false"
qp_assert "a refused beginClose does not start closing" "beginClose.refusedClosing" "false"
qp_assert "a legal beginClose still closes" "beginClose.acceptedClosing" "true"

t_section "LCK-4: the failure flash has a conversation-scoped token"
qp_assert "a rejection does not bump the conversation token" "token.afterFailure" "1"
qp_assert "a new request does bump it" "token.afterNewRequest" "2"
qp_assert "the view has a conversation-token handler" "token.viewHandler" "true"
qp_assert "resetToken wipes the field" "token.viewResetWipes" "1"
qp_assert "resetToken does not clear the failure flash" "token.viewResetClears" "0"
qp_assert "the conversation token clears it exactly once" "token.viewConversationClears" "1"
qp_assert "resetToken still refocuses" "token.viewRefocuses" "1"
qp_assert "only one site clears the flash" "view.clearFailureCalls" "1"

t_section "LCK-7: shouldShow never owns the exit fade"
qp_assert "shouldShow ignores closing" "show.closingIgnored" "true"
qp_assert "shouldShow still gates on locked" "show.locked" "false"
qp_assert "shouldShow still gates on a screen" "show.noScreen" "false"
qp_assert "suppression still reports closing" "suppression.closing" "closing"
# XHR cannot read a .js import, so the doc claim is checked as source text.
t_false "no stale visible-binding claim remains" \
  grep -Fq 'visible: Polkit.visible && !Lockscreen.locked' \
  "$SHELL_DIR/features/polkit/PolkitTrace.js"

t_summary
