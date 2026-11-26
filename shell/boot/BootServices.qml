pragma ComponentBehavior: Bound
import QtQml
import QtQuick
import qs.services
import qs.services as Services
import qs.features.lock

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

  // One row per owned id. The resolve closures are the former case bodies;
  // the other fields say whether the id has a readiness predicate or a
  // controller to release. Building the table touches no singleton, so a half
  // that has loaded but is not yet demanded stays inert.
  property var handlers: ({
    // The session lock is essential - a lock request and the shell's own
    // readiness verdict both wait on it - and its module set is small, so it
    // resolves here instead of with the feature half. Behind the feature half
    // it could not land until the menu, launcher, apps and picker sets had
    // compiled and the entrance had settled; here it lands when the services
    // do. `qs.features.lock` imports `qs.services` already, so this shares
    // that compile rather than repeating it in a fourth half.
    "lockscreen": {
      resolve: function() { void Lockscreen.locked },
      ready: null,
      teardown: null
    },
    // Timer, SystemUpdates, Connectivity and Tools are qualified because qs.services
    // shares those names with the bar's own modules and with QtQuick's
    // Timer; the qualified name is the one that cannot resolve to the wrong
    // type.
    "idleDaemon": {
      resolve: function() { void IdleDaemon.tag },
      ready: null,
      teardown: null
    },
    "inhibitor": {
      resolve: function() { void Inhibitor.tag },
      ready: null,
      teardown: null
    },
    "session": {
      resolve: function() { void Session.tag },
      ready: null,
      teardown: null
    },
    "privacy": {
      resolve: function() { void Privacy.tag },
      ready: null,
      teardown: null
    },
    "audio": {
      resolve: function() { void Audio.tag },
      ready: null,
      teardown: null
    },
    "mediaArt": {
      resolve: function() { void MediaArt.tag },
      ready: null,
      teardown: null
    },
    "keyboard": {
      resolve: function() { void Keyboard.tag },
      ready: null,
      teardown: null
    },
    "timer": {
      resolve: function() { void Services.Timer.tag },
      ready: null,
      teardown: null
    },
    "recording": {
      resolve: function() { void Recording.tag },
      ready: null,
      teardown: null
    },
    "update": {
      resolve: function() { void Update.tag },
      ready: null,
      teardown: null
    },
    "systemUpdates": {
      resolve: function() { void Services.SystemUpdates.tag },
      ready: null,
      teardown: null
    },
    "powerProfile": {
      resolve: function() { void PowerProfile.tag },
      ready: null,
      teardown: null
    },
    "printers": {
      resolve: function() { void Printers.tag },
      ready: null,
      teardown: null
    },
    "powerPolicy": {
      resolve: function() { void PowerPolicy.tag },
      ready: null,
      teardown: null
    },
    "batteryAlert": {
      resolve: function() { void BatteryAlert.tag },
      ready: null,
      teardown: null
    },
    "connectivity": {
      resolve: function() { void Services.Connectivity.tag },
      ready: null,
      teardown: null
    },
    "tools": {
      resolve: function() { void Services.Tools.tag },
      ready: null,
      teardown: null
    },
    "screenshots": {
      resolve: function() {
        void Screenshots.tag
        late._observeScreenshots()
      },
      ready: function() { return Screenshots._runtimeReady === true },
      teardown: null
    }
  })

  function handler(id) {
    return Object.prototype.hasOwnProperty.call(handlers, id) ? handlers[id] : null
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

  // An observation edge, attached when the unit is first resolved rather than
  // when this half is constructed: a Connections element evaluates `target` at
  // creation, so naming Screenshots here would instantiate the singleton
  // before its turn. Boot refreshes each unit right after resolve(), so the
  // initial state needs no connection; this only carries later transitions.
  function _observeScreenshots() {
    if (screenshotsConnection.target === null) screenshotsConnection.target = Screenshots
  }

  Connections {
    id: screenshotsConnection
    target: null
    function on_RuntimeReadyChanged() {
      if (late.boot) late.boot._refreshUnit("screenshots")
    }
  }
}
