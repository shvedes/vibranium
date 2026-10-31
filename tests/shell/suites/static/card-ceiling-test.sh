#!/bin/bash
# Suite: card-ceiling - a card's height ceiling comes from its screen.
#
# Every overlay view that hosts a scrolling card used to hand its panel a
# ceiling derived from the window the card lives in:
#
#   maxHeight: win.height > 0 ? Math.round(win.height * 0.6) : 600
#
# and the window is sized FROM that card, so the number resolved in stages.
# win.height reads 0 before the first polish, so a hardcoded placeholder stood
# in for that frame, and the real value arrived a frame or two later as a
# DIFFERENT number from the placeholder - which is the only part that
# mattered. The card was built to the placeholder's row count, the ceiling then
# grew under it, one more row fitted where a row had just been cut, and the
# row that appeared was a visible pop on every summon. Five features carried
# the same two lines, so the same defect had to be found five times.
#
# This pins the fix as a SOURCE rule rather than a runtime assertion, because
# none of the five views can be constructed headlessly (no PanelWindow backend
# under QT_QPA_PLATFORM=offscreen, so all five are classified
# needs-environment in the construction suite) and the defect lives in a
# number that only misbehaves across the first two frames. What CAN be checked
# without a compositor is that no view reaches for its own window to size a
# card, and that every ceiling goes through the shared primitive.
#
# Both directions are asserted. The rule is not satisfied by deleting the
# ceilings, and it is not satisfied by declaring the primitive and leaving a
# view with no ceiling at all: the consumer count is pinned so the scan cannot
# quietly shrink its own coverage, and each consumer is checked for the two
# bindings it is supposed to read.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "card-ceiling" "a card's ceiling comes from the screen, not from the window it sizes"

CEILING="$SHELL_DIR/common/ui/ScreenCeiling.qml"
# t_contains takes a haystack STRING, so every assertion below is handed file
# contents rather than a path. $(<f) is the project's own idiom for that.
CEILING_SRC="$(<"$CEILING")"
VIEWS=(
  "launcher/AppLauncherView"
  "menu/MenuView"
  "clipboard/ClipboardView"
  "powerMenu/PowerMenuView"
  "wallpaperPicker/WallpaperPickerView"
)

t_section "the shared primitive exists and owns the rule"

t_file "the ceiling primitive is in common/ui" "$CEILING"
t_contains "it takes a screen" "property ShellScreen screen" "$CEILING_SRC"
t_contains "and a resting fraction" "property real fraction" "$CEILING_SRC"
t_contains "and a growth fraction" "property real growthFraction" "$CEILING_SRC"
t_contains "and answers the resting ceiling" "readonly property int maxHeight" "$CEILING_SRC"
t_contains "and the growth ceiling" "readonly property int hardMaxHeight" "$CEILING_SRC"
# The reason has to survive with the code, or the sixth consumer writes the
# loop again believing nobody knows why the window is the wrong input.
t_contains "and says why a window cannot answer it" "sized FROM that card" "$CEILING_SRC"

t_section "no view sizes a card from the window it lives in"

# The whole defect in one grep: a ceiling read off the window, or a
# placeholder standing in for it - the placeholder being the part that
# differed from the real value.
OFFENDERS=""
for v in "${VIEWS[@]}"; do
  f="$SHELL_DIR/features/$v.qml"
  if grep -qE 'maxHeight:[^\n]*win\.height|hardMaxHeight:[^\n]*win\.height' "$f"; then
    OFFENDERS+="$v "
  fi
done
t_empty "no view derives a card ceiling from its own window" "$OFFENDERS"

# Every view in the tree, not just the five known ones, so a sixth consumer
# cannot arrive with the loop already written.
ANY=""
for f in "$SHELL_DIR"/features/*/[A-Z]*View.qml; do
  if grep -qE 'maxHeight:[^\n]*win\.height|hardMaxHeight:[^\n]*win\.height' "$f"; then
    ANY+="$(basename "$f") "
  fi
done
t_empty "and no other view does either" "$ANY"

t_section "every consumer declares the primitive and reads it"

CONSUMERS=0
for v in "${VIEWS[@]}"; do
  f="$SHELL_DIR/features/$v.qml"
  name="$(basename "$v")"
  src="$(<"$f")"
  t_contains "$name declares the ceiling" "ScreenCeiling {" "$src"
  t_contains "$name binds the resting ceiling" "maxHeight: ceiling.maxHeight" "$src"
  t_contains "$name binds the growth ceiling" "hardMaxHeight: ceiling.hardMaxHeight" "$src"
  CONSUMERS=$((CONSUMERS + 1))
done
t_eq "and the scan cannot shrink: five views are pinned" "5" "$CONSUMERS"
t_note "a card's ceiling is a share of a SCREEN (ScreenCeiling); the window a card lives in is sized from that card, so reading it is a loop that resolves after the first paint"

t_summary
