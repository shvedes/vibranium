#!/bin/bash
# Suite: layer-policy - the layer-shell contract of every surface.
#
# The shell draws its chrome from PanelWindow surfaces, and until this suite
# nothing pinned what any of them declared. qmltestrunner cannot construct a
# PanelWindow (there is no backend under QT_QPA_PLATFORM=offscreen), so a
# missing namespace, a surface that reserves an exclusive zone it never asked
# for, or two features that quietly share a namespace could only be found by
# reading every declaring file. This suite reads them.
#
# The contract asserted below, surface by surface:
#
#   - every layer surface names itself, so a Hyprland layer rule can be
#     written for it and deleted with the feature;
#   - the layer is the one the feature was designed for;
#   - a fullscreen surface ignores the exclusive zone; the bar is the only
#     surface that reserves space, which is what keeps a modal overlay from
#     reflowing the desktop under it;
#   - namespaces are unique, because a layer rule matches a namespace and two
#     surfaces sharing one would be one rule silently governing both;
#   - the two app-like fullscreen views are toplevels rather than layer
#     surfaces, so the compositor can focus and list them as windows.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "layer-policy" "every layer surface keeps its layer, namespace and exclusion mode"

# The base scrim is a PanelWindow every modal overlay inherits; it declares no
# namespace or layer of its own because its consumers do (OverlayWindow sets
# both for the whole menu family). It is the one exclusion to "names itself".
BASE="common/ui/ScrimWindow.qml"

t_section "every surface names its layer"

NO_NS=""
NO_LAYER=""
while read -r f; do
  rel="${f#"$SHELL_DIR/"}"
  [[ $rel == "$BASE" ]] && continue
  if ! grep -q "WlrLayershell.namespace:" "$f"; then
    NO_NS+="$rel "
  fi
  if ! grep -q "WlrLayershell.layer:" "$f"; then
    NO_LAYER+="$rel "
  fi
done < <(grep -rl "PanelWindow {" "$SHELL_DIR" --include=*.qml | sort)

t_empty "every layer surface declares a namespace" "$NO_NS"
t_empty "and a layer" "$NO_LAYER"

# Surface -> layer. One entry per declaring file; WallpaperView carries the
# background surface and its own context menu in one file and is covered by
# the namespace section below.
LAYERS=(
  "common/ui/IslandHost.qml:WlrLayer.Top"
  "features/annotations/AnnotationEditor.qml:WlrLayer.Overlay"
  "features/annotations/AnnotationOverlay.qml:WlrLayer.Overlay"
  "features/annotations/CapturePicker.qml:WlrLayer.Overlay"
  "features/bar/BarView.qml:WlrLayer.Bottom"
  "features/bar/MoveWindow.qml:WlrLayer.Overlay"
  "features/bar/PrivacyOverlay.qml:WlrLayer.Overlay"
  "features/bar/ToolTipHost.qml:WlrLayer.Overlay"
  "features/bar/modules/ColorPicker/ColorPickerOverlay.qml:WlrLayer.Overlay"
  "features/bar/modules/Network/NetworkQrOverlay.qml:WlrLayer.Overlay"
  "features/bar/modules/Tray/TrayMenu.qml:WlrLayer.Overlay"
  "features/notifications/NotificationsView.qml:WlrLayer.Overlay"
  "features/osd/OSDView.qml:WlrLayer.Overlay"
  "features/polkit/PolkitView.qml:WlrLayer.Overlay"
  "features/wallpaper/WallpaperView.qml:WlrLayer.Background"
  "services/screenshots/Screenshots.qml:WlrLayer.Top"
)

for entry in "${LAYERS[@]}"; do
  rel="${entry%%:*}"
  layer="${entry##*:}"
  t_contains "$(basename "$rel") is on $layer" \
    "WlrLayershell.layer: $layer" "$(<"$SHELL_DIR/$rel")"
done

t_section "the bar is the only surface that reserves space"

BAR_SRC="$(<"$SHELL_DIR/features/bar/BarView.qml")"
t_contains "the bar reserves its own height" \
  "exclusiveZone: (Bar.enabled && !Bar.hideToggle) ? Bar.height : 0" "$BAR_SRC"
t_not_contains "and does not opt out of the zone" "exclusionMode:" "$BAR_SRC"

# Every other surface is fullscreen chrome: it draws over the desktop without
# reflowing it, so it ignores the zone and takes no space.
ZONE_OFFENDERS=""
while read -r f; do
  rel="${f#"$SHELL_DIR/"}"
  [[ $rel == "$BASE" || $rel == "features/bar/BarView.qml" ]] && continue
  if ! grep -q "exclusionMode: ExclusionMode.Ignore" "$f" \
    || ! grep -q "exclusiveZone: -1" "$f"; then
    ZONE_OFFENDERS+="$rel "
  fi
done < <(grep -rl "PanelWindow {" "$SHELL_DIR" --include=*.qml | sort)
t_empty "every other surface ignores the zone" "$ZONE_OFFENDERS"

t_section "namespaces are unique"

NAMESPACES=""
while read -r f; do
  rel="${f#"$SHELL_DIR/"}"
  [[ $rel == "$BASE" ]] && continue
  while read -r ns; do
    NAMESPACES+="$ns"$'\n'
  done < <(grep -o 'WlrLayershell.namespace: .*' "$f" | sed 's/.*namespace: *//')
done < <(grep -rl "PanelWindow {" "$SHELL_DIR" --include=*.qml | sort)

DUPLICATES="$(printf '%s' "$NAMESPACES" | sort | uniq -d)"
t_empty "no namespace is declared twice" "$DUPLICATES"

# The 18 declaration sites are pinned so the scans above cannot shrink their
# own coverage: a file that stops declaring a PanelWindow stops being checked.
DECLARED="$(grep -rho "PanelWindow {" "$SHELL_DIR" --include=*.qml | wc -l)"
t_eq "the scan covers eighteen declarations" "18" "$DECLARED"

t_section "the app-like fullscreen view is a toplevel"

LYRICS="features/bar/modules/NowPlaying/LyricsFullscreenOverlay.qml"
LYRICS_SRC="$(<"$SHELL_DIR/$LYRICS")"
t_not_contains "the lyrics view is not a layer surface" "PanelWindow {" "$LYRICS_SRC"
t_contains "it holds a real window" "property Window win: Window" "$LYRICS_SRC"
t_empty "it does not request a fullscreen state" "$(grep -o 'Window.FullScreen' "$SHELL_DIR/$LYRICS")"
t_contains "it is named in the compositor's window list" 'title: "Lyrics"' "$LYRICS_SRC"
t_contains "and maps only when opened" "visible: root.opened" "$LYRICS_SRC"
t_empty "and carries no layer-shell keyboard grab" "$(grep -o 'WlrKeyboardFocus' "$SHELL_DIR/$LYRICS")"

t_section "the layer rules cover the surfaces that need them"

RULES="$(<"$VIBRANIUM_DIR/default/hypr/window-rules.lua")"
t_contains "the pile is ordered under the modal overlays" "order = 1," "$RULES"
t_contains "the privacy dots sit above the lock" "above_lock = 1," "$RULES"
t_contains "the color pick is the topmost overlay" "order = -2" "$RULES"
t_contains "the picker leaves at the unmap" "vibranium:screenshot-picker" "$RULES"
t_contains "and so does the region selector" "vibranium:screenshot-region" "$RULES"

t_note "layer choice is a contract with default/hypr/window-rules.lua: a namespace change edits both or the surface loses its order, its lock behaviour or its animation"

t_summary
