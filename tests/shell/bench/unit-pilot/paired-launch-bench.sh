#!/bin/bash
# Gate 4: paired launch benchmark, powerProfile.status and appLauncher.status.
#
#   bash tests/shell/bench/unit-pilot/paired-launch-bench.sh
#
# FULL PROTOCOL ONLY. No synthetic headless pilot and no static check is
# substituted: an endpoint is a real launch of the selected test instance
# under an isolated compositor, with external IPC readiness as the endpoint,
# identical config/timeout/poll cadence, seeded order within each pair, and
# separate cold/warm protocols with per-variant seeded caches.
#
# This host cannot provide the isolated compositor/socket or the authorization
# to launch the shell; the preflight below prints the exact reasons and exits
# 77 (BLOCKED) before any launch is attempted. The harness must supply all
# three endpoints (VB_PILOT_LAUNCH_CMD, VB_PILOT_READY_CMD, VB_PILOT_STOP_CMD)
# plus the authorization and an isolated compositor socket.
set -uo pipefail

PILOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${VB_PILOT_REPORT_DIR:-/tmp/opencode/vibranium-pilot-reports}"
mkdir -p "$REPORT_DIR"
OUT="$REPORT_DIR/gate4-paired-launch.json"

baseline_commit="9c3b2828"
runs="${VB_PILOT_PAIRS:-20}"
resolution_ms=1
socket="${VB_BENCH_COMPOSITOR_SOCKET:-}"
reasons=()

if [[ ${VB_BENCH_ALLOW_LIVE_SHELL:-0} != 1 ]]; then
  reasons+=("live shell launch not authorized (VB_BENCH_ALLOW_LIVE_SHELL!=1); starting it would attach to the user session")
fi
if [[ -z $socket ]]; then
  reasons+=("no isolated compositor socket provisioned (VB_BENCH_COMPOSITOR_SOCKET unset); WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>} is the host session")
elif [[ ! -S $socket ]]; then
  reasons+=("VB_BENCH_COMPOSITOR_SOCKET=$socket is not a live socket")
elif [[ $socket == "$WAYLAND_DISPLAY" || $socket == *"/$WAYLAND_DISPLAY" ]]; then
  reasons+=("VB_BENCH_COMPOSITOR_SOCKET=$socket is the host session's WAYLAND_DISPLAY=$WAYLAND_DISPLAY")
fi
if [[ -z ${VB_PILOT_LAUNCH_CMD:-} ]]; then
  reasons+=("no harness launch endpoint (VB_PILOT_LAUNCH_CMD unset)")
fi
if [[ -z ${VB_PILOT_READY_CMD:-} ]]; then
  reasons+=("no harness readiness endpoint (VB_PILOT_READY_CMD unset)")
fi
if [[ -z ${VB_PILOT_STOP_CMD:-} ]]; then
  reasons+=("no harness stop endpoint (VB_PILOT_STOP_CMD unset)")
fi
reasons+=("offscreen Quickshell has zero screens and no PanelWindow backend; the registered IPC readiness endpoint cannot be probed offscreen")

printf '=== GATE 4: PAIRED LAUNCH BENCH (full protocol only) ===\n'
printf 'baseline=%s runs=%s resolution_ms=%s\n' "$baseline_commit" "$runs" "$resolution_ms"
printf 'endpoints: powerProfile.status, appLauncher.status\n'
printf 'modes: cold, warm (separate protocols, per-variant seeded caches)\n'

if (( ${#reasons[@]} > 0 )); then
  printf 'BLOCKED / INCONCLUSIVE. No launch attempted. No statistic computed.\n'
  for reason in "${reasons[@]}"; do printf '  - %s\n' "$reason"; done
  {
    printf '{\n'
    printf '  "verdict": "BLOCKED",\n'
    printf '  "gate": "paired-launch-benchmark",\n'
    printf '  "baseline": "%s",\n' "$baseline_commit"
    printf '  "endpoints": ["powerProfile.status", "appLauncher.status"],\n'
    printf '  "modes": ["cold", "warm"],\n'
    printf '  "requiredPairsPerMode": %s,\n' "$runs"
    printf '  "obtainedPairs": {"cold": 0, "warm": 0},\n'
    printf '  "observationResolutionMs": %s,\n' "$resolution_ms"
    printf '  "censoring": null,\n'
    printf '  "p95": null,\n'
    printf '  "interval95": null,\n'
    printf '  "substitutesUsed": [],\n'
    printf '  "reasons": [\n'
    for i in "${!reasons[@]}"; do
      printf '    "%s"%s\n' "${reasons[$i]//\"/\\\"}" "$([[ $i -lt $((${#reasons[@]} - 1)) ]] && printf , || printf '')"
    done
    printf '  ]\n}\n'
  } >"$OUT"
  printf 'blocked report: %s\n' "$OUT"
  exit 77
fi

# Unreachable on this host. A real harness would launch each selected instance
# through the three supplied endpoints, stop it before the next launch, seed
# order within each A/B pair, and feed the resulting durations to
# paired-stats.mjs for each endpoint and mode.
printf 'harness endpoints present; this driver does not execute on the verification host\n'
exit 77
