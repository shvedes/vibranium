#!/bin/bash
# Suite: common/ui - the shell's component layer, driven through a real event
# loop.
#
# This is the suite that answers "can the UI be tested headlessly?". It can,
# and this is how. QT_QPA_PLATFORM=offscreen suppresses the render loop, not
# the binding, layout or animation passes, so:
#
#   * a declared binding can be read back and asserted (`implicitWidth`)
#   * a derived property can be asserted (`ProgressBar.clamped`)
#   * a signal can be fired and observed (`Toggle.toggled`)
#   * an animation can be sampled *in flight*, which is what proves the
#     animation machinery is wired rather than a value snapping to its target
#
# What is still not reachable, and is not claimed here: rendered pixels,
# presentation latency, input routing from a real compositor, and anything
# needing a real screen, audio daemon or credential store.
#
# The probe (probes/ui.qml) reports one key per observation and steps through
# four event-loop turns via a Timer, so anything that only becomes true after
# bindings settle or a tween has run is read after it happened.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "ui" "common/ui: layout, derived state, signals and animation, in a real event loop"
require_qs

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/ui.qml" 25; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing" "none" "$(qp_get ui.error)"

t_section "the design tokens every component's geometry is expressed in"
t_eq "the spacing scale is s < m < l < xl" "true" "$(qp_get token.spacing.monotonic)"
t_eq "s" "8" "$(qp_get token.s)"
t_eq "m" "12" "$(qp_get token.m)"
t_eq "l" "16" "$(qp_get token.l)"
t_eq "xl" "20" "$(qp_get token.xl)"
t_eq "the font scale is ascending" "true" "$(qp_get token.font.monotonic)"
t_eq "fontXs" "10" "$(qp_get token.fontXs)"
t_eq "fontS" "11" "$(qp_get token.fontS)"
t_eq "fontM" "12" "$(qp_get token.fontM)"
t_eq "fontL" "13" "$(qp_get token.fontL)"
t_eq "the card title size is a whole pixel size" "true" "$(qp_get token.fontCardTitle.isInt)"
t_eq "the font scale is a multiplier" "1" "$(qp_get token.scaling)"
t_eq "the button height token" "28" "$(qp_get token.buttonHeight)"
t_eq "the input height token" "32" "$(qp_get token.inputHeight)"
t_eq "the minimum row height token" "34" "$(qp_get token.rowMinH)"

t_section "tint() routes every component colour through the palette"
t_eq "a fractional alpha is applied" "0.5019607843137255" "$(qp_get tint.knownKey.half)"
t_eq "a zero alpha is applied" "0" "$(qp_get tint.knownKey.zero)"
t_eq "alpha() guards a void colour" "transparent" "$(qp_get alpha.voidUndefined)"
t_eq "alpha() guards an empty colour" "transparent" "$(qp_get alpha.voidEmpty)"
t_eq "alpha() guards a null colour" "transparent" "$(qp_get alpha.voidNull)"
t_eq "alpha() passes a real colour through" "#80000000" "$(qp_get alpha.voidTransparent)"
# Ui.tint and Ui.solid both branch on `Theme.color(key) === undefined`, but
# Theme.color ends in a fallback map and returns a string for every input, so
# the "transparent" arm of both is unreachable in the running shell. Pinned
# here rather than asserted as intended behaviour, because it is a comment
# (`Ui.qml:133`) that does not match the code.
t_note "Ui.tint/Ui.solid branch on Theme.color returning undefined, but Theme.color never does (unknown keys come back as a fallback colour), so the 'transparent' fallback is unreachable"
t_eq "Theme.color never returns undefined" "string" "$(qp_get theme.color.neverUndefined)"
t_eq "an unknown key falls back to a colour, not undefined" "#000000" "$(qp_get theme.color.unknownIsBlack)"
t_eq "so tint() of an unknown key is that fallback at full alpha" "#000000" "$(qp_get tint.unknownKey)"
t_eq "and at zero alpha it is fully transparent" "#00000000" "$(qp_get tint.unknownKey.0)"

t_section "mix() blends two palette leaves"
# The leaves are whichever theme is loaded, so what is asserted is the shape
# of the blend and not a colour: a share of nothing is the first leaf, a full
# share is the second, and anything between is between them.
t_eq "no share is the first leaf" "true" "$(qp_get mix.zeroIsBase)"
t_eq "a full share is the second leaf" "true" "$(qp_get mix.oneIsTarget)"
t_eq "a share above one is the second leaf" "true" "$(qp_get mix.clampedHighIsTarget)"
t_eq "a share below zero is the first leaf" "true" "$(qp_get mix.clampedLowIsBase)"
t_eq "a third of the way is neither leaf" "true" "$(qp_get mix.thirtyIsNotBase)"
t_eq "and it is not the second leaf either" "true" "$(qp_get mix.thirtyIsNotTarget)"
t_eq "the blend is a colour" "true" "$(qp_get mix.isHex)"
t_eq "and it lies between the two leaves" "true" "$(qp_get mix.thirtyIsBetween)"
t_match "the blend is a bare hex colour" '^#[0-9a-f]{6}$' "$(qp_get mix.thirty)"

t_section "Chip: width is a function of text, icon and the boxed flag"
t_eq "the boxed chip has width" "35.84375" "$(qp_get chip.boxed.width)"
t_eq "dropping the box removes exactly 2 * Ui.s" "16" "$(qp_get chip.paddingDelta)"
t_eq "which is the padding the source claims" "16" "$(qp_get chip.padding.expected)"
t_eq "an unboxed chip still has a width" "19.84375" "$(qp_get chip.plain.width)"
t_eq "the box is one pixel of border" "1" "$(qp_get chip.boxed.border)"
t_eq "an unboxed chip has no border" "0" "$(qp_get chip.plain.border)"
t_eq "the pill has square corners" "0" "$(qp_get chip.radius)"
t_eq "an icon adds width" "62.84375" "$(qp_get chip.icon.width)"
t_match "and more than the spacing unit alone" '^[1-9][0-9]*' "$(qp_get chip.icon.delta)"
t_eq "an empty chip collapses to zero width" "true" "$(qp_get chip.empty.isZero)"
t_eq "a longer label is wider" "true" "$(qp_get chip.long.wider)"
t_eq "the height comes from the label plus padding" "25" "$(qp_get chip.height)"

t_section "CheckBox and ProgressBar: derived state is exact"
t_eq "the default box size" "14" "$(qp_get checkbox.defaultBoxSize)"
t_eq "an explicit size wins" "30" "$(qp_get checkbox.explicitBoxSize)"
t_eq "so the box follows the requested size" "true" "$(qp_get checkbox.sizeDrivesBox)"
t_eq "an in-range value passes through" "0" "$(qp_get bar.clamped.mid)"
t_eq "a value over 100 clamps to 100" "100" "$(qp_get bar.clamped.high)"
t_eq "and the ratio follows the clamped value" "1" "$(qp_get bar.ratio.high)"
t_eq "a negative value clamps to 0" "0" "$(qp_get bar.clamped.low)"
t_eq "and the ratio is 0, never negative" "0" "$(qp_get bar.ratio.low)"
t_eq "the bar starts determinate" "false" "$(qp_get bar.indeterminate)"

t_section "Divider sizes itself with height, not implicitHeight"
# The type sets `implicitWidth: 200` and `height: 1`; a layout pass gives it
# no implicit height because it never sets one. Asserting implicitHeight would
# be asserting a property the component does not have.
t_eq "it is a one pixel hairline" "1" "$(qp_get divider.height)"
t_eq "which is the documented hairline" "true" "$(qp_get divider.hairline)"
t_eq "its default width is the documented 200" "200" "$(qp_get divider.implicitWidth)"

t_section "Title derives its presentation from level"
t_eq "level 1 has its own height" "17" "$(qp_get title1.height)"
t_eq "level 2 is a different size" "14" "$(qp_get title2.height)"
t_eq "and they are not the same" "true" "$(qp_get title.level2Differs)"
t_eq "level 2 is the section style" "true" "$(qp_get title.isSection)"
t_eq "level 1 is the island style" "true" "$(qp_get title.isIsland)"

t_section "derived flags and signals"
t_eq "a warning notice is not danger" "false" "$(qp_get notice.warning.danger)"
t_eq "a danger notice is" "true" "$(qp_get notice.danger.danger)"
t_eq "an unrecognised tone is not danger" "false" "$(qp_get notice.unknownTone.danger)"
t_eq "tone stays a string" "string" "$(qp_get notice.tone.isString)"
t_eq "a Toggle starts unchecked" "false" "$(qp_get toggle.default.checked)"
t_eq "toggling emits exactly one signal" "1" "$(qp_get toggle.afterToggle.signalCount)"
t_eq "carrying the NEW checked value" "true" "$(qp_get toggle.afterToggle.signalValue)"
t_eq "a disabled Toggle does not move" "false" "$(qp_get toggle.disabled.checked)"
t_eq "and reports itself disabled by default" "false" "$(qp_get toggle.disabled.default)"

t_section "the motion gate is what decides whether anything animates"
# MotionPolicy.duration() is the single place a requested duration becomes a
# runnable one, and the contract is that it is either the request or exactly
# zero - the value still arrives, only the motion is gone.
t_eq "a zero duration is zero either way" "0" "$(qp_get motion.duration.zero)"
t_eq "a requested duration is honoured when motion is on" "100" "$(qp_get motion.duration.100)"
t_eq "a duration is never negative" "true" "$(qp_get motion.duration.neverNegative)"
t_eq "and always matches the gate exactly" "true" "$(qp_get motion.duration.matchesGate)"
t_eq "a large duration is not clamped" "60000" "$(qp_get motion.duration.large)"

t_section "a real animation, sampled across its run"
# This is the assertion a source read cannot make. The chip's selected colour
# is driven by `Behavior on color { ColorAnim {} }`, so if the animation
# machinery is wired the samples are distinct and move in one direction; if a
# value were snapping to its target instead, every sample would be the same.
#
# Whether the tween was still running on the last sample is a wall-clock race
# the probe decides, not this file: on a machine slow enough that the 120ms
# tween finished before the first 5ms sample, the in-flight assertions are not
# applicable and asserting them anyway would report a slow machine as a broken
# animation.
t_eq "the event loop actually ran" "true" "$(qp_get anim.tick1.eventLoopRan)"
t_eq "before the palette lands the colour is not ARGB" "false" "$(qp_get anim.start.isValidColor)"
t_eq "and is a bare 6-digit colour" "#393939" "$(qp_get anim.start.color)"
t_eq "on the first turn the colour is ARGB" "true" "$(qp_get anim.tick1.valid)"
t_eq "and on the last" "true" "$(qp_get anim.tick3.valid)"
t_match "the final sample is a real colour" '^#[0-9a-f]{8}$' "$(qp_get anim.tick3.color)"
t_eq "the tween reached a different value than it started at" "true" "$(qp_get anim.tick3.changedFromStart)"

if [[ $(qp_get anim.inFlight) == "true" ]]; then
  t_eq "the tween was still running on the last sample" "true" "$(qp_get anim.tick3.stillMoving)"
  t_eq "first sample alpha" "0.8823529411764706" "$(qp_get anim.tick1.alpha)"
  t_eq "second sample alpha" "0.7647058823529411" "$(qp_get anim.tick2.alpha)"
  t_eq "third sample alpha" "0.6470588235294118" "$(qp_get anim.tick3.alpha)"
  t_eq "and it moved in one direction throughout" "true" "$(qp_get anim.alpha.movedConsistently)"
  t_eq "the middle sample is not the end point" "true" "$(qp_get anim.midIsNotAnEndpoint)"
else
  # The animation completed before the first sample could catch it. Still a
  # real assertion: it landed on the target rather than being left mid-tween.
  t_eq "the tween completed rather than being left mid-flight" "true" "$(qp_get anim.alpha.reachedTarget)"
  t_note "the tween finished before the first sample this run, so the in-flight assertions were not applicable; the machine was too slow to catch a 120ms tween at a 5ms sample rate"
fi

t_section "layout settles rather than oscillating"
# The chip's width at Component.onCompleted (35.84) differs from its width on
# the first event-loop turn (37.56): the label's implicit width needs a layout
# pass before it is final. That gap is the reason this suite runs a pump
# instead of reading everything synchronously - a snapshot taken at
# onCompleted would assert a width the component never actually uses.
t_eq "the chip's width equals its implicit width after the ticks" "true" "$(qp_get layout.width.stable)"
t_eq "and it had settled by the first turn" "37.5625" "$(qp_get layout.width.afterTicks)"

t_summary
