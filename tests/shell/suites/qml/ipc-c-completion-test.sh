#!/bin/bash
# Suite: batch C singletons complete startup in a headless real Quickshell.
#
# This is the regression guard for the empty-bar incident: an assignment to
# an undeclared property inside Component.onCompleted threw under
# `pragma ComponentBehavior: Bound`, aborting the rest of startup. The probe
# constructs the real bar, clipboard and emoji pickers in an isolated config
# and reads their registration verdicts; the runner also scans the whole
# diagnostic stream for that error class.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "ipc-c-completion" "a batch C singleton finishes onCompleted and registers offscreen"
require_qs
require_tools grep mktemp

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-ipc-c-completion.XXXXXX")"
trap 'qp_teardown; rm -rf "$WORK"' EXIT

# Private XDG roots: constructing these singletons reads configuration and
# cache paths. Nothing here may touch the user's session.
mkdir -p "$WORK/config" "$WORK/state" "$WORK/cache" "$WORK/data" "$WORK/run"
export XDG_CONFIG_HOME="$WORK/config"
export XDG_STATE_HOME="$WORK/state"
export XDG_CACHE_HOME="$WORK/cache"
export XDG_DATA_HOME="$WORK/data"
export VIBRANIUM_RUNTIME="$WORK/run"
# The inherited config path would put the real module tree ahead of the
# stub root below, so nothing here may inherit it.
export QS_CONFIG_PATH= QS_CONFIG_NAME= QS_MANIFEST=

# EmojiPicker now imports the Menu singleton to compare bundle identity. The
# real Menu type pulls MenuView -> OverlayWindow -> PanelWindow, which cannot
# be constructed offscreen. Stub only that external window boundary: a module
# root that mirrors the shell tree except for `qs.features.menu`, whose
# singleton is a plain QtObject. EmojiPicker, IpcRouter, Registry and the
# menu's own JS libraries are the real files, so completion and registration
# are still observed on the code under test.
STUB="$WORK/stub"
mkdir -p "$STUB/shell/features/menu"
for entry in "$SHELL_DIR"/*; do
  [[ $(basename "$entry") == features ]] && continue
  ln -s "$entry" "$STUB/shell/$(basename "$entry")"
done
for entry in "$SHELL_DIR/features"/*; do
  [[ $(basename "$entry") == menu ]] && continue
  ln -s "$entry" "$STUB/shell/features/$(basename "$entry")"
done
for entry in "$SHELL_DIR/features/menu"/*; do
  [[ $(basename "$entry") == Menu.qml || $(basename "$entry") == qmldir ]] && continue
  ln -s "$entry" "$STUB/shell/features/menu/$(basename "$entry")"
done
cat >"$STUB/shell/features/menu/qmldir" <<'QMLDIR'
module qs.features.menu
singleton Menu 1.0 Menu.qml
QMLDIR
cat >"$STUB/shell/features/menu/Menu.qml" <<'QML'
pragma Singleton
import QtQml
QtObject {
  function isBundleOpen(path) { return false }
  function openFile(path) { return true }
  function close() { return true }
}
QML
export VIBRANIUM="$STUB"
ln -s "$STUB/shell" "$XDG_CONFIG_HOME/quickshell"

# qp_setup assigns `_QP_CFG` inside a command substitution, so callers that
# want to edit the mirror must set the global directly: qp_run would otherwise
# rebuild a fresh, unstubbed mirror on the next call.
_QP_CFG="$(qp_setup)"
CFG="$_QP_CFG"
# Keep the probe mirror in step with the stubbed module root: a relative
# import from EmojiPicker would otherwise walk back into the real menu dir.
if [[ -L $CFG/features ]]; then
  rm "$CFG/features"
  cp -a "$STUB/shell/features" "$CFG/features"
fi

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/ipc-c-completion.qml" 30; then
  t_no "the probe reached ##DONE##" "probe did not finish. $(qp_out)"
  t_summary
  exit $?
fi
if qp_probe_ran "probe.error"; then
  t_no "the probe ran without throwing" "$(qp_get probe.error)"
fi

t_section "no Bound-component assignment error"
t_not_contains "no undeclared property assignment" "Cannot assign to non-existent property" "$(qp_out)"
t_not_contains "no ReferenceError from onCompleted" "ReferenceError" "$(qp_out)"

t_section "registration verdict is published"
t_eq "emojiPicker completed" "true" "$(qp_get emoji.verdict)"

t_section "the router sees the owner"
t_eq "emojiPicker is registered" "true" "$(qp_get router.emoji)"

t_summary
