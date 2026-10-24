pragma ComponentBehavior: Bound

import QtQuick
// Aliased because this component is itself called ScrollBar and exports that
// name from qs.common: an unaliased import would make the bare name resolve to
// the wrapper instead of the Qt control.
import QtQuick.Controls as Ctl
import qs.common

// Little scrollbar for Flickable/ListView - track on the right, thumb
// auto-sized from visible/content ratio, fades when idle. Reusable lib:
//   ScrollBar { flickable: myList }
// Other components can reuse by pointing `flickable` at any Flickable.
//
// Canonical placement: the bar belongs to the list and is always drawn
// INSIDE its viewport edge, overlaid - never in a gutter outside it.
// The list keeps its full width; rows reserve a small right inset
// (ArchUpdates' _vBarGutter, Battery/Network's rowPad) so nothing runs
// underneath the bar:
//
//   List { id: myList; width: parent.width; ... }
//   ScrollBar {
//     flickable: myList
//     anchors.right: parent.right
//     anchors.rightMargin: 1
//     anchors.top: myList.top
//     anchors.topMargin: 8
//     anchors.bottom: myList.bottom
//     anchors.bottomMargin: 8
//     thickness: 3
//   }
//
// The native ScrollBar owns the interaction: hit testing, press and hover
// state, press-to-snap, the drag mapping, and the range arithmetic that
// decides how long the thumb is and where it may travel. This wrapper owns
// the shell's side of it - the public properties, the thumb tokens, the
// autoHide policy, the insets, and the single-writer routing of the
// position Qt produces.
Item {
  id: root

  required property Flickable flickable
  // The drag target as var: consumers are either the shared List (which
  // routes contentY through seatTo) or a plain Flickable (raw write).
  readonly property var target: root.flickable
  property int thickness: 3
  property int minThumb: 24
  property int radius: RoundingPolicy.radius
  property bool autoHide: true

  width: thickness
  clip: false
  // Qt's own scrollable fraction. A bar with nothing to scroll is size 1,
  // and the list gets its full edge back.
  visible: !!flickable && bar.size < 1
  opacity: autoHide ? (flickable.moving || bar.pressed || bar.hovered ? 1 : 0.55) : 1

  Behavior on opacity { NumberAnimation { duration: Ui.fastMs } }

  // The thumb's auto-hide opacity, per frame. It is the one value on this
  // primitive the frame loop produces, and it is what a reader watches to
  // see whether the bar is being woken by the scroll it is tracking.

  // A Qt 6 ScrollBar binds to a Flickable only through the ScrollBar.vertical
  // attached property, and that can be written only from the Flickable's own
  // QML - Qt 6 exposes no `flickable` property to write. This wrapper is handed a
  // Flickable it does not own, so it reports the target's geometry through a
  // shadow viewport instead: invisible, non-interactive, never the item under
  // the pointer and never a pixel on screen. Qt reads the range and the
  // position from the shadow and writes its drag result back into it, and both
  // contentY edges are mirrored, so the thumb follows every other way the list
  // moves. The shadow reports the target's viewport, not the bar's length,
  // which is what makes an inset bar measure the visible ratio of the list.
  Flickable {
    id: shadow
    visible: false
    interactive: false
    boundsBehavior: Flickable.StopAtBounds
    width: root.flickable ? root.flickable.width : 1
    height: root.flickable ? root.flickable.height : 1
    contentWidth: root.flickable ? Math.max(root.flickable.contentWidth, 1) : 1
    contentHeight: root.flickable ? Math.max(root.flickable.contentHeight, 1) : 1
    Ctl.ScrollBar.vertical: bar
  }

  Ctl.ScrollBar {
    id: bar
    anchors.fill: parent
    padding: 0
    // Track-free by design: the shell shows the thumb alone, so the style's
    // high-contrast track stays out.
    background: null
    policy: Ctl.ScrollBar.AsNeeded
    // A fraction of the bar's own length, so a long list keeps a grabbable
    // thumb instead of a hairline.
    minimumSize: root.height > 0 ? Math.min(1, root.minThumb / root.height) : 0
    contentItem: Rectangle {
      radius: root.radius
      color: Ui.tint("foreground_1", bar.pressed ? 0.65 : 0.42)

      Behavior on color { ColorAnimation { duration: Ui.fastMs } }
    }
  }

  // Whether the position arriving from the shadow is the thumb's, as opposed
  // to the shadow moving on its own. A shadow contentY moves three ways and
  // only one is a drag: we mirror the target into it, Qt clamps it when the
  // content it mirrors changes under it, and the user moves the thumb.
  // Relaying either of the first two is a loop that ends with the target
  // parked wherever the clamp put the shadow - which is the top of the
  // list, every time a model write resets the view - written through the
  // one writer whose write is believed, and epoch-stamped, so the swap
  // that dropped the offset cannot hand it back.
  //
  // Pressed, not moving: the shadow mirrors a tweening target every frame,
  // so a position that agrees with the target is indistinguishable from a
  // thumb held there, and relaying it would stop the very tween that is
  // producing it.
  readonly property bool _thumbDriving: bar.pressed
  // The position Qt's drag produced, in through the shell's single writer.
  Connections {
    target: shadow
    function onContentYChanged() {
      root._writePosition(shadow.contentY)
    }
  }

  // Every other way the target moves - wheel, key, seat, follow, pursuit -
  // has to reach the shadow, or the thumb keeps a position the list left.
  Connections {
    target: root.flickable
    function onContentYChanged() {
      root._mirrorPosition()
    }
  }

  // A shared List owns its contentY through seatTo (the one programmatic
  // writer, which clamps against the measured table). A plain Flickable has
  // no such entry point, so the raw write stays as its fallback.
  function _writePosition(y) {
    const f = root.target
    if (!f) return
    // A position the target already shows is the mirror talking to itself,
    // whatever the thumb is doing.
    if (!root._thumbDriving || Math.abs(y - f.contentY) < 0.5) {
      root._mirrorPosition()
      return
    }
    // `via` names which writer took the drag result, because a list with
    // seatTo clamps it and a plain Flickable does not, and the two land on
    // different positions from the same thumb.
    if (typeof f.seatTo === "function") {
      f.seatTo(y, false, "scrollbar")
    } else {
      f.contentY = y
    }
    // seatTo clamps against the target's own bound, which can be tighter than
    // the shadow's range. Pull the shadow back to the value that landed, so
    // the thumb never shows a position the target refused.
    root._mirrorPosition()
  }

  // The shadow is a follower: the target's contentY is its truth, and the
  // 0.01 dead band is what stops the two edges from driving each other.
  function _mirrorPosition() {
    const f = root.target
    if (!f) return
    if (Math.abs(shadow.contentY - f.contentY) < 0.01) return
    const from = shadow.contentY
    shadow.contentY = f.contentY
    // Every way the list moves that is not a drag arrives here, so this is
    // the per-frame position stream for a wheel scroll, a seat or a
    // pursuit - and it is silent for a drag, which took bar.write above.
  }

  Component.onCompleted: {
    // The shadow's first read of the target, before anything is moving.
    _mirrorPosition()
  }
}
