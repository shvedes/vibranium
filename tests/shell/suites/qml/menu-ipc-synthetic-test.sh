#!/bin/bash
# Suite: menu-ipc-synthetic - the public Menu gateway without a desktop shell.
#
# The real Menu singleton is built offscreen in a disposable config mirror.
# Its view component is replaced by an inert Item so no Wayland layer surface
# is required (the menu model must work when no panel is mounted; that is an
# explicit contract of the gateway). A synthetic bundle drives every row type,
# then observations and mutations go through the same gateway frames the
# router hands to vb-shell. No key event, debug probe or delegate polling is
# used anywhere in this suite.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "menu-ipc-synthetic" "synthetic-menu gateway: refs, guards, staged actions and protection"

require_qs

PROBE="$VIBRANIUM_DIR/tests/shell/suites/qml/probes/menu-ipc-synthetic.qml"
if [[ ! -f $PROBE ]]; then
  t_block "the synthetic menu probe is missing"
fi

qp_setup >/dev/null
trap qp_teardown EXIT

# Replace only the view component in the disposable mirror. Every other module
# stays a symlink to the real shell tree, so this exercises production code.
cfg="$_QP_CFG"
rm -rf "$cfg/features"
mkdir -p "$cfg/features"
for d in "$SHELL_DIR"/features/*; do
  [[ -e $d ]] && ln -s "$d" "$cfg/features/$(basename "$d")"
done
rm -rf "$cfg/features/menu"
mkdir -p "$cfg/features/menu"
for f in "$SHELL_DIR"/features/menu/*; do
  [[ -e $f ]] && ln -s "$f" "$cfg/features/menu/$(basename "$f")"
done
rm -f "$cfg/features/menu/MenuView.qml"
cat > "$cfg/features/menu/MenuView.qml" <<'QML'
import QtQuick
Item { width: 1; height: 1 }
QML

if ! qp_run "$PROBE" 40; then
  t_no "synthetic menu probe completed" "$(qp_out)"
else
  t_ok "synthetic menu probe completed"

  # Closed root: success with an empty model, never an error.
  qp_assert "closed root" closed.open false
  qp_assert "closed page" closed.page null
  qp_assert "closed depth" closed.depth 0
  qp_assert "closed scope" closed.scope none
  qp_assert "closed row" closed.row null
  qp_assert "closed current" closed.currentOpen false
  qp_assert "closed list is unavailable" closed.listCode unavailable
  qp_assert "closed pages are empty" closed.pagesEmpty 0
  qp_assert "closed navigation is unavailable" closed.goCode unavailable

  # Open, refs and projection.
  qp_assert "open succeeds" open.ok true
  qp_assert "entry page" open.page main
  qp_assert "same bundle is a no-op" open.sameNoop main
  qp_assert "row count" list.count 14
  qp_assert "ref format" list.refShape true
  qp_assert "nested parent ref" list.parentShape true

  # Typed writes.
  qp_assert "toggle before" toggle.before false
  qp_assert "toggle set" toggle.set true
  qp_assert "toggle after" toggle.after true
  qp_assert "wrong toggle type" toggle.wrongType invalid-argument
  qp_assert "toggle activate" toggle.activate true
  qp_assert "number step up" number.step 15
  qp_assert "number clamp" number.clamp 20
  qp_assert "wrong number type" number.wrongType invalid-argument
  qp_assert "number step down" number.stepDown 15
  qp_assert "text trims and commits" text.set new
  qp_assert "text commit closes editor" text.openAfterSet false

  # Options and choices.
  qp_assert "option ids" options.ids o0,o1
  qp_assert "declared disabled option" options.disabled false
  qp_assert "unknown option id" choose.badId not-found
  qp_assert "disabled option refused" choose.disabled refused
  qp_assert "select set outside prompt" select.setRefuses refused

  # Protection and guard veto.
  qp_assert "protected row marked" secret.protected true
  qp_assert "protected value redacted" secret.valueRedacted null
  qp_assert "protected write refused" secret.writeRefused unsupported
  qp_assert "blocked ancestor muting" blocked.available false
  qp_assert "blocked activation refused" blocked.activate refused

  # Staged flow with skipUnless, Back and cancellation.
  qp_assert "flow opens" flow.open true
  qp_assert "flow current draft" flow.set ok
  qp_assert "future step refused" flow.skipStep refused
  qp_assert "flow advance over skip" flow.next 1
  qp_assert "flow set draft" flow.setDraft ok
  qp_assert "flow back" flow.back 0
  qp_assert "flow cancel" flow.cancel false
  qp_assert "cancelled flow persists nothing" flow.noPersist ""

  # Three confirmation stages and deletion stages.
  qp_assert "confirm arms on activate" confirm.arm ok
  qp_assert "confirm stage 1" confirm.status1 1
  qp_assert "confirm stage 2" confirm.next2 2
  qp_assert "confirm stage 3" confirm.next3 3
  qp_assert "confirm cancel" confirm.cancel 0
  qp_assert "next without active confirm" confirm.nextIdle refused
  qp_assert "delete stage 1" delete.1 ok
  qp_assert "delete stage 2" delete.2 ok

  # Navigation, generations and grid action.
  qp_assert "pages projected" pages.count 3
  qp_assert "reachable pages" pages.reachable 2
  qp_assert "go navigates" go.other other
  qp_assert "back pops" back.main main
  qp_assert "live ref survives focus change" current.refStillLive true
  qp_assert "rebuilt page retires ref" generation.pageRefChanged true
  qp_assert "old generation ref is stale" generation.oldRefStale stale
  qp_assert "grid page reached" go.cells cells
  qp_assert "grid action dispatched" grid.action ok
  qp_assert "grid action closes" back.afterGrid false

  # Search and closing.
  qp_assert "reopen after grid action" reopen true
  qp_assert "global search" search.global ok
  qp_assert "search result projected" search.hasHits true
  qp_assert "partial rerender" search.rerender ok
  qp_assert "rerender retires result ref" search.rerenderStale stale
  qp_assert "search clear" search.clear none
  qp_assert "visual select needs a panel" select.noPanel unavailable
  qp_assert "other bundle is not open" bundle.isOpenOther false
  qp_assert "close" close.ok false
  qp_assert "closed after close" closed.afterClose false
  qp_assert "refs retire on close" ref.staleAfterClose stale

  # Real v1 envelopes through the real router.
  qp_assert "owner is registered" router.registered true
  qp_assert "router ping" router.ping '"pong"'
  qp_assert "router open" router.open true
  qp_assert "router list" router.list 14
  qp_assert "router unknown command" router.unknown unknown-command
  qp_assert "router item branch help" router.itemBranch true
  # The inline/file branches carry their own dispatch rows plus help-only
  # placeholders; they are presentation rows, not extra verbs.
  qp_assert "router row count" router.rowCount 47

  # Built-in Settings bundle with an injected page and a runtime option list.
  qp_assert "settings bundle opens" settings.openCode ok
  qp_assert "bundle source ignores fragment" settings.isBundleOpen true
  qp_assert "settings entry page" settings.bundleEntry main
  qp_assert "injected page is listed" settings.journeyPage true
  qp_assert "injected page list" settings.journeyList ok
  qp_assert "dynamic option list" settings.dynamicOptions 2
  qp_assert "dynamic option chosen" settings.dynamicChoose ok
  qp_assert "dynamic value committed" settings.dynamicValue two
fi

t_summary
