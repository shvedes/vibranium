pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.common
import qs.features.launcher

// Launcher overlay: same architecture as MenuView - a dimming scrim on
// every screen, the card and exclusive keyboard focus on the primary one
// only. The panel tree is loader-gated: idle secondary screens hold no
// launcher tree; the primary keeps its panel attached for status().
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
      fraction: 0.6
      growthFraction: 0.85
    }

    // Keep the primary native surface after the boot entrance. The scrim
    // owns opacity and OverlayWindow releases its keyboard grab on close.
    // An empty input region also lets pointer input reach the desktop.
    visible: AppLauncher.visible || (win.primary && DesktopLayoutState.bootEntrancePlayed)
    mask: AppLauncher.visible ? null : closedInput
    overlayOpen: AppLauncher.visible
    primary: modelData === Ui.primaryScreen
    dim: Settings.menuDimBackground ? Settings.menuDimLevel : 0
    animateDimIn: true

    wlrNamespace: "vibranium:launcher"

    Region {
      id: closedInput
      width: 0
      height: 0
    }

    onCloseRequested: AppLauncher.close()

    Loader {
      anchors.fill: parent
      // The primary retains its panel across closes. Unloading on close
      // can race a surface teardown because the Loader deletes its items
      // later, after the underlying QQuickWindow has already gone.
      // Secondary windows only draw the scrim.
      active: win.primary
      sourceComponent: launcherPanelComp
    }

    Component {
      id: launcherPanelComp

      // Plain Item absorbs the Loader's explicit size; the panel keeps its
      // own width binding and centerIn anchor as a child.
      Item {
        id: panelVisual

        Connections {
          target: AppLauncher

          function onVisibleChanged() {
            openFade.stop()
            if (!AppLauncher.visible) return
            panelVisual.opacity = win.animationsEnabled ? 0 : 1
            if (win.animationsEnabled) openFade.start()
          }
        }

        Connections {
          target: win

          function onAnimationsEnabledChanged() {
            if (win.animationsEnabled) return
            openFade.stop()
            panelVisual.opacity = 1
          }
        }

        NumberAnimation {
          id: openFade
          target: panelVisual
          property: "opacity"
          to: 1
          duration: Ui.fastMs
          easing.type: Easing.OutCubic
        }

        // Halo follows the Drop shadow row, independent of the scrim.
        MenuOverlayShadow { host: card }

        LauncherPanel {
          id: card
          visible: win.primary
          maxHeight: ceiling.maxHeight
          hardMaxHeight: ceiling.hardMaxHeight
        }
      }
    }
  }
}
