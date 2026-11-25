pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// Shared scrim window - the common layer surface for menu, launcher, power,
// clipboard, wallpaper picker and pass. The anchors, the ignoring exclusion
// mode and the transparent color come from LayerSurface; the close-fade and the
// dim live here, so every overlay shares one timing.
//
// It declares no namespace and no layer of its own: OverlayWindow sets both for
// the whole family through `surface`, which is the registry key.
LayerSurface {
  id: root

  property real dim: 0.45
  property bool overlayOpen: false
  property bool isPrimary: false
  property bool animateDimIn: false
  property bool animationsEnabled: true

  signal closeRequested()

  default property alias content: container.data

  onOverlayOpenChanged: {
    scrimFade.enabled = root.animationsEnabled && !root.overlayOpen
    dimFade.stop()
    if (!root.overlayOpen) return

    if (root.animateDimIn && root.animationsEnabled && root.dim > 0) {
      scrim.dimProgress = 0
      dimFade.restart()
    } else {
      scrim.dimProgress = 1
    }
  }

  onAnimationsEnabledChanged: {
    if (root.animationsEnabled) return
    dimFade.stop()
    scrim.dimProgress = 1
  }

  Item {
    anchors.fill: parent
    opacity: root.overlayOpen ? 1 : 0
    // Snap the parent on open so the card and dim can animate independently.
    // The signal handler disables the Behavior before the opacity binding
    // updates; a second binding can read the previous state.
    Behavior on opacity {
      id: scrimFade
      enabled: false
      NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
    }

    Rectangle {
      id: scrim
      anchors.fill: parent
      color: "#000000"
      property real dimProgress: 1
      opacity: root.dim * scrim.dimProgress

      NumberAnimation {
        id: dimFade
        target: scrim
        property: "dimProgress"
        to: 1
        duration: Ui.fastMs
        easing.type: Easing.OutCubic
      }
    }

    MouseArea {
      anchors.fill: parent
      enabled: root.isPrimary
      onClicked: root.closeRequested()
    }

    Item {
      id: container
      anchors.fill: parent
    }
  }
}
