#!/bin/bash
# Headless Quickshell probe runner.
#
# A QML singleton cannot be unit-tested from node, but it can be *observed*
# from a live Quickshell: build a throwaway config that mirrors the shell
# tree, evaluate a probe that imports the real `qs.*` modules, print the
# values under test, and kill the process as soon as the probe says it is
# finished.
#
# The protocol a probe follows:
#
#   console.log("##KV## " + key + "=" + value)   // one per assertion
#   console.log("##DONE##")                       // exactly one, last
#
# `qp_run` returns 0 only when ##DONE## was seen, so a probe that fails to
# construct - the usual outcome of a broken singleton - is a failure and not a
# silently empty result set.
#
# Why a sentinel instead of Qt.quit(): `Qt.quit()` emits a signal with no
# receiver in this configuration, and `Qt.exit()` is not hooked up either, so
# the process runs until it is killed. Waiting for the sentinel and then
# killing the process group takes ~110ms instead of a timeout.
#
# Offscreen is required: without it the engine tries to open a window on a
# display this test run has no business touching.

require_qs() {
  require_tools qs
  if platform_mismatch="$(platform_mismatch)"; then
    t_block "$platform_mismatch"
  fi
}

# _qp_ensure_cfg creates the mirror once and sets _QP_CFG as a real global.
#
# This is split out from qp_setup because a function whose last statement is
# an assignment to a global cannot be called in a command substitution: the
# assignment happens in the subshell and is discarded, so the caller keeps an
# empty _QP_CFG, the mirror is rebuilt on every qp_run, and qp_teardown has
# nothing to remove. Callers that want the path still use qp_setup, which
# echoes it.
_QP_CFG=""

_qp_ensure_cfg() {
  [[ -n $_QP_CFG && -d $_QP_CFG ]] && return 0
  local cfg entry
  cfg="$(mktemp -d "${TMPDIR:-/tmp}/vb-shell-qml.XXXXXX")" || return 1
  for entry in "$SHELL_DIR"/*; do
    [[ -e $entry ]] || continue
    ln -s "$entry" "$cfg/$(basename "$entry")"
  done
  _QP_CFG="$cfg"
}

# qp_setup echoes the mirror's path, creating it if needed.
qp_setup() {
  _qp_ensure_cfg
  printf '%s' "$_QP_CFG"
}

qp_teardown() {
  if [[ -n $_QP_CFG && -d $_QP_CFG ]]; then
    rm -rf "$_QP_CFG"
    _QP_CFG=""
  fi
  qp_cleanup_out
}

# qp_run <probe-file> [timeout-seconds]
#
# Copies the probe into the mirror, runs it, and writes everything the probe
# printed to the file named by _QP_OUT. Returns 0 when ##DONE## arrived, 1
# when a probe never finished.
#
# _QP_OUT is replaced on every call, so a suite that runs the probe more than
# once must copy the output it needs out of it before the next run.
_QP_OUT=""

qp_cleanup_out() {
  if [[ -n $_QP_OUT && -f $_QP_OUT ]]; then
    rm -f "$_QP_OUT"
    _QP_OUT=""
  fi
}

qp_run() {
  local probe="$1" timeout="${2:-20}"
  qp_cleanup_out
  _qp_ensure_cfg || return 2
  local cfg="$_QP_CFG"

  cp "$probe" "$cfg/__probe.qml"
  _QP_OUT="$(mktemp "${TMPDIR:-/tmp}/vb-shell-probe.XXXXXX")"

  # setsid so the whole process group can be killed: qs spawns a render
  # thread and children that outlive a plain kill of the parent.
  setsid env QT_QPA_PLATFORM=offscreen \
    qs --no-color -p "$cfg/__probe.qml" >"$_QP_OUT" 2>&1 &
  local pid=$!

  local waited=0
  local limit=$((timeout * 20))
  while ((waited < limit)); do
    if grep -q '##DONE##' "$_QP_OUT" 2>/dev/null; then
      break
    fi
    # A probe that dies during construction never prints the sentinel. qs
    # stays alive in that case, so poll for a dead pid too rather than
    # burning the whole timeout.
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.05
    ((waited++))
  done

  kill -TERM -"$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  local rc=0
  grep -q '##DONE##' "$_QP_OUT" || rc=1
  return $rc
}

# qp_get <key> - the value the probe printed for a key, or the empty string.
qp_get() {
  sed -n "s/.*##KV## $1=//p" "$_QP_OUT" 2>/dev/null | head -1
}

# qp_out prints the raw probe output, for diagnosing a failed run.
qp_out() {
  cat "$_QP_OUT" 2>/dev/null
}

# qp_probe_ran <key> - true when the key was printed at all. Distinguishes
# "the value was empty" from "the probe never got that far", which is the
# difference between a wrong value and a broken singleton.
qp_probe_ran() {
  grep -q "##KV## $1=" "$_QP_OUT" 2>/dev/null
}

# qp_assert <label> <key> <expected> - the common case: the probe printed a
# key and it must equal the expected text.
qp_assert() {
  local label="$1" key="$2" expected="$3"
  if ! qp_probe_ran "$key"; then
    t_no "$label" "$(printf 'probe never printed key "%s"\n--- probe output ---\n%s' "$key" "$(qp_out)")"
    return
  fi
  t_eq "$label" "$expected" "$(qp_get "$key")"
}

# qp_assert_contains <label> <key> <needle>
qp_assert_contains() {
  local label="$1" key="$2" needle="$3"
  if ! qp_probe_ran "$key"; then
    t_no "$label" "$(printf 'probe never printed key "%s"' "$key")"
    return
  fi
  t_contains "$label" "$needle" "$(qp_get "$key")"
}

# qp_assert_match <label> <key> <extended-regex>
qp_assert_match() {
  local label="$1" key="$2" regex="$3"
  if ! qp_probe_ran "$key"; then
    t_no "$label" "$(printf 'probe never printed key "%s"' "$key")"
    return
  fi
  t_match "$label" "$regex" "$(qp_get "$key")"
}
