// Gate 1: inertness of ALL FIVE generated handler types.
//
// The five objects under test are byte-for-byte copies of the shipped
// generated types. Every singleton they name (directly, through a ready
// predicate, or through an authored hook that attaches a Connections target)
// is an instrumented stand-in in the throwaway mirror; a shared .pragma
// library counter records each Component.onCompleted so the probe can read a
// count without touching - and thereby constructing - the singleton itself.
//
// Representative ids from every provider are covered, including the four
// custom-hook forms (paths/pass/screenshots hooks plus the bar and annotations
// boot-bridge hooks):
//   floor   : log (direct tag), paths (hook)
//   services: powerProfile (direct tag), screenshots (hook)
//   features: appLauncher (facade), pass (hook)
//   bar     : bar (hook -> boot bridge)
//   demand  : annotations (hook -> boot bridge)
import QtQml
import QtQuick
import qs.features.launcher
import "CounterLib.js" as CounterLib
import "boot/generated/floor" as GenFloor
import "boot/generated/services" as GenServices
import "boot/generated/features" as GenFeatures
import "boot/generated/bar" as GenBar
import "boot/generated/demand" as GenDemand

Item {
  id: probe
  width: 1
  height: 1

  // The only surface the bar/annotations hooks forward to. It stands in for
  // Boot without importing Boot (which would pull in the whole shell).
  QtObject {
    id: bootStub
    property int mountCalls: 0
    property int unmountCalls: 0
    property int activateCalls: 0
    property int annotationsReadyCalls: 0
    property int teardownAnnotationsCalls: 0
    property int refreshCalls: 0
    property var _barRuntimeItem: null

    function _mountBarRuntime() {
      bootStub.mountCalls++
      bootStub._barRuntimeItem = ({ tag: "bar" })
      return true
    }
    function _unmountBarRuntime() {
      bootStub.unmountCalls++
      bootStub._barRuntimeItem = null
    }
    function _activateAnnotations() { bootStub.activateCalls++ }
    function _annotationsReady() {
      bootStub.annotationsReadyCalls++
      return true
    }
    function _teardownAnnotations() { bootStub.teardownAnnotationsCalls++ }
    function _refreshUnit(id) { bootStub.refreshCalls++ }
  }

  // Constructed synchronously, exactly where the providers construct theirs.
  property var floorHandlers: GenFloor.FloorHandlers { boot: bootStub }
  property var servicesHandlers: GenServices.ServicesHandlers { boot: bootStub }
  property var featuresHandlers: GenFeatures.FeaturesHandlers { boot: bootStub }
  property var barHandlers: GenBar.BarHandlers { boot: bootStub }
  property var demandHandlers: GenDemand.DemandHandlers { boot: bootStub }

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  // Every stand-in that is either resolved below or must stay untouched.
  function keys() {
    return [
      "common.Log", "common.Paths", "common.Watch", "common.Settings",
      "services.PowerProfile", "services.Screenshots", "services.Session",
      "services.Audio", "services.SystemUpdates",
      "features.launcher.AppLauncher", "features.pass.Pass",
      "features.clipboard.Clipboard", "features.apps.audioMixer.AudioMixer",
      "features.notifications.Notifications"
    ]
  }
  function dumpCounters(prefix) {
    var list = keys()
    for (var i = 0; i < list.length; i++) {
      kv(prefix + list[i], CounterLib.get(list[i]))
    }
  }

  Component.onCompleted: {
    try {
      run()
    } catch (e) {
      kv("probe.error", "" + (e && e.message ? e.message : e))
    }
    console.log("##DONE##")
  }

  function run() {
    // -- construction: no singleton has been completed, no hook object has
    //    been created, no target attached, and no boot bridge called. The
    //    generated rows create their authored hooks lazily on first use, so
    //    the hook properties are null here; "no hook object yet" is itself
    //    the absence of an attached Connections target. --
    dumpCounters("initial.")
    kv("hook.pass.target.at.construct",
       featuresHandlers.passHooks === null ||
       featuresHandlers.passHooks.passConnection.target === null)
    kv("hook.screenshots.target.at.construct",
       servicesHandlers.screenshotsHooks === null ||
       servicesHandlers.screenshotsHooks.screenshotsConnection.target === null)
    kv("boot.mount.calls.initial", bootStub.mountCalls)
    kv("boot.activate.calls.initial", bootStub.activateCalls)

    // -- floor: direct row then hook row --
    floorHandlers.handlers.log.resolve()
    kv("resolve.log.count", CounterLib.get("common.Log"))
    floorHandlers.handlers.log.resolve()
    kv("repeat.log.count", CounterLib.get("common.Log"))

    floorHandlers.handlers.paths.resolve()
    kv("resolve.paths.count", CounterLib.get("common.Paths"))
    kv("ready.paths", floorHandlers.handlers.paths.ready())
    floorHandlers.handlers.paths.resolve()
    kv("repeat.paths.count", CounterLib.get("common.Paths"))

    // -- services: direct row then custom-hook row --
    servicesHandlers.handlers.powerProfile.resolve()
    kv("resolve.powerProfile.count", CounterLib.get("services.PowerProfile"))
    servicesHandlers.handlers.powerProfile.resolve()
    kv("repeat.powerProfile.count", CounterLib.get("services.PowerProfile"))

    servicesHandlers.handlers.screenshots.resolve()
    kv("resolve.screenshots.count", CounterLib.get("services.Screenshots"))
    kv("hook.screenshots.target.after",
       servicesHandlers.screenshotsHooks !== null &&
       servicesHandlers.screenshotsHooks.screenshotsConnection.target !== null)
    kv("ready.screenshots", servicesHandlers.handlers.screenshots.ready())
    servicesHandlers.handlers.screenshots.resolve()
    kv("repeat.screenshots.count", CounterLib.get("services.Screenshots"))

    // -- features: facade row then custom-hook row --
    featuresHandlers.handlers.appLauncher.resolve()
    kv("resolve.appLauncher.count", CounterLib.get("features.launcher.AppLauncher"))
    kv("ready.appLauncher", featuresHandlers.handlers.appLauncher.ready())
    featuresHandlers.handlers.appLauncher.teardown()
    kv("teardown.appLauncher.calls", AppLauncher.teardownCalls)
    featuresHandlers.handlers.appLauncher.resolve()
    kv("repeat.appLauncher.count", CounterLib.get("features.launcher.AppLauncher"))

    featuresHandlers.handlers.pass.resolve()
    kv("resolve.pass.count", CounterLib.get("features.pass.Pass"))
    kv("hook.pass.target.after",
       featuresHandlers.passHooks !== null &&
       featuresHandlers.passHooks.passConnection.target !== null)
    kv("ready.pass", featuresHandlers.handlers.pass.ready())
    featuresHandlers.handlers.pass.resolve()
    kv("repeat.pass.count", CounterLib.get("features.pass.Pass"))

    // -- bar: hook forwards to Boot's runtime bridge, no singleton --
    barHandlers.handlers.bar.resolve()
    kv("resolve.bar.mounts", bootStub.mountCalls)
    barHandlers.handlers.bar.resolve()
    kv("repeat.bar.mounts", bootStub.mountCalls)
    kv("ready.bar", barHandlers.handlers.bar.ready())
    barHandlers.handlers.bar.teardown()
    kv("teardown.bar.unmounts", bootStub.unmountCalls)

    // -- demand: hook forwards to Boot's annotation bridge, no singleton --
    demandHandlers.handlers.annotations.resolve()
    kv("resolve.annotations.activations", bootStub.activateCalls)
    demandHandlers.handlers.annotations.resolve()
    kv("repeat.annotations.activations", bootStub.activateCalls)
    kv("ready.annotations", demandHandlers.handlers.annotations.ready())
    demandHandlers.handlers.annotations.teardown()
    kv("teardown.annotations.calls", bootStub.teardownAnnotationsCalls)

    // -- final: only the resolved stand-ins moved 0 -> 1; the untouched ones
    //    stayed at zero, so no cross-provider construction leaked. --
    dumpCounters("final.")
    kv("boot.refresh.calls", bootStub.refreshCalls)
  }
}
