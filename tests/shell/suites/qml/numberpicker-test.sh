#!/bin/bash
# Suite: features/menu/NumberPicker.qml - the numeric filter, and the unit that
# used to switch it off.
#
# A QValidator applies to a field only while the text ALREADY in that field is
# one the validator accepts. Measured on this Qt (6.12.0) with real synthesised
# key events, on a bare TextInput carrying the same DoubleValidator:
#
#   seeded "5"     + key "a"     ->  "5"        the letter is refused
#   seeded "5min"  + key "a"     ->  "5mina"    the letter lands
#   seeded "5min"  + keys "b.c"  ->  "5minab.c" everything lands
#
# The picker used to seed its field with the value PLUS its read-only unit, so
# on every number row that declares a unit - the shipped Timer row is
# `type: number, unit: "min"` - the field held a string its own validator
# rejected, and the filter that makes a number field numeric was silently off
# for the whole edit. The unit is painted beside the value now and the field
# holds the value alone, which deletes the caret-clamp and suffix-stripping
# that existed only to police a suffix the field no longer carries.
#
# The condition the Qt rule makes load-bearing is asserted behaviourally, on
# the real file evaluated from disk: what the field holds, what the unit does
# instead, and what the component's own writes put back into it. The seed
# itself lives one file up in InlineEditor, and that file is asserted as source
# - the feature layer is not constructible headlessly, so a runtime claim
# about it would be worth nothing.
#
# Not reachable here, and not claimed: the keystrokes themselves. `qs` posts no
# key events and the component cannot be loaded into qmltestrunner (its module
# reaches Menu -> MenuView -> a PanelWindow backend). The Qt rule is quoted
# above with the harness that measured it; the shell-side condition it depends
# on is what this suite holds.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "numberpicker" "features/menu/NumberPicker.qml: the numeric filter, and the unit as chrome"
require_qs

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/numberpicker.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing" "none" "$(qp_get np.error)"

# --- the picker under test is the shell's own file --------------------------

t_section "the picker under test is NumberPicker.qml itself"
t_eq "the source was read" "200" "$(qp_get np.status)"
t_eq "and it is not empty" "true" "$([ "$(qp_get np.len)" -gt 4000 ] && echo true || echo false)"
t_eq "exactly one module import was dropped" "1" "$(qp_get np.moduleDropped)"
t_eq "and the sibling MenuLib import was re-rooted" "1" "$(qp_get np.siblingRerooted)"
t_eq "it constructed" "1" "$(qp_get np.made)"
t_eq "and measures as the input height" "32" "$(qp_get np.height)"
t_note "NumberPicker.qml cannot be written out as a type here: qs.features.menu declares 'singleton Menu', and loading the module reaches MenuView -> OverlayWindow -> ScrimWindow -> a PanelWindow backend that offscreen does not have. So the probe drops the one module import - the picker references no type from it, MenuLib arrives on the next line - and re-roots 'import \"MenuLib.js\"' at the config root, which is where the rewritten text is evaluated from. The drop is counted, not pattern-matched silently, so a picker that starts using a module type makes this section red rather than testing something else."
t_note "The probe seeds the row the way the shipped Timer row declares it (default/vibranium/menus/utilities.jsonc: type number, min 1, max 180, step 1, value 5, unit \"min\") and then writes the value with the picker's own formatted(), which is what InlineEditor does on completion."

# --- the field holds the value; the unit is painted beside it --------------

t_section "a row with a unit leaves the unit out of the field"
t_eq "the value is 5" "5" "$(qp_get np.seed.value)"
t_eq "and the unit is min" "min" "$(qp_get np.seed.unit)"
t_eq "the field holds the value alone" '"5"' "$(qp_get np.seed.text)"
t_eq "so the unit is nowhere in the text" "false" "$(qp_get np.seed.hasUnitInText)"
t_eq "which is exactly what the component would write" "true" "$(qp_get np.seed.isValueAlone)"
t_eq "the field is the one carrying the validator" "true" "$(qp_get np.field.hasValidator)"
t_eq "and it carries the same value" '"5"' "$(qp_get np.field.text)"
t_eq "the unit is on screen as its own item" "min" "$(qp_get np.suffix.text)"
t_eq "and it is visible" "true" "$(qp_get np.suffix.visible)"

t_section "the unit sits behind the digits, and the pair reads as one run"
t_eq "the unit starts exactly where the digits end" "true" \
  "$(awk -v g="$(qp_get np.suffix.gap)" 'BEGIN { d = g < 0 ? -g : g; print (d < 0.5) ? "true" : "false" }')"
t_eq "with the same room either side of the pair" \
  "$(qp_get np.suffix.roomAtRight)" "$(qp_get np.suffix.roomAtLeft)"
t_eq "and the unit is not parked at the far right" "true" \
  "$(awk -v r="$(qp_get np.suffix.roomAtRight)" 'BEGIN { print (r > 0) ? "true" : "false" }')"

t_section "and it still reads that way for a longer unit"
t_eq "the unit is switched to pixels" "pixels" "$(qp_get np.long.unit)"
t_eq "the unit still starts where the digits end" "true" \
  "$(awk -v g="$(qp_get np.long.gap)" 'BEGIN { d = g < 0 ? -g : g; print (d < 0.5) ? "true" : "false" }')"
t_eq "with the same room either side of the pair" \
  "$(qp_get np.long.roomAtRight)" "$(qp_get np.long.roomAtLeft)"
t_eq "and the pair stays inside the field" "true" "$(qp_get np.long.insideField)"
t_eq "while the field still holds the bare value" '"6"' "$(qp_get np.long.textStillBare)"
t_eq "switching back to the shipped unit restores its own centring" \
  "73.72" "$(qp_get np.back.roomAtRight)"
t_note "The unit's width is the input's right padding and half the pair's centring, so a longer unit is where a placement tuned for one short unit would come apart. Read both ways: the arrangement is a function of the unit rather than a position someone picked."
t_note "The unit is placed, not anchored: its x is the number's left edge plus the number's width, and the number's left edge is where the input centres its own text inside the box its right padding leaves - that padding being the unit's share. So the two read as the one centred run they read as when the unit was part of the field's text, and the field never holds a string its validator refuses. Anchoring the unit to the right edge instead parks it at the far right of a wide field, which is not where a unit belongs."

# --- focus selects the value, all of it ------------------------------------

t_section "focus through the component's own entry point"
t_eq "the field takes focus" "field" "$(qp_get np.focus.owner)"
t_eq "and the selection is the value" '"5"' "$(qp_get np.focus.selected)"
t_eq "which is the whole text, unit excluded because it is not text" "true" "$(qp_get np.focus.allSelected)"

# --- the component's own writes keep it numeric ----------------------------

t_section "stepping and committing write the value, never the unit"
t_eq "a step lands a bare number" '"6"' "$(qp_get np.step.text)"
t_eq "and the value moved with it" "6" "$(qp_get np.step.value)"
t_eq "with no unit in the text" "false" "$(qp_get np.step.hasUnitInText)"
t_eq "commit emits once" "1" "$(qp_get np.commit.count)"
t_eq "carrying the number the row will store" "6" "$(qp_get np.commit.value)"
t_eq "an emptied field escapes rather than committing" "1" "$(qp_get np.empty.escaped)"
t_eq "and emits no value" "1" "$(qp_get np.empty.accepted)"
t_eq "unsupported data raises the row's error" "1" "$(qp_get np.garbage.invalid)"
t_eq "and the field is restored to the real value" '"6"' "$(qp_get np.garbage.restored)"
t_eq "with the message the row shows" \
  "That is not a number. Use digits with an optional decimal point, like 0.05 - or press Esc to cancel." \
  "$(qp_get np.garbage.error)"

t_section "the suffix policing is gone with the suffix"
t_eq "there is no editable-region arithmetic left" "undefined" "$(qp_get np.legacy.valueEnd)"
t_eq "and no cursor clamp to re-run on every change" "undefined" "$(qp_get np.legacy.clampCursor)"
t_note "valueEnd() and clampCursor() existed only to keep a caret out of a suffix that was part of the field's text - a read-only zone the user could still select across, delete into, and that a validator could never accept. With the unit painted instead, the caret cannot reach it because it is not there, so both are deleted rather than kept as a guard."

# --- the seed, as source ---------------------------------------------------

t_section "the seed is the value: InlineEditor.qml, read as source"
INLINE_EDITOR="$SHELL_DIR/features/menu/InlineEditor.qml"
PICKER_SRC="$(<"$SHELL_DIR/features/menu/NumberPicker.qml")"
EDITOR_SRC="$(<"$INLINE_EDITOR")"
ENTRY_SRC="$(<"$SHELL_DIR/features/menu/Entry.qml")"
t_file "the editor file is there to read" "$INLINE_EDITOR"
t_contains "the editor seeds its field from the value" \
  "text = root.numericValue.toFixed(root.decimals)" "$EDITOR_SRC"
t_not_contains "and not from a display string that carries the unit" \
  "text = root.numericDisplay" "$EDITOR_SRC"
t_not_contains "the editor no longer declares a numericDisplay at all" \
  "property string numericDisplay" "$EDITOR_SRC"
t_not_contains "nor does the row hand it one" "numericDisplay: {" "$ENTRY_SRC"
t_not_contains "the picker never concatenates the unit into the value it writes" \
  "toFixed(decimals) + unitSuffix" "$PICKER_SRC"
t_note "The seed lives in InlineEditor because the picker has no completion handler of its own, and InlineEditor is a feature-layer file that cannot be constructed headlessly (it needs the module that reaches the PanelWindow backend). Asserting the binding as source is the honest form of the claim: it is one line, it is the line the bug ran through, and a runtime assertion from a probe could not have produced a real editor to read it from."
t_note "Entry.qml keeps its own numericDisplay, and it should: that is the collapsed row's right-hand value and the argument its onChange command receives, both of which are meant to read \"5 min\". Only the field stopped carrying the unit."

# --- gaps, stated rather than passed over ----------------------------------

t_section "gaps, stated rather than passed over"
t_skip "a letter being refused while typing" \
  "no synthesised input in qs, and the real component cannot be loaded into qmltestrunner (its module reaches Menu -> MenuView -> OverlayWindow -> ScrimWindow -> a PanelWindow backend offscreen does not have). The Qt rule the fix rests on was measured directly on a bare TextInput with the same DoubleValidator through qmltestrunner - seeded \"5\" refuses \"a\", seeded \"5min\" accepts it - and the shell-side condition that rule makes load-bearing is asserted above"
t_skip "a number row with no unit" \
  "the probe stages the seeded Timer row, the one that declares a unit, because that is the shape that had no filter. An unsuffixed row was never affected: its seed was already a value, so its validator was always live. Nothing about it changed"
t_skip "a flow stage's own unit" \
  "a flow stage's unit reaches the picker through MenuLib.stageUnitSuffix and is now painted rather than typed, but a staged flow cannot be driven headlessly - it needs the menu service. The picker's half is asserted above, and the stage half is the same property feeding the same field"

t_summary
