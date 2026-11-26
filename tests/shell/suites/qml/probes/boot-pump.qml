// Probe: the real qs.boot.BootPump, constructed offscreen (it is a QtObject),
// driven with an injected fake clock and a recording observer.
//
// Every observer call and every pump callback is appended to one ordered event
// list; the shell suite compares that list, byte for byte, with a serialized
// fixture under tests/shell/fixtures/boot-pump/. Timer state is recorded at
// the points that distinguish a rearm from a timer left armed by an enqueue.
//
// A direct `pump._turn()` call is preceded by `tick.stop()` so it models a real
// one-shot timer firing (otherwise the timer that enqueue() armed would still
// be running when _turn() returns).
import QtQml
import Quickshell
import qs.boot

QtObject {
  id: root

  property Component pumpComponent: Component { BootPump { } }
  property var events: []
  property var calls: []
  property var callbackNames: []
  property int nextToken: 0
  property int ms: 0
  property string error: ""

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }
  function show(key, value) { kv(key, JSON.stringify(value)) }

  function push(target, op, fields) {
    const event = { op: op }
    if (fields) {
      for (const key in fields) {
        if (Object.prototype.hasOwnProperty.call(fields, key)) event[key] = fields[key]
      }
    }
    target.push(event)
  }
  function rec(op, fields) { push(events, op, fields) }
  function observe(op, fields) {
    const event = { op: op }
    if (fields) {
      for (const key in fields) {
        if (Object.prototype.hasOwnProperty.call(fields, key)) event[key] = fields[key]
      }
    }
    calls.push(event)
    events.push(event)
  }

  function makeObserver(cfg) {
    return {
      openWork: function (source, kind) {
        observe("openWork", { source: String(source), kind: String(kind) })
        if (cfg.throwOpen) throw new Error("openWork fault")
        const token = ++nextToken
        observe("token", { token: token })
        return token
      },
      closeWork: function (source, token, outcome) {
        observe("closeWork", {
          source: String(source), token: Number(token), outcome: String(outcome)
        })
      },
      enqueue: function (source, outcome) {
        observe("enqueue", { source: String(source), outcome: String(outcome) })
        if (cfg.throwEnqueue) throw new Error("enqueue fault")
      },
      dispatch: function (source, token, waitMs) {
        observe("dispatch", {
          source: String(source), token: Number(token), waitMs: Number(waitMs)
        })
        if (cfg.throwDispatch) throw new Error("dispatch fault")
      },
      noteFailure: function (code) { observe("noteFailure", { code: String(code) }) }
    }
  }

  function start(cfg) {
    events = []
    calls = []
    callbackNames = []
    nextToken = 0
    ms = 0
    const pump = pumpComponent.createObject(root)
    pump.now = function () { return ms }
    if (!cfg.inert) pump.observer = makeObserver(cfg)
    return pump
  }

  // BootPump owns its one-shot timer in a default _owned list; accept a direct
  // `tick` property too so the probe is not tied to either spelling.
  function timerOf(pump) {
    if (pump._owned && pump._owned.length > 0) return pump._owned[0]
    return pump.tick
  }
  function callback(name) {
    return function () {
      callbackNames.push(name)
      rec("callback", { name: name })
    }
  }
  function state(pump, step) {
    rec("state", { step: step, pending: pump.pending.length, timer: timerOf(pump).running })
  }
  function turn(pump) {
    timerOf(pump).stop()
    let result = "ok"
    try {
      pump._turn()
    } catch (error) {
      result = String((error && error.message) || error)
    }
    rec("turn", { result: result, pending: pump.pending.length, timer: timerOf(pump).running })
    return result
  }
  function noteFailures() {
    let n = 0
    for (const call of calls) if (call.op === "noteFailure") n++
    return n
  }
  function emit(key) { show(key + ".events", events) }

  Component.onCompleted: {
    try {
      run()
    } catch (error) {
      kv("probe.error", String((error && error.message) || error))
    }
    kv("probe.complete", "true")
    console.log("##DONE##")
  }

  function run() {
    const timerPump = pumpComponent.createObject(root)
    const timer = timerOf(timerPump)
    kv("pump.timer", JSON.stringify({
      interval: timer.interval,
      repeat: timer.repeat
    }))
    timerPump.destroy()

    normalReturn()
    throwWithoutEnqueue()
    throwAfterEnqueue()
    duplicate()
    alreadyArmed()
    reentrant()
    overlap()
    fakeClock()
    shutdownWithOpenToken()
    throwingDispatchObserver()
    throwingOpenObserver()
    throwingEnqueueObserver()
    inertObserver()
  }

  function normalReturn() {
    const pump = start({})
    kv("normal.enqueueA", pump.enqueue(callback("A"), "queue:early"))
    kv("normal.enqueueB", pump.enqueue(callback("B"), "queue:deferred"))
    state(pump, "armed")
    turn(pump)
    turn(pump)
    emit("normal")
    show("normal.callbacks", callbackNames)
    pump.destroy()
  }

  function throwWithoutEnqueue() {
    const pump = start({})
    const thrower = function () {
      callbackNames.push("THROW_NO_ENQUEUE")
      rec("callback", { name: "THROW_NO_ENQUEUE" })
      throw new Error("boom-no-enqueue")
    }
    kv("throwNoEnqueue.enqueue", pump.enqueue(thrower, "queue:entrance"))
    turn(pump)
    emit("throwNoEnqueue")
    pump.destroy()
  }

  function throwAfterEnqueue() {
    const pump = start({})
    kv("throwSelf.enqueue", pump.enqueue(function () {
      callbackNames.push("SELF")
      rec("callback", { name: "SELF" })
      const accepted = pump.enqueue(callback("FOLLOW"), "queue:replay")
      rec("enqueueResult", { result: accepted })
      state(pump, "insideCallback")
      // Neutralize the timer armed by the self-enqueue: a pump that wrongly
      // rearms after a throw would leave it running here.
      timerOf(pump).stop()
      throw new Error("boom-self")
    }, "queue:early"))
    turn(pump)
    turn(pump)
    emit("throwSelf")
    pump.destroy()
  }

  function duplicate() {
    const pump = start({})
    const fn = callback("A")
    kv("duplicate.first", pump.enqueue(fn, "queue:early"))
    timerOf(pump).stop()
    kv("duplicate.second", pump.enqueue(fn, "queue:deferred"))
    state(pump, "afterDuplicate")
    turn(pump)
    emit("duplicate")
    pump.destroy()
  }

  function alreadyArmed() {
    const pump = start({})
    pump.enqueue(callback("A"), "queue:early")
    state(pump, "firstArmed")
    pump.enqueue(callback("B"), "queue:entrance")
    state(pump, "secondArmed")
    turn(pump)
    turn(pump)
    emit("alreadyArmed")
    pump.destroy()
  }

  function reentrant() {
    const pump = start({})
    pump.enqueue(function () {
      callbackNames.push("OUTER")
      rec("callback", { name: "OUTER" })
      const accepted = pump.enqueue(callback("INNER"), "queue:replay")
      rec("enqueueResult", { result: accepted })
    }, "queue:early")
    turn(pump)
    turn(pump)
    emit("reentrant")
    pump.destroy()
  }

  function overlap() {
    const pump = start({})
    pump.enqueue(callback("early1"), "queue:early")
    pump.enqueue(callback("early2"), "queue:early")
    pump.enqueue(callback("deferred"), "queue:deferred")
    pump.enqueue(callback("replay"), "queue:replay")
    state(pump, "allQueued")
    turn(pump)
    turn(pump)
    turn(pump)
    turn(pump)
    emit("overlap")
    show("overlap.callbacks", callbackNames)
    pump.destroy()
  }

  function fakeClock() {
    const pump = start({})
    ms = 5
    pump.enqueue(callback("A"), "queue:early")
    ms = 15
    pump.enqueue(callback("B"), "queue:deferred")
    ms = 40
    turn(pump)
    turn(pump)
    emit("fakeClock")
    pump.destroy()
  }

  function shutdownWithOpenToken() {
    const pump = start({})
    pump.enqueue(callback("A"), "queue:early")
    pump.enqueue(callback("B"), "queue:deferred")
    let result = "ok"
    try {
      pump.shutdown()
    } catch (error) {
      result = String((error && error.message) || error)
    }
    rec("shutdown", { result: result })
    kv("shutdown.pending", pump.pending.length)
    kv("shutdown.timer", timerOf(pump).running)
    kv("shutdown.callbacks", JSON.stringify(callbackNames))
    emit("shutdown")
    pump.destroy()
  }

  function throwingDispatchObserver() {
    const pump = start({ throwDispatch: true })
    pump.enqueue(callback("A"), "queue:early")
    pump.enqueue(callback("B"), "queue:deferred")
    turn(pump)
    turn(pump)
    emit("observerDispatch")
    kv("observerDispatch.noteFailures", noteFailures())
    pump.destroy()
  }

  function throwingOpenObserver() {
    const pump = start({ throwOpen: true })
    pump.enqueue(callback("A"), "queue:early")
    state(pump, "armed")
    turn(pump)
    emit("observerOpen")
    kv("observerOpen.noteFailures", noteFailures())
    pump.destroy()
  }

  function throwingEnqueueObserver() {
    const pump = start({ throwEnqueue: true })
    const fn = callback("A")
    pump.enqueue(fn, "queue:early")
    timerOf(pump).stop()
    pump.enqueue(fn, "queue:replay")
    state(pump, "afterDuplicate")
    turn(pump)
    emit("observerDuplicate")
    kv("observerDuplicate.noteFailures", noteFailures())
    pump.destroy()
  }

  function inertObserver() {
    const pump = start({ inert: true })
    pump.enqueue(callback("A"), "queue:early")
    pump.enqueue(callback("B"), "queue:deferred")
    state(pump, "armed")
    turn(pump)
    turn(pump)
    emit("inert")
    show("inert.observerCalls", calls)
    show("inert.callbacks", callbackNames)
    kv("inert.noteFailures", noteFailures())
    pump.destroy()
  }
}
