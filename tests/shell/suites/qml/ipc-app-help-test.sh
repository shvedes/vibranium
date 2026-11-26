#!/bin/bash
# Suite: the app help exemplar through the real router, headless.
#
# `app call list <APP>` is a help-kind data reply and `app call <APP> help`
# is a describe reply. Both use AppHost's static allowlist; neither demands a
# controller, loads a view or opens a window.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "ipc-app-help" "per-app help pages, concrete tab ids and dispatch parity"
require_qs
require_tools grep

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/ipc-app-help.qml" 30; then
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

t_section "parent pages stay flat"
t_eq "the owner registered" "true" "$(qp_get register)"
t_eq "root shows one generic call branch" "true" "$(qp_get root.genericCall)"
t_eq "root does not enumerate app verbs" "true" "$(qp_get root.noDeep)"
t_eq "the call branch shows only its own list verb" '["list <ID>"]' "$(qp_get call.commands)"
t_eq "the index shows the generic call branch" "true" "$(qp_get index.genericCall)"
t_eq "the index hides every app verb" "true" "$(qp_get index.noDeep)"

t_section "audio mixer help teaches the real tabs"
t_eq "usage names the app" "vb-shell app call audioMixer" "$(qp_get mixer.usage)"
t_eq "summary is the authoritative snapshot line" \
  "Audio mixer: native Pavucontrol replacement, with Pipewire node graph included" "$(qp_get mixer.summary)"
t_eq "only mixer verbs are listed" '["app.call.audioMixer.openTab","app.call.audioMixer.selectTab","app.call.audioMixer.status"]' \
  "$(qp_get mixer.commands)"
t_eq "openTab has a placeholder" "true" "$(qp_get mixer.usages | grep -q 'openTab <TAB>' && echo true)"
t_eq "selectTab has a placeholder" "true" "$(qp_get mixer.usages | grep -q 'selectTab <TAB>' && echo true)"
t_eq "the tab ids are the real five" '["apps","devices","recording","configuration","graph"]' "$(qp_get mixer.tabIds)"
t_contains "the argument summary names every tab" "configuration" "$(qp_get mixer.tabSummary)"
t_eq "an openTab example is present" "true" "$(qp_get mixer.openTabExample)"
t_eq "a selectTab example is present" "true" "$(qp_get mixer.selectTabExample)"
t_eq "the mixer note is the exact snapshot line" \
  '["Valid tab ids are: apps, devices, recording, configuration, graph"]' "$(qp_get mixer.notes)"

t_section "image viewer help teaches openPath"
t_eq "viewer usage names the app" "vb-shell app call imageViewer" "$(qp_get viewer.usage)"
t_eq "only viewer verbs are listed" '["app.call.imageViewer.openPath","app.call.imageViewer.status"]' "$(qp_get viewer.commands)"
t_eq "an openPath example is present" "true" "$(qp_get viewer.openPathExample)"

t_section "unknown ids do not fabricate a page"
t_eq "an unknown app has no commands" "true" "$(qp_get unknown.noFabricatedPage)"

t_section "one descriptor, two spellings"
t_eq "call list succeeds" "true" "$(qp_get list.ok)"
t_eq "call list is a help-kind result" "help" "$(qp_get list.format)"
t_eq "call list publishes the same verbs" \
  '["app.call.audioMixer.openTab","app.call.audioMixer.selectTab","app.call.audioMixer.status"]' \
  "$(qp_get list.dataCommands)"
t_eq "call list and describe are the same page" "true" "$(qp_get list.sameAsHelp)"
t_eq "an unknown app is an invalid ID" "invalid-argument" "$(qp_get list.unknown)"

t_section "documented spellings still dispatch"
t_eq "openTab dispatches" '{"TAB":"graph"}' "$(qp_get dispatch.openTab.args)"
t_eq "openTab is silent" 'null' "$(qp_get dispatch.openTab)"
t_eq "selectTab dispatches" '{"TAB":"devices"}' "$(qp_get dispatch.selectTab.args)"
t_eq "selectTab is silent" 'null' "$(qp_get dispatch.selectTab)"
t_eq "openPath dispatches" '{"PATH":"/tmp/a.png"}' "$(qp_get dispatch.openPath.args)"
t_eq "openPath is silent" 'null' "$(qp_get dispatch.openPath)"

t_eq "unregisters by identity" "true" "$(qp_get unregister)"
t_eq "every observation was printed" "true" "$(qp_get probe.complete)"

t_summary
