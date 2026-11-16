.pragma library

// The layer-shell contract, one row per surface.
//
// A surface's layer, namespace, exclusion mode, keyboard policy, input region
// and mapping policy used to be declared in full at every `PanelWindow`, which
// made the cross-surface story (what sits over what, which surface may take the
// keyboard, which one reserves space) reconstructible only by reading eighteen
// declarations and the Hyprland rules beside them. This table is that story in
// one place. `LayerSurface.qml` reads the static half of each row; the static
// suite asserts the dynamic half against the files that own it.
//
// Layer numbers are the `wlr-layer-shell-unstable-v1` enum: 0 background,
// 1 bottom, 2 top, 3 overlay. They are numbers because this is a pure JS
// library with no Qt imports; `LayerSurface` maps them back to `WlrLayer`.
var BACKGROUND = 0
var BOTTOM = 1
var TOP = 2
var OVERLAY = 3

// layer      - the wlr-layer-shell level the surface maps on.
// focus      - the keyboard mode the surface may ever ask for: "none",
//              "ondemand" (dismissal keys) or "exclusive" (owns the screen).
//              A surface whose mode is gated on visibility still declares the
//              strongest mode it reaches.
// exclusion  - "normal" reserves space for tiled windows; "ignore" leaves the
//              desktop alone. Everything but the bar is "ignore": a modal that
//              reflowed the desktop under it would move the very content it is
//              dimming.
// mask       - "none" (the whole surface takes input, which is what a modal
//              scrim wants), "empty" (click-through: a full-screen surface that
//              draws without owning the pointer), "content" (the input region
//              follows the drawn box: the pile, the bar strip minus its module
//              slots).
// mapped     - "always" (the surface stays mapped for the session; the content
//              fades instead) or "open" (mapped only while it has something to
//              show).
// order      - the Hyprland layer-rule order. It counts DOWN: the lowest value
//              renders on top. 0 means the surface takes the compositor default
//              and needs no rule for ordering.
// rule       - whether `default/hypr/window-rules.lua` must carry a rule that
//              matches this namespace. The static suite checks both directions,
//              so a rule cannot outlive its surface and a namespace that needs
//              one cannot lose it.
var SPECS = {
  "vibranium:wallpaper": { layer: BACKGROUND, focus: "none", exclusion: "ignore", mask: "none", mapped: "always", order: 0, rule: false },
  // The bar is the only surface that reserves space, and Bottom is the level
  // that keeps it there. A tiled window can never overlap it (the exclusive
  // zone), a floating window can draw over it (a bar that punched through a
  // float would be a layer surface pretending to be chrome), and a fullscreen
  // toplevel covers it outright rather than fading it like the Top layer.
  "vibranium:bar": { layer: BOTTOM, focus: "none", exclusion: "normal", mask: "none", mapped: "always", order: 0, rule: false },
  // Overlay rather than Top: Hyprland fades the whole Top layer when a window
  // goes fullscreen, which is why the pile and this surface both left it. The
  // rule's order puts the island under the modal menus (0) and over the
  // notification pile (2).
  "vibranium:island": { layer: OVERLAY, focus: "ondemand", exclusion: "ignore", mask: "none", mapped: "open", order: 1, rule: true },
  // The capture host is on Top and invisible: it is mapped for the
  // frame -> grab -> decode hop only, and an empty input region keeps the
  // pointer off it for that interval.
  "vibranium:screenshot": { layer: TOP, focus: "none", exclusion: "ignore", mask: "empty", mapped: "open", order: 0, rule: false },
  // The menu family. Seven namespaces, one declaration in OverlayWindow.qml:
  // every view is a full-screen scrim on every screen, the panel and the
  // exclusive keyboard on the primary alone.
  "vibranium:menu": { layer: OVERLAY, focus: "exclusive", exclusion: "ignore", mask: "none", mapped: "open", order: 0, rule: false },
  "vibranium:launcher": { layer: OVERLAY, focus: "exclusive", exclusion: "ignore", mask: "none", mapped: "open", order: 0, rule: false },
  "vibranium:clipboard": { layer: OVERLAY, focus: "exclusive", exclusion: "ignore", mask: "none", mapped: "open", order: 0, rule: false },
  "vibranium:power": { layer: OVERLAY, focus: "exclusive", exclusion: "ignore", mask: "none", mapped: "open", order: 0, rule: false },
  "vibranium:pass": { layer: OVERLAY, focus: "exclusive", exclusion: "ignore", mask: "none", mapped: "open", order: 0, rule: false },
  "vibranium:theme-picker": { layer: OVERLAY, focus: "exclusive", exclusion: "ignore", mask: "none", mapped: "open", order: 0, rule: false },
  "vibranium:wallpaper-picker": { layer: OVERLAY, focus: "exclusive", exclusion: "ignore", mask: "none", mapped: "open", order: 0, rule: false },
  // The desktop context menu. OnDemand only while open: it has no card of its
  // own to draw a keyboard into, and Escape is the whole keyboard surface.
  "vibranium:wallpaper-menu": { layer: OVERLAY, focus: "ondemand", exclusion: "ignore", mask: "none", mapped: "open", order: 0, rule: false },
  "vibranium:tray": { layer: OVERLAY, focus: "ondemand", exclusion: "ignore", mask: "none", mapped: "open", order: 0, rule: false },
  "vibranium:tooltip": { layer: OVERLAY, focus: "none", exclusion: "ignore", mask: "empty", mapped: "open", order: 0, rule: false },
  "vibranium:notifications": { layer: OVERLAY, focus: "none", exclusion: "ignore", mask: "content", mapped: "open", order: 2, rule: true },
  "vibranium:osd": { layer: OVERLAY, focus: "none", exclusion: "ignore", mask: "empty", mapped: "open", order: 0, rule: false },
  "vibranium:polkit": { layer: OVERLAY, focus: "exclusive", exclusion: "ignore", mask: "none", mapped: "open", order: 0, rule: false },
  // The dots stay mapped for the session: an Overlay map/unmap on every
  // fullscreen toggle re-maps the surface and replays the layer fade. The rule
  // carries them over the session lock, which draws above every layer.
  "vibranium:privacy": { layer: OVERLAY, focus: "none", exclusion: "ignore", mask: "empty", mapped: "always", order: -1, rule: true },
  // The bar's move/drop proxy. Full-screen for the session on purpose: the
  // gesture needs the surface under the pointer for the whole drag, and a held
  // pointer only stays on the pressed surface while some window of this client
  // holds keyboard focus - a strip-sized proxy would drop the drag the moment
  // the cursor left the bar. The content mask is what keeps the idle surface
  // from eating module clicks.
  "vibranium:bar-move": { layer: OVERLAY, focus: "none", exclusion: "ignore", mask: "content", mapped: "always", order: 0, rule: false },
  "vibranium:color-pick": { layer: OVERLAY, focus: "exclusive", exclusion: "ignore", mask: "none", mapped: "open", order: -2, rule: true },
  "vibranium:network-qr": { layer: OVERLAY, focus: "exclusive", exclusion: "ignore", mask: "none", mapped: "open", order: 0, rule: false },
  "vibranium:screenshot-region": { layer: OVERLAY, focus: "exclusive", exclusion: "ignore", mask: "none", mapped: "open", order: 0, rule: true },
  "vibranium:screenshot-picker": { layer: OVERLAY, focus: "exclusive", exclusion: "ignore", mask: "none", mapped: "open", order: 0, rule: true },
  // The annotation editor is the one surface that may share the screen with a
  // visit overlay: it is the last step of a capture the user asked for, so it
  // draws above the menu band (0) and above the ambient surfaces. The color
  // pick keeps its -2: a pick that samples pixels must stay above the board.
  "vibranium:screenshot-annotate": { layer: OVERLAY, focus: "exclusive", exclusion: "ignore", mask: "none", mapped: "open", order: -1, rule: true }
}

function spec(namespace) {
  return Object.prototype.hasOwnProperty.call(SPECS, namespace) ? SPECS[namespace] : null
}

function has(namespace) {
  return Object.prototype.hasOwnProperty.call(SPECS, namespace)
}

function names() {
  return Object.keys(SPECS)
}

function layerFor(namespace) {
  var s = spec(namespace)
  return s === null ? OVERLAY : s.layer
}

function focusFor(namespace) {
  var s = spec(namespace)
  return s === null ? "none" : s.focus
}

function exclusionFor(namespace) {
  var s = spec(namespace)
  return s === null ? "ignore" : s.exclusion
}

// The namespace a Hyprland layer rule must match, when the surface needs one.
function needsRule(namespace) {
  var s = spec(namespace)
  return s !== null && s.rule === true
}

// Every namespace with order != 0, which is exactly the set a rule has to
// order: the compositor's default order is 0.
function orderedNames() {
  return names().filter(function (n) { return SPECS[n].order !== 0 })
}

// Namespaces declared by more than one row, which would make one layer rule
// govern two surfaces silently.
function duplicates() {
  var seen = {}
  var dupes = []
  names().forEach(function (n) {
    if (seen[n] === true) dupes.push(n)
    seen[n] = true
  })
  return dupes
}
