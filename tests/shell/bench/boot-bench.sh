#!/bin/bash
# Phase 5 opt-in boot benchmark (deliberately OUTSIDE suites/, so run-all.sh
# never discovers it).
#
#   bash tests/shell/bench/boot-bench.sh --runs=20 --mode=cold --compare=<baseline.json>
#   bash tests/shell/bench/boot-bench.sh --runs=20 --mode=cold --pilot
#   bash tests/shell/bench/boot-bench.sh --help
#
# Full protocol = live shell with the registered `boot` target under an
# isolated compositor, external IPC readiness as endpoint, identical probe
# cadence, randomized A/B pairs. This host cannot provide that; the wrapper
# prints a specific BLOCKED reason and exits 77 unless --pilot is given.
# --pilot runs a clearly labelled headless/common-observable measurement using
# the real BootPump, AsyncLoader, BootTrace recorder and IpcProtocol codec.
# A pilot makes NO boot-endpoint or presentation claim.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$BENCH_DIR/../../.." && pwd)"
ENGINE="$BENCH_DIR/boot-bench.mjs"

runs=20
mode=cold
compare=""
out=""
pilot=0

usage() {
  cat <<EOF
Usage: bash tests/shell/bench/boot-bench.sh [options]

  --runs=N             paired blocks (minimum 20 for a p95 claim; default 20)
  --mode=cold|warm     cold = fresh cache per launch; warm = prior identical launch seeds it
  --compare=<file.json> compare this run with a pinned result summary
  --pilot              run the explicitly labelled headless/common-observable pilot
  --out=<file.json>    result destination (default: tests/shell/fixtures/boot-bench/result-<mode>-pilot.json)
  --help               this text

Protocol (full): predeclared external IPC readiness endpoint, identical probe
  cadence, randomized A/B block order (>=20 pairs), pinned build/hardware/
  compositor/refresh/VRR/outputs/settings beside the result (never inside
  graphDigest), explicit censoring of non-starts/timeouts, p50/p95, paired p95
  effect with block-resampling CI. Cold and warm are never mixed.

Gate: an optimisation lands only if p95 improves beyond paired uncertainty AND
  the structural golden snapshot is unchanged AND the visual contract holds.
  A headless pilot cannot certify the visual contract, so its gate is always
  NOT_LANDED; it reports the comparison without changing production code.

Host limitation: this host has no isolated compositor/surface owner, and
  offscreen Quickshell exposes no screens or PanelWindow backend. Starting the
  live shell here would attach to the user session, so no cold/warm boot
  endpoint is claimed. Use --pilot for the labelled headless run.
EOF
}

while (($#)); do
  arg="$1"
  case "$arg" in
    --runs=*) runs="${arg#--runs=}" ;;
    --mode=*) mode="${arg#--mode=}" ;;
    --compare=*) compare="${arg#--compare=}" ;;
    --out=*) out="${arg#--out=}" ;;
    --pilot) pilot=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if ! [[ $runs =~ ^[0-9]+$ ]] || ((runs < 1)); then
  printf 'bad --runs=%s\n' "$runs" >&2
  exit 2
fi
if [[ $mode != cold && $mode != warm ]]; then
  printf 'bad --mode=%s (expected cold or warm)\n' "$mode" >&2
  exit 2
fi
if [[ -n $compare && ! -f $compare ]]; then
  printf 'baseline not found: %s\n' "$compare" >&2
  exit 2
fi

full_protocol_reason() {
  local reasons=()
  if [[ ${VB_BENCH_ALLOW_LIVE_SHELL:-0} != 1 ]]; then
    reasons+=("live shell launch not authorized (VB_BENCH_ALLOW_LIVE_SHELL!=1); starting it would attach to the user session")
  fi
  if [[ -z ${VB_BENCH_COMPOSITOR_SOCKET:-} ]]; then
    reasons+=("no isolated compositor socket provisioned (VB_BENCH_COMPOSITOR_SOCKET unset); WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>} is the host session")
  fi
  reasons+=("offscreen Quickshell has zero screens and no PanelWindow backend; external IPC readiness of the registered boot target cannot be probed here")
  printf '%s\n' "${reasons[@]}"
}

printf '=== PHASE 5 BOOT BENCH (opt-in; not part of run-all.sh) ===\n'
printf 'mode=%s runs=%s compare=%s\n' "$mode" "$runs" "${compare:-<none>}"
printf 'FULL PROTOCOL BLOCKED ON THIS HOST:\n'
while IFS= read -r reason; do printf '  - %s\n' "$reason"; done < <(full_protocol_reason)

if ((pilot == 0)); then
  printf '\nBLOCKED: use --pilot to run the explicitly labelled headless/common-observable pilot.\n'
  exit 77
fi
printf '\nPILOT MODE: headless common observables only — no cold/warm boot endpoint and no presentation claim.\n'

args=(--runs="$runs" --mode="$mode" --pilot)
[[ -n $compare ]] && args+=(--compare="$compare")
[[ -n $out ]] && args+=(--out="$out")

cd "$ROOT"
exec node "$ENGINE" "${args[@]}"
