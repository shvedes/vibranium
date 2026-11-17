pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common

// One child entry inside a group row's inline dropdown: the compact form of the
// entries the group collects - the type's glyph, the label, and the control the
// type owns. A toggle is flipped in place by the group cursor (Entry) or by a
// click here; a row of another type renders as reference copy until the group
// grows a view for it.
//
// The widget is state-externalized like OptionRow: `checked` is bound by the
// owner and every activation reports back through picked(), so the store write
// that makes the state real stays in one place.
Rectangle {
  id: child

  required property var modelData
  required property int index

  // Group cursor position and the stored toggle state, owned by the row.
  property bool cursor: false
  property bool checked: false

  readonly property string label: child.modelData && child.modelData.label !== undefined
    ? String(child.modelData.label) : ""
  readonly property string iconName: child.modelData && typeof child.modelData.icon === "string"
    ? child.modelData.icon : ""
  readonly property bool isToggle: !!child.modelData && child.modelData.type === "toggle"

  signal picked()

  width: parent.width
  height: 28
  radius: RoundingPolicy.radius
  // Always transparent: the group's sliding cursor bar paints the selection
  // behind the rows, exactly as the select dropdown does.
  color: "transparent"

  Item {
    anchors.fill: parent
    anchors.leftMargin: Ui.m
    anchors.rightMargin: Ui.m

    // Behind the controls: the toggle above it keeps its own clicks, and every
    // other pixel of the row is still a hit target.
    MouseArea {
      anchors.fill: parent
      cursorShape: child.isToggle ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: child.picked()
    }

    Icon {
      id: glyph

      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      visible: child.iconName !== ""
      size: Ui.childIconW
      name: child.iconName
      colorKey: "foreground_0"
    }

    Text {
      id: label

      anchors.left: glyph.visible ? glyph.right : parent.left
      anchors.leftMargin: glyph.visible ? Ui.s : 0
      anchors.right: togglePill.visible ? togglePill.left : parent.right
      anchors.rightMargin: Ui.s
      anchors.verticalCenter: parent.verticalCenter
      text: child.label
      // The cursor is the hint this widget owns (the group paints its bar
      // behind the row); the stored state belongs to the pill.
      color: child.cursor ? Theme.color("foreground_0")
        : Ui.tint("foreground_1", 0.85)
      font.pixelSize: Ui.fontM
      font.family: Ui.fontFamily
      elide: Text.ElideRight
      textFormat: Text.PlainText

      Behavior on color {
        enabled: MotionPolicy.enabled
        ColorAnim {}
      }
    }

    Toggle {
      id: togglePill

      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: child.isToggle
      checked: child.checked
      animationsEnabled: MotionPolicy.enabled
      onToggled: child.picked()
    }
  }
}
