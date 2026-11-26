#!/bin/bash
# Suite: a known target or branch prints its real help page immediately;
# unknown words and bad typed tokens keep their RC-2 diagnostics. Headless.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "ipc-usage-hint" "instant help pages for known paths, errors for real mistakes"
require_qs
require_tools grep

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/ipc-usage-hint.qml" 30; then
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

assert_help_page() {
  local label="$1" usage="$2" examples="${3:-authored}"
  t_eq "$label succeeds" "true" "$(qp_get "$label.ok")"
  t_eq "$label has no error code" "ok" "$(qp_get "$label.code")"
  t_eq "$label has no diagnostic" "" "$(qp_get "$label.message")"
  t_eq "$label is a help-kind result" "help" "$(qp_get "$label.format")"
  t_eq "$label names the actual page" "$usage" "$(qp_get "$label.usage")"
  t_eq "$label has commands" "true" \
    "$(test "$(qp_get "$label.commands")" -gt 0 && echo true)"
  if [ "$examples" = "none" ]; then
    t_eq "$label is a target root and prints no examples" "0" "$(qp_get "$label.examples")"
  else
    t_eq "$label has an example" "true" \
      "$(test "$(qp_get "$label.examples")" -gt 0 && echo true)"
  fi
}

t_eq "the app describer registered" "true" "$(qp_get register.app)"
t_eq "the launcher describer registered" "true" "$(qp_get register.launcher)"

t_section "bare targets print their help pages"
assert_help_page "bare.app" "vb-shell app" none
assert_help_page "bare.bar" "vb-shell bar" none
assert_help_page "bare.colorPicker" "vb-shell colorPicker" none

t_section "known branches print their help pages"
assert_help_page "app.call" "vb-shell app call audioMixer"
assert_help_page "bar.module" "vb-shell bar module volume"
assert_help_page "launcher.plugin" "vb-shell appLauncher plugin command calc"
assert_help_page "menu.item" "vb-shell menu item r1.1.1.2"
assert_help_page "updates.dump" "vb-shell systemUpdates dump"

t_eq "no bare no-command diagnostic" "0" "$(qp_out | grep -c 'no command')"

t_section "genuinely unknown input is unchanged"
t_eq "an unknown verb stays unknown-command" "unknown-command" "$(qp_get genuine.unknown.code)"
t_eq "an unknown verb has the fixed message" "no such command" "$(qp_get genuine.unknown.message)"

t_section "enum and ref failures name the argument, never the token"
t_eq "a bad app id is invalid-argument" "invalid-argument" "$(qp_get bad.id.code)"
t_eq "a bad app id names the label" "unknown ID" "$(qp_get bad.id.message)"
t_eq "a bad tab is invalid-argument" "invalid-argument" "$(qp_get bad.tab.code)"
t_eq "a bad tab names the label" "unknown TAB" "$(qp_get bad.tab.message)"
t_not_contains "the bad token is never echoed" "audioMicer" "$(qp_out)"
t_not_contains "the bad tab token is never echoed" "nope" "$(qp_out)"

t_section "a bad typed token is still invalid-argument"
t_eq "non-JSON token is invalid-argument" "invalid-argument" "$(qp_get typed.bad.code)"
t_eq "the diagnostic stays fixed" "argument has the wrong type" "$(qp_get typed.bad.message)"

t_eq "both describers unregistered" "true|true" \
  "$(printf '%s|%s' "$(qp_get unregister.app)" "$(qp_get unregister.launcher)")"
t_eq "every observation was printed" "true" "$(qp_get probe.complete)"

t_summary
