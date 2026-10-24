#!/bin/bash
# Suite: common/ui/PanelFocus.qml - the focus gate, against a consumer's own
# editors, in a real Window.
#
# PanelFocus is the one place every overlay panel's keyboard ownership lives,
# and it reaches focus through exactly two items: the search field and the key
# sink. Everything else in a panel surface belongs to the consumer - the field
# inside a dropdown slot being the ordinary one - so the rule this suite pins
# is that an AUTOMATIC focus request (the window re-seat, the search field's
# own focus watcher) is owed only while nothing in the surface holds focus.
#
# The bug it exists for is a focus war. `QQuickWindow.activeFocusItem` changes
# on every focus change, including the one an editor makes when it opens, and
# the re-seat that watched it answered each one by handing focus back to the
# panel. A number picker or a text field in a dropdown opened, took focus, and
# had it taken away a turn later, with nothing re-asserting it afterwards: not
# activated, not active, and not clickable back into life either.
#
# The probe drives the shell's own editors through the call the shell makes
# (`grabFocus()`, which is what InlineEditor.takeFocus() calls) and reads the
# focus owner on later event-loop turns, because the theft happens a turn
# after the grab - the turn the window reports the new focus item.
#
# Both halves of the rule are staged, in the order a session runs them: a
# fresh window sits on Qt's content-item placeholder, which is the "nobody is
# focused" state a panel is left in when the compositor's keyboard grant costs
# it its focus request, so the re-seat is owed and must seat the sink; the
# editors open afterwards, and the gate is what must keep them.
#
# Not reachable here, and not claimed: anything a key press would do (no
# compositor, no QTest), the pre-grant case itself (a request made while the
# surface is still inactive needs a compositor to stage), and the
# InlineEditor's own takeFocus() (its module declares `singleton Menu`, which
# reaches MenuView -> OverlayWindow -> ScrimWindow -> a PanelWindow backend
# that offscreen does not have). Each is a t_skip, never a silent pass.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "focus" "common/ui/PanelFocus.qml: the focus gate against a consumer's own editors"
require_qs

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/focus.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing" "none" "$(qp_get focus.error)"

# --- the number picker under test is the shell's own file -------------------

t_section "the number picker is the shell's own bytes, with two imports rewritten"
t_eq "the source was read" "200" "$(qp_get focus.picker.status)"
t_eq "and it is not empty" "true" "$([ "$(qp_get focus.picker.len)" -gt 4000 ] && echo true || echo false)"
t_eq "exactly one module import was dropped" "1" "$(qp_get focus.picker.moduleImportsDropped)"
t_eq "and the sibling MenuLib import was re-rooted" "1" "$(qp_get focus.picker.siblingRerooted)"
t_eq "it measures as the input height, so it is the real component" "32" "$(qp_get focus.picker.height)"
t_note "NumberPicker.qml cannot be written out as a type here: qs.features.menu declares 'singleton Menu', and loading the module reaches MenuView -> OverlayWindow -> ScrimWindow -> ScrimWindow's PanelWindow backend, which offscreen does not have ('No PanelWindow backend loaded'). So the probe drops the one module import - NumberPicker uses no type from it, MenuLib arrives on the next line - and re-roots 'import \"MenuLib.js\"' at the config root, because that is where the rewritten text is evaluated from. The drop is counted rather than pattern-matched silently, so a NumberPicker that starts using a module type makes this section red instead of testing something else."

# --- the heal: a panel left holding nothing ---------------------------------

t_section "a surface nobody has focused is the panel's to take"
t_eq "at construction the window has no focus item at all" "none" "$(qp_get focus.pre.owner)"
t_eq "and the panel's sink does not hold focus" "false" "$(qp_get focus.pre.sink)"
t_eq "the window is active, which is what makes the handler reachable" "true" "$(qp_get focus.window.active)"
t_eq "one turn later the sink holds focus nobody asked for" "true" "$(qp_get focus.turn1.sink)"
t_eq "and it stays seated" "true" "$(qp_get focus.turn2.sink)"
t_eq "with the gate closed behind it" "false" "$(qp_get focus.turn2.unowned)"

# --- the fight: a number picker in a dropdown slot --------------------------

t_section "a number picker in the panel's own surface keeps its focus"
t_eq "the editor is the focus owner a turn after it grabs" "editor" "$(qp_get focus.turn4.owner)"
t_eq "and it is the picker's own field, holding its display value" "42" "$(qp_get focus.turn4.text)"
t_eq "a turn later it still holds focus" "editor" "$(qp_get focus.turn5.owner)"
t_eq "with the value intact" "42" "$(qp_get focus.turn5.text)"
t_eq "and the key sink has not taken it back" "false" "$(qp_get focus.turn5.sink)"
t_eq "the mode was not rewritten on the way" "list" "$(qp_get focus.turn4.mode)"
t_eq "the panel's own probe agrees: no field, list mode" '{"focused":false,"text":"","mode":"list"}' "$(qp_get focus.turn4.probe)"

# --- the fight: a text field, in filter mode -------------------------------

t_section "a text field in filter mode keeps its focus from the panel's field"
t_eq "the panel is in filter mode with its own field focused" "search" "$(qp_get focus.turn6.owner)"
t_eq "and the mode says so" "filter" "$(qp_get focus.turn6.mode)"
t_eq "the editor takes focus when the row opens" "editor-text" "$(qp_get focus.turn7.owner)"
t_eq "and it is the text field, holding its own text" "hello" "$(qp_get focus.turn7.text)"
t_eq "a turn later the search field has not healed over it" "editor-text" "$(qp_get focus.turn8.owner)"
t_eq "with the text still there" "hello" "$(qp_get focus.turn8.text)"
t_eq "and the mode is untouched" "filter" "$(qp_get focus.turn8.mode)"
t_eq "the gate reads the surface as owned" "false" "$(qp_get focus.turn9.unowned)"
t_eq "a direct reseat moves nothing" "editor-text" "$(qp_get focus.turn10.owner)"
t_eq "and the text survives it" "hello" "$(qp_get focus.turn10.text)"

t_note "reassert() is the consumer's own lever and behaves differently on purpose: called while the text editor holds focus in filter mode it takes the panel's field back (turn 11 reads owner=search). That is why MenuPanel keeps its own editor-aware reassertFocus instead of delegating, and why the gate lives on the automatic paths rather than on reassert itself. Recorded so the contrast is on the record, not asserted: the claim under test is that nothing AUTOMATIC moves focus off a consumer's editor."

# --- what this environment cannot reach -------------------------------------

t_section "gaps, stated rather than passed over"
t_skip "keystrokes landing in a focused field" \
  "no compositor and no QTest: what a focused field does with a key event is not reachable from a headless probe, so the suite asserts focus ownership - the state that has to hold for a keystroke to arrive at all - and not the delivery"
t_skip "the pre-grant case, a focus request made while the surface is inactive" \
  "needs a compositor: offscreen reports the window active from the first turn, so a request cannot be staged inside the window where the grant would cost it. The heal it repairs is asserted above through the same code path, from the one state offscreen can reach - a surface with no focus item"
t_skip "InlineEditor.takeFocus() itself" \
  "qs.features.menu cannot be imported headlessly ('singleton Menu' reaches MenuView -> OverlayWindow -> ScrimWindow -> a PanelWindow backend offscreen does not have). takeFocus() is a five-line dispatch to the two editors under test, both entered here through the grabFocus() it calls"
t_note "Two windows would stage the two halves of the gate better - the fight and the heal cannot share one surface - but under offscreen a second visible window takes the focus bookkeeping with it and the first window's items stop being able to take focus at all. Measured, not assumed, and the reason the probe orders the heal before the fight in one window instead."

t_summary
