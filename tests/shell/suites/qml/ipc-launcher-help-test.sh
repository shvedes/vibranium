#!/bin/bash
# Suite: per-plugin help through the real IpcRouter, headless.
#
# A stub owner registers the appLauncher rows and the static LauncherLib
# describe table. No plugin code, controller, controller demand or window is
# involved: the whole page is presentation from the catalog and the table.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "ipc-launcher-help" "real-router plugin help pages, argument docs and cross-plugin isolation"
require_qs
require_tools grep

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/ipc-launcher-help.qml" 30; then
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

t_section "registration and parent pages"
t_eq "the owner registered" "true" "$(qp_get register)"
t_eq "typed ping returns pong" "pong" "$(qp_get ping.data)"
t_eq "typed ping keeps its text format" "text" "$(qp_get ping.format)"
t_eq "typed status stays a record" '{"ready":true}' "$(qp_get status.data)"
t_eq "root help hides individual plugin verbs" "true" "$(qp_get root.noChildPlugins)"
t_eq "root help shows the generic plugin entry" "true" "$(qp_get root.genericPlugin)"
t_eq "root help has no rescan verb" "true" "$(qp_get root.noRescan)"
t_eq "root help has no discover verb" "true" "$(qp_get root.noDiscover)"
t_eq "the plugin command branch lists its features" '8' \
  "$(python3 - "$(qp_get branch.commands)" <<'PY'
import json, sys
print(len(json.loads(sys.argv[1])))
PY
)"
t_eq "the index shows the generic plugin entry" "true" "$(qp_get index.genericPlugin)"
t_eq "the index hides individual plugin verbs" "true" "$(qp_get index.noChildPlugins)"

t_section "a concrete plugin page"
t_eq "usage names the plugin" "vb-shell appLauncher plugin command color" "$(qp_get color.usage)"
t_contains "the page has a summary" "Parse one color expression" "$(qp_get color.summary)"
t_eq "only color's verb is described" '["appLauncher.plugin.command.color.parse"]' "$(qp_get color.commands)"
t_eq "no other plugin's verb leaks in" "true" "$(qp_get color.isolated)"
t_contains "the argument is documented" "COLOR" "$(qp_get color.arg)"
t_contains "the argument has a summary" "Color expression" "$(qp_get color.arg)"
t_contains "the command has a concrete example" \
  "vb-shell appLauncher plugin command color parse '#ff8800'" "$(qp_get color.examples)"
t_contains "notes point at plugins list" "vb-shell appLauncher plugin list" "$(qp_get color.notes)"
t_contains "examples point at plugins list" \
  "vb-shell appLauncher plugin list" "$(qp_get color.examplesPage)"
t_eq "calc's page is isolated" '["appLauncher.plugin.command.calc.eval"]' "$(qp_get calc.commands)"
t_contains "calc documents its expression argument" "Arithmetic expression" "$(qp_get calc.arg)"
t_eq "time has two verbs" "2" "$(qp_get time.commands)"
t_contains "time lookup documents ZONE_OR_CITY" "ZONE_OR_CITY" "$(qp_get time.lookupArg)"
t_eq "binary has no feature verbs" "0" "$(qp_get binary.commands)"
t_contains "binary points at plugins list" \
  "vb-shell appLauncher plugin list" "$(qp_get binary.notes)"

t_section "unknown ids do not fabricate a page"
t_eq "an unknown id has no commands" "0" "$(qp_get unknown.commands)"
t_eq "the generic branch stays" "true" "$(qp_get unknown.noFabricatedPage)"

t_section "exact documented spellings dispatch"
t_eq "calc eval" '{"EXPR":"5+5"}' "$(qp_get dispatch.calc)"
t_eq "websearch url" '{"QUERY":"shell ipc"}' "$(qp_get dispatch.websearch)"
t_eq "unit convert" '{"QUERY":"1 light years"}' "$(qp_get dispatch.unit)"
t_eq "time lookup" '{"ZONE_OR_CITY":"Berlin"}' "$(qp_get dispatch.time)"
t_eq "a wrong plugin prints the plugin help page" "ok" "$(qp_get dispatch.wrongPlugin)"
t_eq "the plugin help page is a help-kind result" "help" "$(qp_get dispatch.wrongPlugin.format)"
t_eq "a wrong verb prints help too" "ok" "$(qp_get dispatch.wrongVerb)"
t_eq "the generic entry is not callable but is discoverable" "ok" "$(qp_get dispatch.genericNotCallable)"

t_eq "unregisters by identity" "true" "$(qp_get unregister)"
t_eq "every observation was printed" "true" "$(qp_get probe.complete)"

t_summary
