#!/bin/bash
# Gate 1: inertness of all five generated handler types.
#
#   bash tests/shell/bench/unit-pilot/inertness-test.sh
#
# Builds a throwaway mirror whose every singleton referenced by the five
# generated types is an instrumented stand-in, copies the SHIPPED generated
# types and the authored hook files into it byte-for-byte, and drives one QML
# probe that holds each row, resolves representative ids from every provider,
# and reads the shared completion counter. Nothing under shell/ is modified.
set -uo pipefail

PILOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PILOT_DIR/../../lib/lib.sh"
source "$PILOT_DIR/../../lib/harness.sh"
source "$PILOT_DIR/../../lib/qmlprobe.sh"
source "$PILOT_DIR/mirror-lib.sh"

REPORT_DIR="${VB_PILOT_REPORT_DIR:-/tmp/opencode/vibranium-pilot-reports}"
mkdir -p "$REPORT_DIR"
OUT="$REPORT_DIR/gate1-inertness.kv.txt"

t_init "unit-pilot/inertness" "all five generated rows construct no singleton until first resolve"
pilot_require_qs

mirror="$(mktemp -d "${TMPDIR:-/tmp}/vb-pilot-inert.XXXXXX")"
trap 'qp_teardown; rm -rf "$mirror"' EXIT
pilot_build_inert_mirror "$mirror" "$SHELL_DIR"

printf 'byte-exact generated outputs under test (sha256):\n'
for f in "$mirror"/boot/generated/*/*.qml; do
  printf '  %s = %s\n' "$(basename "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
done
# No adaptation is applied: the repaired generator emits a lazy
# _ensure<Hook>() that calls Qt.createComponent(...).createObject(root,
# { boot: root.boot }) on first use, with no static hook imports, so the
# shipped files load verbatim in this mirror. The hook properties are null
# until that first use; the probe reads them null-safely.

SHELL_DIR="$mirror"
qp_setup >/dev/null
if ! qp_run "$PILOT_DIR/inertness-probe.qml" 45; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

qp_out >"$OUT"
printf '%s\n' "--- exact probe key/value output ($OUT) ---"
grep '##KV##' "$OUT" | sed 's/^.*##KV## //'
printf '%s\n' "--- end probe output ---"

kv() { grep "##KV## $1=" "$OUT" | sed 's/.*=//'; }

t_section "construction: no singleton completion, no lazy target, no boot bridge"
t_false "the probe printed no error" "$(qp_probe_ran probe.error && printf true || printf false)"
for key in common.Log common.Paths common.Watch common.Settings \
           services.PowerProfile services.Screenshots services.Session \
           services.Audio services.SystemUpdates \
           features.launcher.AppLauncher features.pass.Pass \
           features.clipboard.Clipboard features.apps.audioMixer.AudioMixer \
           features.notifications.Notifications; do
  t_eq "initial $key = 0" "0" "$(kv "initial.$key")"
done
t_eq "Pass Connections target is null at construction" "true" "$(kv hook.pass.target.at.construct)"
t_eq "Screenshots Connections target is null at construction" "true" "$(kv hook.screenshots.target.at.construct)"
t_eq "bar bridge not called at construction" "0" "$(kv boot.mount.calls.initial)"
t_eq "annotations bridge not called at construction" "0" "$(kv boot.activate.calls.initial)"

t_section "exactly one completion after the owning id resolves; repeats stay at one"
t_eq "floor log resolves once" "1" "$(kv resolve.log.count)"
t_eq "floor log repeat adds none" "1" "$(kv repeat.log.count)"
t_eq "floor paths (hook) resolves once" "1" "$(kv resolve.paths.count)"
t_eq "floor paths ready predicate holds" "true" "$(kv ready.paths)"
t_eq "floor paths repeat adds none" "1" "$(kv repeat.paths.count)"
t_eq "services powerProfile resolves once" "1" "$(kv resolve.powerProfile.count)"
t_eq "services powerProfile repeat adds none" "1" "$(kv repeat.powerProfile.count)"
t_eq "services screenshots (hook) resolves once" "1" "$(kv resolve.screenshots.count)"
t_eq "screenshots Connections attached on resolve" "true" "$(kv hook.screenshots.target.after)"
t_eq "screenshots ready predicate holds" "true" "$(kv ready.screenshots)"
t_eq "services screenshots repeat adds none" "1" "$(kv repeat.screenshots.count)"
t_eq "features appLauncher facade resolves once" "1" "$(kv resolve.appLauncher.count)"
t_eq "appLauncher ready predicate holds" "true" "$(kv ready.appLauncher)"
t_eq "appLauncher teardown reached the stand-in" "1" "$(kv teardown.appLauncher.calls)"
t_eq "features appLauncher repeat adds none" "1" "$(kv repeat.appLauncher.count)"
t_eq "features pass (hook) resolves once" "1" "$(kv resolve.pass.count)"
t_eq "pass Connections attached on resolve" "true" "$(kv hook.pass.target.after)"
t_eq "pass ready predicate holds" "true" "$(kv ready.pass)"
t_eq "features pass repeat adds none" "1" "$(kv repeat.pass.count)"

t_section "boot-bridge hooks (bar, annotations) touch no singleton"
t_eq "bar resolve calls the runtime mount once" "1" "$(kv resolve.bar.mounts)"
t_eq "bar ready sees the mounted runtime" "true" "$(kv ready.bar)"
t_eq "bar teardown calls unmount once" "1" "$(kv teardown.bar.unmounts)"
t_eq "bar repeat resolve forwards again (unguarded boot stub, no singleton)" "2" "$(kv repeat.bar.mounts)"
t_eq "annotations resolve activates once" "1" "$(kv resolve.annotations.activations)"
t_eq "annotations ready predicate holds" "true" "$(kv ready.annotations)"
t_eq "annotations teardown reached the bridge once" "1" "$(kv teardown.annotations.calls)"
t_eq "annotations repeat resolve forwards again (unguarded boot stub, no singleton)" "2" "$(kv repeat.annotations.activations)"
t_eq "hook refresh calls reached the boot bridge" "0" "$(kv boot.refresh.calls)"

t_section "no cross-provider construction leaked"
for key in common.Watch common.Settings services.Session services.Audio \
           services.SystemUpdates features.clipboard.Clipboard \
           features.apps.audioMixer.AudioMixer features.notifications.Notifications; do
  t_eq "final $key stayed at 0" "0" "$(kv "final.$key")"
done
for key in common.Log common.Paths services.PowerProfile services.Screenshots \
           features.launcher.AppLauncher features.pass.Pass; do
  t_eq "final $key is exactly 1" "1" "$(kv "final.$key")"
done

t_summary
