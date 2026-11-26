#!/bin/bash
# Shared mirror helpers for the unit-pilot verification drivers.
# All mirrors are throwaway and never write into the source tree.

PILOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# pilot_mirror <dest> <source-shell-dir>
#
# Symlinks the source shell's top-level entries into <dest>, then replaces one
# nested leaf: common/ui/LayerSurface.qml. The real type is a PanelWindow and
# cannot compile offscreen; the inert Item keeps the same compile-time surface
# so the REAL feature singletons (and their REAL IpcRouter registrations) can
# be observed headlessly. Offscreen Ui.validScreens is empty, so no overlay is
# ever instanced and no user surface is touched.
pilot_mirror() {
  local dest="$1" source="$2" entry
  mkdir -p "$dest"
  for entry in "$source"/*; do
    [[ -e $entry ]] || continue
    ln -s "$entry" "$dest/$(basename "$entry")"
  done

  rm "$dest/common"
  mkdir "$dest/common"
  for entry in "$source"/common/*; do
    [[ -e $entry ]] || continue
    ln -s "$entry" "$dest/common/$(basename "$entry")"
  done

  rm "$dest/common/ui"
  mkdir "$dest/common/ui"
  for entry in "$source"/common/ui/*; do
    [[ -e $entry ]] || continue
    ln -s "$entry" "$dest/common/ui/$(basename "$entry")"
  done
  rm "$dest/common/ui/LayerSurface.qml"
  cp "$PILOT_DIR/LayerSurface.inert.qml" "$dest/common/ui/LayerSurface.qml"
}

# No import adaptation exists in this library. The repaired generator emits
# Qt.createComponent("<relative path>").createObject(root, { boot: root.boot })
# with no static hook imports, so the byte-exact shipped generated files load
# verbatim. Earlier test-only rewrites were removed, not merely disabled.

# pilot_run <mirror> <probe> <timeout> <out-file> [instance-label]
#
# Sets SHELL_DIR to the mirror, runs the probe through the shared qmlprobe
# protocol and copies the raw output to <out-file>. Returns qp_run's status.
pilot_run() {
  local mirror="$1" probe="$2" timeout="$3" out="$4" label="${5:-unit-pilot}"
  SHELL_DIR="$mirror"
  qp_setup >/dev/null
  if ! qp_run "$probe" "$timeout"; then
    qp_out >"$out"
    printf 'probe did not reach ##DONE## (instance=%s)\n' "$label" >&2
    return 1
  fi
  qp_out >"$out"
  return 0
}

# pilot_require_qs - require the qs binary, warn (do not block) on a patch-level
# platform drift.
#
# The benchmark suite pins Qt 6.12.0, but this host carries Qt 6.12.1 while
# Quickshell itself is the pinned 0.3.2. A strict platform gate would block
# every offscreen probe before it can observe anything, so the pilot drivers
# use this wrapper: it requires the binary, prints the drift as a NOTE, and
# lets the probe itself decide (failure to reach ##DONE## is still a failure).
# Disclosed in the verification report.
pilot_require_qs() {
  require_tools qs
  local reason
  if reason="$(platform_mismatch)"; then
    printf 'NOTE (pilot): relaxed platform pin - %s\n' "$reason"
  fi
}

# pilot_standin <dir> <name> <counter-key> <counter-import>
#
# Writes one instrumented `pragma Singleton` stub into <dir>, registers it in
# that directory's qmldir, and bumps the shared counter in Component.onCompleted
# so a probe can observe construction without touching (and constructing) it.
# The stub exposes the union of surfaces the generated rows read (tag, home,
# ready, locked, primaryScreen, run, enabled, facadeReady, _runtimeReady and
# teardownController), so one template serves every generated type.
pilot_standin() {
  local dir="$1" name="$2" key="$3" counter_import="$4"
  mkdir -p "$dir"
  printf 'singleton %s 1.0 %s.qml\n' "$name" "$name" >>"$dir/qmldir"
  cat >"$dir/$name.qml" <<EOF
pragma Singleton
import QtQml
import "$counter_import" as CounterLib

// Test-only instrumented stand-in. Never copied into production.
QtObject {
  id: root
  readonly property string tag: "$name"
  readonly property string home: "/pilot/home"
  readonly property bool ready: true
  readonly property bool locked: false
  readonly property var primaryScreen: null
  readonly property var run: null
  readonly property bool enabled: false
  readonly property bool facadeReady: true
  readonly property bool _runtimeReady: true
  property int teardownCalls: 0
  function teardownController() { root.teardownCalls++ }
  function status() { return { ok: true, unit: "$name" } }
  Component.onCompleted: CounterLib.bump("$key")
}
EOF
}

# pilot_build_inert_mirror <mirror> <source-shell>
#
# Builds a throwaway mirror in which every module imported by the five
# generated handler types is provided by an instrumented stand-in singleton,
# every authored hook file is copied verbatim to the relative path the
# generated file imports, and the five generated QML files are copied
# byte-for-byte from the source shell. Nothing under shell/ is written.
pilot_build_inert_mirror() {
  local mirror="$1" source="$2" rel entry depth ups counter_import module name key names
  mkdir -p "$mirror"
  cp "$PILOT_DIR/CounterLib.js" "$mirror/CounterLib.js"

  # module-path|type names. Every singleton named by a generated resolve /
  # ready / teardown (directly or through an authored hook) is covered.
  local specs=(
    "common|Log Paths Watch Settings HyprlandSettings MiscSettings SystemFont Theme Ui Icons Exec AppState"
    "features/wallpaper|Wallpaper"
    "features/lock|Lockscreen"
    "services|IdleDaemon Inhibitor Session Privacy Audio MediaArt Keyboard Timer Recording Update SystemUpdates PowerProfile Printers PowerPolicy BatteryAlert Connectivity Screenshots Tools"
    "features/apps|AppHost"
    "features/apps/audioMixer|AudioMixer"
    "features/apps/imageViewer|ImageViewer"
    "features/clipboard|Clipboard"
    "features/launcher|AppLauncher"
    "features/menu|Menu"
    "features/notifications|Notifications"
    "features/osd|OSD"
    "features/pickers/cursor|CursorPicker"
    "features/pickers/emoji|EmojiPicker"
    "features/pickers/font|FontPicker"
    "features/pickers/keybindings|Keybindings"
    "features/pickers/theme|ThemePicker ThemeRemover"
    "features/polkit|Polkit"
    "features/powerMenu|PowerMenu"
    "features/wallpaperPicker|WallpaperPicker"
    "features/pass|Pass"
  )
  for spec in "${specs[@]}"; do
    rel="${spec%%|*}"
    names="${spec#*|}"
    mkdir -p "$mirror/$rel"
    printf 'module qs.%s\n\n' "${rel//\//.}" >"$mirror/$rel/qmldir"
    depth=$(awk -F/ '{print NF}' <<<"$rel")
    ups=""
    for ((i = 0; i < depth; i++)); do ups="../$ups"; done
    counter_import="${ups}CounterLib.js"
    for name in $names; do
      key="${rel//\//.}.$name"
      pilot_standin "$mirror/$rel" "$name" "$key" "$counter_import"
    done
  done

  # Authored hook files, copied verbatim to the paths the generated files
  # import via relative file imports.
  local hooks=(
    "common/PathsUnitHooks.qml"
    "common/log/LogUnitHooks.qml"
    "common/settings/HyprlandSettingsUnitHooks.qml"
    "common/settings/MiscSettingsUnitHooks.qml"
    "common/settings/SettingsUnitHooks.qml"
    "common/theme/IconsUnitHooks.qml"
    "common/watch/WatchUnitHooks.qml"
    "services/screenshots/ScreenshotsUnitHooks.qml"
    "features/apps/AppHostUnitHooks.qml"
    "features/notifications/NotificationsUnitHooks.qml"
    "features/pass/PassUnitHooks.qml"
  )
  for rel in "${hooks[@]}"; do
    mkdir -p "$mirror/$(dirname "$rel")"
    cp "$source/$rel" "$mirror/$rel"
  done
  # boot-level hooks: generated/bar and generated/demand import them with
  # "../../BarUnitHooks.qml", i.e. from shell/boot/generated/<type> up to
  # shell/boot. The mirror keeps that exact depth.
  mkdir -p "$mirror/boot"
  cp "$source/boot/BarUnitHooks.qml" "$mirror/boot/BarUnitHooks.qml"
  cp "$source/boot/AnnotationsUnitHooks.qml" "$mirror/boot/AnnotationsUnitHooks.qml"

  # The five generated outputs under test, copied byte-for-byte at the same
  # shell/boot/generated/<type> depth as production so every relative hook
  # import resolves to the copied hook file.
  for entry in "$source"/boot/generated/*; do
    [[ -e $entry ]] || continue
    rel="boot/generated/$(basename "$entry")"
    mkdir -p "$mirror/$rel"
    cp "$entry"/*.qml "$mirror/$rel/"
  done
}
