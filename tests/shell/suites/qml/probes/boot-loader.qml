// Probe: the real qs.boot.AsyncLoader, constructed offscreen (it is a QtObject),
// driven through the full Phase 2 request matrix with an injected component
// factory. One real, small QML URL is loaded at the end to exercise the actual
// statusChanged hookup and the { boot: owner } creation property.
//
// Every public signal, every load() result and every observer call is appended
// to an ordered list. The shell suite compares the signal lists, byte for byte,
// with the serialized fixtures under tests/shell/fixtures/boot-loader/.
//
// The injected fake component is deliberately minimal: only the shape the
// loader actually uses (status, statusChanged.connect/disconnect, createObject,
// errorString). Everything else - the generation guard, the single-flight and
// adoption guards, terminal publishing order, cancellation and attempt ids -
// is the real loader's own code.

import QtQml
import QtQuick as QQ
import Quickshell
import qs.boot

QtObject {
  id: root

  // A QtObject has no default child property; own the watchdog timer through
  // an explicit list, the way the pump probe owns its frame timer.
  default property list<QtObject> _owned: [
    QQ.Timer {
      id: realWatch
      interval: 5000
      repeat: false
      onTriggered: {
        if (root.realDone) return
        root.realDone = true
        if (root.realLoader) {
          show("realUrl.signals", [])
          kv("realUrl.state", root.realLoader.state)
        }
        kv("probe.error", "real URL load timed out")
        kv("probe.complete", "false")
        console.log("##DONE##")
      }
    }
  ]

  property Component loaderComponent: Component { AsyncLoader { } }
  property string error: ""
  property var realLoader: null
  property bool realDone: false

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }
  function show(key, value) { kv(key, JSON.stringify(value)) }

  function statusValue(name) {
    if (name === "Ready") return Component.Ready
    if (name === "Error") return Component.Error
    return Component.Loading
  }

  // The fake component factory. One component per accepted load; `statuses`
  // and `objects` are indexed by attempt so a repeat can change outcome.
  function makeFactory(cfg, log) {
    return function (url, mode) {
      const index = log.factoryCalls.length
      log.factoryCalls.push({ url: String(url), async: mode === Component.Asynchronous })
      const name = cfg.statuses[Math.min(index, cfg.statuses.length - 1)]
      const comp = {
        status: statusValue(name),
        errorString: function () { return cfg.errorText || "fake load error" },
        createObject: function (owner, props) {
          log.createCalls.push({
            owner: owner === root,
            boot: !!(props && props.boot === root)
          })
          const choice = cfg.objects[Math.min(index, cfg.objects.length - 1)]
          if (choice === null) return null
          return { tag: cfg.tag || "half", boot: props && props.boot }
        },
        statusChanged: null
      }
      const handlers = []
      comp.statusChanged = {
        connect: function (fn) { handlers.push(fn); log.connects++ },
        disconnect: function (fn) {
          const at = handlers.indexOf(fn)
          if (at >= 0) { handlers.splice(at, 1); log.disconnects++ }
          else log.badDisconnects++
        },
        emit: function () { const copy = handlers.slice(); for (const fn of copy) fn() }
      }
      comp.emitStatus = function (next) {
        comp.status = statusValue(next)
        comp.statusChanged.emit()
      }
      comp.handlerCount = function () { return handlers.length }
      log.components.push(comp)
      return comp
    }
  }

  function newLoader(cfg, sink) {
    const loader = loaderComponent.createObject(root)
    // One observer counter per loader; deferredReadyRepeat shares one counter
    // across two loaders to make the distinct-id assertion meaningful.
    if (!cfg.counter) cfg.counter = { n: 0 }
    loader.sourceUrl = cfg.url || "BootServices.qml"
    loader.owner = root
    loader.createProperties = ({ boot: root })
    const log = {
      signals: [], observer: [], factoryCalls: [], createCalls: [], components: [],
      connects: 0, disconnects: 0, badDisconnects: 0
    }
    if (!cfg.useRealUrl) loader.componentFactory = makeFactory(cfg, log)
    if (!cfg.inertObserver) {
      loader.observer = {
        attemptOpen: function (url) {
          const id = ++cfg.counter.n
          log.observer.push({ op: "attemptOpen", id: id })
          return id
        },
        attemptClose: function (id, outcome) {
          log.observer.push({
            op: "attemptClose", id: Number(id), outcome: String(outcome)
          })
        },
        noteFailure: function (code) {
          log.observer.push({ op: "noteFailure", code: String(code) })
        }
      }
    }
    const out = sink || log.signals
    loader.adopted.connect(function (object, attemptId) {
      const event = { op: "adopted", id: Number(attemptId) }
      if (object && object.tag !== undefined) event.tag = String(object.tag)
      if (object && object.boot === root) event.owner = true
      out.push(event)
    })
    loader.failed.connect(function (errorClass, attemptId, detail) {
      const event = { op: "failed", class: String(errorClass), id: Number(attemptId) }
      event.detailBound = String(detail === undefined || detail === null ? "" : detail).length <= 160
      out.push(event)
    })
    cfg.log = log
    cfg.sink = out
    cfg.loader = loader
    return loader
  }

  // The marker is appended before the call: a synchronous Ready/failed signal
  // is emitted from inside load(), so recording the result afterwards would
  // put the signal ahead of the load that caused it.
  function load(loader, cfg) {
    const event = { op: "load", result: null }
    cfg.sink.push(event)
    event.result = loader.load()
    return event.result
  }
  // The real URL's attempt id is a live counter, so normalize it to a marker;
  // distinctness and positivity are asserted on the injected scenarios.
  function normalized(events) {
    const out = []
    for (const event of events) {
      const copy = {}
      for (const key in event) {
        if (Object.prototype.hasOwnProperty.call(event, key)) {
          copy[key] = key === "id" ? "N" : event[key]
        }
      }
      out.push(copy)
    }
    return out
  }
  function idsOf(events) {
    const ids = []
    for (const event of events) {
      if ((event.op === "adopted" || event.op === "failed") && ids.indexOf(event.id) < 0) {
        ids.push(event.id)
      }
    }
    return ids
  }
  function emitScenario(name, cfg) {
    show(name + ".signals", cfg.log.signals)
    show(name + ".observer", cfg.log.observer)
    show(name + ".ids", idsOf(cfg.log.signals))
    kv(name + ".state", cfg.loader.state)
    kv(name + ".generation", cfg.loader.generation)
    kv(name + ".connects", cfg.log.connects)
    kv(name + ".disconnects", cfg.log.disconnects)
    kv(name + ".badDisconnects", cfg.log.badDisconnects)
    kv(name + ".factoryCalls", cfg.log.factoryCalls.length)
    kv(name + ".async", cfg.log.factoryCalls.length > 0
      ? String(cfg.log.factoryCalls[0].async) : "n/a")
    kv(name + ".createCalls", JSON.stringify(cfg.log.createCalls))
    kv(name + ".handlerCount", cfg.log.components.length > 0
      ? cfg.log.components[0].handlerCount() : "n/a")
    show(name + ".factoryUrls", cfg.log.factoryCalls.map(function (call) { return call.url }))
    cfg.loader.destroy()
  }

  Component.onCompleted: {
    try {
      run()
    } catch (error) {
      root.error = String((error && error.message) || error)
      kv("probe.error", root.error)
    }
    if (!root.realLoader) {
      kv("probe.complete", "true")
      console.log("##DONE##")
    }
  }

  function run() {
    syncReady()
    syncErrorRepeat()
    deferredReady()
    deferredReadyRepeat()
    deferredErrorRepeat()
    createObjectNullRepeat()
    adoptionSuppresses()
    teardownDuringLoad()
    reentrantAdopted()
    reentrantFailed()
    inertObserver()
    startRealUrl()
  }

  // services synchronous Ready: createObject -> adopted inline, then the
  // instance guard refuses every later request.
  function syncReady() {
    const cfg = {
      statuses: ["Ready"], objects: ["object"], tag: "services"
    }
    const loader = newLoader(cfg)
    load(loader, cfg)
    load(loader, cfg)
    emitScenario("syncReady", cfg)
  }

  // A synchronous load Error is a terminal *report*, not a permanent refusal:
  // a second attempt is accepted and gets a distinct id, and succeeds.
  function syncErrorRepeat() {
    const cfg = {
      statuses: ["Error", "Ready"], objects: [null, "object"], tag: "services"
    }
    const loader = newLoader(cfg)
    load(loader, cfg)
    kv("syncErrorRepeat.stateAfterFailure", loader.state)
    load(loader, cfg)
    load(loader, cfg)
    emitScenario("syncErrorRepeat", cfg)
  }

  // Deferred Ready: adoption happens in the statusChanged turn, the named
  // handler is disconnected once, and a stale second callback is inert.
  function deferredReady() {
    const cfg = {
      statuses: ["Loading"], objects: ["object"], tag: "services"
    }
    const loader = newLoader(cfg)
    load(loader, cfg)
    cfg.log.components[0].emitStatus("Ready")
    cfg.log.components[0].emitStatus("Ready")
    load(loader, cfg)
    emitScenario("deferredReady", cfg)
  }

  // Two deferred Ready attempts (one per loader) must each adopt exactly once
  // and carry distinct attempt ids from the shared observer.
  function deferredReadyRepeat() {
    const shared = { n: 0 }
    const cfgA = {
      statuses: ["Loading"], objects: ["object"], tag: "services", counter: shared
    }
    const cfgB = {
      statuses: ["Loading"], objects: ["object"], tag: "features", counter: shared
    }
    const events = []
    const a = newLoader(cfgA, events)
    const b = newLoader(cfgB, events)
    load(a, cfgA)
    cfgA.log.components[0].emitStatus("Ready")
    load(b, cfgB)
    cfgB.log.components[0].emitStatus("Ready")
    show("deferredReadyRepeat.signals", events)
    show("deferredReadyRepeat.ids", idsOf(events))
    kv("deferredReadyRepeat.stateA", a.state)
    kv("deferredReadyRepeat.stateB", b.state)
    a.destroy()
    b.destroy()
  }

  // A deferred Error is reported with its own attempt id and is followed by a
  // legal second attempt, which adopts on a deferred Ready.
  function deferredErrorRepeat() {
    const cfg = {
      statuses: ["Loading", "Loading"], objects: [null, "object"], tag: "features"
    }
    const loader = newLoader(cfg)
    load(loader, cfg)
    cfg.log.components[0].emitStatus("Error")
    kv("deferredErrorRepeat.stateAfterFailure", loader.state)
    load(loader, cfg)
    cfg.log.components[1].emitStatus("Ready")
    load(loader, cfg)
    emitScenario("deferredErrorRepeat", cfg)
  }

  // createObject returning null is a failure edge with no adopted signal; the
  // next request is still accepted and adopts normally.
  function createObjectNullRepeat() {
    const cfg = {
      statuses: ["Ready", "Ready"], objects: [null, "object"], tag: "features"
    }
    const loader = newLoader(cfg)
    load(loader, cfg)
    kv("createObjectNullRepeat.stateAfterFailure", loader.state)
    load(loader, cfg)
    load(loader, cfg)
    emitScenario("createObjectNullRepeat", cfg)
  }

  // Adoption suppresses all later requests: no extra attempt id, no extra
  // signal, and the instance is never replaced.
  function adoptionSuppresses() {
    const cfg = {
      statuses: ["Ready"], objects: ["object"], tag: "services"
    }
    const loader = newLoader(cfg)
    load(loader, cfg)
    const instance = loader.instance
    load(loader, cfg)
    load(loader, cfg)
    load(loader, cfg)
    kv("adoptionSuppresses.instanceStable", loader.instance === instance)
    emitScenario("adoptionSuppresses", cfg)
  }

  // Teardown while Loading is cancellation, not failure: the exact handler is
  // disconnected once, a stale Ready callback publishes nothing, no public
  // failed signal is emitted, and a fresh request afterwards is legal.
  function teardownDuringLoad() {
    const cfg = {
      statuses: ["Loading", "Ready"], objects: [null, "object"], tag: "services"
    }
    const loader = newLoader(cfg)
    load(loader, cfg)
    loader.teardown()
    kv("teardownDuringLoad.stateAfterTeardown", loader.state)
    cfg.log.components[0].emitStatus("Ready")
    load(loader, cfg)
    cfg.log.components[1].emitStatus("Ready")
    emitScenario("teardownDuringLoad", cfg)
  }

  // A request issued from inside adopted is refused: adoption is already
  // published, so there is no second attempt and no recursion.
  function reentrantAdopted() {
    const cfg = {
      statuses: ["Ready"], objects: ["object"], tag: "services"
    }
    const loader = newLoader(cfg)
    loader.adopted.connect(function () {
      const event = { op: "reentrantLoad", result: null }
      cfg.sink.push(event)
      event.result = loader.load()
    })
    load(loader, cfg)
    emitScenario("reentrantAdopted", cfg)
  }

  // A request issued from inside failed is accepted: the loader publishes its
  // terminal state and clears the pending pair BEFORE calling the consumer.
  function reentrantFailed() {
    const cfg = {
      statuses: ["Error", "Ready"], objects: [null, "object"], tag: "features"
    }
    const loader = newLoader(cfg)
    loader.failed.connect(function () {
      const event = { op: "reentrantLoad", result: null }
      cfg.sink.push(event)
      event.result = loader.load()
    })
    load(loader, cfg)
    load(loader, cfg)
    emitScenario("reentrantFailed", cfg)
  }

  // An inert (null) observer changes no choreography: attempt ids fall back to
  // the loader's own monotonic counter and the same callbacks are emitted.
  function inertObserver() {
    const cfg = {
      statuses: ["Error", "Ready"], objects: [null, "object"],
      tag: "services", inertObserver: true
    }
    const loader = newLoader(cfg)
    load(loader, cfg)
    load(loader, cfg)
    emitScenario("inertObserver", cfg)
  }

  // The one real URL: no injected factory, so Qt.createComponent's real
  // statusChanged signal drives the adoption of a small QtObject with the
  // loader's boot owner property.
  function startRealUrl() {
    const cfg = {
      url: Qt.resolvedUrl("BootLoaderSmallTarget.qml"),
      statuses: [], objects: [], useRealUrl: true
    }
    const loader = newLoader(cfg)
    // A recording wrapper around the real Qt call: the component, its
    // statusChanged signal and the created object are all genuine; only the
    // requested mode is captured for the assertion.
    loader.componentFactory = function (url, mode) {
      cfg.log.factoryCalls.push({
        url: String(url), async: mode === Component.Asynchronous
      })
      return Qt.createComponent(url, mode)
    }
    root.realLoader = loader
    loader.adopted.connect(function (object, attemptId) {
      if (root.realDone) return
      root.realDone = true
      show("realUrl.signals", normalized(cfg.log.signals))
      kv("realUrl.state", loader.state)
      kv("realUrl.id", Number(attemptId))
      kv("realUrl.tag", object && object.tag ? String(object.tag) : "")
      kv("realUrl.owner", object && object.boot === root ? "true" : "false")
      kv("realUrl.async", cfg.log.factoryCalls.length > 0
        ? String(cfg.log.factoryCalls[0].async) : "n/a")
      kv("probe.complete", "true")
      console.log("##DONE##")
    })
    loader.failed.connect(function (cls, attemptId, detail) {
      if (root.realDone) return
      root.realDone = true
      show("realUrl.signals", cfg.log.signals)
      kv("realUrl.state", loader.state)
      kv("realUrl.failure", String(cls))
      kv("probe.error", "real URL load failed: " + String(cls))
      kv("probe.complete", "false")
      console.log("##DONE##")
    })
    realWatch.restart()
    load(loader, cfg)
  }

}
