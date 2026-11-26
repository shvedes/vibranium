#!/bin/bash
# Gate 5: compositor presentation check.
#
#   bash tests/shell/bench/unit-pilot/compositor-gate.sh
#
# Intended check: an ISOLATED compositor, identical output/wallpaper/motion
# settings, controlled test content only, verifying first visible content and
# the bar/wallpaper entrance order plus the animation invariants. No user
# desktop content is ever captured or inspected by this driver.
set -uo pipefail

REPORT_DIR="${VB_PILOT_REPORT_DIR:-/tmp/opencode/vibranium-pilot-reports}"
mkdir -p "$REPORT_DIR"
OUT="$REPORT_DIR/gate5-compositor.json"
reasons=()

if [[ -z ${VB_BENCH_COMPOSITOR_SOCKET:-} ]]; then
  reasons+=("no isolated compositor socket (VB_BENCH_COMPOSITOR_SOCKET unset); WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>} is the host session")
elif [[ ! -S ${VB_BENCH_COMPOSITOR_SOCKET} ]]; then
  reasons+=("VB_BENCH_COMPOSITOR_SOCKET=${VB_BENCH_COMPOSITOR_SOCKET} is not a live socket")
fi
if [[ ${VB_BENCH_ALLOW_LIVE_SHELL:-0} != 1 ]]; then
  reasons+=("no authorization to launch a shell on a compositor (VB_BENCH_ALLOW_LIVE_SHELL!=1); doing so would attach to the user session")
fi
if [[ -z ${VB_PILOT_CONTROLLED_CONTENT:-} ]]; then
  reasons+=("no controlled test content harness (VB_PILOT_CONTROLLED_CONTENT unset); production wallpaper and bar content cannot stand in")
fi
reasons+=("offscreen Quickshell has zero screens and no PanelWindow backend, so no first-paint or entrance order can be observed")

printf '=== GATE 5: COMPOSITOR PRESENTATION ===\n'
printf 'UNVERIFIED. No compositor launch, no screen capture, no user desktop inspection.\n'
for reason in "${reasons[@]}"; do printf '  - %s\n' "$reason"; done
printf 'shipping and expansion are deferred until this gate is verified.\n'

{
  printf '{\n'
  printf '  "verdict": "UNVERIFIED",\n'
  printf '  "gate": "compositor-presentation",\n'
  printf '  "checks": {\n'
  printf '    "firstVisibleContent": "not run",\n'
  printf '    "barWallpaperEntranceOrder": "not run",\n'
  printf '    "animationInvariants": "not run"\n'
  printf '  },\n'
  printf '  "userDesktopContentRecorded": false,\n'
  printf '  "shippingAndExpansion": "deferred",\n'
  printf '  "reasons": [\n'
  for i in "${!reasons[@]}"; do
    printf '    "%s"%s\n' "${reasons[$i]//\"/\\\"}" "$([[ $i -lt $((${#reasons[@]} - 1)) ]] && printf , || printf '')"
  done
  printf '  ]\n}\n'
} >"$OUT"
printf 'unverified report: %s\n' "$OUT"
exit 77
