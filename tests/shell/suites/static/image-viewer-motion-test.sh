#!/bin/bash
# Suite: image-viewer-motion - every window-owned Behavior obeys MotionPolicy.
#
# Finding APP-1: ImageViewerWindow owns seven Behaviors - three button colour
# fades, the image opacity fade, the zoom-badge fade and both chrome slides.
# None asked MotionPolicy whether motion is on, so with hypr.animations.enabled
# off they kept animating, and their durations were copied literals (100/180/
# 260) rather than the shared Ui tokens. The fix gives the holder one animOn
# gate read from MotionPolicy.enabled, puts `enabled: root.animOn` on every
# owned Behavior and replaces the literals with Ui.fastMs/Ui.normalMs/
# Ui.slowMs. Easing curves are unchanged.
#
# This is a SOURCE suite, not a headless QML probe. The holder builds a native
# QtQuick Window whose screen is bound through WindowScreen.forScreen(
# Ui.primaryScreen); under QT_QPA_PLATFORM=offscreen Quickshell.screens is
# empty (tests/shell/README.md), so there is no screen to attach the window to
# and no probe can construct it. Every assertion below is therefore a static
# read of the real source; each names that limitation where it is made.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "image-viewer-motion" "every owned Behavior is gated by MotionPolicy and uses Ui duration tokens"

WINDOW="$SHELL_DIR/features/apps/imageViewer/ImageViewerWindow.qml"
t_file "the image viewer window source exists" "$WINDOW"
SRC="$(<"$WINDOW")"

t_section "the holder exposes one gate read from the global switch"
# Source-level (no headless window can be built): the gate must be derived from
# MotionPolicy, the single global switch, not a second local flag.
t_contains "the holder declares animOn from MotionPolicy" \
  "readonly property bool animOn: MotionPolicy.enabled" "$SRC"

t_section "every owned Behavior carries the policy gate"
# Source-level (no headless window can be built): count the owned Behaviors.
BEHAVIOR_COUNT="$(grep -c 'Behavior on ' "$WINDOW")"
# Source-level (no headless window can be built): require the gate on each line.
UNGATED="$(grep 'Behavior on ' "$WINDOW" | grep -v 'enabled: root.animOn' | wc -l)"
# Source-level (no headless window can be built): non-vacuity guard, so a
# missing Behavior cannot make the gate check pass by finding nothing.
t_eq "the window owns seven Behaviors" "7" "$BEHAVIOR_COUNT"
# Source-level (no headless window can be built): a new ungated Behavior must
# turn this red rather than slip through.
t_eq "no owned Behavior is ungated" "0" "$UNGATED"

t_section "no copied duration literal remains"
# Source-level (no headless window can be built): the three old literal
# durations must be gone, with a digit boundary so 100 cannot hide in 1000.
t_not_match "no 100 / 180 / 260 ms duration literal" \
  'duration: (100|180|260)([^0-9]|$)' "$SRC"

t_section "durations come from the shared Ui tokens"
# Source-level (no headless window can be built): three fast button-colour
# fades, three normal (image + two chrome) motions, one slow badge fade.
t_eq "three fast colour fades use Ui.fastMs" "3" \
  "$(grep -c 'duration: Ui.fastMs' "$WINDOW")"
t_eq "three normal motions use Ui.normalMs" "3" \
  "$(grep -c 'duration: Ui.normalMs' "$WINDOW")"
t_eq "the slow badge fade uses Ui.slowMs" "1" \
  "$(grep -c 'duration: Ui.slowMs' "$WINDOW")"

t_section "existing easing curves are preserved"
# Source-level (no headless window can be built): the two OutQuad fades and
# the two OutCubic chrome slides keep their curves - only the clock changed.
t_eq "two OutQuad fades keep their curve" "2" \
  "$(grep -c 'easing.type: Easing.OutQuad' "$WINDOW")"
t_eq "two OutCubic slides keep their curve" "2" \
  "$(grep -c 'easing.type: Easing.OutCubic' "$WINDOW")"

t_summary
