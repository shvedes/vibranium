#!/bin/bash
# Suite: ipc-b-migrations - the in-tree callers moved with their owner verbs.
# The gateway behavior itself is driven from the JS suites; this suite pins
# the caller side: one literal path to the CLI, no parsed human reply, the
# two fallback defaults and the audio keybind spellings.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "ipc-b-migrations" "callers and defaults follow the new app and audio verbs"

t_section "the image viewer wrapper"

VIEWER="$VIBRANIUM_DIR/bin/vb-app-imageviewer"
t_file "the wrapper is present" "$VIEWER"
t_status "the wrapper parses" 0 bash -n "$VIEWER"
t_contains "one literal path to the public CLI" \
  'vb-shell app call "$APP_ID" "$APP_VERB" "$absolute"' "$(cat "$VIEWER")"
t_not_contains "no JSON payload wrapping" 'jq -n' "$(cat "$VIEWER")"
t_not_contains "no parsed human reply" 'opened:*)' "$(cat "$VIEWER")"
t_contains "the exit status is the verdict" 'status=$?' "$(cat "$VIEWER")"

t_section "volume clicks and settings fallbacks"

VOLUME="$SHELL_DIR/features/bar/modules/Volume/Volume.qml"
CATALOG="$SHELL_DIR/common/settings/catalog.jsonc"
t_eq "both volume clicks use the toggle spelling" "2" \
  "$(grep -c 'vb-shell app toggle audioMixer' "$VOLUME" || true)"
t_eq "both settings fallbacks use the toggle spelling" "2" \
  "$(grep -c 'vb-shell app toggle audioMixer' "$CATALOG" || true)"
t_eq "no old fallback remains in either" "0" \
  "$(grep -c 'vb-shell app audioMixer' "$VOLUME" "$CATALOG" | awk -F: '{ s += $2 } END { print s + 0 }')"
t_contains "SettingsLib substitutes only the two full keys" \
  'shell.statusbar.volumeMicRightClick' \
  "$(cat "$SHELL_DIR/common/settings/SettingsLib.js")"

t_section "audio keybinds"

MAIN="$VIBRANIUM_DIR/default/hypr/binds.lua"
USER="$VIBRANIUM_DIR/config/hypr/hyprland.conf.d/binds.lua"
for old in voldown volup voltoggle mictoggle; do
  t_eq "the old $old spelling is gone from the shipped binds" "0" \
    "$(grep -c "audio $old" "$MAIN" "$USER" | awk -F: '{ s += $2 } END { print s + 0 }')"
done
t_contains "volume up uses the new action" '"audio.volume.up"' "$(cat "$MAIN")"
t_contains "volume down uses the new action" '"audio.volume.down"' "$(cat "$MAIN")"
t_contains "volume mute uses the new action" '"audio.volume.toggle"' "$(cat "$MAIN")"
t_contains "mic mute uses the new action" '"audio.microphone.toggle"' "$(cat "$MAIN")"
t_contains "the microphone rename is documented" 'microphone down/microphone up' "$(cat "$USER")"
t_contains "the set N -> volume set N rename is documented" 'volume set N' "$(cat "$MAIN")"

t_section "catalog rows the CLI depends on"

catalog_rows() {
  node - "$SHELL_DIR" <<'NODE'
const path = require('path')
const fs = require('fs')
// Read the catalog as data: a target missing here cannot be returned by the
// router even when the owner has registered its closure.
const dir = process.argv[2]
const src = fs.readFileSync(path.join(dir, 'common/text/IpcCatalog.js'), 'utf8')
const ids = ['app.list', 'app.open', 'app.close', 'app.toggle', 'app.call.list',
  'app.call.imageViewer.openPath', 'app.call.audioMixer.openTab',
  'audio.volume.up', 'audio.volume.down', 'audio.volume.set', 'audio.sink.list',
  'audio.stream.route', 'audio.stream.route-status', 'appLauncher.plugin.list', 'appLauncher.history.show',
  'appLauncher.plugin.command.calc.eval',
  'appLauncher.plugin.command.websearch.url']
const missing = ids.filter(id => !src.includes('"' + id + '"'))
if (missing.length !== 0) console.error('missing catalog rows: ' + missing.join(','))
process.exit(missing.length === 0 ? 0 : 1)
NODE
}
t_status "the B rows exist in the catalog" 0 catalog_rows

t_summary
