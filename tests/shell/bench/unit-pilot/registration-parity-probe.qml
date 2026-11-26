// Gate 2: raw offer and gateway-registration parity at three observation
// points. Runs unchanged in two isolated trees (baseline 9c3b2828 and the
// candidate working tree) against the REAL singletons and the REAL IpcRouter.
// The only substituted file is common/ui/LayerSurface.qml, swapped in the
// throwaway mirror for an inert Item so AppLauncher can compile offscreen.
import QtQml
import QtQuick
import Quickshell
import qs.common
import "common/text/IpcProtocol.js" as P

Item {
  id: probe
  width: 1
  height: 1

  // The selected test instance, identical in both trees. The process id is
  // printed only as a run marker; no observation depends on it.
  property string instance: "unit-pilot-registration-parity"
  property var services: null
  property var features: null

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }
  function show(key, value) { kv(key, JSON.stringify(value === undefined ? null : value)) }

  function gateway(words) {
    const text = P.encode({ v: 1, kind: "call", argv: words.slice(), literalFrom: null })
    const frame = P.decode(IpcRouter.invoke(text))
    if (!frame) return { ok: false, code: "no-frame" }
    if (frame.ok === true) {
      const d = frame.data
      if (words[0] === "appLauncher" && d && typeof d === "object") {
        return {
          ok: true,
          visible: d.visible,
          reads: d.reads,
          discovery: d.discovery,
          controller: d.controller,
          mode: d.mode
        }
      }
      return { ok: true, data: d === undefined ? null : d }
    }
    return { ok: false, code: frame.error && frame.error.code }
  }

  function observe(label) {
    const ids = ["powerProfile", "appLauncher", "screenshots", "pass"]
    for (let i = 0; i < ids.length; i++) {
      kv(label + ".offers." + ids[i], Registry.offers().indexOf(ids[i]) >= 0)
      kv(label + ".gateway.owner." + ids[i], IpcRouter.registered(ids[i]))
    }
    // Only the two declared safe endpoints are dispatched; the affected late
    // units are compared by real offer membership and gateway owner state.
    show(label + ".gateway.powerProfile.status", gateway(["powerProfile", "status"]))
    show(label + ".gateway.appLauncher.status", gateway(["appLauncher", "status"]))
  }

  function descriptor(id, provider, activation, hasReady) {
    return {
      id: id,
      provider: "pilot-probe",
      phase: "early",
      activation: activation,
      criticality: "optional",
      dependencies: [],
      // The one call under test: the provider dispatches through its authored
      // or generated row into the real singleton's completion handler.
      resolver: function () { return provider.resolve(id) },
      ready: hasReady ? function () { return provider.readyState(id) } : null,
      teardown: hasReady ? function () { provider.teardown(id) } : null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    }
  }

  Component.onCompleted: {
    try {
      kv("instance", probe.instance)
      kv("process.marker", Quickshell.processId)
      observe("before_load")

      const servicesComp = Qt.createComponent("boot/BootServices.qml")
      const featuresComp = Qt.createComponent("boot/BootLate.qml")
      kv("providers.component.services", servicesComp.status === Component.Ready)
      kv("providers.component.features", featuresComp.status === Component.Ready)
      probe.services = servicesComp.createObject(probe, { boot: null })
      probe.features = featuresComp.createObject(probe, { boot: null })
      kv("providers.object.services", probe.services !== null)
      kv("providers.object.features", probe.features !== null)
      observe("adopted_no_resolve")

      kv("gate.register.powerProfile", UnitGate.register("powerProfile",
        descriptor("powerProfile", probe.services, "resident", false)))
      kv("gate.register.appLauncher", UnitGate.register("appLauncher",
        descriptor("appLauncher", probe.features, "facade", true)))
      kv("gate.register.screenshots", UnitGate.register("screenshots",
        descriptor("screenshots", probe.services, "resident", true)))
      kv("gate.register.pass", UnitGate.register("pass",
        descriptor("pass", probe.features, "facade", true)))
      const p = UnitGate.ensure("powerProfile", "pilot-probe")
      const a = UnitGate.ensure("appLauncher", "pilot-probe")
      const s = UnitGate.ensure("screenshots", "pilot-probe")
      const pa = UnitGate.ensure("pass", "pilot-probe")
      kv("gate.ensure.powerProfile", JSON.stringify({ ok: p.ok === true, state: p.state }))
      kv("gate.ensure.appLauncher", JSON.stringify({ ok: a.ok === true, state: a.state }))
      kv("gate.ensure.screenshots", JSON.stringify({ ok: s.ok === true, state: s.state }))
      kv("gate.ensure.pass", JSON.stringify({ ok: pa.ok === true, state: pa.state }))
      UnitGate.refresh("powerProfile")
      UnitGate.refresh("appLauncher")
      UnitGate.refresh("screenshots")
      UnitGate.refresh("pass")
      observe("after_first_resolve")
    } catch (e) {
      kv("probe.error", "" + (e && e.message ? e.message : e))
    }
    console.log("##DONE##")
  }
}
