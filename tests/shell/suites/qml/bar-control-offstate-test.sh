#!/bin/bash
# Suite: the resident bar control answers config/IPC with no visual bar loaded.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "bar-control-offstate" "BarControl answers settings, IPC and layout with the visual bar absent"

require_qs
trap qp_teardown EXIT

# Private settings so the probe cannot touch the user's configuration.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-bar-control.XXXXXX")"
mkdir -p "$WORK/config" "$WORK/state" "$WORK/cache" "$WORK/data" "$WORK/run"
export XDG_CONFIG_HOME="$WORK/config"
export XDG_STATE_HOME="$WORK/state"
export XDG_CACHE_HOME="$WORK/cache"
export XDG_DATA_HOME="$WORK/data"
export VIBRANIUM_RUNTIME="$WORK/run"
trap 'qp_teardown; rm -rf "$WORK"' EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/bar-control-offstate.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing" "" "$(qp_get probe.error)"
t_eq "the control singleton exists" "object" "$(qp_get control.exists)"
t_eq "the control registers on construction" "true" "$(qp_get control.initialized)"
t_eq "no runtime is attached" "true" "$(qp_get control.noRuntime)"
t_eq "the master switch reads false" "true" "$(qp_get control.disabled)"
t_eq "effectiveEnabled is false" "true" "$(qp_get control.effectiveOff)"
t_eq "bar status reports disabled" "false" "$(qp_get ipc.status.enabled)"
t_eq "bar status reports ineffective" "false" "$(qp_get ipc.status.effective)"
t_eq "outputs are reported as an array" "true" "$(qp_get ipc.status.outputsArray)"
t_eq "per-output module records exist" "true" "$(qp_get ipc.status.moduleRecord)"
t_eq "off-state records are unloaded" "true" "$(qp_get ipc.status.outputUnloaded)"
t_eq "the layout has four arrays" "true" "$(qp_get layout.hasZones)"
t_eq "a layout round trip is accepted" "ok" "$(qp_get layout.readWrite)"
t_eq "hide is accepted" "ok" "$(qp_get hide.set)"
t_eq "hide is reported" "true" "$(qp_get hide.state)"
t_eq "show is accepted" "ok" "$(qp_get show.clear)"
t_eq "show clears the override" "false" "$(qp_get show.state)"
t_eq "island ops are unavailable" "unavailable" "$(qp_get island.unavailable)"
t_eq "trigger is unavailable" "unavailable" "$(qp_get trigger.unavailable)"
t_eq "module status works" "ok" "$(qp_get module.status)"
t_eq "module options work" "ok" "$(qp_get opt.get)"
t_eq "bar ping works" "pong" "$(qp_get ping)"

t_summary
