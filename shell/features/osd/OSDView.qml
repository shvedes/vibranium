pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.common
import qs.features.osd
import "../../common/math/Range.js" as Range

// OSD surface. Passive, click-through, Overlay layer. The card hugs the
// screen edge named by `shell.osd.position` and sits `shell.osd.offset` px
// away from that same edge: top and bottom center it horizontally, left and
// right center it vertically and rotate it 90 degrees so the meter reads
// along the edge.
// The card body lives in OSDCard.qml. Session-lock surfaces render above
// all layer-shell windows, so this window stays unmapped while the session
// is locked (OSD.desktopSuppressed) and no OSD is shown over the lockscreen.
PanelWindow {
  id: win

  screen: Ui.primaryScreen ?? Quickshell.screens[0] ?? null
  // The mapping rule lives with the rest of the OSD's policy (OSD.qml):
  // a payload is up, including its exit fade, and the lock is not
  // suppressing the desktop surface.
  visible: OSD.surfaceVisible
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: -1
  anchors.top: true
  anchors.bottom: true
  anchors.left: true
  anchors.right: true

  mask: Region { width: 0; height: 0 }

  WlrLayershell.namespace: "vibranium:osd"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  // Placement: one slot owns the box the card occupies. A side placement
  // rotates the card, so the box swaps its sides (a 320px-wide card becomes
  // a 320px-tall strip); the card is centered in the box and rotates around
  // its own center, which leaves the two aligned. `offset` is measured from
  // the edge the card hugs, and the clamp keeps it on screen when the
  // offset is pushed past the opposite edge.
  readonly property int margin: 12
  readonly property bool vertical: OSD.vertical

  Item {
    id: slot
    width: win.vertical ? card.height : card.width
    height: win.vertical ? card.width : card.height
    readonly property real freeX: Math.max(0, win.width - slot.width)
    readonly property real freeY: Math.max(0, win.height - slot.height)
    // Top/bottom: offset from that edge, horizontally centered. Left/right:
    // offset from that edge, vertically centered.
    readonly property real preferredX: OSD.position === "right"
      ? slot.freeX - OSD.offset : OSD.offset
    readonly property real preferredY: OSD.position === "bottom"
      ? slot.freeY - OSD.offset : OSD.offset
    x: win.vertical
      ? Range.clamp(slot.preferredX, win.margin, Math.max(win.margin, slot.freeX - win.margin))
      : slot.freeX / 2
    y: win.vertical
      ? slot.freeY / 2
      : Range.clamp(slot.preferredY, win.margin, Math.max(win.margin, slot.freeY - win.margin))

    OSDCard {
      id: card
      // The card's width runs along the screen edge, so a side placement
      // caps it against the screen height instead of the width.
      maxWidth: Math.max(0, (win.vertical ? win.height : win.width) - 2 * win.margin)
      // Right reads top-to-bottom, left bottom-to-top: the glyphs face the
      // edge they sit on. Rotation of the reading, not of the geometry.
      rotation: !win.vertical ? 0 : (OSD.position === "right" ? 90 : -90)
      transformOrigin: Item.Center
      // The card turns, the icon does not: the label and meter follow the
      // edge, but a speaker or sun glyph has an upright orientation of its
      // own and would read as a tilt there.
      iconRotation: -card.rotation
      // A clockwise turn (right edge) sends the row's leading edge and the
      // meter's 0 mark to the top, so mirror the content there: the glyph
      // and the fill's origin both stay at the bottom of the vertical card.
      mirrored: win.vertical && OSD.position === "right"
      x: (slot.width - width) / 2
      y: (slot.height - height) / 2
    }
  }
}
