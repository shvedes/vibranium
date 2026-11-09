#!/bin/bash
# Suite: js-engine - every `.pragma library` JS file parses and binds in the
# QML engine the shell actually runs on.
#
# Why this exists: the node suites load these libraries through their own
# module loader, which accepts syntax the shell's V4 engine rejects. An object
# spread literal in MenuLib.js passed the whole menu suite and still took the
# bar, the launcher and the power menu down at boot - the import failed with
# `Expected token `}'` and every surface that reads the library failed with it.
# A node test cannot catch that class of defect, so this suite asks the engine.
#
# The file set is discovered, not listed: a new `.pragma library` file is in the
# probe the next run, and the count is asserted against the probe's own report
# so a file that silently stopped being imported fails rather than shrinks the
# coverage. Each alias is also read back (`typeof L<n>`), because an import that
# resolves to nothing would otherwise pass the count check alone.
#
# The control at the end is the teeth: a library with an object spread literal
# is dropped into the mirror and the suite asserts that the probe fails and the
# engine's parse error is in the output. Without it, a probe that never
# actually imported anything would look exactly like a passing run.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "js-engine" "every .pragma library JS file parses and binds in the QML engine"

require_qs
require_tools grep sort awk sed

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-js-engine.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

t_section "the file set"

# `.pragma library` is the first line of a QML JS library and is what makes the
# engine parse the file as a library rather than as a scoped script. Only those
# files are importable this way, so only those are in scope here.
mapfile -t JS_FILES < <(grep -rl '^\.pragma library' --include='*.js' "$SHELL_DIR" | LC_ALL=C sort)

t_not_empty "the tree ships .pragma library JS files" "${#JS_FILES[@]}"
COUNT="${#JS_FILES[@]}"

# Every file must be inside the shell tree; a path that escapes it cannot be
# expressed as a relative import from the probe in the mirror.
OUTSIDE=0
for f in "${JS_FILES[@]}"; do
  case "$f" in
  "$SHELL_DIR"/*) ;;
  *) OUTSIDE=$((OUTSIDE + 1)) ;;
  esac
done
t_count "every library is under the shell tree" "0" "$OUTSIDE"

t_section "one probe imports all of them"

PROBE="$WORK/probe.qml"
{
  printf 'import QtQuick\nimport Quickshell\n'
  for i in "${!JS_FILES[@]}"; do
    printf 'import "%s" as L%d\n' "${JS_FILES[$i]#"$SHELL_DIR"/}" "$i"
  done
  printf '\nShellRoot {\n  Component.onCompleted: {\n'
  printf '    console.log("##KV## imported=%d")\n' "$COUNT"
  for i in "${!JS_FILES[@]}"; do
    printf '    console.log("##KV## lib%d=" + (typeof L%d))\n' "$i" "$i"
  done
  printf '    console.log("##DONE##")\n    Qt.exit(0)\n  }\n}\n'
} >"$PROBE"

# A broken import aborts construction of the probe, so ##DONE## never arrives and
# qp_run reports the run as unfinished - which is the failure this suite wants.
if ! qp_run "$PROBE" 60; then
  t_no "the engine loads and binds every library" "$(qp_out)"
else
  t_ok "the engine loads and binds every library"
  t_eq "the probe imported the discovered file count" "$COUNT" "$(qp_get imported)"
  for i in "${!JS_FILES[@]}"; do
    t_eq "L$i binds an object (${JS_FILES[$i]#"$SHELL_DIR"/})" \
      "object" "$(qp_get "lib$i")"
  done
fi

t_section "the control: an engine-unparseable library must fail this check"

# Object spread in a literal is the exact defect this suite was written for: the
# node suites accept it, the QML engine does not. Asserting the probe fails here
# proves the check above is reading the engine's verdict and not just a count.
_QP_CFG="$(qp_setup)"
cat >"$_QP_CFG/bad.js" <<'EOF'
.pragma library
function broken() {
  const merged = { ...{ a: 1 } }
  return merged
}
EOF

cat >"$WORK/control.qml" <<'EOF'
import QtQuick
import Quickshell
import "bad.js" as Bad

ShellRoot {
  Component.onCompleted: {
    console.log("##KV## imported=" + (typeof Bad))
    console.log("##DONE##")
    Qt.exit(0)
  }
}
EOF

if qp_run "$WORK/control.qml" 20; then
  t_no "a library the engine cannot parse fails the probe" \
    "the probe finished anyway: $(qp_out)"
else
  t_ok "a library the engine cannot parse fails the probe"
  t_contains "the engine's parse error is in the transcript" \
    "Expected token" "$(qp_out)"
fi

qp_teardown

t_note "probed $COUNT .pragma library files; the control failed as required"

t_summary
