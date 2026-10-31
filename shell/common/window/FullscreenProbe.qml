pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import Quickshell.Hyprland

// Whether a fullscreen surface owns a workspace, read from the compositor
// rather than re-derived per feature.
//
// The OSD hides itself, and the bar's move-window gesture suppresses its
// idle strip - two features that must agree, and each of which had written
// the walk itself. `anyActive` is the first; `screenActive` is the second,
// which asks about one named output instead of the whole session.
//
// The check is `hasFullscreen === true` and not a truthiness test on
// purpose: a Quickshell build without workspace fullscreen tracking leaves
// the field undefined, and an undefined field has to read as "nothing is
// fullscreen" so a feature that hides on it stays visible.
Singleton {
  id: root

  readonly property var _monitors: Hyprland.monitors ? Hyprland.monitors.values ?? [] : []

  // True while any monitor's active workspace carries a fullscreen surface.
  readonly property bool anyActive: root._fullscreenAmong(root._monitors, null)

  // The same question about one output. An empty or unknown name is
  // answered false rather than falling back to the session-wide answer: a
  // caller asking about a screen it has lost is asking because the screen
  // is gone.
  function screenActive(name) {
    if (!name) return false
    return root._fullscreenAmong(root._monitors, String(name))
  }

  function _fullscreenAmong(monitors, wanted) {
    for (let i = 0; i < monitors.length; i++) {
      if (wanted !== null && monitors[i].name !== wanted) continue
      const ws = monitors[i].activeWorkspace
      if (ws && ws.hasFullscreen === true) return true
    }
    return false
  }
}
