pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import "../math/Range.js" as Range

// Library-wide empty state: big background glyph over one line of muted
// copy. The bar-island pattern (ArchUpdatesIsland error/up-to-date
// overlays, menu warning rows): centered Column, 10px gap, 56px
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

  // `spacing` is inherited from Column and stays overridable per instance:
  // consumers migrating their own column set it to their old gap, everyone
  // else keeps the 10 baked in here.
  spacing: 10

  // Type and layout overrides for surfaces migrating their own icon+copy
  // column here. Every default is the original baked-in value, so existing
  // consumers keep their look without setting any of these.
  property bool italic: true
  property color textColor: Ui.tint("foreground_1", 0.4)
  // An Item-hosted column centres its children in the area it is stretched
  // over; a stretched Column top-aligns them. Set this when the state is
  // anchored to a body area and the pair must stay visually centred.
  property bool centerContent: false

  // The fillers are invisible by default, and Column skips invisible
  // children entirely, so the non-centred layout (and its implicit height)
  // is byte-for-byte the old one.
  property int _centredChildren: (root.centerContent ? 2 : 0)
    + (emptyIcon.visible ? 1 : 0) + (emptyText.visible ? 1 : 0)

  Item {
    id: topFiller
    width: 1
    visible: root.centerContent
    height: root.centerContent
      ? Math.max(0, (root.height
        - (emptyIcon.visible ? emptyIcon.height : 0)
        - (emptyText.visible ? emptyText.height : 0)
        - (root._centredChildren - 1) * root.spacing) / 2)
      : 0
  }

  Icon {
    id: emptyIcon

    anchors.horizontalCenter: parent.horizontalCenter
    name: root.iconName
    colorKey: root.iconColorKey
    accentKey: root.iconAccentKey
    size: root.iconSize
    opacity: root.iconOpacity
    visible: root.iconName !== ""
  }

  Text {
    id: emptyText

    anchors.horizontalCenter: parent.horizontalCenter
    width: Range.clamp(parent.width, 0, root.maxTextWidth)
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    // Icon-only states pass "": collapse so no trailing gap is left.
    visible: root.text !== ""
    text: root.text
    color: root.textColor
    font.pixelSize: root.textSize
    font.family: Ui.fontFamily
    font.italic: root.italic
    textFormat: Text.PlainText
  }

  Item {
    width: 1
    visible: root.centerContent
    height: root.centerContent ? topFiller.height : 0
  }
}
