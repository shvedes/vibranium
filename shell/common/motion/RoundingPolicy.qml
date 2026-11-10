pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.common
import "../math/Range.js" as Range

Singleton {
  id: root

  // Hypr rounding in px. QS caps at 16: the compositor allows more,
  // but larger corners read wrong on dense shell chrome.
  readonly property int targetRadius: {
    const raw = HyprlandSettings.value("hypr.decoration.rounding")
    const n = Number(raw)
    if (!isFinite(n))
      return 0
    return Range.clamp(Math.round(n), 0, 16)
  }

  // Public value every surface binds. Eases toward the target rather
  // than swapping in one frame, gated on the same global switch as
  // every other tween in the shell.
  property int radius: root.targetRadius
  Behavior on radius {
    enabled: MotionPolicy.enabled
    NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
  }
}
