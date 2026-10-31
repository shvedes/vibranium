pragma Singleton

import QtQuick
import Quickshell

// A Quickshell screen and the Qt screen a `Window` wants are different types,
// and assigning one to the other is refused at runtime rather than converted:
//
//   Unable to assign QuickshellScreenInfo to QQuickScreenInfo
//
// which means `Window.screen` is left unset and the compositor picks the
// output. The two are the same output seen through two type systems -
// `Quickshell.screens` yields `QuickshellScreenInfo`, `Qt.application.screens`
// yields `QQuickScreenInfo` - so the only translation needed is the output's
// name, and the pair is matched on it.
//
// `forScreen` returning null is a real answer, not a failure: a screen the Qt
// side does not know yet, or one that has just gone away, leaves the window
// without an explicit screen, which is what the compositor would have chosen
// anyway.
Singleton {
  id: root

  readonly property string tag: "windowScreen"

  // qmllint disable missing-property
  // `Qt.application.screens` is a QQuickScreenInfo list. The installed
  // builtins.qmltypes types `Qt.application` with a subset of its real members
  // - `state` and `screens` are both missing from it - so this line is a
  // description gap in the linter, not a bad read.
  readonly property var screens: Qt.application.screens
  // qmllint enable missing-property

  // The Qt screen carrying `info`'s name, or null.
  function forScreen(info) {
    if (info === null || info === undefined) return null
    const list = root.screens
    if (list === null || list === undefined) return null
    for (let i = 0; i < list.length; i++) {
      if (String(list[i].name) === String(info.name)) return list[i]
    }
    return null
  }
}