pragma ComponentBehavior: Bound
import QtQml
import QtQuick as QQ

// Phase 1 FIFO pump: a literal port of the boot-owned drain pump. One callback
// per tick, in arrival order. No policy, clock or retry decision lives here.
QtObject {
  id: pump

  // [{ fn, token, source, enqueuedAtMs? }]
  property var pending: []

  // The original frame-budget clock, literally: one one-shot timer, restarted
  // on every accepted enqueue and on a non-throwing turn with work left.
  // A QtObject has no default child property, so the timer is owned through an
  // explicit one (the BootGate pattern) and dies with the pump.
  default property list<QtObject> _owned: [
    QQ.Timer {
      id: tick
      interval: 16
      repeat: false
      onTriggered: pump._turn()
    }
  ]

  // null = inert: zero observer calls and no noteFailure. Boot supplies the
  // recorder-backed observer; a missing observer is not an error.
  property var observer: null

  // Boot injects its existing monotonic clock. No BootClock, no Date.now().
  property var now: function () { return 0 }

  // Every observer call is fault-contained: a throw is reported once (when an
  // observer exists) and never changes pump control flow or escapes it.
  function _observe(fn) {
    try {
      fn()
    } catch (error) {
      try {
        if (pump.observer) pump.observer.noteFailure("observerThrow")
      } catch (ignored) {}
    }
  }

  // The token-returning form: a throwing openWork becomes an untracked entry
  // (token 0), which is never dispatched or closed.
  function _observeToken(fn) {
    try {
      return fn()
    } catch (error) {
      try {
        if (pump.observer) pump.observer.noteFailure("observerThrow")
      } catch (ignored) {}
      return 0
    }
  }

  function enqueue(fn, source) {
    const src = source || "queue:pump"
    for (let i = 0; i < pump.pending.length; i++) {
      if (pump.pending[i].fn === fn) {
        if (pump.observer) pump._observe(function () { pump.observer.enqueue(src, "duplicate") })
        return false
      }
    }
    // No observer lambda is built on the inert path.
    const token = pump.observer
      ? pump._observeToken(function () { return pump.observer.openWork(src, "callback") })
      : 0
    const entry = { fn: fn, token: token, source: src }
    if (pump.observer && token > 0) entry.enqueuedAtMs = pump.now()
    pump.pending.push(entry)
    if (pump.observer) pump._observe(function () { pump.observer.enqueue(src, "accepted") })
    tick.restart()
    return true
  }

  function _turn() {
    if (pump.pending.length === 0) return
    const entry = pump.pending.shift()
    const waitMs = typeof entry.enqueuedAtMs === "number"
      ? pump.now() - entry.enqueuedAtMs
      : 0
    if (pump.observer && entry.token > 0) {
      pump._observe(function () { pump.observer.dispatch(entry.source, entry.token, waitMs) })
    }
    let threw = false
    let error = null
    try {
      entry.fn()
    } catch (e) {
      threw = true
      error = e
    }
    if (pump.observer && entry.token > 0) {
      pump._observe(function () {
        pump.observer.closeWork(entry.source, entry.token,
          threw ? "callbackThrew" : "callbackReturned")
      })
    }
    // A throwing callback that self-enqueued already armed the timer in
    // enqueue(); do not rearm it here. The original error is rethrown.
    if (!threw && pump.pending.length > 0) tick.restart()
    if (threw) throw error
  }

  function shutdown() {
    if (pump.observer) {
      for (let i = 0; i < pump.pending.length; i++) {
        const entry = pump.pending[i]
        if (entry.token > 0) {
          pump._observe(function () {
            pump.observer.closeWork(entry.source, entry.token, "teardown")
          })
        }
      }
    }
    pump.pending = []
    tick.stop()
  }

  Component.onDestruction: pump.shutdown()
}
