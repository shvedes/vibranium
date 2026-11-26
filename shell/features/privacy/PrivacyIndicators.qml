pragma ComponentBehavior: Bound

import QtQuick
import QtQml
import Quickshell
import qs.common

// One capture-dot surface per real output. This lives beside the privacy unit
// rather than inside the bar runtime: a bar disable, a hide override or a bar
// reload cannot take the indicators off screen.
Item {
  id: root

  Variants {
    model: Ui.validScreens
    delegate: PrivacyOverlay {
      required property ShellScreen modelData
      winScreen: modelData
    }
  }
}
