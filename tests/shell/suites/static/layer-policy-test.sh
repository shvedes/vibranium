#!/bin/bash
# Suite: layer-policy - the layer-shell contract of every surface.
#
# The shell draws its chrome from layer surfaces, and the contract each one
# keeps is now declared once, in common/ui/LayerSpec.js, and applied by
# common/ui/LayerSurface.qml. This suite asserts the three files that have to
# agree: the registry, the declarations that name a registry key, and the
# Hyprland layer rules that order or re-animate a namespace.
#
# The contract, surface by surface:
#
#   - every surface names itself, and every name is one registry row, so a
#     layer rule can be written for it and deleted with the feature;
#   - the layer is the one the feature was designed for;
#   - the bar is the only surface that reserves space, which is what keeps a
#     modal overlay from reflowing the desktop under it;
#   - a namespace is a surface class, shared by every window that keeps the
#     same contract, and each row names its clients, so what maps a class is
#     answerable from the table;
#   - a class that needs a Hyprland rule has one, in both directions: no rule
#     outlives its class, and no class loses the rule that carries its order,
#     its lock behavior or its animation;
#   - the modal scrims take input and the passive surfaces are click-through,
#     which is a property of the mask each one declares;
#   - an exclusive keyboard grab has a release branch, so it cannot outlive
#     the surface it was granted to;
#   - the two app-like fullscreen views are toplevels rather than layer
#     surfaces, so the compositor can focus and list them as windows.
#
# qmltestrunner cannot construct a PanelWindow (there is no backend under
# QT_QPA_PLATFORM=offscreen), so a missing namespace, a surface that reserves
# an exclusive zone it never asked for, or two classes that were meant to stay
# apart quietly sharing a name could only be found by reading every declaring
# file. This suite reads them.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "layer-policy" "every layer surface keeps its layer, namespace, focus and exclusion contract"

REGISTRY="$SHELL_DIR/common/ui/LayerSpec.js"
PRIMITIVE="$SHELL_DIR/common/ui/LayerSurface.qml"
RULES="$VIBRANIUM_DIR/default/hypr/window-rules.lua"

# The registry's keys, layer pairs, rule flags and mask policies. Parsed from
# the table rather than restated, so the assertions compare the file to itself
# and to the declarations instead of to a second copy of the table.
reg_namespaces() {
  grep -oE '^  "vibranium:[a-z-]+":' "$REGISTRY" | sed -E 's/^  "vibranium:([a-z-]+)":/\1/'
}
reg_layers() {
  grep -E '^  "vibranium:' "$REGISTRY" \
    | sed -E 's/^  "vibranium:([a-z-]+)": \{ layer: ([A-Z]+),.*/\1:\2/'
}
reg_rule_namespaces() {
  grep -E '^  "vibranium:.*rule: true' "$REGISTRY" \
    | sed -E 's/^  "vibranium:([a-z-]+)":.*/\1/'
}
reg_mask_count() {
  grep -cE "^  \"vibranium:.*mask: \"$1\"" "$REGISTRY" || true
}
reg_client_count() {
  grep -o 'clients: \[[^]]*\]' "$REGISTRY" \
    | sed -E 's/clients: \[//; s/\]//' | tr ',' '\n' | grep -c '"'
}
rule_namespaces() {
  grep -oE 'namespace = "\^vibranium:[a-z-]+[$]"' "$RULES" \
    | sed -E 's/.*vibranium:([a-z-]+).*/\1/'
}

t_section "the primitive is the only layer-shell declaration"

# One PanelWindow left in the tree: the primitive itself. Every surface is a
# LayerSurface that names a registry key, so namespace, layer and exclusion
# cannot drift file by file.
PANEL_COUNT="$(grep -rho "PanelWindow {" "$SHELL_DIR" --include=*.qml | wc -l)"
t_eq "one declaration still opens a PanelWindow" "1" "$PANEL_COUNT"
t_contains "and it is the primitive" "PanelWindow {" "$(<"$PRIMITIVE")"
LAYERSHELL_DECLARATIONS="$(grep -rho "WlrLayershell\.\(namespace\|layer\):" "$SHELL_DIR" --include=*.qml | wc -l)"
t_eq "two lines set the namespace and the layer, in the primitive" "2" "$LAYERSHELL_DECLARATIONS"
t_empty "no other file sets a namespace by hand" \
  "$(grep -rl "WlrLayershell\.namespace:" "$SHELL_DIR" --include=*.qml | grep -v "^$PRIMITIVE$")"

SURFACES="$(grep -rho "LayerSurface {" "$SHELL_DIR" --include=*.qml | wc -l)"
t_eq "the scan covers eighteen declarations" "18" "$SURFACES"

# ScrimWindow is the family's base and declares no key of its own; OverlayWindow
# names the key its seven consumers set. Both are structural, not surfaces.
NO_KEY=""
while read -r f; do
  rel="${f#"$SHELL_DIR/"}"
  [[ $rel == "common/ui/ScrimWindow.qml" ]] && continue
  if ! grep -q "surface:" "$f"; then
    NO_KEY+="$rel "
  fi
done < <(grep -rl "LayerSurface {" "$SHELL_DIR" --include=*.qml | sort)
t_empty "every surface names a registry key" "$NO_KEY"

t_section "the registry is the single table of surfaces"

REG_KEYS="$(reg_namespaces)"
t_unique "no namespace is declared twice in the registry" "$REG_KEYS"
t_eq "the registry keeps fifteen surface classes" "15" \
  "$(printf '%s\n' "$REG_KEYS" | grep -c .)"
t_eq "the classes account for every window the shell maps" "24" "$(reg_client_count)"
t_eq "and every class names at least one client" "15" \
  "$(grep -E '^  "vibranium:' "$REGISTRY" | grep -c 'clients: \[')"

# The declared side of the same set: literal keys, the menu family's bound
# namespaces, and the capture picker's constant. A surface that maps without a
# registry row is a surface with no declared layer, focus or mask policy.
DECLARED="$( {
  grep -rhoE 'surface: "vibranium:[a-z-]+"' "$SHELL_DIR" --include=*.qml | sed -E 's/.*vibranium:([a-z-]+)"/\1/'
  grep -rhoE 'wlrNamespace: "vibranium:[a-z-]+"' "$SHELL_DIR" --include=*.qml | sed -E 's/.*vibranium:([a-z-]+)"/\1/'
  grep -oE 'pickerLayerNamespace: "vibranium:[a-z-]+"' "$SHELL_DIR/common/capture/AnnotationActions.qml" | sed -E 's/.*vibranium:([a-z-]+)"/\1/'
} | LC_ALL=C sort -u)"
MISSING_FROM_REGISTRY="$(LC_ALL=C comm -13 <(printf '%s\n' "$REG_KEYS" | LC_ALL=C sort -u) <(printf '%s\n' "$DECLARED"))"
t_empty "every declared surface has a registry row" "$MISSING_FROM_REGISTRY"
UNUSED_ROWS="$(LC_ALL=C comm -23 <(printf '%s\n' "$REG_KEYS" | LC_ALL=C sort -u) <(printf '%s\n' "$DECLARED"))"
t_empty "and no row outlives its declaration" "$UNUSED_ROWS"

t_section "the table is a closed schema"

# The row shape is normative: the same fields, in the same order, each inside
# the domain the spec names. A row that adds a field is rejected by the JS
# suite as an unknown key, and here by the shape, so neither file can grow an
# extension the other does not know about.
ROW_SCHEMA='^  "vibranium:[a-z-]+": . layer: (BACKGROUND|BOTTOM|TOP|OVERLAY), focus: "(none|ondemand|exclusive)", exclusion: "(normal|ignore)", mask: "(none|empty|content|open)", mapped: "(always|open|primary)", order: -?[0-9]+, rule: (true|false), clients: \[("[a-z-]+"(, "[a-z-]+")*)\] .[,]?$'
t_count "every row declares the full schema, in field order" "15" \
  "$(grep -E '^  "vibranium:' "$REGISTRY" | grep -cE "$ROW_SCHEMA" || true)"
t_eq "and no row escapes the schema" "0" \
  "$(grep -E '^  "vibranium:' "$REGISTRY" | grep -vcE "$ROW_SCHEMA" || true)"
# Clause 4: an order with no rule is an intent the compositor never hears.
t_empty "no class carries an order without a rule" \
  "$(grep -E '^  "vibranium:' "$REGISTRY" | grep -v 'order: 0,' | grep -v 'rule: true' || true)"

# Clause 3: one client, one class. The counts above prove the total; this
# proves no name was reused to reach it.
t_unique "every client belongs to one class" \
  "$(grep -o 'clients: \[[^]]*\]' "$REGISTRY" | sed -E 's/clients: \[//; s/\]//' | tr ',' '\n' | tr -d ' "' | grep .)"

t_section "the layer of each surface is the one it was designed for"

# Pinned here rather than read from the table: the registry is the thing under
# test, so the expectation has to live outside it.
EXPECTED_LAYERS="bar:BOTTOM
bar-drag:OVERLAY
capture:TOP
capture-region:OVERLAY
capture-picker:OVERLAY
annotate:OVERLAY
color-pick:OVERLAY
hud:OVERLAY
island:OVERLAY
launcher:OVERLAY
modal:OVERLAY
notifications:OVERLAY
popup:OVERLAY
privacy:OVERLAY
wallpaper:BACKGROUND"
t_eq "every row's layer is the designed one" \
  "$(printf '%s\n' "$EXPECTED_LAYERS" | LC_ALL=C sort)" "$(reg_layers | LC_ALL=C sort)"

t_section "the bar is the only surface that reserves space"

t_eq "one row reserves a zone" "1" \
  "$(grep -cE '^  "vibranium:.*exclusion: "normal"' "$REGISTRY" || true)"
t_contains "and it is the bar" 'exclusion: "normal"' \
  "$(grep -E '^  "vibranium:bar"' "$REGISTRY")"
BAR_SRC="$(<"$SHELL_DIR/features/bar/BarView.qml")"
t_contains "the bar reserves its own height" \
  "exclusiveZone: (Bar.enabled && !Bar.hideToggle) ? Bar.height : 0" "$BAR_SRC"
t_not_contains "and does not opt out of the zone" "exclusionMode:" "$BAR_SRC"

# Every other surface is fullscreen chrome: it draws over the desktop without
# reflowing it. LayerSurface applies the ignoring mode, so the check is that no
# consumer re-enables a zone.
ZONE_OVERRIDES="$(grep -rln "exclusiveZone:" "$SHELL_DIR" --include=*.qml \
  | grep -v "common/ui/LayerSurface.qml" | grep -v "features/bar/BarView.qml" || true)"
t_empty "no other surface sets an exclusive zone" "$ZONE_OVERRIDES"

t_section "modal scrims take input and passive surfaces do not"

t_eq "three classes are click-through" "3" "$(reg_mask_count empty)"
t_eq "two surfaces follow their content" "2" "$(reg_mask_count content)"
for rel in \
  features/bar/PrivacyOverlay.qml \
  features/bar/ToolTipHost.qml \
  features/osd/OSDView.qml \
  services/screenshots/Screenshots.qml; do
  t_contains "$(basename "$rel") declares an empty region" \
    "mask: Region { width: 0; height: 0 }" "$(<"$SHELL_DIR/$rel")"
done
t_contains "the pile's region follows the pile" "mask: Region { item: pile }" \
  "$(<"$SHELL_DIR/features/notifications/NotificationsView.qml")"
t_contains "the move proxy's region is computed" "mask: Region {" \
  "$(<"$SHELL_DIR/features/bar/MoveWindow.qml")"
t_not_contains "a modal scrim is not masked" "mask:" \
  "$(<"$SHELL_DIR/common/ui/OverlayWindow.qml")"
LAUNCHER_VIEW="$(<"$SHELL_DIR/features/launcher/AppLauncherView.qml")"
t_contains "only the primary launcher stays mapped after the entrance" \
  "AppLauncher.visible || (win.primary && DesktopLayoutState.bootEntrancePlayed)" "$LAUNCHER_VIEW"
t_contains "closing the launcher installs its empty input region" \
  "mask: AppLauncher.visible ? null : closedInput" "$LAUNCHER_VIEW"
t_contains "launcher open state drives the scrim and keyboard grab" \
  "overlayOpen: AppLauncher.visible" "$LAUNCHER_VIEW"

t_section "an exclusive grab has a release branch"

# A surface that asks for Exclusive and never gives it back holds the keyboard
# past its own close. Every grab in the tree is a ternary, so the release is
# part of the same statement rather than a second assignment to remember.
UNGATED=""
while read -r f; do
  statement="$(grep -A2 "WlrLayershell.keyboardFocus:" "$f" | tr '\n' ' ')"
  [[ $statement == *"?"* ]] || UNGATED+="${f#"$SHELL_DIR/"} "
done < <(grep -rl "WlrKeyboardFocus.Exclusive" "$SHELL_DIR" --include=*.qml | sort)
t_empty "every exclusive grab is gated on the surface's own state" "$UNGATED"

t_section "a visit that can stand down does"

# The QR card was the one fullscreen visit outside the claim set, so it could sit
# on top of a menu with a credential on screen. It claims on open and releases
# on close now, which is what makes it dismissable in both directions.
QR_OVERLAY="$SHELL_DIR/features/bar/modules/Network/NetworkQrOverlay.qml"
t_contains "the QR overlay claims the screen when it opens" \
  'SurfaceClaim.claim("networkQr", root.close, root)' "$(<"$QR_OVERLAY")"
t_contains "and releases it when it closes" \
  "SurfaceClaim.release(root._claimToken)" "$(<"$QR_OVERLAY")"
t_contains "and drops the claim if it is destroyed while open" \
  "SurfaceClaim.releaseOwner(root)" "$(<"$QR_OVERLAY")"

# The two context menus are visits too. A popup left mapped under a visit's dim
# is invisible but still there, and it reappears when the visit closes.
TRAY_MENU="$SHELL_DIR/features/bar/modules/Tray/TrayMenu.qml"
t_contains "the tray menu claims the screen while open" \
  'SurfaceClaim.claim("trayMenu", root.close, root)' "$(<"$TRAY_MENU")"
t_contains "and gives it back when it closes" \
  "SurfaceClaim.release(root._claimToken)" "$(<"$TRAY_MENU")"
WALLPAPER_VIEW="$SHELL_DIR/features/wallpaper/WallpaperView.qml"
t_contains "the desktop menu claims the screen while open" \
  'SurfaceClaim.claim("wallpaperMenu", win.closeMenu, win)' "$(<"$WALLPAPER_VIEW")"
t_contains "and gives it back when it closes" \
  "SurfaceClaim.release(win._menuClaim)" "$(<"$WALLPAPER_VIEW")"

t_section "the island is an overlay that unmaps on close"

ISLAND="$(<"$SHELL_DIR/common/ui/IslandHost.qml")"
t_contains "the island is on the overlay layer" 'island:OVERLAY' "$(reg_layers)"
t_contains "it maps only while open" "visible: root.open" "$ISLAND"
t_contains "the close is the compositor's fade, so it takes OnDemand" \
  "WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None" "$ISLAND"
t_not_contains "and needs no exclusive focus prime" "focusPrimed" "$ISLAND"
t_eq "no exclusive grab of its own" "0" \
  "$(grep -cE 'WlrLayershell\.keyboardFocus:.*Exclusive' "$SHELL_DIR/common/ui/IslandHost.qml" || true)"

t_section "a visit belongs to the workspace it was summoned on"

# A layer surface is bound to the output, not the workspace: the compositor
# keeps it mapped across a switch, so a menu opened on one desktop used to stay
# on the next one, Escape scope and all. The registry dismisses its holder; the
# capture flow opts out because an annotation is a document.
CLAIM_IMPL="$SHELL_DIR/common/bus/SurfaceClaim.qml"
t_contains "the registry dismisses the holder when the workspace changes" \
  "onFocusedWorkspaceIdChanged" "$(<"$CLAIM_IMPL")"
t_contains "and the capture flow survives a switch" \
  "keepOnWorkspace: true" "$(<"$SHELL_DIR/services/screenshots/Screenshots.qml")"
t_contains "the island closes too, since it holds no claim" \
  "onWorkspaceIdChanged" "$(<"$SHELL_DIR/common/ui/IslandHost.qml")"
t_empty "no surface keeps its own copy of the workspace rule" \
  "$(grep -l 'focusedWorkspaceId' "$TRAY_MENU" "$WALLPAPER_VIEW" 2>/dev/null || true)"

t_section "the layer rules cover the surfaces that need them"

# Both directions: a rule for a namespace that no longer asks for one is dead
# configuration, and a namespace that needs an order or a `no_anim` without its
# rule loses that behavior silently.
REG_RULES="$(reg_rule_namespaces | LC_ALL=C sort -u)"
FILE_RULES="$(rule_namespaces | LC_ALL=C sort -u)"
t_eq "every rule matches a registry row that asks for one" "$REG_RULES" "$FILE_RULES"

RULES_SRC="$(<"$RULES")"
t_contains "the pile is ordered under the modal overlays" "order = 2," "$RULES_SRC"
t_contains "the island is ordered under the menus and over the pile" \
  "Vibranium Island" "$RULES_SRC"
t_contains "the privacy dots sit above the lock" "above_lock = 1," "$RULES_SRC"
t_contains "the color pick is the topmost overlay" "order = -2" "$RULES_SRC"
t_contains "the picker leaves at the unmap" "vibranium:capture-picker" "$RULES_SRC"
t_contains "and so does the region selector" "vibranium:capture-region" "$RULES_SRC"
t_contains "the annotator may share the screen with a visit" \
  "Vibranium Annotation Editor" "$RULES_SRC"
t_contains "one order step above the visit band" "order = -1," \
  "$(grep -A4 'Vibranium Annotation Editor' "$RULES")"

t_section "the app-like fullscreen view is a toplevel"

LYRICS="features/bar/modules/NowPlaying/LyricsFullscreenOverlay.qml"
LYRICS_SRC="$(<"$SHELL_DIR/$LYRICS")"
t_not_contains "the lyrics view is not a layer surface" "LayerSurface {" "$LYRICS_SRC"
t_not_contains "and not a raw panel" "PanelWindow {" "$LYRICS_SRC"
t_contains "it holds a real window" "property Window win: Window" "$LYRICS_SRC"
t_empty "it does not start in fullscreen" "$(grep -o 'visibility: Window.FullScreen' "$SHELL_DIR/$LYRICS")"
t_contains "it requests fullscreen on demand" "Window.FullScreen" "$LYRICS_SRC"
t_contains "it is named in the compositor's window list" 'title: "Player view"' "$LYRICS_SRC"
t_contains "and maps only when opened" "visible: root.opened" "$LYRICS_SRC"
t_empty "and carries no layer-shell keyboard grab" "$(grep -o 'WlrKeyboardFocus' "$SHELL_DIR/$LYRICS")"

t_note "layer choice is a contract with common/ui/LayerSpec.js: a namespace change edits the registry, the declaration and default/hypr/window-rules.lua, or the surface loses its order, its lock behavior or its animation"

t_summary
