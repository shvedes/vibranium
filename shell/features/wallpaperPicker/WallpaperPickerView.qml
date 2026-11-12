pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.common
import qs.features.wallpaperPicker

// Wallpaper picker overlay. Every screen gets the dimming scrim; the panel
// loader's `active` is bound to `win.primary` alone, so the picker tree is
// built on the primary screen only, where it stays attached across
// open/close cycles -> that attached panel is what status() reads.
//
// The panel fills the surface: the deck is a horizontal cascade that needs the
// screen's width, not a card-shaped box, and the dim behind it is the whole
// point of the overlay.
Variants {
  model: Ui.validScreens
  OverlayWindow {
    id: win
    required property ShellScreen modelData

    screen: modelData

    // The deck's share of THIS screen, owned by the shared ceiling so the
    // reason lives in one place. See ScreenCeiling.
    ScreenCeiling {
      id: ceiling
      screen: win.modelData
      fraction: 0.72
      growthFraction: 0.92
    }

    visible: WallpaperPicker.visible
    overlayOpen: WallpaperPicker.isOpen
    primary: modelData === Ui.primaryScreen
    dim: 0.55
    wlrNamespace: "vibranium:wallpaper-picker"
    onCloseRequested: WallpaperPicker.close()

    Loader {
      anchors.fill: parent
      active: win.primary
      sourceComponent: wallpaperPickerPanelComp
    }

    Component {
      id: wallpaperPickerPanelComp

      WallpaperPickerPanel {
        anchors.fill: parent
        visible: win.primary
        // The screen, not this window: the window is the surface the deck is
        // painted on, so its height is the screen's and never a number this
        // panel's own size feeds back into.
        maxHeight: ceiling.maxHeight
        hardMaxHeight: ceiling.hardMaxHeight
      }
    }
  }
}
