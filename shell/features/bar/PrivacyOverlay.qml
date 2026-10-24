pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.common
import qs.services

// Always-on privacy indicator for one screen, on the Overlay layer.
//
// The only surface in the shell that draws the capture dots. The bar's privacy
// module is a launcher for the island and paints no dots of its own, so
// nothing here consults the bar: the indicator is visible whatever the bar
// module's toggle says and whatever the bar's own enabled state is.
//
// Overlay is the topmost layer wlr-layer-shell has, and Hyprland's fullscreen
// fade only walks LAYER_TOP, so this surface keeps its alpha and is composited
// after the window pass. That is what lets a fullscreen toplevel - which covers
// the bar outright - still show the indicator, and why the only thing below
// that has to know about fullscreen is one predicate.
//
// A session lock draws above every layer-shell surface, so this one would be
// covered while the session is locked. It is carried over the lock surface
// anyway, by the `above_lock` effect on this namespace's layer rule rather
// than by anything here. The effect is the whole mechanism: to change whether
// the indicator survives a lock, edit the Hyprland layer rule for
// vibranium:privacy, not this file.
PanelWindow {
  id: root

  property ShellScreen winScreen
  screen: root.winScreen
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: -1
  // Full-screen surface, like every other Overlay in this shell. Covering
  // the monitor costs one transparent surface, and the empty mask region
  // below keeps all of it click-through, so the dots are positioned
  // explicitly instead of the window being shrunk around them.
  anchors.top: true
  anchors.bottom: true
  anchors.left: true
  anchors.right: true

  // The window's own `visible` is never bound to the privacy state. The
  // surface stays mapped for the whole session and only the content
  // fades, because an Overlay map/unmap on every fullscreen toggle
  // re-maps the surface, damages the monitor and replays the layer fade.
  readonly property bool screenFullscreen:
    FullscreenProbe.screenActive(root.winScreen?.name)
  // The level is a pure function of `screenFullscreen` with no state and no
  // schedule of its own: the Behavior on the wrapper item is what carries the
  // change across. Capture activity is not an input, so a capture beginning
  // well into a fullscreen window still finds the dots at that window's level.
  //
  // A fullscreen toplevel is the only thing that dims the dots. The lock screen
  // is not, even though `above_lock` draws this surface over it, because a lock
  // backdrop is a known dark surface rather than arbitrary content and the dots
  // read at full strength against it without competing.
  readonly property real dimAlpha: 0.5
  readonly property real levelAlpha: root.screenFullscreen ? root.dimAlpha : 1
  // How long the level change takes to travel, in both directions: the way back
  // up is the same drift in reverse, so leaving fullscreen does not read as a
  // separate snap against the way down. One knob for both.
  //
  // Paired with InOutQuad below, which is what makes the change feel
  // deliberate rather than instant. A strongly symmetric curve spends its
  // opening barely moving - InOutCubic reaches a tenth of the change about 29%
  // into the duration and a quarter about 40% - so at any length long enough to
  // read as a fade it opens on a dead period that looks like a stall. InOutQuad
  // is the mildest symmetric curve, late enough to be deliberate without
  // opening on a wait, which leaves the duration free to be the settle rather
  // than the wait.
  readonly property int rampMs: 400
  // The show/hide decision only. The level is a separate factor on a separate
  // item: folding both into one product would force a single Behavior, and one
  // duration cannot serve the 120ms show/hide fade and this slower level
  // change at once.
  readonly property real dotOpacity:
    Settings.privacyOverlay && Privacy.active ? 1 : 0
  // The dot and the gap that follows it. The gap belongs to the dot's own slot
  // rather than to the Row's `spacing`, so it collapses with the dot instead of
  // being charged across a collapsed slot; the wrapper's width is what trims
  // the one gap that is always there.
  readonly property int dotSize: 6
  readonly property int dotGap: 5

  // Corner pick, split once per position change rather than per binding
  // evaluation: the vertical edge only varies with the row's top/bottom
  // half, the horizontal one only with its left/right half.
  readonly property bool dotOnTopEdge: Settings.privacyPosition.indexOf("top") === 0
  readonly property bool dotOnLeftEdge: Settings.privacyPosition.indexOf("left") > 0

  // An empty region makes the surface click-through everywhere, so it can
  // never take input from a fullscreen app sitting under it.
  mask: Region { width: 0; height: 0 }

  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.namespace: "vibranium:privacy"
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  // Dot geometry and colour order: microphone, camera, screenshare. Each dot
  // is a fixed-size circle plus its own trailing gap.
  //
  // Two stacked opacity factors with two different durations. The show/hide
  // fade and the fullscreen level change are independent, so they cannot share
  // one property - a single Behavior on their product would give both the same
  // duration. Qt multiplies the two item opacities, so no arithmetic here.

  // One capture dot: a transparent SLOT carrying its own trailing gap and
  // holding a fixed-size circle at its left edge. The slot's width is what
  // the Row lays out, and animating that width is the load-bearing part: a
  // Row drops an invisible child from its layout outright, so a dot that only
  // faded would leave its neighbours snapping to new x positions the moment a
  // capture came or went - the fade smooth, the row jumping. Animating the
  // slot drags the neighbours along instead.
  //
  // The gap lives in the slot rather than in the Row's `spacing` because
  // `spacing` is charged between EVERY pair of children, including a slot
  // collapsed to zero: a dot appearing at the far end would then push the
  // whole cluster along the edge while the same dot appearing at the near
  // end would not, and the row's right edge would stop being the corner. A
  // gap that belongs to its own slot collapses with it, so the cluster stays
  // flush to the edge whichever dot changes. The one gap that is always
  // present is the trailing one, which is what the wrapper's width trims.
  //
  // The circle keeps its own fixed size instead of stretching with the slot,
  // so a dot appears by fading in at full size while the gap grows around it
  // - rather than squashing from a sliver. `enabled` on each Behavior is what
  // motion-off snaps instead of animates.
  //
  // An inline component gets its own scope and cannot read `root`, so the two
  // geometry numbers and the gate come in as properties: the use site is in
  // the enclosing scope and is where `root` is read.
  component Dot: Rectangle {
    id: dot

    required property bool on
    required property string colorKey
    required property real dotSize
    required property real dotGap

    width: dot.on ? dot.dotSize + dot.dotGap : 0
    height: dot.dotSize
    color: "transparent"
    Behavior on width {
      enabled: MotionPolicy.enabled
      NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
    }

    Rectangle {
      width: dot.dotSize
      height: dot.dotSize
      radius: dot.dotSize / 2
      color: Ui.solid(dot.colorKey)
      opacity: dot.on ? 1 : 0
      Behavior on opacity {
        enabled: MotionPolicy.enabled
        NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
      }
    }
  }

  Item {
    id: rampHost

    // A positioner does not honour anchors, so the corner inset is set
    // explicitly against the surface. The width is the row's own extent less
    // the trailing gap every lit dot carries, so the last lit dot's right edge
    // is the wrapper's right edge and the cluster sits flush to the corner
    // whichever dots happen to be on. The row's width tracks the lit dots, so
    // this does too, and the cluster grows inward from the edge.
    y: root.dotOnTopEdge ? Ui.s : root.winScreen.height - height - Ui.s
    x: root.dotOnLeftEdge ? Ui.s : root.winScreen.width - width - Ui.s
    width: Math.max(0, dotsRow.implicitWidth - root.dotGap)
    height: dotsRow.implicitHeight
    opacity: root.levelAlpha
    // InOutQuad, symmetric so the onset and the settle are the same shape and
    // neither end reads as a stall or a lurch. Curves with a later head
    // (InOutQuart, InCubic) buy that delay by collapsing the tail, so the last
    // half of the fade lands inside a few frames and the delay costs the
    // settle rather than adding to it. See `rampMs`.
    //
    // `enabled` here is the only thing motion is allowed to gate. Motion off
    // makes the Behavior inert, so the level change snaps instead of easing -
    // it does not suppress the change itself. Gating the VALUE by motion would
    // pin the target at 1 and the dots would never dim at all.
    Behavior on opacity {
      enabled: MotionPolicy.enabled
      NumberAnimation {
        duration: root.rampMs
        easing.type: Easing.InOutQuad
      }
    }

    // A Row drops an invisible child from its layout outright, so a dot
    // that only faded would leave its neighbours snapping to new x positions
    // the moment a capture came or went - the fade smooth, the row jumping.
    // The Dot slots animate their width instead, which drags the neighbours
    // along; the reasoning for that shape is on the component above.
    Row {
      id: dotsRow

      spacing: 0
      opacity: root.dotOpacity
      // The animation runs on the Row's own opacity because that is the
      // property a Behavior writes; `dotOpacity` is readonly, and a Behavior
      // on a readonly property is an assignment the engine refuses at load.
      Behavior on opacity {
        enabled: MotionPolicy.enabled
        NumberAnimation { duration: Ui.fastMs }
      }

      Dot {
        on: Privacy.micOn
        colorKey: "green"
        dotSize: root.dotSize
        dotGap: root.dotGap
      }

      Dot {
        on: Privacy.camOn
        colorKey: "purple"
        dotSize: root.dotSize
        dotGap: root.dotGap
      }

      Dot {
        on: Privacy.shareOn
        colorKey: "orange"
        dotSize: root.dotSize
        dotGap: root.dotGap
      }
    }
  }
}
