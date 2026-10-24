pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// Generic chip / pill used inside text fields (launcher mode indicator,
// filter tags, etc). Extracted from the former AppLauncher ModeChip so
// InputField embeds it for the launcher's mode-chip presentation.
Rectangle {
  id: root

  property string text: ""
  // Optional themed icon (name in assets/icons, recolored through the live
  // palette); rendered left of the text, or alone when text is empty
  // (icon-only chip).
  property string iconName: ""
  property string iconColorKey: "foreground_1"
  property bool selected: false
  // Pill chrome (background + border + padding). Unboxed chips render as
  // bare inline content - icon/label only - for search-field mode
  // indicators that should read as part of the text, not a badge.
  property bool boxed: true

  // Icon squares up against the text's font height so it sits optically
  // centered with the label at any font size.
  readonly property real iconSize: label.implicitHeight + 2

  readonly property real contentW: iconName !== ""
    ? iconSize + (label.visible ? Ui.s : 0) + label.implicitWidth
    : label.implicitWidth

  implicitWidth: contentW > 0 ? contentW + (boxed ? 2 * Ui.s : 0) : 0
  implicitHeight: label.implicitHeight + 8
  radius: RoundingPolicy.radius
  color: root.boxed ? (root.selected ? Ui.tint("accent", 0.12) : Ui.tint("background_2", 1)) : "transparent"
  border.width: root.boxed ? 1 : 0
  border.color: root.selected ? Ui.tint("accent", 0.45) : Ui.tint("background_3", 1)

  Behavior on color { ColorAnim {} }
  Behavior on border.color { ColorAnim {} }

  Row {
    anchors.centerIn: parent
    spacing: Ui.s

    // Lefthand glyph: the library crossfade, trading opacity on
    // iconName flips while the slot holds iconSize throughout.
    CrossfadeIcon {
      name: root.iconName
      colorKey: root.iconColorKey
      size: root.iconSize
    }

    Text {
      id: label
      visible: root.text !== ""
      text: root.text
      color: root.selected ? Ui.tint("accent", 1) : Ui.tint("foreground_1", 0.75)
      font.pixelSize: Ui.fontM
      font.family: Ui.fontFamily
      font.bold: root.selected
      textFormat: Text.PlainText
    }
  }
}
