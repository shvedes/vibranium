// Probe: a failed gateway registration is only an observation. Capture stays
// live, integrity is unchanged, the watchdog keeps its own deadline, and a
// catalog registration failure is a separate, explicit aborted seal.
import QtQuick
import Quickshell
import qs.common
import "boot/BootTrace.js" as BT

Item {
  id: root

  property string error: ""
  property var owner: ({ tag: "probe.bad.gateway" })

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  Component.onCompleted: {
    try {
      run()
    } catch (e) {
      kv("probe.error", String((e && e.message) || e))
    }
    console.log("##DONE##")
  }

  function run() {
    // --- gateway failure ----------------------------------------------------
    var ms = 0
    var trace = BT.create({ now: function () { return ms } })
    var map = Object.create(null)
    trace.setContext({ source: "test", estimate: null }, null)
    trace.setTokenCap(32)
    ms = 0
    map.origin = trace.emit("boot.begin", { source: "test", estimateMs: null })
    trace.armWatchdog(0, 5000)

    // The real router refuses a map with an unknown row id; Boot notes that
    // false result instead of aborting capture (see Boot.qml source checks).
    var registered = IpcRouter.register("boot", root.owner, {
      "boot.noSuchRow": function () { return "unused" }
    })
    kv("router.failedRegister", registered)

    ms = 2
    map.gw = trace.emit("gateway.registered", { valid: registered, target: "boot" })
    ms = 3
    map.v = trace.emit("verdict.decision", { state: "ready", causes: [map.gw] })
    ms = 4
    map.fv = trace.emit("endpoint.firstVerdict", { causes: [map.v] })
    var report = trace.snapshot()
    kv("gateway.eventId", map.gw)
    kv("gateway.inChain", report.chains.firstVerdict.chain.some(function (e) {
      return e.kind === "gateway.registered"
    }))
    kv("gateway.sealed", report.sealed)
    kv("gateway.sealReason", report.sealReason === null ? "null" : report.sealReason)
    kv("gateway.integrity", report.integrity.valid)
    kv("gateway.violations", report.integrity.violations.length)
    kv("gateway.snapshotAvailable", report.schema)
    kv("gateway.observedThroughMs", report.observedThroughMs)

    // Later work is still captured after the failed registration.
    ms = 5
    var late = trace.emit("unit.state", { unit: "late", state: "ready", causes: [map.origin] })
    var later = trace.snapshot()
    kv("gateway.captureContinues", late > map.fv && later.observedThroughMs === 5)

    // The watchdog keeps the deadline that was armed before the failure.
    kv("gateway.watchdogEarly", trace.watchdogFired(4999))
    kv("gateway.watchdogAtDeadline", trace.watchdogFired(5000))
    var sealed = trace.snapshot()
    kv("gateway.watchdogSealed", sealed.sealed && sealed.sealReason === "watchdog")
    var frozen = JSON.stringify(trace.snapshot())
    ms = 9000
    kv("gateway.sealedReportFrozen", JSON.stringify(trace.snapshot()) === frozen)

    // --- catalog failure is a separate observation --------------------------
    var ms2 = 0
    var other = BT.create({ now: function () { return ms2 } })
    other.setContext({ source: "test", estimate: null }, null)
    other.setTokenCap(32)
    ms2 = 0
    other.emit("boot.begin", { source: "test", estimateMs: null })
    ms2 = 1
    other.emit("catalog.registered", { valid: false, digest: "probe" })
    ms2 = 2
    var aborted = other.seal("aborted")
    kv("catalog.sealed", aborted.sealed)
    kv("catalog.reason", aborted.sealReason)
    kv("catalog.distinctFromGateway", JSON.stringify(report).indexOf('"sealed":false') >= 0)
    kv("probe.complete", true)
  }
}
