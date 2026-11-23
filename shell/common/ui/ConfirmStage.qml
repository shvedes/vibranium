pragma ComponentBehavior: Bound
import QtQuick

// Pure staged-confirm state shared by panels with in-flow delete/confirm
// slots. A panel owns its key namespace, the service calls and every view
// binding; this type only tracks which key is armed and how far its
// confirmation has advanced.
QtObject {
  id: confirm

  // null when closed. Panels pass the identity they key rows by (an int
  // index in the launcher, clipboard and power menu).
  property var key: null
  property int stage: 0

  readonly property bool open: confirm.key !== null
  readonly property bool armed: confirm.open && confirm.stage >= 1

  function isArmed(key) {
    return confirm.open && confirm.key === key
  }

  function arm(key) {
    confirm.key = key
    confirm.stage = 1
  }

  // The first advance past the armed hint reaches the threshold; the caller
  // runs the destructive action and closes the state.
  function advance(key) {
    if (!confirm.isArmed(key)) return false
    if (confirm.stage >= 2) return true
    confirm.stage++
    return false
  }

  function close() {
    confirm.key = null
    confirm.stage = 0
  }
}
