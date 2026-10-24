pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.common
import qs.features.clipboard

// Clipboard overlay - scrim on every screen, panel on primary with preview.
// The panel tree is loader-gated: idle secondary screens hold no clipboard
// tree; the primary keeps its panel attached across open/close cycles.
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
      fraction: 0.72
      growthFraction: 0.92
    }

    visible: Clipboard.visible
    overlayOpen: Clipboard.open
    primary: modelData === Ui.primaryScreen
    dim: 0.45

    wlrNamespace: "vibranium:clipboard"

    onCloseRequested: Clipboard.close()

    Loader {
      anchors.fill: parent
      active: win.primary
      sourceComponent: clipboardPanelComp
    }

    Component {
      id: clipboardPanelComp

      // Plain Item absorbs the Loader's explicit size; the panel keeps its
      // own width binding and centerIn anchor as a child.
      Item {

        ClipboardPanel {
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
