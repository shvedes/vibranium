pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import "../../common/math/Range.js" as Range

// One dropdown option line inside the select expansion. The stored choice
// is marked by painting its name in the accent, the same way a regular
// entry marks the active row, rather than by a bullet in a gutter of its
// own: the gutter was a second way of saying "this one", and it charged
// every option - chosen or not - the width to hold it. Cursor and chosen
// flags are owned by the entry row; clicks report back through picked().
Rectangle {
  id: opt

  // Payload {label, value} from the options list.
  required property var modelData
  required property int index

  // Dropdown cursor position and stored-choice match, owned by the row.
  property bool cursor: false
  property bool chosen: false

  // Reveal treatment mirroring Entry.textReveal: while the card grows,
  // the label paints whole and clipped (fading with the space it has)
  // instead of letting the ellipsis stutter in and out as the column
  // widens. Rests at 1, so an option that genuinely does not fit elides
  // exactly as before once the card is done moving.
  property bool settling: false
  readonly property real reveal: settling && optLabel.implicitWidth > 0
    ? Range.clamp01(midCol.width / optLabel.implicitWidth) : 1

  signal picked(var value)

  width: parent.width
  height: 28
  radius: RoundingPolicy.radius
  // Always transparent: the dropdown's sliding cursor bar (see Entry
  // optionsComp) paints the selection behind the rows. Per-row fades
  // flashed mid-tones the same way the entry crossfade did.
  color: "transparent"

  Item {
    anchors.fill: parent
    anchors.leftMargin: Ui.m
    anchors.rightMargin: Ui.m

    Column {
      id: midCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.rightMargin: 8
      anchors.verticalCenter: parent.verticalCenter
      spacing: 2

      Text {
        id: optLabel

        width: parent.width
        text: opt.modelData.label
        // Chosen is the stored value, so it is the one option already
        // applied - the same claim the entry row above makes with the
        // accent, which is why the cursor alone must not look like it.
        color: opt.chosen ? Theme.color("accent")
          : opt.cursor ? Theme.color("foreground_0")
          : Ui.tint("foreground_1", 0.85)
        font.pixelSize: Ui.fontM
        font.family: Ui.fontFamily
        elide: opt.reveal < 1 ? Text.ElideNone : Text.ElideRight
        clip: opt.reveal < 1
        opacity: opt.reveal
        textFormat: Text.PlainText

        // Vibrancy fades like the parent entry's value text, and now
        // carries the accent swap with it. Light to light only - never the
        // dark dip a background fade makes.
        Behavior on color {
          enabled: MotionPolicy.enabled
          ColorAnim {}
        }
      }
    }
  }

  MouseArea {

    anchors.fill: parent
    onClicked: opt.picked(opt.modelData.value)
  }
}
