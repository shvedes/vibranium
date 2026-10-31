pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common

// Tinted notice box for inline cautions and validation errors: translucent
// fill, matching border, centered wrapped message. Height collapses to zero
// when there is no message so the box slots into Columns without layout
// jumps.
//
// tone "warning": yellow cautionary fill (settings warnings)
// tone "danger":  red fill (editor validation errors)
//
// markup=true switches to StyledText for declarative copy carrying the
// whitelisted inline tags (<b>/<i>/<u>, \n breaks via MenuLib.styledMarkup);
// plain by default so runtime strings never parse as markup.
Rectangle {
  id: root

  property string message: ""
  property string tone: "warning"
  property bool markup: false

  readonly property bool danger: root.tone === "danger"

  implicitWidth: 200
  height: visible ? label.height + 20 : 0
  visible: root.message !== ""
  radius: RoundingPolicy.radius
  // Ui.tint resolves to transparent until the palette lands.
  color: Ui.tint(root.danger ? "red" : "yellow", 0.12)
  border.width: 1
  border.color: Ui.tint(root.danger ? "red" : "yellow", 0.5)

  Text {
    id: label

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.margins: 10
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    text: root.message
    color: Ui.tint(root.danger ? "red" : "yellow", 1)
    font.pixelSize: Ui.fontS
    font.family: Ui.fontFamily
    textFormat: root.markup ? Text.StyledText : Text.PlainText
  }
}
