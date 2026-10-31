pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.common
import qs.features.bar
import "../../common/text/DropPayload.js" as DropPayload

// Persistent input proxy and full-screen feedback for the bar-position
// gesture.
//
// The press has to land on THIS surface rather than on the 28px bar strip:
// the compositor keeps a held pointer on the surface that took the press
// only while some window holds keyboard focus (InputManager.cpp keeps
// `pointerFocus` "if we are holding a pointer button" and only when
// `Desktop::focusState()->surface()` is mapped). On an empty workspace
// there is no such window, so a press on the bar itself would lose the
// pointer the moment the cursor left the strip. A full-screen surface is
// the only thing that tracks a drag anywhere on the monitor, which is
// exactly what the gesture needs.
//
// The cost of that is the bug this file's input region now guards: an
// overlay is hit-tested before any window, so a strip-shaped region
// claimed clicks over a FULLSCREEN app, in the rows the app painted under
// a bar the user cannot see. So the idle region is the strip only while
// the bar is actually visible; a fullscreen window on this monitor (which
// is also when Hyprland stops the bar from receiving input at all) drops
// it to empty. Once a gesture is running the region goes full-screen, but
// a gesture can only start from a visible bar, so that never sits over
// an app.
//
// The same hit-test precedence makes this surface the drop target for the
// strip's gaps: a drag landing there arrives here and never reaches the bar
// window, whose own DropArea only serves the zone rects the region subtracts.
PanelWindow {
  id: root

  required property ShellScreen winScreen
  screen: root.winScreen

  property var sourceView: null
  readonly property bool inputReady: root.sourceView !== null
  readonly property bool ownsGesture: Bar.movePressed
    && Bar.moveOwner === root
    && !!root.winScreen
    && Bar.moveScreenKey === root.winScreen.name
  readonly property bool matches: Bar.moveActive && root.ownsGesture
  readonly property real barY: Bar.position === "top"
    ? 0 : Math.max(0, root.winScreen.height - Bar.height)
  // The zone rects the idle region subtracts, read off the per-monitor bar
  // window's own `moveExcl*` scalars. Flat scalars rather than a list of
  // objects for the reason BarView keeps them flat: a number notifies only
  // when it changes, so a slot gliding sub-pixel through the bar's grow
  // animation leaves this mask alone until a rect crosses a whole pixel,
  // instead of rebuilding and pushing the full-screen region's mask every
  // frame. An unregistered bar window reads as a zero rect, which subtracts
  // nothing and is also what keeps these bindings from failing their
  // conversion to real on the first evaluation, which happens before
  // `refreshSourceView()` has set `sourceView`.
  readonly property real excl0X: root.sourceView ? root.sourceView.moveExcl0X : 0
  readonly property real excl0Y: root.sourceView ? root.sourceView.moveExcl0Y : 0
  readonly property real excl0W: root.sourceView ? root.sourceView.moveExcl0W : 0
  readonly property real excl0H: root.sourceView ? root.sourceView.moveExcl0H : 0
  readonly property real excl1X: root.sourceView ? root.sourceView.moveExcl1X : 0
  readonly property real excl1Y: root.sourceView ? root.sourceView.moveExcl1Y : 0
  readonly property real excl1W: root.sourceView ? root.sourceView.moveExcl1W : 0
  readonly property real excl1H: root.sourceView ? root.sourceView.moveExcl1H : 0
  readonly property real excl2X: root.sourceView ? root.sourceView.moveExcl2X : 0
  readonly property real excl2Y: root.sourceView ? root.sourceView.moveExcl2Y : 0
  readonly property real excl2W: root.sourceView ? root.sourceView.moveExcl2W : 0
  readonly property real excl2H: root.sourceView ? root.sourceView.moveExcl2H : 0

  // True while a fullscreen window covers this monitor, which is also
  // exactly when Hyprland unfocuses the bar's own layer surface: the bar
  // is invisible, so the proxy must not claim the strip either. A binding,
  // so it tracks the workspace live, and scoped to this monitor because the
  // proxy is per monitor: a fullscreen app on one must not disarm the bar
  // on the others. A monitor with no name, or one Hyprland no longer
  // reports, reads false.
  readonly property bool screenFullscreen:
    FullscreenProbe.screenActive(root.winScreen?.name)
  // The idle strip: present only while the bar is the thing under the
  // pointer there. Empty otherwise, so a fullscreen app's own controls
  // under the (hidden) bar stay clickable.
  //
  // It is also empty while the bar's zones have not settled yet: at boot
  // the per-monitor bar window registers before its zone widths are known,
  // so a non-empty mask would claim the whole strip with no module holes
  // and swallow every click and hover on the bar. Waiting for at least one
  // zone to report a real width (or for a bar that genuinely has no modules)
  // keeps the strip pass-through until the holes can be cut. Settings.ready
  // is the gate for the same reason: before the store lands the layout is
  // empty and would otherwise read as "no modules".
  readonly property bool idleRegion: root.inputReady
    && Bar.enabled
    && !Bar.hideToggle
    && !root.screenFullscreen
    && Settings.ready
    && (root.excl0W + root.excl1W + root.excl2W > 0
      || (Bar.layout.left.length + Bar.layout.center.length + Bar.layout.right.length === 0))
  property bool proxyPressed: false
  property bool proxyDragging: false
  property real pressedX: 0
  property real pressedY: 0
  readonly property real dragThreshold: 6

  function refreshSourceView() {
    root.sourceView = Bar.moveViewFor(root.winScreen)
  }

  function cancelLocal() {
    Bar.cancelBarMove(root)
    root.proxyPressed = false
    root.proxyDragging = false
  }

  function invalidateScreen() {
    root.cancelLocal()
    root.refreshSourceView()
  }

  // Mapped only while the strip can actually be used for the move gesture
  // (or a gesture is running). Mapping it earlier - while the zone widths
  // are still zero - would create the surface with a mask that claims the
  // whole strip and no module holes, and the compositor keeps that stale
  // mask until something re-maps the surface (which is exactly what a
  // random menu toggle did). Staying unmapped until the holes exist makes
  // the first map carry the correct region.
  visible: Bar.enabled && !Bar.hideToggle && (root.ownsGesture || root.idleRegion)
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: -1
  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }

  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.namespace: "vibranium:bar-move"
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  mask: Region {
    x: 0
    y: root.ownsGesture ? 0 : root.barY
    width: root.ownsGesture || root.idleRegion ? root.winScreen.width : 0
    height: root.ownsGesture ? root.winScreen.height
      : (root.idleRegion ? Bar.height : 0)

    Region {
      x: root.excl0X
      y: root.excl0Y
      width: root.ownsGesture ? 0 : root.excl0W
      height: root.ownsGesture ? 0 : root.excl0H
      intersection: Intersection.Subtract
    }

    Region {
      x: root.excl1X
      y: root.excl1Y
      width: root.ownsGesture ? 0 : root.excl1W
      height: root.ownsGesture ? 0 : root.excl1H
      intersection: Intersection.Subtract
    }

    Region {
      x: root.excl2X
      y: root.excl2Y
      width: root.ownsGesture ? 0 : root.excl2W
      height: root.ownsGesture ? 0 : root.excl2H
      intersection: Intersection.Subtract
    }
  }

  onWinScreenChanged: root.invalidateScreen()

  Connections {
    target: Bar
    function onMoveViewsRevisionChanged() {
      root.refreshSourceView()
    }
  }

  Connections {
    target: root.winScreen
    function onGeometryChanged() { root.invalidateScreen() }
  }

  Component.onCompleted: {
    root.refreshSourceView()
  }
  onBackingWindowVisibleChanged: {
    if (!backingWindowVisible) root.cancelLocal()
    root.refreshSourceView()
  }
  onVisibleChanged: {
    if (!visible) root.cancelLocal()
    root.refreshSourceView()
  }

  // One slab per edge, crossfaded by candidate; the active edge lights up.
  Repeater {
    model: ["top", "bottom"]

    Rectangle {
      id: slab

      required property string modelData
      readonly property bool candidate: modelData === Bar.moveCandidate

      color: Ui.tint("accent", 0.16)
      border.color: candidate ? Ui.solid("accent") : Ui.tint("accent", 0.5)
      border.width: 1
      radius: RoundingPolicy.radius
      visible: root.matches && opacity > 0
      opacity: candidate ? 1 : 0.35

      x: 0
      y: modelData === "top" ? 0 : root.height - height
      width: root.width
      height: Bar.height

      // Dim away when a slot is just a hint (non-candidate); snap instantly
      // to a bright highlight when it becomes the candidate.
      Behavior on opacity {
        enabled: !candidate
        NumberAnimation { duration: Ui.normalMs; easing.type: Easing.OutCubic }
      }

      Title {
        level: 3
        anchors.centerIn: parent
        visible: slab.candidate
        text: "Drop here"
        color: Ui.solid("accent")
        font.bold: true
      }
    }
  }

  // Wallpaper drop target for the strip's gaps. This surface is hit-tested
  // before any window, so over a gap the compositor hands the drag here and
  // the bar window never sees it; the zone rects the region subtracts are
  // the only part of the strip that reaches BarView's own DropArea. Both
  // halves forward through the same per-monitor BarView.
  DropArea {
    id: wallpaperDrop

    anchors.fill: parent
    enabled: Bar.enabled && !Bar.hideToggle && DesktopLayoutState.wallpaperEnabled
    // True only while a payload that passed the hover filter is over the
    // area. DropArea.containsDrag is true for every hovering drag whether
    // or not onEntered accepted it, so the slab binds to this verdict and
    // to the bar window's half instead.
    property bool dragOk: false
    onEntered: drag => {
      if (!Bar.enabled || Bar.hideToggle || !DesktopLayoutState.wallpaperEnabled) return
      // The same filter the bar window's own half applies, so a drag that
      // crosses a module zone and a drag that crosses a gap get the same
      // verdict and the same slab.
      dragOk = DropPayload.supported(drag)
      if (dragOk) drag.acceptProposedAction()
    }
    onExited: dragOk = false
    onDropped: drop => {
      dragOk = false
      if (!Bar.enabled || Bar.hideToggle || !DesktopLayoutState.wallpaperEnabled) return
      if (root.sourceView) root.sourceView.forwardWallpaperDrop(drop)
    }
  }

  // One slab per accepted hover, in the same style as the move slabs. It is
  // drawn here rather than on the bar window so a drag over a module zone,
  // which arrives at that window, lights the same slab.
  Rectangle {
    id: wallpaperSlab

    x: 0
    y: root.barY
    width: parent.width
    height: Bar.height
    visible: wallpaperDrop.dragOk
      || (root.sourceView ? root.sourceView.wallpaperDropHover : false)
    color: Ui.solid("background_0")
    border.color: Ui.solid("accent")
    border.width: 1
    Item {
      anchors.fill: parent
      anchors.leftMargin: 8
      anchors.rightMargin: 8
      clip: true
      Text {
        id: measureText
        visible: false
        text: "DROP TO SET WALLPAPER | "
        color: Ui.solid("accent")
        font.family: Ui.fontFamily
        font.pixelSize: Ui.fontM
        font.bold: true
        font.weight: Font.Black
        font.letterSpacing: 1.0
        font.capitalization: Font.AllUppercase
      }
      Text {
        anchors.centerIn: parent
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: {
          const seg = "DROP TO SET WALLPAPER";
          const sep = " | ";
          const w = measureText.implicitWidth;
          if (w <= 0) return seg;
          const count = Math.max(1, Math.floor(parent.width / w));
          let s = "";
          for (let i = 0; i < count; i++) {
            if (i > 0) s += sep;
            s += seg;
          }
          return s;
        }
        color: Ui.solid("accent")
        font.family: Ui.fontFamily
        font.pixelSize: Ui.fontM
        font.bold: true
        font.weight: Font.Black
        font.letterSpacing: 1.0
        font.capitalization: Font.AllUppercase
      }
    }
  }

  MouseArea {
    id: moveGrab

    anchors.fill: parent
    visible: root.inputReady && Bar.enabled && !Bar.hideToggle
    enabled: root.inputReady && Bar.enabled && !Bar.hideToggle
    acceptedButtons: Qt.LeftButton
    pressAndHoldInterval: 200
    hoverEnabled: true
    preventStealing: true
    cursorShape: root.proxyDragging ? Qt.ClosedHandCursor : Qt.ArrowCursor

    function insideScreen(mouse) {
      if (!root.winScreen) return false
      return mouse.x >= 0 && mouse.x <= root.winScreen.width
        && mouse.y >= 0 && mouse.y <= root.winScreen.height
    }

    function reset() {
      root.proxyPressed = false
      root.proxyDragging = false
    }

    function beginDrag(mouse) {
      if (!root.proxyPressed || !moveGrab.pressed || !root.ownsGesture) return false
      if (!Bar.startBarMove(root)) return false
      root.proxyDragging = true
      Bar.updateBarMove(root, mouse.x, mouse.y)
      return true
    }

    onPressed: mouse => {
      if (!root.inputReady) {
        mouse.accepted = false
        return
      }
      if (!Bar.pressBar(root.winScreen, root)) {
        mouse.accepted = false
        moveGrab.reset()
        return
      }
      root.proxyPressed = true
      root.proxyDragging = false
      root.pressedX = mouse.x
      root.pressedY = mouse.y
      mouse.accepted = true
    }

    onPressAndHold: mouse => moveGrab.beginDrag(mouse)

    onPositionChanged: mouse => {
      if (!root.proxyPressed) return
      if (!root.ownsGesture) {
        moveGrab.reset()
        return
      }
      if (!(mouse.buttons & Qt.LeftButton)) {
        if (root.proxyDragging || Bar.moveActive) {
          Bar.cancelBarMove(root)
        } else {
          Bar.releaseBar(root)
        }
        moveGrab.reset()
        return
      }
      if (!moveGrab.pressed) {
        Bar.cancelBarMove(root)
        moveGrab.reset()
        return
      }
      if (!root.proxyDragging) {
        const travel = Math.abs(mouse.x - root.pressedX)
          + Math.abs(mouse.y - root.pressedY)
        if (travel < root.dragThreshold) return
        moveGrab.beginDrag(mouse)
        return
      }
      Bar.updateBarMove(root, mouse.x, mouse.y)
    }

    onReleased: mouse => {
      if (root.proxyPressed && root.ownsGesture) {
        if (root.proxyDragging || Bar.moveActive) {
          if (!moveGrab.insideScreen(mouse)) {
            Bar.cancelBarMove(root)
          } else {
            Bar.updateBarMove(root, mouse.x, mouse.y)
            Bar.endBarMove(root)
          }
        } else {
          Bar.releaseBar(root)
        }
      }
      moveGrab.reset()
      mouse.accepted = true
    }

    onCanceled: {
      Bar.cancelBarMove(root)
      moveGrab.reset()
    }

    onClicked: mouse => mouse.accepted = true

    onDoubleClicked: mouse => {
      if (!root.inputReady || !Bar.enabled || Bar.hideToggle) return
      Bar.setOption("blurred", !Bar.blurred)
      mouse.accepted = true
    }
  }

  Component.onDestruction: {
    Bar.cancelBarMove(root)
    root.proxyPressed = false
    root.proxyDragging = false
  }
}
