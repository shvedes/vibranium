pragma ComponentBehavior: Bound

import QtQuick

// The one-shot reveal window: a name a pill otherwise keeps hidden is shown
// for a fixed span after an event, then hidden again.
//
// `pulse()` opens the window, or extends one already open; `active` is true
// while it runs and the timer ends it. A consumer wires `active` into what
// it reveals and owns nothing else about time - the bar modules drive a
// `Behavior on <slide>` from it, so a name glides out and back, and gate the
// slide on the name itself, so a window armed with nothing to show reveals
// nothing.
//
// Declared once rather than written per module because every copy carried
// its own number: two 3000s that agree by coincidence can only be retuned one
// module at a time. The span is readonly for the same reason - one window for
// every site, not a span per site.
Item {
  id: root

  readonly property int durationMs: 3000
  readonly property bool active: flashTimer.running

  // A reveal is an event, never a boot artifact, so the window refuses to open
  // until a settle span has passed since this instance was built. Every backend
  // reports its whole graph while it settles - BlueZ's device list,
  // NetworkManager's links - and the bar instantiates its modules before that
  // has finished, so "a device just connected" in the first seconds after the
  // shell comes up is the graph arriving rather than a connection anybody made.
  // The gate is time rather than state because neither backend publishes
  // readiness: there is no flag that says the list is complete.
  readonly property int settleMs: 3000

  property bool settled: false

  function pulse() {
    if (!root.settled) return
    flashTimer.restart()
  }

  // Ends the window early, for a site whose reveal stopped being true
  // before the span ran out.
  function clear() {
    flashTimer.stop()
  }

  Timer {
    id: settleTimer

    interval: root.settleMs
    running: true
    onTriggered: root.settled = true
  }

  Timer {
    id: flashTimer

    interval: root.durationMs
  }
}
