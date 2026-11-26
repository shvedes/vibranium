#!/bin/bash
# Suite: boot-trace transport - the real registered boot.time route, the same
# frozen report through a native IpcHandler, and the v1 wire fit in QML.
#
# LIMITATION: the real Boot component cannot be constructed in an offscreen
# engine (LayerSurface has no PanelWindow backend). The router, catalog, codec
# and report are real; only the owner is a stand-in. The real handler bodies
# are pinned with static assertions below. This is recorded as UNVERIFIED for
# the real component rather than reported as a pass of it.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "boot-trace-transport" "real boot.time gateway and native handler with one frozen report"
require_qs
require_tools grep sed env python3

FROZEN="$TESTS_SHELL_DIR/fixtures/boot-trace/frozen-report.json"
export BOOT_TRACE_FROZEN_REPORT="$(cat "$FROZEN")"
trap qp_teardown EXIT

canonical() {
  python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read()), ensure_ascii=True, separators=(",", ":")))' <<<"$1"
}
CANON="$(canonical "$BOOT_TRACE_FROZEN_REPORT")"

t_section "the real router probe"
if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/boot-trace-transport.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi
if qp_probe_ran "probe.error"; then
  t_no "the probe ran without throwing" "$(qp_get probe.error)"
else
  t_ok "the probe ran without throwing"
fi

t_section "gateway route and frame"
t_eq "the catalog declares boottime" "boottime" "$(qp_get catalog.kind)"
t_eq "the stand-in owner registers through the real router" "true" "$(qp_get register.bootTime)"
t_eq "the gateway answer is ok" "true" "$(qp_get gateway.ok)"
t_eq "the gateway answer keeps the boottime format" "boottime" "$(qp_get gateway.format)"
t_eq "the gateway answer is the frozen report" "$CANON" "$(canonical "$(qp_get gateway.report)")"
t_eq "both expose the same bounded report" "$CANON" "$(canonical "$(qp_get gateway.report)")"

t_section "wire fit inside the engine"
t_eq "the frame fits the installed reply cap" "true" "$(qp_get wire.fits)"
t_true "the measured byte count is below the cap" test "$(qp_get wire.bytes)" -lt "$(qp_get wire.limit)"
t_eq "the decoded frame equals the frozen report" "true" "$(qp_get wire.decodedEquals)"
t_eq "the frame carries a boottime format" "boottime" "$(qp_get wire.format)"
t_eq "the non-ASCII value is escaped" "true" "$(qp_get wire.escapedNonAscii)"

# --- the native verb ---------------------------------------------------------
t_section "native time() handler"
NATIVE_CFG="$(mktemp -d "${TMPDIR:-/tmp}/vb-shell-boot-native.XXXXXX")"
NATIVE_RUNTIME="$(mktemp -d "${TMPDIR:-/tmp}/vb-shell-boot-native-rt.XXXXXX")"
NATIVE_OUT="$(mktemp "${TMPDIR:-/tmp}/vb-shell-boot-native-out.XXXXXX")"
cleanup_native() {
  if [[ -n ${NATIVE_PID:-} ]]; then
    kill -TERM "-$NATIVE_PID" 2>/dev/null
    wait "$NATIVE_PID" 2>/dev/null
  fi
  rm -rf "$NATIVE_CFG" "$NATIVE_RUNTIME" "$NATIVE_OUT"
}
trap 'qp_teardown; cleanup_native' EXIT
mkdir "$NATIVE_CFG/shell"
cp "$TESTS_SHELL_DIR/suites/qml/probes/boot-trace-native.qml" "$NATIVE_CFG/shell/shell.qml"
NATIVE_ENV=(env -u DISPLAY -u WAYLAND_DISPLAY -u QS_CONFIG_PATH -u QS_CONFIG_NAME -u QS_MANIFEST
  XDG_RUNTIME_DIR="$NATIVE_RUNTIME" QT_QPA_PLATFORM=offscreen VIBRANIUM="$NATIVE_CFG"
  BOOT_TRACE_FROZEN_REPORT="$BOOT_TRACE_FROZEN_REPORT")

setsid "${NATIVE_ENV[@]}" qs --no-color -p "$NATIVE_CFG/shell/shell.qml" >"$NATIVE_OUT" 2>&1 &
NATIVE_PID=$!
ready=false
for _ in $(seq 1 100); do
  grep -q '##NATIVE-READY##' "$NATIVE_OUT" 2>/dev/null && { ready=true; break; }
  kill -0 "$NATIVE_PID" 2>/dev/null || break
  sleep 0.05
done
if [[ $ready == false ]]; then
  t_no "the native handler became ready" "$(cat "$NATIVE_OUT")"
else
  t_ok "the native handler became ready"
  NATIVE_REPLY="$("${NATIVE_ENV[@]}" qs -p "$NATIVE_CFG/shell/shell.qml" ipc call boot time 2>/dev/null)"
  t_eq "the native verb returns the frozen report" "$CANON" "$(canonical "$NATIVE_REPLY")"
  t_eq "native and gateway expose the same report" "$CANON" "$(canonical "$(qp_get gateway.report)")"
fi

# --- pin the stand-in to the real handler bodies -----------------------------
t_section "the stand-in matches the real handler"
t_true "the native handler delegates to _bootReport" \
  grep -Fq 'function time(): string { return jsonOf(boot._bootReport()) }' "$SHELL_DIR/boot/Boot.qml"
t_true "the gateway map delegates to _bootReport" \
  grep -Fq '"boot.time": function () { return jsonOf(boot._bootReport()) }' "$SHELL_DIR/boot/Boot.qml"
t_true "_bootReport never mutates capture" \
  grep -Fq 'return boot._fitBootReport(boot.trace.snapshot())' "$SHELL_DIR/boot/Boot.qml"
t_skip "the real Boot component in a headless engine" \
  "UNVERIFIED: Boot pulls in LayerSurface/PanelWindow, which has no offscreen backend; stand-in owner used"
t_skip "visual boot presentation" "headless probe has no surface to render"

t_summary
