pragma Singleton

import Quickshell
import qs.common

// Neutral lock request contract between session-level callers and the resident
// lock surface. The request path can only engage a session lock; release
// authority belongs to the surface and its PAM exchange, so nothing reachable
// through this contract clears a lock.
//
//   SessionActions.adopt(handler)                         // lock surface
//   const result = SessionActions.requestLock("suspend")  // { ok, code }
//   SessionActions.reportLock(result.id, "locked")        // lock surface
//
// Every entry point answers with a defined value, so a caller never infers
// whether a lock engaged: a refusal names its code and the caller alone
// decides whether a fallback applies.
Singleton {
  id: root

  // Discrete request and answer state, so a surface or a reader that attaches
  // after a request still sees the last one through Bus.latest(topic).
  readonly property string topic: "session.lock"
  readonly property string resultTopic: "session.lock.result"

  // A surface answers true once it engaged the lock, or "already_locked" when
  // one was held. Anything else is a refusal, and any other value names none.
  property var _handler: null
  property int _generation: 0

  // One resident surface answers requests. A second handler is refused so two
  // surfaces cannot both claim the same request, and identity comparison is
  // what keeps a re-adopt of the same surface idempotent.
  function adopt(handler) {
    if (typeof handler !== "function") return false
    if (root._handler !== null && root._handler !== handler) return false
    root._handler = handler
    return true
  }

  function release(handler) {
    if (root._handler !== handler) return false
    root._handler = null
    return true
  }

  // Ids only move forward, so an answer for a superseded request is refused
  // instead of overwriting a newer outcome.
  function requestLock(reason) {
    const request = Object.freeze({ id: root._generation + 1, reason: root._text(reason) })
    root._generation = request.id
    Bus.publish(root.topic, { id: request.id, reason: request.reason })
    if (root._handler === null) return { ok: false, code: "no_surface", id: request.id }
    let answer = null
    try {
      answer = root._handler(request)
    } catch (ignored) {
      return { ok: false, code: "handler_error", id: request.id }
    }
    // A held lock answers already_locked rather than a refusal: the surface
    // owns the lock state either way, so the caller needs no fallback.
    if (answer === true) return { ok: true, code: "locked", id: request.id }
    if (answer === "already_locked") return { ok: true, code: answer, id: request.id }
    return { ok: false, code: "refused", id: request.id }
  }

  // Answer path for a surface that engages the lock asynchronously. The answer
  // is published under its request id, so a request that is never answered
  // stays visible as an unanswered request rather than reading as a success.
  function reportLock(requestId, code) {
    const id = Number(requestId)
    if (!isFinite(id) || id <= 0 || id > root._generation) return false
    const answer = Object.freeze({ id: id, code: root._text(code) })
    Bus.publish(root.resultTopic, answer)
    return true
  }

  function _text(value) {
    return typeof value === "string" ? value : ""
  }
}
