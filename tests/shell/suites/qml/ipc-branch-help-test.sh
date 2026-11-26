#!/bin/bash
# Suite: every nested branch is a columnized help page with examples, and no
# parent page enumerates a deep or dynamic instance. Headless, no owner needed.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "ipc-branch-help" "flat parent pages, one help page per branch"
require_qs
require_tools grep

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/ipc-branch-help.qml" 30; then
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

t_eq "no parent page enumerates a hidden deep row" '[]' "$(qp_get flat.violations)"
t_eq "every branch page was produced" '0' "$(python3 - "$(qp_get branches)" <<'PY'
import json, sys
b = json.loads(sys.argv[1])
print(sum(1 for v in b.values() if not v))
PY
)"
t_eq "every branch has commands and an example" '0' "$(python3 - "$(qp_get branches)" <<'PY'
import json, sys
b = json.loads(sys.argv[1])
print(sum(1 for v in b.values() if not (v and v['commands'] and v['examples'] >= 1)))
PY
)"
t_eq "every branch command has a usage and a summary" '0' "$(python3 - "$(qp_get branches)" <<'PY'
import json, sys
b = json.loads(sys.argv[1])
print(sum(1 for v in b.values() if not v['summary'] or any(not c for c in v['commands'])))
PY
)"

t_section "specific branch pages"
t_eq "systemUpdates dump is one bucket branch" '["dump", "all", "aur"]' \
  "$(python3 - "$(qp_get branches)" <<'PY'
import json, sys
print(json.dumps(json.loads(sys.argv[1])['systemUpdates dump']['commands']))
PY
)"
t_eq "printers job lists the three verbs" '["hold <printer> <jobid>", "release <printer> <jobid>", "cancel <printer> <jobid>"]' \
  "$(python3 - "$(qp_get branches)" <<'PY'
import json, sys
print(json.dumps(json.loads(sys.argv[1])['printers job']['commands']))
PY
)"
t_eq "root bar help has no placeholders" "0" \
  "$(python3 - "$(qp_get bar.rootCommands)" <<'PY'
import json, sys
print(sum(1 for s in json.loads(sys.argv[1]) if '<' in s or '[' in s))
PY
)"
for branch in "bar position" "bar layout" "bar module"; do
  t_eq "$branch scoped help keeps real children" "true" \
    "$(python3 - "$branch" "$(qp_get branches)" <<'PY'
import json, sys
key = sys.argv[1]
v = json.loads(sys.argv[2])[key]
print('true' if v and v['commands'] and v['examples'] >= 1 else 'false')
PY
)"
done
for branch in "audio volume" "audio microphone" "audio sink" "audio source" "audio stream" "appLauncher history"; do
  t_eq "$branch has real children and an example" "true" \
    "$(python3 - "$branch" "$(qp_get branches)" <<'PY'
import json, sys
key = sys.argv[1]
v = json.loads(sys.argv[2])[key]
print('true' if v and v['commands'] and v['examples'] >= 1 else 'false')
PY
)"
done
t_eq "audio stream shows its three actions" '0' "$(python3 - "$(qp_get branches)" <<'PY'
import json, sys
c = json.loads(sys.argv[1])['audio stream n1.2']['commands']
print(0 if all(any(a in x for x in c) for a in ('set','mute','route')) else 1)
PY
)"
t_eq "bar module shows one placeholder per sub-branch" '0' "$(python3 - "$(qp_get branches)" <<'PY'
import json, sys
c = json.loads(sys.argv[1])['bar module volume']['commands']
print(0 if all(any(a in x for x in c) for a in ('island','opt','trigger','status')) else 1)
PY
)"
t_eq "bar module island lists its four verbs" '4' "$(python3 - "$(qp_get branches)" <<'PY'
import json, sys
print(len(json.loads(sys.argv[1])['bar module volume island']['commands']))
PY
)"
t_eq "notifications dnd lists its four verbs" '["enable", "disable", "toggle", "get"]' \
  "$(python3 - "$(qp_get branches)" <<'PY'
import json, sys
print(json.dumps(json.loads(sys.argv[1])['notifications dnd']['commands']))
PY
)"
t_eq "notifications dnd help has no notes" '0' \
  "$(python3 - "$(qp_get branches)" <<'PY'
import json, sys
print(json.loads(sys.argv[1])['notifications dnd']['noted'])
PY
)"
t_eq "notifications dismiss lists its three scopes" '["visible", "all", "<id>"]' \
  "$(python3 - "$(qp_get branches)" <<'PY'
import json, sys
print(json.dumps(json.loads(sys.argv[1])['notifications dismiss']['commands']))
PY
)"
t_eq "menu confirm lists its three verbs" '3' "$(python3 - "$(qp_get branches)" <<'PY'
import json, sys
print(len(json.loads(sys.argv[1])['menu item r1.1.1.2 confirm']['commands']))
PY
)"
t_eq "menu flow lists its six verbs" '6' "$(python3 - "$(qp_get branches)" <<'PY'
import json, sys
print(len(json.loads(sys.argv[1])['menu item r1.1.1.2 flow']['commands']))
PY
)"
t_eq "launcher plugin keeps every lifecycle verb" '8' "$(python3 - "$(qp_get branches)" <<'PY'
import json, sys
print(len(json.loads(sys.argv[1])['appLauncher plugin']['commands']))
PY
)"

t_section "index stays flat"
t_eq "the bar index has one module placeholder" '1' "$(python3 - "$(qp_get index.bar)" <<'PY'
import json, sys
print(sum(1 for s in json.loads(sys.argv[1]) if s == 'module'))
PY
)"
t_eq "the menu index has one item placeholder" '1' "$(python3 - "$(qp_get index.menu)" <<'PY'
import json, sys
print(sum(1 for s in json.loads(sys.argv[1]) if s == 'item'))
PY
)"
t_eq "the bar index has no island instance verbs" '0' "$(python3 - "$(qp_get index.bar)" <<'PY'
import json, sys
print(sum(1 for s in json.loads(sys.argv[1]) if s.startswith('island ')))
PY
)"

t_eq "every observation was printed" "true" "$(qp_get probe.complete)"

t_summary
