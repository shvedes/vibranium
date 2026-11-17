pragma ComponentBehavior: Bound
import QtQml
import qs.common

// A component's single point of contact with a boot milestone. A gate owns the
// milestone watch and the late-built fallback a deferred action would
// otherwise wire by hand, and it is a child of its consumer: the watch dies
// with that consumer, so a pending action cannot fire into an object torn
// down before the milestone arrives.
//
// Two ways to use it. Bind `onFire` for work that must run once after the
// motion has finished drawing. Read `ready` where an early demand has to be
// parked instead of a callback being deferred.
QtObject {
  id: gate

  // Which milestone to follow: "construction", "settled" or "played".
  property string until: "played"

  readonly property bool ready: gate.until === "construction"
    ? DesktopLayoutState.bootConstructionSettled
    : gate.until === "settled"
      ? DesktopLayoutState.bootEntranceSettled
      : DesktopLayoutState.bootEntrancePlayed

  signal fire()

  property bool _fired: false
  function _maybeFire() {
    if (gate._fired || !gate.ready) return
    gate._fired = true
    gate.fire()
  }

  // A plain QtObject declares its non-visual children through an explicit
  // default property; the milestone watch is owned by this gate and dies with
  // it.
  default property list<QtObject> _owned: [
    Connections {
      target: DesktopLayoutState

      function onBootConstructionSettledChanged() { gate._maybeFire() }
      function onBootEntranceSettledChanged() { gate._maybeFire() }
      function onBootEntrancePlayedChanged() { gate._maybeFire() }
    }
  ]

  Component.onCompleted: {
    // The Connections above only carry transitions. A consumer built after its
    // milestone has passed gets its one fire on the next turn instead.
    if (gate.ready) Qt.callLater(gate._maybeFire)
  }
}
