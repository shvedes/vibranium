pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.features.menu
import qs.common

// Menu overlay: every screen gets a dimming scrim at the
// compositor-independent Quickshell level, the primary screen alone hosts
// the panel and grabs exclusive keyboard focus while the menu is up.
// The panel tree is loader-gated: idle secondary screens hold no menu
// tree; the primary keeps its panel alive so the probe panel
// contract survives across open/close cycles.
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
      fraction: 0.7
      growthFraction: 0.92
    }

    visible: Menu.visible
    overlayOpen: Menu.open
    primary: modelData === Ui.primaryScreen
    dim: 0.45

    wlrNamespace: "vibranium:menu"

    onCloseRequested: Menu.close()

    Loader {
      anchors.fill: parent
      active: win.primary
      sourceComponent: menuPanelComp
    }

    Component {
      id: menuPanelComp

      // The Loader explicitly sizes its loaded root, which would stomp the
      // panel's width binding and its centerIn anchor. A plain Item takes
      // the Loader's size; the panel keeps its own sizing as a child.
      Item {

        MenuPanel {
          id: panel

          visible: win.primary
          // The screen, not this window: the window is sized from the card,
          // so its height resolves in stages under a card that has already
          // been built, and the placeholder that covers the first frame is
          // not the number the real one turns out to be. The screen is the
          // same number from the first frame and never changes.
          maxHeight: ceiling.maxHeight
          hardMaxHeight: ceiling.hardMaxHeight

          Component.onCompleted: {
            if (win.primary) Menu.probeSource = panel
          }
        }
      }
    }
  }
}
