// Gate 3: pre-adoption decline/stash/replay for both pilot ids, plus the real
// appLauncher controller lifecycle on admitted demand and release. Run in the
// two isolated trees with the real singletons; only the window layer primitive
// is swapped for an inert Item in the throwaway mirror.
import QtQml
import QtQuick
import qs.common
import qs.features.launcher
import qs.features.pass
import qs.features.apps.audioMixer
import qs.features.apps.imageViewer
import "boot/Units.catalog.js" as Units

Item {
  id: probe
  width: 1
  height: 1

  property string instance: "unit-pilot-replay-lifecycle"
  property var services: null
  property var features: null
  // One entry per UnitGate.unitChanged for the pilot facade, so an extra
  // ready/stop signal is observable rather than assumed absent.
  property var appSignals: []
  // All four resident facades are observed through decline and replay. Only
  // AppLauncher exposes a public demand seam (_demandTransient), so the full
  // admitted-demand/teardown cycle below is exercised on that facade.
  property var facades: ["appLauncher", "pass", "audioMixer", "imageViewer"]
  // Every services/features id in the shipped catalog (except the five
  // already registered explicitly above) is observed through the same
  // decline/stash/replay path in one compact record per point.
  property var lateIds: []

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }
  function compact(r) {
    return JSON.stringify({ ok: r.ok === true, state: r.state || null })
  }
  function show(key, value) { kv(key, JSON.stringify(value)) }
  function unitState(id) {
    const row = UnitGate.state(id)
    return row === null ? "null" : row.state
  }
  function owners(id) {
    const row = UnitGate.state(id)
    return row === null ? -1 : row.ownerCount
  }

  // The resolver declines while its provider half is absent. That is the
  // stash path: UnitGate keeps the lease and Boot replays the demand when the
  // half is adopted.
  function descriptor(id, providerOf, activation, withReady) {
    return {
      id: id,
      provider: "pilot-probe",
      phase: "early",
      activation: activation,
      criticality: "optional",
      dependencies: [],
      resolver: function () {
        const provider = providerOf()
        return provider !== null ? provider.resolve(id) : false
      },
      ready: withReady ? function () { return providerOf().readyState(id) } : null,
      teardown: withReady ? function () { providerOf().teardown(id) } : null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    }
  }

  Component.onCompleted: {
    try {
      kv("instance", probe.instance)
      UnitGate.unitChanged.connect(function (id) {
        if (id === "appLauncher") probe.appSignals.push(id)
      })
      // Touching the facade constructs the REAL singleton; its own prewarm is
      // gated on the boot entrance, which no offscreen probe has played.
      kv("prewarm.played", DesktopLayoutState.bootEntrancePlayed)
      kv("facade.tag", AppLauncher.tag)
      kv("facade.controller.before", AppLauncher.controllerState)
      kv("facade.constructions.before", AppLauncher.constructions)

      UnitGate.register("powerProfile", descriptor("powerProfile",
        function () { return probe.services }, "resident", false))
      UnitGate.register("appLauncher", descriptor("appLauncher",
        function () { return probe.features }, "facade", true))
      const extraFacades = ["pass", "audioMixer", "imageViewer"]
      for (let i = 0; i < extraFacades.length; i++) {
        UnitGate.register(extraFacades[i], descriptor(extraFacades[i],
          function () { return probe.features }, "facade", true))
      }

      // Every remaining services/features id from the shipped catalog takes
      // the identical decline/stash/replay path. The catalog is byte-identical
      // between baseline and candidate, so both sides enumerate the same ids.
      const explicit = { powerProfile: 1, appLauncher: 1, pass: 1,
        audioMixer: 1, imageViewer: 1 }
      for (let i = 0; i < Units.catalog.length; i++) {
        const row = Units.catalog[i]
        if (row.provider !== "services" && row.provider !== "features") continue
        if (explicit[row.id]) continue
        probe.lateIds.push(row.id)
        const providerOf = row.provider === "services"
          ? function () { return probe.services }
          : function () { return probe.features }
        UnitGate.register(row.id, descriptor(row.id, providerOf,
          row.activation || "resident", row.hasReady === true))
      }
      kv("late.ids.count", probe.lateIds.length)

      // (a) demand before either provider is adopted: decline + stash.
      const pp = UnitGate.ensure("powerProfile", "pilot-probe")
      const al = UnitGate.ensure("appLauncher", "pilot-probe")
      kv("decline.powerProfile.ensure", compact(pp))
      kv("decline.appLauncher.ensure", compact(al))
      kv("decline.powerProfile.state", unitState("powerProfile"))
      kv("decline.appLauncher.state", unitState("appLauncher"))
      kv("decline.powerProfile.owners", owners("powerProfile"))
      kv("decline.appLauncher.owners", owners("appLauncher"))
      kv("decline.appLauncher.controller", AppLauncher.controllerState)
      kv("decline.appLauncher.constructions", AppLauncher.constructions)
      kv("decline.appLauncher.signals", probe.appSignals.length)
      // The other three facades decline and stash identically, with no
      // controller built before adoption.
      for (let i = 0; i < extraFacades.length; i++) {
        const id = extraFacades[i]
        const r = UnitGate.ensure(id, "pilot-probe")
        kv("decline." + id + ".ensure", compact(r))
        kv("decline." + id + ".state", unitState(id))
        kv("decline." + id + ".owners", owners(id))
      }
      kv("decline.pass.controller", Pass.controllerState)
      kv("decline.pass.constructions", Pass.constructions)
      kv("decline.audioMixer.controller", AudioMixer.controllerState)
      kv("decline.audioMixer.constructions", AudioMixer.constructions)
      kv("decline.imageViewer.controller", ImageViewer.controllerState)
      kv("decline.imageViewer.constructions", ImageViewer.constructions)
      const declineAll = ({})
      for (let i = 0; i < probe.lateIds.length; i++) {
        const id = probe.lateIds[i]
        const r = UnitGate.ensure(id, "pilot-probe")
        declineAll[id] = { ok: r.ok === true, state: unitState(id), owners: owners(id) }
      }
      show("decline.allLate", declineAll)

      // (b) adopt the halves, then replay exactly like Boot._replayNext.
      const sc = Qt.createComponent("boot/BootServices.qml")
      const fc = Qt.createComponent("boot/BootLate.qml")
      probe.services = sc.createObject(probe, { boot: null })
      probe.features = fc.createObject(probe, { boot: null })
      kv("adopt.services", probe.services !== null)
      kv("adopt.features", probe.features !== null)
      // The late half still owns the annotation component handoff, and the
      // bar stays owned by Boot rather than by either late provider.
      kv("adopt.annotationComponent", probe.features.annotationComponent() !== null)
      kv("late.bar.not.owned", probe.features.resolve("bar") === false)

      kv("replay.powerProfile.refresh", UnitGate.refresh("powerProfile"))
      kv("replay.appLauncher.refresh", UnitGate.refresh("appLauncher"))
      kv("replay.powerProfile.state", unitState("powerProfile"))
      kv("replay.appLauncher.state", unitState("appLauncher"))
      kv("replay.powerProfile.owners", owners("powerProfile"))
      kv("replay.appLauncher.owners", owners("appLauncher"))
      kv("replay.appLauncher.controller", AppLauncher.controllerState)
      kv("replay.appLauncher.constructions", AppLauncher.constructions)
      kv("replay.appLauncher.signals", probe.appSignals.length)
      for (let i = 0; i < extraFacades.length; i++) {
        const id = extraFacades[i]
        kv("replay." + id + ".refresh", UnitGate.refresh(id))
        kv("replay." + id + ".state", unitState(id))
        kv("replay." + id + ".owners", owners(id))
      }
      kv("replay.pass.controller", Pass.controllerState)
      kv("replay.pass.constructions", Pass.constructions)
      kv("replay.audioMixer.controller", AudioMixer.controllerState)
      kv("replay.audioMixer.constructions", AudioMixer.constructions)
      kv("replay.imageViewer.controller", ImageViewer.controllerState)
      kv("replay.imageViewer.constructions", ImageViewer.constructions)
      const replayAll = ({})
      for (let i = 0; i < probe.lateIds.length; i++) {
        const id = probe.lateIds[i]
        UnitGate.refresh(id)
        replayAll[id] = { state: unitState(id), owners: owners(id) }
      }
      show("replay.allLate", replayAll)

      // (c) admitted demand builds exactly one controller, then releasing the
      // facade owner unloads it. The replay lease is released after the
      // teardown so the gate's teardown hook sees zero owners.
      const ctrl = AppLauncher._demandTransient()
      kv("demand.controller.built", ctrl !== null)
      kv("demand.controller.state", AppLauncher.controllerState)
      kv("demand.constructions", AppLauncher.constructions)
      kv("demand.owners", owners("appLauncher"))
      kv("demand.signals", probe.appSignals.length)

      AppLauncher.teardownController()
      kv("release.controller.state", AppLauncher.controllerState)
      kv("release.constructions", AppLauncher.constructions)
      kv("release.owners.beforeReplayRelease", owners("appLauncher"))
      UnitGate.releaseOwner("pilot-probe")
      kv("release.state.afterAllOwners", unitState("appLauncher"))
      kv("release.controller.state.afterAllOwners", AppLauncher.controllerState)
      kv("release.constructions.afterAllOwners", AppLauncher.constructions)
      kv("release.signals", probe.appSignals.length)
    } catch (e) {
      kv("probe.error", "" + (e && e.message ? e.message : e))
    }
    console.log("##DONE##")
  }
}
