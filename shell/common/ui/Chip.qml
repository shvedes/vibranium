pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// Generic chip / pill used inside text fields (launcher mode indicator,
// filter tags, etc). Extracted from the former AppLauncher ModeChip so
// InputField embeds it for the launcher's mode-chip presentation.
Rectangle {
  id: root

  property string text: ""
  // Palette key the chip's selected and tinted states ride. Empty keeps the
  // shell accent (the launcher's mode chip); the playlist's quality row names
  // one leaf per tier so a cap is recognisable before its label is read.
  property string colorKey: ""
  // Optional themed icon (name in assets/icons, recolored through the live
  // palette); rendered left of the text, or alone when text is empty
  // (icon-only chip).
  property string iconName: ""
  property string iconColorKey: "foreground_1"
  property bool selected: false
  // Type scale for the label (and, through it, the icon). Dense consumers -
  // the playlist's quality row - pass the small size so the chip reads as
  // chrome beside a section cap rather than as a button of its own.
  property int fontSize: Ui.fontM
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

  readonly property string accentKey: root.colorKey !== "" ? root.colorKey : "accent"

  implicitWidth: contentW > 0 ? contentW + (boxed ? 2 * Ui.s : 0) : 0
  implicitHeight: label.implicitHeight + 8
  radius: RoundingPolicy.radius
  color: root.boxed ? (root.selected ? Ui.tint(root.accentKey, 0.12)
    : root.colorKey !== "" ? Ui.tint(root.accentKey, 0.07)
    : Ui.tint("background_2", 1)) : "transparent"
  border.width: root.boxed ? 1 : 0
  border.color: root.selected ? Ui.tint(root.accentKey, 0.45)
    : root.colorKey !== "" ? Ui.tint(root.accentKey, 0.3)
    : Ui.tint("background_3", 1)

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
      color: root.selected ? Ui.tint(root.accentKey, 1)
        : root.colorKey !== "" ? Ui.tint(root.accentKey, 0.9)
        : Ui.tint("foreground_1", 0.75)
      font.pixelSize: root.fontSize
      font.family: Ui.fontFamily
      font.bold: root.selected
      textFormat: Text.PlainText
    }
  }
}
