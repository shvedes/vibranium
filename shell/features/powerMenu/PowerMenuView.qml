pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.common
import qs.features.powerMenu

// Power menu overlay - same scrim + exclusive focus pattern as
// AppLauncher/MenuView. Every screen gets the dimming scrim; the panel
// loader's `active` is bound to `win.primary` alone, so the panel tree is
// built on the primary screen only, where it stays resident across
// open/close cycles -> that resident panel is what status() reads.
Variants {
  model: Ui.validScreens

  OverlayWindow {
    id: win

    required property ShellScreen modelData
    screen: modelData
    // The card's share of THIS screen, owned by the shared ceiling so
    // the reason lives in one place. See ScreenCeiling.
    ScreenCeiling {
      id: ceiling
      screen: win.modelData
      fraction: 0.5
      growthFraction: 0.8
    }

    visible: PowerMenu.visible
    overlayOpen: PowerMenu.visible
    primary: modelData === Ui.primaryScreen
    dim: 0.45

    wlrNamespace: "vibranium:power"

    onCloseRequested: PowerMenu.close()

    Loader {
      anchors.fill: parent
      active: win.primary
      sourceComponent: powerMenuPanelComp
    }

    Component {
      id: powerMenuPanelComp

      // Plain Item absorbs the Loader's explicit size; the panel keeps its
      // own width binding and centerIn anchor as a child.
      Item {

        PowerMenuPanel {
          visible: win.primary
          // The screen, not this window: the window is sized from the card, so
          // its height resolves in stages under a card that has already been
          // built. The screen is the same number from the first frame and never
          // changes.
          maxHeight: ceiling.maxHeight
          hardMaxHeight: ceiling.hardMaxHeight
        }
      }
    }
  }
}
