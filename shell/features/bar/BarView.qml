pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type missing-property
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.common
import qs.features.bar
import "../../common/text/DropPayload.js" as DropPayload

// Per-screen bar surface on the bottom layer. One window per real screen,
// spanning the full width at Bar.height, reserving an exclusive zone so
// tiled windows never overlap it. The three zones live here as reusable
// Zone components (self-anchored) - each renders its layout + owned slots
// and handles its own drag reorder with boundary hints and a live config
// write through Bar.
//
// Dragging empty bar space (anywhere the zones don't cover) starts the bar
// position gesture: the pointer's screen y picks a top/bottom target, the
// per-monitor MoveWindow previews it, and releasing persists it live. The
// press itself lands on the MoveWindow overlay, not here: this window is
// only `Bar.height` tall, and the compositor keeps a held pointer on the
// pressed surface only while some window holds keyboard focus (see the
// MoveWindow comment), so on an empty workspace the drag would die the
// moment the pointer left the strip. The `moveExcl*` rects are what lets the
// overlay's region skip the module zones.
//
// The window never closes while the shell runs: disabled state only
// unmaps it (and releases the exclusive zone) so a toggle over IPC can
// bring it back instantly.
PanelWindow {
  id: win

  property string moveRegistrationKey: ""
  readonly property real moveBarY: Bar.position === "top"
    ? 0 : Math.max(0, win.screen.height - Bar.height)

  // The three zone rects the move proxy's input region subtracts, one set of
  // four scalars per zone. Scalars rather than a list of objects because the
  // proxy pushes the whole mask to the compositor on every change, and a
  // number only notifies when that number changes: a `var` binding that built
  // a fresh array and fresh objects on each evaluation gave every field a new
  // identity every time, so the mask rebuilt itself and went to the
  // compositor on every frame of any bar animation, on every monitor. The
  // rounding is what makes the scalars hold still - a slot width glides
  // sub-pixel through the grow animation, and only a rect that crosses a
  // whole pixel reaches the proxy.
  //
  // A zone that is not there yet, or that is collapsed, reads as a zero rect
  // and subtracts nothing. That guard is also what makes these bindings safe
  // to declare here: a `real` whose expression cannot produce a number on its
  // first evaluation has its binding dropped for good, and the zones are
  // children created after this object's properties are set up.
  readonly property real moveExcl0X: leftZone
    ? Math.round(content.x + leftZone.x) : 0
  readonly property real moveExcl0Y: leftZone
    ? Math.round(win.moveBarY + content.y + leftZone.y) : 0
  readonly property real moveExcl0W: leftZone
    ? (leftZone.width <= 0 || leftZone.height <= 0
      ? 0 : Math.ceil(leftZone.width)) : 0
  readonly property real moveExcl0H: leftZone
    ? (leftZone.width <= 0 || leftZone.height <= 0
      ? 0 : Math.ceil(leftZone.height)) : 0
  readonly property real moveExcl1X: centerZone
    ? Math.round(content.x + centerZone.x) : 0
  readonly property real moveExcl1Y: centerZone
    ? Math.round(win.moveBarY + content.y + centerZone.y) : 0
  readonly property real moveExcl1W: centerZone
    ? (centerZone.width <= 0 || centerZone.height <= 0
      ? 0 : Math.ceil(centerZone.width)) : 0
  readonly property real moveExcl1H: centerZone
    ? (centerZone.width <= 0 || centerZone.height <= 0
      ? 0 : Math.ceil(centerZone.height)) : 0
  readonly property real moveExcl2X: rightZone
    ? Math.round(content.x + rightZone.x) : 0
  readonly property real moveExcl2Y: rightZone
    ? Math.round(win.moveBarY + content.y + rightZone.y) : 0
  readonly property real moveExcl2W: rightZone
    ? (rightZone.width <= 0 || rightZone.height <= 0
      ? 0 : Math.ceil(rightZone.width)) : 0
  readonly property real moveExcl2H: rightZone
    ? (rightZone.width <= 0 || rightZone.height <= 0
      ? 0 : Math.ceil(rightZone.height)) : 0

  // Shared hover state between the logout trigger and the tray module: the
  // tray stays expanded while the logout icon (or the tray itself) is
  // hovered. Lives on the window so each monitor's bar keeps its own state.
  property bool trayTriggerHovered: false

  // Count of zones on this window with a slot-reorder drag running. While a
  // drag is live the session group must be inert: hovering it (the logout
  // trigger) must not expand the tray, which would otherwise shift the row
  // under the cursor mid-drag. Counted per window so a drag on one monitor
  // never freezes another's session hover.
  property int _slotDragCount: 0
  readonly property bool slotDragActive: win._slotDragCount > 0

  // True during a drag and for a short grace after it ends. The session
  // keys off this (not slotDragActive) so releasing a module that leaves
  // the cursor parked over the session doesn't pop the tray open right
  // after a rearrange; it only expands again on a deliberate fresh hover.
  property bool recentDragActive: false
  property int dragGraceMs: 450

  function enterSlotDrag() {
    win._slotDragCount++
    win._armRecentDrag()
    // Clear any hover the logout trigger accumulated, so a drag that swept
    // over the session can't leave the tray latched open on release.
    win.trayTriggerHovered = false
    // Trace: the per-window drag count is the contract the session group
    // reads to freeze itself, so a frozen tray is explained by the window
    // that reported the drag rather than by a guess.
  }
  function leaveSlotDrag() {
    if (win._slotDragCount > 0) win._slotDragCount--
    win._armRecentDrag()
    win.trayTriggerHovered = false
  }
  function _armRecentDrag() {
    win.recentDragActive = true
    dragGraceTimer.restart()
  }

  // Hold recentDragActive (and thus the session's inertness) for dragGraceMs
  // after the last drag ends, then let the session react to hover again.
  // Guarded so a timer firing during a still-running long drag doesn't lift
  // the inertness; the next enter/leave re-arms it anyway.
  Timer {
    id: dragGraceTimer

    interval: win.dragGraceMs
    onTriggered: if (win._slotDragCount <= 0) win.recentDragActive = false
  }

  visible: Bar.enabled && !Bar.hideToggle
  color: Bar.blurred ? Ui.tint("background_0", 0.8) : Ui.solid("background_0")
  // exclusiveZone implies ExclusionMode.Normal (reserves space for tiled
  // windows); an explicit Ignore would let windows slide under the bar.
  // A transient IPC-only hide (hideToggle) releases the zone like a
  // disabled bar so tiled windows reclaim the space.
  exclusiveZone: (Bar.enabled && !Bar.hideToggle) ? Bar.height : 0
  anchors {
    left: true
    right: true
    top: Bar.position === "top"
    bottom: Bar.position === "bottom"
  }
  implicitHeight: Bar.height

  WlrLayershell.layer: WlrLayer.Bottom
  WlrLayershell.namespace: "vibranium:bar"
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  // Uniform inset between the zones and every window edge. Zones anchor to
  // this filled container (not the window) so module positions stay
  // consistent for both positions.
  Item {
    id: content

    anchors.fill: parent
    anchors.topMargin: Ui.s
    anchors.bottomMargin: Ui.s
    anchors.leftMargin: Ui.s
    anchors.rightMargin: Ui.s

    // Left hugs the start edge, center sits fixed on the horizontal
    // center (fixed-center anchoring: independent of the side zones'
    // widths), right hugs the end edge. Each instantiates its layout +
    // owned slots and wires them to this window for popup anchoring.
    // (Paint order lives in Zone itself: center above the sides, and a
    // zone carrying a module above everything.)
    Zone {
      id: leftZone
      region: "left"
      hostWindow: win
    }

    Zone {
      id: centerZone
      region: "center"
      hostWindow: win
    }

    Zone {
      id: rightZone
      region: "right"
      hostWindow: win
    }

    IslandHost {
      id: islandHost

      barPosition: Bar.position
    }

    ToolTipHost {
      id: toolTipHost

      barPosition: Bar.position
    }
  }

  Rectangle {
    id: barBorder

    z: 1
    x: 0
    y: Bar.position === "top" ? parent.height - height : 0
    width: parent.width
    height: 1
    visible: Bar.showBorder
    color: Ui.solid("background_3")
  }

  // Wallpaper drop target for the module zones. The move proxy's input
  // region is the strip MINUS the zone rects, so a drag over a module
  // arrives here and a drag over a gap arrives at the proxy instead; both
  // halves hand the same payload to forwardWallpaperDrop, so the payload
  // parsing exists once and the drop target covers the whole strip.
  // The slab is drawn by the proxy, which sits above this window.
  property bool wallpaperDropHover: false

  // Reduce a drop to the one uri the desktop layer can act on, and name the
  // monitor it landed on. The reduction is the shared DropPayload rule, the
  // same one the hover filters on every surface use, so this half cannot
  // accept a drag on hover and then refuse the same drag as a multi-file one.
  // The wallpaper service remains the authority on what it can turn into a
  // wallpaper, and reports a rejection through the error argument. The uri
  // travels as one string rather than a one-element list, so no array
  // crossing the signal can arrive in a shape the service does not recognise.
  function forwardWallpaperDrop(drop) {
    const verdict = DropPayload.resolve(drop)
    const uri = verdict.ok === true ? String(verdict.uri) : ""
    const error = verdict.ok === true ? "" : String(verdict.error)
    const screen = String(win.screen?.name ?? "").trim().replace(/[^A-Za-z0-9._-]/g, "_")
    DesktopActions.wallpaperDrop(uri, screen, error)
  }

  DropArea {
    id: wallpaperDrop
    anchors.fill: parent
    enabled: DesktopLayoutState.barEnabled && DesktopLayoutState.wallpaperEnabled
    onEntered: drag => {
      if (!DesktopLayoutState.wallpaperEnabled || !DesktopLayoutState.barEnabled) return
      // The same filter forwardWallpaperDrop applies, so the slab cannot
      // appear for a drag this half is about to refuse.
      if (DropPayload.supported(drag)) {
        win.wallpaperDropHover = true
        drag.acceptProposedAction()
      }
    }
    onExited: win.wallpaperDropHover = false
    onDropped: drop => {
      win.wallpaperDropHover = false
      if (!DesktopLayoutState.wallpaperEnabled || !DesktopLayoutState.barEnabled) return
      win.forwardWallpaperDrop(drop)
    }
  }

  // Module contract: every module receives its monitor screen and the bar
  // window it lives in (islands anchor to the latter). The loader calls
  // this after instantiating; groups forward it to their members.
  property alias islandHost: islandHost
  property alias toolTipHost: toolTipHost

  Connections {
    target: Bar

    function onEnabledChanged() {
      if (!Bar.enabled || Bar.hideToggle) {
        islandHost.close()
        toolTipHost.hide()
      }
    }
    function onHideToggleChanged() {
      if (!Bar.enabled || Bar.hideToggle) {
        islandHost.close()
        toolTipHost.hide()
      }
    }
  }

  function refreshMoveRegistration() {
    const key = String(win.screen?.name ?? "")
    if (key === win.moveRegistrationKey) return
    if (win.moveRegistrationKey !== "") Bar.unregisterMoveView(win)
    win.moveRegistrationKey = key
    // Trace: the MoveWindow proxy finds its bar window through this key, so
    // a strip that stopped receiving presses is explained by the
    // registration (or its loss) rather than by the input region.
    if (key !== "") Bar.registerMoveView(win)
  }

  Component.onCompleted: {
    win.moveRegistrationKey = String(win.screen?.name ?? "")
    if (win.moveRegistrationKey !== "") Bar.registerMoveView(win)
  }
  onScreenChanged: win.refreshMoveRegistration()
  Component.onDestruction: {
    Bar.unregisterMoveView(win)
  }

  function wireModule(item) {
    item.barScreen = win.screen
    item.barWindow = win
  }

}
