pragma ComponentBehavior: Bound
import QtQml

// Phase 2 loader: one URL, one active generation, extraction only. Boot owns
// one loader per URL and keeps the caller/failure order around it. No demand
// policy, no retry policy, no global refcount, no URL-keyed singleton, no
// timers and no provider import live here.
QtObject {
  id: loader

  property url sourceUrl: ""
  property string state: "idle"          // idle | loading | adopted | failed
  property var instance: null
  property var component: null
  property var owner: null
  property var observer: null
  property int generation: 0

  // Narrow fixture seam. Production is the real Qt call; a fixture injects a
  // fake component. `mode` is Component.Asynchronous on every accepted load.
  property var componentFactory: function (url, mode) { return Qt.createComponent(url, mode) }

  // Boot supplies its own property block (e.g. { boot: owner }); the loader
  // does not import a provider to build it.
  property var createProperties: ({})

  // Bounded text for Boot's EXISTING Log.error only. Never sent to the trace.
  property string lastError: ""

  signal adopted(var object, int attemptId)
  signal failed(string errorClass, int attemptId, string detail)

  // Private: the active generation holds its component AND its named handler
  // as one record, so cancellation can detach the exact pair exactly once.
  property var _active: null
  property int _nextAttemptId: 0

  function _bound(value) {
    const text = value === undefined || value === null ? "" : String(value)
    return text.slice(0, 160)
  }

  function _componentError(comp) {
    if (!comp) return "componentError"
    try {
      if (typeof comp.errorString === "function") return _bound(comp.errorString())
    } catch (ignored) {}
    return "componentError"
  }

  // A throwing observer cannot stop a load. Internal ids stay monotonic even
  // when the observer supplies its own, so a fallback id is always positive.
  function _allocateAttempt() {
    const fallback = ++loader._nextAttemptId
    if (!loader.observer) return fallback
    try {
      const id = loader.observer.attemptOpen(loader.sourceUrl)
      return typeof id === "number" ? id : fallback
    } catch (error) {
      return fallback
    }
  }

  function _detach(record) {
    if (!record) return
    if (record.connected && record.component && record.handler) {
      try {
        record.component.statusChanged.disconnect(record.handler)
      } catch (ignored) {}
    }
    record.connected = false
    if (loader.component === record.component) loader.component = null
    record.handler = null
    record.component = null
    if (loader._active === record) loader._active = null
  }

  function load() {
    // Adoption suppresses every later request; a terminal failure does not.
    if (loader.state === "loading" || loader.instance !== null) return false

    const attemptId = loader._allocateAttempt()
    const gen = ++loader.generation
    loader.state = "loading"
    loader.lastError = ""

    const comp = loader.componentFactory(loader.sourceUrl, Component.Asynchronous)
    if (!comp) {
      finish("failed", "loadError", attemptId, gen, "componentNull")
      return true
    }

    const record = {
      gen: gen,
      attemptId: attemptId,
      component: comp,
      handler: null,
      connected: false
    }
    loader._active = record
    loader.component = comp

    // Named closure, stored on the generation record rather than hidden in a
    // local, so teardown/shutdown can disconnect this exact handler once.
    function onStatus() {
      if (gen !== loader.generation) return
      if (loader._active !== record) return
      if (!record.component) return
      const status = record.component.status
      if (status === Component.Loading) return
      finish(status === Component.Ready ? "adopted" : "failed",
             status === Component.Ready ? "" : "loadError",
             attemptId, gen,
             status === Component.Ready ? "" : _componentError(record.component))
    }
    record.handler = onStatus

    if (comp.status === Component.Ready) {
      finish("adopted", "", attemptId, gen, "")
    } else if (comp.status === Component.Error) {
      finish("failed", "loadError", attemptId, gen, _componentError(comp))
    } else {
      try {
        comp.statusChanged.connect(onStatus)
        record.connected = true
      } catch (error) {
        // A component with no usable statusChanged is a load error, not a throw.
        finish("failed", "loadError", attemptId, gen, "statusChangedUnavailable")
      }
    }
    return true
  }

  function finish(kind, errorClass, attemptId, gen, detail) {
    if (gen !== loader.generation) return
    const record = loader._active
    if (!record || record.gen !== gen) return

    let object = null
    let outcomeClass = errorClass
    let outcomeDetail = detail
    if (kind === "adopted") {
      const comp = record.component
      if (!comp) return
      try {
        object = comp.createObject(loader.owner, loader.createProperties)
      } catch (error) {
        object = null
        outcomeClass = "createObjectThrew"
        outcomeDetail = _bound((error && error.message) || error)
      }
      // createObject can reenter (onCompleted, boot wiring, a nested request).
      // Validate the generation again before publishing anything.
      if (gen !== loader.generation || loader._active !== record) return
    }

    // Clear the pending pair and publish terminal state BEFORE any consumer
    // signal, because a consumer may issue another request from its handler.
    _detach(record)

    if (kind === "adopted" && object !== null) {
      loader.instance = object
      loader.state = "adopted"
      loader.lastError = ""
      loader.adopted(object, attemptId)
      return
    }

    if (kind === "adopted") {
      // Null adoption is a failure edge with no adopted signal.
      outcomeClass = "createObjectNull"
      outcomeDetail = "createObject returned null"
    }
    loader.instance = null
    loader.state = "failed"
    loader.lastError = _bound(outcomeDetail)
    loader.failed(outcomeClass, attemptId, _bound(outcomeDetail))
  }

  // Cancellation, not failure: disconnect the exact stored handler once,
  // invalidate by generation, emit no failed signal and call no fallback.
  function _cancel() {
    const record = loader._active
    loader.generation++
    _detach(record)
    loader.instance = null
    loader.component = null
    loader.state = "idle"
    loader.lastError = ""
    if (record && loader.observer) {
      try {
        // 0 is never closed, and a throwing observer is contained.
        if (record.attemptId > 0) loader.observer.attemptClose(record.attemptId, "teardown")
      } catch (ignored) {}
    }
  }

  function teardown() { loader._cancel() }
  function shutdown() { loader._cancel() }
  function reset() { loader._cancel() }

  Component.onDestruction: {
    try { loader._cancel() } catch (ignored) {}
  }
}
