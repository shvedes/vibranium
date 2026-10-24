pragma ComponentBehavior: Bound

import QtQuick
import qs.services
import qs.common
import qs.features.bar

// Keyboard layout indicator: the active layout as a lowercased two-letter
// code ("us", "de", "ru"). The code is the only display form - there is no
// emoji/flag option. Clicking switches layouts; the label updates in
// place, without any roll animation. Reads the shared Keyboard singleton
// (hyprland request socket at boot, activelayout events after), so
// switching layouts updates instantly and there is no second socket or
// process here.
CollapsibleSlot {
  id: root

  // "English (US)" -> "us", "Russian" -> "ru"; a bare code from an
  // activelayout event ("us") passes through unchanged.
  readonly property string label: {
    const l = String(Keyboard.layout ?? "").trim()
    if (l === "") return ""
    const m = l.match(/\(([^)]+)\)/)
    const code = m ? m[1] : l.slice(0, 2)
    return code.toLowerCase()
  }

  // Collapsible slot (see CollapsibleSlot.qml). Bar.slotInset per side
  // (not the fixed sidePad): the zone row has zero gap and an icon-only
  // slot keeps (slot - canvas) / 2 of air at each edge, so the text module
  // boxes itself with the same inset and keeps the conventional
  // inter-module spacing at any bar scale. The slide also carries the idle
  // collapse: the socket has named no layout yet, and a slot holding
  // nothing but two insets is a hole in the bar, so the empty module has to
  // collapse away. clip
  // keeps the centered glyph inside the shrinking box, so the label is
  // revealed from its own centre rather than sliding off an edge.
  collapseShown: root.label !== ""
  collapseFull: glyph.implicitWidth + Bar.slotInset * 2

  // The code label, centered in the slot exactly like the other bar
  // modules' content.
  Title {
    id: glyph
    level: 1
    anchors.centerIn: parent
    text: root.label
    font.bold: false
    font.pixelSize: Math.round(Ui.fontM * root.textScale)
  }

  // Both buttons run through the click contract, so
  // shell.statusbar.keyboardLayoutLeftClick / ...RightClick win over the
  // defaults. The compositor command stays the fallback: an undeclared key
  // resolves to "", and an empty click command must not leave the button
  // inert.
  fillButtons: Qt.LeftButton | Qt.RightButton
  onClicked: mouse => {
    if (mouse.button === Qt.LeftButton) {
      root.clickCommand("leftClick", "hyprctl switchxkblayout current next")
      return
    }
    if (mouse.button === Qt.RightButton) {
      root.clickCommand("rightClick", "hyprctl switchxkblayout current prev")
    }
  }
}
