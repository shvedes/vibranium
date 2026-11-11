import QtQml
import qs.common

// One surface's hold on the shared PlaybackClock.
//
// `wanted` is the whole policy: a surface says whether it is currently showing
// a moving position, and this object takes the hold when that becomes true and
// gives it back when it becomes false. Creation and destruction are the same
// two edges, so a surface torn down mid-hold cannot leave the clock ticking
// with nobody listening - the state a bare acquire() in a handler would leak.
//
// The hold is idempotent on purpose: a property that re-evaluates to its
// current value changes nothing, so no consumer has to guard its own writes.
QtObject {
  id: hold

  property bool wanted: false
  property bool _held: false

  // Read-only view of what this object actually holds. A consumer that wants
  // to know whether it is on the clock reads this rather than `wanted`, which
  // is only the wish.
  readonly property bool held: hold._held

  onWantedChanged: hold.sync()
  Component.onCompleted: hold.sync()
  Component.onDestruction: hold.release()

  function sync() {
    if (hold.wanted === hold._held) return
    if (hold.wanted) {
      hold._held = true
      PlaybackClock.acquire()
      return
    }
    hold.release()
  }

  function release() {
    if (!hold._held) return false
    hold._held = false
    return PlaybackClock.release()
  }
}
