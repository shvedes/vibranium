pragma ComponentBehavior: Bound
import QtQml
import QtQuick
import qs.services
import qs.services as Services

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
// Boot.qml loads this half and BootBar.qml in the same turn, both
// asynchronously, and adopts whichever lands first. The early service tier
// starts at the bar half's adoption (see Boot._adoptBarHalf); this half only
// answers the resolvers, so a demand that arrives before it lands is stashed
// for the replay like any other.
//
// Every case here is a type from qs.services. A unit whose type lives in a
// feature module belongs in BootLate.qml, and the bar itself belongs in
// BootBar.qml: resolve() answers false for an id it does not own, and Boot
// stashes that demand for the half that does.
Item {
  id: late

  // Boot, set at createObject time. Readiness refreshes go through it so the
  // gate bookkeeping stays in one place.
  property var boot: null

  function resolve(id) {
    switch (id) {
      // Timer, MediaEvents, ArchUpdates and Connectivity are prefixed
      // because qs.services shares those names with the bar's own modules and
      // with QtQuick's Timer; the qualified name is the one that cannot
      // resolve to the wrong type.
      case "idleDaemon":    void IdleDaemon.tag; break
      case "inhibitor":     void Inhibitor.tag; break
      case "session":       void Session.tag; break
      case "privacy":       void Privacy.tag; break
      case "mediaEvents":   void Services.MediaEvents.tag; break
      case "audio":         void Audio.tag; break
      case "mediaArt":      void MediaArt.tag; break
      case "keyboard":      void Keyboard.tag; break
      case "timer":         void Services.Timer.tag; break
      case "recording":     void Recording.tag; break
      case "update":        void Update.tag; break
      case "archUpdates":   void Services.ArchUpdates.tag; break
      case "powerProfile":  void PowerProfile.tag; break
      case "printers":      void Printers.tag; break
      case "powerPolicy":   void PowerPolicy.tag; break
      case "batteryAlert":  void BatteryAlert.tag; break
      case "connectivity":  void Services.Connectivity.tag; break
      case "screenshots":
        void Screenshots.tag
        late._observeScreenshots()
        break
      default:              return false
    }
    return true
  }

  function readyState(id) {
    switch (id) {
      case "screenshots": return Screenshots._runtimeReady === true
      default:            return false
    }
  }

  // No unit in this half splits into a resident facade and a controller that
  // has to be released, so there is no teardown to dispatch.
  function teardown(id) {
    switch (id) {
      default: break
    }
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
