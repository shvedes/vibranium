pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// The dark glass pill shared by the full-screen pickers' captions and footer
// legends: a stronger-than-scrim black fill, a hairline light border and a
// centred white label. The deck behind these labels is a dimmed desktop, so
// a palette foreground on it vanishes on a light theme; this island is
// theme-independent by construction.
//
// The recipe lives here instead of at each call site: implicit size is the
// label plus Ui.l / Ui.s on either side, the corners cap at half the height
// so short pills are fully round, and the caller only chooses the copy, the
// typography and the width ceiling its layout allows. The look properties are
// pass-throughs to the one label, so a pill reads as the Text it replaces.
Rectangle {
  id: root

  // Text, typography and elide pass-throughs. An unset alias leaves the
  // label's own default in place (white, Ui.fontL, the system font).
  property alias text: label.text
  property alias textColor: label.color
  property alias fontPixelSize: label.font.pixelSize
  property alias fontFamily: label.font.family
  property alias bold: label.font.bold
  property alias elide: label.elide
  property alias textFormat: label.textFormat
  // The styled footer can reach the label for the one-off that does not
  // deserve a public property; the named API above is the normal route.
  property alias content: label

  // Screen-reader name. KeyHint.plain() supplies this for a styled legend,
  // so the keys are read rather than the color tags around them.
  property string accessibleName: ""
  // Width ceiling from the surrounding layout; the default keeps a pill at
  // its natural width. Callers pass parent.width or their own available run.
  property real maxWidth: 1e9

  implicitWidth: label.implicitWidth + Ui.l * 2
  implicitHeight: label.implicitHeight + Ui.s * 2
  width: Math.min(implicitWidth, maxWidth)
  height: implicitHeight

  radius: Math.min(RoundingPolicy.radius, Math.round(height / 2))
  color: Qt.rgba(0, 0, 0, 0.62)
  border.width: 1
  border.color: Qt.rgba(1, 1, 1, 0.18)

  Accessible.role: Accessible.StaticText
  Accessible.name: root.accessibleName

  Text {
    id: label

    anchors.centerIn: parent
    width: Math.min(implicitWidth, Math.max(0, parent.width - Ui.l * 2))
    horizontalAlignment: Text.AlignHCenter
    text: ""
    color: "#ffffff"
    font.pixelSize: Ui.fontL
    font.family: Ui.fontFamily
  }
}
