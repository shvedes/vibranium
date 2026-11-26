// Phase 4 conditional lease audit: headless probe on the NEUTRAL contract.
//
// LIMITATION (explicit): the full boot/Boot.qml component cannot be constructed
// headlessly - it starts the shell. This probe therefore drives the real
// UnitGate, UnitLease and IpcRouter singletons with a synthetic catalog and a
// stand-in facade owner. The places that matter in the SHIPPED code are pinned
// statically against their source by suites/js/boot-lease-contract.test.mjs:
//   * AppLauncher registers its IpcRouter target in Component.onCompleted and
//     unregisters it in Component.onDestruction;
//   * BootLate's resolver for "appLauncher" is `void AppLauncher.tag`, so a
//     declined resolver means no facade has been constructed, hence no
//     registered target;
//   * IpcRouter refuses an unregistered target before it reaches any owner.
// The four moments below are reproducible from that pinning; the stand-in
// facade additionally exercises the UnitLease demand paths that would apply
// IF a handler were registered during a provider-pending window.

import QtQuick
import Quickshell
import qs.common
import "common/text/IpcProtocol.js" as P

Item {
  id: probe
  width: 1
  height: 1

  // Controlled provider state. The resolver for "appLauncher" declines while
  // this is false, which is UnitGate's "half not loaded yet" path (_defer).
  property bool providerAvailable: false
  property bool pendingProviderAvailable: false

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }
  function show(key, value) { kv(key, JSON.stringify(value === undefined ? null : value)) }

  function okFrame() { return { v: 1, ok: true } }
  function errFrame(code, message) { return { v: 1, ok: false, error: { code: code, message: message } } }

  function descriptor(id, deps, opts) {
    const o = opts || {}
    return {
      criticality: "optional",
      activation: "facade",
      phase: "early",
      dependencies: deps || [],
      resolver: o.resolver || function () { return true },
      ready: function () { return true },
      teardown: function () {},
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    }
  }

  function compact(result) {
    if (!result) return null
    return {
      ok: result.ok === true,
      state: result.state || null,
      code: result.code || null,
      hasLease: !!result.lease
    }
  }

  function gateState(id) {
    const row = UnitGate.state(id)
    return row === null ? "null" : row.state
  }

  function call(words) {
    const envelope = P.encode({ v: 1, kind: "call", argv: words.slice(), literalFrom: null })
    return P.decode(IpcRouter.invoke(envelope))
  }

  // Record only the wire-visible part of a reply: code and message, never a
  // private lease error. That is what a vb-shell caller can distinguish.
  function reply(frame) {
    if (!frame) return { ok: false, code: "no-frame", message: null }
    if (frame.ok === true) return { ok: true, code: null, message: null }
    return {
      ok: false,
      code: frame.error && frame.error.code,
      message: frame.error && frame.error.message
    }
  }

  function openNow() { return reply(call(["appLauncher", "open"])) }

  function shortcutWords() { return IpcRouter._shortcutWords["appLauncher.toggle"].slice() }

  function shortcutNow() {
    // invokeShortcut() returns nothing; it decodes _invokeWords on the pinned
    // words. Exercise the real entry point, then record that same dispatch.
    IpcRouter.invokeShortcut("vibranium:shortcut:appLauncher.toggle")
    return reply(call(shortcutWords()))
  }

  function snapshot(name) {
    kv(name + ".registered", IpcRouter.registered("appLauncher"))
    kv(name + ".gateState", gateState("appLauncher"))
    show(name + ".open", openNow())
    show(name + ".shortcut", shortcutNow())
  }

  Component.onCompleted: {
    try {
      run()
    } catch (e) {
      kv("probe.error", "" + (e && e.message ? e.message : e))
    }
    console.log("##DONE##")
  }

  // The stand-in facade: registers on completion, like the shipped singleton,
  // and answers through the real UnitLease. No window and no controller tree.
  Component {
    id: facadeComp

    Item {
      id: facade

      property string unitIdForLease: "appLauncher"
      property var controllerSource: readyComp
      property string startupErrorForController: ""
      property bool shown: false

      UnitLease {
        id: lease
        unitId: facade.unitIdForLease
        owner: "appLauncher-facade"
        controllerComponent: facade.controllerSource
      }

      Component {
        id: readyComp
        Item {
          // UnitLease reads startupError on every built controller.
          property string startupError: facade.startupErrorForController
        }
      }

      function phase() { return lease.phase }
      function error() { return lease.error }
      function constructions() { return lease.constructions }
      function teardownLease() {
        lease.teardown()
        facade.shown = false
      }
      function useReadyController() { facade.controllerSource = readyComp }

      // Mirrors AppLauncher._openGateway: a refused demand is the same wire
      // answer for gate, load and construction refusals.
      function openGateway() {
        const ctrl = lease.demand()
        if (ctrl === null) return probe.errFrame("unavailable", "launcher did not open")
        facade.shown = true
        return probe.okFrame()
      }
      function closeGateway() {
        facade.shown = false
        return probe.okFrame()
      }
      function toggleGateway() {
        if (facade.shown) return closeGateway()
        return openGateway()
      }

      Component.onCompleted: {
        IpcRouter.register("appLauncher", facade, {
          "appLauncher.open": function () { return facade.openGateway() },
          "appLauncher.close": function () { return facade.closeGateway() },
          "appLauncher.toggle": function () { return facade.toggleGateway() }
        })
      }
      Component.onDestruction: IpcRouter.unregister("appLauncher", facade)
    }
  }

  function run() {
    kv("limitation", "neutral UnitLease/UnitGate/IpcRouter contract; Boot not constructed; registration sites pinned statically")
    show("shortcut.words", shortcutWords())

    UnitGate.register("appLauncher", descriptor("appLauncher", [], {
      resolver: function () { return probe.providerAvailable }
    }))
    UnitGate.register("bl-pending", descriptor("bl-pending", [], {
      resolver: function () { return probe.pendingProviderAvailable }
    }))
    UnitGate.register("bl-blocked", descriptor("bl-blocked", ["bl-missing"]))
    UnitGate.register("bl-gatefail", descriptor("bl-gatefail", [], {
      resolver: function () { throw new Error("unit exploded") }
    }))

    // (a) before any request: the catalog exists, no facade does.
    snapshot("before")

    // (b) during provider loading: the resolver declines, the demand is
    // deferred, and still no facade exists to register a target.
    show("loading.ensure", compact(UnitGate.ensure("appLauncher", "boot-facade")))
    snapshot("loading")

    // (c) the provider half has adopted; refresh settles the deferred unit.
    // The facade still has not been constructed, so the target is still absent.
    probe.providerAvailable = true
    kv("adopted.refresh", UnitGate.refresh("appLauncher"))
    snapshot("adopted")
    UnitGate.releaseOwner("boot-facade")
    kv("adopted.stateAfterBootRelease", gateState("appLauncher"))

    // (d) the facade exists: registration happens in its completion handler.
    const facade = facadeComp.createObject(probe)
    kv("facade.registered", IpcRouter.registered("appLauncher"))
    show("facade.open", openNow())
    kv("facade.phase", facade.phase())
    kv("facade.constructions", facade.constructions())
    kv("facade.gateState", gateState("appLauncher"))
    show("facade.shortcut", shortcutNow())
    facade.teardownLease()

    // Separate facade tests, all with a REGISTERED dispatch.
    // Pending controller: the gate defers and no controller is publishable.
    facade.unitIdForLease = "bl-pending"
    facade.controllerSource = null
    show("pending.ensure", compact(UnitGate.ensure("bl-pending", "probe-record")))
    UnitGate.releaseOwner("probe-record")
    show("pending.first", openNow())
    kv("pending.phase", facade.phase())
    kv("pending.error", facade.error())
    kv("pending.gateState", gateState("bl-pending"))
    kv("pending.constructions", facade.constructions())
    show("pending.retry", openNow())
    kv("pending.retry.phase", facade.phase())
    probe.pendingProviderAvailable = true
    facade.useReadyController()
    show("pending.recovered", openNow())
    kv("pending.recovered.phase", facade.phase())
    kv("pending.recovered.constructions", facade.constructions())
    facade.teardownLease()

    // Genuinely blocked unit: same wire code even though the cause differs.
    facade.unitIdForLease = "bl-blocked"
    facade.useReadyController()
    show("blocked.ensure", compact(UnitGate.ensure("bl-blocked", "probe-record")))
    UnitGate.releaseOwner("probe-record")
    show("blocked.reply", openNow())
    kv("blocked.phase", facade.phase())
    kv("blocked.error", facade.error())
    kv("blocked.gateState", gateState("bl-blocked"))
    facade.teardownLease()

    // Genuinely failed controller: startupError reported by the built object.
    facade.unitIdForLease = "appLauncher"
    facade.startupErrorForController = "controller exploded"
    show("failed.reply", openNow())
    kv("failed.phase", facade.phase())
    kv("failed.error", facade.error())
    kv("failed.gateState", gateState("appLauncher"))
    facade.startupErrorForController = ""
    show("failed.recovered", openNow())
    kv("failed.recovered.phase", facade.phase())
    facade.teardownLease()

    // Genuinely failed gate: the resolver throws before a controller exists.
    facade.unitIdForLease = "bl-gatefail"
    show("gateFailed.ensure", compact(UnitGate.ensure("bl-gatefail", "probe-record")))
    UnitGate.releaseOwner("probe-record")
    show("gateFailed.reply", openNow())
    kv("gateFailed.phase", facade.phase())
    kv("gateFailed.error", facade.error())
    facade.teardownLease()
  }
}
