// Probe: the AnnotationActions demand latch. The real singleton is imported,
// so every assertion drives the same bound hook, frozen records and id rules
// the capture service uses. Only the hook is a stub: it can throw, stay
// silent, answer "pending", or report a terminal failure, and a controller is
// adopted only when a scenario says a demand-loaded unit reached ready.
//
// The contract under test: a throw or a missing answer is "not ready" and the
// next demand asks again; only a terminal answer latches a denial, and that
// denial carries a reason and retires when a controller actually arrives.
// Rebinding the same hook must NOT retire it.

import QtQuick
import qs.common

Item {
  id: root

  width: 1
  height: 1

  property string error: ""

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  function spec() { return ({ screen: {} }) }

  // A controller that takes every open, so a request can reach "opened".
  function controller() {
    return function (cmd) { return cmd.code === "open" }
  }

  function drive() {
    const h = controller()

    // A thrown hook during startup is not a verdict. The second demand must
    // call it again; a permanent refusal would kill the flow for the session.
    let thrown = 0
    const boom = function () { thrown++; throw new Error("startup") }
    AnnotationActions.bind(boom)
    const t1 = AnnotationActions.request("picker", spec())
    kv("throw.reason", t1.reason)
    kv("throw.first.calls", thrown)
    AnnotationActions.request("picker", spec())
    kv("throw.second.calls", thrown)

    // No answer at all reads like "pending": retryable, with its own reason.
    let silent = 0
    const quiet = function () { silent++ }
    AnnotationActions.bind(quiet)
    const s1 = AnnotationActions.request("picker", spec())
    kv("silent.reason", s1.reason)
    AnnotationActions.request("picker", spec())
    kv("silent.second.calls", silent)

    // An explicit "pending" was already retryable; pin its reason too.
    let pending = 0
    const waiting = function () { pending++; return "pending" }
    AnnotationActions.bind(waiting)
    const p1 = AnnotationActions.request("picker", spec())
    kv("pending.reason", p1.reason)
    AnnotationActions.request("picker", spec())
    kv("pending.calls", pending)

    // A terminal answer latches: the hook is called once and the refusal
    // carries a reason a caller can branch on.
    let failed = 0
    const terminal = function () {
      failed++
      if (failed === 1) return false
      AnnotationActions.adopt(h)
      return true
    }
    AnnotationActions.bind(terminal)
    const f1 = AnnotationActions.request("picker", spec())
    kv("terminal.reason", f1.reason)
    const f2 = AnnotationActions.request("picker", spec())
    kv("terminal.latched.reason", f2.reason)
    kv("terminal.calls", failed)

    // bind() compares with ===, so re-running the same binding is a no-op and
    // the terminal denial survives it.
    AnnotationActions.bind(terminal)
    AnnotationActions.request("picker", spec())
    kv("bind.same.calls", failed)

    // The demand-loaded unit reaching ready is observable as a controller
    // adopting. Once it has, the denial is retired: releasing that controller
    // lets the next demand ask the same hook again and open a request.
    AnnotationActions.adopt(h)
    AnnotationActions.release(h)
    const after = AnnotationActions.request("picker", spec())
    kv("edge.calls", failed)
    kv("edge.ok", after.ok)
    kv("edge.code", after.code)
    if (after.ok) AnnotationActions.close(after.id)
    AnnotationActions.release(h)

    // A genuinely different hook still resets the verdict, as before.
    let fresh = 0
    const replacement = function () { fresh++; return "pending" }
    AnnotationActions.bind(replacement)
    const r = AnnotationActions.request("picker", spec())
    kv("bind.different.calls", fresh)
    kv("bind.different.reason", r.reason)
  }

  Component.onCompleted: {
    try {
      drive()
    } catch (e) {
      root.error = String(e && e.message ? e.message : e)
    }
    kv("probe.error", root.error)
    console.log("##DONE##")
  }
}
