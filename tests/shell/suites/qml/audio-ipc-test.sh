#!/bin/bash
# Suite: rearranged audio and launcher verbs dispatch through the real router.
# No PipeWire, controller or window is involved.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "audio-ipc" "nested audio/launcher dispatch and retired verb absence"
require_qs
require_tools grep

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/ipc-audio-ipc.qml" 30; then
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

t_eq "audio registered" "true" "$(qp_get register.audio)"
t_eq "launcher registered" "true" "$(qp_get register.launcher)"

t_section "new spellings reach their owner closures"
t_eq "volume up" '{"N":10}' "$(qp_get volume.up.args)"
t_eq "volume up is silent" 'null' "$(qp_get volume.up.data)"
t_eq "volume down" '{"N":0}' "$(qp_get volume.down.args)"
t_eq "volume down is silent" 'null' "$(qp_get volume.down.data)"
t_eq "volume toggle" '{"toggle":true}' "$(qp_get volume.toggle.args)"
t_eq "volume toggle is silent" 'null' "$(qp_get volume.toggle.data)"
t_eq "volume set" '{"N":80}' "$(qp_get volume.set.args)"
t_eq "volume set is silent" 'null' "$(qp_get volume.set.data)"
t_eq "volume get is read-only" '{"percent":80,"muted":false}' "$(qp_get volume.get.data)"
t_eq "microphone up" '{"N":0}' "$(qp_get microphone.up.args)"
t_eq "microphone up is silent" 'null' "$(qp_get microphone.up.data)"
t_eq "microphone down" '{"N":0}' "$(qp_get microphone.down.args)"
t_eq "microphone down is silent" 'null' "$(qp_get microphone.down.data)"
t_eq "microphone toggle" '{"toggle":true}' "$(qp_get microphone.toggle.args)"
t_eq "microphone toggle is silent" 'null' "$(qp_get microphone.toggle.data)"
t_eq "microphone set" '{"N":60}' "$(qp_get microphone.set.args)"
t_eq "microphone set is silent" 'null' "$(qp_get microphone.set.data)"
t_eq "microphone get is read-only" '{"percent":60,"muted":true}' "$(qp_get microphone.get.data)"
t_eq "stream list is under stream" '{"list":"apps"}' "$(qp_get stream.list.data)"
t_eq "route-status is under stream" '{"REQUEST":"r1.1"}' "$(qp_get stream.routeStatus.data)"
t_eq "sink list" '{"list":"sink"}' "$(qp_get sink.list.data)"
t_eq "sink set" '{"ID":"n1.2"}' "$(qp_get sink.set.args)"
t_eq "sink set is silent" 'null' "$(qp_get sink.set.data)"
t_eq "source list" '{"list":"source"}' "$(qp_get source.list.data)"
t_eq "source set" '{"ID":"n1.3"}' "$(qp_get source.set.args)"
t_eq "source set is silent" 'null' "$(qp_get source.set.data)"
t_eq "history is-empty" '{"empty":true}' "$(qp_get history.empty.data)"
t_eq "history show" '{"show":true}' "$(qp_get history.show.data)"
t_eq "history clear" '{"clear":true}' "$(qp_get history.clear.args)"
t_eq "history clear is silent" 'null' "$(qp_get history.clear.data)"

t_section "retired spellings are gone"
for key in old.volumeUp old.micToggle old.sinks old.setDefault old.hasHistory old.apps old.routeStatus; do
  t_eq "$key is unknown or a discoverable hint" "true" \
    "$(case "$(qp_get "$key")" in unknown-command|usage) echo true;; *) echo false;; esac)"
done

t_eq "audio unregistered" "true" "$(qp_get unregister.audio)"
t_eq "launcher unregistered" "true" "$(qp_get unregister.launcher)"
t_eq "every observation was printed" "true" "$(qp_get probe.complete)"

t_summary
