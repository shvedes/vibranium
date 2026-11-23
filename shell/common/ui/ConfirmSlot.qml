pragma ComponentBehavior: Bound
import QtQuick
import qs.common

// Drop-in staged confirmation slot: hint -> armed -> confirmed.
// Panels track stage externally and confirm through their key sink; this is
// pure view with no pointer target of its own.
//
// PLACEMENT is owned here, not by each host. A confirm either hangs off a row
// line (owns its lead and its trailing gap) or is a view inside another
// DropdownSlot, in which case the host slot owns both. Hosts set `lead` and
// `embedded`; no host has to know how DropdownSlot splits topGap, gap and
// anchor margins. The lead is an ANCHOR margin so the row's own bottom
// padding is never counted twice - a topGap inside the slot's height was the
// original reason the button sat far above the bar's lower edge.
DropdownSlot {
  id: root

  property int stage: 0
  property string confirmText: "Delete"
  property string hintText: "Press Delete to remove"
  property string armedText: "<b><u>Press again to confirm</u></b>"

  // Space between the row (or the slot above) and the hint text.
  property real lead: Ui.m
  // True when a host DropdownSlot wraps this body: its trailing gap is the
  // one the bar and the neighbour push read, so this body adds none.
  property bool embedded: false

  anchors.topMargin: root.lead
  topGap: 0
  gap: root.embedded ? 0 : Ui.m

  signal confirmed()
  // Declared and never raised by the component; ui-rest's probe connects
  // onCancelled and pins the count at zero. A consumer that wires it hangs
  // silently, so the empty surface stays until something emits it.
  signal cancelled()

  Column {
    x: Ui.m
    width: parent.width - 2 * Ui.m
    spacing: Ui.s

    Text {
      width: parent.width
      text: root.stage >= 2 ? root.armedText : root.hintText
      color: Ui.tint("foreground_1", 0.6)
      font.pixelSize: Ui.fontXs
      font.family: Ui.fontFamily
      textFormat: Text.StyledText
      wrapMode: Text.WordWrap
    }

    Rectangle {
      width: parent.width
      height: Ui.buttonHeight
      radius: RoundingPolicy.radius
      color: root.stage >= 2 ? Theme.color("red") : "transparent"
      border.width: 1
      border.color: root.stage >= 2 ? Theme.color("red") : Ui.tint("red", 0.45)
      Behavior on color { ColorAnim {} }
      Behavior on border.color { ColorAnim {} }

      Text {
        anchors.centerIn: parent
        text: root.confirmText
        color: root.stage >= 2 ? Theme.color("background_0") : Theme.color("red")
        font.pixelSize: Ui.fontS
        font.family: Ui.fontFamily
        font.bold: root.stage >= 2
        textFormat: Text.PlainText
        Behavior on color { ColorAnim {} }
      }
    }
  }
}
