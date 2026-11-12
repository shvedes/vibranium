pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import "../math/Range.js" as Range

// Library-wide empty state: big background glyph over one line of muted
// copy. The bar-island pattern (ArchUpdatesIsland error/up-to-date
// overlays, PassPanel package warning): centered Column, 10px gap, 56px
// glyph, muted text below. Menus show it for filter/search with no hits;
// the glyph names the mode (filter-x vs search-alert, two-tone with a red
// indicator), with per-surface overrides (ThemePicker palette,
// clipboard-check with a green indicator, wallpapers image as-is).
Column {
  id: root

  property string iconName: ""
  property string iconColorKey: "foreground_1"
  property string iconAccentKey: ""
  property real iconSize: 56
  // Opt-in type size for surfaces that need a louder empty state. The default
  // stays the dense-list hint size every menu and panel already uses.
  property real textSize: Ui.fontS
  property real maxTextWidth: 320
  // Dimmed to the copy tone below: the glyph reads as a background mark,
  // not a live row icon. Opacity (not a second palette key) so body and
  // two-tone indicator dim together.
  property real iconOpacity: 0.4
  property string text: "No matches"

  spacing: 10

  Icon {
    anchors.horizontalCenter: parent.horizontalCenter
    name: root.iconName
    colorKey: root.iconColorKey
    accentKey: root.iconAccentKey
    size: root.iconSize
    opacity: root.iconOpacity
    visible: root.iconName !== ""
  }

  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    width: Range.clamp(parent.width, 0, root.maxTextWidth)
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    // Icon-only states pass "": collapse so no trailing gap is left.
    visible: root.text !== ""
    text: root.text
    color: Ui.tint("foreground_1", 0.4)
    font.pixelSize: root.textSize
    font.family: Ui.fontFamily
    font.italic: true
    textFormat: Text.PlainText
  }
}
