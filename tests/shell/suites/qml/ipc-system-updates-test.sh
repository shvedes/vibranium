#!/bin/bash
# Suite: systemUpdates through the real IpcRouter, headless. Stub owner rows
# exercise the read-only dumps, the JSON-array update token and error class;
# no fetch, process or package update is started.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "ipc-system-updates" "renamed target, typed dumps and invalid-argument classification"
require_qs
require_tools grep

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/ipc-system-updates.qml" 30; then
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

t_section "registration and read-only dumps"
t_eq "the owner registered" "true" "$(qp_get register)"
t_eq "refresh is still an action" "ok" "$(qp_get refresh)"
DUMP_ALL='[{"name":"coreutils","current":"9.1","candidate":"9.4-1","repository":"core","size":"4.0 MiB","source":"official"},{"name":"artcraft-launcher-bin","current":"1.0","candidate":"2.0","repository":"aur","size":"1.2 MiB","source":"aur"}]'
DUMP_AUR='[{"name":"artcraft-launcher-bin","current":"1.0","candidate":"2.0","repository":"aur","size":"1.2 MiB","source":"aur"}]'
t_eq "bare dump returns the merged rows" "$DUMP_ALL" "$(qp_get dump.all)"
t_eq "dump all returns the merged rows" "$DUMP_ALL" "$(qp_get dump.explicitAll)"
t_eq "dump aur returns only AUR rows" "$DUMP_AUR" "$(qp_get dump.aur)"
t_contains "the result carries a typed table format" '"kind":"table"' "$(qp_get dump.format)"
t_eq "the table columns are ordered" \
  '{"kind":"table","columns":[{"key":"name","heading":"Name"}|{"key":"current","heading":"Current"}|{"key":"candidate","heading":"Candidate"}|{"key":"repository","heading":"Repository"}|{"key":"size","heading":"Size"}|{"key":"source","heading":"Source"}]}' \
  "$(printf '%s' "$(qp_get dump.format)" | sed 's/},{/}|{/g')"

t_section "error classification"
t_eq "a non-JSON packages token is invalid-argument" "invalid-argument" "$(qp_get badJsonToken)"
t_eq "a wrong verb is unknown-command" "unknown-command" "$(qp_get wrongVerb)"
t_eq "a wrong dump source prints the dump branch help" "ok" "$(qp_get wrongDump)"
t_eq "the dump help is a help-kind result" "help" "$(qp_get wrongDump.format)"
t_eq "the dump help names the branch" "vb-shell systemUpdates dump" "$(qp_get wrongDump.usage)"

t_section "the documented update form"
t_eq "the update action succeeds" "ok" "$(qp_get update.reply)"
t_eq "the JSON array reaches the owner as a typed value" \
  '{"mode":"aur","packages":["artcraft-launcher-bin"],"raw":"[\"artcraft-launcher-bin\"]"}' \
  "$(qp_get update.jsonArray)"
t_eq "the legacy empty package list reaches the owner" \
  '{"mode":"repo","packages":"","raw":""}' "$(qp_get update.emptyList)"
t_contains "help names the exact JSON shape" "JSON array of package names" "$(qp_get help.argSummary)"
t_eq "help shows the quoted array example" "true" "$(qp_get help.example)"
t_eq "target help shows one dump placeholder" "true" "$(qp_get help.genericDump)"
t_eq "the dump branch lists all three forms" "true" "$(qp_get help.dumps)"

t_eq "unregisters by identity" "true" "$(qp_get unregister)"
t_eq "every observation was printed" "true" "$(qp_get probe.complete)"

t_summary
