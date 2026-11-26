#!/bin/bash
# Suite: ipc-transport - the common router in a live Quickshell, plus one
# isolated real-qs echo probe with a resident `shell` IpcHandler.
#
# Neither half starts the desktop shell. The first half uses qmlprobe.sh's
# throwaway mirror of the shell tree; the second half uses a single standalone
# QML file with no window and no imports from the shell tree.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "ipc-transport" "IpcRouter in an offscreen engine; v1 echo on installed qs"
require_qs
require_tools grep sed env

trap qp_teardown EXIT

t_section "the router probe reached the end"
if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/ipc-transport.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi
if qp_probe_ran "probe.error"; then
  t_no "the probe ran without throwing" "$(qp_get probe.error)"
else
  t_ok "the probe ran without throwing"
fi

t_section "incarnation and registration"
t_eq "incarnation is ASCII" "true" "$(qp_get incarnation.ascii)"
t_eq "incarnation names this process" "true" "$(qp_get incarnation.process)"
t_eq "an unknown target is refused" "false" "$(qp_get register.unknownTarget)"
t_eq "an unknown row id is refused" "false" "$(qp_get register.unknownRow)"
t_eq "the injected help row cannot be owned" "false" "$(qp_get register.helpRow)"
t_eq "a complete constant map registers" "true" "$(qp_get register.good)"

t_section "strict request validation"
t_eq "a missing prefix" "invalid-argument" "$(qp_get bad.envelope)"
t_eq "a wrong wire version" "invalid-argument" "$(qp_get bad.version)"
t_eq "an unknown describe field" "invalid-argument" "$(qp_get bad.helpField)"
t_eq "an unknown invoke field" "invalid-argument" "$(qp_get bad.callField)"
t_eq "a literalFrom past argv" "invalid-argument" "$(qp_get bad.literalFrom)"
t_eq "an oversized request is refused before decoding" "oversize" "$(qp_get bad.requestOversize)"
t_eq "an oversized describe is refused before decoding" "oversize" "$(qp_get bad.describeOversize)"

t_section "index and help are paged immutable snapshots"
t_eq "index items are a page" "true" "$(qp_get index.isPaged)"
t_eq "index meta carries common once" "true" "$(qp_get index.hasCommon)"
t_eq "first page holds 24 targets" "24" "$(qp_get index.targetCount)"
t_eq "target ids are sorted" "true" "$(qp_get index.sorted)"
t_eq "the index does not repeat common rows" "true" "$(qp_get index.noCommonRows)"
t_eq "the lockscreen target is absent from the index" "true" "$(qp_get index.noLockscreen)"
t_eq "branch summary comes from the catalog" "Manage installed system fonts" "$(qp_get help.branch.summary)"
t_eq "branch help has an example" "1" "$(qp_get help.branch.examples)"
t_true "branch commands are catalog rows" test "$(qp_get help.commands)" -ge 1
t_contains "branch command ids belong to the target" "settings." "$(qp_get help.command.ids)"
t_eq "an unknown branch target is a target error" "unknown-target" "$(qp_get help.unknownTarget)"
t_eq "the removed lockscreen target has no help" "unknown-target" "$(qp_get help.removedTarget)"

t_section "dispatch, reply kinds and lifecycle"
t_eq "shortcut filters unknown and malformed events" "0" "$(qp_get shortcuts.ignored)"
t_eq "shortcut invokes the same launcher owner" "1" "$(qp_get shortcuts.toggle)"
t_eq "ping is injected" "pong" "$(qp_get invoke.ping)"
t_eq "session status dispatches through the real router" "true" "$(qp_get invoke.sessionStatus)"
t_eq "session reboot firmware routes as a refused destructive action" "refused" "$(qp_get invoke.sessionFirmware)"
t_eq "session isLocked is an unknown command" "unknown-command" "$(qp_get invoke.sessionIsLockedGone)"
t_eq "status passes explicit context" \
  '{"ok":true,"target":"watch","id":"watch.status"}' \
  "$(qp_get invoke.status | sed -E 's/,"incarnation":"[^"]+"//')"
t_eq "an extra argument is not a prefix match" "unknown-command" "$(qp_get invoke.extraArg)"
t_eq "an unknown command is not executed" "unknown-command" "$(qp_get invoke.unknownCommand)"
t_eq "the removed target is refused before command matching" "unknown-target" "$(qp_get invoke.removedUnlock)"
t_eq "the former terminal unlock payload is refused" "invalid-argument" "$(qp_get bad.removedUnlockAux)"
t_eq "log-read cannot execute in the router" "unsupported" "$(qp_get invoke.logRead)"
t_eq "a different owner cannot unregister" "false" "$(qp_get invoke.wrongOwner)"
t_eq "the real owner can unregister" "true" "$(qp_get invoke.correctOwner)"
t_eq "an unregistered owner is unavailable" "unavailable" "$(qp_get invoke.afterUnregister)"

t_section "page boundaries, identical meta and cursor discipline"
t_eq "first page is capped at 24" "24" "$(qp_get page.first.count)"
t_eq "meta is on the first page" "fixed" "$(qp_get page.first.marker)"
t_eq "a next cursor is opaque" "true" "$(qp_get page.first.hasNext)"
t_eq "second page holds the remainder" "6" "$(qp_get page.second.count)"
t_eq "meta is identical across pages" "fixed" "$(qp_get page.second.marker)"
t_eq "a reused cursor is stale" "stale" "$(qp_get page.reuse)"
t_eq "a foreign instance cursor is stale" "stale" "$(qp_get page.foreign)"
t_eq "an unknown cursor is stale" "stale" "$(qp_get page.unknown)"
t_eq "an evicted snapshot is gone" "false" "$(qp_get page.evictedSnapshot)"
t_eq "an evicted snapshot retires its cursor" "false" "$(qp_get page.evictedCursor)"
t_eq "every observation was printed" "true" "$(qp_get probe.complete)"

# --- the real-qs echo probe --------------------------------------------------
# Installed quickshell is pinned by require_qs. One resident IpcHandler echoes
# a single argv word byte-for-byte; this is the premise the v1 design relies
# on, measured rather than assumed.

t_section "headless real-qs v1 echo"
ECHO_CFG="$(mktemp -d "${TMPDIR:-/tmp}/vb-shell-echo.XXXXXX")"
ECHO_RUNTIME="$(mktemp -d "${TMPDIR:-/tmp}/vb-shell-echo-runtime.XXXXXX")"
ECHO_OUT="$(mktemp "${TMPDIR:-/tmp}/vb-shell-echo-out.XXXXXX")"
ECHO_CALL="$(mktemp "${TMPDIR:-/tmp}/vb-shell-echo-call.XXXXXX")"
cleanup_echo() {
  if [[ -n ${ECHO_PID:-} ]]; then
    kill -TERM "-$ECHO_PID" 2>/dev/null
    wait "$ECHO_PID" 2>/dev/null
  fi
  rm -rf "$ECHO_CFG" "$ECHO_RUNTIME" "$ECHO_OUT" "$ECHO_CALL"
}
trap 'qp_teardown; cleanup_echo' EXIT
mkdir "$ECHO_CFG/shell"
ECHO_CONFIG="$ECHO_CFG/shell/shell.qml"
ECHO_ENV=(env -u DISPLAY -u WAYLAND_DISPLAY -u QS_CONFIG_PATH -u QS_CONFIG_NAME -u QS_MANIFEST
  XDG_RUNTIME_DIR="$ECHO_RUNTIME" QT_QPA_PLATFORM=offscreen VIBRANIUM="$ECHO_CFG")
cat >"$ECHO_CONFIG" <<'QML'
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  Component.onCompleted: console.log("##READY##")

  IpcHandler {
    target: "shell"
    function echo(request: string): string { return request }
  }
  IpcHandler {
    target: "log"
    function status(): string {
      return JSON.stringify({ level: "info", scope: "日本語", state: "x".repeat(6000) })
    }
  }
}
QML

setsid "${ECHO_ENV[@]}" qs --no-color -p "$ECHO_CONFIG" >"$ECHO_OUT" 2>&1 &
ECHO_PID=$!
ready=false
for _ in $(seq 1 100); do
  grep -q '##READY##' "$ECHO_OUT" 2>/dev/null && { ready=true; break; }
  kill -0 "$ECHO_PID" 2>/dev/null || break
  sleep 0.05
done
if [[ $ready == false ]]; then
  t_no "the echo handler became ready" "$(cat "$ECHO_OUT")"
else
  t_ok "the echo handler became ready"
  FRAME='v1:{"v":1,"text":"h\u00e9llo \ud83d\ude00","arr":["A","a",""],"n":true}'
  "${ECHO_ENV[@]}" qs -p "$ECHO_CONFIG" ipc call shell echo "$FRAME" >"$ECHO_CALL" 2>/dev/null
  rc=$?
  t_eq "qs accepted the single envelope word" "0" "$rc"
  t_eq "Unicode, array, case and empty string round-trip exactly" "$FRAME" "$(cat "$ECHO_CALL")"
  "${ECHO_ENV[@]}" qs -p "$ECHO_CONFIG" ipc call shell noSuchVerb >"$ECHO_CALL" 2>/dev/null
  t_eq "a missing native method prints a sentinel with exit zero" \
    "Function not found." "$(cat "$ECHO_CALL")"
  log_output="$("${ECHO_ENV[@]}" "$VIBRANIUM_DIR/bin/vb-shell" --verbose log status 2>"$ECHO_CALL")"
  t_eq "the direct log status call succeeds" "0" "$?"
  t_contains "the log client uses the socket" "ipc call log status (socket)" "$(cat "$ECHO_CALL")"
  t_eq "the multi-read reply keeps non-ASCII QString data" $'level: info\nscope: 日本語' "$log_output"
  t_eq "log ping accepts the direct status reply" "pong" \
    "$("${ECHO_ENV[@]}" "$VIBRANIUM_DIR/bin/vb-shell" log ping)"
fi

t_summary
