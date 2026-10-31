#!/bin/bash
# Suite: common/ui/InputField and common/ui/PasswordBox, driven through a real
# event loop.
#
# Two text-input components, one of which is the unlock surface for the whole
# session, so what is asserted here is a security surface rather than a look:
# which echo mode a field ends up in, when a reveal state is dropped, when the
# failure window opens and closes, and what each signal promises to carry.
#
# The probe (probes/textinput.qml) puts 24 InputFields and 13 PasswordBoxes in
# a real Window, steps through four event-loop turns with a repeating Timer and
# five named deadlines, and reports one key per observation. The pump is not
# ceremony:
#
#   * the mode chip and the reveal badge fade over Ui.fastMs, so their opacity
#     is mid-flight on the first turn and 1 on a later one
#   * the ghost placeholder cross-slidefades (one layer rises out as the
#     other rises in, the enter holding a short pause so total light dips
#     mid-swap), so the pair is mid-flight on the second turn and landed
#     by 600ms
#   * the failure border cross-fades over 150ms, so a colour read too early is
#     a blend of the two ends rather than either of them
#   * PasswordBox.failure is `failureTimer.running` and the window is 1400ms,
#     so "still failing" and "expired" are 1400ms apart and the driver samples
#     both ends of that range
#
# Colours are never asserted as literals. The theme palette lands milliseconds
# after boot, so every border assertion compares against `Theme.color()` read in
# the same turn as the colour it judges.
#
# Not reachable here, and not claimed: anything a key press would do. There is
# no compositor and no QTest, so InputField's accepted/escaped/backspaceEmpty
# and PasswordBox's submitted/edited/cancelled/capsToggled/navigate cannot be
# emitted. The routing properties they read are asserted instead, and every gap
# is a t_skip rather than a silent pass.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "textinput" "common/ui/InputField and PasswordBox: echo, reveal, failure window, signals"
require_qs

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/textinput.qml" 40; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing" "none" "$(qp_get textinput.error)"

t_section "the tokens both components are sized from"
t_eq "the input height token" "32" "$(qp_get probe.ui.inputHeight)"
t_eq "the body font token" "12" "$(qp_get probe.ui.fontM)"
t_eq "the spacing unit" "8" "$(qp_get probe.ui.s)"
t_eq "the shared mask glyph" "*" "$(qp_get probe.ui.passwordEcho)"
t_eq "the shared tween duration" "120" "$(qp_get probe.ui.fastMs)"
t_eq "a requested duration is honoured when motion is on" "100" "$(qp_get settle.motion.duration100)"

t_section "InputField defaults"
t_eq "the placeholder is the consumer's" "Type here" "$(qp_get if.defaultPlaceholder)"
t_eq "fontSize defaults to Ui.fontM" "12" "$(qp_get if.defaultFontSize)"
t_eq "and is literally that token" "true" "$(qp_get if.fontSize.isUiFontM)"
t_empty "text starts empty" "$(qp_get if.defaultText)"
t_eq "emacsKeys is on by default" "true" "$(qp_get if.defaultEmacsKeys)"
t_eq "sensitive is off by default" "false" "$(qp_get if.defaultSensitive)"
t_eq "revealable is off by default" "false" "$(qp_get if.defaultRevealable)"
t_eq "revealed is off by default" "false" "$(qp_get if.defaultRevealed)"
t_eq "the clear affordance is on by default" "true" "$(qp_get if.defaultClearable)"
t_eq "the ghost hint survives focus by default" "true" "$(qp_get if.defaultGhost)"
t_eq "echoMode defaults to Normal" "0" "$(qp_get if.defaultEchoMode)"
t_eq "which is TextInput.Normal" "true" "$(qp_get if.echoMode.isNormal)"
t_eq "no prefixes are configured" "0" "$(qp_get if.defaultPrefixesLength)"
t_empty "no prefix is active" "$(qp_get if.defaultActivePrefix)"
t_eq "the chip is off by default" "false" "$(qp_get if.defaultChipActive)"
t_empty "the chip has no text" "$(qp_get if.defaultChipText)"
t_empty "the chip has no icon" "$(qp_get if.defaultChipIcon)"

t_section "text is an alias onto the inner control, and survives the round trip"
t_eq "a written string reads back" "hello" "$(qp_get if.text.roundtrip)"
t_eq "and lands on the control itself" "true" "$(qp_get if.text.aliasIsInputText)"
t_empty "an empty string reads back empty" "$(qp_get if.text.empty.roundtrip)"
t_eq "which is the empty string, not null" "true" "$(qp_get if.text.empty.isEmpty)"
t_eq "a long string is not truncated" \
  "the quick brown fox jumps over the lazy dog, repeatedly, at length" \
  "$(qp_get if.text.long.roundtrip)"
t_eq "a long string keeps its length" "66" "$(qp_get if.text.long.length)"
t_eq "byte for byte" "true" "$(qp_get if.text.long.isExact)"
t_eq "a unicode string round-trips" "héllo-ẞ-🎉" "$(qp_get if.text.unicode.roundtrip)"
# 9 code points, 10 UTF-16 units: the astral emoji is a surrogate pair, so the
# length is not the character count.
t_eq "and keeps its surrogate pair" "10" "$(qp_get if.text.unicode.length)"
t_eq "so the length is not the grapheme count" "true" "$(qp_get if.text.unicode.isAstralPair)"
t_eq "on the control as well" "true" "$(qp_get if.text.unicode.alias)"
t_empty "and clears back to empty" "$(qp_get if.text.unicode.cleared)"

t_section "the placeholder rule: the string and the visibility are the shell's"
t_eq "empty and unfocused: the ghost is bound" "Type here" "$(qp_get ph.ghost.unfocused.text)"
t_eq "and the overlay shows it" "true" "$(qp_get ph.ghost.unfocused.visible)"
t_eq "so it paints" "true" "$(qp_get ph.ghost.unfocused.paints)"
t_eq "empty and focused: the flag keeps the ghost" "true" "$(qp_get ph.ghost.focused.flag)"
t_eq "the ghost is still bound" "Type here" "$(qp_get ph.ghost.focused.text)"
t_eq "and still painted" "true" "$(qp_get ph.ghost.focused.paints)"
t_eq "focus again does not take it away" "true" "$(qp_get ph.ghost.released.paints)"
# With text in the field the ghost is still *bound*; the overlay's own
# show rule is what hides it, so the binding alone would not have been
# a real assertion.
t_eq "non-empty text: the binding survives" "Type here" "$(qp_get ph.ghost.withText.textStillBound)"
t_eq "and the overlay hides itself" "false" "$(qp_get ph.ghost.withText.visible)"
t_eq "so nothing paints" "false" "$(qp_get ph.ghost.withText.paints)"
t_eq "ghostWhileFocused off: the flag is really off" "false" "$(qp_get ph.noGhost.flag)"
t_eq "unfocused it still paints" "true" "$(qp_get ph.noGhost.unfocused.paints)"
t_eq "focused the string is kept" "Type here" "$(qp_get ph.noGhost.focused.text)"
t_eq "and the overlay hides through opacity instead" "false" "$(qp_get ph.noGhost.focused.visible)"
t_eq "so the painted result is still nothing" "false" "$(qp_get ph.noGhost.focused.paints)"
t_note "with ghostWhileFocused off and the field focused, the overlay keeps its string and hides via opacity (Qt's old item stayed visible and emptied its string instead), so the shown flag alone is not the painted result; the probe reports both"
t_eq "and it comes back on blur" "true" "$(qp_get ph.noGhost.released.paints)"
t_eq "with text present it never paints" "false" "$(qp_get ph.noGhost.withText.paints)"

t_section "the ghost cross-slidefade: staging is synchronous, the travel is a tween"
t_eq "all three slide layers exist" "3" "$(qp_get ghost.swap.layers)"
t_eq "the idle layer takes the new string at once" "Filter..." "$(qp_get ghost.swap.staged)"
t_eq "and the overlay reads it at once" "Filter..." "$(qp_get ghost.swap.front)"
t_eq "with the front sitting on the second layer" "1" "$(qp_get ghost.swap.frontIndex)"
t_eq "by 600ms the outgoing layer rests staged below" "8" "$(qp_get settle.ghost.A.rise)"
t_eq "invisible" "0" "$(qp_get settle.ghost.A.opacity)"
t_eq "and the incoming one sits at rest" "0" "$(qp_get settle.ghost.B.rise)"
t_eq "opaque" "1" "$(qp_get settle.ghost.B.opacity)"
t_eq "and the idle layer never moved" "8" "$(qp_get settle.ghost.C.rise)"
t_eq "still invisible" "0" "$(qp_get settle.ghost.C.opacity)"
t_eq "the overlay reads the new string" "Filter..." "$(qp_get settle.ghost.text)"
t_eq "and still shows it (empty field, unfocused)" "true" "$(qp_get settle.ghost.shown)"

t_section "focused is the control's activeFocus, not a second flag"
t_eq "nothing is focused to begin with" "false" "$(qp_get focus.plain.before)"
t_eq "and the two agree when they are both false" "true" "$(qp_get focus.plain.isInputActiveFocus)"
t_eq "grabFocus takes it" "true" "$(qp_get focus.plain.afterGrab)"
t_eq "and the control's focus property follows" "true" "$(qp_get focus.plain.inputFocusProperty)"
t_eq "a second field takes it away from the first" "false" "$(qp_get focus.plain.afterTwinGrab)"
t_eq "and the second has it" "true" "$(qp_get focus.twin.afterGrab)"
t_eq "releasing gives it up" "false" "$(qp_get focus.plain.afterRelease)"
t_eq "without disturbing the other field" "true" "$(qp_get focus.twin.stillFocused)"
t_eq "and that field can be released too" "false" "$(qp_get focus.twin.afterRelease)"
t_eq "leaving nothing focused" "false" "$(qp_get focus.anyLeft)"

t_section "the echo mode truth table: revealed, then sensitive, then echoMode"
t_eq "TextInput.Normal" "0" "$(qp_get echo.normal)"
t_eq "TextInput.NoEcho" "1" "$(qp_get echo.noEcho)"
t_eq "TextInput.Password" "2" "$(qp_get echo.password)"
t_eq "a plain field echoes plain" "0" "$(qp_get echo.table.plain)"
t_eq "sensitive masks it" "2" "$(qp_get echo.table.sensitive)"
t_eq "as Password" "true" "$(qp_get echo.table.sensitiveIsPassword)"
t_eq "echoMode alone is honoured" "1" "$(qp_get echo.table.noEcho)"
t_eq "as NoEcho" "true" "$(qp_get echo.table.noEchoIsNoEcho)"
t_eq "sensitive beats a consumer's echoMode" "2" "$(qp_get echo.table.noEchoAndSensitive)"
t_eq "so the mask wins" "true" "$(qp_get echo.table.sensitiveBeatsEchoMode)"
t_eq "revealed beats sensitive" "0" "$(qp_get echo.table.revealedBeatsSensitive)"
t_eq "down to plain text" "true" "$(qp_get echo.table.revealedIsPlain)"
t_eq "dropping revealed re-masks" "2" "$(qp_get echo.table.remasked)"
t_eq "back to Password" "true" "$(qp_get echo.table.remaskedIsPassword)"

t_section "the eye affordance on a revealable field"
t_eq "the field is revealable" "true" "$(qp_get echo.eye.revealable)"
t_eq "and masked before any reveal" "true" "$(qp_get echo.eye.maskedBefore)"
t_eq "revealed unmask s it" "true" "$(qp_get echo.eye.afterReveal)"
t_eq "and re-masks when dropped" "true" "$(qp_get echo.eye.afterHide)"
t_eq "toggleReveal flips it on" "true" "$(qp_get echo.eye.afterToggle)"
t_eq "with the echo following" "true" "$(qp_get echo.eye.afterToggleEcho)"
t_eq "toggleReveal flips it back off" "false" "$(qp_get echo.eye.afterSecondToggle)"
t_eq "and the mask returns" "true" "$(qp_get echo.eye.afterSecondToggleEcho)"

t_section "FINDING: revealed does not consult revealable"
# InputField.qml:237-238 reads `root.revealed` first and never mentions
# `root.revealable`, so `revealable` gates the affordance (the eye item is
# `visible: root.revealable` at 406, and the Ctrl+H branch at 284) but not the
# reveal state itself. A consumer that sets `revealed` on a sensitive,
# non-revealable field gets plain text.
t_eq "the field under test is not revealable" "false" "$(qp_get echo.locked.revealable)"
t_eq "and is sensitive" "true" "$(qp_get echo.locked.sensitive)"
t_eq "so it starts masked" "true" "$(qp_get echo.locked.echoBefore)"
t_eq "revealed is accepted" "true" "$(qp_get echo.locked.revealedAccepted)"
t_eq "and the echo is no longer Password" "0" "$(qp_get echo.locked.echoAfter)"
# The line below is the defect, asserted as it behaves.
t_eq "a non-revealable sensitive field DOES unmask" "false" "$(qp_get echo.locked.stillMasked)"
t_eq "and drops the ligature freeze with it" "false" "$(qp_get echo.locked.ligaturesFrozen)"
t_eq "dropping revealed re-masks it" "true" "$(qp_get echo.locked.echoRestored)"
t_note "FINDING (medium, defence in depth): InputField.qml:237-238 - echoMode is root.revealed ? Normal : (root.sensitive ? Password : root.echoMode), with no root.revealable term. Setting revealed: true on a { sensitive: true, revealable: false } field unmasks it and unfreezes its ligatures. Not reachable from user input: the only paths to revealed are the eye MouseArea (eyeButton is visible: root.revealable, so it takes no clicks) and the Ctrl+H branch, which is itself gated on root.revealable. Reachable only from a consumer binding or setting the property, so this is a hardening gap in the component, not a live exposure. The gate that would close it is root.revealed && root.revealable."

t_section "the mask glyph and the sensitive input-method hint"
t_eq "the default mask character is the shared token" "*" "$(qp_get echo.char.default)"
t_eq "literally Ui.passwordEcho" "true" "$(qp_get echo.char.defaultIsToken)"
t_eq "a per-instance override reaches the control" "#" "$(qp_get echo.char.override)"
t_eq "and survives going sensitive" "#" "$(qp_get echo.char.overrideWhenSensitive)"
t_eq "so the override is the one that masks" "true" "$(qp_get echo.char.sensitiveUsesOverride)"
t_eq "Qt.ImhNone" "0" "$(qp_get imh.none)"
t_eq "Qt.ImhSensitiveData" "2" "$(qp_get imh.sensitive)"
t_eq "a plain field asks for no hints" "0" "$(qp_get imh.plain)"
t_eq "which is ImhNone" "true" "$(qp_get imh.plainIsNone)"
t_eq "a sensitive field asks for the sensitive hint" "2" "$(qp_get imh.masked)"
t_eq "which is ImhSensitiveData" "true" "$(qp_get imh.maskedIsSensitive)"
t_eq "and the two differ" "true" "$(qp_get imh.maskedDiffersFromPlain)"
t_eq "a revealed field keeps the hint" "true" "$(qp_get imh.revealedKeepsHint)"
t_eq "so does one with text in it" "true" "$(qp_get imh.textWithSensitiveHint)"
t_eq "a plain field still asks for none" "true" "$(qp_get imh.plainRevealedHasNoHint)"

t_section "a masked field freezes the ligatures its mask needs"
t_eq "a plain field has no feature overrides" "0" "$(qp_get liga.plain.keyCount)"
t_eq "a masked field turns five off" "5" "$(qp_get liga.masked.keyCount)"
t_eq "namely every contextual and ligature feature" "calt,clig,dlig,hlig,liga" "$(qp_get liga.masked.keys)"
t_eq "calt off" "0" "$(qp_get liga.masked.calt)"
t_eq "liga off" "0" "$(qp_get liga.masked.liga)"
t_eq "a revealed field has none again" "0" "$(qp_get liga.revealed.keyCount)"
t_eq "and re-masking brings them back" "5" "$(qp_get liga.remasked.keyCount)"
t_eq "the freeze is tied to the echo, not the flag (plain)" "tied" "$(qp_get liga.tiedToEcho.plain)"
t_eq "tied to the echo (masked)" "tied" "$(qp_get liga.tiedToEcho.masked)"
t_eq "tied to the echo (revealed)" "tied" "$(qp_get liga.tiedToEcho.revealed)"

t_section "a sensitive field masks the screen, not the owner's copy"
t_eq "the owner reads the secret back" "s3cret" "$(qp_get text.sensitive.readback)"
t_eq "while the echo is still masked" "true" "$(qp_get text.sensitive.stillMasked)"
t_eq "and a second field in the same window is untouched" "true" "$(qp_get text.sensitive.twinUnmasked)"

t_section "the mode chip"
t_eq "an inactive chip carries the chipText" "Web" "$(qp_get chip.inactive.text)"
t_eq "and is fully transparent" "0" "$(qp_get chip.inactive.opacity)"
t_eq "so it does not paint" "false" "$(qp_get chip.inactive.visible)"
t_eq "effectiveChipActive follows chipActive" "false" "$(qp_get chip.inactive.effectiveChipActive)"
t_eq "an inactive chip costs no inset" "8" "$(qp_get chip.inactive.leadInset)"
t_eq "just the base padding" "true" "$(qp_get chip.inactive.leadInsetIsBasePadding)"
t_eq "switching it on raises effectiveChipActive" "true" "$(qp_get chip.active.effectiveChipActive)"
t_eq "and the text yields the chip its width" "true" "$(qp_get chip.active.leadInsetGrew)"
t_eq "which is exactly the chip plus two gaps" "true" "$(qp_get chip.active.leadInsetIsChipPlusGaps)"
t_eq "switching it off gives the inset back" "false" "$(qp_get chip.inactiveAgain.effectiveChipActive)"
t_eq "a chip icon reaches the chip" "globe" "$(qp_get chip.icon.name)"
t_eq "and the chip keeps its text beside it" "Web" "$(qp_get chip.icon.text)"
t_eq "effectiveChipIcon takes the explicit one" "globe" "$(qp_get chip.icon.effectiveIcon)"
t_eq "and chipIcon is what was set" "globe" "$(qp_get chip.icon.chipIcon)"
t_eq "a launcher chip is boxed by default" "true" "$(qp_get chip.icon.boxed)"
t_empty "clearing chipIcon leaves no icon" "$(qp_get chip.icon.emptyWhenCleared)"

t_section "the input role stands in for a chip"
t_eq "inputRole search gives the search glyph" "search" "$(qp_get role.search.icon)"
t_eq "inputRole filter gives the filter glyph" "filter" "$(qp_get role.filter.icon)"
t_empty "the default role has no glyph" "$(qp_get role.none.icon)"
t_eq "and is not active" "false" "$(qp_get role.none.active)"
t_eq "searchIconAlways defaults on" "true" "$(qp_get role.search.searchIconAlways)"
t_eq "so a search field is active even unfocused" "true" "$(qp_get role.search.activeUnfocused)"
t_eq "filterIconAlways defaults off" "false" "$(qp_get role.filter.filterIconAlways)"
t_eq "so a filter field is not active unfocused" "false" "$(qp_get role.filter.activeUnfocused)"
t_eq "but is once focused" "true" "$(qp_get role.filter.activeFocused)"
t_eq "and stops when it loses focus" "false" "$(qp_get role.filter.activeReleased)"
t_eq "unless the consumer says always" "true" "$(qp_get role.filter.activeWhenAlways)"
t_eq "a bare role field owns the chip" "true" "$(qp_get role.ownsChip.search)"
t_eq "a role field with chipText does not" "false" "$(qp_get role.ownsChip.withText)"
t_eq "so the role-owned chip renders unboxed" "false" "$(qp_get role.ownsChip.unboxed)"
t_eq "while an explicit chip stays boxed" "true" "$(qp_get role.ownsChip.boxedWithText)"
t_eq "a role field falls back to the role glyph" "search" "$(qp_get role.effectiveIcon.search)"
t_eq "and a role field with no icon of its own inherits it" "search" "$(qp_get role.effectiveIcon.fallsBackToRole)"
t_eq "an explicit icon still wins" "star" "$(qp_get role.effectiveIcon.explicitWins)"
t_eq "the role glyph makes the chip active" "true" "$(qp_get role.effectiveChipActive.search)"
t_eq "chipActive alone does too" "true" "$(qp_get role.effectiveChipActive.explicit)"
t_eq "and clearing it takes the chip away" "false" "$(qp_get role.effectiveChipActive.explicitOff)"
t_eq "chipText is a plain property" "Mode" "$(qp_get chip.chipTextSet)"
t_eq "as is chipIcon" "search" "$(qp_get chip.chipIconSet)"
t_eq "and an explicit icon beats the role" "search" "$(qp_get chip.effectiveIconOverride)"

t_section "type() is the single write path: one call, one edited"
t_eq "a write emits once" "1" "$(qp_get type.edited.count)"
t_eq "carrying the new value" "xyz" "$(qp_get type.edited.payload)"
t_eq "and the text lands" "xyz" "$(qp_get type.text.landed)"
t_eq "an assign of the value already there still emits once" "2" "$(qp_get type.same.count)"
t_eq "with that value" "abc" "$(qp_get type.same.payload)"
t_eq "writing the empty string emits too" "3" "$(qp_get type.empty.count)"
t_empty "carrying the empty string" "$(qp_get type.empty.payload)"
t_empty "and the text is empty" "$(qp_get type.empty.text)"

t_section "FINDING: clear() is silent where the clear affordance is not"
t_eq "the clear affordance exists" "true" "$(qp_get clear.affordance.found)"
t_eq "and is visible with text" "true" "$(qp_get clear.affordance.visibleWithText)"
t_eq "clear() empties the text" "" "$(qp_get clear.text)"
t_eq "but emits no edited()" "0" "$(qp_get clear.edited.count)"
t_eq "and the affordance goes away with the text" "false" "$(qp_get clear.affordance.visibleAfterClear)"
t_note "FINDING (low, consumer-visible): InputField.qml:117-119 - clear() assigns input.text = \"\" and nothing else, while the clear affordance's handler at 370-374 assigns the same string and then emits root.edited(\"\") and takes focus. A consumer that mirrors the field through edited() - which is the documented way to consume this component ('Panels simply listen to edited()', 158) - goes stale on every clear() and never learns that the field emptied. A fix that makes clear() emit edited(\"\") turns this assertion red."
t_note "The other half of that pair, the affordance's own click, is not reachable here: MouseArea's clicked signal cannot be emitted from QML (calling it throws 'Insufficient arguments' and a null argument does not reach onClicked), so the affordance's edited(\"\") is pinned from the source, not measured."

t_section "prefixes: a match flips into chip mode, a miss is a query"
t_eq "two prefixes are configured" "2" "$(qp_get prefix.length)"
t_eq "the first" ">" "$(qp_get prefix.first)"
t_eq "the second" "#" "$(qp_get prefix.second)"
t_eq "a matching batch strips the prefix" " hello" "$(qp_get prefix.match.text)"
t_eq "and flips the mode exactly once" "1" "$(qp_get prefix.match.signalCount)"
t_eq "carrying prefix and payload" ">| hello" "$(qp_get prefix.match.last)"
t_eq "but does not emit edited()" "0" "$(qp_get prefix.match.editedCount)"
t_note "prefixEntered carries the mode switch instead of edited() (InputField.qml:138-155 returns before the edited() call), so a consumer binding only edited() will not see the leading character. That is the documented design, pinned here because the two signals are easy to confuse."
t_eq "the second prefix behaves the same" "tag rest" "$(qp_get prefix.match2.text)"
t_eq "once each" "1" "$(qp_get prefix.match2.signalCount)"
t_eq "with its own prefix" "#|tag rest" "$(qp_get prefix.match2.last)"
t_eq "a non-matching batch is a query" "plain query" "$(qp_get prefix.nomatch.text)"
t_eq "and flips nothing" "0" "$(qp_get prefix.nomatch.signalCount)"
t_eq "but is an ordinary edit" "1" "$(qp_get prefix.nomatch.editedCount)"
t_eq "an emptied list is inert" "0" "$(qp_get prefix.emptied.length)"
t_eq "so the character is literal text" ">x" "$(qp_get prefix.emptied.text)"
t_eq "and flips nothing" "0" "$(qp_get prefix.emptied.signalCount)"
t_eq "a list set after construction counts" "late" "$(qp_get prefix.setAfterConstruction.text)"
t_eq "and still flips" "1" "$(qp_get prefix.setAfterConstruction.signalCount)"
t_eq "with the new prefix" "@|late" "$(qp_get prefix.setAfterConstruction.last)"
t_eq "in mode the prefix is literal text" ">x" "$(qp_get prefix.inMode.text)"
t_eq "because chipActive is on" "true" "$(qp_get prefix.inMode.chipActive)"
t_eq "activePrefix round-trips" ">" "$(qp_get prefix.activePrefix.roundtrip)"
t_eq "and does not touch the text by itself" "late" "$(qp_get prefix.activePrefix.textUntouched)"
t_note "activePrefix is only read by the in-mode echo guard in Keys.onPressed (InputField.qml:310-314), so with no key event it is an inert property here: type() does not consult it, and the probe pins that it round-trips and leaves the text alone."

t_section "the readline handlers behind emacsKeys"
t_eq "emacsKeys is on by default" "true" "$(qp_get emacs.flag.default)"
t_eq "a consumer can turn it off" "false" "$(qp_get emacs.flag.whenOff)"
t_eq "and back on" "true" "$(qp_get emacs.flag.whenBackOn)"
t_eq "eraseWord is a function" "function" "$(qp_get emacs.handler.eraseWord)"
t_eq "wordForward is a function" "function" "$(qp_get emacs.handler.wordForward)"
t_eq "wordBackward is a function" "function" "$(qp_get emacs.handler.wordBackward)"
t_eq "eraseWord removes the word" "true" "$(qp_get emacs.eraseWord.ret1)"
t_eq "leaving the earlier words" "alpha beta " "$(qp_get emacs.eraseWord.text1)"
t_eq "and putting the cursor at the boundary" "11" "$(qp_get emacs.eraseWord.cursor1)"
t_eq "emitting edited once for it" "1" "$(qp_get emacs.eraseWord.edited1)"
t_eq "the second erase works too" "true" "$(qp_get emacs.eraseWord.ret2)"
t_eq "leaving the first word" "alpha " "$(qp_get emacs.eraseWord.text2)"
t_eq "with the cursor at its start" "6" "$(qp_get emacs.eraseWord.cursor2)"
t_eq "the third empties the field" "true" "$(qp_get emacs.eraseWord.ret3)"
t_empty "down to nothing" "$(qp_get emacs.eraseWord.text3)"
t_eq "with the cursor at 0" "0" "$(qp_get emacs.eraseWord.cursor3)"
t_eq "three edits for three erases" "3" "$(qp_get emacs.eraseWord.edited3)"
t_eq "a fourth erase reports no work" "false" "$(qp_get emacs.eraseWord.ret4)"
t_empty "and leaves the text alone" "$(qp_get emacs.eraseWord.text4)"
t_eq "emitting nothing" "3" "$(qp_get emacs.eraseWord.noopEmitsNothing)"
t_eq "wordForward from 0 lands on the next boundary" "4" "$(qp_get emacs.wordForward.from0)"
t_eq "and again" "8" "$(qp_get emacs.wordForward.again)"
t_eq "wordBackward goes back" "4" "$(qp_get emacs.wordBackward)"
t_eq "and to the start" "0" "$(qp_get emacs.wordBackward.again)"
t_eq "word motion never touches the text" "one two three" "$(qp_get emacs.wordMoves.textUntouched)"
t_eq "a cursor just past a space erases through it" "true" "$(qp_get emacs.afterSpace.ret)"
t_eq "leaving the next word" "cd" "$(qp_get emacs.afterSpace.text)"
t_eq "with the cursor at the boundary" "0" "$(qp_get emacs.afterSpace.cursor)"
t_eq "a multi-byte word erases as one unit" "true" "$(qp_get emacs.unicode.ret)"
t_eq "leaving the accented word before it" "café " "$(qp_get emacs.unicode.text)"
t_eq "and then the rest" "true" "$(qp_get emacs.unicode.ret2)"
t_empty "of the line" "$(qp_get emacs.unicode.text2)"
t_skip "emacsKeys gates the keystrokes" "Keys.onPressed cannot be reached headlessly: no compositor and no QTest, so Ctrl-W/Alt-F/Alt-B are unverified. The flag and the three handlers it routes to are asserted above."
t_skip "SelectAll on Ctrl-A" "the Keys.onPressed SelectAll branch (InputField.qml:273-277) needs a key event"
t_skip "the prefix key handler" "the Keys.onPressed prefix branch (299-308) needs a key event; the same logic reached through type() is asserted above"
t_skip "the in-mode echo guard" "the activePrefix guard (310-314) needs a key event"

t_section "the right-hand chrome: clear slot, eye slot, counter"
t_eq "the base padding is Ui.s" "8" "$(qp_get slot.basePadding)"
t_eq "literally" "true" "$(qp_get slot.basePaddingIsUiS)"
t_eq "an empty non-revealable field reserves no eye slot" "0" "$(qp_get slot.empty.eyeSlot)"
t_eq "and no clear slot" "0" "$(qp_get slot.empty.clearSlot)"
t_eq "so its right inset is the base padding" "8" "$(qp_get slot.empty.rightInset)"
t_eq "text brings in the clear slot" "24" "$(qp_get slot.text.clearSlot)"
t_eq "which is the 16px button plus the gap" "true" "$(qp_get slot.text.clearSlotIsButtonPlusGap)"
t_eq "and the right inset follows" "24" "$(qp_get slot.text.rightInset)"
# The eye slot is reserved with or without text, deliberately: the caret must
# not shift when typing starts (InputField.qml:194-198).
t_eq "a revealable field reserves the eye even with no text" "24" "$(qp_get slot.revealable.eyeSlotWithNoText)"
t_eq "which is the button plus the gap" "true" "$(qp_get slot.revealable.eyeSlotIsButtonPlusGap)"
t_eq "and the clear slot is still zero" "0" "$(qp_get slot.revealable.clearSlotStillEmpty)"
t_eq "so the right inset is just the eye" "24" "$(qp_get slot.revealable.rightInsetJustEye)"
t_eq "text adds the clear slot back" "24" "$(qp_get slot.revealable.clearSlotWithText)"
t_eq "and the two add up" "48" "$(qp_get slot.revealable.bothSlots)"
t_eq "the eye is still reserved inside that" "true" "$(qp_get slot.revealable.eyeStillReserved)"
t_eq "dropping revealable drops the eye slot" "24" "$(qp_get slot.plain.rightInset)"

t_section "the clear affordance's own visibility"
t_eq "visible with text" "true" "$(qp_get clear.item.visibleWithText)"
t_eq "hidden when clearable is off" "false" "$(qp_get clear.item.visibleNotClearable)"
t_eq "and its slot goes too" "0" "$(qp_get clear.slot.notClearable)"
t_eq "hidden with no text" "false" "$(qp_get clear.item.visibleEmpty)"
t_eq "hidden with clearable off even with text" "false" "$(qp_get clear.item.visibleClearableOff)"
t_eq "a field declared clearable: false never shows it" "false" "$(qp_get clear.item.visibleNeverClearable)"

t_section "the counter takes the right slot instead of the clear affordance"
t_eq "the counter row exists" "true" "$(qp_get counter.row.found)"
t_eq "and is visible" "true" "$(qp_get counter.row.visible)"
t_eq "rendering matched over total" "3/7" "$(qp_get counter.text)"
t_eq "unchanged by the query text" "3/7" "$(qp_get counter.textWithQuery)"
t_ne "and its right inset is not the clear slot" "24" "$(qp_get counter.rightInset)"
t_eq "the clear slot is suppressed" "0" "$(qp_get counter.clearSlotSuppressed)"
t_eq "so the clear affordance is not shown" "false" "$(qp_get counter.item.visible)"

t_section "the eye affordance's visibility and glyph"
t_eq "the eye item exists" "true" "$(qp_get eye.item.found)"
t_eq "hidden unless revealable" "false" "$(qp_get eye.item.visibleNotRevealable)"
t_eq "shown when revealable" "true" "$(qp_get eye.item.visibleRevealable)"
t_eq "with the open-eye glyph" "eye" "$(qp_get eye.item.glyphHidden)"
t_eq "swapped for the closed one while revealed" "eye-closed" "$(qp_get eye.item.glyphRevealed)"
t_eq "and back again" "eye" "$(qp_get eye.item.glyphHiddenAgain)"

t_section "layout: the box is the input token, fontSize is not the box"
t_eq "the default implicit width" "200" "$(qp_get layout.implicitWidth)"
t_eq "the implicit height is Ui.inputHeight" "32" "$(qp_get layout.implicitHeight)"
t_eq "and the item's height agrees" "32" "$(qp_get layout.height)"
t_eq "literally the token" "true" "$(qp_get layout.heightIsInputToken)"
t_eq "and the inner control fills it" "32" "$(qp_get layout.input.height)"
t_eq "box and control agree" "true" "$(qp_get layout.inputHeightMatchesBox)"
t_eq "the default fontSize" "12" "$(qp_get layout.fontSize)"
t_eq "reaching the control" "12" "$(qp_get layout.inputFontSize)"
t_eq "which is Ui.fontM" "true" "$(qp_get layout.fontSizeIsFontM)"
t_eq "and the control's pixel size too" "true" "$(qp_get layout.inputFontSizeIsFontM)"
t_eq "a larger fontSize reaches the control" "24" "$(qp_get layout.big.inputFontSize)"
# `implicitHeight: Ui.inputHeight` (177) is the only height term in the
# component, so the type can be scaled inside a fixed box but the box does not
# follow it.
t_eq "but the box height does not follow the type" "true" "$(qp_get layout.big.heightUnchanged)"
t_eq "it is still 32" "32" "$(qp_get layout.big.implicitHeight)"
t_eq "scaling the type back reaches the control" "12" "$(qp_get layout.big.backToFontM)"
t_eq "and the box is still the token" "true" "$(qp_get layout.big.heightStillToken)"
t_note "fontSize does not change InputField's height: implicitHeight is the bare Ui.inputHeight token (InputField.qml:177) and fontSize only feeds font.pixelSize (261). A 24px type in a 32px box is the intended embedding knob for chat rows, not a bug."
t_eq "the text starts at the lead inset" "8" "$(qp_get layout.text.x)"
t_eq "which is the declared inset" "true" "$(qp_get layout.text.xIsLeadInset)"
t_eq "and its right edge is inside the box" "192" "$(qp_get layout.text.rightEdge)"
t_eq "so the chrome never runs under the text" "true" "$(qp_get layout.text.fitsInBox)"

t_section "PasswordBox defaults"
t_eq "the box is 320 wide" "320" "$(qp_get pw.default.width)"
t_eq "and 44 tall" "44" "$(qp_get pw.default.height)"
t_eq "hidden is on by default" "true" "$(qp_get pw.default.hidden)"
t_eq "revealed is off by default" "false" "$(qp_get pw.default.revealed)"
t_eq "busy is off by default" "false" "$(qp_get pw.default.busy)"
t_eq "animated is on by default" "true" "$(qp_get pw.default.animated)"
t_eq "arrowNavigation is opt-in" "false" "$(qp_get pw.default.arrowNavigation)"
t_eq "the placeholder" "PASSWORD" "$(qp_get pw.default.placeholder)"
t_eq "the failure text" "Wrong password!" "$(qp_get pw.default.failureText)"
t_eq "the failure window" "1400" "$(qp_get pw.default.failureMs)"
t_eq "and nothing is failing" "false" "$(qp_get pw.default.failure)"
t_eq "nothing is focused yet" "false" "$(qp_get pw.default.focused)"
t_empty "and there is no text" "$(qp_get pw.default.text)"
t_eq "the echo is Password" "2" "$(qp_get pw.default.echoMode)"
t_eq "literally" "true" "$(qp_get pw.default.echoIsPassword)"
t_eq "the input method hint is the sensitive one" "2" "$(qp_get pw.default.imh)"
t_eq "literally" "true" "$(qp_get pw.default.imhIsSensitive)"
t_eq "one pixel of border" "1" "$(qp_get pw.default.borderWidth)"
t_eq "square corners" "0" "$(qp_get pw.default.radius)"
t_eq "the prompt shows the placeholder" "PASSWORD" "$(qp_get pw.default.prompt.text)"
t_eq "and is visible while empty" "true" "$(qp_get pw.default.prompt.visible)"
t_eq "at 12px" "12" "$(qp_get pw.default.prompt.px)"
t_eq "in bold" "true" "$(qp_get pw.default.prompt.bold)"
t_eq "with the prompt's 6px tracking" "6" "$(qp_get pw.default.prompt.spacing)"

t_section "no key event exists here, so no key-driven signal fired"
t_eq "edited was silent before anything happened" "0" "$(qp_get pw.signal.edited)"
t_eq "and so was submitted" "0" "$(qp_get pw.signal.submitted)"
t_eq "and cancelled" "0" "$(qp_get pw.signal.cancelled)"
t_eq "and capsToggled" "0" "$(qp_get pw.signal.capsToggled)"
t_eq "and navigate" "0" "$(qp_get pw.signal.navigate)"
t_eq "with no direction recorded" "99" "$(qp_get pw.signal.navigateDir)"
# After every box has been written to, revealed, failed and cleared: still
# nothing, which is the whole of the documented contract - a programmatic text
# sync is not a keystroke.
t_eq "and edited stayed silent through the whole run" "0" "$(qp_get pw.signalAfter.edited)"
t_eq "nothing was submitted either" "0" "$(qp_get pw.signalAfter.submitted)"
t_eq "nothing was cancelled" "0" "$(qp_get pw.signalAfter.cancelled)"
t_eq "no caps event either" "0" "$(qp_get pw.signalAfter.capsToggled)"
t_eq "and no navigation" "0" "$(qp_get pw.signalAfter.navigate)"
t_note "PasswordBox.edited is documented as 'Real keystrokes only - programmatic text syncs never fire this' (PasswordBox.qml:70), and the lockscreen relies on it: it assigns authBox.text to sync sibling surfaces (LockscreenSurfaceView.qml:112) with the comment 'Programmatic assignment never fires edited'."

t_section "the box has no caps state of its own"
t_eq "capsOn is not a property of PasswordBox" "undefined" "$(qp_get pw.capsState.notAPropertyOfTheBox)"
t_note "The box only reports the key press; the state lives in the consumer. Both call sites do onCapsToggled: Keyboard.toggleCaps() and render Keyboard.capsOn in a separate CapsChip (PolkitView.qml:190, LockscreenSurfaceView.qml:365), so a consumer that ignores the signal has no indicator at all."
t_skip "capsToggled fires for both directions" "needs a CapsLock key event; the handler (PasswordBox.qml:217-218) is unreachable headlessly"
t_skip "the submitted payload and its single emission" "onAccepted needs Enter"
t_skip "the edited payload on a real keystroke" "onTextEdited needs a keystroke; the negative contract is asserted above"
t_skip "cancelled on Escape" "Keys.onPressed needs a key event"
t_skip "navigate(int) directions and arrowNavigation's routing" "Keys.onPressed needs arrow keys; the default is asserted above"

t_section "reveal, and the mask it is layered over"
t_eq "hidden" "true" "$(qp_get pw.reveal.hidden)"
t_eq "revealed is on when the probe starts this box" "true" "$(qp_get pw.reveal.revealedBeforeToggle)"
t_eq "toggleReveal flips it off" "false" "$(qp_get pw.reveal.afterToggle)"
t_eq "and back on" "true" "$(qp_get pw.reveal.afterSecondToggle)"
t_eq "a third toggle is a plain flip" "false" "$(qp_get pw.reveal.afterThirdToggle)"

t_section "FINDING-adjacent, by design: toggleReveal() reveals a hidden box"
# PasswordBox.qml:168 is `(root.hidden && !root.revealed) ? Password : Normal`
# and toggleReveal() (54-56) flips `revealed` with no `hidden` term, so a box
# that is hidden - the default - unmasks on the first toggle. That is the
# documented Ctrl+H feature, not a defect, so it is asserted as the contract.
t_eq "the box under test is hidden: false" "false" "$(qp_get pw.plainEcho.hidden)"
t_eq "so it shows plain text" "0" "$(qp_get pw.plainEcho.echoMode)"
t_eq "which is Normal" "true" "$(qp_get pw.plainEcho.isPlain)"
t_eq "and revealed does not change that" "true" "$(qp_get pw.plainEcho.stillPlain)"
t_eq "so revealed: true unmasks even a hidden box" "true" "$(qp_get pw.plainEcho.revealedUnmasksHidden)"
t_eq "dropping revealed re-masks it" "true" "$(qp_get pw.plainEcho.remasked)"
t_eq "revealed: false on its own never unmasks" "true" "$(qp_get pw.plainEcho.revealedAloneDoesNotUnmaskHidden)"
t_note "Reported and triaged as deliberate, then pinned: toggleReveal() on a hidden box DOES reveal, and the comment at PasswordBox.qml:26-28 is what settles it. It describes the layering as 'echo stays masked until both say so', which is the hidden: false case, while the Ctrl+H feature the same property documents is that a masked box unmasks on demand. The reading that would make it a bug (a reveal is refused while hidden) would delete Ctrl+H. The distinction a caller needs is the one asserted above: hidden: false alone always shows plain text, and revealed: true only ever unmasks."

t_section "a failure over a box that still has text"
t_eq "the failure is running" "true" "$(qp_get pw.failedWithText.failure)"
t_eq "the text is still there" "s3cret" "$(qp_get pw.failedWithText.text)"
t_eq "and the prompt is hidden" "false" "$(qp_get pw.failedWithText.promptVisible)"
t_eq "although the failure text is bound to it" "Wrong password!" "$(qp_get pw.failedWithText.promptText)"
t_note "PasswordBox.qml:297 gates the whole prompt on passwordInput.text.length === 0, so a failure over a non-empty field shows the red border and the shake but no message. Deliberate: the field is full of the password that was rejected, so there is nowhere to put a message."

t_section "the display row: what is actually painted, not just the echo mode"
t_eq "a masked box paints one glyph per character" "6" "$(qp_get glyph.masked.count)"
t_eq "and every glyph is the mask" "******" "$(qp_get glyph.masked.text)"
t_eq "which is the echo token" "true" "$(qp_get glyph.masked.isAllEcho)"
t_eq "with no glyph count drift" "true" "$(qp_get glyph.masked.matchesTextLength)"
t_eq "and the echo mode behind it" "2" "$(qp_get glyph.masked.echoMode)"
t_eq "a revealed box paints the real characters" "s3cret" "$(qp_get glyph.revealed.text)"
t_eq "exactly the password" "true" "$(qp_get glyph.revealed.isPlaintext)"
t_eq "with echoMode Normal behind it" "0" "$(qp_get glyph.revealed.echoMode)"
t_eq "a hidden: false box paints the real characters" "s3cret" "$(qp_get glyph.plainEcho.text)"
t_eq "exactly the password" "true" "$(qp_get glyph.plainEcho.isPlaintext)"
t_eq "a masked box stays masked while the probe runs" "true" "$(qp_get glyph.wipedBeforeClear.isAllEcho)"
t_eq "and is not revealed" "false" "$(qp_get glyph.wipedBeforeClear.revealed)"
t_eq "the owner still reads the secret" "s3cret" "$(qp_get pw.ownerReadback)"
t_eq "exactly" "true" "$(qp_get pw.ownerReadback.isSecret)"

t_section "a failure re-masks a revealed password without clearing it"
t_eq "the reveal is dropped on failure" "false" "$(qp_get fail.revealed.stillRevealed)"
t_eq "the display row paints only the mask" "******" "$(qp_get fail.revealed.glyphText)"
t_eq "which is not plaintext" "false" "$(qp_get fail.revealed.isPlaintext)"
t_eq "while the failure is still running" "true" "$(qp_get fail.revealed.failureStillOn)"
t_eq "with echoMode Password" "2" "$(qp_get fail.revealed.echoMode)"
t_note "PasswordBox.fail() drops revealed but preserves the text for a retry; an authentication failure cannot leave a Ctrl+H-revealed secret painted on the lock screen."

t_section "FINDING-adjacent: clear() does not clear the failure"
# clear() (81-84) empties the text and drops `revealed`; the failure timer is
# separate and only stopped by clearFailure(), onTextEdited, or expiry.
t_eq "the text empties" "" "$(qp_get tick2.fail.withText.textCleared)"
t_eq "and the reveal state goes with it" "false" "$(qp_get tick2.fail.withText.revealedAfterClear)"
t_eq "but the failure flash survives" "true" "$(qp_get tick2.fail.withText.failureSurvivedClear)"
t_note "Deliberate per the source comment at PasswordBox.qml:38-39 ('fail() arms it, typing or clearFailure() ends the flash early'), and correct on its own terms: a consumer that clears the field to show a fresh prompt does not thereby claim the flash is over. It is a trap for the polkit case in reverse - clear() looks like a reset, and a consumer that reaches for it to silence the red border gets the border back. clearFailure() is the call that stops the flash."

t_section "clear() takes the text and the reveal state together"
t_eq "the text empties" "" "$(qp_get clear.text)"
t_eq "and the reveal state is dropped" "false" "$(qp_get clear.revealed)"
t_eq "a second clear keeps it dropped" "false" "$(qp_get clear.revealedAgain)"
t_eq "toggleReveal can still set it afterwards" "true" "$(qp_get clear.revealedAfterToggle)"
t_eq "and a further clear drops it again" "false" "$(qp_get clear.revealedAfterClear)"
t_eq "so a reveal state never survives a clear" "true" "$(qp_get rest.glyph.revealed.stillPlain)"
t_eq "and the display row empties with the text" "0" "$(qp_get tick2.glyph.wiped.count)"
t_eq "with nothing left in it" "" "$(qp_get tick2.glyph.wiped.text)"
t_eq "no glyph outliving its character" "true" "$(qp_get tick2.glyph.wiped.matchesTextLength)"
t_eq "which is the model following the text" "true" "$(qp_get tick2.glyph.modelFollowsText)"

t_section "the failure window, sampled at both ends of its 1400ms"
t_eq "fail() arms it" "true" "$(qp_get pw.window.failure)"
t_eq "with the documented interval" "1400" "$(qp_get pw.window.failureMs)"
t_eq "and the failure text replaces the placeholder" "Wrong password!" "$(qp_get pw.window.promptText)"
t_eq "which is now visible" "true" "$(qp_get pw.window.promptVisible)"
t_eq "failureMs is a live input" "300" "$(qp_get pw.short.failureMs)"
t_eq "and that box is failing too" "true" "$(qp_get pw.short.failure)"
t_eq "clearFailure() on a box that never failed is a no-op" "false" "$(qp_get pw.quiet.before)"
t_eq "still no failure afterwards" "false" "$(qp_get pw.quiet.afterNoOpClear)"
t_empty "and no text" "$(qp_get pw.quiet.text)"

t_section "the failure typography is a different voice from the placeholder"
t_eq "the failure message is 14px" "14" "$(qp_get tick1.fail.prompt.px)"
t_eq "against the placeholder's 12px" "12" "$(qp_get pw.default.prompt.px)"
t_eq "and not bold, where the placeholder is" "false" "$(qp_get tick1.fail.prompt.bold)"
t_eq "with the prompt's tracking dropped" "0" "$(qp_get tick1.fail.prompt.spacing)"
t_eq "and the message is the configured one" "Wrong password!" "$(qp_get tick1.fail.prompt.text)"
t_eq "its colour is an #AARRGGBB tint, not a literal theme value" "true" \
  "$(qp_get tick1.fail.prompt.colourIsArgb)"

t_section "the failure border, sampled while it cross-fades and after it lands"
t_eq "the failure window is open 40ms in" "true" "$(qp_get tick1.fail.window)"
t_eq "and so is the 300ms one" "true" "$(qp_get tick1.fail.short)"
t_eq "while an unfailed box is not flashing" "false" "$(qp_get tick1.fail.quiet)"
t_eq "so the two borders differ" "true" "$(qp_get tick1.fail.borderDiffersFromIdle)"
# The 600ms read is the first one the theme palette is guaranteed to have
# landed for, so the pre-failure colour is compared with Theme.color() in the
# same turn.
t_eq "both boxes start on the idle border" "true" "$(qp_get settle.border.preFail.equal)"
t_eq "which is the unfocused palette entry" "true" "$(qp_get settle.border.preFail.isBackground3)"
t_eq "the failure border is still cross-fading 120ms in" "false" "$(qp_get mid.late.quiet.landed)"
t_eq "and has moved off the idle colour" "true" "$(qp_get mid.late.quiet.movedOffPre)"
t_eq "with animated: false it has already landed" "true" "$(qp_get mid.late.still.landed)"
t_eq "and is the palette's red" "true" "$(qp_get land.late.quiet.onRed)"
t_eq "for the still box too" "true" "$(qp_get land.late.still.onRed)"
t_note "animated: false disables the border fade, not the border: the Behaviour is enabled: root.animated (PasswordBox.qml:106), so a minimal-setup consumer gets the same red border with no fade. Asserted as the difference between a mid-fade colour and the landed one on the two boxes, in the same turn, which is the only way to see a tween without a compositor."

t_section "the failure window expires on its own"
t_eq "at 320ms the 300ms window has closed" "false" "$(qp_get tick8.fail.shortExpired)"
t_eq "and the 1400ms one has not" "true" "$(qp_get tick8.fail.windowStillOn)"
t_eq "while a box that never failed has not either" "false" "$(qp_get tick8.fail.quietStillOff)"
t_eq "the short box's prompt is its placeholder again" "PASSWORD" "$(qp_get tick8.fail.shortPrompt)"
t_eq "the long one still shows the failure" "Wrong password!" "$(qp_get tick8.fail.windowPrompt)"
t_eq "past 1400ms the window has closed" "false" "$(qp_get half.window.expired)"
t_eq "and the placeholder is back" "PASSWORD" "$(qp_get half.window.prompt)"
t_eq "at the placeholder's 12px" "12" "$(qp_get half.window.promptPx)"
t_eq "in bold again" "true" "$(qp_get half.window.promptBold)"
t_eq "with its 6px tracking" "6" "$(qp_get half.window.promptSpacing)"
t_eq "100ms after it closed the border is still fading home" "true" "$(qp_get half.window.borderStillFading)"
t_eq "700ms later it has landed on the idle colour" "true" "$(qp_get rest.window.borderBackToIdle)"
t_eq "and so has the box that flashed for 300ms" "true" "$(qp_get rest.short.borderBackToIdle)"
t_eq "a box that never failed is still not failing" "false" "$(qp_get rest.quiet.neverFailed)"

t_section "a second fail() restarts the window rather than extending it"
t_eq "the box was failing before the second fail" "true" "$(qp_get settle.double.failureAfterSecondFail)"
t_eq "at 1500ms the restarted window is still open" "true" "$(qp_get half.double.stillOn)"
# Without the second fail() this box would have expired at 1400ms like
# pwWindow did. It expires at 2100ms, i.e. 600 + 1400, so Timer.restart()
# replaced the deadline rather than adding another interval to it.
t_eq "and it closes at 600 + 1400, not 1400 + 1400" "false" "$(qp_get rest.double.expired)"
t_eq "the single-fail box is closed by then too" "false" "$(qp_get rest.window.expired)"
t_eq "as is the 300ms box" "false" "$(qp_get rest.short.expired)"

t_section "the failure text takes the empty prompt's place"
t_eq "the prompt is hidden while there is text" "false" "$(qp_get pw.failedWithText.promptVisible)"
t_eq "once the text is gone the prompt comes back" "true" "$(qp_get tick8.fail.withText.promptVisible)"
t_eq "showing the failure message" "Wrong password!" "$(qp_get tick8.fail.withText.promptText)"
t_eq "at the failure's 14px" "14" "$(qp_get tick8.fail.withText.promptPx)"
t_eq "and the failure's weight" "false" "$(qp_get tick8.fail.withText.promptBold)"

t_section "two PasswordBoxes in one window do not share a failure"
t_eq "failing one box leaves the other quiet" "false" "$(qp_get tick1.fail.quiet)"
t_eq "through the run" "false" "$(qp_get tick8.fail.quietStillOff)"
t_eq "and it is still not failing at the end" "false" "$(qp_get rest.quiet.neverFailed)"

t_section "the box's focus follows the same contract as InputField's"
t_eq "nothing focused to begin with" "false" "$(qp_get pw.focus.before)"
t_eq "grabFocus takes it" "true" "$(qp_get pw.focus.afterGrab)"
t_eq "and it is the control's own activeFocus" "true" "$(qp_get pw.focus.isInputActiveFocus)"
t_eq "a second box takes it" "false" "$(qp_get pw.focus.afterTwinGrab)"
t_eq "and has it" "true" "$(qp_get pw.focus.twin)"
t_note "The inner control declares focus: true (PasswordBox.qml:166) but activeFocus stays false until the window itself is active, so the component does not steal focus at construction; the lockscreen hands it over explicitly with authBox.grabFocus() (LockscreenSurfaceView.qml:59)."

t_section "FINDING-adjacent: busy paints a border and nothing else"
t_eq "busy is off to begin with" "false" "$(qp_get pw.busy.before)"
t_eq "and can be set" "true" "$(qp_get pw.busy.set)"
t_eq "the box is still enabled" "true" "$(qp_get pw.busy.enabledUnchanged)"
t_eq "and so is the control inside it" "true" "$(qp_get pw.busy.inputEnabled)"
t_eq "which is not read-only" "false" "$(qp_get pw.busy.inputReadOnly)"
t_eq "and clearing it works" "false" "$(qp_get pw.busy.cleared)"
t_note "FINDING (low, naming trap): busy only feeds border.color (PasswordBox.qml:100-103). It does not disable the field, make it read-only, or suppress submitted(), so a consumer that sets busy on a PasswordBox to mean 'authentication in flight' still takes keystrokes and Enter. Both in-tree call sites also bind enabled to the same state (PolkitView.qml:210, LockscreenSurfaceView.qml:373), which is what actually gates it, so there is no live exposure here - but the property named after the security-relevant state is the one that does nothing. Asserted as the current behaviour so a fix turns these four lines red."

t_section "a long run leaves every field in the state it started in"
t_eq "the masked box still holds its secret" "s3cret" "$(qp_get rest.text)"
t_eq "and still masks it" "true" "$(qp_get rest.glyph.masked.stillMasked)"
t_eq "with the echo mode behind it" "true" "$(qp_get rest.masked.stillMasked)"
t_eq "the revealed box is still revealed, as asked for" "true" "$(qp_get rest.glyph.revealed.stillPlain)"
t_eq "the sensitive input-method hint never lapsed" "true" "$(qp_get rest.imh.stillSensitive)"
t_eq "and the prompt shows the placeholder" "PASSWORD" "$(qp_get rest.promptBack)"

t_section "the fades are real animations, sampled in flight"
t_eq "the event loop actually ran" "true" "$(qp_get anim.eventLoopRan)"
t_eq "the chip is already visible on the first turn" "true" "$(qp_get anim.chip.visible)"
t_eq "with its opacity above zero" "true" "$(qp_get anim.chip.opacity.gtZero)"
t_eq "and not above one" "true" "$(qp_get anim.chip.opacity.leOne)"
t_match "the reveal badge's opacity is a real fraction on the first turn" \
  '^0?\.[0-9]+$|^1$' "$(qp_get anim.badge.opacity)"
t_eq "with the eye glyph's own width" "45" "$(qp_get anim.badge.width)"
t_eq "by 600ms the chip has landed" "1" "$(qp_get settle.chip.opacity)"
t_eq "and stays visible" "true" "$(qp_get settle.chip.visible)"
t_eq "at the chip's own inset" "8" "$(qp_get settle.chip.x)"
t_eq "and the lead inset is the chip plus two gaps" "true" "$(qp_get settle.chip.leadInsetIsChipPlusGaps)"
t_eq "the badge has landed too" "1" "$(qp_get settle.badge.opacity)"

if [[ "$(qp_get probe.motion.enabled)" == "true" ]]; then
  t_eq "the chip fade is mid-flight on the first turn" "true" "$(qp_get anim.chip.opacity.inFlight)"
  t_eq "and so is the reveal badge" "true" "$(qp_get anim.badge.opacity.inFlight)"
  t_eq "the outgoing ghost is rising out mid-flight" "true" "$(qp_get anim.ghost.A.exiting)"
  t_eq "and the incoming one is rising in" "true" "$(qp_get anim.ghost.B.entering)"
  t_eq "with total light dipped below full (the visible fade)" "true" "$(qp_get anim.ghost.dip)"
else
  t_skip "the chip and badge fades are mid-flight on the first turn" \
    "MotionPolicy is disabled on this host, so the tween lands in the turn it is asked for"
  t_skip "the ghost slide is mid-flight on the first turn" \
    "MotionPolicy is disabled on this host, so the tween lands in the turn it is asked for"
fi

t_section "the glyph model logs a warning per character of a secret it drops"
# PasswordBox.qml:286 binds a delegate to `passwordInput.text[index]` while the
# ListModel row count is trimmed separately by syncModel(), so on the turn a
# secret is shortened the delegates that are on their way out re-evaluate
# against a string that no longer has their index.
glyph_warnings="$(qp_out | grep -c 'Unable to assign \[undefined\] to QString' || true)"
if ((glyph_warnings > 0)); then
  t_true "shortening a password logs an undefined-to-String warning per glyph" \
    test "$glyph_warnings" -gt 0
  t_note "FINDING (low, log hygiene plus a length leak): PasswordBox.qml:286 - every time the text is shortened (clear() at 82, the Ctrl+U handler at 223, or a shorter programmatic assignment) the departing glyph delegates re-evaluate passwordInput.text[index] against a string without that index, and Qt prints 'Unable to assign [undefined] to QString' once per character. This run printed $glyph_warnings of them. Nothing stale is painted - the delegates are destroyed in the same frame - but the lock screen and the polkit dialog both wipe passwords routinely (LockscreenSurfaceView.qml:112, PolkitView.qml:117), so the journal of a session records the LENGTH of every secret that was on screen. Binding the glyph to the model (append({ ch: passwordInput.text[i] }), then text: model.ch) or guarding the index removes it. The count is not asserted exactly: a stripped-down single-box probe of the same sequence prints none, so the trigger also depends on delegate-creation timing."
else
  t_skip "shortening a password logs an undefined-to-String warning per glyph" \
    "no warning was printed this run; see the note in the report for the mechanism"
fi

t_summary
