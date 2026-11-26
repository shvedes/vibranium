pragma ComponentBehavior: Bound
import QtQml
import QtQuick
import qs.services
import qs.services as Services
import qs.features.lock
import "generated/services" as Generated

// Services half of the late boot: the singleton set in qs.services, and
// nothing else.
//
// The late boot is three components because they are three different
// deadlines. The bar is the surface a boot is waiting on, the services are
// what its modules read, and the feature modules are neither. Each half
// imports only the module set it resolves, so a half's compile is its own
// set and not the union: a component's imports load their whole file sets
// before it is ready, and when the services shared the bar's half they made
// the bar wait for every service file to compile first. Measured on the boot
// hardware, qs.services + qs.features.bar costs about twice qs.features.bar
// alone, and that difference sat directly on the bar's path to screen.
//
// Boot.qml loads this half beside the resident bar control, both
// asynchronously, and adopts whichever lands first. The early service tier
// starts at the bar half's adoption (see Boot._adoptBarHalf); this half only
// answers the resolvers, so a demand that arrives before it lands is stashed
// for the replay like any other.
//
// Every case here is a type from qs.services, plus the session lock: it is an
// essential unit whose module is small and whose absence is what holds the
// shell's readiness, so it rides this half rather than the feature half. A
// unit whose type lives in any other feature module belongs in BootLate.qml,
// the bar is owned by Boot: resolve() answers false for an id
// it does not own, and Boot stashes that demand for the half that does.
Item {
  id: late

  // Boot, set at createObject time. Readiness refreshes go through it so the
  // gate bookkeeping stays in one place.
  property var boot: null

  // Generator-owned rows for every id this half owns. Constructed
  // synchronously in this provider's adoption turn and inert until a generated
  // id is demanded.
  property var generatedHandlers: Generated.ServicesHandlers { boot: boot }

  function handler(id) {
    if (Object.prototype.hasOwnProperty.call(generatedHandlers.handlers, id)) return generatedHandlers.handlers[id]
    return null
  }

  function resolve(id) {
    var row = handler(id)
    if (!row) return false
    row.resolve()
    return true
  }

  function readyState(id) {
    var row = handler(id)
    return row && row.ready ? row.ready() : false
  }
}
