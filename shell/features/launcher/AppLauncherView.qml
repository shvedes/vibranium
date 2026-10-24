pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
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

    visible: AppLauncher.visible
    overlayOpen: AppLauncher.visible
    primary: modelData === Ui.primaryScreen
    dim: 0.45

    wlrNamespace: "vibranium:launcher"

    onCloseRequested: AppLauncher.close()

    Loader {
      anchors.fill: parent
      // Panels stay loaded across closes, exactly like MenuView: hiding the
      // window keeps the tree attached, so no item is ever destroyed against
      // a dead surface. Unloading here would race the hide - Loader
      // unload is deferred (deleteLater) while the hide tears the native
      // surface down, and the deferred deletes then landed in
      // QQuickItemPrivate::derefWindow on a dangling window (SIGSEGV after
      // close, usually when event-loop load delayed the deletes past the
      // surface death). Secondary screens hold no panel tree at all (no
      // `|| AppLauncher.visible` tail): building one per open only to tear
      // it down on the matching close is the same race on every other
      // output. The controller still unloads in closeSettle; its
      // children hold no windows, so that cascade is safe.
      active: win.primary
      sourceComponent: launcherPanelComp
    }

    Component {
      id: launcherPanelComp

      // Plain Item absorbs the Loader's explicit size; the panel keeps its
      // own width binding and centerIn anchor as a child.
      Item {

      LauncherPanel {
        visible: win.primary
        maxHeight: ceiling.maxHeight
        hardMaxHeight: ceiling.hardMaxHeight
      }
      }
    }
  }
}
