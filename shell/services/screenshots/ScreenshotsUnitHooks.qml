import QtQml
import qs.services

// Authored hooks for the screenshots unit: the resolution touch and the
// readiness predicate from BootServices.qml, plus the late observation edge.
//
// The Connections element has a null target at construction. Naming
// Screenshots here would instantiate the singleton before its turn, so the
// target is attached only when resolve() runs; Boot refreshes the unit right
// after resolution, so this only carries later transitions.
QtObject {
  id: root

  // Boot, set at createObject time. Readiness refreshes go through it so the
  // gate bookkeeping stays in one place.
  property var boot: null

  function resolve() {
    void Screenshots.tag
    _observeScreenshots()
  }

  function _observeScreenshots() {
    if (screenshotsConnection.target === null) screenshotsConnection.target = Screenshots
  }

  function ready() { return Screenshots._runtimeReady === true }

  // Declared as a typed property rather than a child: QtObject has no default
  // child property, so this is the way to own a Connections element here.
  property Connections screenshotsConnection: Connections {
    target: null
    function on_RuntimeReadyChanged() {
      if (root.boot) root.boot._refreshUnit("screenshots")
    }
  }
}
