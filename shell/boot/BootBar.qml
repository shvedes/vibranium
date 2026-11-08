pragma ComponentBehavior: Bound
import QtQml
import QtQuick
import qs.features.bar

// Bar half of the late boot: the bar surface, and nothing else.
//
// The late boot is three components because they are three different
// deadlines. The bar is the surface a boot is waiting on, the services are
// what its modules read, and the feature modules are neither. Each half
// imports only the module set it resolves, so a half's compile is its own
// set and not the union: a component's imports load their whole file sets
// before it is ready, which is why the services (BootServices.qml) and the
// feature modules (BootLate.qml) live beside this file instead of in it.
// Measured on the boot hardware, the union cost about twice this set, and
// that difference sat directly on the bar's path to screen.
//
// Boot.qml loads all three in the same turn, asynchronously, and adopts each
// as it lands. The bar's demand and the early service tier belong to this half
// (see Boot._adoptBarHalf); the drain still waits for the feature half,
// because the entrance and deferred queues resolve types that live there.
//
// Every case here is a type from qs.features.bar. A service belongs in
// BootServices.qml and a feature module in BootLate.qml: resolve() answers
// false for an id it does not own, and Boot stashes that demand for the half
// that does.
Item {
  id: late

  // Boot, set at createObject time. Readiness refreshes go through it so the
  // gate bookkeeping stays in one place.
  property var boot: null

  function resolve(id) {
    switch (id) {
      // The bar is here for its import set, not its timing: Bar.qml imports
      // the whole module registry, and a module import compiles its file set
      // before anything paints. Loading it with an async half keeps that
      // compile off the UI thread and lets the wallpaper map on the first
      // frame (see Boot._bootVisuals).
      case "bar": void Bar.tag; break
      default:    return false
    }
    return true
  }

  // No unit in this half reports a readiness edge of its own; the bar unit
  // settles on its dependencies like any other resident surface.
  function readyState(id) {
    switch (id) {
      default: return false
    }
  }

  // No unit in this half splits into a resident facade and a controller that
  // has to be released, so there is no teardown to dispatch.
  function teardown(id) {
    switch (id) {
      default: break
    }
  }
}
