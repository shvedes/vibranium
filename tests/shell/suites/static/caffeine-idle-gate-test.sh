#!/bin/bash
# Suite: caffeine-idle-gate - both Caffeine controls follow the Idle daemon.
#
# Settings owns the `shell.idle.enabled` fact. Both entry points bind to that
# one owner instead of re-reading it: the Utilities row through the menu's
# store-condition gate, the Player view's chrome button through IconButton's
# `enabled` fade. Neither surface polls IPC or keeps a copy of the verdict.
#
# SOURCE suite: the menu row is config and the Player view owns a Window, so
# neither surface can be constructed headlessly here.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "caffeine-idle-gate" "both Caffeine controls dim when the Idle daemon is off"

CATALOG="$SHELL_DIR/common/settings/catalog.jsonc"
MENU="$SHELL_DIR/features/menu/Menu.qml"
INDEX="$SHELL_DIR/features/menu/MenuIndex.js"
WINDOW="$SHELL_DIR/features/bar/modules/NowPlaying/LyricsFullscreenOverlay.qml"
t_file "the utilities catalog exists" "$CATALOG"
t_file "the Player view source exists" "$WINDOW"

t_section "the Utilities row binds the store condition"

CAFFEINE_ROW="$(grep -A16 '"id": "caffeine",' "$CATALOG")"
t_contains "the gate lives on the Caffeine row" '"disabledIf": [' "$CAFFEINE_ROW"
t_contains "it names the owning setting" '"var": "shell.idle.enabled",' "$CAFFEINE_ROW"
t_contains "and the disabling verdict" '"arg": false' "$CAFFEINE_ROW"
t_eq "no row reads the setting through IPC" "0" \
  "$(grep -c 'settings get shell.idle.enabled' "$CATALOG")"

t_section "the menu resolves store-disabled conditions"

MENU_SRC="$(<"$MENU")"
t_contains "isDisabled asks the same condition evaluator" \
  "!root.conditionsMet(item.disabledIf)" "$MENU_SRC"
t_contains "condition vars include the disabled gate" \
  "collect(item.disabledIf)" "$(<"$INDEX")"

t_section "the Player view button binds the same setting"

CAFFEINE_BUTTON="$(grep -A5 'name: "caffeine"' "$WINDOW")"
t_contains "the gate sits on the caffeine button" \
  "enabled: Settings.idleEnabled" "$CAFFEINE_BUTTON"
t_eq "no other button carries that gate" "1" \
  "$(grep -c 'enabled: Settings.idleEnabled' "$WINDOW")"

t_summary
