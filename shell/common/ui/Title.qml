pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// Title levels shared by islands, menus and panels.
// Replaces hardcoded Text blocks that duplicated the same font/color
// tokens in every island (Wi-Fi/Bluetooth headers, section caps, row
// titles). Level chooses the canonical Ui/Theme pairing; callers may
// override color/bold/letterSpacing when a row state (connected, failed)
// demands it.
Text {
  id: root

  // 1: Island header (Wi-Fi, Bluetooth) - Ui.fontM bold, foreground_0
  // 2: Section cap (PAIRED/AVAILABLE/KNOWN) - Ui.fontXs bold caps, 1.2 ls, muted
  // 3: Row primary (device/ssid) - Ui.fontS, bold toggled by caller
  // 4: Row secondary / subtitle / hint - Ui.fontXs muted 0.5
  // 5: Body / empty hint - Ui.fontS muted 0.5
  property int level: 1

  property bool isSection: root.level === 2
  property bool isIsland: root.level === 1

  color: {
    if (root.level === 1) return Ui.solid("foreground_0")
    if (root.level === 2) return Ui.tint("foreground_1", 0.5)
    if (root.level === 3) return Ui.solid("foreground_1")
    if (root.level === 4) return Ui.tint("foreground_1", 0.5)
    return Ui.tint("foreground_1", 0.5)
  }
  font.family: Ui.fontFamily
  font.pixelSize: {
    if (root.level === 1) return Ui.fontM
    if (root.level === 2) return Ui.fontXs
    if (root.level === 3) return Ui.fontS
    if (root.level === 4) return Ui.fontXs
    return Ui.fontS
  }
  font.bold: root.level === 1 || root.level === 2
  font.letterSpacing: root.level === 2 ? 1.2 : 0
  font.capitalization: Font.MixedCase
  elide: Text.ElideRight
  textFormat: Text.PlainText
  wrapMode: Text.NoWrap

  // Optical centering: a single-line Text box reserves the font's full
  // descent even when the string carries none (digits, caps, "us",
  // "72°F"), so geometrically centering the box parks cap-height glyphs
  // ~1px high next to icons whose canvas is truly centered. Nudging the
  // vertical-center anchor down by ~8% of the pixel size puts the cap
  // height on the module middle. Only applies where callers anchor the
  // vertical center; top/baseline/Row layouts ignore it.
  anchors.verticalCenterOffset: Math.round(font.pixelSize * 0.08)
}
